//! Redis.
//!
//! Redis is not relational, so the mapping onto the shared `Driver` trait is a deliberate
//! choice rather than a natural fit:
//!
//! - a **database** is a numbered Redis database, and only the ones holding keys are listed
//! - a **table** is a key namespace — the part before the first `:`, which is how nearly
//!   every Redis codebase organises its keyspace
//! - **rows** are the keys in that namespace, with their type, TTL and a value preview
//! - **execute** runs a raw Redis command
//!
//! Every listing goes through SCAN rather than KEYS, because KEYS blocks the server for
//! the length of the keyspace and this is a tool people will point at production.

use super::{Credentials, Driver};
use crate::error::{DbError, DbResult};
use crate::models::*;
use async_trait::async_trait;
use redis::{aio::MultiplexedConnection, AsyncCommands, Value};

/// How many keys to sample when working out which namespaces exist. Enough to be
/// representative, small enough not to sweep a large keyspace on every expansion.
const NAMESPACE_SAMPLE: usize = 2_000;
const SCAN_BATCH: usize = 500;

pub struct RedisDriver {
    credentials: Credentials,
    conn: Option<MultiplexedConnection>,
    active_database: i64,
}

impl RedisDriver {
    pub fn new(credentials: Credentials) -> Self {
        Self {
            credentials,
            conn: None,
            active_database: 0,
        }
    }

    fn conn_mut(&mut self) -> DbResult<&mut MultiplexedConnection> {
        self.conn.as_mut().ok_or_else(DbError::not_connected)
    }

    /// Redis has no notion of a read-only client, so the guard is enforced here by command
    /// name — the same promise the SQL drivers make.
    fn guard_read_only(&self, command: &str) -> DbResult<()> {
        if !self.credentials.profile.read_only {
            return Ok(());
        }
        const READS: &[&str] = &[
            "GET",
            "MGET",
            "STRLEN",
            "EXISTS",
            "TTL",
            "PTTL",
            "TYPE",
            "KEYS",
            "SCAN",
            "RANDOMKEY",
            "HGET",
            "HGETALL",
            "HKEYS",
            "HVALS",
            "HLEN",
            "HMGET",
            "HEXISTS",
            "HSCAN",
            "LRANGE",
            "LLEN",
            "LINDEX",
            "SMEMBERS",
            "SCARD",
            "SISMEMBER",
            "SSCAN",
            "SRANDMEMBER",
            "ZRANGE",
            "ZREVRANGE",
            "ZRANGEBYSCORE",
            "ZCARD",
            "ZSCORE",
            "ZCOUNT",
            "ZSCAN",
            "XRANGE",
            "XLEN",
            "GETRANGE",
            "BITCOUNT",
            "PFCOUNT",
            "OBJECT",
            "MEMORY",
            "INFO",
            "DBSIZE",
            "PING",
            "TIME",
            "COMMAND",
            "CONFIG",
            "CLIENT",
            "LOLWUT",
            "SELECT",
        ];
        let name = command
            .split_whitespace()
            .next()
            .unwrap_or("")
            .to_uppercase();
        if READS.contains(&name.as_str()) {
            return Ok(());
        }
        Err(DbError::read_only(&name))
    }

    /// Splits a command line the way redis-cli does, honouring quotes so a value with a
    /// space in it survives.
    fn split_command(input: &str) -> Vec<String> {
        let mut parts = Vec::new();
        let mut current = String::new();
        let mut quote: Option<char> = None;
        let mut started = false;

        for ch in input.chars() {
            match quote {
                Some(q) if ch == q => quote = None,
                Some(_) => current.push(ch),
                None if ch == '"' || ch == '\'' => {
                    quote = Some(ch);
                    started = true;
                }
                None if ch.is_whitespace() => {
                    if started || !current.is_empty() {
                        parts.push(std::mem::take(&mut current));
                        started = false;
                    }
                }
                None => current.push(ch),
            }
        }
        if started || !current.is_empty() {
            parts.push(current);
        }
        parts
    }

