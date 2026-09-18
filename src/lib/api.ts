// Typed wrappers over the Tauri command surface. Every call the UI makes goes through
// here, so the invoke names live in one place.

import { invoke } from "@tauri-apps/api/core";
import type {
  AppSettings,
  ConnectionProfile,
  HistoryEntry,
  QueryResult,
  ServerInfo,
  TableDetails,
  TableRef,
} from "./types";

export const api = {
  listProfiles: () => invoke<ConnectionProfile[]>("list_profiles"),
  saveProfile: (profile: ConnectionProfile, password?: string) =>
    invoke<ConnectionProfile[]>("save_profile", { profile, password: password ?? null }),
  deleteProfile: (id: string) => invoke<ConnectionProfile[]>("delete_profile", { id }),

  parseConnectionUrl: (url: string) =>
    invoke<{ profile: ConnectionProfile; password: string | null; warnings: string[] }>(
      "parse_connection_url",
      { url },
    ),
  looksLikeConnectionUrl: (text: string) =>
    invoke<boolean>("looks_like_connection_url", { text }),
  connectionUrlForProfile: (profile: ConnectionProfile) =>
    invoke<string>("connection_url_for_profile", { profile }),

  connect: (profile: ConnectionProfile, password?: string) =>
    invoke<ServerInfo>("connect", { profile, password: password ?? null }),
  testConnection: (profile: ConnectionProfile, password?: string) =>
    invoke<ServerInfo>("test_connection", { profile, password: password ?? null }),
  disconnect: (id: string) => invoke<void>("disconnect", { id }),

  executeSql: (id: string, sql: string, maxRows: number) =>
    invoke<QueryResult[]>("execute_sql", { id, sql, maxRows }),
  listDatabases: (id: string) => invoke<string[]>("list_databases", { id }),
  listSchemas: (id: string, database: string) =>
    invoke<string[]>("list_schemas", { id, database }),
  listTables: (id: string, database: string, schema: string) =>
    invoke<TableRef[]>("list_tables", { id, database, schema }),
  describeTable: (id: string, table: TableRef) =>
    invoke<TableDetails>("describe_table", { id, table }),
  createStatement: (id: string, table: TableRef) =>
    invoke<string>("create_statement", { id, table }),
  fetchRows: (
    id: string,
    table: TableRef,
    whereClause: string,
    orderBy: [string, boolean][],
    limit: number,
    offset: number,
  ) => invoke<QueryResult>("fetch_rows", { id, args: { table, whereClause, orderBy, limit, offset } }),
  countRows: (id: string, table: TableRef, whereClause: string) =>
    invoke<number>("count_rows", { id, table, whereClause }),

  getSettings: () => invoke<AppSettings>("get_settings"),
  setSettings: (settings: AppSettings) => invoke<void>("set_settings", { settings }),
  getHistory: () => invoke<HistoryEntry[]>("get_history"),
  addHistory: (entry: HistoryEntry, limit: number) =>
    invoke<HistoryEntry[]>("add_history", { entry, limit }),
  clearHistory: () => invoke<void>("clear_history"),
  dataDirectory: () => invoke<string>("data_directory"),
};
