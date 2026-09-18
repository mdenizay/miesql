//! Ported from the Swift test suite the v0.1 release shipped with. The cases are the
//! specification; keeping them identical is how the rewrite proves it did not lose
//! behaviour that was already correct.

use miesql_lib::connection_url::{self, ConnectionUrlError};
use miesql_lib::models::{DatabaseKind, SqlValue, SslMode, TableRef};
use miesql_lib::sql::dialect::{self, Dialect};
use miesql_lib::sql::splitter;

// MARK: - Statement splitting

#[test]
fn splits_simple_script() {
    let statements = splitter::split("SELECT 1; SELECT 2;", DatabaseKind::Postgres);
    let texts: Vec<&str> = statements.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(texts, vec!["SELECT 1", "SELECT 2"]);
}

#[test]
fn ignores_semicolons_inside_strings() {
    let statements = splitter::split("SELECT 'a;b'; SELECT 2", DatabaseKind::Postgres);
    assert_eq!(statements.len(), 2);
    assert_eq!(statements[0].text, "SELECT 'a;b'");
}

#[test]
fn ignores_semicolons_inside_comments() {
    let sql = "-- first; not a split\nSELECT 1;\n/* also; not a split */\nSELECT 2";
    assert_eq!(splitter::split(sql, DatabaseKind::Postgres).len(), 2);
}

#[test]
fn handles_dollar_quoting() {
    let sql = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT 1";
    let statements = splitter::split(sql, DatabaseKind::Postgres);
    assert_eq!(statements.len(), 2);
    assert!(statements[0].text.contains("BEGIN RETURN 1; END;"));
}

#[test]
fn honours_mysql_delimiter() {
    let sql = "DELIMITER //\nCREATE TRIGGER t BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2;";
    let statements = splitter::split(sql, DatabaseKind::Mysql);
    assert!(statements
        .iter()
        .any(|s| s.text.contains("CREATE TRIGGER") && s.text.contains("SELECT 1;")));
    assert!(statements.iter().any(|s| s.text == "SELECT 2"));
}

#[test]
fn escaped_quotes_do_not_end_a_literal() {
    let statements = splitter::split("SELECT 'it''s'; SELECT 2", DatabaseKind::Postgres);
    assert_eq!(statements.len(), 2);
    assert_eq!(statements[0].text, "SELECT 'it''s'");
}

#[test]
fn finds_the_statement_under_the_caret() {
    let sql = "SELECT 1;\nSELECT 2;";
    let found = splitter::statement_at(sql, 12, DatabaseKind::Postgres).expect("statement");
    assert_eq!(found.text, "SELECT 2");
}

// MARK: - Dialect quoting

#[test]
fn quotes_identifiers_per_engine() {
    assert_eq!(Dialect::new(DatabaseKind::Mysql).quote("users"), "`users`");
    assert_eq!(Dialect::new(DatabaseKind::Postgres).quote("users"), "\"users\"");
    assert_eq!(Dialect::new(DatabaseKind::Sqlite).quote("users"), "\"users\"");
}

#[test]
fn doubles_embedded_quote_characters() {
    assert_eq!(Dialect::new(DatabaseKind::Mysql).quote("we`ird"), "`we``ird`");
    assert_eq!(
        Dialect::new(DatabaseKind::Postgres).quote("we\"ird"),
        "\"we\"\"ird\""
    );
}

#[test]
fn escapes_string_literals() {
    assert_eq!(
        Dialect::new(DatabaseKind::Postgres).string_literal("it's"),
        "'it''s'"
    );
    // MySQL also needs the backslash doubled.
    assert_eq!(
        Dialect::new(DatabaseKind::Mysql).string_literal("a\\b"),
        "'a\\\\b'"
    );
}

#[test]
fn renders_null_as_a_keyword() {
    let d = Dialect::new(DatabaseKind::Postgres);
    assert_eq!(d.literal(&SqlValue::Null), "NULL");
    assert_eq!(d.literal(&SqlValue::text("NULL")), "'NULL'");
}

#[test]
fn finds_leading_keyword_past_comments() {
    assert_eq!(dialect::leading_keyword("  -- note\n SELECT 1"), "select");
    assert_eq!(dialect::leading_keyword("/* x */ DELETE FROM t"), "delete");
}

