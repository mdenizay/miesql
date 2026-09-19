import { useCallback, useEffect, useMemo, useState } from "react";
import { ArrowPathIcon, ExclamationTriangleIcon, LockClosedIcon, PlusIcon, TrashIcon } from "@heroicons/react/24/outline";
import { api } from "../lib/api";
import type { Translate } from "../lib/i18n";
import { ResultGrid } from "./ResultGrid";
import {
  errorText,
  type AppSettings,
  type QueryResult,
  type RowEdit,
  type SqlValue,
  type TableDetails,
  type TableRef,
} from "../lib/types";

type Section = "data" | "structure" | "ddl";

interface Props {
  connectionId: string;
  kind: string;
  /** From the profile. The backend refuses writes anyway; this keeps the UI from
   *  offering an action that is going to be turned down. */
  readOnly: boolean;
  table: TableRef;
  settings: AppSettings;
  t: Translate;
  onConfirm: (options: {
    title: string;
    message: string;
    confirmLabel: string;
    onConfirm: () => void;
  }) => void;
}

export function TableTab({ connectionId, kind, readOnly, table, settings, t, onConfirm }: Props) {
  const [section, setSection] = useState<Section>("data");
  const [details, setDetails] = useState<TableDetails | null>(null);
  const [ddl, setDdl] = useState("");
  const [result, setResult] = useState<QueryResult | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [page, setPage] = useState(0);
  const [filter, setFilter] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Edits are held here until applied, so nothing reaches the database unreviewed.
  const [pending, setPending] = useState<Record<number, Record<string, SqlValue>>>({});
  const [originals, setOriginals] = useState<Record<number, Record<string, SqlValue>>>({});
  const [deleted, setDeleted] = useState<Set<number>>(new Set());
  const [selection, setSelection] = useState<number[]>([]);
  // Rows added here but not yet inserted. Their ids are negative so they can share the
  // grid's id space with real rows without ever being mistaken for one.
  const [addedIds, setAddedIds] = useState<number[]>([]);

  const editable = (details?.columns ?? []).some((c) => c.isPrimaryKey) && table.kind === "table";
  // Appending needs no key — nothing has to be identified to add a row — so a keyless
  // table can still be written to even though its existing rows cannot be edited.
  const appendable = table.kind === "table" && !readOnly;
  const pendingCount = Object.keys(pending).length + deleted.size;

  const displayRows = useMemo(() => {
    if (!result) return [];
    const blank = addedIds.map((id) => ({
      id,
      values: result.columns.map(() => ({ t: "null" }) as SqlValue),
    }));
    return [...result.rows, ...blank];
  }, [result, addedIds]);

  const load = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      const described = details ?? (await api.describeTable(connectionId, table));
      setDetails(described);
      const rows = await api.fetchRows(
        connectionId,
        table,
        filter,
        [],
        settings.pageSize,
        page * settings.pageSize,
      );
      setResult(rows);
      setPending({});
      setOriginals({});
      setDeleted(new Set());
      setAddedIds([]);
      if (page === 0) {
        setTotal(await api.countRows(connectionId, table, filter).catch(() => 0));
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
    // `details` is intentionally not a dependency: refetching it on every page would be
    // a round trip for information that cannot have changed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [connectionId, table, filter, page, settings.pageSize]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (section !== "ddl" || ddl) return;
    void api
      .createStatement(connectionId, table)
      .then(setDdl)
      .catch((e) => setDdl(`-- ${errorText(e)}`));
  }, [section, ddl, connectionId, table]);

  const recordEdit = useCallback(
    (rowId: number, column: string, value: SqlValue) => {
      if (!result) return;
      // A row being added has nothing to compare against and no WHERE clause to build,
      // so the typed value is simply kept.
      if (rowId < 0) {
        setPending((current) => ({
          ...current,
          [rowId]: { ...(current[rowId] ?? {}), [column]: value },
        }));
        return;
      }
      const row = result.rows.find((r) => r.id === rowId);
      if (!row) return;

      // The row as it was read is what the WHERE clause will be built from.
      const original: Record<string, SqlValue> = {};
      for (const info of result.columns) original[info.name] = row.values[info.index];
      setOriginals((current) => ({ ...current, [rowId]: original }));

      setPending((current) => {
        const forRow = { ...(current[rowId] ?? {}) };
        const before = original[column];
        // An edit that restores the original value is not a change at all.
        const same =
          before &&
          before.t === value.t &&
          (before.t === "null" || before.v === (value as { v: string }).v);
        if (same) delete forRow[column];
        else forRow[column] = value;

        const next = { ...current };
        if (Object.keys(forRow).length === 0) delete next[rowId];
        else next[rowId] = forRow;
        return next;
      });
    },
    [result],
  );

  const markDeleted = useCallback(() => {
    if (!result || selection.length === 0) return;
    const nextOriginals = { ...originals };
    for (const rowId of selection) {
      const row = result.rows.find((r) => r.id === rowId);
      if (!row) continue;
      const original: Record<string, SqlValue> = {};
      for (const info of result.columns) original[info.name] = row.values[info.index];
      nextOriginals[rowId] = original;
    }
    setOriginals(nextOriginals);
    setDeleted((current) => new Set([...current, ...selection]));
  }, [originals, result, selection]);

  const apply = useCallback(async () => {
    const edits: RowEdit[] = [
      // A row that was added but never typed into would become `INSERT INTO t () VALUES ()`,
      // so it is dropped rather than sent as a statement no engine would accept.
      ...addedIds
        .filter((rowId) => Object.keys(pending[rowId] ?? {}).length > 0)
        .map((rowId) => ({ kind: "insert" as const, rowId, values: pending[rowId] })),
      ...Object.entries(pending)
        .filter(([rowId]) => Number(rowId) >= 0 && !deleted.has(Number(rowId)))
        .map(([rowId, changes]) => ({
          kind: "update" as const,
          rowId: Number(rowId),
          changes,
          original: originals[Number(rowId)] ?? {},
        })),
      ...[...deleted].map((rowId) => ({
        kind: "delete" as const,
        rowId,
        original: originals[rowId] ?? {},
      })),
    ];
    if (edits.length === 0) return;

    try {
      const planned = await api.planRowEdits(connectionId, table, edits);
      onConfirm({
        title: t("data.applyTitle", planned.length),
        // Showing the statements is the point: an edit is never applied unseen.
        message: `${t("data.applyBody", table.name)}\n\n${planned.map((p) => p.sql).join("\n")}`,
        confirmLabel: t("general.apply"),
        onConfirm: async () => {
          try {
            await api.applyStatements(connectionId, planned.map((p) => p.sql));
            await load();
          } catch (e) {
            setError(errorText(e));
          }
        },
      });
    } catch (e) {
      setError(errorText(e));
    }
  }, [addedIds, connectionId, deleted, load, onConfirm, originals, pending, t, table]);

  return (
    <>
      <div className="query-toolbar">
        {(["data", "structure", "ddl"] as Section[]).map((s) => (
          <button key={s} className={section === s ? "primary" : ""} onClick={() => setSection(s)}>
            {t(`tab.${s}` as never)}
          </button>
        ))}
        <button onClick={() => void load()} disabled={busy} title={t("general.refresh")}>
          <ArrowPathIcon className="icon" />
        </button>
        <div className="spacer" />
        {!editable && section === "data" && (
          <span className="hint" style={{ display: "flex", alignItems: "center", gap: 4 }}>
            <LockClosedIcon className="icon" />
            {t("data.notEditable")}
          </span>
        )}
        <span className="hint">{table.schema ? `${table.schema}.${table.name}` : table.name}</span>
      </div>

      {error && (
        <div className="error-banner">
          <ExclamationTriangleIcon className="icon" />
          <div style={{ flex: 1 }}>{error}</div>
        </div>
      )}

      {section === "data" && (
        <>
          <div className="query-toolbar">
            <input
              value={filter}
              placeholder={t("data.filter")}
              style={{ fontFamily: "var(--mono)", maxWidth: 420 }}
              onChange={(e) => setFilter(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  setPage(0);
                  void load();
                }
              }}
            />
            {appendable && (
              <button onClick={() => setAddedIds((current) => [...current, -(current.length + 1)])}>
                <PlusIcon className="icon" />
                {t("data.addRow")}
              </button>
            )}
            {editable && (
              <button disabled={selection.length === 0} onClick={markDeleted}>
                <TrashIcon className="icon" />
                {t("data.deleteRows")}
              </button>
            )}
          </div>

          {result && <ResultGrid
            columns={result.columns}
            rows={displayRows}
            fontSize={settings.gridFontSize}
            kind={kind}
            editable={editable}
            pending={pending}
            deleted={deleted}
            added={new Set(addedIds)}
            onEdit={recordEdit}
            onSelectionChange={setSelection}
          />}

          <div className="status-bar">
            <button disabled={page === 0} onClick={() => setPage((p) => Math.max(0, p - 1))}>‹</button>
            <span>{t("data.page", page + 1)}</span>
            <button
              disabled={(result?.rows.length ?? 0) < settings.pageSize}
              onClick={() => setPage((p) => p + 1)}
            >
              ›
            </button>
            {total !== null && <span>{total} {t("general.rows")}</span>}
            <div className="spacer" />
            {pendingCount > 0 && (
              <>
                <span style={{ color: "var(--accent)" }}>{t("data.pending", pendingCount)}</span>
                <button
                  onClick={() => {
                    setPending({});
                    setDeleted(new Set());
                    setAddedIds([]);
                  }}
                >
                  {t("general.discard")}
                </button>
                <button className="primary" onClick={() => void apply()}>
                  {t("data.review")}
                </button>
              </>
            )}
          </div>
        </>
      )}

      {section === "structure" && details && (
        <div className="struct">
          {details.estimatedRowCount !== null && (
            <div className="hint">
              {t("structure.rowCount")}: {details.estimatedRowCount}
            </div>
          )}
          {details.comment && <div className="hint">{details.comment}</div>}

          <h3>{t("structure.columns")}</h3>
          <table>
            <thead>
              <tr>
                <th>{t("structure.column")}</th>
                <th>{t("structure.type")}</th>
                <th>{t("structure.nullable")}</th>
                <th>{t("structure.key")}</th>
                <th>{t("structure.default")}</th>
                <th>{t("structure.comment")}</th>
              </tr>
            </thead>
            <tbody>
              {details.columns.map((column) => (
                <tr key={column.name}>
                  <td>{column.name}</td>
                  <td>{column.dataType}</td>
                  <td className="muted">{column.isNullable ? "✓" : ""}</td>
                  <td>{column.isPrimaryKey ? "PK" : column.isAutoIncrement ? "AI" : ""}</td>
                  <td className="muted">{column.defaultValue ?? ""}</td>
                  <td className="muted">{column.comment ?? ""}</td>
                </tr>
              ))}
            </tbody>
          </table>

          {details.indexes.length > 0 && (
            <>
              <h3>{t("structure.indexes")}</h3>
              <table>
                <thead>
                  <tr>
                    <th>{t("connection.name")}</th>
                    <th>{t("structure.columns")}</th>
                    <th>{t("structure.unique")}</th>
                    <th>{t("structure.primary")}</th>
                    <th>{t("structure.method")}</th>
                  </tr>
                </thead>
                <tbody>
                  {details.indexes.map((index) => (
                    <tr key={index.name}>
                      <td>{index.name}</td>
                      <td>{index.columns.join(", ")}</td>
                      <td className="muted">{index.isUnique ? "✓" : ""}</td>
                      <td className="muted">{index.isPrimary ? "✓" : ""}</td>
                      <td className="muted">{index.method ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}

          {details.foreignKeys.length > 0 && (
            <>
              <h3>{t("structure.foreignKeys")}</h3>
              <table>
                <thead>
                  <tr>
                    <th>{t("connection.name")}</th>
                    <th>{t("structure.columns")}</th>
                    <th>{t("structure.references")}</th>
                    <th>{t("structure.onDelete")}</th>
                    <th>{t("structure.onUpdate")}</th>
                  </tr>
                </thead>
                <tbody>
                  {details.foreignKeys.map((key) => (
                    <tr key={key.name}>
                      <td>{key.name}</td>
                      <td>{key.columns.join(", ")}</td>
                      <td>
                        {key.referencedTable} ({key.referencedColumns.join(", ")})
                      </td>
                      <td className="muted">{key.onDelete ?? ""}</td>
                      <td className="muted">{key.onUpdate ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </div>
      )}

      {section === "ddl" && <pre className="ddl">{ddl || "…"}</pre>}
    </>
  );
}
