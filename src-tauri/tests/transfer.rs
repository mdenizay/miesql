//! Dump, restore, export and row editing. The cases are ported from the Swift suite the
//! v0.1.0 release shipped with, plus a real round trip through SQLite.

use miesql_lib::drivers::{make_driver, Credentials, Driver};
use miesql_lib::models::*;
use miesql_lib::transfer::csv_import::{self, CsvOptions};
use miesql_lib::transfer::dump::{self, DumpOptions};
use miesql_lib::transfer::export::{self, ExportFormat, ExportOptions};
use miesql_lib::transfer::row_edit::{RowEdit, RowEditPlanner};
use std::collections::BTreeMap;

fn map(pairs: &[(&str, SqlValue)]) -> BTreeMap<String, SqlValue> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

// MARK: - Row editing

#[test]
fn update_matches_on_the_full_primary_key() {
    let planner = RowEditPlanner::new(
        DatabaseKind::Postgres,
        TableRef::new("app", "public", "users"),
        vec!["id".into()],
    );
    let planned = planner
        .plan(&[RowEdit::Update {
            row_id: 0,
            changes: map(&[("name", SqlValue::text("Ada"))]),
            original: map(&[
                ("id", SqlValue::text("7")),
                ("name", SqlValue::text("Grace")),
            ]),
        }])
        .unwrap();
    assert_eq!(
        planned[0].sql,
        "UPDATE \"public\".\"users\" SET \"name\" = 'Ada' WHERE \"id\" = '7';"
    );
}

#[test]
fn null_key_parts_use_is_null() {
    let planner = RowEditPlanner::new(
        DatabaseKind::Sqlite,
        TableRef::new("main", "", "t"),
        vec!["a".into(), "b".into()],
    );
    let planned = planner
        .plan(&[RowEdit::Delete {
            row_id: 0,
            original: map(&[("a", SqlValue::text("1")), ("b", SqlValue::Null)]),
        }])
        .unwrap();
    // `= NULL` matches nothing, which would silently delete zero rows.
    assert_eq!(
        planned[0].sql,
        "DELETE FROM \"t\" WHERE \"a\" = '1' AND \"b\" IS NULL;"
    );
}

#[test]
fn a_table_without_a_key_is_refused() {
    let planner = RowEditPlanner::new(
        DatabaseKind::Mysql,
        TableRef::new("app", "", "users"),
        Vec::new(),
    );
    let error = planner
        .plan(&[RowEdit::Delete {
            row_id: 0,
            original: map(&[("id", SqlValue::text("1"))]),
        }])
        .unwrap_err();
    assert!(error.message.contains("no primary key"));
}

#[test]
fn inserts_do_not_need_a_key() {
    let planner = RowEditPlanner::new(
        DatabaseKind::Mysql,
        TableRef::new("app", "", "users"),
        Vec::new(),
    );
    let planned = planner
        .plan(&[RowEdit::Insert {
            row_id: 0,
            values: map(&[("name", SqlValue::text("Ada"))]),
        }])
        .unwrap();
    assert_eq!(
        planned[0].sql,
        "INSERT INTO `users` (`name`) VALUES ('Ada');"
    );
}

#[test]
fn edited_values_are_escaped() {
    let planner = RowEditPlanner::new(
        DatabaseKind::Postgres,
        TableRef::new("app", "public", "t"),
        vec!["id".into()],
    );
    let planned = planner
        .plan(&[RowEdit::Update {
            row_id: 0,
            changes: map(&[("note", SqlValue::text("it's a 'quote'"))]),
            original: map(&[("id", SqlValue::text("1"))]),
        }])
        .unwrap();
    assert!(planned[0].sql.contains("'it''s a ''quote'''"));
}

// MARK: - Exporting

fn sample() -> (Vec<ColumnInfo>, Vec<ResultRow>) {
    (
        vec![
            ColumnInfo::new(0, "id", "int4"),
            ColumnInfo::new(1, "name", "text"),
        ],
        vec![
            ResultRow {
                id: 0,
                values: vec![SqlValue::text("1"), SqlValue::text("Ada")],
            },
            ResultRow {
                id: 1,
                values: vec![SqlValue::text("2"), SqlValue::Null],
            },
            ResultRow {
                id: 2,
                values: vec![SqlValue::text("3"), SqlValue::text("say \"hi\", ok")],
            },
        ],
    )
}

fn options(format: ExportFormat) -> ExportOptions {
    ExportOptions {
        format,
        include_header: true,
        null_placeholder: String::new(),
        table_name: "people".into(),
        kind: DatabaseKind::Postgres,
    }
}

#[test]
fn csv_quotes_separators_and_quotes() {
    let (columns, rows) = sample();
    let csv = export::export(&columns, &rows, &options(ExportFormat::Csv));
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(lines[0], "id,name");
    assert_eq!(lines[1], "1,Ada");
    // NULL becomes an empty field, the CSV convention.
    assert_eq!(lines[2], "2,");
    assert_eq!(lines[3], "3,\"say \"\"hi\"\", ok\"");
}

#[test]
fn json_renders_null_as_null() {
    let (columns, rows) = sample();
    let json = export::export(&columns, &rows, &options(ExportFormat::Json));
    assert!(json.contains("\"name\": null"));
    assert!(json.contains("\"name\": \"say \\\"hi\\\", ok\""));
}

