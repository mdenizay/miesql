//! MySQL and MariaDB. They share a wire protocol, so one driver serves both.
//!
//! Queries go through the text protocol, which means the server renders every value as
//! text and the column metadata arrives with the result set whether or not any rows do.
//! That gives the same two properties the PostgreSQL driver has: no per-type decoding to
//! keep correct, and column headers for a query that returns nothing.

use super::{Credentials, Driver};
use crate::error::{DbError, DbResult};
use crate::models::*;
use crate::sql::{dialect, dialect::Dialect, splitter};
use async_trait::async_trait;
use mysql_async::prelude::Queryable;
use mysql_async::{Conn, OptsBuilder, SslOpts, Value};

pub struct MySqlDriver {
    credentials: Credentials,
    conn: Option<Conn>,
    active_database: String,
    kind: DatabaseKind,
}

impl MySqlDriver {
    pub fn new(credentials: Credentials) -> Self {
        let kind = credentials.profile.kind;
        let active_database = credentials.profile.database.clone();
        Self {
            credentials,
            conn: None,
            active_database,
            kind,
        }
    }

    fn conn_mut(&mut self) -> DbResult<&mut Conn> {
        self.conn.as_mut().ok_or_else(DbError::not_connected)
    }

    fn guard_read_only(&self, sql: &str) -> DbResult<()> {
        if !self.credentials.profile.read_only {
            return Ok(());
        }
        let keyword = dialect::leading_keyword(sql);
        // USE only changes the session, so it stays allowed on a read-only connection.
        if keyword == "use" || dialect::is_read_only_statement(sql) {
            return Ok(());
        }
        Err(DbError::read_only(&keyword))
    }

    async fn run_single(&mut self, sql: &str) -> DbResult<QueryResult> {
        let started = std::time::Instant::now();
        let conn = self.conn_mut()?;

        let mut result = conn.query_iter(sql).await.map_err(map_error)?;

        // Taken before the rows are consumed: this is what carries the column names when
        // the result set turns out to be empty.
        let columns: Vec<ColumnInfo> = result
            .columns_ref()
            .iter()
            .enumerate()
            .map(|(index, column)| {
                let table = column.table_str().to_string();
                ColumnInfo {
                    index,
                    name: column.name_str().to_string(),
                    type_name: format!("{:?}", column.column_type()).replace("MYSQL_TYPE_", ""),
                    table_name: (!table.is_empty()).then_some(table),
                }
            })
            .collect();

        let mut rows = Vec::new();
        while let Some(row) = result.next().await.map_err(map_error)? {
            let values = (0..columns.len().max(row.len()))
                .map(|index| {
                    row.as_ref(index)
                        .map(render_value)
                        .unwrap_or(SqlValue::Null)
                })
                .collect();
            rows.push(ResultRow {
                id: rows.len(),
                values,
            });
        }

        let affected = result.affected_rows();
        drop(result);

        let is_read = dialect::is_read_only_statement(sql);
        Ok(QueryResult {
            statement: sql.to_string(),
            columns: columns.clone(),
            rows,
            // For a SELECT the count just repeats the rows returned, which would be
            // misleading shown as "rows affected".
            rows_affected: (columns.is_empty() && !is_read).then_some(affected),
            duration_ms: started.elapsed().as_secs_f64() * 1000.0,
            messages: Vec::new(),
        })
    }

    async fn scalar(&mut self, sql: &str) -> DbResult<Option<String>> {
        let result = self.run_single(sql).await?;
        Ok(result
            .rows
            .first()
            .and_then(|row| row.values.first())
            .filter(|value| !value.is_null())
            .map(|value| value.as_str().to_string()))
    }

    fn first_column(result: &QueryResult) -> Vec<String> {
        result
            .rows
            .iter()
            .filter_map(|row| row.values.first().map(|v| v.as_str().to_string()))
            .collect()
    }
}

#[async_trait]
impl Driver for MySqlDriver {
    fn kind(&self) -> DatabaseKind {
        self.kind
    }

    fn is_connected(&self) -> bool {
        self.conn.is_some()
    }