    async fn run_command(&mut self, line: &str) -> DbResult<QueryResult> {
        let started = std::time::Instant::now();
        let parts = Self::split_command(line);
        if parts.is_empty() {
            return Ok(QueryResult::new(line));
        }

        let conn = self.conn_mut()?;
        let mut command = redis::cmd(&parts[0].to_uppercase());
        for argument in &parts[1..] {
            command.arg(argument);
        }
        let value: Value = command.query_async(conn).await.map_err(|e| map_error(&e))?;

        // SELECT changes which database later commands land in.
        if parts[0].eq_ignore_ascii_case("SELECT") {
            if let Some(index) = parts.get(1).and_then(|d| d.parse::<i64>().ok()) {
                self.active_database = index;
            }
        }

        let (columns, rows) = shape(value);
        Ok(QueryResult {
            statement: line.to_string(),
            columns,
            rows,
            rows_affected: None,
            duration_ms: started.elapsed().as_secs_f64() * 1000.0,
            messages: Vec::new(),
        })
    }

    /// Walks the keyspace with SCAN, which never blocks the server, unlike KEYS.
    async fn scan_keys(&mut self, pattern: &str, limit: usize) -> DbResult<Vec<String>> {
        let conn = self.conn_mut()?;
        let mut cursor: u64 = 0;
        let mut keys = Vec::new();

        loop {
            let (next, batch): (u64, Vec<String>) = redis::cmd("SCAN")
                .arg(cursor)
                .arg("MATCH")
                .arg(pattern)
                .arg("COUNT")
                .arg(SCAN_BATCH)
                .query_async(conn)
                .await
                .map_err(|e| map_error(&e))?;
            keys.extend(batch);
            cursor = next;
            if cursor == 0 || keys.len() >= limit {
                break;
            }
        }
        keys.truncate(limit);
        Ok(keys)
    }

    /// Opens a connection with a specific protocol version.
    async fn open(&mut self, protocol: redis::ProtocolVersion) -> DbResult<()> {
        let profile = &self.credentials.profile;
        let insecure = profile.ssl_mode != SslMode::Disable;

        let info = redis::ConnectionInfo {
            addr: if insecure {
                redis::ConnectionAddr::TcpTls {
                    host: profile.host.clone(),
                    port: profile.port,
                    // Matches the app's documented behaviour: encrypt, do not validate.
                    insecure: true,
                    tls_params: None,
                }
            } else {
                redis::ConnectionAddr::Tcp(profile.host.clone(), profile.port)
            },
            redis: redis::RedisConnectionInfo {
                db: profile.database.parse().unwrap_or(0),
                username: (!profile.username.is_empty()).then(|| profile.username.clone()),
                password: self.credentials.password.clone(),
                protocol,
            },
        };

        let client = redis::Client::open(info).map_err(|e| map_error(&e))?;
        let timeout = std::time::Duration::from_secs(profile.connect_timeout_seconds.max(1));
        let conn = tokio::time::timeout(timeout, client.get_multiplexed_async_connection())
            .await
            .map_err(|_| {
                DbError::new(format!(
                    "Could not reach {}:{} within {} seconds.",
                    profile.host, profile.port, profile.connect_timeout_seconds
                ))
            })?
            .map_err(|e| map_error(&e))?;

        self.conn = Some(conn);
        Ok(())
    }
}

#[async_trait]
impl Driver for RedisDriver {
    fn kind(&self) -> DatabaseKind {
        DatabaseKind::Redis
    }

    fn is_connected(&self) -> bool {
        self.conn.is_some()
    }

