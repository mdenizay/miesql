// Mirrors the Rust types in src-tauri/src/models.rs. Kept hand-written rather than
// generated so the shape the UI works with stays readable at a glance.

export type DatabaseKind = "postgres" | "mysql" | "mariadb" | "sqlite" | "redis" | "mongodb";
export type SslMode = "disable" | "prefer" | "require";

export interface ConnectionProfile {
  id: string;
  name: string;
  kind: DatabaseKind;
  host: string;
  port: number;
  username: string;
  database: string;
  filePath: string;
  sslMode: SslMode;
  savePassword: boolean;
  readOnly: boolean;
  folder: string;
  colorHex: string | null;
  connectTimeoutSeconds: number;
  notes: string;
  createdAt: string | null;
  lastConnectedAt: string | null;
}

/** NULL is a distinct variant, never an empty string. */
export type SqlValue = { t: "null" } | { t: "text"; v: string };

export function isNull(value: SqlValue): boolean {
  return value.t === "null";
}

export function valueText(value: SqlValue): string {
  return value.t === "text" ? value.v : "";
}

export interface ColumnInfo {
  index: number;
  name: string;
  typeName: string;
  tableName: string | null;
}

export interface ResultRow {
  id: number;
  values: SqlValue[];
}

export interface QueryResult {
  statement: string;
  columns: ColumnInfo[];
  rows: ResultRow[];
  rowsAffected: number | null;
  durationMs: number;
  messages: string[];
}

export type TableKind = "table" | "view" | "materializedView" | "collection";

export interface TableRef {
  database: string;
  schema: string;
  name: string;
  kind: TableKind;
}

export interface ColumnDefinition {
  name: string;
  dataType: string;
  isNullable: boolean;
  defaultValue: string | null;
  isPrimaryKey: boolean;
  isAutoIncrement: boolean;
  comment: string | null;
  ordinalPosition: number;
}

export interface IndexDefinition {
  name: string;
  columns: string[];
  isUnique: boolean;
  isPrimary: boolean;
  method: string | null;
}

export interface ForeignKeyDefinition {
  name: string;
  columns: string[];
  referencedTable: string;
  referencedColumns: string[];
  onDelete: string | null;
  onUpdate: string | null;
}

export interface TableDetails {
  table: TableRef;
  columns: ColumnDefinition[];
  indexes: IndexDefinition[];
  foreignKeys: ForeignKeyDefinition[];
  estimatedRowCount: number | null;
  comment: string | null;
}

export interface ServerInfo {
  productName: string;
  version: string;
  currentDatabase: string;
  currentUser: string;
}

export interface AppSettings {
  appearance: "system" | "light" | "dark";
  languageCode: string;
  editorFontSize: number;
  gridFontSize: number;
  pageSize: number;
  maxResultRows: number;
  confirmDestructiveStatements: boolean;
  historyLimit: number;
  showLineNumbers: boolean;
  wrapLongLines: boolean;
  checkForUpdates: boolean;
  downloadUpdatesAutomatically: boolean;
}

export interface HistoryEntry {
  id: string;
  sql: string;
  connectionName: string;
  database: string;
  executedAt: string;
  durationMs: number;
  succeeded: boolean;
  rowCount: number | null;
  errorMessage: string | null;
}

/** What every command rejects with: the server's own wording, not ours. */
export interface DbError {
  message: string;
  code: string | null;
  detail: string | null;
}

export function errorText(error: unknown): string {
  if (error && typeof error === "object" && "message" in error) {
    const e = error as DbError;
    const code = e.code ? `[${e.code}] ` : "";
    return `${code}${e.message}${e.detail ? `\n${e.detail}` : ""}`;
  }
  return String(error);
}

export const DEFAULT_PORTS: Record<DatabaseKind, number> = {
  postgres: 5432,
  mysql: 3306,
  mariadb: 3306,
  sqlite: 0,
  redis: 6379,
  mongodb: 27017,
};

export function displayName(profile: ConnectionProfile): string {
  if (profile.name) return profile.name;
  if (profile.kind === "sqlite") return profile.filePath.split("/").pop() ?? "SQLite";
  return `${profile.username}@${profile.host}:${profile.port}`;
}

export function subtitle(profile: ConnectionProfile): string {
  if (profile.kind === "sqlite") return profile.filePath;
  return `${profile.host}:${profile.port}${profile.database ? `/${profile.database}` : ""}`;
}
