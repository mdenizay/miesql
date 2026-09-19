//! Reads a CSV file and builds the INSERT statements for it.
//!
//! Parsing and inserting are separate so the import sheet can show a preview and a column
//! mapping before anything touches the server.

use crate::error::{DbError, DbResult};
use crate::models::{DatabaseKind, TableRef};
use crate::sql::dialect::Dialect;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CsvOptions {
    #[serde(default = "comma")]
    pub delimiter: String,
    #[serde(default = "yes")]
    pub has_header_row: bool,
    /// Text in the file that should become SQL NULL rather than an empty string.
    #[serde(default)]
    pub null_marker: String,
    #[serde(default = "two_hundred")]
    pub rows_per_insert: usize,
    /// CSV column index to target column name. Unmapped columns are skipped.
    #[serde(default)]
    pub column_mapping: BTreeMap<usize, String>,
}

fn comma() -> String {
    ",".to_string()
}
fn yes() -> bool {
    true
}
fn two_hundred() -> usize {
    200
}

impl Default for CsvOptions {
    fn default() -> Self {
        Self {
            delimiter: ",".into(),
            has_header_row: true,
            null_marker: String::new(),
            rows_per_insert: 200,
            column_mapping: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CsvPreview {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
    pub total_rows: usize,
}

/// RFC 4180 reader: quoted fields, doubled quotes inside them, and newlines within a field.
pub fn parse(text: &str, delimiter: char) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut field = String::new();
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(ch);
            }
            continue;
        }

        match ch {
            '"' if field.is_empty() => in_quotes = true,
            c if c == delimiter => row.push(std::mem::take(&mut field)),
            '\r' => {}
            '\n' => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            c => field.push(c),
        }
    }

    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }

    // A trailing newline leaves one empty row behind; it is not data.
    rows.retain(|r| !(r.len() == 1 && r[0].is_empty()));
    rows
}

fn read_text(path: &str) -> DbResult<String> {
    let bytes =
        std::fs::read(path).map_err(|e| DbError::new(format!("Could not read {path}: {e}")))?;
    match String::from_utf8(bytes) {
        Ok(text) => Ok(text),
        // Fall back to Latin-1 rather than refusing a file exported by an older tool.
        Err(error) => Ok(error.into_bytes().iter().map(|b| *b as char).collect()),
    }
}

fn delimiter_char(options: &CsvOptions) -> char {
    options.delimiter.chars().next().unwrap_or(',')
}

pub fn preview(path: &str, options: &CsvOptions, max_rows: usize) -> DbResult<CsvPreview> {
    let rows = parse(&read_text(path)?, delimiter_char(options));
    let Some(first) = rows.first() else {
        return Ok(CsvPreview {
            header: Vec::new(),
            rows: Vec::new(),
            total_rows: 0,
        });
    };

    let header: Vec<String> = if options.has_header_row {
        first.clone()
    } else {
        (1..=first.len()).map(|i| format!("column{i}")).collect()
    };
    let data: Vec<Vec<String>> = if options.has_header_row {
        rows[1..].to_vec()
    } else {
        rows.clone()
    };

    Ok(CsvPreview {
        header,
        rows: data.iter().take(max_rows).cloned().collect(),
        total_rows: data.len(),
    })
}

/// Builds the INSERT statements. Returning them rather than running them keeps the import
/// reviewable before it is applied.
pub fn statements(
    path: &str,
    table: &TableRef,
    kind: DatabaseKind,
    options: &CsvOptions,
) -> DbResult<Vec<String>> {
    let dialect = Dialect::new(kind);
    let rows = parse(&read_text(path)?, delimiter_char(options));
    let Some(first) = rows.first().cloned() else {
        return Ok(Vec::new());
    };

    let data: Vec<Vec<String>> = if options.has_header_row {
        rows[1..].to_vec()
    } else {
        rows
    };
    if data.is_empty() {
        return Ok(Vec::new());
    }

    // With no explicit mapping, a header row maps itself onto columns of the same name.
    let mapping: BTreeMap<usize, String> = if options.column_mapping.is_empty() {
        if !options.has_header_row {
            return Err(DbError::new("No CSV columns are mapped to table columns."));
        }
        first
            .iter()
            .enumerate()
            .filter(|(_, name)| !name.is_empty())
            .map(|(index, name)| (index, name.clone()))
            .collect()
    } else {
        options.column_mapping.clone()
    };

    if mapping.is_empty() {
        return Err(DbError::new("No CSV columns are mapped to table columns."));
    }

    let column_list = mapping
        .values()
        .map(|name| dialect.quote(name))
        .collect::<Vec<_>>()
        .join(", ");

    let mut statements = Vec::new();
    let mut batch: Vec<String> = Vec::new();
    let flush = |batch: &mut Vec<String>, statements: &mut Vec<String>| {
        if batch.is_empty() {
            return;
        }
        statements.push(format!(
            "INSERT INTO {} ({column_list}) VALUES\n{};",
            dialect.qualified(table),
            batch.join(",\n")
        ));
        batch.clear();
    };

    for row in &data {
        let values: Vec<String> = mapping
            .keys()
            .map(|index| match row.get(*index) {
                None => "NULL".to_string(),
                Some(raw) if *raw == options.null_marker => "NULL".to_string(),
                Some(raw) => dialect.string_literal(raw),
            })
            .collect();
        batch.push(format!("  ({})", values.join(", ")));
        if batch.len() >= options.rows_per_insert.max(1) {
            flush(&mut batch, &mut statements);
        }
    }
    flush(&mut batch, &mut statements);

    Ok(statements)
}
