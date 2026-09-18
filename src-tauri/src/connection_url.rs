//! Reads and writes database connection strings.
//!
//! Hand-rolled rather than built on a URL crate, because real-world connection strings
//! routinely carry unencoded `@`, `:` and `/` inside the password, which strict URL
//! parsers reject outright. Splitting on the *last* `@` before the host, and the *first*
//! `:` inside the user info, handles those the way libpq and the MySQL clients do.
//!
//! Understood forms:
//! - `postgres://user:pass@host:5432/db?sslmode=require`
//! - `mysql://user@host/db`, `mariadb://…`, `redis://…`, `mongodb://…`
//! - `jdbc:postgresql://host/db`
//! - `sqlite:///absolute/path.db`, `file:///absolute/path.db`, or a bare filesystem path
//! - libpq keyword form: `host=… port=… dbname=… user=… password=…`

use crate::models::{ConnectionProfile, DatabaseKind, SslMode};

/// What a connection string turned into. `warnings` carries anything that was understood
/// but not honoured exactly, so the UI can say so instead of silently changing meaning.
#[derive(Debug, Clone)]
pub struct ParsedConnectionUrl {
    pub profile: ConnectionProfile,
    pub password: Option<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConnectionUrlError {
    #[error("Enter a connection URL.")]
    Empty,
    #[error("This does not look like a connection URL. Expected something like postgres://user:password@host:5432/database.")]
    UnrecognisedFormat,
    #[error("\"{0}\" is not a database MieSQL supports. Use postgres, mysql, mariadb, sqlite, redis or mongodb.")]
    UnsupportedScheme(String),
    #[error("The URL has no database file path.")]
    MissingFilePath,
    #[error("\"{0}\" is not a valid port number.")]
    InvalidPort(String),
}

type Result<T> = std::result::Result<T, ConnectionUrlError>;

pub fn parse(raw_input: &str) -> Result<ParsedConnectionUrl> {
    let input = clean(raw_input);
    if input.is_empty() {
        return Err(ConnectionUrlError::Empty);
    }

    // `host=… dbname=…` — common in .env files and PostgreSQL docs.
    if !input.contains("://") && input.contains('=') && !looks_like_path(&input) {
        return parse_keyword_value(&input);
    }

    // A bare path is the friendliest way to add a SQLite file.
    if looks_like_path(&input) {
        return Ok(sqlite_result(&expand_tilde(&input), &[]));
    }

    // JDBC prefixes wrap an otherwise ordinary URL.
    let body = if input.to_lowercase().starts_with("jdbc:") {
        input["jdbc:".len()..].to_string()
    } else {
        input.clone()
    };

    let colon = body.find(':').ok_or(ConnectionUrlError::UnrecognisedFormat)?;
    let scheme = body[..colon].to_lowercase();
    let mut remainder = body[colon + 1..].to_string();
    // `scheme://rest` and `scheme:rest` are both seen in the wild.
    if let Some(stripped) = remainder.strip_prefix("//") {
        remainder = stripped.to_string();
    }

    let kind = kind_for_scheme(&scheme).ok_or(ConnectionUrlError::UnsupportedScheme(scheme))?;

    // Split the query off first; everything before it is authority plus path.
    let (authority_and_path, query) = match remainder.find('?') {
        Some(mark) => (
            remainder[..mark].to_string(),
            parse_query(&remainder[mark + 1..]),
        ),
        None => (remainder.clone(), Vec::new()),
    };

    if kind.is_file_based() {
        // `sqlite:///abs/path` leaves an empty authority and an absolute path;
        // `sqlite://./rel.db` puts the first segment in the authority.
        let mut path = authority_and_path.clone();
        if !path.starts_with('/') && !path.starts_with('~') && !path.is_empty() {
            path = if authority_and_path.starts_with('.') {
                authority_and_path.clone()
            } else {
                format!("/{path}")
            };
        }
        let expanded = expand_tilde(&percent_decoded(&path));
        if expanded.is_empty() || expanded == "/" {
            return Err(ConnectionUrlError::MissingFilePath);
        }
        return Ok(sqlite_result(&expanded, &query));
    }

    let chars: Vec<char> = authority_and_path.chars().collect();
    let last_at = chars.iter().rposition(|c| *c == '@');
    let search_start = last_at.map(|i| i + 1).unwrap_or(0);
    let path_start = chars[search_start..]
        .iter()
        .position(|c| *c == '/')
        .map(|i| i + search_start);

    let authority_end = path_start.unwrap_or(chars.len());
    let mut database = String::new();
    if let Some(start) = path_start {
        database = percent_decoded(&chars[start + 1..].iter().collect::<String>());
    }

    let mut username = String::new();
    let mut password = None;
    // Everything between the user info and the path is host and port. With no `@`,
    // `search_start` is already the start of the string.
    let host_port: String = chars[search_start..authority_end].iter().collect();

    if let Some(at) = last_at {
        let user_info: String = chars[..at].iter().collect();
        // The password may itself contain `:`, so only the first one separates.
        match user_info.find(':') {
            Some(sep) => {
                username = percent_decoded(&user_info[..sep]);
                password = Some(percent_decoded(&user_info[sep + 1..]));
            }
            None => username = percent_decoded(&user_info),
        }
    }

    let (host, port) = split_host_and_port(&host_port, kind.default_port())?;

    let mut warnings = Vec::new();
    let mut profile = ConnectionProfile::new(kind);
    profile.host = if host.is_empty() { "127.0.0.1".into() } else { host };
    profile.port = port;
    profile.username = username.clone();
    profile.database = database;

    // `postgres://user@host/` means "connect to the database named after the user", which
    // is what libpq does when dbname is omitted.
    if kind == DatabaseKind::Postgres && profile.database.is_empty() && !username.is_empty() {
        profile.database = username;
        warnings.push(
            "No database in the URL, so the username was used — the same default libpq applies."
                .to_string(),
        );
    }

    apply_query(&query, &mut profile, &mut warnings);
    profile.name = suggested_name(&profile);
    profile.save_password = password.is_some();

    Ok(ParsedConnectionUrl {
        profile,
        password,
        warnings,
    })
}

/// Rebuilds a URL from a profile. The password is left out unless asked for, so
/// "Copy Connection URL" is safe to paste into a ticket.
pub fn to_string(profile: &ConnectionProfile, password: Option<&str>, include_password: bool) -> String {
    if profile.kind.is_file_based() {
        return format!("sqlite://{}", profile.file_path);
    }

    let mut url = format!("{}://", scheme_for_kind(profile.kind));
    if !profile.username.is_empty() {
        url.push_str(&encode(&profile.username));
        if include_password {
            if let Some(password) = password.filter(|p| !p.is_empty()) {
                url.push(':');
                url.push_str(&encode(password));
            }
        }
        url.push('@');
    }
    if profile.host.contains(':') {
        url.push_str(&format!("[{}]", profile.host));
    } else {
        url.push_str(&profile.host);
    }
    if profile.port != profile.kind.default_port() {
        url.push_str(&format!(":{}", profile.port));
    }
    if !profile.database.is_empty() {
        url.push('/');
        url.push_str(&encode(&profile.database));
    }

    let mut parameters = Vec::new();
    if profile.ssl_mode != SslMode::Prefer {
        parameters.push(format!(
            "sslmode={}",
            match profile.ssl_mode {
                SslMode::Disable => "disable",
                SslMode::Prefer => "prefer",
                SslMode::Require => "require",
            }
        ));
    }
    if profile.read_only {
        parameters.push("readonly=true".to_string());
    }
    if !parameters.is_empty() {
        url.push('?');
        url.push_str(&parameters.join("&"));
    }
    url
}

/// True when the text stands a chance of parsing, used to decide whether to offer the
/// clipboard's contents.
pub fn looks_like_connection_url(text: &str) -> bool {
    let cleaned = clean(text);
    if cleaned.is_empty() || cleaned.len() >= 2048 || cleaned.contains('\n') {
        return false;
    }
    if looks_like_path(&cleaned) {
        return true;
    }
    if cleaned.contains("host=") {
        return true;
    }
    if cleaned.to_lowercase().starts_with("jdbc:") {
        return true;
    }
    match cleaned.find(':') {
        Some(colon) => kind_for_scheme(&cleaned[..colon].to_lowercase()).is_some(),
        None => false,
    }
}

// MARK: - Pieces

fn kind_for_scheme(scheme: &str) -> Option<DatabaseKind> {
    match scheme {
        "postgres" | "postgresql" | "psql" | "pgsql" => Some(DatabaseKind::Postgres),
        "mysql" | "mysqlx" => Some(DatabaseKind::Mysql),
        "mariadb" => Some(DatabaseKind::Mariadb),
        "sqlite" | "sqlite3" | "file" => Some(DatabaseKind::Sqlite),
        "redis" | "rediss" => Some(DatabaseKind::Redis),
        "mongodb" | "mongodb+srv" => Some(DatabaseKind::Mongodb),
        _ => None,
    }
}

fn scheme_for_kind(kind: DatabaseKind) -> &'static str {
    match kind {
        DatabaseKind::Postgres => "postgres",
        DatabaseKind::Mysql => "mysql",
        DatabaseKind::Mariadb => "mariadb",
        DatabaseKind::Sqlite => "sqlite",
        DatabaseKind::Redis => "redis",
        DatabaseKind::Mongodb => "mongodb",
    }
}