#[test]
fn sql_inserts_escape_values_and_quote_identifiers() {
    let (columns, rows) = sample();
    let sql = export::export(&columns, &rows, &options(ExportFormat::SqlInsert));
    assert!(sql.contains("INSERT INTO \"people\" (\"id\", \"name\") VALUES ('1', 'Ada');"));
    assert!(sql.contains("VALUES ('2', NULL);"));
}

// MARK: - CSV parsing

#[test]
fn csv_parses_quoted_fields_and_embedded_quotes() {
    let rows = csv_import::parse("a,b\n1,\"x,y\"\n2,\"he said \"\"no\"\"\"\n", ',');
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[1], vec!["1", "x,y"]);
    assert_eq!(rows[2], vec!["2", "he said \"no\""]);
}

#[test]
fn csv_keeps_a_newline_inside_a_quoted_field() {
    let rows = csv_import::parse("a,b\n1,\"line one\nline two\"\n", ',');
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1][1], "line one\nline two");
}

// MARK: - Dump and restore, against a real database

async fn sqlite_driver(path: &str) -> Box<dyn Driver> {
    let mut profile = ConnectionProfile::new(DatabaseKind::Sqlite);
    profile.file_path = path.to_string();
    let mut driver = make_driver(Credentials::new(profile, None)).unwrap();
    driver.connect().await.expect("connect");
    driver
}

#[tokio::test(flavor = "multi_thread")]
async fn a_dump_restores_into_an_identical_database() {
    let dir = tempfile::tempdir().unwrap();
    let source_path = dir.path().join("source.sqlite");
    let dump_path = dir.path().join("dump.sql");

    let mut source = sqlite_driver(source_path.to_str().unwrap()).await;
    source
        .execute(
            "CREATE TABLE users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                balance REAL,
                bio TEXT
             );
             CREATE INDEX idx_users_name ON users(name);
             INSERT INTO users (name, balance, bio) VALUES
                ('Ada Lovelace', 1250.75, 'First programmer'),
                ('Grace Hopper', 980.0, 'Compiler pioneer'),
                ('Alan Turing', NULL, NULL);",
        )
        .await
        .expect("seed");

    let tables = source.list_tables("main", "").await.unwrap();
    let summary = dump::dump(
        &mut source,
        &tables,
        &DumpOptions {
            rows_per_insert: 2,
            ..Default::default()
        },
        dump_path.to_str().unwrap(),
        |_| {},
    )
    .await
    .expect("dump");

    assert_eq!(summary.rows, 3);
    assert!(summary.bytes > 0);

    let script = std::fs::read_to_string(&dump_path).unwrap();
    assert!(script.contains("CREATE TABLE users"));
    assert!(script.contains("'Ada Lovelace'"));
    // Numbers are written unquoted so the restored column keeps its type affinity.
    assert!(script.contains("1250.75"));
    assert!(script.contains("NULL"));
    source.disconnect().await;

    let restored_path = dir.path().join("restored.sqlite");
    let mut restored = sqlite_driver(restored_path.to_str().unwrap()).await;
    let run = dump::run_script(&mut restored, &script, true, |_| {})
        .await
        .expect("restore");

    assert!(run.failures.is_empty(), "failures: {:?}", run.failures);
    assert_eq!(run.succeeded, run.total);

    let rows = restored
        .execute("SELECT id, name, balance, bio FROM users ORDER BY id")
        .await
        .unwrap();
    let rows = &rows[0].rows;
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0].values[1].as_str(), "Ada Lovelace");
    assert_eq!(rows[0].values[2].as_str(), "1250.75");
    // NULL has to survive the round trip as NULL, not as an empty string.
    assert!(rows[2].values[2].is_null());
    assert!(rows[2].values[3].is_null());

    restored.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_structure_only_dump_carries_no_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.sqlite");
    let out = dir.path().join("schema.sql");

    let mut driver = sqlite_driver(path.to_str().unwrap()).await;
    driver
        .execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t VALUES (1, 'x');")
        .await
        .unwrap();

    let tables = driver.list_tables("main", "").await.unwrap();
    dump::dump(
        &mut driver,
        &tables,
        &DumpOptions {
            include_data: false,
            ..Default::default()
        },
        out.to_str().unwrap(),
        |_| {},
    )
    .await
    .unwrap();

    let script = std::fs::read_to_string(&out).unwrap();
    assert!(script.contains("CREATE TABLE t"));
    assert!(!script.contains("INSERT INTO"));
    driver.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn csv_import_inserts_the_mapped_columns() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("i.sqlite");
    let csv = dir.path().join("people.csv");

    let mut driver = sqlite_driver(db.to_str().unwrap()).await;
    driver
        .execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, age INTEGER)")
        .await
        .unwrap();

    std::fs::write(
        &csv,
        "name,email,age\nKatherine Johnson,katherine@example.com,101\n\"Hamilton, Margaret\",margaret@example.com,88\n",
    )
    .unwrap();

    let table = TableRef::new("main", "", "users");
    let statements = csv_import::statements(
        csv.to_str().unwrap(),
        &table,
        DatabaseKind::Sqlite,
        &CsvOptions::default(),
    )
    .unwrap();

    for statement in &statements {
        driver.execute(statement).await.unwrap();
    }

    let result = driver
        .execute("SELECT name FROM users ORDER BY age")
        .await
        .unwrap();
    let names: Vec<&str> = result[0]
        .rows
        .iter()
        .map(|r| r.values[0].as_str())
        .collect();
    // The comma inside the quoted field must not have split the row.
    assert_eq!(names, vec!["Hamilton, Margaret", "Katherine Johnson"]);

    driver.disconnect().await;
}
