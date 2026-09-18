import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowPathIcon,
  BoltIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  CircleStackIcon,
  ClipboardDocumentIcon,
  Cog6ToothIcon,
  CommandLineIcon,
  DocumentDuplicateIcon,
  ExclamationTriangleIcon,
  EyeIcon,
  FolderIcon,
  LinkIcon,
  LockClosedIcon,
  MagnifyingGlassIcon,
  PencilSquareIcon,
  PlayIcon,
  PowerIcon,
  ServerStackIcon,
  TableCellsIcon,
  TrashIcon,
  XMarkIcon,
} from "@heroicons/react/24/outline";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { api } from "./lib/api";
import { useUpdater } from "./lib/useUpdater";
import { UpdateBanner } from "./components/UpdateBanner";
import { ConnectionDialog } from "./components/ConnectionDialog";
import { SettingsDialog } from "./components/SettingsDialog";
import { SqlEditor } from "./components/SqlEditor";
import { ResultGrid } from "./components/ResultGrid";
import { ContextMenu, type MenuItem } from "./components/ContextMenu";
import { ConfirmDialog } from "./components/ConfirmDialog";
import {
  displayName,
  errorText,
  isRelational,
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
  schemas: Record<string, string[]>;
  tables: Record<string, TableRef[]>;
  expanded: Set<string>;
}

interface QueryTab {
  id: string;
  title: string;
  connectionId: string;
  sql: string;
  results: QueryResult[];
  resultIndex: number;
  error: string | null;
  running: boolean;
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
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  const [tabs, setTabs] = useState<QueryTab[]>([]);
  const [activeTabId, setActiveTabId] = useState<string | null>(null);

  const [editing, setEditing] = useState<{ profile: ConnectionProfile; urlMode: boolean } | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const [menu, setMenu] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const [confirm, setConfirm] = useState<{
    title: string;
    message: string;
    confirmLabel: string;
    onConfirm: () => void;
  } | null>(null);
  const [banner, setBanner] = useState<string | null>(null);

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

  const activeTab = tabs.find((t) => t.id === activeTabId) ?? null;
  const selectedProfile = profiles.find((p) => p.id === selectedId) ?? null;
  const activeConnectionId = activeTab?.connectionId ?? selectedId;
  const activeProfile = profiles.find((p) => p.id === activeConnectionId) ?? null;
  const activeSession = activeConnectionId ? sessions[activeConnectionId] : undefined;

  const patchTab = useCallback((id: string, changes: Partial<QueryTab>) => {
    setTabs((current) => current.map((tab) => (tab.id === id ? { ...tab, ...changes } : tab)));
  }, []);

  // MARK: - Connections

  const connect = useCallback(async (profile: ConnectionProfile) => {
    setBanner(null);
    try {
      const info = await api.connect(profile);
      const databases = await api.listDatabases(profile.id);
      const session: Session = { info, databases, schemas: {}, tables: {}, expanded: new Set() };
      setSessions((s) => ({ ...s, [profile.id]: session }));
      setSelectedId(profile.id);
      if (info.currentDatabase && databases.includes(info.currentDatabase)) {
        await toggleDatabase(profile.id, session, info.currentDatabase);
      }
    } catch (error) {
      setBanner(errorText(error));
    }
  }, []);

  const disconnect = useCallback(async (id: string) => {
    await api.disconnect(id);
    setSessions((s) => {
      const next = { ...s };
      delete next[id];
      return next;
    });
    setTabs((current) => current.filter((tab) => tab.connectionId !== id));
  }, []);