fn split_host_and_port(input: &str, default_port: u16) -> Result<(String, u16)> {
    if input.is_empty() {
        return Ok((String::new(), default_port));
    }

    // Bracketed IPv6: [::1]:5432
    if let Some(stripped) = input.strip_prefix('[') {
        if let Some(close) = stripped.find(']') {
            let host = stripped[..close].to_string();
            let rest = &stripped[close + 1..];
            return match rest.strip_prefix(':') {
                Some(port_text) => port_text
                    .parse::<u16>()
                    .ok()
                    .filter(|p| *p > 0)
                    .map(|p| (host.clone(), p))
                    .ok_or_else(|| ConnectionUrlError::InvalidPort(port_text.to_string())),
                None => Ok((host, default_port)),
            };
        }
    }

    // A comma-separated host list is a failover list; the first entry is the one to use.
    let candidate = input.split(',').next().unwrap_or(input);

    let Some(colon) = candidate.rfind(':') else {
        return Ok((percent_decoded(candidate), default_port));
    };
    // A bare, unbracketed IPv6 address has several colons and no port.
    if candidate.matches(':').count() > 1 {
        return Ok((percent_decoded(candidate), default_port));
    }
    let port_text = &candidate[colon + 1..];
    let port = port_text
        .parse::<u16>()
        .ok()
        .filter(|p| *p > 0)
        .ok_or_else(|| ConnectionUrlError::InvalidPort(port_text.to_string()))?;
    Ok((percent_decoded(&candidate[..colon]), port))
}

