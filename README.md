# MieSQL

A fast, native SQL client for macOS — an open-source alternative to Navicat.

MieSQL is written in Swift and SwiftUI, with pure-Swift database drivers. There is no
Electron runtime, no bundled Chromium and no telemetry. Everything you create — connection
profiles, query history, snippets, settings — stays on your Mac, and the app makes no
network calls other than to the databases you point it at.

> **Status: early.** v0.1 covers the core workflow for PostgreSQL, MySQL, MariaDB and
> SQLite. Redis, MongoDB and Firebase are on the roadmap, not in the box. See
> [Limitations](#limitations) for the honest list of what is missing.

## Features

**Connections**
- PostgreSQL, MySQL, MariaDB and SQLite
- Many connections open at once, each on its own actor — a slow query on one server never
  blocks another
- Passwords in the macOS Keychain, never in a config file
- Per-connection **read-only mode** that blocks writes and DDL before they leave the app
- Colour tags and folders so a production connection never looks like a local one
- Test the connection before saving it

**Querying**
- SQL editor with syntax highlighting, line numbers and schema-aware completion
  (your own table, schema and database names, not just keywords)
- Run all (`⌘R` / `⌘↩`) or run the selection (`⇧⌘↩`)
- Multi-statement scripts, split correctly around string literals, comments,
  PostgreSQL dollar quoting and MySQL `DELIMITER`
- SQL formatter that only re-indents — it never rewrites your statement
- Query history and reusable snippets, both stored locally
- A confirmation step before anything destructive runs (switchable)

**Browsing and editing**
- Virtualised result grid backed by `NSTableView`: scrolling 100k rows costs what scrolling
  10 does
- Paging, sorting and a free-form `WHERE` filter on any table
- Inline cell editing with `NULL` kept distinct from `''`. Edits collect into a pending set,
  and you see the exact `UPDATE` / `DELETE` statements before they run
- Editing is refused on tables with no primary key rather than guessing at a `WHERE` clause
- Structure tab: columns, indexes and foreign keys
- DDL tab: `SHOW CREATE TABLE` on MySQL, reconstructed from the catalog on PostgreSQL

**Import and export**
- Database dump to `.sql`: structure, data or both, with `DROP IF EXISTS`, transaction
  wrapping and a configurable rows-per-`INSERT`. Streamed to disk, so a table larger than
  RAM is fine
- Run a `.sql` file back in, statement by statement, with progress and a per-statement
  failure list
- Export a result set as CSV, TSV, JSON, SQL `INSERT` or Markdown
- CSV import with a preview and per-column mapping

**The rest**
- Light, dark and system appearance
- English and Turkish, switchable at runtime with no relaunch
- Command palette (`⌘K`) over connections, tables and actions
- Universal keyboard shortcuts and a real macOS menu bar

## Install

There is no signed release yet, so build it yourself. It takes about a minute.

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
./Scripts/bundle-app.sh release
open build/MieSQL.app
```

To install it properly:

```bash
cp -R build/MieSQL.app /Applications/
```

### Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ — either full Xcode, or just the Command Line Tools (`xcode-select --install`)

The build script prefers the standalone Command Line Tools, so you do not need Xcode. If
you do have Xcode installed but have never opened it, the toolchain refuses to run until
you accept the licence:

```bash
sudo xcodebuild -license accept
```

## Development

```bash
swift build            # build
swift run MieSQL       # run without bundling (no menu bar; use the script for the real app)
swift test             # run the test suite
```

Opening `Package.swift` in Xcode works too.

If you are building with the Command Line Tools rather than Xcode, `swift test` needs to be
pointed at the bundled Swift Testing framework:

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F -Xswiftc $F \
  -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

### Layout

```
Sources/
  MieSQLCore/          No UI. Safe to depend on from a CLI or tests.
    Models/            Connection profiles, result sets, schema objects
    SQL/               Dialect quoting, statement splitter, lexer, formatter
    Drivers/           PostgresDriver, MySQLDriver, SQLiteDriver
    Storage/           Keychain, connection store, settings, history
    Transfer/          Dump, script runner, CSV import, row-edit planner
  MieSQL/              The SwiftUI app
    ViewModels/        AppModel, DatabaseSession, tab models
    Views/             Sidebar, editor, result grid, sheets
    Localization/      String tables
Tests/MieSQLCoreTests/ Unit tests plus SQLite integration tests
```

Each driver is a Swift `actor`, so one connection serialises its own traffic while several
connections run in parallel. Drivers return values already rendered to text, which keeps the
grid, the exporters and the clipboard on a single code path.

### Adding a language

1. Add a case to `AppLanguage` in `Sources/MieSQL/Localization/Localization.swift`.
2. Add a dictionary to `Translations` in `Translations.swift` and register it in `table`.

Missing keys fall back to English, so a partial translation is still useful. Please keep
English as the source language.

### Adding a database engine

Implement `DatabaseDriver` (`Sources/MieSQLCore/Drivers/DatabaseDriver.swift`), add a case
to `DatabaseKind`, teach `SQLDialect` its quoting rules, and wire it into `DriverFactory`.
The protocol is deliberately small: connect, execute, list, describe.

## Limitations

Known and deliberate, as of v0.1:

- **No SSH tunnelling yet.** Use a local `ssh -L` tunnel and connect to `127.0.0.1`.
- **No Redis, MongoDB or Firebase yet.** The driver protocol assumes a relational shape;
  supporting key-value and document stores needs a second protocol alongside it.
- **A PostgreSQL query that returns zero rows shows no column headers.** PostgresNIO does
  not expose the row description separately from the rows. Table browsing is unaffected —
  it reads columns from the catalog.
- **MySQL 8 accounts using `caching_sha2_password` need SSL set to Prefer or Require.**
  The driver cannot complete that handshake over a plaintext socket.
- **No schema editor.** You can read structure and DDL, but changing a table means writing
  the `ALTER`.
- **No stored procedure, trigger or user management UI.**
- **Transactions are per-statement.** There is no explicit transaction panel yet; `BEGIN`
  and `COMMIT` in the editor work as expected on a single connection.

## Roadmap

- SSH tunnelling
- Redis, MongoDB and Firebase
- Visual schema editor and ER diagram
- Data comparison and synchronisation between two connections
- Saved workspaces and tab restore
- Signed, notarised releases and a Homebrew cask

## Privacy

MieSQL stores everything under `~/Library/Application Support/MieSQL`:

| File | Contents |
| --- | --- |
| `connections.json` | Connection profiles. Never passwords. Mode `0600`. |
| `settings.json` | Preferences |
| `query-history.json` | Query history |
| `snippets.json` | Saved snippets |

Passwords live in the macOS Keychain under the service `app.miesql.connections`, keyed by a
per-connection UUID. Deleting a connection deletes its Keychain item.

There is no analytics, no crash reporting and no update check.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a PR, and keep
`MieSQLCore` free of UI imports so it stays testable.

## Licence

MIT. See [LICENSE](LICENSE).

---

## Türkçe

MieSQL, macOS için hızlı ve yerel bir SQL istemcisidir — Navicat'e açık kaynak bir
alternatif. Swift ve SwiftUI ile yazıldı; veritabanı sürücüleri saf Swift. Electron yok,
telemetri yok. Bağlantı profilleri, sorgu geçmişi, ayarlar — hepsi bu Mac'te kalır ve
uygulama bağlandığınız veritabanları dışında hiçbir ağ isteği yapmaz.

**v0.1'de olanlar:** PostgreSQL, MySQL, MariaDB ve SQLite; eş zamanlı çoklu bağlantı;
Anahtar Zinciri'nde parola saklama; bağlantı bazlı salt okunur kipi; sözdizimi renklendirmeli
ve şema farkında tamamlamalı SQL editörü; sayfalama, sıralama ve süzme ile veri tarayıcı;
birincil anahtar üzerinden satır düzenleme (çalıştırmadan önce ifadeleri gösterir); yapı ve
DDL sekmeleri; `.sql` dışa/içe aktarma (dump/restore); CSV içe aktarma; CSV/JSON/SQL/Markdown
dışa aktarma; açık/koyu tema; İngilizce ve Türkçe arayüz (yeniden başlatmadan değişir);
komut paleti (`⌘K`).

**Kurulum:**

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
./Scripts/bundle-app.sh release
open build/MieSQL.app
```

macOS 14+ ve Swift 6.0+ gerekir. Xcode şart değil; Komut Satırı Araçları yeterli
(`xcode-select --install`). Xcode kuruluysa ama hiç açmadıysanız önce lisansı kabul edin:
`sudo xcodebuild -license accept`.

**Şimdilik olmayanlar:** SSH tüneli, Redis/MongoDB/Firebase, görsel şema düzenleyici.
Ayrıntılı liste için yukarıdaki [Limitations](#limitations) bölümüne bakın.

Katkılar memnuniyetle karşılanır. Lisans: MIT.
