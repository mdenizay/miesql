A fast, native SQL client for macOS — an open-source alternative to Navicat.

This is the first tagged build. It covers the core workflow for **PostgreSQL, MySQL,
MariaDB and SQLite**: many connections at once, a SQL editor with highlighting and
schema-aware completion, a virtualised result grid you can edit, structure and DDL views,
`.sql` dump and restore, CSV import, and CSV/JSON/SQL/Markdown export. Light and dark,
English and Turkish, both switchable at runtime.

Everything stays on your Mac. Passwords go to the Keychain; nothing else leaves the
machine except the queries you send to your own databases.

## Install

Download the zip, unpack it, and move `MieSQL.app` to `/Applications`.

**The app is not signed with a Developer ID and is not notarised**, because that needs a
paid Apple Developer account. macOS will therefore refuse to open it on the first try —
this is Gatekeeper doing its job on an unidentified developer, not a fault in the download.

To open it anyway, either remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/MieSQL.app
```

…or launch it once, then go to **System Settings → Privacy & Security**, find the blocked
MieSQL entry, and choose **Open Anyway**.

If you would rather not trust a binary from a stranger — a reasonable position — build it
yourself instead; it takes about a minute:

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
./Scripts/bundle-app.sh release
open build/MieSQL.app
```

Verify the download against `SHA256SUMS.txt` if you do use the zip.

## Requirements

macOS 14 (Sonoma) or later. The binary is universal: Apple Silicon and Intel.

## Known limitations

These are deliberate for a first release, not oversights:

- **No SSH tunnelling.** Use a local `ssh -L` tunnel and connect to `127.0.0.1`.
- **No Redis, MongoDB or Firebase.** The driver protocol assumes a relational shape.
- **A PostgreSQL query returning zero rows shows no column headers**, because PostgresNIO
  does not expose the row description separately from the rows. Table browsing is
  unaffected — it reads columns from the catalog.
- **MySQL 8 accounts using `caching_sha2_password` need SSL set to Prefer or Require.**
  That handshake cannot complete over a plaintext socket.
- **Certificate validation is not implemented.** `sslmode=verify-ca` and `verify-full` are
  accepted but downgraded to Require, and the app says so rather than pretending.
- **No schema editor**, and no UI for stored procedures, triggers or users.

Bug reports and pull requests are welcome:
https://github.com/mdenizay/miesql/issues