    async fn connect(&mut self) -> DbResult<ServerInfo> {
        // RESP3 first, because it returns typed replies: a hash comes back as a map rather
        // than a flat field, value, field, value array, which is what lets the grid show
        // two columns instead of one. Servers older than Redis 6 reject the handshake, so
        // the connection is retried on RESP2 rather than refused.
        let mut last_error = None;
        for protocol in [redis::ProtocolVersion::RESP3, redis::ProtocolVersion::RESP2] {
            match self.open(protocol).await {
                Ok(()) => {
                    last_error = None;
                    break;
                }
                Err(error) => last_error = Some(error),
            }
        }
        if let Some(error) = last_error {
            return Err(error);
        }

        self.active_database = self.credentials.profile.database.parse().unwrap_or(0);

        let server_info: String = redis::cmd("INFO")
            .arg("server")
            .query_async(self.conn_mut()?)
            .await
            .map_err(|e| map_error(&e))?;
        let version = server_info
            .lines()
            .find_map(|line| line.strip_prefix("redis_version:"))
            .unwrap_or("unknown")
            .trim()
            .to_string();

        Ok(ServerInfo {
            product_name: "Redis".into(),
            version,
            current_database: format!("db{}", self.active_database),
            current_user: self.credentials.profile.username.clone(),
        })
    }

    async fn disconnect(&mut self) {
        self.conn = None;
    }

    async fn use_database(&mut self, database: &str) -> DbResult<()> {
        let index: i64 = database.trim_start_matches("db").parse().unwrap_or(0);
        if index == self.active_database {
            return Ok(());
        }
        let conn = self.conn_mut()?;
        redis::cmd("SELECT")
            .arg(index)
            .query_async::<()>(conn)
            .await
            .map_err(|e| map_error(&e))?;
        self.active_database = index;
        Ok(())
    }

