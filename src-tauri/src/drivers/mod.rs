//! The contract every engine implements, and the factory that picks one.
//!
//! Drivers hand back values already rendered to text. That single decision is what keeps
//! the grid, the exporters, the clipboard and the dumper on one code path, and it is why
//! each driver uses its engine's *text* protocol where one exists.

pub mod cancel;
pub mod mysql;
pub mod postgres;
pub mod redis;
pub mod sqlite;

use crate::error::{DbError, DbResult};
use crate::models::{
    ConnectionProfile, DatabaseKind, QueryResult, ServerInfo, TableDetails, TableRef,
};
use crate::sql::dialect::Dialect;
use async_trait::async_trait;
pub use cancel::{CancelSlot, Canceller};

/// What a driver needs to open a connection. The password is passed in rather than read
/// from the credential store here, so the core stays testable and free of UI concerns.
#[derive(Debug, Clone)]
pub struct Credentials {
    pub profile: ConnectionProfile,
    pub password: Option<String>,
}

impl Credentials {
    pub fn new(profile: ConnectionProfile, password: Option<String>) -> Self {
        Self { profile, password }
    }
}

#[async_trait]
pub trait Driver: Send {
    fn kind(&self) -> DatabaseKind;
    fn is_connected(&self) -> bool;

    /// The slot this driver publishes its cancel handle into. The session keeps a second
    /// reference so a running query can be stopped without waiting for the driver lock.
    /// A driver that leaves the slot empty is one that cannot cancel.
    fn cancel_slot(&self) -> CancelSlot;

    async fn connect(&mut self) -> DbResult<ServerInfo>;
    async fn disconnect(&mut self);

    /// Runs a script, returning one result per statement.
    async fn execute(&mut self, sql: &str) -> DbResult<Vec<QueryResult>>;

    /// Databases visible to this login.
    async fn list_databases(&mut self) -> DbResult<Vec<String>>;
    /// Schemas inside a database. Empty for engines without a schema level.
    async fn list_schemas(&mut self, database: &str) -> DbResult<Vec<String>>;
    async fn list_tables(&mut self, database: &str, schema: &str) -> DbResult<Vec<TableRef>>;
    async fn describe(&mut self, table: &TableRef) -> DbResult<TableDetails>;

    /// Every column name in a schema, keyed by table, in one round trip.
    ///
    /// Editor completion needs the whole schema at once, and describing each table in
    /// turn would be one query per table on a tree that routinely holds hundreds of them.
    /// Only names are returned: completion has no use for types, and leaving them out
    /// keeps this to a single cheap query. An engine with no columns to speak of returns
    /// nothing rather than pretending.
    async fn schema_columns(
        &mut self,
        _database: &str,
        _schema: &str,
    ) -> DbResult<std::collections::BTreeMap<String, Vec<String>>> {
        Ok(Default::default())
    }
    /// `CREATE TABLE` text for the DDL tab.
    async fn create_statement(&mut self, table: &TableRef) -> DbResult<String>;
    /// Switches the active database without reconnecting, where the engine allows it.
    async fn use_database(&mut self, database: &str) -> DbResult<()>;

    /// Convenience used by the data browser and the exporters.
    async fn fetch_rows(
        &mut self,
        table: &TableRef,
        where_clause: &str,
        order_by: &[(String, bool)],
        limit: u64,
        offset: u64,
    ) -> DbResult<QueryResult> {
        let sql = Dialect::new(self.kind()).select_statement(
            table,
            where_clause,
            order_by,
            limit,
            offset,
        );
        self.execute(&sql)
            .await?
            .into_iter()
            .next()
            .ok_or_else(|| DbError::new("The server returned no result for the row query."))
    }

    async fn count_rows(&mut self, table: &TableRef, where_clause: &str) -> DbResult<i64> {
        let sql = Dialect::new(self.kind()).count_statement(table, where_clause);
        let results = self.execute(&sql).await?;
        Ok(results
            .first()
            .and_then(|r| r.rows.first())
            .and_then(|row| row.values.first())
            .and_then(|value| value.as_str().parse::<i64>().ok())
            .unwrap_or(0))
    }
}

pub fn make_driver(credentials: Credentials) -> DbResult<Box<dyn Driver>> {
    // Every connection comes through here, including from tests, so this is the one place
    // that guarantees TLS is ready before a driver reaches for it.
    crate::tls::ensure_crypto_provider();

    match credentials.profile.kind {
        DatabaseKind::Postgres => Ok(Box::new(postgres::PostgresDriver::new(credentials))),
        DatabaseKind::Mysql | DatabaseKind::Mariadb => {
            Ok(Box::new(mysql::MySqlDriver::new(credentials)))
        }
        DatabaseKind::Sqlite => Ok(Box::new(sqlite::SqliteDriver::new(credentials))),
        DatabaseKind::Redis => Ok(Box::new(redis::RedisDriver::new(credentials))),
        other => Err(DbError::new(format!(
            "{} support is not implemented yet.",
            other.display_name()
        ))),
    }
}

/// Folds a two-column `(table, column)` result into the map completion wants. Shared by
/// the drivers because every one of them can express the question as exactly that shape.
pub(crate) fn group_columns(
    result: &QueryResult,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut grouped: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for row in &result.rows {
        let (Some(table), Some(column)) = (row.values.first(), row.values.get(1)) else {
            continue;
        };
        if table.is_null() || column.is_null() {
            continue;
        }
        grouped
            .entry(table.as_str().to_string())
            .or_default()
            .push(column.as_str().to_string());
    }
    grouped
}
