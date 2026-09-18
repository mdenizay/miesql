import { useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { isNull, valueText, type ColumnInfo, type ResultRow } from "../lib/types";

interface Props {
  columns: ColumnInfo[];
  rows: ResultRow[];
  fontSize: number;
}

const NUMERIC = ["int", "num", "dec", "float", "double", "real", "serial", "money"];

function isNumeric(column: ColumnInfo): boolean {
  const type = column.typeName.toLowerCase();
  return NUMERIC.some((needle) => type.includes(needle));
}

/**
 * Only the visible rows exist in the DOM, so scrolling a hundred thousand rows costs the
 * same as scrolling ten — the property the AppKit table gave the Swift version for free.
 */
export function ResultGrid({ columns, rows, fontSize }: Props) {
  const scroller = useRef<HTMLDivElement>(null);
  const rowHeight = Math.max(20, fontSize + 10);

  // A first guess at useful widths, from the header and the first rows.
  const widths = useMemo(() => {
    return columns.map((column) => {
      let width = column.name.length * (fontSize * 0.62) + 28;
      for (const row of rows.slice(0, 40)) {
        const value = row.values[column.index];
        const length = value ? (isNull(value) ? 4 : valueText(value).length) : 0;
        width = Math.max(width, length * (fontSize * 0.6) + 20);
      }
      return Math.min(Math.max(width, 64), 420);
    });
  }, [columns, rows, fontSize]);

  const totalWidth = widths.reduce((sum, w) => sum + w, 0);

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scroller.current,
    estimateSize: () => rowHeight,
    overscan: 12,
  });

  if (columns.length === 0) return null;

  return (
    <div className="grid" ref={scroller}>
      <div className="grid-inner" style={{ width: totalWidth, height: virtualizer.getTotalSize() + rowHeight }}>
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
          return (
            <div
              key={row.id}
              className="grid-row"
              style={{
                height: rowHeight,
                transform: `translateY(${item.start + rowHeight}px)`,
                width: totalWidth,
              }}
            >
              {columns.map((column, index) => {
                const value = row.values[column.index];
                const nullish = !value || isNull(value);
                return (
                  <div
                    key={column.index}
                    className={`cell${isNumeric(column) ? " numeric" : ""}${nullish ? " null" : ""}`}
                    style={{ width: widths[index], lineHeight: `${rowHeight - 6}px`, fontSize }}
                    title={nullish ? "NULL" : valueText(value)}
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
