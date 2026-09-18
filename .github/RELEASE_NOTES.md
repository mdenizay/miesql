MieSQL is now a Tauri app: a Rust core with a React interface, building for macOS, Windows
and Linux from one codebase. v0.1.0 was macOS-only Swift.

Everything still stays on your device. Passwords go to the system credential store —
Keychain, Credential Manager or the Secret Service — and the app makes no network calls
beyond the databases you connect to and, if you leave it on, the update check.

## Read this before updating from v0.1.0

**This release supports fewer databases than v0.1.0 did.** The rewrite is not finished.
Working today: **PostgreSQL and SQLite**. Not yet ported: **MySQL and MariaDB**, dump and
restore, CSV import, the editable result grid, and the Structure and DDL tabs.

If you depend on any of those, stay on
[v0.1.0](https://github.com/mdenizay/miesql/releases/tag/v0.1.0) for now. Your saved
connections are shared between the two, so nothing is lost either way.

Saved passwords will be asked for once more after updating. macOS ties a keychain item to
the code signature that wrote it, and the Swift build's signature is not this one's.
Re-entering a password fixes it permanently for that connection.

## What is better than v0.1.0

- **Windows and Linux**, alongside a universal macOS build for Apple Silicon and Intel.
- **A PostgreSQL query that returns no rows now shows its column headers.** v0.1.0 could
  not do this; the simple query protocol reports the row description even for an empty
  result, which also removed ~300 lines of hand-written type decoding.
- **Automatic updates.** Checked shortly after launch and downloaded in the background,
  but never installed on their own — applying an update waits for you to restart, so it
  cannot interrupt a query. Both steps are switchable in Settings.
- **Add a connection by pasting its URL**, including passwords containing `@`, `:` or `/`,
  JDBC prefixes, bare SQLite paths and the `host=… dbname=…` form.
- **7 MB instead of 52 MB.**
- `sslmode=verify-full` no longer silently degrades to Prefer — a bug that shipped in
  v0.1.0. It is treated as Require and says so.

## Install

**macOS** — download the `.dmg`, or the `.app.tar.gz` if you prefer. The app is not signed
with a Developer ID or notarised, because that needs a paid Apple Developer account, so
macOS will refuse to open it the first time. Either clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/MieSQL.app
```

…or open **System Settings → Privacy & Security** after the first attempt and choose
**Open Anyway**.

**Windows** — run the `.exe`. It installs for the current user and needs no administrator
rights. SmartScreen will warn that the publisher is unknown; the installer is unsigned for
the same reason as above.

**Linux** — take the `.AppImage` (works anywhere, `chmod +x` it first), or the `.deb` or
`.rpm` for your distribution. Saving passwords needs a Secret Service provider such as
gnome-keyring or KWallet; without one, MieSQL says so and lets you enter the password each
time instead.

Prefer to build it yourself? It takes a couple of minutes:

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql && npm install && npm run app:build
```

## Known limitations

- No MySQL or MariaDB yet, and no Redis, MongoDB or SSH tunnelling.
- No dump, restore or CSV import.
- The result grid is read-only; there is no Structure or DDL tab.
- Certificate validation is not implemented. `verify-ca` and `verify-full` are accepted but
  downgraded to Require, and the app tells you so rather than pretending.
- The interface is English only; Turkish is not ported yet.

Progress and the full checklist: https://github.com/mdenizay/miesql/pull/1
