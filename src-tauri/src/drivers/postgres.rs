//! PostgreSQL over the simple query protocol.
//!
//! `simple_query` is what makes this driver small: the server renders every value as text
//! and sends a row description even when the result is empty. That removes the per-type
//! binary decoder the Swift version needed, and fixes its limitation where a query
//! returning no rows showed no column headers.

use super::{Credentials, Driver};
use crate::error::{DbError, DbResult};
use crate::models::*;
use crate::sql::{dialect, dialect::Dialect, splitter};
use async_trait::async_trait;
use tokio_postgres::{Client, Config, SimpleQueryMessage};

pub struct PostgresDriver {
    credentials: Credentials,
    client: Option<Client>,
    active_database: String,
}

impl PostgresDriver {
    pub fn new(credentials: Credentials) -> Self {
        let active_database = credentials.profile.database.clone();
        Self {
            credentials,
            client: None,
            active_database,
        }
    }

    fn client(&self) -> DbResult<&Client> {
        match &self.client {
            Some(client) if !client.is_closed() => Ok(client),
            _ => Err(DbError::not_connected()),
        }
    }

    async fn open(&mut self, database: &str) -> DbResult<()> {
        let profile = &self.credentials.profile;

        let mut config = Config::new();
        config
            .host(&profile.host)
            .port(profile.port)
            .user(&profile.username)
            .dbname(database)
            .connect_timeout(std::time::Duration::from_secs(
                profile.connect_timeout_seconds,
            ));
        if let Some(password) = &self.credentials.password {
            config.password(password);
        }
        if profile.ssl_mode == SslMode::Require {
            config.ssl_mode(tokio_postgres::config::SslMode::Require);
        } else if profile.ssl_mode == SslMode::Prefer {
            config.ssl_mode(tokio_postgres::config::SslMode::Prefer);
        } else {
            config.ssl_mode(tokio_postgres::config::SslMode::Disable);
        }

        let client = if profile.ssl_mode == SslMode::Disable {
            let (client, connection) = config
                .connect(tokio_postgres::NoTls)
                .await
                .map_err(map_error)?;
            // The connection future drives the socket and must keep running for the life
            // of the client; dropping it closes the connection.
            tokio::spawn(async move {
                let _ = connection.await;
            });
            client
        } else {
            let tls = crate::tls::postgres_connector()?;
            let (client, connection) = config.connect(tls).await.map_err(map_error)?;
            tokio::spawn(async move {
                let _ = connection.await;
            });
            client
        };

        self.client = Some(client);
        self.active_database = database.to_string();
        Ok(())
    }

    fn guard_read_only(&self, sql: &str) -> DbResult<()> {
        if self.credentials.profile.read_only && !dialect::is_read_only_statement(sql) {
            return Err(DbError::read_only(&dialect::leading_keyword(sql)));
        }
        Ok(())
    }

    async fn run_single(&self, sql: &str) -> DbResult<QueryResult> {
        let client = self.client()?;
        let started = std::time::Instant::now();
        let messages = client.simple_query(sql).await.map_err(map_error)?;

        let mut columns: Vec<ColumnInfo> = Vec::new();
        let mut rows: Vec<ResultRow> = Vec::new();
        let mut rows_affected: Option<u64> = None;

        for message in &messages {
            match message {
                // Sent even when the result is empty, which is the whole point.
                SimpleQueryMessage::RowDescription(description) => {
                    columns = description
                        .iter()
                        .enumerate()
                        .map(|(index, column)| ColumnInfo::new(index, column.name(), ""))
                        .collect();
                }
                SimpleQueryMessage::Row(row) => {
                    if columns.is_empty() {
                        columns = (0..row.len())
                            .map(|index| ColumnInfo::new(index, row.columns()[index].name(), ""))
                            .collect();
                    }
                    let values = (0..columns.len())
                        .map(|index| SqlValue::from_option(row.get(index)))
                        .collect();
                    rows.push(ResultRow {
                        id: rows.len(),
                        values,
                    });
                }
                // For SELECT the tag just repeats the row count, which would be
                // misleading shown as "rows affected", so it is only read when the
                // statement produced no columns.
                SimpleQueryMessage::CommandComplete(count) if columns.is_empty() => {
                    rows_affected = Some(*count);
                }
                _ => {}
            }
        }

        Ok(QueryResult {
            statement: sql.to_string(),
            columns,
            rows,
            rows_affected,
            duration_ms: started.elapsed().as_secs_f64() * 1000.0,
            messages: Vec::new(),
        })
    }