    async fn connect(&mut self) -> DbResult<ServerInfo> {
        let profile = &self.credentials.profile;

        let mut builder = OptsBuilder::default()
            .ip_or_hostname(profile.host.clone())
            .tcp_port(profile.port)
            .user(Some(profile.username.clone()))
            .pass(self.credentials.password.clone());
        if !profile.database.is_empty() {
            builder = builder.db_name(Some(profile.database.clone()));
        }
        if profile.ssl_mode != SslMode::Disable {
            // Encrypt without validating the certificate, matching what ssl-mode=REQUIRED
            // means to the MySQL clients. Validation is a separate mode MieSQL does not
            // implement yet and reports as downgraded rather than pretending to honour.
            builder = builder.ssl_opts(Some(
                SslOpts::default()
                    .with_danger_accept_invalid_certs(true)
                    .with_danger_skip_domain_validation(true),
            ));
        }

        // OptsBuilder has no connect timeout, so the whole attempt is bounded here. That
        // also covers the TLS handshake, which is where an unreachable host usually stalls.
        let timeout = std::time::Duration::from_secs(profile.connect_timeout_seconds.max(1));
        let conn = tokio::time::timeout(timeout, Conn::new(builder))
            .await
            .map_err(|_| {
                DbError::new(format!(
                    "Could not reach {}:{} within {} seconds.",
                    profile.host, profile.port, profile.connect_timeout_seconds
                ))
            })?
            .map_err(map_error)?;
        self.conn = Some(conn);

        let version = self
            .scalar("SELECT VERSION()")
            .await?
            .unwrap_or_else(|| "unknown".into());
        let current_database = self.scalar("SELECT DATABASE()").await?.unwrap_or_default();
        let current_user = self
            .scalar("SELECT CURRENT_USER()")
            .await?
            .unwrap_or_else(|| self.credentials.profile.username.clone());
        self.active_database = current_database.clone();

        Ok(ServerInfo {
            // MariaDB reports itself inside the version string; the sidebar should say
            // which one the user is actually talking to.
            product_name: if version.to_lowercase().contains("mariadb") {
                "MariaDB".into()
            } else {
                "MySQL".into()
            },
            version,
            current_database,
            current_user,
        })
    }

    async fn disconnect(&mut self) {
        if let Some(conn) = self.conn.take() {
            let _ = conn.disconnect().await;
        }
    }

    async fn use_database(&mut self, database: &str) -> DbResult<()> {
        if database.is_empty() || database == self.active_database {
            return Ok(());
        }
        let quoted = Dialect::new(self.kind).quote(database);
        self.run_single(&format!("USE {quoted}")).await?;
        self.active_database = database.to_string();
        Ok(())
    }

    async fn execute(&mut self, sql: &str) -> DbResult<Vec<QueryResult>> {
        let statements = splitter::split(sql, self.kind);
        let mut results = Vec::with_capacity(statements.len());
        for statement in statements {
            self.guard_read_only(&statement.text)?;
            results.push(self.run_single(&statement.text).await?);
            // Keep our idea of the active database in step with the user's own USE.
            if dialect::leading_keyword(&statement.text) == "use" {
                self.active_database = self.scalar("SELECT DATABASE()").await?.unwrap_or_default();
            }
        }
        Ok(results)
    }

    async fn list_databases(&mut self) -> DbResult<Vec<String>> {
        let result = self
            .run_single(
                "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA \
                 WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') \
                 ORDER BY SCHEMA_NAME",
            )
            .await?;
        Ok(Self::first_column(&result))
    }

    /// MySQL has no level between database and table.
    async fn list_schemas(&mut self, _database: &str) -> DbResult<Vec<String>> {
        Ok(Vec::new())
    }

    async fn list_tables(&mut self, database: &str, _schema: &str) -> DbResult<Vec<TableRef>> {
        let literal = Dialect::new(self.kind).string_literal(database);
        let result = self
            .run_single(&format!(
                "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES \
                 WHERE TABLE_SCHEMA = {literal} ORDER BY TABLE_NAME"
            ))
            .await?;

        Ok(result
            .rows
            .iter()
            .filter_map(|row| {
                let name = row.values.first()?.as_str().to_string();
                let is_view = row
                    .values
                    .get(1)
                    .map(|v| v.as_str().to_uppercase().contains("VIEW"))
                    .unwrap_or(false);
                Some(TableRef {
                    database: database.to_string(),
                    schema: String::new(),
                    name,
                    kind: if is_view {
                        TableKind::View
                    } else {
                        TableKind::Table
                    },
                })
            })
            .collect())
    }

