import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "./lib/api";
import { useUpdater } from "./lib/useUpdater";
import { UpdateBanner } from "./components/UpdateBanner";
import { ConnectionDialog } from "./components/ConnectionDialog";
import { SqlEditor } from "./components/SqlEditor";
import { ResultGrid } from "./components/ResultGrid";
import { SettingsDialog } from "./components/SettingsDialog";
import {
  displayName,
  errorText,
  subtitle,
  type AppSettings,
  type ConnectionProfile,
  type QueryResult,
  type ServerInfo,
  type TableRef,
} from "./lib/types";

interface Session {
  info: ServerInfo;
  databases: string[];
  /** database → schemas, empty for engines with no schema level. */
  schemas: Record<string, string[]>;
  /** "database" or "database|schema" → tables. */
  tables: Record<string, TableRef[]>;
  expanded: Set<string>;
}

const KIND_COLOR: Record<string, string> = {
  postgres: "#3b82f6",
  mysql: "#e0a33c",
  mariadb: "#a855f7",
  sqlite: "#14b8a6",
  redis: "#ef4444",
  mongodb: "#22c55e",
};

function newProfile(): ConnectionProfile {
  return {
    id: crypto.randomUUID(),
    name: "",
    kind: "postgres",
    host: "127.0.0.1",
    port: 5432,
    username: "postgres",
    database: "",
    filePath: "",
    sslMode: "prefer",
    savePassword: true,
    readOnly: false,
    folder: "",
    colorHex: null,
    connectTimeoutSeconds: 10,
    notes: "",
    createdAt: new Date().toISOString(),
    lastConnectedAt: null,
  };
}