    async fn scalar(&self, sql: &str) -> DbResult<Option<String>> {
        let result = self.run_single(sql).await?;
        Ok(result
            .rows
            .first()
            .and_then(|row| row.values.first())
            .filter(|value| !value.is_null())
            .map(|value| value.as_str().to_string()))
    }
}

#[async_trait]
impl Driver for PostgresDriver {
    fn kind(&self) -> DatabaseKind {
        DatabaseKind::Postgres
    }

    fn is_connected(&self) -> bool {
        self.client.as_ref().is_some_and(|c| !c.is_closed())
    }

    async fn connect(&mut self) -> DbResult<ServerInfo> {
        let database = if self.active_database.is_empty() {
            "postgres".to_string()
        } else {
            self.active_database.clone()
        };
        self.open(&database).await?;

        let version = self
            .scalar("SHOW server_version")
            .await?
            .unwrap_or_else(|| "unknown".into());
        let current_database = self
            .scalar("SELECT current_database()")
            .await?
            .unwrap_or_else(|| database.clone());
        let current_user = self
            .scalar("SELECT current_user")
            .await?
            .unwrap_or_else(|| self.credentials.profile.username.clone());
        self.active_database = current_database.clone();

        Ok(ServerInfo {
            product_name: "PostgreSQL".into(),
            version,
            current_database,
            current_user,
        })
    }

    async fn disconnect(&mut self) {
        self.client = None;
    }

    /// PostgreSQL binds a connection to one database, so switching means reconnecting.
    async fn use_database(&mut self, database: &str) -> DbResult<()> {
        if database == self.active_database || database.is_empty() {
            return Ok(());
        }
        self.disconnect().await;
        self.open(database).await
    }

    async fn execute(&mut self, sql: &str) -> DbResult<Vec<QueryResult>> {
        let statements = splitter::split(sql, DatabaseKind::Postgres);
        let mut results = Vec::with_capacity(statements.len());
        for statement in statements {
            self.guard_read_only(&statement.text)?;
            results.push(self.run_single(&statement.text).await?);
        }
        Ok(results)
    }

    async fn list_databases(&mut self) -> DbResult<Vec<String>> {
        let result = self
            .run_single(
                "SELECT datname FROM pg_database \
                 WHERE datistemplate = false AND has_database_privilege(datname, 'CONNECT') \
                 ORDER BY datname",
            )
            .await?;
        Ok(first_column(&result))
    }

    async fn list_schemas(&mut self, database: &str) -> DbResult<Vec<String>> {
        self.use_database(database).await?;
        let result = self
            .run_single(
                "SELECT nspname FROM pg_namespace \
                 WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema' \
                 ORDER BY nspname",
            )
            .await?;
        Ok(first_column(&result))
    }

    async fn list_tables(&mut self, database: &str, schema: &str) -> DbResult<Vec<TableRef>> {
        self.use_database(database).await?;
        let dialect = Dialect::new(DatabaseKind::Postgres);
        let result = self
            .run_single(&format!(
                "SELECT c.relname, c.relkind FROM pg_class c \
                 JOIN pg_namespace n ON n.oid = c.relnamespace \
                 WHERE n.nspname = {} AND c.relkind IN ('r', 'p', 'v', 'm', 'f') \
                 ORDER BY c.relname",
                dialect.string_literal(schema)
            ))
            .await?;

        Ok(result
            .rows
            .iter()
            .filter_map(|row| {
                let name = row.values.first()?.as_str().to_string();
                let kind = match row.values.get(1).map(|v| v.as_str()) {
                    Some("v") => TableKind::View,
                    Some("m") => TableKind::MaterializedView,
                    _ => TableKind::Table,
                };
                Some(TableRef {
                    database: database.to_string(),
                    schema: schema.to_string(),
                    name,
                    kind,
                })
            })
            .collect())
    }

