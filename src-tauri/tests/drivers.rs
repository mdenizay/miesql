//! Driver behaviour against real databases. SQLite runs everywhere; the PostgreSQL cases
//! need a server and are skipped unless MIESQL_TEST_PG is set.
//!
//! Ported from the Swift integration suite: same scenarios, so the rewrite has to clear
//! the same bar.

use miesql_lib::drivers::{make_driver, Credentials, Driver};
use miesql_lib::models::*;

fn sqlite_profile(path: &str) -> ConnectionProfile {
    let mut profile = ConnectionProfile::new(DatabaseKind::Sqlite);
    profile.file_path = path.to_string();
    profile
}

async fn sqlite_driver(dir: &tempfile::TempDir, name: &str) -> Box<dyn Driver> {
    let path = dir.path().join(name);
    let mut driver = make_driver(Credentials::new(
        sqlite_profile(path.to_str().unwrap()),
        None,
    ))
    .unwrap();
    driver.connect().await.expect("connect");
    driver
}

async fn seed(driver: &mut Box<dyn Driver>) {
    driver
        .execute(
            "CREATE TABLE users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                email TEXT UNIQUE,
                age INTEGER,
                balance REAL,
                bio TEXT
             );
             CREATE INDEX idx_users_email ON users(email);
             CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                total REAL NOT NULL
             );
             INSERT INTO users (name, email, age, balance, bio) VALUES
                ('Ada Lovelace', 'ada@example.com', 36, 1250.75, 'First programmer'),
                ('Grace Hopper', 'grace@example.com', 85, 980.0, 'Compiler pioneer'),
                ('Alan Turing', 'alan@example.com', 41, NULL, NULL);
             INSERT INTO orders (user_id, total) VALUES (1, 99.9), (2, 12.0);",
        )
        .await
        .expect("seed");
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_queries_and_reports_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "a.sqlite").await;
    seed(&mut driver).await;

    let results = driver
        .execute("SELECT id, name, balance FROM users ORDER BY id")
        .await
        .unwrap();
    let result = &results[0];
    let names: Vec<&str> = result.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name", "balance"]);
    assert_eq!(result.rows.len(), 3);
    assert_eq!(result.rows[0].values[1].as_str(), "Ada Lovelace");
    // NULL must stay distinct from the empty string all the way to the grid.
    assert!(result.rows[2].values[2].is_null());

    let update = driver
        .execute("UPDATE users SET age = age + 1 WHERE id <= 2")
        .await
        .unwrap();
    assert_eq!(update[0].rows_affected, Some(2));
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_reports_columns_for_an_empty_result() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "empty.sqlite").await;
    seed(&mut driver).await;

    let results = driver
        .execute("SELECT id, name FROM users WHERE 1 = 0")
        .await
        .unwrap();
    assert!(results[0].rows.is_empty());
    // The Swift version could not do this for PostgreSQL; here it holds for every engine.
    let names: Vec<&str> = results[0].columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_reads_columns_indexes_and_foreign_keys() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "b.sqlite").await;
    seed(&mut driver).await;

    let tables = driver.list_tables("main", "").await.unwrap();
    let mut names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["orders", "users"]);

    let users = tables.iter().find(|t| t.name == "users").unwrap().clone();
    let details = driver.describe(&users).await.unwrap();
    let column_names: Vec<&str> = details.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(
        column_names,
        vec!["id", "name", "email", "age", "balance", "bio"]
    );
    assert_eq!(details.primary_key_columns(), vec!["id"]);
    assert!(
        !details
            .columns
            .iter()
            .find(|c| c.name == "name")
            .unwrap()
            .is_nullable
    );
    assert!(details
        .indexes
        .iter()
        .any(|i| i.name == "idx_users_email" && i.columns == vec!["email"]));
    assert_eq!(details.estimated_row_count, Some(3));

    let orders = tables.iter().find(|t| t.name == "orders").unwrap().clone();
    let order_details = driver.describe(&orders).await.unwrap();
    let key = &order_details.foreign_keys[0];
    assert_eq!(key.columns, vec!["user_id"]);
    assert_eq!(key.referenced_table, "users");
    assert_eq!(key.referenced_columns, vec!["id"]);

    let ddl = driver.create_statement(&users).await.unwrap();
    assert!(ddl.contains("CREATE TABLE users"));
    assert!(ddl.contains("idx_users_email"));
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_paging_and_counting_agree() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "c.sqlite").await;
    seed(&mut driver).await;

    let users = TableRef::new("main", "", "users");
    assert_eq!(driver.count_rows(&users, "").await.unwrap(), 3);
    assert_eq!(driver.count_rows(&users, "age > 40").await.unwrap(), 2);

    let order = [("id".to_string(), true)];
    let first = driver.fetch_rows(&users, "", &order, 2, 0).await.unwrap();
    assert_eq!(first.rows.len(), 2);

    let second = driver.fetch_rows(&users, "", &order, 2, 2).await.unwrap();
    assert_eq!(second.rows.len(), 1);
    assert_eq!(second.rows[0].values[1].as_str(), "Alan Turing");
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_read_only_connections_refuse_writes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("d.sqlite");
    let path_str = path.to_str().unwrap().to_string();

    let mut writable = make_driver(Credentials::new(sqlite_profile(&path_str), None)).unwrap();
    writable.connect().await.unwrap();
    seed(&mut writable).await;
    writable.disconnect().await;

    let mut profile = sqlite_profile(&path_str);
    profile.read_only = true;
    let mut guarded = make_driver(Credentials::new(profile, None)).unwrap();
    guarded.connect().await.unwrap();

    // Reads still work…
    let read = guarded.execute("SELECT COUNT(*) FROM users").await.unwrap();
    assert_eq!(read[0].rows[0].values[0].as_str(), "3");

    // …writes are stopped before they reach the file.
    let error = guarded.execute("DELETE FROM users").await.unwrap_err();
    assert_eq!(error.code.as_deref(), Some("MIESQL_READONLY"));
}