    async fn describe(&mut self, table: &TableRef) -> DbResult<TableDetails> {
        let dialect = Dialect::new(self.kind);
        let db = dialect.string_literal(&table.database);
        let name = dialect.string_literal(&table.name);

        let column_rows = self
            .run_single(&format!(
                "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, \
                        EXTRA, COLUMN_COMMENT, ORDINAL_POSITION \
                 FROM information_schema.COLUMNS \
                 WHERE TABLE_SCHEMA = {db} AND TABLE_NAME = {name} ORDER BY ORDINAL_POSITION"
            ))
            .await?;

        let columns: Vec<ColumnDefinition> = column_rows
            .rows
            .iter()
            .map(|row| {
                let get = |i: usize| row.values.get(i).cloned().unwrap_or(SqlValue::Null);
                let text = |i: usize| get(i).as_str().to_string();
                ColumnDefinition {
                    name: text(0),
                    data_type: text(1),
                    is_nullable: text(2).eq_ignore_ascii_case("YES"),
                    default_value: match get(3) {
                        SqlValue::Null => None,
                        SqlValue::Text(v) => Some(v),
                    },
                    is_primary_key: text(4).eq_ignore_ascii_case("PRI"),
                    is_auto_increment: text(5).to_lowercase().contains("auto_increment"),
                    comment: Some(text(6)).filter(|c| !c.is_empty()),
                    ordinal_position: text(7).parse().unwrap_or(0),
                }
            })
            .collect();

        // information_schema returns one row per indexed column, so they are folded back
        // into one entry per index, keeping the order the server reported.
        let index_rows = self
            .run_single(&format!(
                "SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, INDEX_TYPE \
                 FROM information_schema.STATISTICS \
                 WHERE TABLE_SCHEMA = {db} AND TABLE_NAME = {name} \
                 ORDER BY INDEX_NAME, SEQ_IN_INDEX"
            ))
            .await?;

        let mut indexes: Vec<IndexDefinition> = Vec::new();
        for row in &index_rows.rows {
            let text = |i: usize| {
                row.values
                    .get(i)
                    .map(|v| v.as_str().to_string())
                    .unwrap_or_default()
            };
            let index_name = text(0);
            match indexes.iter_mut().find(|i| i.name == index_name) {
                Some(existing) => existing.columns.push(text(2)),
                None => indexes.push(IndexDefinition {
                    is_unique: text(1) == "0",
                    is_primary: index_name == "PRIMARY",
                    method: Some(text(3)),
                    columns: vec![text(2)],
                    name: index_name,
                }),
            }
        }

        let fk_rows = self
            .run_single(&format!(
                "SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, \
                        k.REFERENCED_COLUMN_NAME, r.DELETE_RULE, r.UPDATE_RULE \
                 FROM information_schema.KEY_COLUMN_USAGE k \
                 JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
                   ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA \
                  AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME \
                 WHERE k.TABLE_SCHEMA = {db} AND k.TABLE_NAME = {name} \
                   AND k.REFERENCED_TABLE_NAME IS NOT NULL \
                 ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION"
            ))
            .await?;

        let mut foreign_keys: Vec<ForeignKeyDefinition> = Vec::new();
        for row in &fk_rows.rows {
            let text = |i: usize| {
                row.values
                    .get(i)
                    .map(|v| v.as_str().to_string())
                    .unwrap_or_default()
            };
            let key_name = text(0);
            match foreign_keys.iter_mut().find(|k| k.name == key_name) {
                Some(existing) => {
                    existing.columns.push(text(1));
                    existing.referenced_columns.push(text(3));
                }
                None => foreign_keys.push(ForeignKeyDefinition {
                    columns: vec![text(1)],
                    referenced_table: text(2),
                    referenced_columns: vec![text(3)],
                    on_delete: Some(text(4)),
                    on_update: Some(text(5)),
                    name: key_name,
                }),
            }
        }

        let stats = self
            .run_single(&format!(
                "SELECT TABLE_ROWS, TABLE_COMMENT FROM information_schema.TABLES \
                 WHERE TABLE_SCHEMA = {db} AND TABLE_NAME = {name}"
            ))
            .await
            .ok();
        let first = stats.as_ref().and_then(|s| s.rows.first());

        Ok(TableDetails {
            table: table.clone(),
            columns,
            indexes,
            foreign_keys,
            estimated_row_count: first
                .and_then(|r| r.values.first())
                .and_then(|v| v.as_str().parse::<i64>().ok()),
            comment: first
                .and_then(|r| r.values.get(1))
                .map(|v| v.as_str().to_string())
                .filter(|c| !c.is_empty()),
        })
    }

