//! Writes a `.sql` file that can recreate the selected tables, and runs one back in.
//!
//! Output is streamed to disk in batches rather than assembled in memory, so dumping a
//! table larger than RAM works.

use crate::drivers::Driver;
use crate::error::{DbError, DbResult};
use crate::models::{ColumnInfo, DatabaseKind, SqlValue, TableKind, TableRef};
use crate::sql::{dialect::Dialect, splitter};
use serde::{Deserialize, Serialize};
use std::io::Write;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DumpOptions {
    #[serde(default = "yes")]
    pub include_schema: bool,
    #[serde(default = "yes")]
    pub include_data: bool,
    #[serde(default)]
    pub drop_if_exists: bool,
    /// Wraps the data in a transaction so a failed restore leaves nothing behind.
    #[serde(default = "yes")]
    pub wrap_in_transaction: bool,
    /// Rows per multi-row INSERT. 1 is slower to restore but far easier to diff.
    #[serde(default = "hundred")]
    pub rows_per_insert: usize,
    /// How many rows to hold in memory at once while reading.
    #[serde(default = "thousand")]
    pub fetch_batch_size: u64,
}

fn yes() -> bool {
    true
}
fn hundred() -> usize {
    100
}
fn thousand() -> u64 {
    1_000
}

impl Default for DumpOptions {
    fn default() -> Self {
        Self {
            include_schema: true,
            include_data: true,
            drop_if_exists: false,
            wrap_in_transaction: true,
            rows_per_insert: 100,
            fetch_batch_size: 1_000,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DumpProgress {
    pub current_table: String,
    pub table_index: usize,
    pub table_count: usize,
    pub rows_written: u64,
    pub bytes_written: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DumpSummary {
    pub tables: usize,
    pub rows: u64,
    pub bytes: u64,
    pub path: String,
}

pub async fn dump(
    driver: &mut Box<dyn Driver>,
    tables: &[TableRef],
    options: &DumpOptions,
    path: &str,
    mut progress: impl FnMut(DumpProgress),
) -> DbResult<DumpSummary> {
    let kind = driver.kind();
    let dialect = Dialect::new(kind);

    let file = std::fs::File::create(path)
        .map_err(|e| DbError::new(format!("Could not open {path} for writing: {e}")))?;
    let mut writer = std::io::BufWriter::new(file);
    let mut bytes: u64 = 0;

    macro_rules! write_str {
        ($text:expr) => {{
            let text: String = $text;
            writer
                .write_all(text.as_bytes())
                .map_err(|e| DbError::new(format!("Could not write to {path}: {e}")))?;
            bytes += text.len() as u64;
        }};
    }

    let now = chrono::Utc::now().to_rfc3339();
    write_str!(format!(
        "-- MieSQL dump\n-- Engine: {}\n-- Generated: {now}\n-- Tables: {}\n\n",
        kind.display_name(),
        tables.len()
    ));

    // Constraint checks are relaxed for the whole restore, so table order cannot matter.
    write_str!(match kind {
        DatabaseKind::Mysql | DatabaseKind::Mariadb =>
            "SET FOREIGN_KEY_CHECKS = 0;\n\n".to_string(),
        DatabaseKind::Sqlite => "PRAGMA foreign_keys = OFF;\n\n".to_string(),
        _ => "SET session_replication_role = 'replica';\n\n".to_string(),
    });

    if options.wrap_in_transaction {
        write_str!("BEGIN;\n\n".to_string());
    }

    let mut total_rows: u64 = 0;
    for (index, table) in tables.iter().enumerate() {
        progress(DumpProgress {
            current_table: table.qualified_name(),
            table_index: index,
            table_count: tables.len(),
            rows_written: total_rows,
            bytes_written: bytes,
        });

        write_str!(format!(
            "-- ----------------------------\n-- {}\n-- ----------------------------\n",
            table.qualified_name()
        ));

        if options.include_schema {
            if options.drop_if_exists {
                let keyword = if table.kind == TableKind::Table {
                    "TABLE"
                } else {
                    "VIEW"
                };
                write_str!(format!(
                    "DROP {keyword} IF EXISTS {};\n",
                    dialect.qualified(table)
                ));
            }
            let ddl = driver.create_statement(table).await?;
            write_str!(if ddl.trim_end().ends_with(';') {
                format!("{ddl}\n\n")
            } else {
                format!("{ddl};\n\n")
            });
        }

        if options.include_data && table.kind == TableKind::Table {
            let details = driver.describe(table).await?;
            // Paging needs a stable order; the primary key is the natural choice, and
            // without one the first column keeps pages from overlapping.
            let order_columns = if details.primary_key_columns().is_empty() {
                details
                    .columns
                    .first()
                    .map(|c| vec![(c.name.clone(), true)])
                    .unwrap_or_default()
            } else {
                details
                    .primary_key_columns()
                    .into_iter()
                    .map(|c| (c, true))
                    .collect()
            };

            let mut offset = 0u64;
            let mut pending: Vec<String> = Vec::new();
            let mut columns: Vec<ColumnInfo> = Vec::new();
            let mut column_list = String::new();

            loop {
                let page = driver
                    .fetch_rows(table, "", &order_columns, options.fetch_batch_size, offset)
                    .await?;
                if page.rows.is_empty() {
                    break;
                }
                if columns.is_empty() {
                    columns = page.columns.clone();
                    column_list = columns
                        .iter()
                        .map(|c| dialect.quote(&c.name))
                        .collect::<Vec<_>>()
                        .join(", ");
                }

                for row in &page.rows {
                    let values: Vec<String> = (0..columns.len())
                        .map(|i| {
                            literal(
                                row.values.get(i).unwrap_or(&SqlValue::Null),
                                columns.get(i),
                                &dialect,
                            )
                        })
                        .collect();
                    pending.push(format!("  ({})", values.join(", ")));
                    total_rows += 1;

                    if pending.len() >= options.rows_per_insert.max(1) {
                        write_str!(format!(
                            "INSERT INTO {} ({column_list}) VALUES\n{};\n",
                            dialect.qualified(table),
                            pending.join(",\n")
                        ));
                        pending.clear();
                    }
                }

                let fetched = page.rows.len() as u64;
                offset += fetched;
                if fetched < options.fetch_batch_size {
                    break;
                }
            }

            if !pending.is_empty() {
                write_str!(format!(
                    "INSERT INTO {} ({column_list}) VALUES\n{};\n",
                    dialect.qualified(table),
                    pending.join(",\n")
                ));
            }
            write_str!("\n".to_string());
        }
    }

    if options.wrap_in_transaction {
        write_str!("COMMIT;\n".to_string());
    }
    write_str!(match kind {
        DatabaseKind::Mysql | DatabaseKind::Mariadb =>
            "\nSET FOREIGN_KEY_CHECKS = 1;\n".to_string(),
        DatabaseKind::Sqlite => "\nPRAGMA foreign_keys = ON;\n".to_string(),
        _ => "\nSET session_replication_role = 'origin';\n".to_string(),
    });

    writer
        .flush()
        .map_err(|e| DbError::new(format!("Could not finish writing {path}: {e}")))?;

    progress(DumpProgress {
        current_table: String::new(),
        table_index: tables.len(),
        table_count: tables.len(),
        rows_written: total_rows,
        bytes_written: bytes,
    });

    Ok(DumpSummary {
        tables: tables.len(),
        rows: total_rows,
        bytes,
        path: path.to_string(),
    })
}

/// Numbers, booleans and binary blobs are written unquoted so a restore round-trips.
fn literal(value: &SqlValue, column: Option<&ColumnInfo>, dialect: &Dialect) -> String {
    let SqlValue::Text(text) = value else {
        return "NULL".to_string();
    };

    if let Some(column) = column {
        let type_name = column.type_name.to_lowercase();
        if type_name.contains("blob") || type_name.contains("bytea") || type_name.contains("binary")
        {
            if text.starts_with("X'") || text.starts_with("x'") {
                return text.clone();
            }
            if let Some(hex) = text.strip_prefix("\\x") {
                return dialect.blob_literal(hex);
            }
        }
        if column.is_numeric() && text.parse::<f64>().is_ok() {
            return text.clone();
        }
        if type_name.contains("bool") {
            let lowered = text.to_lowercase();
            if ["true", "false", "t", "f", "0", "1"].contains(&lowered.as_str()) {
                let truthy = ["true", "t", "1"].contains(&lowered.as_str());
                return match dialect.kind {
                    DatabaseKind::Sqlite => if truthy { "1" } else { "0" }.to_string(),
                    _ => if truthy { "TRUE" } else { "FALSE" }.to_string(),
                };
            }
        }
    }
    dialect.string_literal(text)
}

// MARK: - Running a script back in

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptProgress {
    pub statement_index: usize,
    pub statement_count: usize,
    pub succeeded: usize,
    pub failed: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptFailure {
    pub statement: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptSummary {
    pub total: usize,
    pub succeeded: usize,
    pub failures: Vec<ScriptFailure>,
    pub duration_ms: f64,
}

/// Runs a `.sql` file one statement at a time, so progress is honest and a failure can be
/// reported with the statement that caused it.
pub async fn run_script(
    driver: &mut Box<dyn Driver>,
    script: &str,
    stop_on_error: bool,
    mut progress: impl FnMut(ScriptProgress),
) -> DbResult<ScriptSummary> {
    let started = std::time::Instant::now();
    let statements = splitter::split(script, driver.kind());
    let mut succeeded = 0usize;
    let mut failures: Vec<ScriptFailure> = Vec::new();

    for (index, statement) in statements.iter().enumerate() {
        progress(ScriptProgress {
            statement_index: index,
            statement_count: statements.len(),
            succeeded,
            failed: failures.len(),
        });

        match driver.execute(&statement.text).await {
            Ok(_) => succeeded += 1,
            Err(error) => {
                failures.push(ScriptFailure {
                    statement: statement.text.clone(),
                    message: error.to_string(),
                });
                if stop_on_error {
                    break;
                }
            }
        }
    }

    progress(ScriptProgress {
        statement_index: statements.len(),
        statement_count: statements.len(),
        succeeded,
        failed: failures.len(),
    });

    Ok(ScriptSummary {
        total: statements.len(),
        succeeded,
        failures,
        duration_ms: started.elapsed().as_secs_f64() * 1000.0,
    })
}

/// Reads a script from disk, falling back to Latin-1 so a dump from an older client still
/// loads rather than failing with an unhelpful decoding error.
pub fn read_script(path: &str) -> DbResult<String> {
    let bytes =
        std::fs::read(path).map_err(|e| DbError::new(format!("Could not read {path}: {e}")))?;
    match String::from_utf8(bytes) {
        Ok(text) => Ok(text),
        Err(error) => Ok(error
            .into_bytes()
            .iter()
            .map(|b| *b as char)
            .collect::<String>()),
    }
}