#[tokio::test(flavor = "multi_thread")]
async fn sqlite_renders_blobs_and_reals_predictably() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "types.sqlite").await;
    driver
        .execute(
            "CREATE TABLE t (r REAL, whole REAL, blob BLOB);
             INSERT INTO t VALUES (1250.75, 4.0, X'00FF10');",
        )
        .await
        .unwrap();

    let result = &driver
        .execute("SELECT r, whole, blob FROM t")
        .await
        .unwrap()[0];
    let row = &result.rows[0];
    assert_eq!(row.values[0].as_str(), "1250.75");
    // A whole float prints without a trailing .0 so a dump round-trips unchanged.
    assert_eq!(row.values[1].as_str(), "4");
    assert_eq!(row.values[2].as_str(), "X'00FF10'");
}

// MARK: - PostgreSQL

/// Parses the test URL the same way the app would, and keeps the password with it.
/// Dropping the password made these tests pass only against a server using trust
/// authentication, which is why they went green locally and failed in CI.
fn postgres_credentials() -> Option<Credentials> {
    let url = std::env::var("MIESQL_TEST_PG_URL").ok()?;
    let parsed = miesql_lib::connection_url::parse(&url).ok()?;
    Some(Credentials::new(parsed.profile, parsed.password))
}

#[tokio::test(flavor = "multi_thread")]
async fn postgres_round_trips_a_table() {
    let Some(credentials) = postgres_credentials() else {
        eprintln!("skipping: MIESQL_TEST_PG_URL is not set");
        return;
    };
    let mut driver = make_driver(credentials).unwrap();
    let info = driver.connect().await.expect("connect");
    assert_eq!(info.product_name, "PostgreSQL");

    driver
        .execute(
            "DROP TABLE IF EXISTS driver_probe;
             CREATE TABLE driver_probe (
                id serial PRIMARY KEY,
                name text NOT NULL,
                amount numeric(12,4),
                created timestamptz DEFAULT now()
             );
             CREATE INDEX idx_driver_probe_name ON driver_probe(name);
             INSERT INTO driver_probe (name, amount) VALUES ('ada', 1234.5600), ('grace', NULL);",
        )
        .await
        .expect("seed");

    let results = driver
        .execute("SELECT id, name, amount FROM driver_probe ORDER BY id")
        .await
        .unwrap();
    let result = &results[0];
    assert_eq!(result.rows.len(), 2);
    assert_eq!(result.rows[0].values[1].as_str(), "ada");
    // Values arrive already formatted by the server, with no binary decoding involved.
    assert_eq!(result.rows[0].values[2].as_str(), "1234.5600");
    assert!(result.rows[1].values[2].is_null());

    // The limitation that shipped in v0.1 is gone.
    let empty = driver
        .execute("SELECT id, name FROM driver_probe WHERE false")
        .await
        .unwrap();
    assert!(empty[0].rows.is_empty());
    let names: Vec<&str> = empty[0].columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);

    let affected = driver
        .execute("UPDATE driver_probe SET amount = 1 WHERE name = 'grace'")
        .await
        .unwrap();
    assert_eq!(affected[0].rows_affected, Some(1));

    let table = TableRef::new(&info.current_database, "public", "driver_probe");
    let details = driver.describe(&table).await.unwrap();
    assert_eq!(details.primary_key_columns(), vec!["id"]);
    assert!(
        details
            .columns
            .iter()
            .find(|c| c.name == "id")
            .unwrap()
            .is_auto_increment
    );
    assert!(
        !details
            .columns
            .iter()
            .find(|c| c.name == "name")
            .unwrap()
            .is_nullable
    );
    assert!(
        details
            .columns
            .iter()
            .find(|c| c.name == "amount")
            .unwrap()
            .is_nullable
    );
    assert!(details
        .indexes
        .iter()
        .any(|i| i.name == "idx_driver_probe_name" && i.columns == vec!["name"]));

    let ddl = driver.create_statement(&table).await.unwrap();
    assert!(ddl.contains("CREATE TABLE \"public\".\"driver_probe\""));
    assert!(ddl.contains("PRIMARY KEY (\"id\")"));

    assert_eq!(driver.count_rows(&table, "").await.unwrap(), 2);

    driver.execute("DROP TABLE driver_probe").await.unwrap();
    driver.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn postgres_reports_server_errors_with_their_sqlstate() {
    let Some(credentials) = postgres_credentials() else {
        eprintln!("skipping: MIESQL_TEST_PG_URL is not set");
        return;
    };
    let mut driver = make_driver(credentials).unwrap();
    driver.connect().await.expect("connect");

    let error = driver
        .execute("SELECT * FROM table_that_is_not_there")
        .await
        .unwrap_err();
    // 42P01 is undefined_table; showing the server's own code is more useful than ours.
    assert_eq!(error.code.as_deref(), Some("42P01"));
    assert!(error.message.contains("table_that_is_not_there"));
}
