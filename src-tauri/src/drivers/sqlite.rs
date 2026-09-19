//! SQLite talks to the bundled C library directly — there is no server, so there is
//! nothing to pool or reconnect. The library is synchronous, so the blocking calls run
//! inside `block_in_place`, which hands the work to a blocking thread instead of stalling
//! the async runtime while a large query runs.

use super::{CancelSlot, Canceller, Credentials, Driver};
use crate::error::{DbError, DbResult};
use crate::models::*;
use crate::sql::{dialect, dialect::Dialect, splitter};
use async_trait::async_trait;
use rusqlite::{Connection, InterruptHandle, OpenFlags};
use std::sync::Arc;

pub const MAIN_DATABASE: &str = "main";

pub struct SqliteDriver {
    credentials: Credentials,
    connection: Option<Connection>,
    cancel: CancelSlot,
}

/// SQLite runs in this process, so there is no second connection to send anything over:
/// the interrupt handle sets a flag the running statement checks, and the call returns
/// straight away rather than waiting for the statement to notice.
struct SqliteCanceller {
    handle: InterruptHandle,
}

#[async_trait]
impl Canceller for SqliteCanceller {
    async fn cancel(&self) -> DbResult<()> {
        self.handle.interrupt();
        Ok(())
    }
}

impl SqliteDriver {
    pub fn new(credentials: Credentials) -> Self {
        Self {
            credentials,
            connection: None,
            cancel: CancelSlot::default(),
        }
    }

    fn conn(&self) -> DbResult<&Connection> {
        self.connection.as_ref().ok_or_else(DbError::not_connected)
    }

    fn guard_read_only(&self, sql: &str) -> DbResult<()> {
        if self.credentials.profile.read_only && !dialect::is_read_only_statement(sql) {
            return Err(DbError::read_only(&dialect::leading_keyword(sql)));
        }
        Ok(())
    }

    /// Runs one statement. Column metadata comes from the prepared statement, so a query
    /// that returns no rows still reports its columns.
    fn run_single(&self, sql: &str) -> DbResult<QueryResult> {
        let connection = self.conn()?;
        let started = std::time::Instant::now();

        let mut statement = connection.prepare(sql).map_err(map_error)?;
        let column_count = statement.column_count();

        let mut columns: Vec<ColumnInfo> = (0..column_count)
            .map(|index| {
                let name = statement.column_name(index).unwrap_or("?").to_string();
                let declared = statement
                    .columns()
                    .get(index)
                    .and_then(|c| c.decl_type())
                    .unwrap_or("")
                    .to_string();
                ColumnInfo::new(index, name, declared)
            })
            .collect();

        let mut rows = Vec::new();
        if column_count > 0 {
            let mut cursor = statement.raw_query();
            let mut row_index = 0usize;
            while let Some(row) = cursor.next().map_err(map_error)? {
                let values = (0..column_count)
                    .map(|index| value_at(row, index))
                    .collect::<DbResult<Vec<_>>>()?;
                rows.push(ResultRow {
                    id: row_index,
                    values,
                });
                row_index += 1;
            }
        } else {
            statement.raw_execute().map_err(map_error)?;
        }

        // `decl_type` is empty for expressions, so fall back to the runtime type of the
        // first row, which is what the grid needs for alignment.
        if let Some(first) = rows.first() {
            for column in columns.iter_mut() {
                if column.type_name.is_empty() {
                    column.type_name = runtime_type_name(&first.values[column.index]);
                }
            }
        }

        let is_read = dialect::is_read_only_statement(sql);
        Ok(QueryResult {
            statement: sql.to_string(),
            columns: if column_count > 0 {
                columns
            } else {
                Vec::new()
            },
            rows,
            rows_affected: if column_count == 0 && !is_read {
                Some(connection.changes())
            } else {
                None
            },
            duration_ms: started.elapsed().as_secs_f64() * 1000.0,
            messages: Vec::new(),
        })
    }

    fn scalar(&self, sql: &str) -> DbResult<Option<String>> {
        let result = self.run_single(sql)?;
        Ok(result
            .rows
            .first()
            .and_then(|row| row.values.first())
            .filter(|value| !value.is_null())
            .map(|value| value.as_str().to_string()))
    }
}

#[async_trait]
impl Driver for SqliteDriver {
    fn kind(&self) -> DatabaseKind {
        DatabaseKind::Sqlite
    }

    fn is_connected(&self) -> bool {
        self.connection.is_some()
    }

    fn cancel_slot(&self) -> CancelSlot {
        self.cancel.clone()
    }