    async fn execute(&mut self, sql: &str) -> DbResult<Vec<QueryResult>> {
        let mut results = Vec::new();
        // One command per line, the way redis-cli reads a script.
        for line in sql.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            self.guard_read_only(trimmed)?;
            results.push(self.run_command(trimmed).await?);
        }
        Ok(results)
    }

    /// Only the databases that actually hold keys, so the tree is not sixteen empty nodes.
    async fn list_databases(&mut self) -> DbResult<Vec<String>> {
        let conn = self.conn_mut()?;
        let keyspace: String = redis::cmd("INFO")
            .arg("keyspace")
            .query_async(conn)
            .await
            .map_err(|e| map_error(&e))?;

        let mut databases: Vec<String> = keyspace
            .lines()
            .filter_map(|line| line.split(':').next())
            .filter(|name| name.starts_with("db"))
            .map(|name| name.to_string())
            .collect();

        // db0 is where an empty server puts everything, so it is always worth showing.
        if !databases.iter().any(|d| d == "db0") {
            databases.insert(0, "db0".into());
        }
        Ok(databases)
    }

    async fn list_schemas(&mut self, _database: &str) -> DbResult<Vec<String>> {
        Ok(Vec::new())
    }

    /// Key namespaces, derived from a sample of the keyspace.
    async fn list_tables(&mut self, database: &str, _schema: &str) -> DbResult<Vec<TableRef>> {
        self.use_database(database).await?;
        let keys = self.scan_keys("*", NAMESPACE_SAMPLE).await?;

        let mut namespaces: Vec<String> = Vec::new();
        for key in &keys {
            let namespace = match key.split_once(':') {
                Some((prefix, _)) => prefix.to_string(),
                // Keys with no separator are grouped under their own name, so they are
                // still reachable rather than vanishing from the tree.
                None => key.clone(),
            };
            if !namespaces.contains(&namespace) {
                namespaces.push(namespace);
            }
        }
        namespaces.sort();

        Ok(namespaces
            .into_iter()
            .map(|name| TableRef {
                database: database.to_string(),
                schema: String::new(),
                name,
                kind: TableKind::Collection,
            })
            .collect())
    }

    /// Redis keys have no schema, so this reports the shape the browser actually shows.
    async fn describe(&mut self, table: &TableRef) -> DbResult<TableDetails> {
        let count = self.count_rows(table, "").await.unwrap_or(0);
        let column = |name: &str, kind: &str| ColumnDefinition {
            name: name.into(),
            data_type: kind.into(),
            is_nullable: false,
            default_value: None,
            is_primary_key: name == "key",
            is_auto_increment: false,
            comment: None,
            ordinal_position: 0,
        };
        Ok(TableDetails {
            table: table.clone(),
            columns: vec![
                column("key", "string"),
                column("type", "string"),
                column("ttl", "seconds"),
                column("value", "preview"),
            ],
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            estimated_row_count: Some(count),
            comment: Some(format!("Keys matching {}:*", table.name)),
        })
    }

    async fn create_statement(&mut self, table: &TableRef) -> DbResult<String> {
        Ok(format!(
            "# Redis has no schema to describe.\n# Keys in this namespace:\nSCAN 0 MATCH {}:* COUNT 100",
            table.name
        ))
    }

    /// Keys in the namespace, with their type, TTL and a short preview of the value.
    async fn fetch_rows(
        &mut self,
        table: &TableRef,
        where_clause: &str,
        _order_by: &[(String, bool)],
        limit: u64,
        offset: u64,
    ) -> DbResult<QueryResult> {
        self.use_database(&table.database).await?;
        let started = std::time::Instant::now();

        // The filter box takes a glob, which is what SCAN understands.
        let pattern = if where_clause.trim().is_empty() {
            format!("{}:*", table.name)
        } else {
            format!("{}:{}", table.name, where_clause.trim())
        };

        let mut keys = self.scan_keys(&pattern, (offset + limit) as usize).await?;
        // SCAN has no cursor we can resume from a page boundary, so paging is done here.
        keys.sort();
        let page: Vec<String> = keys
            .into_iter()
            .skip(offset as usize)
            .take(limit as usize)
            .collect();

        let conn = self.conn_mut()?;
        let mut rows = Vec::new();
        for key in page {
            let key_type: String = redis::cmd("TYPE")
                .arg(&key)
                .query_async(conn)
                .await
                .map_err(|e| map_error(&e))?;
            let ttl: i64 = conn.ttl(&key).await.map_err(|e| map_error(&e))?;
            let preview = preview_value(conn, &key, &key_type).await;

            rows.push(ResultRow {
                id: rows.len(),
                values: vec![
                    SqlValue::text(key),
                    SqlValue::text(key_type),
                    // -1 means no expiry and -2 means gone; neither is a number of seconds.
                    match ttl {
                        -1 => SqlValue::Null,
                        other => SqlValue::text(other.to_string()),
                    },
                    preview,
                ],
            });
        }

        Ok(QueryResult {
            statement: format!("SCAN MATCH {pattern}"),
            columns: vec![
                ColumnInfo::new(0, "key", "string"),
                ColumnInfo::new(1, "type", "string"),
                ColumnInfo::new(2, "ttl", "int"),
                ColumnInfo::new(3, "value", "preview"),
            ],
            rows,
            rows_affected: None,
            duration_ms: started.elapsed().as_secs_f64() * 1000.0,
            messages: Vec::new(),
        })
    }

    async fn count_rows(&mut self, table: &TableRef, where_clause: &str) -> DbResult<i64> {
        self.use_database(&table.database).await?;
        let pattern = if where_clause.trim().is_empty() {
            format!("{}:*", table.name)
        } else {
            format!("{}:{}", table.name, where_clause.trim())
        };
        // Counted from a bounded sample; an exact count would mean sweeping the keyspace.
        Ok(self.scan_keys(&pattern, NAMESPACE_SAMPLE).await?.len() as i64)
    }
}

