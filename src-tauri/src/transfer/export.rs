//! Turns a result set into a file. Used by "Export result", "Copy as…" and the dumper.

use crate::models::{ColumnInfo, DatabaseKind, QueryResult, ResultRow, SqlValue};
use crate::sql::dialect::Dialect;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExportFormat {
    Csv,
    Tsv,
    Json,
    SqlInsert,
    Markdown,
}

impl ExportFormat {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Csv => "csv",
            Self::Tsv => "tsv",
            Self::Json => "json",
            Self::SqlInsert => "sql",
            Self::Markdown => "md",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportOptions {
    pub format: ExportFormat,
    #[serde(default = "yes")]
    pub include_header: bool,
    /// Written in place of NULL. Empty means an empty field, the CSV convention.
    #[serde(default)]
    pub null_placeholder: String,
    #[serde(default)]
    pub table_name: String,
    pub kind: DatabaseKind,
}

fn yes() -> bool {
    true
}

pub fn export(columns: &[ColumnInfo], rows: &[ResultRow], options: &ExportOptions) -> String {
    match options.format {
        ExportFormat::Csv => delimited(columns, rows, ",", options),
        ExportFormat::Tsv => delimited(columns, rows, "\t", options),
        ExportFormat::Json => json(columns, rows),
        ExportFormat::SqlInsert => sql_inserts(columns, rows, options),
        ExportFormat::Markdown => markdown(columns, rows, options),
    }
}

pub fn export_result(result: &QueryResult, options: &ExportOptions) -> String {
    export(&result.columns, &result.rows, options)
}

fn cell(row: &ResultRow, index: usize, options: &ExportOptions) -> String {
    match row.values.get(index) {
        Some(SqlValue::Null) | None => options.null_placeholder.clone(),
        Some(SqlValue::Text(value)) => value.clone(),
    }
}

fn delimited(
    columns: &[ColumnInfo],
    rows: &[ResultRow],
    delimiter: &str,
    options: &ExportOptions,
) -> String {
    let mut lines = Vec::with_capacity(rows.len() + 1);
    if options.include_header {
        lines.push(
            columns
                .iter()
                .map(|c| escape_delimited(&c.name, delimiter))
                .collect::<Vec<_>>()
                .join(delimiter),
        );
    }
    for row in rows {
        lines.push(
            (0..columns.len())
                .map(|i| escape_delimited(&cell(row, i, options), delimiter))
                .collect::<Vec<_>>()
                .join(delimiter),
        );
    }
    lines.join("\n")
}

/// RFC 4180 quoting: wrap when the field holds the delimiter, a quote or a newline, and
/// double any embedded quote.
fn escape_delimited(value: &str, delimiter: &str) -> String {
    let needs_quoting = value.contains(delimiter)
        || value.contains('"')
        || value.contains('\n')
        || value.contains('\r');
    if !needs_quoting {
        return value.to_string();
    }
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn json(columns: &[ColumnInfo], rows: &[ResultRow]) -> String {
    let objects: Vec<String> = rows
        .iter()
        .map(|row| {
            let pairs: Vec<String> = columns
                .iter()
                .map(|column| {
                    let rendered = match row.values.get(column.index) {
                        Some(SqlValue::Text(value)) => json_string(value),
                        _ => "null".to_string(),
                    };
                    format!("{}: {}", json_string(&column.name), rendered)
                })
                .collect();
            format!("  {{{}}}", pairs.join(", "))
        })
        .collect();
    format!("[\n{}\n]", objects.join(",\n"))
}

fn json_string(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for ch in value.chars() {
        match ch {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            c if (c as u32) < 0x20 => output.push_str(&format!("\\u{:04x}", c as u32)),
            c => output.push(c),
        }
    }
    output.push('"');
    output
}

fn sql_inserts(columns: &[ColumnInfo], rows: &[ResultRow], options: &ExportOptions) -> String {
    let dialect = Dialect::new(options.kind);
    let table = if options.table_name.contains('.') {
        let parts: Vec<&str> = options.table_name.split('.').collect();
        dialect.quote_qualified(&parts)
    } else {
        dialect.quote(&options.table_name)
    };
    let column_list = columns
        .iter()
        .map(|c| dialect.quote(&c.name))
        .collect::<Vec<_>>()
        .join(", ");

    rows.iter()
        .map(|row| {
            let values = (0..columns.len())
                .map(|i| dialect.literal(row.values.get(i).unwrap_or(&SqlValue::Null)))
                .collect::<Vec<_>>()
                .join(", ");
            format!("INSERT INTO {table} ({column_list}) VALUES ({values});")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn markdown(columns: &[ColumnInfo], rows: &[ResultRow], options: &ExportOptions) -> String {
    let escape = |value: &str| value.replace('|', "\\|").replace('\n', " ");
    let mut lines = vec![
        format!(
            "| {} |",
            columns
                .iter()
                .map(|c| escape(&c.name))
                .collect::<Vec<_>>()
                .join(" | ")
        ),
        format!(
            "| {} |",
            columns
                .iter()
                .map(|_| "---")
                .collect::<Vec<_>>()
                .join(" | ")
        ),
    ];
    for row in rows {
        lines.push(format!(
            "| {} |",
            (0..columns.len())
                .map(|i| escape(&cell(row, i, options)))
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }
    lines.join("\n")
}
