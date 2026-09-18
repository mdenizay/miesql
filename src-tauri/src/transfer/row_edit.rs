//! Turns grid edits into SQL.
//!
//! Every generated statement is keyed on the complete primary key and is shown to the user
//! before it runs, so an edit can never silently hit more rows than intended. A table with
//! no key is refused rather than approximated.

use crate::error::DbError;
use crate::models::{DatabaseKind, SqlValue, TableRef};
use crate::sql::dialect::Dialect;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One pending change made in the result grid.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RowEdit {
    #[serde(rename_all = "camelCase")]
    Update {
        row_id: usize,
        changes: BTreeMap<String, SqlValue>,
        /// The row as it was read, used to build the WHERE clause.
        original: BTreeMap<String, SqlValue>,
    },
    #[serde(rename_all = "camelCase")]
    Insert {
        row_id: usize,
        values: BTreeMap<String, SqlValue>,
    },
    #[serde(rename_all = "camelCase")]
    Delete {
        row_id: usize,
        original: BTreeMap<String, SqlValue>,
    },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannedStatement {
    pub sql: String,
    /// Which grid row produced it, so the UI can point at the offending edit.
    pub row_id: usize,
}

pub struct RowEditPlanner {
    dialect: Dialect,
    table: TableRef,
    key_columns: Vec<String>,
}

impl RowEditPlanner {
    pub fn new(kind: DatabaseKind, table: TableRef, key_columns: Vec<String>) -> Self {
        Self {
            dialect: Dialect::new(kind),
            table,
            key_columns,
        }
    }

    pub fn plan(&self, edits: &[RowEdit]) -> Result<Vec<PlannedStatement>, DbError> {
        if edits.is_empty() {
            return Err(DbError::new("There is nothing to apply."));
        }

        // Inserts need no key, so a keyless table can still be appended to.
        let needs_key = edits
            .iter()
            .any(|edit| !matches!(edit, RowEdit::Insert { .. }));
        if needs_key && self.key_columns.is_empty() {
            return Err(DbError::new(format!(
                "{} has no primary key or unique index, so MieSQL cannot identify a single \
                 row to change. Edit it with a SQL statement instead.",
                self.table.qualified_name()
            )));
        }

        edits
            .iter()
            .map(|edit| match edit {
                RowEdit::Update {
                    row_id,
                    changes,
                    original,
                } => Ok(PlannedStatement {
                    sql: self.update_statement(changes, original)?,
                    row_id: *row_id,
                }),
                RowEdit::Insert { row_id, values } => Ok(PlannedStatement {
                    sql: self.insert_statement(values),
                    row_id: *row_id,
                }),
                RowEdit::Delete { row_id, original } => Ok(PlannedStatement {
                    sql: self.delete_statement(original)?,
                    row_id: *row_id,
                }),
            })
            .collect()
    }

    fn update_statement(
        &self,
        changes: &BTreeMap<String, SqlValue>,
        original: &BTreeMap<String, SqlValue>,
    ) -> Result<String, DbError> {
        if changes.is_empty() {
            return Err(DbError::new("An edited row has no changed values."));
        }
        let assignments: Vec<String> = changes
            .iter()
            .map(|(column, value)| {
                format!(
                    "{} = {}",
                    self.dialect.quote(column),
                    self.dialect.literal(value)
                )
            })
            .collect();
        Ok(format!(
            "UPDATE {} SET {} WHERE {};",
            self.dialect.qualified(&self.table),
            assignments.join(", "),
            self.where_clause(original)?
        ))
    }

    fn insert_statement(&self, values: &BTreeMap<String, SqlValue>) -> String {
        let columns: Vec<String> = values.keys().map(|c| self.dialect.quote(c)).collect();
        let literals: Vec<String> = values.values().map(|v| self.dialect.literal(v)).collect();
        format!(
            "INSERT INTO {} ({}) VALUES ({});",
            self.dialect.qualified(&self.table),
            columns.join(", "),
            literals.join(", ")
        )
    }

    fn delete_statement(&self, original: &BTreeMap<String, SqlValue>) -> Result<String, DbError> {
        Ok(format!(
            "DELETE FROM {} WHERE {};",
            self.dialect.qualified(&self.table),
            self.where_clause(original)?
        ))
    }

    /// Always matches on the complete key, and uses `IS NULL` where a key part is NULL so
    /// the comparison behaves as expected rather than matching nothing.
    fn where_clause(&self, original: &BTreeMap<String, SqlValue>) -> Result<String, DbError> {
        let mut predicates = Vec::with_capacity(self.key_columns.len());
        for column in &self.key_columns {
            let value = original.get(column).ok_or_else(|| {
                DbError::new(format!(
                    "The value of key column \"{column}\" is missing for this row."
                ))
            })?;
            predicates.push(if value.is_null() {
                format!("{} IS NULL", self.dialect.quote(column))
            } else {
                format!(
                    "{} = {}",
                    self.dialect.quote(column),
                    self.dialect.literal(value)
                )
            });
        }
        Ok(predicates.join(" AND "))
    }
}
