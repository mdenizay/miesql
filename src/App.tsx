import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowPathIcon,
  ArrowUpTrayIcon,
  BoltIcon,
  BookmarkIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  CircleStackIcon,
  ClipboardDocumentIcon,
  ClockIcon,
  Cog6ToothIcon,
  CommandLineIcon,
  DocumentArrowDownIcon,
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
  StopIcon,
  TableCellsIcon,
  TrashIcon,
  XMarkIcon,
} from "@heroicons/react/24/outline";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import { api } from "./lib/api";
import { makeTranslator, type LanguageCode } from "./lib/i18n";
import { useUpdater } from "./lib/useUpdater";
import { UpdateBanner } from "./components/UpdateBanner";
import { ConnectionDialog } from "./components/ConnectionDialog";
import { SettingsDialog } from "./components/SettingsDialog";
import { SqlEditor } from "./components/SqlEditor";
import { ResultGrid } from "./components/ResultGrid";
import { TableTab } from "./components/TableTab";
import { HistoryPanel } from "./components/HistoryPanel";
import { ContextMenu, type MenuItem } from "./components/ContextMenu";
import { ConfirmDialog } from "./components/ConfirmDialog";
import { CsvImportSheet, DumpSheet, RunScriptSheet } from "./components/TransferSheets";
import {
  displayName,
  errorText,
  isRelational,
  subtitle,
  type AppSettings,
  type ConnectionProfile,
  type ExportFormat,
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

type Tab =
  | {
      id: string;
      kind: "query";
      connectionId: string;
      title: string;
      sql: string;
      results: QueryResult[];
      resultIndex: number;
      error: string | null;
      running: boolean;
    }
  | { id: string; kind: "table"; connectionId: string; title: string; table: TableRef };

const KIND_COLOR: Record<string, string> = {
  postgres: "#3b82f6",
  mysql: "#e0a33c",
  mariadb: "#a855f7",
  sqlite: "#14b8a6",
  redis: "#ef4444",
  mongodb: "#22c55e",
};

const EXPORT_FORMATS: ExportFormat[] = ["csv", "tsv", "json", "sqlInsert", "markdown"];

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
    sshEnabled: false,
    sshHost: "",
    sshPort: 22,
    sshUsername: "",
    sshKeyPath: "",
  };
}

