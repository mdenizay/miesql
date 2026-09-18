//! Types shared by every layer: what a connection is, what a result looks like, and how
//! schema objects are described. Everything here is `Serialize`, because these are exactly
//! the shapes that cross the Tauri boundary into the UI.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The database engines MieSQL can talk to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DatabaseKind {
    Postgres,
    Mysql,
    Mariadb,
    Sqlite,
    Redis,
    Mongodb,
}

impl DatabaseKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Postgres => "PostgreSQL",
            Self::Mysql => "MySQL",
            Self::Mariadb => "MariaDB",
            Self::Sqlite => "SQLite",
            Self::Redis => "Redis",
            Self::Mongodb => "MongoDB",
        }
    }

    pub fn default_port(self) -> u16 {
        match self {
            Self::Postgres => 5432,
            Self::Mysql | Self::Mariadb => 3306,
            Self::Sqlite => 0,
            Self::Redis => 6379,
            Self::Mongodb => 27017,
        }
    }

    /// SQLite lives in a file; everything else lives behind a socket.
    pub fn is_file_based(self) -> bool {
        matches!(self, Self::Sqlite)
    }

    /// MySQL and MariaDB share a wire protocol, so they share a driver.
    pub fn uses_mysql_protocol(self) -> bool {
        matches!(self, Self::Mysql | Self::Mariadb)
    }

    /// Whether the engine speaks SQL at all. Redis and MongoDB do not, and the parts of
    /// the UI that assume SQL — the formatter, the dump, the row editor — stay hidden.
    pub fn is_relational(self) -> bool {
        matches!(
            self,
            Self::Postgres | Self::Mysql | Self::Mariadb | Self::Sqlite
        )
    }

    pub fn default_user(self) -> &'static str {
        match self {
            Self::Postgres => "postgres",
            Self::Mysql | Self::Mariadb => "root",
            Self::Mongodb => "",
            Self::Sqlite | Self::Redis => "",
        }
    }
}

/// How a connection should negotiate TLS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SslMode {
    Disable,
    #[default]
    Prefer,
    Require,
}

/// Everything needed to reach a server, minus the password, which lives in the OS
/// credential store.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionProfile {
    pub id: Uuid,
    #[serde(default)]
    pub name: String,
    pub kind: DatabaseKind,
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    /// Initial database to open. Unused for SQLite.
    #[serde(default)]
    pub database: String,
    /// Absolute path to the `.sqlite` file. Only used when `kind` is SQLite.
    #[serde(default)]
    pub file_path: String,
    #[serde(default)]
    pub ssl_mode: SslMode,
    #[serde(default)]
    pub save_password: bool,
    /// Refuses anything that is not a read — a guard rail for production.
    #[serde(default)]
    pub read_only: bool,
    /// Optional sidebar folder, e.g. "Production".
    #[serde(default)]
    pub folder: String,
    /// Hex colour (RRGGBB) used as an accent so prod connections look different.
    #[serde(default)]
    pub color_hex: Option<String>,
    #[serde(default = "default_timeout")]
    pub connect_timeout_seconds: u64,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub last_connected_at: Option<String>,
}

fn default_host() -> String {
    "127.0.0.1".to_string()
}

fn default_timeout() -> u64 {
    10
}

impl ConnectionProfile {
    pub fn new(kind: DatabaseKind) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: String::new(),
            kind,
            host: default_host(),
            port: kind.default_port(),
            username: kind.default_user().to_string(),
            database: String::new(),
            file_path: String::new(),
            ssl_mode: SslMode::default(),
            save_password: true,
            read_only: false,
            folder: String::new(),
            color_hex: None,
            connect_timeout_seconds: default_timeout(),
            notes: String::new(),
            created_at: Some(chrono::Utc::now().to_rfc3339()),
            last_connected_at: None,
        }
    }

    /// Credential-store key. Derived from the id so it survives a rename.
    pub fn credential_account(&self) -> String {
        format!("connection-{}", self.id)
    }

    pub fn display_name(&self) -> String {
        if !self.name.is_empty() {
            return self.name.clone();
        }
        if self.kind.is_file_based() {
            return std::path::Path::new(&self.file_path)
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| self.kind.display_name().to_string());
        }
        format!("{}@{}:{}", self.username, self.host, self.port)
    }

    /// Basic sanity check so the editor can disable Save on nonsense input.
    pub fn validation_error(&self) -> Option<String> {
        if self.kind.is_file_based() {
            return if self.file_path.is_empty() {
                Some("A database file must be selected.".into())
            } else {
                None
            };
        }
        if self.host.trim().is_empty() {
            return Some("Host is required.".into());
        }
        if self.port == 0 {
            return Some("Port must be between 1 and 65535.".into());
        }
        if self.kind == DatabaseKind::Postgres && self.database.trim().is_empty() {
            return Some("Database is required for PostgreSQL.".into());
        }
        None
    }
}

