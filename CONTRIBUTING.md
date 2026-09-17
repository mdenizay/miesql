# Contributing to MieSQL

Thanks for taking a look. MieSQL is small enough that a first patch is realistic in an
afternoon.

## Getting set up

```bash
git clone https://github.com/mdenizay/miesql.git
cd miesql
swift build
swift test
./Scripts/bundle-app.sh debug && open build/MieSQL.app
```

macOS 14+ and Swift 6.0+. Xcode is optional — the build script uses the standalone Command
Line Tools when they are present.

## Ground rules

- **Keep `MieSQLCore` free of UI.** No `SwiftUI`, no `AppKit`. Everything in there should be
  testable without a window, and it is where new tests should go.
- **Escape once, in one place.** All identifier quoting and literal escaping goes through
  `SQLDialect`. If you find yourself writing `"'" + value + "'"`, stop.
- **Never guess at a `WHERE` clause.** Generated statements key on the complete primary key,
  and the user sees them before they run. A feature that cannot meet that bar should be
  refused rather than approximated.
- **English is the source language.** Add the English string first; other languages fall
  back to it.
- **Tests before the PR.** `swift test` must be green.

## Where things live

See the Layout section in the [README](README.md#layout).

## Adding a database engine

1. Implement `DatabaseDriver` as an `actor` in `Sources/MieSQLCore/Drivers/`.
2. Add a case to `DatabaseKind` with its display name, default port and icon.
3. Teach `SQLDialect` its quoting and paging rules.
4. Register it in `DriverFactory`.
5. Add integration tests modelled on `SQLiteIntegrationTests`.

Drivers return `SQLValue` — values already rendered to text, with `NULL` kept distinct from
the empty string. If the wire format is binary, decode it in the driver, not in the UI.

## Adding a language

1. Add a case to `AppLanguage`.
2. Add a dictionary to `Translations` and register it in `Translations.table`.

You do not have to translate every key; missing ones fall back to English.

## Commit messages

Plain and descriptive. One logical change per commit where it is easy to do so.

## Reporting bugs

Please include: macOS version, database engine and version, what you ran, what you expected,
and what happened. If the app showed an error, the exact text is more useful than a summary.