fn apply_query(query: &[(String, String)], profile: &mut ConnectionProfile, warnings: &mut Vec<String>) {
    for (raw_key, raw_value) in query {
        let key = raw_key.to_lowercase().replace(['-', '_'], "");
        let value = raw_value.to_lowercase();

        match key.as_str() {
            "sslmode" | "ssl" | "usessl" | "tls" | "tlsmode" | "sslaccept" => {
                if let Some(mode) = ssl_mode_from(&value, warnings) {
                    profile.ssl_mode = mode;
                }
            }
            "connecttimeout" | "timeout" | "connecttimeoutms" => {
                if let Ok(seconds) = value.parse::<u64>() {
                    // Some drivers express this in milliseconds; anything huge is clearly that.
                    profile.connect_timeout_seconds =
                        if seconds > 600 { (seconds / 1000).max(1) } else { seconds.max(1) };
                }
            }
            "mode" => {
                if value == "ro" {
                    profile.read_only = true;
                }
            }
            "readonly" | "immutable" => {
                if matches!(value.as_str(), "true" | "1" | "yes") {
                    profile.read_only = true;
                }
            }
            "user" | "username" | "uid" => {
                if profile.username.is_empty() {
                    profile.username = raw_value.clone();
                }
            }
            // Deliberately ignored: the caller decides what to do with secrets, and a
            // password in the user-info section already took priority.
            "password" | "pwd" => {}
            "dbname" | "database" | "db" => {
                if profile.database.is_empty() {
                    profile.database = raw_value.clone();
                }
            }
            "host" | "server" | "hostaddr" => {
                if profile.host.is_empty() || profile.host == "127.0.0.1" {
                    profile.host = raw_value.clone();
                }
            }
            "port" => {
                if let Ok(port) = value.parse::<u16>() {
                    if port > 0 {
                        profile.port = port;
                    }
                }
            }
            "applicationname" | "appname" => {
                if profile.name.is_empty() {
                    profile.name = raw_value.clone();
                }
            }
            _ => {}
        }
    }
}

fn ssl_mode_from(value: &str, warnings: &mut Vec<String>) -> Option<SslMode> {
    // Drivers spell these with and without separators: `verify-full`, `verify_full`,
    // `VERIFY_IDENTITY`. Normalise before matching so one arm covers every spelling.
    let normalised = value.replace(['-', '_'], "");
    match normalised.as_str() {
        "disable" | "disabled" | "false" | "0" | "no" | "off" | "skip" => Some(SslMode::Disable),
        "allow" | "prefer" | "preferred" | "true" | "1" | "yes" | "on" => Some(SslMode::Prefer),
        "require" | "required" | "skipverify" => Some(SslMode::Require),
        "verifyca" | "verifyfull" | "verifyidentity" => {
            warnings.push(format!(
                "Certificate verification is not implemented yet, so \"{value}\" was treated as Require: the connection is encrypted but the server's certificate is not validated."
            ));
            Some(SslMode::Require)
        }
        _ => None,
    }
}