    async fn create_statement(&mut self, table: &TableRef) -> DbResult<String> {
        let dialect = Dialect::new(self.kind);
        let qualified = dialect.quote_qualified(&[&table.database, &table.name]);
        let keyword = if table.kind == TableKind::View {
            "VIEW"
        } else {
            "TABLE"
        };
        let result = self
            .run_single(&format!("SHOW CREATE {keyword} {qualified}"))
            .await?;

        // SHOW CREATE returns (name, statement); the statement is the second column.
        result
            .rows
            .first()
            .and_then(|row| row.values.get(1))
            .map(|v| {
                let sql = v.as_str();
                if sql.ends_with(';') {
                    sql.to_string()
                } else {
                    format!("{sql};")
                }
            })
            .ok_or_else(|| {
                DbError::new(format!(
                    "The server did not return a CREATE statement for {}.",
                    table.name
                ))
            })
    }
}

/// Over the text protocol nearly everything arrives as bytes; the rest is rendered the way
/// the server would print it.
fn render_value(value: &Value) -> SqlValue {
    match value {
        Value::NULL => SqlValue::Null,
        Value::Bytes(bytes) => SqlValue::Text(String::from_utf8_lossy(bytes).to_string()),
        Value::Int(v) => SqlValue::text(v.to_string()),
        Value::UInt(v) => SqlValue::text(v.to_string()),
        Value::Float(v) => SqlValue::text(format_float(*v as f64)),
        Value::Double(v) => SqlValue::text(format_float(*v)),
        Value::Date(year, month, day, hour, minute, second, micros) => {
            let date = format!("{year:04}-{month:02}-{day:02}");
            if *hour == 0 && *minute == 0 && *second == 0 && *micros == 0 {
                SqlValue::text(date)
            } else if *micros == 0 {
                SqlValue::text(format!("{date} {hour:02}:{minute:02}:{second:02}"))
            } else {
                SqlValue::text(format!(
                    "{date} {hour:02}:{minute:02}:{second:02}.{micros:06}"
                ))
            }
        }
        Value::Time(negative, days, hours, minutes, seconds, micros) => {
            let sign = if *negative { "-" } else { "" };
            let total_hours = *days * 24 + *hours as u32;
            if *micros == 0 {
                SqlValue::text(format!("{sign}{total_hours:02}:{minutes:02}:{seconds:02}"))
            } else {
                SqlValue::text(format!(
                    "{sign}{total_hours:02}:{minutes:02}:{seconds:02}.{micros:06}"
                ))
            }
        }
    }
}

/// Whole floats print without a trailing `.0`, so a dump round-trips unchanged.
fn format_float(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        value.to_string()
    }
}

fn map_error(error: mysql_async::Error) -> DbError {
    if let mysql_async::Error::Server(server) = &error {
        return DbError::with_code(server.message.clone(), server.state.clone());
    }
    let text = error.to_string();
    // MySQL 8 defaults to caching_sha2_password, which cannot complete over a plaintext
    // socket. That is a setting to change, not a mystery to debug.
    if text.contains("caching_sha2_password") || text.contains("Authentication plugin") {
        return DbError::new(
            "This account uses an authentication plugin that needs an encrypted connection.",
        )
        .with_detail(format!(
            "Set SSL to Prefer or Require in the connection settings.\n{text}"
        ));
    }
    DbError::new(text)
}