#[test]
fn classifies_read_only_statements() {
    assert!(dialect::is_read_only_statement("SELECT 1"));
    assert!(dialect::is_read_only_statement(
        "WITH t AS (SELECT 1) SELECT * FROM t"
    ));
    assert!(!dialect::is_read_only_statement("DROP TABLE users"));
    assert!(!dialect::is_read_only_statement("UPDATE users SET a = 1"));
}

#[test]
fn builds_paged_select_statements() {
    let d = Dialect::new(DatabaseKind::Postgres);
    let table = TableRef::new("app", "public", "users");
    let sql = d.select_statement(&table, "age > 30", &[("id".into(), true)], 50, 100);
    assert_eq!(
        sql,
        "SELECT * FROM \"public\".\"users\" WHERE age > 30 ORDER BY \"id\" ASC LIMIT 50 OFFSET 100"
    );
}

// MARK: - Connection URLs

#[test]
fn parses_a_full_postgres_url() {
    let parsed = connection_url::parse("postgres://admin:s3cret@db.example.com:6432/analytics").unwrap();
    assert_eq!(parsed.profile.kind, DatabaseKind::Postgres);
    assert_eq!(parsed.profile.host, "db.example.com");
    assert_eq!(parsed.profile.port, 6432);
    assert_eq!(parsed.profile.username, "admin");
    assert_eq!(parsed.profile.database, "analytics");
    assert_eq!(parsed.password.as_deref(), Some("s3cret"));
    assert_eq!(parsed.profile.name, "analytics");
    assert!(parsed.profile.save_password);
}

#[test]
fn accepts_every_postgres_scheme_spelling() {
    for scheme in ["postgres", "postgresql", "psql", "pgsql"] {
        let parsed = connection_url::parse(&format!("{scheme}://u@h/d")).unwrap();
        assert_eq!(parsed.profile.kind, DatabaseKind::Postgres);
    }
}

#[test]
fn tells_mysql_and_mariadb_apart() {
    assert_eq!(
        connection_url::parse("mysql://root@localhost/shop").unwrap().profile.kind,
        DatabaseKind::Mysql
    );
    assert_eq!(
        connection_url::parse("mariadb://root@localhost/shop").unwrap().profile.kind,
        DatabaseKind::Mariadb
    );
    assert_eq!(
        connection_url::parse("mysql://root@localhost/shop").unwrap().profile.port,
        3306
    );
}

#[test]
fn recognises_the_new_engines() {
    assert_eq!(
        connection_url::parse("redis://localhost:6379").unwrap().profile.kind,
        DatabaseKind::Redis
    );
    assert_eq!(
        connection_url::parse("mongodb://user:pw@localhost:27017/app").unwrap().profile.kind,
        DatabaseKind::Mongodb
    );
}

#[test]
fn unwraps_a_jdbc_prefix() {
    let parsed = connection_url::parse("jdbc:postgresql://localhost:5432/app").unwrap();
    assert_eq!(parsed.profile.kind, DatabaseKind::Postgres);
    assert_eq!(parsed.profile.database, "app");
    assert_eq!(parsed.profile.port, 5432);
}

#[test]
fn password_containing_at_sign_does_not_break_the_host() {
    let parsed = connection_url::parse("postgres://user:p@ss@w0rd@db.internal:5432/app").unwrap();
    assert_eq!(parsed.profile.host, "db.internal");
    assert_eq!(parsed.profile.username, "user");
    assert_eq!(parsed.password.as_deref(), Some("p@ss@w0rd"));
}

#[test]
fn password_containing_colon_and_slash_survives() {
    let parsed = connection_url::parse("mysql://root:a:b/c@127.0.0.1:3306/shop").unwrap();
    assert_eq!(parsed.profile.username, "root");
    assert_eq!(parsed.password.as_deref(), Some("a:b/c"));
    assert_eq!(parsed.profile.host, "127.0.0.1");
    assert_eq!(parsed.profile.database, "shop");
}

