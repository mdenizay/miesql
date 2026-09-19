import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { open as openDialog, save as saveDialog } from "@tauri-apps/plugin-dialog";
import { api } from "../lib/api";
import type { Translate } from "../lib/i18n";
import {
  errorText,
  type CsvOptions,
  type CsvPreview,
  type DumpOptions,
  type DumpProgress,
  type ScriptProgress,
  type ScriptSummary,
  type TableRef,
} from "../lib/types";

interface Common {
  connectionId: string;
  t: Translate;
  onClose: () => void;
}

// MARK: - Export a database

export function DumpSheet({
  connectionId,
  database,
  t,
  onClose,
}: Common & { database: string }) {
  const [tables, setTables] = useState<TableRef[]>([]);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [options, setOptions] = useState<DumpOptions>({
    includeSchema: true,
    includeData: true,
    dropIfExists: false,
    wrapInTransaction: true,
    rowsPerInsert: 100,
  });
  const [path, setPath] = useState<string | null>(null);
  const [progress, setProgress] = useState<DumpProgress | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const key = (table: TableRef) => `${table.schema}|${table.name}`;

  useEffect(() => {
    void (async () => {
      try {
        const schemas = await api.listSchemas(connectionId, database);
        const collected = schemas.length
          ? (await Promise.all(schemas.map((s) => api.listTables(connectionId, database, s)))).flat()
          : await api.listTables(connectionId, database, "");
        setTables(collected);
        setChosen(new Set(collected.map(key)));
      } catch (e) {
        setError(errorText(e));
      }
    })();
  }, [connectionId, database]);

  // A dump of a large table runs for minutes, so progress comes back as events.
  useEffect(() => {
    const promise = listen<DumpProgress>("dump-progress", (event) => setProgress(event.payload));
    return () => {
      void promise.then((unlisten) => unlisten());
    };
  }, []);

  const start = useCallback(async () => {
    if (!path) return;
    setBusy(true);
    setError(null);
    try {
      const selected = tables.filter((table) => chosen.has(key(table)));
      const summary = await api.dumpDatabase(connectionId, selected, options, path);
      setDone(t("dump.done", summary.tables, summary.rows));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }, [chosen, connectionId, options, path, t, tables]);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" style={{ width: 620 }}>
        <h2>{t("dump.title")} — {database}</h2>
        <div className="dialog-body" style={{ flexDirection: "row", gap: 16 }}>
          <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
            <div className="row" style={{ marginBottom: 6 }}>
              <strong style={{ flex: 1, fontSize: 11 }}>{t("dump.tables")}</strong>
              <button onClick={() => setChosen(new Set(tables.map(key)))}>{t("general.all")}</button>
              <button onClick={() => setChosen(new Set())}>{t("general.none")}</button>
            </div>
            <div className="list" style={{ border: "1px solid var(--border)", borderRadius: 5, maxHeight: 300 }}>
              {tables.map((table) => (
                <label key={key(table)} className="check" style={{ padding: "3px 8px" }}>
                  <input
                    type="checkbox"
                    checked={chosen.has(key(table))}
                    onChange={(e) =>
                      setChosen((current) => {
                        const next = new Set(current);
                        if (e.target.checked) next.add(key(table));
                        else next.delete(key(table));
                        return next;
                      })
                    }
                  />
                  {table.schema ? `${table.schema}.${table.name}` : table.name}
                </label>
              ))}
            </div>
          </div>

          <div style={{ width: 250, display: "flex", flexDirection: "column", gap: 8 }}>
            <label className="check">
              <input
                type="checkbox"
                checked={options.includeSchema}
                onChange={(e) => setOptions({ ...options, includeSchema: e.target.checked })}
              />
              {t("dump.includeSchema")}
            </label>
            <label className="check">
              <input
                type="checkbox"
                checked={options.includeData}
                onChange={(e) => setOptions({ ...options, includeData: e.target.checked })}
              />
              {t("dump.includeData")}
            </label>
            <label className="check">
              <input
                type="checkbox"
                checked={options.dropIfExists}
                onChange={(e) => setOptions({ ...options, dropIfExists: e.target.checked })}
              />
              {t("dump.dropIfExists")}
            </label>
            <label className="check">
              <input
                type="checkbox"
                checked={options.wrapInTransaction}
                onChange={(e) => setOptions({ ...options, wrapInTransaction: e.target.checked })}
              />
              {t("dump.transaction")}
            </label>
            <div className="field">
              <label>{t("dump.rowsPerInsert")}</label>
              <input
                type="number"
                value={options.rowsPerInsert}
                onChange={(e) =>
                  setOptions({ ...options, rowsPerInsert: Number(e.target.value) || 1 })
                }
              />
            </div>
            <div className="field">
              <label>{t("dump.destination")}</label>
              <div className="row">
                <input readOnly value={path?.split("/").pop() ?? "—"} />
                <button
                  onClick={async () => {
                    const chosenPath = await saveDialog({
                      defaultPath: `${database}.sql`,
                      filters: [{ name: "SQL", extensions: ["sql"] }],
                    });
                    if (chosenPath) setPath(chosenPath);
                  }}
                >
                  {t("general.browse")}
                </button>
              </div>
            </div>

            {busy && progress && (
              <div className="progress-row">
                <div className="progress">
                  <div style={{ width: `${(progress.tableIndex / Math.max(1, progress.tableCount)) * 100}%` }} />
                </div>
                <span>{t("dump.running", progress.currentTable || "…")}</span>
              </div>
            )}
            {done && <div className="good">{done}</div>}
            {error && <div className="bad">{error}</div>}
          </div>
        </div>
        <div className="dialog-footer">
          <div className="spacer" />
          <button onClick={onClose}>{t("general.close")}</button>
          <button className="primary" disabled={busy || !path || chosen.size === 0} onClick={() => void start()}>
            {t("dump.start")}
          </button>
        </div>
      </div>
    </div>
  );
}