/// A short, readable stand-in for a value, whatever its type. Long values are clipped
/// because this is a list, not an inspector.
async fn preview_value(conn: &mut MultiplexedConnection, key: &str, key_type: &str) -> SqlValue {
    const LIMIT: usize = 120;
    let raw: redis::RedisResult<Value> = match key_type {
        "string" => {
            redis::cmd("GETRANGE")
                .arg(key)
                .arg(0)
                .arg(LIMIT as i64)
                .query_async(conn)
                .await
        }
        "list" => {
            redis::cmd("LRANGE")
                .arg(key)
                .arg(0)
                .arg(4)
                .query_async(conn)
                .await
        }
        "set" => {
            redis::cmd("SRANDMEMBER")
                .arg(key)
                .arg(5)
                .query_async(conn)
                .await
        }
        "zset" => {
            redis::cmd("ZRANGE")
                .arg(key)
                .arg(0)
                .arg(4)
                .query_async(conn)
                .await
        }
        "hash" => redis::cmd("HGETALL").arg(key).query_async(conn).await,
        "stream" => redis::cmd("XLEN").arg(key).query_async(conn).await,
        _ => return SqlValue::Null,
    };

    match raw {
        Ok(value) => {
            let text = render(&value);
            SqlValue::text(if text.chars().count() > LIMIT {
                format!("{}…", text.chars().take(LIMIT).collect::<String>())
            } else {
                text
            })
        }
        Err(_) => SqlValue::Null,
    }
}

/// Turns a reply into the grid's shape: a scalar becomes one row, a list becomes many, and
/// a map becomes two columns.
fn shape(value: Value) -> (Vec<ColumnInfo>, Vec<ResultRow>) {
    match value {
        Value::Map(pairs) => {
            let rows = pairs
                .into_iter()
                .enumerate()
                .map(|(index, (field, item))| ResultRow {
                    id: index,
                    values: vec![
                        SqlValue::text(render(&field)),
                        SqlValue::text(render(&item)),
                    ],
                })
                .collect();
            (
                vec![
                    ColumnInfo::new(0, "field", "string"),
                    ColumnInfo::new(1, "value", "string"),
                ],
                rows,
            )
        }
        Value::Array(items) | Value::Set(items) => {
            let rows = items
                .into_iter()
                .enumerate()
                .map(|(index, item)| ResultRow {
                    id: index,
                    values: vec![SqlValue::text(render(&item))],
                })
                .collect();
            (vec![ColumnInfo::new(0, "value", "string")], rows)
        }
        Value::Nil => (
            vec![ColumnInfo::new(0, "value", "string")],
            vec![ResultRow {
                id: 0,
                values: vec![SqlValue::Null],
            }],
        ),
        other => (
            vec![ColumnInfo::new(0, "value", "string")],
            vec![ResultRow {
                id: 0,
                values: vec![SqlValue::text(render(&other))],
            }],
        ),
    }
}

fn render(value: &Value) -> String {
    match value {
        Value::Nil => String::new(),
        Value::Int(v) => v.to_string(),
        Value::BulkString(bytes) => String::from_utf8_lossy(bytes).to_string(),
        Value::SimpleString(s) | Value::VerbatimString { text: s, .. } => s.clone(),
        Value::Okay => "OK".into(),
        Value::Double(v) => v.to_string(),
        Value::Boolean(v) => v.to_string(),
        Value::BigNumber(v) => v.to_string(),
        Value::Array(items) | Value::Set(items) | Value::Push { data: items, .. } => {
            items.iter().map(render).collect::<Vec<_>>().join(", ")
        }
        Value::Map(pairs) => pairs
            .iter()
            .map(|(k, v)| format!("{}={}", render(k), render(v)))
            .collect::<Vec<_>>()
            .join(", "),
        Value::Attribute { data, .. } => render(data),
        Value::ServerError(error) => format!("{error:?}"),
    }
}

fn map_error(error: &redis::RedisError) -> DbError {
    match error.code() {
        Some(code) => {
            DbError::with_code(error.detail().unwrap_or("").to_string(), code.to_string())
        }
        None => DbError::new(error.to_string()),
    }
}