/// A single cell. Values arrive from every driver already rendered to text, which keeps
/// the grid, the exporters and the clipboard on one code path. `Null` stays distinct from
/// the empty string so `NULL` and `''` are never confused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", content = "v", rename_all = "lowercase")]
pub enum SqlValue {
    Null,
    Text(String),
}

impl SqlValue {
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    /// The raw text. NULL becomes an empty string; call `is_null` to tell them apart.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Null => "",
            Self::Text(s) => s,
        }
    }

    pub fn text(value: impl Into<String>) -> Self {
        Self::Text(value.into())
    }

    /// Builds a value from an optional string, which is the shape every driver hands back.
    pub fn from_option(value: Option<impl Into<String>>) -> Self {
        match value {
            Some(v) => Self::Text(v.into()),
            None => Self::Null,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnInfo {
    pub index: usize,
    pub name: String,
    /// Engine specific type name, e.g. `int4`, `VARCHAR`, `TEXT`.
    pub type_name: String,
    /// Source table when the server reports one. Needed for editable grids.
    pub table_name: Option<String>,
}

impl ColumnInfo {
    pub fn new(index: usize, name: impl Into<String>, type_name: impl Into<String>) -> Self {
        Self {
            index,
            name: name.into(),
            type_name: type_name.into(),
            table_name: None,
        }
    }

    /// Right-aligns numerics in the grid.
    pub fn is_numeric(&self) -> bool {
        let t = self.type_name.to_lowercase();
        [
            "int", "num", "dec", "float", "double", "real", "serial", "money",
        ]
        .iter()
        .any(|needle| t.contains(needle))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResultRow {
    pub id: usize,
    pub values: Vec<SqlValue>,
}

/// The outcome of one statement. A batch produces one of these per statement.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryResult {
    pub statement: String,
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<ResultRow>,
    /// Rows changed by INSERT/UPDATE/DELETE. `None` for SELECT-shaped results.
    pub rows_affected: Option<u64>,
    pub duration_ms: f64,
    /// Server notices, surfaced under the grid.
    pub messages: Vec<String>,
}

impl QueryResult {
    pub fn new(statement: impl Into<String>) -> Self {
        Self {
            statement: statement.into(),
            columns: Vec::new(),
            rows: Vec::new(),
            rows_affected: None,
            duration_ms: 0.0,
            messages: Vec::new(),
        }
    }

    pub fn has_result_set(&self) -> bool {
        !self.columns.is_empty()
    }
}

// MARK: - Schema

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TableKind {
    Table,
    View,
    MaterializedView,
    /// Redis keyspace or MongoDB collection.
    Collection,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableRef {
    pub database: String,
    /// Empty for engines with no schema level.
    #[serde(default)]
    pub schema: String,
    pub name: String,
    pub kind: TableKind,
}

impl TableRef {
    pub fn new(
        database: impl Into<String>,
        schema: impl Into<String>,
        name: impl Into<String>,
    ) -> Self {
        Self {
            database: database.into(),
            schema: schema.into(),
            name: name.into(),
            kind: TableKind::Table,
        }
    }

    /// `schema.name` where a schema exists, otherwise just the name.
    pub fn qualified_name(&self) -> String {
        if self.schema.is_empty() {
            self.name.clone()
        } else {
            format!("{}.{}", self.schema, self.name)
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnDefinition {
    pub name: String,
    pub data_type: String,
    pub is_nullable: bool,
    pub default_value: Option<String>,
    pub is_primary_key: bool,
    pub is_auto_increment: bool,
    pub comment: Option<String>,
    pub ordinal_position: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexDefinition {
    pub name: String,
    pub columns: Vec<String>,
    pub is_unique: bool,
    pub is_primary: bool,
    pub method: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForeignKeyDefinition {
    pub name: String,
    pub columns: Vec<String>,
    pub referenced_table: String,
    pub referenced_columns: Vec<String>,
    pub on_delete: Option<String>,
    pub on_update: Option<String>,
}

/// Everything the structure tab shows for one table.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableDetails {
    pub table: TableRef,
    pub columns: Vec<ColumnDefinition>,
    pub indexes: Vec<IndexDefinition>,
    pub foreign_keys: Vec<ForeignKeyDefinition>,
    pub estimated_row_count: Option<i64>,
    pub comment: Option<String>,
}

impl TableDetails {
    /// The columns that identify one row. Without these the grid refuses to edit.
    pub fn primary_key_columns(&self) -> Vec<String> {
        let from_columns: Vec<String> = self
            .columns
            .iter()
            .filter(|c| c.is_primary_key)
            .map(|c| c.name.clone())
            .collect();
        if !from_columns.is_empty() {
            return from_columns;
        }
        self.indexes
            .iter()
            .find(|i| i.is_primary)
            .map(|i| i.columns.clone())
            .unwrap_or_default()
    }
}

/// Reported on connect and shown in the sidebar footer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfo {
    pub product_name: String,
    pub version: String,
    pub current_database: String,
    pub current_user: String,
}
