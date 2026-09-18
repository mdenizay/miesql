MieSQL now covers the feature set the macOS-only v0.1.0 had, and more besides. It supports
**PostgreSQL, MySQL, MariaDB, SQLite and Redis** on macOS, Windows and Linux.

Everything still stays on your device. Passwords go to the system credential store, and the
app makes no network calls beyond the databases you connect to and, if you leave it on, the
update check.

## New since v0.2.1

**MySQL and MariaDB.** The gap against v0.1.0 is closed. Like the other drivers it uses the
text protocol, so values arrive rendered by the server and a query returning no rows still
shows its column headers.

**Redis.** Not relational, so the mapping is deliberate: a database is a numbered Redis
database, a table is a key namespace, rows are the keys in it with type, TTL and a value
preview, and the editor runs raw commands. Listings use `SCAN`, never `KEYS`, because
`KEYS` blocks the server for the length of the keyspace.

**Editable grid.** Edits are held locally and applying them shows the exact `UPDATE` and
`DELETE` statements to agree to first. Every statement keys on the complete primary key, a
NULL key part becomes `IS NULL` rather than `= NULL` — which would match nothing and
silently change no rows — and a table without a key is refused rather than guessed at.

**Structure and DDL tabs.** Columns, indexes, foreign keys and the `CREATE` statement.

**Dump, restore and CSV import.** Dumps stream to disk, so a table larger than RAM works,
and progress actually moves. Restore runs one statement at a time and names the one that
failed. Results export as CSV, TSV, JSON, SQL or Markdown.

**SSH tunnelling.** Through the system `ssh` client, so `~/.ssh/config`, ssh-agent,
hardware keys, jump hosts and `known_hosts` all work exactly as they do in a terminal —
host key verification is OpenSSH's, not a reimplementation of it.

**Turkish.** The interface switches language at runtime, with no relaunch.

**Query history and snippets** are reachable from the toolbar.

## Fixed

- Connecting to MySQL over TLS **crashed the app**. Two rustls crypto providers had ended
  up in the dependency tree, and rustls aborts rather than choosing between them. There is
  now one, which also removed cmake and nasm from the Windows build.
- On Linux without a Secret Service, saving a password failed with a raw DBus message. It
  now says which package to install, and offers not saving the password instead.

## Install

**macOS** — open the `.dmg` and drag MieSQL to Applications. Signed with a Developer ID and
notarised, so it opens with no warning. Universal: Apple Silicon and Intel.

**Windows** — run the `.exe`. The installer is **not** signed, so SmartScreen will report an
unknown publisher; choose **More info → Run anyway**. Per-user, no administrator rights.

**Linux** — take the `.AppImage` (`chmod +x` it first), or the `.deb` or `.rpm`. Saving
passwords needs gnome-keyring or KWallet; without one MieSQL says so and asks each time.

## Known limitations

- No MongoDB or Firebase.
- No schema editor: Structure and DDL are read-only.
- SSH password authentication does not work on Windows, because its `ssh.exe` ignores
  `SSH_ASKPASS`. Use a key or ssh-agent there.
- Certificate validation is not implemented. `verify-ca` and `verify-full` are accepted but
  downgraded to Require, and the app says so rather than pretending.
- The Windows installer is unsigned.
- Builds are x86_64 on Windows and Linux; macOS is universal.

Progress and the full checklist: https://github.com/mdenizay/miesql/pull/1