    async fn describe(&mut self, table: &TableRef) -> DbResult<TableDetails> {
        self.use_database(&table.database).await?;
        let dialect = Dialect::new(DatabaseKind::Postgres);
        let schema_literal = dialect.string_literal(&table.schema);
        let table_literal = dialect.string_literal(&table.name);
        let qualified_literal = dialect.string_literal(&format!("{}.{}", table.schema, table.name));

        let column_rows = self
            .run_single(&format!(
                "SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, \
                        pg_get_expr(d.adbin, d.adrelid), COALESCE(pk.is_primary, false), \
                        a.attidentity <> '' OR pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval%', \
                        col_description(a.attrelid, a.attnum), a.attnum \
                 FROM pg_attribute a \
                 LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum \
                 LEFT JOIN (SELECT conrelid, unnest(conkey) AS attnum, true AS is_primary \
                            FROM pg_constraint WHERE contype = 'p') pk \
                   ON pk.conrelid = a.attrelid AND pk.attnum = a.attnum \
                 WHERE a.attrelid = {qualified_literal}::regclass \
                   AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum"
            ))
            .await?;

        let columns: Vec<ColumnDefinition> = column_rows
            .rows
            .iter()
            .map(|row| {
                let get = |i: usize| row.values.get(i).cloned().unwrap_or(SqlValue::Null);
                let optional = |i: usize| match get(i) {
                    SqlValue::Null => None,
                    SqlValue::Text(v) => Some(v),
                };
                ColumnDefinition {
                    name: get(0).as_str().to_string(),
                    data_type: get(1).as_str().to_string(),
                    is_nullable: get(2).as_str() == "t",
                    default_value: optional(3),
                    is_primary_key: get(4).as_str() == "t",
                    is_auto_increment: get(5).as_str() == "t",
                    comment: optional(6),
                    ordinal_position: get(7).as_str().parse().unwrap_or(0),
                }
            })
            .collect();

        let index_rows = self
            .run_single(&format!(
                "SELECT i.relname, ix.indisunique, ix.indisprimary, am.amname, \
                        pg_get_indexdef(ix.indexrelid) \
                 FROM pg_index ix \
                 JOIN pg_class i ON i.oid = ix.indexrelid \
                 JOIN pg_class t ON t.oid = ix.indrelid \
                 JOIN pg_namespace n ON n.oid = t.relnamespace \
                 JOIN pg_am am ON am.oid = i.relam \
                 WHERE n.nspname = {schema_literal} AND t.relname = {table_literal} \
                 ORDER BY i.relname"
            ))
            .await?;

        let indexes: Vec<IndexDefinition> = index_rows
            .rows
            .iter()
            .map(|row| {
                let get = |i: usize| {
                    row.values
                        .get(i)
                        .map(|v| v.as_str().to_string())
                        .unwrap_or_default()
                };
                IndexDefinition {
                    name: get(0),
                    columns: columns_from_index_definition(&get(4)),
                    is_unique: get(1) == "t",
                    is_primary: get(2) == "t",
                    method: Some(get(3)),
                }
            })
            .collect();

        let fk_rows = self
            .run_single(&format!(
                "SELECT con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con \
                 JOIN pg_class t ON t.oid = con.conrelid \
                 JOIN pg_namespace n ON n.oid = t.relnamespace \
                 WHERE con.contype = 'f' AND n.nspname = {schema_literal} \
                   AND t.relname = {table_literal} ORDER BY con.conname"
            ))
            .await?;

        let foreign_keys: Vec<ForeignKeyDefinition> = fk_rows
            .rows
            .iter()
            .filter_map(|row| {
                let name = row.values.first()?.as_str().to_string();
                let definition = row.values.get(1)?.as_str();
                parse_foreign_key(name, definition)
            })
            .collect();

        let estimated_row_count = self
            .scalar(&format!(
                "SELECT reltuples::bigint FROM pg_class WHERE oid = {qualified_literal}::regclass"
            ))
            .await
            .ok()
            .flatten()
            .and_then(|v| v.parse::<i64>().ok())
            .filter(|v| *v >= 0);

        let comment = self
            .scalar(&format!(
                "SELECT obj_description({qualified_literal}::regclass)"
            ))
            .await
            .ok()
            .flatten();

        Ok(TableDetails {
            table: table.clone(),
            columns,
            indexes,
            foreign_keys,
            estimated_row_count,
            comment,
        })
    }