    async fn connect(&mut self) -> DbResult<ServerInfo> {
        let path = self.credentials.profile.file_path.clone();
        if path.is_empty() {
            return Err(DbError::new("No database file was selected."));
        }

        let flags = if self.credentials.profile.read_only {
            OpenFlags::SQLITE_OPEN_READ_ONLY
        } else {
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE
        } | OpenFlags::SQLITE_OPEN_FULL_MUTEX;

        let connection = Connection::open_with_flags(&path, flags).map_err(map_error)?;
        self.cancel.set(Arc::new(SqliteCanceller {
            handle: connection.get_interrupt_handle(),
        }));
        self.connection = Some(connection);

        // Foreign keys are off by default; a database client should honour the schema's
        // declared constraints rather than silently letting the user break them.
        let _ = self.run_single("PRAGMA foreign_keys = ON");

        let version = self
            .scalar("SELECT sqlite_version()")?
            .unwrap_or_else(|| "unknown".into());
        Ok(ServerInfo {
            product_name: "SQLite".into(),
            version,
            current_database: std::path::Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            current_user: whoami_fallback(),
        })
    }

    async fn disconnect(&mut self) {
        self.cancel.clear();
        self.connection = None;
    }

    /// Nothing to switch: a SQLite connection is a file.
    async fn use_database(&mut self, _database: &str) -> DbResult<()> {
        Ok(())
    }

    async fn execute(&mut self, sql: &str) -> DbResult<Vec<QueryResult>> {
        let statements = splitter::split(sql, DatabaseKind::Sqlite);
        tokio::task::block_in_place(|| {
            statements
                .iter()
                .map(|statement| {
                    self.guard_read_only(&statement.text)?;
                    self.run_single(&statement.text)
                })
                .collect()
        })
    }

    async fn list_databases(&mut self) -> DbResult<Vec<String>> {
        tokio::task::block_in_place(|| {
            // `PRAGMA database_list` also reports anything the user has ATTACHed.
            let result = self.run_single("PRAGMA database_list")?;
            let names: Vec<String> = result
                .rows
                .iter()
                .filter_map(|row| row.values.get(1).map(|v| v.as_str().to_string()))
                .collect();
            Ok(if names.is_empty() {
                vec![MAIN_DATABASE.to_string()]
            } else {
                names
            })
        })
    }

    async fn list_schemas(&mut self, _database: &str) -> DbResult<Vec<String>> {
        Ok(Vec::new())
    }

    async fn list_tables(&mut self, database: &str, _schema: &str) -> DbResult<Vec<TableRef>> {
        let dialect = Dialect::new(DatabaseKind::Sqlite);
        let prefix = if database.is_empty() {
            MAIN_DATABASE
        } else {
            database
        };
        let sql = format!(
            "SELECT name, type FROM {}.sqlite_master \
             WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
            dialect.quote(prefix)
        );

        tokio::task::block_in_place(|| {
            let result = self.run_single(&sql)?;
            Ok(result
                .rows
                .iter()
                .filter_map(|row| {
                    let name = row.values.first()?.as_str().to_string();
                    let kind = match row.values.get(1).map(|v| v.as_str()) {
                        Some("view") => TableKind::View,
                        _ => TableKind::Table,
                    };
                    Some(TableRef {
                        database: prefix.to_string(),
                        schema: String::new(),
                        name,
                        kind,
                    })
                })
                .collect())
        })
    }

    async fn describe(&mut self, table: &TableRef) -> DbResult<TableDetails> {
        let dialect = Dialect::new(DatabaseKind::Sqlite);
        let quoted = dialect.quote(&table.name);

        tokio::task::block_in_place(|| {
            let column_rows = self.run_single(&format!("PRAGMA table_info({quoted})"))?;
            let columns: Vec<ColumnDefinition> = column_rows
                .rows
                .iter()
                .map(|row| {
                    // cid, name, type, notnull, dflt_value, pk
                    let get = |i: usize| row.values.get(i).cloned().unwrap_or(SqlValue::Null);
                    ColumnDefinition {
                        name: get(1).as_str().to_string(),
                        data_type: get(2).as_str().to_string(),
                        is_nullable: get(3).as_str() != "1",
                        default_value: match get(4) {
                            SqlValue::Null => None,
                            SqlValue::Text(v) => Some(v),
                        },
                        is_primary_key: get(5).as_str() != "0",
                        is_auto_increment: false,
                        comment: None,
                        ordinal_position: get(0).as_str().parse::<i64>().unwrap_or(0) + 1,
                    }
                })
                .collect();

            let index_list = self.run_single(&format!("PRAGMA index_list({quoted})"))?;
            let mut indexes = Vec::new();
            for row in &index_list.rows {
                // seq, name, unique, origin, partial
                let get = |i: usize| {
                    row.values
                        .get(i)
                        .map(|v| v.as_str().to_string())
                        .unwrap_or_default()
                };
                let name = get(1);
                let info =
                    self.run_single(&format!("PRAGMA index_info({})", dialect.quote(&name)))?;
                indexes.push(IndexDefinition {
                    columns: info
                        .rows
                        .iter()
                        .filter_map(|r| r.values.get(2).map(|v| v.as_str().to_string()))
                        .collect(),
                    is_unique: get(2) == "1",
                    is_primary: get(3) == "pk",
                    name,
                    method: None,
                });
            }

            let fk_rows = self.run_single(&format!("PRAGMA foreign_key_list({quoted})"))?;
            let mut keys: Vec<ForeignKeyDefinition> = Vec::new();
            for row in &fk_rows.rows {
                // id, seq, table, from, to, on_update, on_delete, match
                let get = |i: usize| {
                    row.values
                        .get(i)
                        .map(|v| v.as_str().to_string())
                        .unwrap_or_default()
                };
                let name = format!("fk_{}_{}", table.name, get(0));
                match keys.iter_mut().find(|k| k.name == name) {
                    Some(existing) => {
                        existing.columns.push(get(3));
                        existing.referenced_columns.push(get(4));
                    }
                    None => keys.push(ForeignKeyDefinition {
                        name,
                        columns: vec![get(3)],
                        referenced_table: get(2),
                        referenced_columns: vec![get(4)],
                        on_delete: Some(get(6)),
                        on_update: Some(get(5)),
                    }),
                }
            }

            let row_count = self
                .run_single(&format!("SELECT COUNT(*) FROM {quoted}"))
                .ok()
                .and_then(|r| r.rows.first().and_then(|row| row.values.first().cloned()))
                .and_then(|v| v.as_str().parse::<i64>().ok());

            Ok(TableDetails {
                table: table.clone(),
                columns,
                indexes,
                foreign_keys: keys,
                estimated_row_count: row_count,
                comment: None,
            })
        })
    }