// MARK: - Run a SQL file

export function RunScriptSheet({ connectionId, t, onClose }: Common) {
  const [path, setPath] = useState<string | null>(null);
  const [stopOnError, setStopOnError] = useState(true);
  const [progress, setProgress] = useState<ScriptProgress | null>(null);
  const [summary, setSummary] = useState<ScriptSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const promise = listen<ScriptProgress>("script-progress", (event) => setProgress(event.payload));
    return () => {
      void promise.then((unlisten) => unlisten());
    };
  }, []);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog">
        <h2>{t("restore.title")}</h2>
        <div className="dialog-body">
          <div className="field">
            <label>{t("restore.file")}</label>
            <div className="row">
              <input readOnly value={path?.split("/").pop() ?? "—"} />
              <button
                onClick={async () => {
                  const chosen = await openDialog({
                    multiple: false,
                    filters: [{ name: "SQL", extensions: ["sql"] }],
                  });
                  if (typeof chosen === "string") setPath(chosen);
                }}
              >
                {t("general.browse")}
              </button>
            </div>
          </div>
          <label className="check">
            <input type="checkbox" checked={stopOnError} onChange={(e) => setStopOnError(e.target.checked)} />
            {t("restore.stopOnError")}
          </label>

          {busy && progress && (
            <div className="progress-row">
              <div className="progress">
                <div
                  style={{
                    width: `${(progress.statementIndex / Math.max(1, progress.statementCount)) * 100}%`,
                  }}
                />
              </div>
              <span>{t("restore.running", progress.statementIndex, progress.statementCount)}</span>
            </div>
          )}

          {summary && (
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <div className={summary.failures.length ? "warn" : "good"}>
                {t("restore.done", summary.succeeded, summary.total)}
                {summary.failures.length > 0 && ` · ${t("restore.failures", summary.failures.length)}`}
              </div>
              {summary.failures.length > 0 && (
                <div className="failure-list">
                  {summary.failures.map((failure, index) => (
                    <div key={index}>
                      <div className="bad">{failure.message}</div>
                      <div className="sql">{failure.statement}</div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
          {error && <div className="bad">{error}</div>}
        </div>
        <div className="dialog-footer">
          <div className="spacer" />
          <button onClick={onClose}>{t("general.close")}</button>
          <button
            className="primary"
            disabled={busy || !path}
            onClick={async () => {
              if (!path) return;
              setBusy(true);
              setError(null);
              try {
                setSummary(await api.runScriptFile(connectionId, path, stopOnError));
              } catch (e) {
                setError(errorText(e));
              } finally {
                setBusy(false);
              }
            }}
          >
            {t("restore.start")}
          </button>
        </div>
      </div>
    </div>
  );
}

// MARK: - Import a CSV

export function CsvImportSheet({
  connectionId,
  table,
  t,
  onClose,
}: Common & { table: TableRef }) {
  const [path, setPath] = useState<string | null>(null);
  const [options, setOptions] = useState<CsvOptions>({
    delimiter: ",",
    hasHeaderRow: true,
    nullMarker: "",
    rowsPerInsert: 200,
    columnMapping: {},
  });
  const [preview, setPreview] = useState<CsvPreview | null>(null);
  const [targets, setTargets] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void api
      .describeTable(connectionId, table)
      .then((details) => setTargets(details.columns.map((c) => c.name)))
      .catch((e) => setError(errorText(e)));
  }, [connectionId, table]);

  const reload = useCallback(
    async (nextPath: string, nextOptions: CsvOptions) => {
      try {
        const loaded = await api.csvPreview(nextPath, nextOptions);
        setPreview(loaded);
        // Pre-map anything whose header matches a column name, which is the usual case.
        const mapping: Record<number, string> = {};
        loaded.header.forEach((name, index) => {
          const match = targets.find((c) => c.toLowerCase() === name.toLowerCase());
          if (match) mapping[index] = match;
        });
        setOptions({ ...nextOptions, columnMapping: mapping });
      } catch (e) {
        setError(errorText(e));
      }
    },
    [targets],
  );

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" style={{ width: 560 }}>
        <h2>{t("import.title")} — {table.name}</h2>
        <div className="dialog-body">
          <div className="field">
            <label>{t("import.file")}</label>
            <div className="row">
              <input readOnly value={path?.split("/").pop() ?? "—"} />
              <button
                onClick={async () => {
                  const chosen = await openDialog({
                    multiple: false,
                    filters: [{ name: "CSV", extensions: ["csv", "tsv", "txt"] }],
                  });
                  if (typeof chosen === "string") {
                    setPath(chosen);
                    await reload(chosen, options);
                  }
                }}
              >
                {t("general.browse")}
              </button>
            </div>
          </div>

          <label className="check">
            <input
              type="checkbox"
              checked={options.hasHeaderRow}
              onChange={async (e) => {
                const next = { ...options, hasHeaderRow: e.target.checked };
                setOptions(next);
                if (path) await reload(path, next);
              }}
            />
            {t("import.hasHeader")}
          </label>

          <div className="field">
            <label>{t("import.delimiter")}</label>
            <select
              value={options.delimiter}
              onChange={async (e) => {
                const next = { ...options, delimiter: e.target.value };
                setOptions(next);
                if (path) await reload(path, next);
              }}
            >
              <option value=",">,</option>
              <option value=";">;</option>
              <option value="&#9;">Tab</option>
              <option value="|">|</option>
            </select>
          </div>

          {preview && preview.header.length > 0 && (
            <>
              <div className="section-title">{t("import.mapping")}</div>
              {preview.header.map((name, index) => (
                <div className="row" key={index}>
                  <div style={{ flex: 1, fontFamily: "var(--mono)", fontSize: 12 }}>{name}</div>
                  <select
                    style={{ flex: 1 }}
                    value={options.columnMapping[index] ?? ""}
                    onChange={(e) => {
                      const mapping = { ...options.columnMapping };
                      if (e.target.value) mapping[index] = e.target.value;
                      else delete mapping[index];
                      setOptions({ ...options, columnMapping: mapping });
                    }}
                  >
                    <option value="">{t("general.none")}</option>
                    {targets.map((column) => (
                      <option key={column} value={column}>
                        {column}
                      </option>
                    ))}
                  </select>
                </div>
              ))}

              <div className="section-title">{t("import.preview")}</div>
              <div style={{ overflow: "auto", maxHeight: 120 }}>
                {preview.rows.map((row, index) => (
                  <div key={index} className="sql" style={{ whiteSpace: "nowrap" }}>
                    {row.join(" │ ")}
                  </div>
                ))}
              </div>
              <div className="hint">{preview.totalRows} {t("general.rows")}</div>
            </>
          )}

          {done && <div className="good">{done}</div>}
          {error && <div className="bad">{error}</div>}
        </div>
        <div className="dialog-footer">
          <div className="spacer" />
          <button onClick={onClose}>{t("general.close")}</button>
          <button
            className="primary"
            disabled={busy || !path || Object.keys(options.columnMapping).length === 0}
            onClick={async () => {
              if (!path) return;
              setBusy(true);
              setError(null);
              try {
                const inserted = await api.csvImport(connectionId, table, path, options);
                setDone(t("import.done", inserted));
              } catch (e) {
                setError(errorText(e));
              } finally {
                setBusy(false);
              }
            }}
          >
            {t("import.start")}
          </button>
        </div>
      </div>
    </div>
  );
}