/// libpq's `host=localhost port=5432 dbname=app` form.
fn parse_keyword_value(input: &str) -> Result<ParsedConnectionUrl> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    let mut key = String::new();
    let mut value = String::new();
    let mut reading_key = true;
    let mut quote: Option<char> = None;
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;

    macro_rules! commit {
        () => {
            let trimmed = key.trim().to_lowercase();
            if !trimmed.is_empty() {
                pairs.push((trimmed, value.clone()));
            }
            key.clear();
            value.clear();
            reading_key = true;
        };
    }

    while i < chars.len() {
        let c = chars[i];
        if let Some(active) = quote {
            if c == '\\' && i + 1 < chars.len() {
                i += 1;
                value.push(chars[i]);
            } else if c == active {
                quote = None;
            } else {
                value.push(c);
            }
        } else if reading_key {
            if c == '=' {
                reading_key = false;
            } else if c.is_whitespace() {
                if !key.is_empty() {
                    commit!();
                }
            } else {
                key.push(c);
            }
        } else if c == '\'' || c == '"' {
            quote = Some(c);
        } else if c.is_whitespace() {
            commit!();
        } else {
            value.push(c);
        }
        i += 1;
    }
    if !key.is_empty() {
        commit!();
    }

    if pairs.is_empty() {
        return Err(ConnectionUrlError::UnrecognisedFormat);
    }

    let get = |name: &str| -> Option<String> {
        pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
    };

    let mut warnings = Vec::new();
    let mut profile = ConnectionProfile::new(DatabaseKind::Postgres);
    profile.host = get("host").or_else(|| get("hostaddr")).unwrap_or_else(default_host);
    profile.port = get("port")
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or_else(|| DatabaseKind::Postgres.default_port());
    profile.username = get("user").or_else(|| get("username")).unwrap_or_default();
    profile.database = get("dbname")
        .or_else(|| get("database"))
        .unwrap_or_else(|| profile.username.clone());

    let known = ["host", "hostaddr", "port", "user", "username", "dbname", "database", "password"];
    let extras: Vec<(String, String)> = pairs
        .iter()
        .filter(|(k, _)| !known.contains(&k.as_str()))
        .cloned()
        .collect();
    apply_query(&extras, &mut profile, &mut warnings);

    let password = get("password");
    profile.save_password = password.is_some();
    profile.name = suggested_name(&profile);

    Ok(ParsedConnectionUrl {
        profile,
        password,
        warnings,
    })
}

fn sqlite_result(path: &str, query: &[(String, String)]) -> ParsedConnectionUrl {
    let mut warnings = Vec::new();
    let mut profile = ConnectionProfile::new(DatabaseKind::Sqlite);
    profile.file_path = path.to_string();
    profile.save_password = false;
    apply_query(query, &mut profile, &mut warnings);
    profile.name = suggested_name(&profile);
    ParsedConnectionUrl {
        profile,
        password: None,
        warnings,
    }
}

fn suggested_name(profile: &ConnectionProfile) -> String {
    if profile.kind.is_file_based() {
        return std::path::Path::new(&profile.file_path)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "SQLite".to_string());
    }
    if !profile.database.is_empty() {
        return profile.database.clone();
    }
    profile.host.clone()
}

fn default_host() -> String {
    "127.0.0.1".to_string()
}

// MARK: - Text helpers

fn clean(input: &str) -> String {
    let mut text = input.trim().to_string();
    // Tolerate a value copied straight out of a shell or .env file.
    for wrapper in ['"', '\'', '`'] {
        if text.len() > 1 && text.starts_with(wrapper) && text.ends_with(wrapper) {
            text = text[1..text.len() - 1].to_string();
        }
    }
    for prefix in ["DATABASE_URL=", "database_url=", "export DATABASE_URL="] {
        if let Some(stripped) = text.strip_prefix(prefix) {
            return clean(stripped);
        }
    }
    text
}

fn looks_like_path(input: &str) -> bool {
    if input.contains("://") {
        return false;
    }
    if input.starts_with('/') || input.starts_with("~/") || input.starts_with("./") {
        return true;
    }
    let lowered = input.to_lowercase();
    [".sqlite", ".sqlite3", ".db"].iter().any(|ext| lowered.ends_with(ext))
}

fn expand_tilde(path: &str) -> String {
    match path.strip_prefix('~') {
        Some(rest) => dirs::home_dir()
            .map(|home| format!("{}{}", home.to_string_lossy(), rest))
            .unwrap_or_else(|| path.to_string()),
        None => path.to_string(),
    }
}

fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| match pair.find('=') {
            Some(sep) => (
                percent_decoded(&pair[..sep]),
                percent_decoded(&pair[sep + 1..]),
            ),
            None => (percent_decoded(pair), String::new()),
        })
        .collect()
}

fn percent_decoded(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(byte) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                output.push(byte);
                i += 3;
                continue;
            }
        }
        output.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&output).to_string()
}

fn encode(value: &str) -> String {
    // Only the unreserved set is left alone, which keeps `@`, `:`, `/` and `?` safe
    // wherever the component lands.
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}
