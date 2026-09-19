# Contributing to MieSQL

Thanks for taking a look. MieSQL is small enough that a first patch is realistic in an
afternoon.

## Getting set up

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
npm install
npm run app:dev            # the app, with hot reload
npm run build              # type-check and bundle the frontend
cargo test --manifest-path src-tauri/Cargo.toml
```

Rust 1.77+ and Node 22+. On Linux you also need the WebKitGTK development packages; the
[CI workflow](.github/workflows/ci.yml) lists them for Ubuntu.

Tests that need a server are skipped unless you point them at one:

```bash
MIESQL_TEST_PG_URL=postgres://user@localhost/scratch \
MIESQL_TEST_MYSQL_URL=mysql://root:secret@127.0.0.1:3306/scratch \
MIESQL_TEST_REDIS_URL=redis://127.0.0.1/15 \
  cargo test --manifest-path src-tauri/Cargo.toml
```

Point them at a scratch database. They create and drop tables.

## Ground rules

- **Keep the UI out of the core.** Everything under `src-tauri/src` should be testable
  without a window, and that is where new tests go. `commands.rs` is the only surface the
  frontend can reach.
- **Escape once, in one place.** All identifier quoting and literal escaping goes through
  `sql::dialect::Dialect`. If you find yourself writing `"'" .to_owned() + value + "'"`,
  stop.
- **Never guess at a `WHERE` clause.** Generated statements key on the complete primary
  key, and the user sees them before they run. A feature that cannot meet that bar should
  be refused rather than approximated.
- **`NULL` is not the empty string.** It stays distinct in the grid, in exports and on the
  clipboard. This is easy to lose by accident.
- **English is the source language.** Add the English string to `src/lib/i18n.ts` first;
  other languages fall back to it.
- **Green before the PR.** `cargo test`, `cargo clippy --all-targets -- -D warnings`,
  `cargo fmt --check` and `npm run build`. CI enforces all four on macOS, Windows and
  Linux.

## Where things live

See the Layout section in the [README](README.md#layout).

## Adding a database engine

1. Implement `Driver` in `src-tauri/src/drivers/`. The trait is deliberately small:
   connect, execute, list, describe.
2. Add a case to `DatabaseKind` with its display name and default port.
3. Teach `Dialect` its quoting and paging rules.
4. Register it in `make_driver`.
5. Publish a cancel handle into the driver's `CancelSlot` if the engine can stop a running
   statement — and leave the slot empty if it cannot, rather than offering a cancel that
   does nothing.
6. Add integration tests modelled on the SQLite ones in `tests/drivers.rs`.

Drivers return values already rendered to text. That is what keeps the grid, the
exporters, the clipboard and the dumper on one code path, so decode binary wire formats in
the driver, never in the UI.

## Adding a language

Add a dictionary to `src/lib/i18n.ts` and register it in `TABLES`. You do not have
to translate every key; missing ones fall back to English.

## Commit messages

Plain and descriptive. One logical change per commit where it is easy to do so.

## Reporting bugs

Please include: your OS, the database engine and version, what you ran, what you expected,
and what happened. If the app showed an error, the exact text is more useful than a
summary. `miesql --doctor` output helps for anything involving saved passwords.
