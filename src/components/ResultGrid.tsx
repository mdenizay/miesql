import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { isNull, valueText, type ColumnInfo, type ResultRow, type SqlValue } from "../lib/types";

interface Props {
  columns: ColumnInfo[];
  rows: ResultRow[];
  fontSize: number;
  /** Editing is off unless the caller can identify a row, which needs a primary key. */
  editable?: boolean;
  /** rowId → column name → the value the user typed but has not applied. */
  pending?: Record<number, Record<string, SqlValue>>;
  deleted?: Set<number>;
  onEdit?: (rowId: number, column: string, value: SqlValue) => void;
  onSelectionChange?: (rowIds: number[]) => void;
}

const NUMERIC = ["int", "num", "dec", "float", "double", "real", "serial", "money"];

function isNumeric(column: ColumnInfo): boolean {
  const type = column.typeName.toLowerCase();
  return NUMERIC.some((needle) => type.includes(needle));
}

/**
 * Only the visible rows exist in the DOM, so scrolling a hundred thousand rows costs the
 * same as scrolling ten. Editing is deliberately in-place and deferred: a change is held
 * here until the user applies it, and never written straight through.
 */
export function ResultGrid({
  columns,
  rows,
  fontSize,
  editable = false,
  pending = {},
  deleted = new Set<number>(),
  onEdit,
  onSelectionChange,
}: Props) {
  const scroller = useRef<HTMLDivElement>(null);
  const [editing, setEditing] = useState<{ rowId: number; column: string } | null>(null);
  const [draft, setDraft] = useState("");
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const rowHeight = Math.max(20, fontSize + 10);

  // A first guess at useful widths, from the header and the first rows.
  const widths = useMemo(
    () =>
      columns.map((column) => {
        let width = column.name.length * (fontSize * 0.62) + 28;
        for (const row of rows.slice(0, 40)) {
          const value = row.values[column.index];
          const length = value ? (isNull(value) ? 4 : valueText(value).length) : 0;
          width = Math.max(width, length * (fontSize * 0.6) + 20);
        }
        return Math.min(Math.max(width, 64), 420);
      }),
    [columns, rows, fontSize],
  );

  const totalWidth = widths.reduce((sum, w) => sum + w, 0);

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scroller.current,
    estimateSize: () => rowHeight,
    overscan: 12,
  });

  useEffect(() => {
    onSelectionChange?.([...selected]);
  }, [selected, onSelectionChange]);

  const valueFor = useCallback(
    (row: ResultRow, column: ColumnInfo): SqlValue => {
      const override = pending[row.id]?.[column.name];
      return override ?? row.values[column.index] ?? { t: "null" };
    },
    [pending],
  );

  const commit = useCallback(() => {
    if (!editing) return;
    // Typing the word NULL is how a cell is cleared; an empty string stays an empty string.
    const value: SqlValue = draft === "NULL" ? { t: "null" } : { t: "text", v: draft };
    onEdit?.(editing.rowId, editing.column, value);
    setEditing(null);
  }, [draft, editing, onEdit]);

  if (columns.length === 0) return null;

  return (
    <div className="grid" ref={scroller}>
      <div
        className="grid-inner"
        style={{ width: totalWidth, height: virtualizer.getTotalSize() + rowHeight }}
      >
        <div className="grid-head" style={{ height: rowHeight, width: totalWidth }}>
          {columns.map((column, index) => (
            <div
              key={column.index}
              className="cell"
              style={{ width: widths[index], lineHeight: `${rowHeight - 6}px` }}
              title={column.typeName ? `${column.name} · ${column.typeName}` : column.name}
            >
              {column.name}
            </div>
          ))}
        </div>

        {virtualizer.getVirtualItems().map((item) => {
          const row = rows[item.index];
          const isDeleted = deleted.has(row.id);
          const isSelected = selected.has(row.id);
          return (
            <div
              key={row.id}
              className={`grid-row${isDeleted ? " deleted" : ""}${isSelected ? " selected" : ""}`}
              style={{
                height: rowHeight,
                transform: `translateY(${item.start + rowHeight}px)`,
                width: totalWidth,
              }}
              onMouseDown={(event) => {
                if (event.target instanceof HTMLInputElement) return;
                setSelected((current) => {
                  const next = new Set(event.metaKey || event.ctrlKey ? current : []);
                  if (next.has(row.id)) next.delete(row.id);
                  else next.add(row.id);
                  return next;
                });
              }}
            >
              {columns.map((column, index) => {
                const value = valueFor(row, column);
                const nullish = isNull(value);
                const isEditing =
                  editing?.rowId === row.id && editing.column === column.name;
                const changed = pending[row.id]?.[column.name] !== undefined;

                if (isEditing) {
                  return (
                    <div key={column.index} className="cell editing" style={{ width: widths[index] }}>
                      <input
                        autoFocus
                        value={draft}
                        style={{ fontSize }}
                        onChange={(e) => setDraft(e.target.value)}
                        onBlur={commit}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") commit();
                          if (e.key === "Escape") setEditing(null);
                        }}
                      />
                    </div>
                  );
                }

                return (
                  <div
                    key={column.index}
                    className={`cell${isNumeric(column) ? " numeric" : ""}${nullish ? " null" : ""}${changed ? " changed" : ""}`}
                    style={{ width: widths[index], lineHeight: `${rowHeight - 6}px`, fontSize }}
                    title={nullish ? "NULL" : valueText(value)}
                    onDoubleClick={() => {
                      if (!editable || isDeleted) return;
                      setDraft(nullish ? "NULL" : valueText(value));
                      setEditing({ rowId: row.id, column: column.name });
                    }}
                  >
                    {/* NULL is shown as a marker, never as a blank that could be mistaken
                        for an empty string. */}
                    {nullish ? "NULL" : valueText(value).replace(/\n/g, "⏎ ")}
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>
    </div>
  );
}
