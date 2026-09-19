MieSQL 1.0 — a fast, cross-platform SQL client for PostgreSQL, MySQL, MariaDB, SQLite and
Redis. Everything stays on your machine.

## New in 1.0

**Stop a running query.** The one thing a SQL client cannot be without. PostgreSQL cancels
over its own protocol, MySQL and MariaDB through `KILL QUERY` on a second login, SQLite by
interrupt. The session survives in every case, so you keep your transaction, your
temporary tables and your selected database. Redis has no way to stop a command without
dropping the connection, and the app says so rather than offering a button that does
nothing.

**Add rows in the grid.** Alongside editing and deleting. An added row sends only the
columns you filled in, so defaults and auto-increment still apply, and — as with every
other edit — you see the exact `INSERT` before it runs.

**Completion knows your columns**, not just your table names. One query per schema, so it
stays cheap on a database with hundreds of tables.

**Run the selection.** `⌘↩` runs the highlighted text when there is a selection and the
whole script otherwise. `⌘F` searches the editor, `⌘C` copies the selected rows as TSV,
and `⌘T` `⌘W` `⌘N` `⌘R` `⌘,` `⌘.` cover tabs, connections, refresh, settings and stop.

## Fixed

- **Typing into a NULL cell produced `NULLwhatever you typed`.** The editor opened
  pre-filled with the literal word `NULL` and typing appended to it. Cells now open empty
  with `NULL` as the placeholder, and leaving one empty keeps it NULL rather than silently
  writing an empty string — the two are not the same value.
- **A second query tab shared the first one's editor handlers**, so typing in one tab
  wrote into the other tab's text.
- The table header showed a bare `.` instead of `schema.table`.

## Also

The unused `mongodb` dependency is gone, and the Swift sources the Tauri rewrite replaced
have been removed — they remain at the `v0.1.0` tag.

## Install

| Platform | File |
| --- | --- |
| macOS (Apple Silicon and Intel) | `MieSQL_1.0.0_universal.dmg` |
| Windows | `MieSQL_1.0.0_x64-setup.exe` |
| Linux | `.AppImage`, `.deb` or `.rpm` |

macOS is signed with a Developer ID and notarised, so it opens with no warning. The
Windows installer is unsigned — SmartScreen will ask; choose **More info → Run anyway**.
It installs for the current user and needs no administrator rights.

If you already have MieSQL, it will offer this update at launch.