#[test]
fn decodes_percent_encoded_credentials() {
    let parsed = connection_url::parse("postgres://my%40user:p%40ss%2Fword@host/my%20db").unwrap();
    assert_eq!(parsed.profile.username, "my@user");
    assert_eq!(parsed.password.as_deref(), Some("p@ss/word"));
    assert_eq!(parsed.profile.database, "my db");
}

#[test]
fn handles_ipv6_hosts() {
    let bracketed = connection_url::parse("postgres://u@[::1]:5433/app").unwrap();
    assert_eq!(bracketed.profile.host, "::1");
    assert_eq!(bracketed.profile.port, 5433);

    // Unbracketed and portless: the colons belong to the address, not a port.
    let bare = connection_url::parse("postgres://u@2001:db8::1/app").unwrap();
    assert_eq!(bare.profile.host, "2001:db8::1");
    assert_eq!(bare.profile.port, 5432);
}

#[test]
fn takes_the_first_host_from_a_failover_list() {
    let parsed =
        connection_url::parse("postgres://u@primary.example.com:5432,replica.example.com:5432/app")
            .unwrap();
    assert_eq!(parsed.profile.host, "primary.example.com");
}

#[test]
fn database_defaults_to_the_username() {
    let parsed = connection_url::parse("postgres://ada@localhost").unwrap();
    assert_eq!(parsed.profile.database, "ada");
    assert!(!parsed.warnings.is_empty());
}

#[test]
fn maps_ssl_mode_onto_the_profile() {
    let mode = |url: &str| connection_url::parse(url).unwrap().profile.ssl_mode;
    assert_eq!(mode("postgres://u@h/d?sslmode=disable"), SslMode::Disable);
    assert_eq!(mode("postgres://u@h/d?sslmode=prefer"), SslMode::Prefer);
    assert_eq!(mode("postgres://u@h/d?sslmode=require"), SslMode::Require);
    assert_eq!(mode("mysql://u@h/d?useSSL=true"), SslMode::Prefer);
    assert_eq!(mode("mysql://u@h/d?ssl-mode=DISABLED"), SslMode::Disable);
}

#[test]
fn warns_that_verify_full_is_downgraded() {
    let parsed = connection_url::parse("postgres://u@h/d?sslmode=verify-full").unwrap();
    assert_eq!(parsed.profile.ssl_mode, SslMode::Require);
    assert!(parsed
        .warnings
        .iter()
        .any(|w| w.to_lowercase().contains("verify-full")));
}

#[test]
fn reads_timeouts_and_read_only_flags() {
    let timeout = |url: &str| connection_url::parse(url).unwrap().profile.connect_timeout_seconds;
    assert_eq!(timeout("postgres://u@h/d?connect_timeout=30"), 30);
    // Millisecond-style values are converted rather than taken as a 30000-second wait.
    assert_eq!(timeout("postgres://u@h/d?connectTimeout=30000"), 30);
    assert!(connection_url::parse("postgres://u@h/d?readonly=true").unwrap().profile.read_only);
}

#[test]
fn parses_sqlite_urls_and_bare_paths() {
    let path = |url: &str| connection_url::parse(url).unwrap().profile.file_path;
    assert_eq!(path("sqlite:///Users/ada/app.sqlite"), "/Users/ada/app.sqlite");
    assert_eq!(path("file:///tmp/data.db"), "/tmp/data.db");
    assert_eq!(path("/Users/ada/app.sqlite"), "/Users/ada/app.sqlite");
    assert_eq!(path("./local.db"), "./local.db");

    assert_eq!(
        connection_url::parse("/Users/ada/app.sqlite").unwrap().profile.kind,
        DatabaseKind::Sqlite
    );
    assert_eq!(
        connection_url::parse("sqlite:///var/db/inventory.sqlite").unwrap().profile.name,
        "inventory"
    );
    assert!(connection_url::parse("sqlite:///tmp/a.db?mode=ro").unwrap().profile.read_only);
}

#[test]
fn expands_a_tilde_in_a_sqlite_path() {
    let parsed = connection_url::parse("~/Databases/app.sqlite").unwrap();
    assert!(!parsed.profile.file_path.starts_with('~'));
    assert!(parsed.profile.file_path.ends_with("/Databases/app.sqlite"));
}