    async fn schema_columns(
        &mut self,
        _database: &str,
        _schema: &str,
    ) -> DbResult<std::collections::BTreeMap<String, Vec<String>>> {
        // `pragma_table_info` as a table-valued function is what keeps this to one query
        // instead of one PRAGMA per table.
        let rows = tokio::task::block_in_place(|| {
            self.run_single(
                "SELECT m.name, p.name FROM sqlite_master m \
                 JOIN pragma_table_info(m.name) p \
                 WHERE m.type IN ('table', 'view') ORDER BY m.name, p.cid",
            )
        })?;
        Ok(super::group_columns(&rows))
    }

    async fn create_statement(&mut self, table: &TableRef) -> DbResult<String> {
        let dialect = Dialect::new(DatabaseKind::Sqlite);
        let name_literal = dialect.string_literal(&table.name);

        tokio::task::block_in_place(|| {
            let result = self.run_single(&format!(
                "SELECT sql FROM sqlite_master WHERE name = {name_literal}"
            ))?;
            let sql = result
                .rows
                .first()
                .and_then(|row| row.values.first())
                .map(|v| v.as_str().to_string())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    DbError::new(format!("No CREATE statement is stored for {}.", table.name))
                })?;

            let mut output = if sql.ends_with(';') {
                sql
            } else {
                format!("{sql};")
            };

            let indexes = self.run_single(&format!(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = {name_literal} \
                 AND sql IS NOT NULL ORDER BY name"
            ))?;
            for row in &indexes.rows {
                let index_sql = row.values.first().map(|v| v.as_str()).unwrap_or("");
                if !index_sql.is_empty() {
                    output.push_str("\n\n");
                    output.push_str(index_sql);
                    if !index_sql.ends_with(';') {
                        output.push(';');
                    }
                }
            }
            Ok(output)
        })
    }
}

fn value_at(row: &rusqlite::Row<'_>, index: usize) -> DbResult<SqlValue> {
    use rusqlite::types::ValueRef;
    let raw = row.get_ref(index).map_err(map_error)?;
    Ok(match raw {
        ValueRef::Null => SqlValue::Null,
        ValueRef::Integer(v) => SqlValue::text(v.to_string()),
        ValueRef::Real(v) => SqlValue::text(format_real(v)),
        ValueRef::Text(bytes) => SqlValue::text(String::from_utf8_lossy(bytes).to_string()),
        // Blobs are shown, and exported, as the hex literal the engine itself accepts.
        ValueRef::Blob(bytes) => SqlValue::text(format!(
            "X'{}'",
            bytes.iter().map(|b| format!("{b:02X}")).collect::<String>()
        )),
    })
}

/// Renders a float the way the server would: no trailing `.0` on whole numbers.
fn format_real(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        value.to_string()
    }
}

fn runtime_type_name(value: &SqlValue) -> String {
    match value {
        SqlValue::Null => String::new(),
        SqlValue::Text(s) => {
            if s.starts_with("X'") {
                "BLOB".into()
            } else if s.parse::<i64>().is_ok() {
                "INTEGER".into()
            } else if s.parse::<f64>().is_ok() {
                "REAL".into()
            } else {
                "TEXT".into()
            }
        }
    }
}

fn whoami_fallback() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "local".into())
}

fn map_error(error: rusqlite::Error) -> DbError {
    match &error {
        rusqlite::Error::SqliteFailure(failure, message) => DbError::with_code(
            message.clone().unwrap_or_else(|| error.to_string()),
            format!("SQLITE_{}", failure.extended_code),
        ),
        _ => DbError::new(error.to_string()),
    }
}
