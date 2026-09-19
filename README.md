# MieSQL

A fast, cross-platform SQL client — an open-source alternative to Navicat, for macOS,
Windows and Linux.

Written in Rust with a React interface, packaged with Tauri. No Electron runtime, no
bundled Chromium, no telemetry. Everything you create — connection profiles, query
history, settings — stays on your machine, and the app makes no network calls other than
to the databases you point it at and, if you leave it on, the update check.

> **Status: 1.0.** Supports **PostgreSQL, MySQL, MariaDB, SQLite and Redis**. MongoDB and
> Firebase are not implemented. See [Limitations](#limitations) for the honest list of
> what is still missing.

## Download

[**Latest release**](https://github.com/mdenizay/miesql/releases/latest)

| Platform | File |
| --- | --- |
| macOS (Apple Silicon and Intel) | `MieSQL_*_universal.dmg` |
| Windows | `MieSQL_*_x64-setup.exe` |
| Linux | `.AppImage`, `.deb` or `.rpm` |

- **macOS:** signed with a Developer ID and notarised by Apple, so it opens with no
  warning and no workaround. The very first launch takes a while, because macOS verifies
  the whole bundle once; every launch after that is immediate.
- **Windows:** the installer is **not** signed, so SmartScreen reports an unknown
  publisher — choose **More info → Run anyway**. It installs for the current user and
  needs no administrator rights.
- **Linux:** `chmod +x` the AppImage. Saving passwords needs a Secret Service provider
  such as gnome-keyring or KWallet; without one MieSQL says so and asks each time instead.

Would rather build it yourself? Reasonable, and quick:

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
npm install
npm run app:build
```

## Features

**Connections**
- PostgreSQL, MySQL, MariaDB, SQLite and Redis, with several open at once — each on its own
  lock, so a slow query on one server never blocks another
- **SSH tunnelling**, through the system ssh client, so `~/.ssh/config`, the agent,
  hardware keys and jump hosts all work exactly as they do in a terminal
- Add a connection by pasting its URL — see [Connection URLs](#connection-urls)
- Passwords in the OS credential store: Keychain, Credential Manager or the Secret Service
- Per-connection **read-only mode** that blocks writes and DDL before they leave the app
- Test the connection before saving it

**Querying**
- SQL editor with syntax highlighting and schema-aware completion — **table *and* column
  names** from the database you are connected to, fetched in one query per schema
- `⌘↩` / `Ctrl+↩` to run — the highlighted text when there is a selection, the whole
  script otherwise
- **Stop a running query.** PostgreSQL cancels over its own protocol, MySQL and MariaDB
  through `KILL QUERY` on a second login, SQLite by interrupt. In every case the session
  survives: you keep your transaction, your temporary tables and your database
- `⌘F` to search the editor; `⌘T`, `⌘W`, `⌘N`, `⌘R`, `⌘,` and `⌘.` for tabs, connections,
  refresh, settings and stop
- Multiple query tabs
- Multi-statement scripts split correctly around string literals, comments, PostgreSQL
  dollar quoting and MySQL `DELIMITER`
- Virtualised result grid: only visible rows exist in the DOM, so scrolling 100k rows costs
  what scrolling 10 does
- `NULL` is always distinct from the empty string — in the grid, in exports and on the
  clipboard
- `⌘C` copies the selected rows as TSV, through the same exporter the file export uses
- Local query history and saved snippets

**Browsing and changing data**
- Tables open with **Data, Structure and DDL** tabs: columns, indexes, foreign keys, and
  the `CREATE` statement
- **Editable grid.** Add, change and delete rows. Edits are held locally and applying them
  shows the exact `INSERT`, `UPDATE` and `DELETE` statements first. Every update and delete
  keys on the complete primary key, a NULL key part becomes `IS NULL`, and a table without
  a key is refused rather than guessed at. An added row sends only the columns you filled
  in, so defaults and auto-increment still apply
- **Dump and restore**: structure, data or both, streamed to disk so a table larger than
  RAM is fine; restore runs statement by statement and names the one that failed
- **CSV import** with a preview and per-column mapping
- Export a result as CSV, TSV, JSON, SQL `INSERT` or Markdown

**The rest**
- Light, dark and system appearance
- English and Turkish, switchable at runtime with no relaunch
- Automatic updates — checked at launch and downloaded in the background, but never
  installed on their own; applying one waits for you to restart
- `miesql --doctor`, a self-check for the data directory and credential store

## Connection URLs

**New Connection from URL** accepts any of these:

```
postgres://user:password@host:5432/database?sslmode=require
postgresql://user@host/db          # database defaults to the username, as libpq does
mysql://root:p@ss@127.0.0.1:3307/shop
jdbc:postgresql://localhost:5432/app
sqlite:///Users/you/app.sqlite
/Users/you/app.sqlite              # a bare path works too
host=db.example.com port=5433 dbname=app user=ada password='se cret'
DATABASE_URL="postgres://u:p@h/d"  # quotes and the env-var prefix are stripped
```

Passwords containing `@`, `:` or `/` parse correctly, encoded or not — the part most
connection-string parsers get wrong. IPv6 hosts and comma-separated failover lists work.
`sslmode` / `useSSL` / `ssl-mode`, `connect_timeout`, `mode=ro` and `readonly` are read;
`verify-ca` and `verify-full` are accepted but reported as downgraded to Require, because
certificate validation is not implemented yet.

The URL fills in the form rather than saving straight away, so you can check it first. If
the clipboard already holds something that parses, it is offered when the sheet opens.
Going the other way, a connection's context menu has **Copy Connection URL**, which leaves
the password out.

## Development

```bash
npm install
npm run app:dev        # run the app with hot reload
npm run build          # type-check and bundle the frontend
cargo test --manifest-path src-tauri/Cargo.toml
```

Requires Rust 1.77+ and Node 22+. On Linux you also need the WebKitGTK development
packages; the [CI workflow](.github/workflows/ci.yml) lists them.

### Layout

```
src-tauri/src/
  models.rs           Connection profiles, result sets, schema objects
  connection_url.rs   Connection-string parsing and serialising
  sql/                Dialect quoting, statement splitter
  drivers/            The Driver trait, PostgreSQL, MySQL, SQLite and Redis
  drivers/cancel.rs   Cancel handles, held outside the driver lock on purpose
  transfer/           Row editing, dump and restore, CSV, export
  ssh.rs              Tunnelling through the system ssh client
  storage/            Profiles, settings, history, OS credential store
  commands.rs         The only surface the UI can reach
src/
  components/         Sidebar, editor, grid, dialogs
  lib/                Typed API wrappers, updater hook
```

Drivers return values already rendered to text, which keeps the grid, the exporters and
the clipboard on one code path. Each uses its engine's *text* protocol where one exists —
for PostgreSQL that is the simple query protocol, which also reports column names for a
result with no rows.

### Adding a database engine

Implement `Driver` in `src-tauri/src/drivers/`, add a case to `DatabaseKind`, teach
`Dialect` its quoting rules, and register it in `make_driver`. The trait is deliberately
small: connect, execute, list, describe.

## Limitations

Known and deliberate:

- **No MongoDB or Firebase.**
- **No schema editor.** Structure and DDL are read-only; changing a table means writing the
  `ALTER` yourself.
- **Redis queries cannot be cancelled.** There is no Redis equivalent of `KILL QUERY` that
  stops a command without dropping the connection, so the app says so rather than offering
  a stop that does nothing.
- **SSH tunnelling needs an `ssh` binary**, which macOS and Linux always have and Windows
  has shipped since Windows 10. Password authentication over SSH does not work on Windows,
  because its ssh.exe ignores `SSH_ASKPASS`; use a key or ssh-agent there.
- **Certificate validation is not implemented.** `verify-ca` and `verify-full` are treated
  as Require, and the app says so rather than pretending.
- **The Windows installer is unsigned**, so SmartScreen warns about it. macOS is signed
  and notarised.
- **Builds are x86_64 on Windows and Linux.** macOS is universal.
- **Two languages**, English and Turkish.

## Privacy

Everything lives in one folder, which Settings will show you:

| Platform | Location |
| --- | --- |
| macOS | `~/Library/Application Support/MieSQL` |
| Windows | `%APPDATA%\MieSQL` |
| Linux | `~/.local/share/MieSQL` |

`connections.json` holds profiles and never passwords, and is written `0600` on Unix.
Passwords live in the OS credential store under the service `com.mdenizay.miesql`,
keyed by a per-connection UUID; deleting a connection deletes its entry.

There is no analytics and no crash reporting. The update check is the only outbound
request the app makes on its own, and it can be switched off in Settings.

## Contributing

Issues and pull requests are welcome. Please keep `cargo test`, `cargo clippy -- -D
warnings` and `cargo fmt` clean — CI enforces all three on macOS, Windows and Linux.

## Licence

MIT. See [LICENSE](LICENSE).

---

## Türkçe

MieSQL, macOS, Windows ve Linux için hızlı bir SQL istemcisidir — Navicat'e açık kaynak bir
alternatif. Rust ve React ile yazıldı, Tauri ile paketlendi. Electron yok, telemetri yok.
Bağlantı profilleri, sorgu geçmişi ve ayarlar bu cihazda kalır; uygulama bağlandığınız
veritabanları ve (açık bırakırsanız) güncelleme kontrolü dışında ağa çıkmaz.

**Desteklenenler:** PostgreSQL, MySQL, MariaDB, SQLite ve Redis; eş zamanlı çoklu bağlantı; işletim sisteminin
kimlik deposunda parola saklama; bağlantı bazlı salt okunur kipi; sözdizimi renklendirmeli
ve şema farkında tamamlamalı SQL editörü; 100 bin satırı akıcı gezen sanallaştırılmış
sonuç tablosu; bağlantı URL'i yapıştırarak ekleme; otomatik güncelleme; açık/koyu tema.

SSH tüneli, düzenlenebilir tablo (çalıştırmadan önce ifadeleri gösterir), Yapı/DDL
sekmeleri, dump/restore, CSV içe aktarma ve Türkçe arayüz dahildir. MongoDB ve Firebase
henüz yok.

**İndirme:** [en son sürüm](https://github.com/mdenizay/miesql/releases/latest) — macOS
için universal `.dmg` (Apple Silicon ve Intel), Windows için `.exe`, Linux için
`.AppImage` / `.deb` / `.rpm`. macOS sürümü Developer ID ile imzalı ve Apple
tarafından notarize edilmiştir — uyarısız açılır, yalnızca ilk açılış bir kerelik uzun
sürer. Windows kurulumu imzasız olduğu için SmartScreen uyarır (**More info → Run anyway**).

Arayüz şimdilik yalnızca İngilizce. Katkılar memnuniyetle karşılanır. Lisans: MIT.