export function App() {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [profiles, setProfiles] = useState<ConnectionProfile[]>([]);
  const [sessions, setSessions] = useState<Record<string, Session>>({});
  const [activeId, setActiveId] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ profile: ConnectionProfile; urlMode: boolean } | null>(null);
  const [showSettings, setShowSettings] = useState(false);

  const [sql, setSql] = useState("SELECT 1;");
  const [results, setResults] = useState<QueryResult[]>([]);
  const [resultIndex, setResultIndex] = useState(0);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const updater = useUpdater({
    enabled: settings?.checkForUpdates ?? false,
    downloadAutomatically: settings?.downloadUpdatesAutomatically ?? true,
  });

  useEffect(() => {
    void (async () => {
      setSettings(await api.getSettings());
      setProfiles(await api.listProfiles());
    })();
  }, []);

  // Theme follows the setting, or the OS when it is set to system.
  useEffect(() => {
    if (!settings) return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      const dark = settings.appearance === "dark" || (settings.appearance === "system" && media.matches);
      document.documentElement.dataset.theme = dark ? "dark" : "light";
    };
    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [settings]);

  const activeSession = activeId ? sessions[activeId] : undefined;
  const activeProfile = profiles.find((p) => p.id === activeId);

  const connect = useCallback(async (profile: ConnectionProfile) => {
    setError(null);
    try {
      const info = await api.connect(profile);
      const databases = await api.listDatabases(profile.id);
      const session: Session = {
        info,
        databases,
        schemas: {},
        tables: {},
        expanded: new Set(),
      };
      setSessions((s) => ({ ...s, [profile.id]: session }));
      setActiveId(profile.id);
      // Open the database the connection landed in, so the tree is useful immediately.
      if (info.currentDatabase && databases.includes(info.currentDatabase)) {
        await expandDatabase(profile, session, info.currentDatabase);
      }
    } catch (e) {
      setError(errorText(e));
    }
  }, []);

  const expandDatabase = useCallback(
    async (profile: ConnectionProfile, session: Session, database: string) => {
      const next: Session = {
        ...session,
        schemas: { ...session.schemas },
        tables: { ...session.tables },
        expanded: new Set(session.expanded),
      };
      if (next.expanded.has(database)) {
        next.expanded.delete(database);
      } else {
        next.expanded.add(database);
        if (!next.schemas[database]) {
          const schemas = await api.listSchemas(profile.id, database);
          next.schemas[database] = schemas;
          if (schemas.length === 0) {
            next.tables[database] = await api.listTables(profile.id, database, "");
          } else {
            // A single schema, or "public", is the common case; open it without a click.
            const target = schemas.length === 1 ? schemas[0] : schemas.includes("public") ? "public" : null;
            if (target) {
              next.expanded.add(`${database}|${target}`);
              next.tables[`${database}|${target}`] = await api.listTables(profile.id, database, target);
            }
          }
        }
      }
      setSessions((s) => ({ ...s, [profile.id]: next }));
    },
    [],
  );

  const expandSchema = useCallback(
    async (profile: ConnectionProfile, session: Session, database: string, schema: string) => {
      const key = `${database}|${schema}`;
      const next: Session = { ...session, tables: { ...session.tables }, expanded: new Set(session.expanded) };
      if (next.expanded.has(key)) {
        next.expanded.delete(key);
      } else {
        next.expanded.add(key);
        if (!next.tables[key]) {
          next.tables[key] = await api.listTables(profile.id, database, schema);
        }
      }
      setSessions((s) => ({ ...s, [profile.id]: next }));
    },
    [],
  );

  const run = useCallback(async () => {
    if (!activeId || !settings || running) return;
    const script = sql.trim();
    if (!script) return;

    setRunning(true);
    setError(null);
    const started = performance.now();
    try {
      const next = await api.executeSql(activeId, script, settings.maxResultRows);
      setResults(next);
      setResultIndex(0);
      await api.addHistory(
        {
          id: crypto.randomUUID(),
          sql: script,
          connectionName: activeProfile ? displayName(activeProfile) : "",
          database: activeSession?.info.currentDatabase ?? "",
          executedAt: new Date().toISOString(),
          durationMs: performance.now() - started,
          succeeded: true,
          rowCount: next[0]?.rows.length ?? null,
          errorMessage: null,
        },
        settings.historyLimit,
      );
    } catch (e) {
      const message = errorText(e);
      setError(message);
      setResults([]);
      await api.addHistory(
        {
          id: crypto.randomUUID(),
          sql: script,
          connectionName: activeProfile ? displayName(activeProfile) : "",
          database: activeSession?.info.currentDatabase ?? "",
          executedAt: new Date().toISOString(),
          durationMs: performance.now() - started,
          succeeded: false,
          rowCount: null,
          errorMessage: message,
        },
        settings.historyLimit,
      );
    } finally {
      setRunning(false);
    }
  }, [activeId, activeProfile, activeSession, settings, sql, running]);

  /** Table and column names for the editor's completion. */
  const completionSchema = useMemo(() => {
    const schema: Record<string, string[]> = {};
    if (!activeSession) return schema;
    for (const tables of Object.values(activeSession.tables)) {
      for (const table of tables) schema[table.name] = [];
    }
    return schema;
  }, [activeSession]);

  const openTable = useCallback(
    async (table: TableRef) => {
      if (!activeProfile) return;
      const quote = activeProfile.kind === "mysql" || activeProfile.kind === "mariadb" ? "`" : '"';
      const qualified = [table.schema, table.name]
        .filter(Boolean)
        .map((part) => `${quote}${part}${quote}`)
        .join(".");
      setSql(`SELECT *\nFROM ${qualified}\nLIMIT 200;`);
    },
    [activeProfile],
  );

  const result = results[resultIndex];

  if (!settings) return <div className="empty">Loading…</div>;

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="sidebar-header">
          <span className="sidebar-title">Connections</span>
          <button className="quiet" title="New connection" onClick={() => setEditing({ profile: newProfile(), urlMode: false })}>+</button>
          <button className="quiet" title="New connection from URL" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>⧉</button>
          <button className="quiet" title="Settings" onClick={() => setShowSettings(true)}>⚙</button>
        </div>

        <div className="sidebar-body">
          {profiles.length === 0 && (
            <div className="empty" style={{ height: "auto", paddingTop: 32 }}>
              <div>No connections yet.</div>
              <div className="hint">Everything stays on this device.</div>
              <button className="primary" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>
                Add from URL
              </button>
            </div>
          )}

          {profiles.map((profile) => {
            const session = sessions[profile.id];
            return (
              <div key={profile.id}>
                <div
                  className={`tree-row${activeId === profile.id ? " selected" : ""}`}
                  onClick={() => setActiveId(profile.id)}
                  onDoubleClick={() => (session ? undefined : void connect(profile))}
                >
                  <span className="dot" style={{ background: session ? "var(--success)" : "var(--text-faint)" }} />
                  <span className="dot" style={{ background: KIND_COLOR[profile.kind] ?? "var(--accent)" }} />
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <div className="name">{displayName(profile)}</div>
                    <div className="sub">{subtitle(profile)}</div>
                  </span>
                  {profile.readOnly && <span className="hint" title="Read-only">🔒</span>}
                  {!session && <button className="quiet" onClick={(e) => { e.stopPropagation(); void connect(profile); }}>Connect</button>}
                  <button className="quiet" title="Edit" onClick={(e) => { e.stopPropagation(); setEditing({ profile, urlMode: false }); }}>✎</button>
                </div>

                {session && (
                  <div className="tree-children">
                    {session.databases.map((database) => (
                      <div key={database}>
                        <div className="tree-row" onClick={() => void expandDatabase(profile, session, database)}>
                          <span className="chevron">{session.expanded.has(database) ? "▾" : "▸"}</span>
                          <span className="name">{database}</span>
                        </div>
                        {session.expanded.has(database) && (
                          <div className="tree-children">
                            {(session.schemas[database] ?? []).map((schema) => (
                              <div key={schema}>
                                <div className="tree-row" onClick={() => void expandSchema(profile, session, database, schema)}>
                                  <span className="chevron">{session.expanded.has(`${database}|${schema}`) ? "▾" : "▸"}</span>
                                  <span className="name">{schema}</span>
                                </div>
                                {session.expanded.has(`${database}|${schema}`) && (
                                  <div className="tree-children">
                                    {(session.tables[`${database}|${schema}`] ?? []).map((table) => (
                                      <div className="tree-row" key={table.name} onClick={() => void openTable(table)}>
                                        <span className="chevron" />
                                        <span className="name">{table.name}</span>
                                      </div>
                                    ))}
                                  </div>
                                )}
                              </div>
                            ))}
                            {(session.schemas[database]?.length ?? 0) === 0 &&
                              (session.tables[database] ?? []).map((table) => (
                                <div className="tree-row" key={table.name} onClick={() => void openTable(table)}>
                                  <span className="chevron" />
                                  <span className="name">{table.name}</span>
                                </div>
                              ))}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <div className="sidebar-footer">
          {activeSession
            ? `${activeSession.info.productName} ${activeSession.info.version}`
            : "A fast, native SQL client"}
        </div>
      </aside>

      <main className="main">
        <UpdateBanner
          stage={updater.stage}
          dismissed={updater.dismissed}
          onDismiss={updater.dismiss}
          onDownload={updater.startDownload}
          onInstall={updater.installAndRestart}
        />

        <div className="toolbar">
          <button className="primary" onClick={() => void run()} disabled={!activeId || running}>
            {running ? "Running…" : "Run"}
          </button>
          <span className="hint">⌘↩</span>
          <div className="spacer" />
          {activeProfile?.readOnly && <span className="hint">Read-only</span>}
          {activeSession && <span className="hint">{activeSession.info.currentDatabase}</span>}
        </div>

        <div className="editor-pane">
          <SqlEditor
            value={sql}
            onChange={setSql}
            onRun={() => void run()}
            kind={activeProfile?.kind ?? "postgres"}
            fontSize={settings.editorFontSize}
            showLineNumbers={settings.showLineNumbers}
            wrapLines={settings.wrapLongLines}
            schema={completionSchema}
          />
        </div>

        <div className="result-pane">
          {error && <div className="error-banner">{error}</div>}

          {results.length > 1 && (
            <div className="toolbar">
              {results.map((r, index) => (
                <button
                  key={index}
                  className={index === resultIndex ? "primary" : ""}
                  onClick={() => setResultIndex(index)}
                >
                  {index + 1}. {r.statement.trim().split(/\s+/)[0]?.toUpperCase()}
                </button>
              ))}
            </div>
          )}

          {result && result.columns.length > 0 ? (
            <ResultGrid columns={result.columns} rows={result.rows} fontSize={settings.gridFontSize} />
          ) : (
            <div className="empty">
              {!activeId
                ? "Connect to a database to run a query."
                : result
                  ? result.rowsAffected !== null
                    ? `${result.rowsAffected} row${result.rowsAffected === 1 ? "" : "s"} affected`
                    : "Statement completed with no result set."
                  : error
                    ? ""
                    : "Run a query to see results."}
            </div>
          )}

          {result && (
            <div className="status-bar">
              <span>
                {result.columns.length > 0
                  ? `${result.rows.length} row${result.rows.length === 1 ? "" : "s"}`
                  : "OK"}
                {" · "}
                {result.durationMs.toFixed(0)} ms
              </span>
              {result.messages.map((message) => (
                <span key={message} className="hint">{message}</span>
              ))}
            </div>
          )}
        </div>
      </main>

      {editing && (
        <ConnectionDialog
          initial={editing.profile}
          startInUrlMode={editing.urlMode}
          onSaved={setProfiles}
          onClose={() => setEditing(null)}
        />
      )}

      {showSettings && (
        <SettingsDialog
          settings={settings}
          onChange={(next) => { setSettings(next); void api.setSettings(next); }}
          updater={updater}
          onClose={() => setShowSettings(false)}
        />
      )}
    </div>
  );
}