    /// PostgreSQL has no `SHOW CREATE TABLE`, so the DDL is rebuilt from the catalog.
    async fn create_statement(&mut self, table: &TableRef) -> DbResult<String> {
        let dialect = Dialect::new(DatabaseKind::Postgres);
        let details = self.describe(table).await?;

        if matches!(table.kind, TableKind::View | TableKind::MaterializedView) {
            let literal = dialect.string_literal(&format!("{}.{}", table.schema, table.name));
            if let Some(definition) = self
                .scalar(&format!("SELECT pg_get_viewdef({literal}::regclass, true)"))
                .await?
            {
                let keyword = if table.kind == TableKind::View {
                    "VIEW"
                } else {
                    "MATERIALIZED VIEW"
                };
                return Ok(format!(
                    "CREATE OR REPLACE {keyword} {} AS\n{definition}",
                    dialect.qualified(table)
                ));
            }
        }

        let mut lines: Vec<String> = details
            .columns
            .iter()
            .map(|column| {
                let mut line = format!("    {} {}", dialect.quote(&column.name), column.data_type);
                if !column.is_nullable {
                    line.push_str(" NOT NULL");
                }
                if let Some(default) = &column.default_value {
                    line.push_str(&format!(" DEFAULT {default}"));
                }
                line
            })
            .collect();

        let primary_key = details.primary_key_columns();
        if !primary_key.is_empty() {
            let quoted: Vec<String> = primary_key.iter().map(|c| dialect.quote(c)).collect();
            lines.push(format!("    PRIMARY KEY ({})", quoted.join(", ")));
        }

        let mut sql = format!(
            "CREATE TABLE {} (\n{}\n);",
            dialect.qualified(table),
            lines.join(",\n")
        );

        for key in &details.foreign_keys {
            let columns: Vec<String> = key.columns.iter().map(|c| dialect.quote(c)).collect();
            let referenced: Vec<String> = key
                .referenced_columns
                .iter()
                .map(|c| dialect.quote(c))
                .collect();
            sql.push_str(&format!(
                "\n\nALTER TABLE {} ADD CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {} ({});",
                dialect.qualified(table),
                dialect.quote(&key.name),
                columns.join(", "),
                key.referenced_table,
                referenced.join(", ")
            ));
        }

        for index in details.indexes.iter().filter(|i| !i.is_primary) {
            let columns: Vec<String> = index.columns.iter().map(|c| dialect.quote(c)).collect();
            sql.push_str(&format!(
                "\n\nCREATE {}INDEX {} ON {} ({});",
                if index.is_unique { "UNIQUE " } else { "" },
                dialect.quote(&index.name),
                dialect.qualified(table),
                columns.join(", ")
            ));
        }

        Ok(sql)
    }
}

fn first_column(result: &QueryResult) -> Vec<String> {
    result
        .rows
        .iter()
        .filter_map(|row| row.values.first().map(|v| v.as_str().to_string()))
        .collect()
}

/// `CREATE INDEX x ON t USING btree (a, b)` → `["a", "b"]`.
pub fn columns_from_index_definition(definition: &str) -> Vec<String> {
    let (Some(open), Some(close)) = (definition.rfind('('), definition.rfind(')')) else {
        return Vec::new();
    };
    if open >= close {
        return Vec::new();
    }
    definition[open + 1..close]
        .split(',')
        .map(|part| part.trim().trim_matches('"').to_string())
        .collect()
}

/// `FOREIGN KEY (a) REFERENCES other(b) ON DELETE CASCADE` → a structured definition.
pub fn parse_foreign_key(name: String, definition: &str) -> Option<ForeignKeyDefinition> {
    let key_open = definition.find('(')?;
    let key_close = definition[key_open..].find(')')? + key_open;
    let columns: Vec<String> = definition[key_open + 1..key_close]
        .split(',')
        .map(|p| p.trim().trim_matches('"').to_string())
        .collect();

    let references_at = definition.find("REFERENCES ")? + "REFERENCES ".len();
    let tail = &definition[references_at..];
    let ref_open = tail.find('(')?;
    let ref_close = tail[ref_open..].find(')')? + ref_open;

    let referenced_table = tail[..ref_open].trim().to_string();
    let referenced_columns: Vec<String> = tail[ref_open + 1..ref_close]
        .split(',')
        .map(|p| p.trim().trim_matches('"').to_string())
        .collect();

    let action = |keyword: &str| -> Option<String> {
        let marker = format!("ON {keyword} ");
        let at = definition.find(&marker)? + marker.len();
        let rest = &definition[at..];
        [
            "NO ACTION",
            "SET NULL",
            "SET DEFAULT",
            "CASCADE",
            "RESTRICT",
        ]
        .iter()
        .find(|candidate| rest.starts_with(*candidate))
        .map(|c| c.to_string())
    };

    Some(ForeignKeyDefinition {
        name,
        columns,
        referenced_table,
        referenced_columns,
        on_delete: action("DELETE"),
        on_update: action("UPDATE"),
    })
}

fn map_error(error: tokio_postgres::Error) -> DbError {
    if let Some(db) = error.as_db_error() {
        return DbError::with_code(db.message().to_string(), db.code().code().to_string())
            .with_detail(
                [db.detail(), db.hint()]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
    }
    DbError::new(error.to_string())
}
