// Copying rows goes through the same exporter the file export uses. One code path means
// the clipboard and a saved file can never disagree about quoting, line endings or how a
// NULL is written — which is the whole reason drivers render values to text in the first
// place.

import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { api } from "./api";
import type { ColumnInfo, ResultRow } from "./types";

/** Tab-separated and headerless, which is what a spreadsheet expects from a paste. */
export async function copyRows(
  columns: ColumnInfo[],
  rows: ResultRow[],
  kind: string,
): Promise<void> {
  if (rows.length === 0) return;
  await writeText(await api.exportRows(columns, rows, "tsv", "", kind, false));
}