  const toggleDatabase = useCallback(
    async (connectionId: string, session: Session, database: string) => {
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
          const schemas = await api.listSchemas(connectionId, database);
          next.schemas[database] = schemas;
          if (schemas.length === 0) {
            next.tables[database] = await api.listTables(connectionId, database, "");
          } else {
            // A single schema, or "public", is the common case; open it without a click.
            const target = schemas.length === 1 ? schemas[0] : schemas.includes("public") ? "public" : null;
            if (target) {
              next.expanded.add(`${database}|${target}`);
              next.tables[`${database}|${target}`] = await api.listTables(connectionId, database, target);
            }
          }
        }
      }
      setSessions((s) => ({ ...s, [connectionId]: next }));
    },
    [],
  );

  const toggleSchema = useCallback(
    async (connectionId: string, session: Session, database: string, schema: string) => {
      const key = `${database}|${schema}`;
      const next: Session = { ...session, tables: { ...session.tables }, expanded: new Set(session.expanded) };
      if (next.expanded.has(key)) {
        next.expanded.delete(key);
      } else {
        next.expanded.add(key);
        if (!next.tables[key]) next.tables[key] = await api.listTables(connectionId, database, schema);
      }
      setSessions((s) => ({ ...s, [connectionId]: next }));
    },
    [],
  );

  const refreshTree = useCallback(
    async (connectionId: string) => {
      const session = sessions[connectionId];
      if (!session) return;
      const databases = await api.listDatabases(connectionId);
      setSessions((s) => ({
        ...s,
        [connectionId]: { ...session, databases, schemas: {}, tables: {}, expanded: new Set() },
      }));
    },
    [sessions],
  );

  const removeProfile = useCallback(
    (profile: ConnectionProfile) => {
      setConfirm({
        title: "Delete this connection?",
        message: `“${displayName(profile)}” is removed from MieSQL and its saved password is deleted from the system credential store.\n\nThe database itself is not touched.`,
        confirmLabel: "Delete",
        onConfirm: async () => {
          await disconnect(profile.id).catch(() => {});
          setProfiles(await api.deleteProfile(profile.id));
          setConfirm(null);
          if (selectedId === profile.id) setSelectedId(null);
        },
      });
    },
    [disconnect, selectedId],
  );

  const duplicateProfile = useCallback(async (profile: ConnectionProfile) => {
    const copy: ConnectionProfile = {
      ...profile,
      id: crypto.randomUUID(),
      name: `${displayName(profile)} copy`,
      // The copy does not inherit the original's stored password.
      savePassword: false,
      lastConnectedAt: null,
    };
    setProfiles(await api.saveProfile(copy));
  }, []);

  // MARK: - Tabs

  const newQueryTab = useCallback(
    (connectionId: string, sql = "") => {
      const tab: QueryTab = {
        id: crypto.randomUUID(),
        title: `Query ${tabs.filter((t) => t.connectionId === connectionId).length + 1}`,
        connectionId,
        sql,
        results: [],
        resultIndex: 0,
        error: null,
        running: false,
      };
      setTabs((current) => [...current, tab]);
      setActiveTabId(tab.id);
      return tab;
    },
    [tabs],
  );

  const closeTab = useCallback(
    (id: string) => {
      setTabs((current) => {
        const index = current.findIndex((t) => t.id === id);
        const next = current.filter((t) => t.id !== id);
        if (activeTabId === id) {
          setActiveTabId(next[index]?.id ?? next[next.length - 1]?.id ?? null);
        }
        return next;
      });
    },
    [activeTabId],
  );

  const openTable = useCallback(
    (profile: ConnectionProfile, table: TableRef) => {
      let starter: string;
      if (!isRelational(profile.kind)) {
        // A Redis namespace is browsed with SCAN, not selected from.
        starter = `SCAN 0 MATCH ${table.name}:* COUNT 100`;
      } else {
        const quote = profile.kind === "mysql" || profile.kind === "mariadb" ? "`" : '"';
        const qualified = [table.schema, table.name]
          .filter(Boolean)
          .map((part) => `${quote}${part}${quote}`)
          .join(".");
        starter = `SELECT *\nFROM ${qualified}\nLIMIT 200;`;
      }
      const tab = newQueryTab(profile.id, starter);
      setTabs((current) => current.map((t) => (t.id === tab.id ? { ...t, title: table.name } : t)));
    },
    [newQueryTab],
  );

  const run = useCallback(
    async (tab: QueryTab) => {
      if (!settings || tab.running) return;
      const script = tab.sql.trim();
      if (!script) return;

      patchTab(tab.id, { running: true, error: null });
      const started = performance.now();
      const profile = profiles.find((p) => p.id === tab.connectionId);
      try {
        const results = await api.executeSql(tab.connectionId, script, settings.maxResultRows);
        patchTab(tab.id, { results, resultIndex: 0, running: false });
        await api.addHistory(
          {
            id: crypto.randomUUID(),
            sql: script,
            connectionName: profile ? displayName(profile) : "",
            database: sessions[tab.connectionId]?.info.currentDatabase ?? "",
            executedAt: new Date().toISOString(),
            durationMs: performance.now() - started,
            succeeded: true,
            rowCount: results[0]?.rows.length ?? null,
            errorMessage: null,
          },
          settings.historyLimit,
        );
      } catch (error) {
        const message = errorText(error);
        patchTab(tab.id, { error: message, results: [], running: false });
        await api.addHistory(
          {
            id: crypto.randomUUID(),
            sql: script,
            connectionName: profile ? displayName(profile) : "",
            database: sessions[tab.connectionId]?.info.currentDatabase ?? "",
            executedAt: new Date().toISOString(),
            durationMs: performance.now() - started,
            succeeded: false,
            rowCount: null,
            errorMessage: message,
          },
          settings.historyLimit,
        );
      }
    },
    [patchTab, profiles, sessions, settings],
  );

  const completionSchema = useMemo(() => {
    const schema: Record<string, string[]> = {};
    if (!activeSession) return schema;
    for (const tables of Object.values(activeSession.tables)) {
      for (const table of tables) schema[table.name] = [];
    }
    return schema;
  }, [activeSession]);

  const connectionMenu = useCallback(
    (profile: ConnectionProfile): MenuItem[] => {
      const connected = Boolean(sessions[profile.id]);
      return [
        connected
          ? { label: "Disconnect", icon: PowerIcon, onSelect: () => void disconnect(profile.id) }
          : { label: "Connect", icon: BoltIcon, onSelect: () => void connect(profile) },
        {
          label: "New Query",
          icon: CommandLineIcon,
          disabled: !connected,
          onSelect: () => newQueryTab(profile.id),
        },
        {
          label: "Refresh",
          icon: ArrowPathIcon,
          disabled: !connected,
          onSelect: () => void refreshTree(profile.id),
          separatorBefore: true,
        },
        {
          label: "Edit Connection…",
          icon: PencilSquareIcon,
          onSelect: () => setEditing({ profile, urlMode: false }),
          separatorBefore: true,
        },
        { label: "Duplicate", icon: DocumentDuplicateIcon, onSelect: () => void duplicateProfile(profile) },
        {
          label: "Copy Connection URL",
          icon: ClipboardDocumentIcon,
          onSelect: async () => {
            // The password is deliberately left out, so this is safe to paste anywhere.
            await writeText(await api.connectionUrlForProfile(profile));
            setBanner("Connection URL copied. The password is not included.");
          },
        },
        {
          label: "Delete Connection…",
          icon: TrashIcon,
          danger: true,
          separatorBefore: true,
          onSelect: () => removeProfile(profile),
        },
      ];
    },
    [connect, disconnect, duplicateProfile, newQueryTab, refreshTree, removeProfile, sessions],
  );

  const visibleProfiles = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    const matching = needle
      ? profiles.filter(
          (p) =>
            displayName(p).toLowerCase().includes(needle) ||
            subtitle(p).toLowerCase().includes(needle),
        )
      : profiles;
    return [...matching].sort((a, b) => {
      if (a.folder !== b.folder) return a.folder.localeCompare(b.folder);
      return displayName(a).localeCompare(displayName(b));
    });
  }, [filter, profiles]);

  if (!settings) return <div className="empty">Loading…</div>;

  const result = activeTab?.results[activeTab.resultIndex];

  return (
    <div className="app">
      <UpdateBanner
        stage={updater.stage}
        dismissed={updater.dismissed}
        onDismiss={updater.dismiss}
        onDownload={updater.startDownload}
        onInstall={updater.installAndRestart}
      />

      <div className="chrome">
        <button className="chrome-button" onClick={() => setEditing({ profile: newProfile(), urlMode: false })}>
          <ServerStackIcon className="icon-lg" />
          Connection
        </button>
        <button className="chrome-button" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>
          <LinkIcon className="icon-lg" />
          From URL
        </button>
        <div className="chrome-divider" />
        <button
          className="chrome-button"
          disabled={!activeConnectionId || !sessions[activeConnectionId]}
          onClick={() => activeConnectionId && newQueryTab(activeConnectionId)}
        >
          <CommandLineIcon className="icon-lg" />
          Query
        </button>
        <button
          className="chrome-button"
          disabled={!activeTab || activeTab.running}
          onClick={() => activeTab && void run(activeTab)}
        >
          <PlayIcon className="icon-lg" />
          Run
        </button>
        <button
          className="chrome-button"
          disabled={!activeConnectionId || !sessions[activeConnectionId]}
          onClick={() => activeConnectionId && void refreshTree(activeConnectionId)}
        >
          <ArrowPathIcon className="icon-lg" />
          Refresh
        </button>
        <div className="spacer" />
        <button className="chrome-button" onClick={() => setShowSettings(true)}>
          <Cog6ToothIcon className="icon-lg" />
          Settings
        </button>
      </div>

      {banner && (
        <div className="error-banner">
          <ExclamationTriangleIcon className="icon" />
          <div style={{ flex: 1 }}>{banner}</div>
          <button className="quiet" onClick={() => setBanner(null)}>
            <XMarkIcon className="icon" />
          </button>
        </div>
      )}

      <div className="body">
        <aside className="sidebar">
          <div className="sidebar-search">
            <div style={{ position: "relative", display: "flex", alignItems: "center" }}>
              <MagnifyingGlassIcon
                className="icon"
                style={{ position: "absolute", left: 6, color: "var(--text-faint)" }}
              />
              <input
                value={filter}
                placeholder="Filter connections"
                style={{ paddingLeft: 26 }}
                onChange={(e) => setFilter(e.target.value)}
              />
            </div>
          </div>

          <div className="sidebar-body">
            {profiles.length === 0 && (
              <div className="empty" style={{ paddingTop: 36 }}>
                <ServerStackIcon className="icon-xl" />
                <div>No connections yet</div>
                <div className="hint">Everything stays on this device.</div>
                <button className="primary" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>
                  <LinkIcon className="icon" />
                  Add from URL
                </button>
              </div>
            )}

            {visibleProfiles.map((profile) => {
              const session = sessions[profile.id];
              return (
                <div key={profile.id}>
                  <div
                    className={`tree-row${selectedId === profile.id ? " selected" : ""}`}
                    onClick={() => setSelectedId(profile.id)}
                    onDoubleClick={() => (session ? void disconnect(profile.id) : void connect(profile))}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      setSelectedId(profile.id);
                      setMenu({ x: e.clientX, y: e.clientY, items: connectionMenu(profile) });
                    }}
                  >
                    <span
                      className="status-dot"
                      title={session ? "Connected" : "Not connected"}
                      style={{ background: session ? "var(--success)" : "var(--text-faint)" }}
                    />
                    <ServerStackIcon className="icon" style={{ color: KIND_COLOR[profile.kind] }} />
                    <span className="label">
                      <div style={{ overflow: "hidden", textOverflow: "ellipsis" }}>{displayName(profile)}</div>
                      <div className="sub">{subtitle(profile)}</div>
                    </span>
                    {profile.readOnly && <LockClosedIcon className="icon" style={{ color: "var(--text-faint)" }} />}
                    <span className="trailing">
                      <button
                        className="quiet"
                        title="Edit connection"
                        onClick={(e) => {
                          e.stopPropagation();
                          setEditing({ profile, urlMode: false });
                        }}
                      >
                        <PencilSquareIcon className="icon" />
                      </button>
                      <button
                        className="quiet"
                        title="Delete connection"
                        onClick={(e) => {
                          e.stopPropagation();
                          removeProfile(profile);
                        }}
                      >
                        <TrashIcon className="icon" />
                      </button>
                    </span>
                  </div>

                  {session &&
                    session.databases.map((database) => {
                      const open = session.expanded.has(database);
                      return (
                        <div key={database}>
                          <div
                            className="tree-row indent-1"
                            onClick={() => void toggleDatabase(profile.id, session, database)}
                          >
                            <span className="disclosure">
                              {open ? <ChevronDownIcon /> : <ChevronRightIcon />}
                            </span>
                            <CircleStackIcon className="icon" style={{ color: "var(--text-muted)" }} />
                            <span className="label">{database}</span>
                          </div>

                          {open && (
                            <>
                              {(session.schemas[database] ?? []).map((schema) => {
                                const key = `${database}|${schema}`;
                                const schemaOpen = session.expanded.has(key);
                                return (
                                  <div key={schema}>
                                    <div
                                      className="tree-row indent-2"
                                      onClick={() => void toggleSchema(profile.id, session, database, schema)}
                                    >
                                      <span className="disclosure">
                                        {schemaOpen ? <ChevronDownIcon /> : <ChevronRightIcon />}
                                      </span>
                                      <FolderIcon className="icon" style={{ color: "var(--text-muted)" }} />
                                      <span className="label">{schema}</span>
                                    </div>
                                    {schemaOpen &&
                                      (session.tables[key] ?? []).map((table) => (
                                        <div
                                          className="tree-row indent-3"
                                          key={table.name}
                                          onDoubleClick={() => openTable(profile, table)}
                                        >
                                          {table.kind === "view" ? (
                                            <EyeIcon className="icon" style={{ color: "var(--text-faint)" }} />
                                          ) : (
                                            <TableCellsIcon className="icon" style={{ color: "var(--text-faint)" }} />
                                          )}
                                          <span className="label">{table.name}</span>
                                        </div>
                                      ))}
                                  </div>
                                );
                              })}

                              {(session.schemas[database]?.length ?? 0) === 0 &&
                                (session.tables[database] ?? []).map((table) => (
                                  <div
                                    className="tree-row indent-2"
                                    key={table.name}
                                    onDoubleClick={() => openTable(profile, table)}
                                  >
                                    {table.kind === "view" ? (
                                      <EyeIcon className="icon" style={{ color: "var(--text-faint)" }} />
                                    ) : (
                                      <TableCellsIcon className="icon" style={{ color: "var(--text-faint)" }} />
                                    )}
                                    <span className="label">{table.name}</span>
                                  </div>
                                ))}
                            </>
                          )}
                        </div>
                      );
                    })}
                </div>
              );
            })}
          </div>

          <div className="sidebar-footer">
            {activeSession ? (
              <>
                <BoltIcon className="icon" />
                {activeSession.info.productName} {activeSession.info.version}
              </>
            ) : (
              "A fast, native SQL client"
            )}
          </div>
        </aside>

        <main className="main">
          {tabs.length > 0 && (
            <div className="tabs">
              {tabs.map((tab) => (
                <button
                  key={tab.id}
                  className={`tab${tab.id === activeTabId ? " active" : ""}`}
                  onClick={() => setActiveTabId(tab.id)}
                >
                  <CommandLineIcon className="icon" />
                  {tab.title}
                  <span
                    className="close"
                    onClick={(e) => {
                      e.stopPropagation();
                      closeTab(tab.id);
                    }}
                  >
                    <XMarkIcon className="icon" style={{ width: 12, height: 12 }} />
                  </span>
                </button>
              ))}
            </div>
          )}

          {!activeTab ? (
            <div className="empty">
              <CommandLineIcon className="icon-xl" />
              <div>Nothing open</div>
              <div className="hint">
                {selectedProfile && !sessions[selectedProfile.id]
                  ? "Connect to the selected database, then open a query."
                  : "Connect to a database and open a query, or double-click a table."}
              </div>
              {selectedProfile && !sessions[selectedProfile.id] && (
                <button className="primary" onClick={() => void connect(selectedProfile)}>
                  <BoltIcon className="icon" />
                  Connect
                </button>
              )}
            </div>
          ) : (
            <>
              <div className="query-toolbar">
                <button
                  className="primary"
                  disabled={activeTab.running}
                  onClick={() => void run(activeTab)}
                >
                  <PlayIcon className="icon" />
                  {activeTab.running ? "Running…" : "Run"}
                </button>
                <span className="hint">⌘↩</span>
                <div className="spacer" />
                {activeProfile?.readOnly && (
                  <span className="hint" style={{ display: "flex", alignItems: "center", gap: 4 }}>
                    <LockClosedIcon className="icon" />
                    Read-only
                  </span>
                )}
                {activeSession && <span className="hint">{activeSession.info.currentDatabase}</span>}
              </div>

              <div className="editor-pane">
                <SqlEditor
                  value={activeTab.sql}
                  onChange={(sql) => patchTab(activeTab.id, { sql })}
                  onRun={() => void run(activeTab)}
                  kind={activeProfile?.kind ?? "postgres"}
                  fontSize={settings.editorFontSize}
                  showLineNumbers={settings.showLineNumbers}
                  wrapLines={settings.wrapLongLines}
                  schema={completionSchema}
                />
              </div>

              <div className="result-pane">
                {activeTab.error && (
                  <div className="error-banner">
                    <ExclamationTriangleIcon className="icon" />
                    <div style={{ flex: 1 }}>{activeTab.error}</div>
                  </div>
                )}

                {activeTab.results.length > 1 && (
                  <div className="query-toolbar">
                    {activeTab.results.map((r, index) => (
                      <button
                        key={index}
                        className={index === activeTab.resultIndex ? "primary" : ""}
                        onClick={() => patchTab(activeTab.id, { resultIndex: index })}
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
                    <TableCellsIcon className="icon-xl" />
                    {result
                      ? result.rowsAffected !== null
                        ? `${result.rowsAffected} row${result.rowsAffected === 1 ? "" : "s"} affected`
                        : "Statement completed with no result set."
                      : activeTab.error
                        ? "The statement did not run."
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
            </>
          )}
        </main>
      </div>

      {menu && <ContextMenu x={menu.x} y={menu.y} items={menu.items} onClose={() => setMenu(null)} />}

      {confirm && (
        <ConfirmDialog
          title={confirm.title}
          message={confirm.message}
          confirmLabel={confirm.confirmLabel}
          destructive
          onConfirm={confirm.onConfirm}
          onCancel={() => setConfirm(null)}
        />
      )}

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
          onChange={(next) => {
            setSettings(next);
            void api.setSettings(next);
          }}
          updater={updater}
          onClose={() => setShowSettings(false)}
        />
      )}
    </div>
  );
}