export function App() {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [profiles, setProfiles] = useState<ConnectionProfile[]>([]);
  const [sessions, setSessions] = useState<Record<string, Session>>({});
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [credentialStore, setCredentialStore] = useState(true);

  const [tabs, setTabs] = useState<Tab[]>([]);
  const [activeTabId, setActiveTabId] = useState<string | null>(null);

  const [editing, setEditing] = useState<{ profile: ConnectionProfile; urlMode: boolean } | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const [dumpFor, setDumpFor] = useState<{ connectionId: string; database: string } | null>(null);
  const [scriptFor, setScriptFor] = useState<string | null>(null);
  const [importFor, setImportFor] = useState<{ connectionId: string; table: TableRef } | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const [confirm, setConfirm] = useState<{
    title: string;
    message: string;
    confirmLabel: string;
    onConfirm: () => void;
  } | null>(null);
  const [banner, setBanner] = useState<string | null>(null);
  // The text highlighted in the editor, so ⌘↩ and the Run button both run the selection
  // when there is one — the standard way to try part of a longer script.
  const [selectedSql, setSelectedSql] = useState("");
  const [completionSchema, setCompletionSchema] = useState<Record<string, string[]>>({});
  const [namingSnippet, setNamingSnippet] = useState<string | null>(null);

  const t = useMemo(
    () => makeTranslator((settings?.languageCode ?? "system") as LanguageCode),
    [settings?.languageCode],
  );

  const updater = useUpdater({
    enabled: settings?.checkForUpdates ?? false,
    downloadAutomatically: settings?.downloadUpdatesAutomatically ?? true,
  });

  useEffect(() => {
    void (async () => {
      setSettings(await api.getSettings());
      setProfiles(await api.listProfiles());
      setCredentialStore(await api.credentialStoreAvailable().catch(() => true));
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

  const activeTab = tabs.find((tab) => tab.id === activeTabId) ?? null;
  const activeConnectionId = activeTab?.connectionId ?? selectedId;
  const activeProfile = profiles.find((p) => p.id === activeConnectionId) ?? null;
  const activeSession = activeConnectionId ? sessions[activeConnectionId] : undefined;
  const selectedProfile = profiles.find((p) => p.id === selectedId) ?? null;

  const patchTab = useCallback((id: string, changes: Partial<Extract<Tab, { kind: "query" }>>) => {
    setTabs((current) =>
      current.map((tab) => (tab.id === id && tab.kind === "query" ? { ...tab, ...changes } : tab)),
    );
  }, []);

  // MARK: - Connections

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

  const connect = useCallback(
    async (profile: ConnectionProfile) => {
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
      } catch (e) {
        setBanner(errorText(e));
      }
    },
    [toggleDatabase],
  );

  const disconnect = useCallback(async (id: string) => {
    await api.disconnect(id);
    setSessions((s) => {
      const next = { ...s };
      delete next[id];
      return next;
    });
    setTabs((current) => current.filter((tab) => tab.connectionId !== id));
  }, []);

  const toggleSchema = useCallback(
    async (connectionId: string, session: Session, database: string, schema: string) => {
      const key = `${database}|${schema}`;
      const next: Session = { ...session, tables: { ...session.tables }, expanded: new Set(session.expanded) };
      if (next.expanded.has(key)) next.expanded.delete(key);
      else {
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

  // MARK: - Tabs

  const newQueryTab = useCallback(
    (connectionId: string, sql = "") => {
      const tab: Tab = {
        id: crypto.randomUUID(),
        kind: "query",
        connectionId,
        title: `${t("chrome.query")} ${tabs.filter((x) => x.kind === "query").length + 1}`,
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
    [t, tabs],
  );

  const openTable = useCallback(
    (profile: ConnectionProfile, table: TableRef) => {
      // Redis has no rows to browse in a grid, so it gets a command instead of a table tab.
      if (!isRelational(profile.kind)) {
        newQueryTab(profile.id, `SCAN 0 MATCH ${table.name}:* COUNT 100`);
        return;
      }
      const existing = tabs.find(
        (tab) =>
          tab.kind === "table" &&
          tab.connectionId === profile.id &&
          tab.table.name === table.name &&
          tab.table.schema === table.schema,
      );
      if (existing) {
        setActiveTabId(existing.id);
        return;
      }
      const tab: Tab = {
        id: crypto.randomUUID(),
        kind: "table",
        connectionId: profile.id,
        title: table.name,
        table,
      };
      setTabs((current) => [...current, tab]);
      setActiveTabId(tab.id);
    },
    [newQueryTab, tabs],
  );

  const closeTab = useCallback(
    (id: string) => {
      setTabs((current) => {
        const index = current.findIndex((tab) => tab.id === id);
        const next = current.filter((tab) => tab.id !== id);
        if (activeTabId === id) setActiveTabId(next[index]?.id ?? next[next.length - 1]?.id ?? null);
        return next;
      });
    },
    [activeTabId],
  );

  // MARK: - Running

  const execute = useCallback(
    async (tab: Extract<Tab, { kind: "query" }>, script: string) => {
      if (!settings) return;
      patchTab(tab.id, { running: true, error: null });
      const started = performance.now();
      const profile = profiles.find((p) => p.id === tab.connectionId);
      const base = {
        id: crypto.randomUUID(),
        sql: script,
        connectionName: profile ? displayName(profile) : "",
        database: sessions[tab.connectionId]?.info.currentDatabase ?? "",
        executedAt: new Date().toISOString(),
      };
      try {
        const results = await api.executeSql(tab.connectionId, script, settings.maxResultRows);
        patchTab(tab.id, { results, resultIndex: 0, running: false });
        await api.addHistory(
          { ...base, durationMs: performance.now() - started, succeeded: true, rowCount: results[0]?.rows.length ?? null, errorMessage: null },
          settings.historyLimit,
        );
      } catch (e) {
        const message = errorText(e);
        patchTab(tab.id, { error: message, results: [], running: false });
        await api.addHistory(
          { ...base, durationMs: performance.now() - started, succeeded: false, rowCount: null, errorMessage: message },
          settings.historyLimit,
        );
      }
    },
    [patchTab, profiles, sessions, settings],
  );

  const run = useCallback(
    async (tab: Extract<Tab, { kind: "query" }>) => {
      if (!settings || tab.running) return;
      const script = (selectedSql.trim() || tab.sql).trim();
      if (!script) return;

      const profile = profiles.find((p) => p.id === tab.connectionId);
      const keyword = script.replace(/^[\s;]*/, "").split(/\s+/)[0]?.toUpperCase() ?? "";
      const reads = ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "WITH", "PRAGMA", "VALUES", "TABLE"];
      const destructive =
        settings.confirmDestructiveStatements &&
        isRelational(profile?.kind ?? "postgres") &&
        !reads.includes(keyword);

      if (destructive) {
        setConfirm({
          title: t("confirm.destructiveTitle"),
          message: t("confirm.destructiveBody", keyword),
          confirmLabel: t("general.run"),
          onConfirm: () => void execute(tab, script),
        });
        return;
      }
      await execute(tab, script);
    },
    [execute, profiles, selectedSql, settings, t],
  );

  const cancel = useCallback(
    async (tab: Extract<Tab, { kind: "query" }>) => {
      try {
        await api.cancelQuery(tab.connectionId);
      } catch (e) {
        // The query itself reports what happened; this only covers the engines that
        // cannot cancel at all.
        setBanner(errorText(e));
      }
    },
    [],
  );

  // Completion needs columns, not just table names, and one query per schema is what
  // makes that affordable. It is a convenience, so a schema the user cannot read leaves
  // completion thinner rather than showing an error.
  useEffect(() => {
    const database = activeSession?.info.currentDatabase;
    if (!activeConnectionId || !database) {
      setCompletionSchema({});
      return;
    }
    let cancelled = false;
    void (async () => {
      const schemas = activeSession.schemas[database] ?? [""];
      const merged: Record<string, string[]> = {};
      for (const schema of schemas) {
        const columns = await api
          .schemaColumns(activeConnectionId, database, schema)
          .catch(() => ({}) as Record<string, string[]>);
        Object.assign(merged, columns);
      }
      // Tables the tree knows about but the column query did not cover still complete by
      // name, which is better than dropping them.
      for (const tables of Object.values(activeSession.tables)) {
        for (const table of tables) merged[table.name] ??= [];
      }
      if (!cancelled) setCompletionSchema(merged);
    })();
    return () => {
      cancelled = true;
    };
  }, [activeConnectionId, activeSession]);

  // The shortcuts a database client is expected to have. ⌘↩ belongs to the editor and is
  // bound there; everything here is about the window rather than the text, so it is bound
  // once on the window and deliberately ignores ⌘F, ⌘C and the rest, which mean something
  // more specific inside the editor and the grid.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
      const active = tabs.find((tab) => tab.id === activeTabId) ?? null;
      switch (event.key) {
        case "t":
          if (activeConnectionId && sessions[activeConnectionId]) {
            event.preventDefault();
            newQueryTab(activeConnectionId);
          }
          return;
        case "w":
          if (active) {
            event.preventDefault();
            closeTab(active.id);
          }
          return;
        case "n":
          event.preventDefault();
          setEditing({ profile: newProfile(), urlMode: false });
          return;
        case ",":
          event.preventDefault();
          setShowSettings(true);
          return;
        case "r":
          if (activeConnectionId && sessions[activeConnectionId]) {
            event.preventDefault();
            void refreshTree(activeConnectionId);
          }
          return;
        // ⌘. is the macOS convention for "stop what you are doing".
        case ".":
          if (active?.kind === "query" && active.running) {
            event.preventDefault();
            void cancel(active);
          }
          return;
        default:
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [activeConnectionId, activeTabId, cancel, closeTab, newQueryTab, refreshTree, sessions, tabs]);

  const connectionMenu = useCallback(
    (profile: ConnectionProfile): MenuItem[] => {
      const connected = Boolean(sessions[profile.id]);
      const database = sessions[profile.id]?.info.currentDatabase ?? profile.database;
      return [
        connected
          ? { label: t("menu.disconnect"), icon: PowerIcon, onSelect: () => void disconnect(profile.id) }
          : { label: t("menu.connect"), icon: BoltIcon, onSelect: () => void connect(profile) },
        { label: t("menu.newQuery"), icon: CommandLineIcon, disabled: !connected, onSelect: () => newQueryTab(profile.id) },
        { label: t("menu.refresh"), icon: ArrowPathIcon, disabled: !connected, onSelect: () => void refreshTree(profile.id), separatorBefore: true },
        {
          label: t("menu.dump"),
          icon: DocumentArrowDownIcon,
          disabled: !connected || !isRelational(profile.kind),
          separatorBefore: true,
          onSelect: () => setDumpFor({ connectionId: profile.id, database }),
        },
        {
          label: t("menu.runScript"),
          icon: ArrowUpTrayIcon,
          disabled: !connected || !isRelational(profile.kind),
          onSelect: () => setScriptFor(profile.id),
        },
        { label: t("menu.edit"), icon: PencilSquareIcon, separatorBefore: true, onSelect: () => setEditing({ profile, urlMode: false }) },
        {
          label: t("menu.duplicate"),
          icon: DocumentDuplicateIcon,
          onSelect: async () => {
            const copy = { ...profile, id: crypto.randomUUID(), name: `${displayName(profile)} copy`, savePassword: false, lastConnectedAt: null };
            setProfiles(await api.saveProfile(copy));
          },
        },
        {
          label: t("menu.copyUrl"),
          icon: ClipboardDocumentIcon,
          onSelect: async () => {
            // The password is deliberately left out, so this is safe to paste anywhere.
            await writeText(await api.connectionUrlForProfile(profile));
          },
        },
        {
          label: t("menu.delete"),
          icon: TrashIcon,
          danger: true,
          separatorBefore: true,
          onSelect: () =>
            setConfirm({
              title: t("connection.deleteTitle"),
              message: t("connection.deleteBody", displayName(profile)),
              confirmLabel: t("general.delete"),
              onConfirm: async () => {
                await disconnect(profile.id).catch(() => {});
                setProfiles(await api.deleteProfile(profile.id));
                if (selectedId === profile.id) setSelectedId(null);
              },
            }),
        },
      ];
    },
    [connect, disconnect, newQueryTab, refreshTree, selectedId, sessions, t],
  );

  const visibleProfiles = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    const matching = needle
      ? profiles.filter(
          (p) => displayName(p).toLowerCase().includes(needle) || subtitle(p).toLowerCase().includes(needle),
        )
      : profiles;
    return [...matching].sort((a, b) =>
      a.folder !== b.folder ? a.folder.localeCompare(b.folder) : displayName(a).localeCompare(displayName(b)),
    );
  }, [filter, profiles]);

  if (!settings) return <div className="empty">…</div>;

  const queryTab = activeTab?.kind === "query" ? activeTab : null;
  const result = queryTab?.results[queryTab.resultIndex];

  return (
    <div className="app">
      <UpdateBanner
        stage={updater.stage}
        dismissed={updater.dismissed}
        t={t}
        onDismiss={updater.dismiss}
        onDownload={updater.startDownload}
        onInstall={updater.installAndRestart}
      />

      <div className="chrome">
        <button className="chrome-button" onClick={() => setEditing({ profile: newProfile(), urlMode: false })}>
          <ServerStackIcon className="icon-lg" />
          {t("chrome.connection")}
        </button>
        <button className="chrome-button" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>
          <LinkIcon className="icon-lg" />
          {t("chrome.fromUrl")}
        </button>
        <div className="chrome-divider" />
        <button
          className="chrome-button"
          disabled={!activeConnectionId || !sessions[activeConnectionId]}
          onClick={() => activeConnectionId && newQueryTab(activeConnectionId)}
        >
          <CommandLineIcon className="icon-lg" />
          {t("chrome.query")}
        </button>
        <button className="chrome-button" disabled={!queryTab || queryTab.running} onClick={() => queryTab && void run(queryTab)}>
          <PlayIcon className="icon-lg" />
          {t("general.run")}
        </button>
        <button
          className="chrome-button"
          disabled={!activeConnectionId || !sessions[activeConnectionId]}
          onClick={() => activeConnectionId && void refreshTree(activeConnectionId)}
        >
          <ArrowPathIcon className="icon-lg" />
          {t("general.refresh")}
        </button>
        <div className="chrome-divider" />
        <button className="chrome-button" onClick={() => setShowHistory(true)}>
          <ClockIcon className="icon-lg" />
          {t("chrome.history")}
        </button>
        <div className="spacer" />
        <button className="chrome-button" onClick={() => setShowSettings(true)}>
          <Cog6ToothIcon className="icon-lg" />
          {t("chrome.settings")}
        </button>
      </div>

      {banner && (
        <div className="error-banner">
          <ExclamationTriangleIcon className="icon" />
          <div style={{ flex: 1 }}>{banner}</div>
          <button className="quiet" onClick={() => setBanner(null)}><XMarkIcon className="icon" /></button>
        </div>
      )}

      <div className="body">
        <aside className="sidebar">
          <div className="sidebar-search">
            <div style={{ position: "relative", display: "flex", alignItems: "center" }}>
              <MagnifyingGlassIcon className="icon" style={{ position: "absolute", left: 6, color: "var(--text-faint)" }} />
              <input value={filter} placeholder={t("sidebar.filter")} style={{ paddingLeft: 26 }} onChange={(e) => setFilter(e.target.value)} />
            </div>
          </div>

          <div className="sidebar-body">
            {profiles.length === 0 && (
              <div className="empty" style={{ paddingTop: 36 }}>
                <ServerStackIcon className="icon-xl" />
                <div>{t("sidebar.empty")}</div>
                <div className="hint">{t("sidebar.emptyHint")}</div>
                <button className="primary" onClick={() => setEditing({ profile: newProfile(), urlMode: true })}>
                  <LinkIcon className="icon" />
                  {t("sidebar.addFromUrl")}
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
                      title={session ? t("sidebar.connected") : t("sidebar.notConnected")}
                      style={{ background: session ? "var(--success)" : "var(--text-faint)" }}
                    />
                    <ServerStackIcon className="icon" style={{ color: KIND_COLOR[profile.kind] }} />
                    <span className="label">
                      <div style={{ overflow: "hidden", textOverflow: "ellipsis" }}>{displayName(profile)}</div>
                      <div className="sub">{subtitle(profile)}</div>
                    </span>
                    {profile.sshEnabled && <LinkIcon className="icon" style={{ color: "var(--text-faint)" }} />}
                    {profile.readOnly && <LockClosedIcon className="icon" style={{ color: "var(--text-faint)" }} />}
                    <span className="trailing">
                      <button className="quiet" onClick={(e) => { e.stopPropagation(); setEditing({ profile, urlMode: false }); }}>
                        <PencilSquareIcon className="icon" />
                      </button>
                    </span>
                  </div>

                  {session &&
                    session.databases.map((database) => {
                      const open = session.expanded.has(database);
                      return (
                        <div key={database}>
                          <div className="tree-row indent-1" onClick={() => void toggleDatabase(profile.id, session, database)}>
                            <span className="disclosure">{open ? <ChevronDownIcon /> : <ChevronRightIcon />}</span>
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
                                    <div className="tree-row indent-2" onClick={() => void toggleSchema(profile.id, session, database, schema)}>
                                      <span className="disclosure">{schemaOpen ? <ChevronDownIcon /> : <ChevronRightIcon />}</span>
                                      <FolderIcon className="icon" style={{ color: "var(--text-muted)" }} />
                                      <span className="label">{schema}</span>
                                    </div>
                                    {schemaOpen &&
                                      (session.tables[key] ?? []).map((table) => (
                                        <TableRow key={table.name} table={table} indent={3} profile={profile} onOpen={openTable} onMenu={setMenu} t={t} onImport={setImportFor} />
                                      ))}
                                  </div>
                                );
                              })}

                              {(session.schemas[database]?.length ?? 0) === 0 &&
                                (session.tables[database] ?? []).map((table) => (
                                  <TableRow key={table.name} table={table} indent={2} profile={profile} onOpen={openTable} onMenu={setMenu} t={t} onImport={setImportFor} />
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
              t("sidebar.tagline")
            )}
          </div>
        </aside>

        <main className="main">
          {tabs.length > 0 && (
            <div className="tabs">
              {tabs.map((tab) => (
                <button key={tab.id} className={`tab${tab.id === activeTabId ? " active" : ""}`} onClick={() => setActiveTabId(tab.id)}>
                  {tab.kind === "query" ? <CommandLineIcon className="icon" /> : <TableCellsIcon className="icon" />}
                  {tab.title}
                  <span className="close" onClick={(e) => { e.stopPropagation(); closeTab(tab.id); }}>
                    <XMarkIcon className="icon" style={{ width: 12, height: 12 }} />
                  </span>
                </button>
              ))}
            </div>
          )}

          {!activeTab && (
            <div className="empty">
              <CommandLineIcon className="icon-xl" />
              <div>{t("workspace.nothingOpen")}</div>
              <div className="hint">
                {selectedProfile && !sessions[selectedProfile.id] ? t("workspace.connectHint") : t("workspace.nothingOpenHint")}
              </div>
              {selectedProfile && !sessions[selectedProfile.id] && (
                <button className="primary" onClick={() => void connect(selectedProfile)}>
                  <BoltIcon className="icon" />
                  {t("sidebar.connect")}
                </button>
              )}
            </div>
          )}

          {activeTab?.kind === "table" && (
            <TableTab
              key={activeTab.id}
              connectionId={activeTab.connectionId}
              kind={activeProfile?.kind ?? "postgres"}
              readOnly={activeProfile?.readOnly ?? false}
              table={activeTab.table}
              settings={settings}
              t={t}
              onConfirm={setConfirm}
            />
          )}

          {queryTab && (
            <>
              <div className="query-toolbar">
                <button className="primary" disabled={queryTab.running} onClick={() => void run(queryTab)}>
                  <PlayIcon className="icon" />
                  {queryTab.running
                    ? t("general.running")
                    : selectedSql.trim()
                      ? t("general.runSelection")
                      : t("general.run")}
                </button>
                {queryTab.running && (
                  <button className="danger" onClick={() => void cancel(queryTab)}>
                    <StopIcon className="icon" />
                    {t("general.stop")}
                  </button>
                )}
                <span className="hint">⌘↩</span>
                <button
                  disabled={!queryTab.sql.trim()}
                  onClick={() => setNamingSnippet(queryTab.sql)}
                  title={t("snippets.save")}
                >
                  <BookmarkIcon className="icon" />
                </button>
                <div className="spacer" />
                {activeProfile?.readOnly && (
                  <span className="hint" style={{ display: "flex", alignItems: "center", gap: 4 }}>
                    <LockClosedIcon className="icon" />
                    {t("workspace.readOnly")}
                  </span>
                )}
                {activeSession && <span className="hint">{activeSession.info.currentDatabase}</span>}
              </div>

              <div className="editor-pane">
                <SqlEditor
                  value={queryTab.sql}
                  onChange={(sql) => patchTab(queryTab.id, { sql })}
                  onRun={() => void run(queryTab)}
                  onSelectionChange={setSelectedSql}
                  kind={activeProfile?.kind ?? "postgres"}
                  fontSize={settings.editorFontSize}
                  showLineNumbers={settings.showLineNumbers}
                  wrapLines={settings.wrapLongLines}
                  schema={completionSchema}
                />
              </div>

              <div className="result-pane">
                {queryTab.error && (
                  <div className="error-banner">
                    <ExclamationTriangleIcon className="icon" />
                    <div style={{ flex: 1 }}>{queryTab.error}</div>
                  </div>
                )}

                {queryTab.results.length > 1 && (
                  <div className="query-toolbar">
                    {queryTab.results.map((r, index) => (
                      <button
                        key={index}
                        className={index === queryTab.resultIndex ? "primary" : ""}
                        onClick={() => patchTab(queryTab.id, { resultIndex: index })}
                      >
                        {index + 1}. {r.statement.trim().split(/\s+/)[0]?.toUpperCase()}
                      </button>
                    ))}
                  </div>
                )}

                {result && result.columns.length > 0 ? (
                  <ResultGrid
                    columns={result.columns}
                    rows={result.rows}
                    fontSize={settings.gridFontSize}
                    kind={activeProfile?.kind ?? "postgres"}
                  />
                ) : (
                  <div className="empty">
                    <TableCellsIcon className="icon-xl" />
                    {result
                      ? result.rowsAffected !== null
                        ? t("workspace.rowsAffected", result.rowsAffected)
                        : t("workspace.noResultSet")
                      : queryTab.error
                        ? t("workspace.didNotRun")
                        : t("workspace.runQueryHint")}
                  </div>
                )}

                {result && (
                  <div className="status-bar">
                    <span>
                      {result.columns.length > 0 ? `${result.rows.length} ${t("general.rows")}` : "OK"} ·{" "}
                      {result.durationMs.toFixed(0)} ms
                    </span>
                    {result.messages.map((message) => (
                      <span key={message} className="hint">{message}</span>
                    ))}
                    <div className="spacer" />
                    {result.columns.length > 0 &&
                      EXPORT_FORMATS.map((format) => (
                        <button
                          key={format}
                          className="quiet"
                          onClick={async () => {
                            const path = await saveDialog({ defaultPath: `export.${format === "sqlInsert" ? "sql" : format === "markdown" ? "md" : format}` });
                            if (!path) return;
                            const text = await api.exportRows(
                              result.columns,
                              result.rows,
                              format,
                              result.columns[0]?.tableName ?? "exported_data",
                              activeProfile?.kind ?? "postgres",
                            );
                            await api.writeTextFile(path, text);
                          }}
                        >
                          {format === "sqlInsert" ? "SQL" : format.toUpperCase()}
                        </button>
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
          onConfirm={() => {
            confirm.onConfirm();
            setConfirm(null);
          }}
          onCancel={() => setConfirm(null)}
        />
      )}

      {editing && (
        <ConnectionDialog
          initial={editing.profile}
          startInUrlMode={editing.urlMode}
          t={t}
          credentialStore={credentialStore}
          onSaved={setProfiles}
          onClose={() => setEditing(null)}
        />
      )}

      {showSettings && (
        <SettingsDialog
          settings={settings}
          t={t}
          onChange={(next) => {
            setSettings(next);
            void api.setSettings(next);
          }}
          updater={updater}
          onClose={() => setShowSettings(false)}
        />
      )}

      {showHistory && (
        <HistoryPanel
          t={t}
          onUse={(sql) => {
            if (queryTab) patchTab(queryTab.id, { sql });
            else if (activeConnectionId) newQueryTab(activeConnectionId, sql);
          }}
          onClose={() => setShowHistory(false)}
        />
      )}

      {dumpFor && (
        <DumpSheet connectionId={dumpFor.connectionId} database={dumpFor.database} t={t} onClose={() => setDumpFor(null)} />
      )}
      {scriptFor && <RunScriptSheet connectionId={scriptFor} t={t} onClose={() => setScriptFor(null)} />}
      {importFor && (
        <CsvImportSheet connectionId={importFor.connectionId} table={importFor.table} t={t} onClose={() => setImportFor(null)} />
      )}

      {namingSnippet !== null && (
        <SnippetPrompt
          sql={namingSnippet}
          t={t}
          onClose={() => setNamingSnippet(null)}
        />
      )}
    </div>
  );
}

function TableRow({
  table,
  indent,
  profile,
  onOpen,
  onMenu,
  onImport,
  t,
}: {
  table: TableRef;
  indent: number;
  profile: ConnectionProfile;
  onOpen: (profile: ConnectionProfile, table: TableRef) => void;
  onMenu: (menu: { x: number; y: number; items: MenuItem[] }) => void;
  onImport: (target: { connectionId: string; table: TableRef }) => void;
  t: ReturnType<typeof makeTranslator>;
}) {
  return (
    <div
      className={`tree-row indent-${indent}`}
      onDoubleClick={() => onOpen(profile, table)}
      onContextMenu={(event) => {
        event.preventDefault();
        onMenu({
          x: event.clientX,
          y: event.clientY,
          items: [
            { label: t("menu.openTable"), icon: TableCellsIcon, onSelect: () => onOpen(profile, table) },
            {
              label: t("menu.importCsv"),
              icon: ArrowUpTrayIcon,
              disabled: !isRelational(profile.kind),
              onSelect: () => onImport({ connectionId: profile.id, table }),
            },
          ],
        });
      }}
    >
      {table.kind === "view" ? (
        <EyeIcon className="icon" style={{ color: "var(--text-faint)" }} />
      ) : (
        <TableCellsIcon className="icon" style={{ color: "var(--text-faint)" }} />
      )}
      <span className="label">{table.name}</span>
    </div>
  );
}

function SnippetPrompt({ sql, t, onClose }: { sql: string; t: ReturnType<typeof makeTranslator>; onClose: () => void }) {
  const [name, setName] = useState("");
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" style={{ width: 380 }}>
        <h2>{t("snippets.save")}</h2>
        <div className="dialog-body">
          <input autoFocus value={name} placeholder={t("snippets.name")} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="dialog-footer">
          <div className="spacer" />
          <button onClick={onClose}>{t("general.cancel")}</button>
          <button
            className="primary"
            disabled={!name.trim()}
            onClick={async () => {
              const existing = await api.getSnippets();
              await api.setSnippets([
                ...existing,
                { id: crypto.randomUUID(), name: name.trim(), sql, updatedAt: new Date().toISOString() },
              ]);
              onClose();
            }}
          >
            {t("general.save")}
          </button>
        </div>
      </div>
    </div>
  );
}