#[test]
fn parses_the_keyword_value_form() {
    let parsed = connection_url::parse(
        "host=db.example.com port=5433 dbname=app user=ada password='se cret' sslmode=require",
    )
    .unwrap();
    assert_eq!(parsed.profile.kind, DatabaseKind::Postgres);
    assert_eq!(parsed.profile.host, "db.example.com");
    assert_eq!(parsed.profile.port, 5433);
    assert_eq!(parsed.profile.database, "app");
    assert_eq!(parsed.profile.username, "ada");
    assert_eq!(parsed.password.as_deref(), Some("se cret"));
    assert_eq!(parsed.profile.ssl_mode, SslMode::Require);
}

#[test]
fn strips_quotes_and_an_env_var_prefix() {
    let from_env = connection_url::parse("DATABASE_URL=\"postgres://u:p@h:5432/d\"").unwrap();
    assert_eq!(from_env.profile.host, "h");
    assert_eq!(from_env.profile.database, "d");

    let quoted = connection_url::parse("  'mysql://root@localhost/shop'  ").unwrap();
    assert_eq!(quoted.profile.kind, DatabaseKind::Mysql);
}

#[test]
fn rejects_what_it_cannot_understand() {
    assert_eq!(connection_url::parse("   ").unwrap_err(), ConnectionUrlError::Empty);
    assert_eq!(
        connection_url::parse("amqp://localhost:5672").unwrap_err(),
        ConnectionUrlError::UnsupportedScheme("amqp".into())
    );
    assert_eq!(
        connection_url::parse("postgres://u@host:abc/db").unwrap_err(),
        ConnectionUrlError::InvalidPort("abc".into())
    );
    assert!(connection_url::parse("just some words").is_err());
}

#[test]
fn recognises_candidates_without_parsing_them() {
    assert!(connection_url::looks_like_connection_url("postgres://u@h/d"));
    assert!(connection_url::looks_like_connection_url("jdbc:mysql://h/d"));
    assert!(connection_url::looks_like_connection_url("/Users/ada/app.sqlite"));
    assert!(connection_url::looks_like_connection_url("host=localhost dbname=app"));
    assert!(!connection_url::looks_like_connection_url("SELECT * FROM users"));
    assert!(!connection_url::looks_like_connection_url("https://example.com"));
    assert!(!connection_url::looks_like_connection_url(""));
}

#[test]
fn serialises_back_to_a_url_that_parses_the_same_way() {
    let mut profile = miesql_lib::models::ConnectionProfile::new(DatabaseKind::Postgres);
    profile.host = "db.example.com".into();
    profile.port = 6432;
    profile.username = "my@user".into();
    profile.database = "analytics".into();
    profile.ssl_mode = SslMode::Require;

    let url = connection_url::to_string(&profile, Some("p@ss/word"), true);
    let parsed = connection_url::parse(&url).unwrap();

    assert_eq!(parsed.profile.host, profile.host);
    assert_eq!(parsed.profile.port, profile.port);
    assert_eq!(parsed.profile.username, profile.username);
    assert_eq!(parsed.profile.database, profile.database);
    assert_eq!(parsed.profile.ssl_mode, SslMode::Require);
    assert_eq!(parsed.password.as_deref(), Some("p@ss/word"));
}

#[test]
fn leaves_the_password_out_unless_asked() {
    let mut profile = miesql_lib::models::ConnectionProfile::new(DatabaseKind::Mysql);
    profile.host = "localhost".into();
    profile.username = "root".into();
    profile.database = "shop".into();

    let url = connection_url::to_string(&profile, Some("hunter2"), false);
    assert_eq!(url, "mysql://root@localhost/shop");
    assert!(!url.contains("hunter2"));
}

#[test]
fn serialises_sqlite_as_a_file_url() {
    let mut profile = miesql_lib::models::ConnectionProfile::new(DatabaseKind::Sqlite);
    profile.file_path = "/Users/ada/app.sqlite".into();
    let url = connection_url::to_string(&profile, None, false);
    assert_eq!(url, "sqlite:///Users/ada/app.sqlite");
    assert_eq!(
        connection_url::parse(&url).unwrap().profile.file_path,
        profile.file_path
    );
}
