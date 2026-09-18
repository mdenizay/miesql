//! Per-engine quoting and paging rules. Everything that builds SQL on the user's behalf —
//! the data browser, the row editor, the dumper — goes through here, so identifiers and
//! literals are escaped exactly once, in one place.

use crate::models::{DatabaseKind, SqlValue, TableRef};

#[derive(Debug, Clone, Copy)]
pub struct Dialect {
    pub kind: DatabaseKind,
}

impl Dialect {
    pub fn new(kind: DatabaseKind) -> Self {
        Self { kind }
    }

    /// Quote an identifier, doubling any embedded quote character.
    pub fn quote(&self, identifier: &str) -> String {
        match self.kind {
            DatabaseKind::Mysql | DatabaseKind::Mariadb => {
                format!("`{}`", identifier.replace('`', "``"))
            }
            _ => format!("\"{}\"", identifier.replace('"', "\"\"")),
        }
    }

    /// Quote a possibly-qualified name such as `public.users`, part by part.
    pub fn quote_qualified(&self, parts: &[&str]) -> String {
        parts
            .iter()
            .filter(|p| !p.is_empty())
            .map(|p| self.quote(p))
            .collect::<Vec<_>>()
            .join(".")
    }

    pub fn qualified(&self, table: &TableRef) -> String {
        self.quote_qualified(&[table.schema.as_str(), table.name.as_str()])
    }

    /// Render a value as a SQL literal. NULL becomes the keyword, not a quoted string.
    pub fn literal(&self, value: &SqlValue) -> String {
        match value {
            SqlValue::Null => "NULL".to_string(),
            SqlValue::Text(s) => self.string_literal(s),
        }
    }

    pub fn string_literal(&self, value: &str) -> String {
        match self.kind {
            DatabaseKind::Mysql | DatabaseKind::Mariadb => {
                // MySQL treats backslash as an escape character by default, so it needs
                // doubling on top of the standard single-quote doubling.
                let escaped = value.replace('\\', "\\\\").replace('\'', "''");
                format!("'{escaped}'")
            }
            _ => format!("'{}'", value.replace('\'', "''")),
        }
    }

    /// Byte literal used by the dumper for binary columns.
    pub fn blob_literal(&self, hex: &str) -> String {
        match self.kind {
            DatabaseKind::Postgres => format!("'\\x{hex}'::bytea"),
            _ => format!("X'{hex}'"),
        }
    }

    pub fn limit_clause(&self, limit: u64, offset: u64) -> String {
        if offset > 0 {
            format!("LIMIT {limit} OFFSET {offset}")
        } else {
            format!("LIMIT {limit}")
        }
    }

    /// `SELECT * FROM table ORDER BY ... LIMIT ...` for the data browser.
    pub fn select_statement(
        &self,
        table: &TableRef,
        where_clause: &str,
        order_by: &[(String, bool)],
        limit: u64,
        offset: u64,
    ) -> String {
        let mut sql = format!("SELECT * FROM {}", self.qualified(table));
        let trimmed = where_clause.trim();
        if !trimmed.is_empty() {
            sql.push_str(&format!(" WHERE {trimmed}"));
        }
        if !order_by.is_empty() {
            let terms: Vec<String> = order_by
                .iter()
                .map(|(column, ascending)| {
                    format!("{} {}", self.quote(column), if *ascending { "ASC" } else { "DESC" })
                })
                .collect();
            sql.push_str(&format!(" ORDER BY {}", terms.join(", ")));
        }
        sql.push(' ');
        sql.push_str(&self.limit_clause(limit, offset));
        sql
    }

    pub fn count_statement(&self, table: &TableRef, where_clause: &str) -> String {
        let mut sql = format!("SELECT COUNT(*) FROM {}", self.qualified(table));
        let trimmed = where_clause.trim();
        if !trimmed.is_empty() {
            sql.push_str(&format!(" WHERE {trimmed}"));
        }
        sql
    }
}

/// Statement kinds we need to tell apart to enforce read-only mode and to decide whether
/// a result grid is expected.
pub fn is_read_only_statement(sql: &str) -> bool {
    matches!(
        leading_keyword(sql).as_str(),
        "select" | "show" | "explain" | "describe" | "desc" | "with" | "pragma" | "values" | "table"
    )
}

/// The first real keyword, skipping whitespace and comments.
pub fn leading_keyword(sql: &str) -> String {
    let chars: Vec<char> = sql.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        // Line comment
        if c == '-' && i + 1 < chars.len() && chars[i + 1] == '-' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        // Block comment
        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '*' {
            i += 2;
            while i < chars.len() {
                if chars[i] == '*' && i + 1 < chars.len() && chars[i + 1] == '/' {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        break;
    }

    let mut word = String::new();
    while i < chars.len() && chars[i].is_alphabetic() {
        word.push(chars[i]);
        i += 1;
    }
    word.to_lowercase()
}
