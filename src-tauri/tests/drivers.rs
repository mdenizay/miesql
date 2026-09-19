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

// MARK: - Credential store

/// The bug this covers: an item written under one code signature cannot be overwritten
/// under another, which is every rebuild of an unsigned app and every update of a shipped
/// one. The write has to heal itself rather than surfacing an opaque platform error.
#[test]
fn saving_a_password_twice_overwrites_it() {
    // A headless machine has no Secret Service to write to. Skipping keeps the suite
    // runnable there; CI starts a real keyring so this path is still covered on Linux.
    if !miesql_lib::storage::credential_store_available() {
        eprintln!("skipping: no credential store on this machine");
        return;
    }
    let account = format!("miesql-test-{}", uuid::Uuid::new_v4());

    miesql_lib::storage::save_password(&account, "first").expect("first write");
    assert_eq!(
        miesql_lib::storage::load_password(&account).as_deref(),
        Some("first")
    );

    miesql_lib::storage::save_password(&account, "second").expect("second write");
    assert_eq!(
        miesql_lib::storage::load_password(&account).as_deref(),
        Some("second")
    );

    miesql_lib::storage::delete_password(&account);
    assert_eq!(miesql_lib::storage::load_password(&account), None);
}

// MARK: - MySQL and MariaDB

/// Skipped unless MIESQL_TEST_MYSQL_URL points at a server. CI starts one; locally a
/// throwaway instance on a spare port does the job.
fn mysql_credentials() -> Option<Credentials> {
    let url = std::env::var("MIESQL_TEST_MYSQL_URL").ok()?;
    let parsed = miesql_lib::connection_url::parse(&url).ok()?;
    Some(Credentials::new(parsed.profile, parsed.password))
}

#[tokio::test(flavor = "multi_thread")]
async fn mysql_round_trips_a_table() {
    let Some(credentials) = mysql_credentials() else {
        eprintln!("skipping: MIESQL_TEST_MYSQL_URL is not set");
        return;
    };
    let database = credentials.profile.database.clone();
    let mut driver = make_driver(credentials).unwrap();

    let info = driver.connect().await.expect("connect");
    // MySQL 9 defaults accounts to caching_sha2_password, which cannot authenticate over a
    // plaintext socket — reaching this line means the TLS path works.
    assert!(info.product_name == "MySQL" || info.product_name == "MariaDB");
    assert_eq!(info.current_database, database);

    let results = driver
        .execute("SELECT id, name, balance FROM users ORDER BY id")
        .await
        .unwrap();
    let result = &results[0];
    assert_eq!(
        result
            .columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        vec!["id", "name", "balance"]
    );
    assert_eq!(result.rows.len(), 3);
    assert_eq!(result.rows[0].values[1].as_str(), "Ada Lovelace");
    // DECIMAL keeps its scale, because the server rendered it, not us.
    assert_eq!(result.rows[0].values[2].as_str(), "1234.5600");
    assert!(result.rows[2].values[2].is_null());

    // The v0.1.0 limitation is gone here too: metadata arrives with the result set, not
    // with the rows.
    let empty = driver
        .execute("SELECT id, name FROM users WHERE 1 = 0")
        .await
        .unwrap();
    assert!(empty[0].rows.is_empty());
    assert_eq!(
        empty[0]
            .columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        vec!["id", "name"]
    );

    let updated = driver
        .execute("UPDATE users SET age = age + 1 WHERE id <= 2")
        .await
        .unwrap();
    assert_eq!(updated[0].rows_affected, Some(2));

    driver.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn mysql_reads_structure() {
    let Some(credentials) = mysql_credentials() else {
        eprintln!("skipping: MIESQL_TEST_MYSQL_URL is not set");
        return;
    };
    let database = credentials.profile.database.clone();
    let mut driver = make_driver(credentials).unwrap();
    driver.connect().await.expect("connect");

    let tables = driver.list_tables(&database, "").await.unwrap();
    let mut names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["orders", "users"]);

    let users = tables.iter().find(|t| t.name == "users").unwrap().clone();
    let details = driver.describe(&users).await.unwrap();
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
            .find(|c| c.name == "bio")
            .unwrap()
            .is_nullable
    );
    assert!(details
        .indexes
        .iter()
        .any(|i| i.name == "idx_users_email" && i.columns == vec!["email"]));
    assert_eq!(details.comment.as_deref(), Some("people"));

    let orders = tables.iter().find(|t| t.name == "orders").unwrap().clone();
    let order_details = driver.describe(&orders).await.unwrap();
    let key = order_details
        .foreign_keys
        .iter()
        .find(|k| k.name == "fk_orders_user")
        .expect("foreign key");
    assert_eq!(key.columns, vec!["user_id"]);
    assert_eq!(key.referenced_table, "users");
    assert_eq!(key.on_delete.as_deref(), Some("CASCADE"));

    // MySQL answers this one itself rather than having it rebuilt from the catalog.
    let ddl = driver.create_statement(&users).await.unwrap();
    assert!(ddl.contains("CREATE TABLE"));
    assert!(ddl.contains("`users`"));

    assert_eq!(driver.count_rows(&users, "").await.unwrap(), 3);
    assert_eq!(driver.count_rows(&users, "age > 40").await.unwrap(), 2);

    driver.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn mysql_reports_server_errors_and_honours_read_only() {
    let Some(credentials) = mysql_credentials() else {
        eprintln!("skipping: MIESQL_TEST_MYSQL_URL is not set");
        return;
    };

    let mut driver = make_driver(credentials.clone()).unwrap();
    driver.connect().await.expect("connect");
    let error = driver
        .execute("SELECT * FROM table_that_is_not_there")
        .await
        .unwrap_err();
    // 42S02 is the SQLSTATE for an unknown table; the server's own wording is kept.
    assert_eq!(error.code.as_deref(), Some("42S02"));
    driver.disconnect().await;

    let mut read_only = credentials;
    read_only.profile.read_only = true;
    let mut guarded = make_driver(read_only).unwrap();
    guarded.connect().await.expect("connect");
    assert!(guarded.execute("SELECT 1").await.is_ok());
    let blocked = guarded.execute("DELETE FROM users").await.unwrap_err();
    assert_eq!(blocked.code.as_deref(), Some("MIESQL_READONLY"));
    guarded.disconnect().await;
}

// MARK: - Redis

/// Skipped unless MIESQL_TEST_REDIS_URL is set. The tests write only under their own key
/// prefix and delete it afterwards, so pointing this at a populated server is safe.
fn redis_credentials() -> Option<Credentials> {
    let url = std::env::var("MIESQL_TEST_REDIS_URL").ok()?;
    let parsed = miesql_lib::connection_url::parse(&url).ok()?;
    Some(Credentials::new(parsed.profile, parsed.password))
}

#[tokio::test(flavor = "multi_thread")]
async fn redis_browses_a_keyspace() {
    let Some(credentials) = redis_credentials() else {
        eprintln!("skipping: MIESQL_TEST_REDIS_URL is not set");
        return;
    };
    let database = format!("db{}", credentials.profile.database);
    let mut driver = make_driver(credentials).unwrap();

    let info = driver.connect().await.expect("connect");
    assert_eq!(info.product_name, "Redis");
    assert!(!info.version.is_empty());

    // A prefix of our own, so this is safe against a server holding real data.
    let ns = format!("miesqltest{}", std::process::id());
    driver
        .execute(&format!(
            "SET {ns}:user:1 Ada\nSET {ns}:user:2 Grace\nHSET {ns}:cfg theme dark lang en\nRPUSH {ns}:queue a b c\nEXPIRE {ns}:user:2 600"
        ))
        .await
        .expect("seed");

    // The namespace shows up in the tree.
    let tables = driver.list_tables(&database, "").await.unwrap();
    assert!(
        tables.iter().any(|t| t.name == ns),
        "namespace {ns} missing from {:?}",
        tables.iter().map(|t| &t.name).collect::<Vec<_>>()
    );

    let table = tables.into_iter().find(|t| t.name == ns).unwrap();
    assert_eq!(table.kind, TableKind::Collection);

    let page = driver.fetch_rows(&table, "", &[], 50, 0).await.unwrap();
    assert_eq!(
        page.columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        vec!["key", "type", "ttl", "value"]
    );
    assert_eq!(page.rows.len(), 4);

    let row_for = |key: &str| {
        page.rows
            .iter()
            .find(|r| r.values[0].as_str() == key)
            .unwrap_or_else(|| panic!("no row for {key}"))
    };
    assert_eq!(
        row_for(&format!("{ns}:user:1")).values[1].as_str(),
        "string"
    );
    assert_eq!(row_for(&format!("{ns}:cfg")).values[1].as_str(), "hash");
    assert_eq!(row_for(&format!("{ns}:queue")).values[1].as_str(), "list");
    // A key with no expiry reports NULL rather than Redis's -1 sentinel.
    assert!(row_for(&format!("{ns}:user:1")).values[2].is_null());
    assert!(!row_for(&format!("{ns}:user:2")).values[2].is_null());
    assert_eq!(row_for(&format!("{ns}:user:1")).values[3].as_str(), "Ada");

    // Replies of different shapes land in the grid sensibly.
    let hash = driver.execute(&format!("HGETALL {ns}:cfg")).await.unwrap();
    assert_eq!(hash[0].rows.len(), 2);

    let list = driver
        .execute(&format!("LRANGE {ns}:queue 0 -1"))
        .await
        .unwrap();
    assert_eq!(list[0].rows.len(), 3);
    assert_eq!(list[0].rows[0].values[0].as_str(), "a");

    let scalar = driver.execute(&format!("GET {ns}:user:1")).await.unwrap();
    assert_eq!(scalar[0].rows[0].values[0].as_str(), "Ada");

    // A quoted argument survives the split, the way redis-cli handles it.
    driver
        .execute(&format!("SET {ns}:quoted \"two words\""))
        .await
        .unwrap();
    let quoted = driver.execute(&format!("GET {ns}:quoted")).await.unwrap();
    assert_eq!(quoted[0].rows[0].values[0].as_str(), "two words");

    // Clean up after ourselves; the server may not be ours.
    driver
        .execute(&format!(
            "DEL {ns}:user:1 {ns}:user:2 {ns}:cfg {ns}:queue {ns}:quoted"
        ))
        .await
        .unwrap();
    driver.disconnect().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn redis_read_only_blocks_writes_but_not_reads() {
    let Some(mut credentials) = redis_credentials() else {
        eprintln!("skipping: MIESQL_TEST_REDIS_URL is not set");
        return;
    };
    credentials.profile.read_only = true;
    let mut driver = make_driver(credentials).unwrap();
    driver.connect().await.expect("connect");

    assert!(driver.execute("PING").await.is_ok());
    assert!(driver.execute("DBSIZE").await.is_ok());

    // Redis has no read-only client mode, so this guard is ours to enforce.
    let blocked = driver.execute("SET should_not_exist 1").await.unwrap_err();
    assert_eq!(blocked.code.as_deref(), Some("MIESQL_READONLY"));
    let flush = driver.execute("FLUSHDB").await.unwrap_err();
    assert_eq!(flush.code.as_deref(), Some("MIESQL_READONLY"));

    driver.disconnect().await;
}

/// Cancelling has to work while the query is still running, which is the whole point:
/// the driver is borrowed by `execute` for the entire call, so the handle has to come
/// from somewhere else. A recursive CTE with no natural end gives a query that will not
/// finish on its own, so if the test returns at all, the interrupt is what ended it.
#[tokio::test(flavor = "multi_thread")]
async fn sqlite_cancels_a_running_query() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "cancel.sqlite").await;
    let cancel = driver.cancel_slot();

    let canceller = cancel.get().expect("SQLite publishes a cancel handle");
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        canceller.cancel().await.expect("cancel");
    });

    let started = std::time::Instant::now();
    let outcome = driver
        .execute(
            "WITH RECURSIVE forever(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM forever) \
             SELECT count(*) FROM forever",
        )
        .await;

    assert!(outcome.is_err(), "the query should have been interrupted");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(20),
        "the interrupt should stop the query promptly, not eventually"
    );

    // The connection stays usable: cancelling a statement is not disconnecting.
    let after = driver.execute("SELECT 1").await.expect("still connected");
    assert_eq!(after[0].rows.len(), 1);
}

/// A connection with nothing to cancel still answers, rather than the command failing in
/// a way the UI would have to special-case.
#[tokio::test(flavor = "multi_thread")]
async fn cancelling_an_idle_connection_is_harmless() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "idle.sqlite").await;
    driver.cancel_slot().get().unwrap().cancel().await.unwrap();
    driver.execute("SELECT 1").await.expect("unaffected");
}

/// PostgreSQL cancels over a second connection carrying the backend key, so unlike SQLite
/// this exercises real network behaviour — and proves the key stays valid for the session
/// rather than only for the statement it was taken during.
#[tokio::test(flavor = "multi_thread")]
async fn postgres_cancels_a_running_query() {
    let Some(credentials) = postgres_credentials() else {
        eprintln!("skipping: MIESQL_TEST_PG_URL is not set");
        return;
    };
    let mut driver = make_driver(credentials).unwrap();
    driver.connect().await.expect("connect");

    let canceller = driver
        .cancel_slot()
        .get()
        .expect("PostgreSQL publishes a cancel handle");
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        canceller.cancel().await.expect("cancel");
    });

    let started = std::time::Instant::now();
    let outcome = driver.execute("SELECT pg_sleep(30)").await;

    assert!(outcome.is_err(), "the query should have been cancelled");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(10),
        "cancelling should not wait for the query to end on its own"
    );
    // The session survives: `pg_cancel_backend` semantics, not `pg_terminate_backend`.
    let after = driver.execute("SELECT 1").await.expect("still connected");
    assert_eq!(after[0].rows.len(), 1);
}

/// MySQL has no out-of-band cancel, so this proves the `KILL QUERY` path: a second login
/// ends the statement while leaving the session alive.
#[tokio::test(flavor = "multi_thread")]
async fn mysql_cancels_a_running_query() {
    let Some(credentials) = mysql_credentials() else {
        eprintln!("skipping: MIESQL_TEST_MYSQL_URL is not set");
        return;
    };
    let mut driver = make_driver(credentials).unwrap();
    driver.connect().await.expect("connect");

    let canceller = driver
        .cancel_slot()
        .get()
        .expect("MySQL publishes a cancel handle");
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        canceller.cancel().await.expect("cancel");
    });

    let started = std::time::Instant::now();
    let outcome = driver.execute("SELECT SLEEP(30)").await;

    assert!(outcome.is_err(), "the query should have been killed");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(10),
        "KILL QUERY should land while the statement is still running"
    );
    let after = driver.execute("SELECT 1").await.expect("still connected");
    assert_eq!(after[0].rows.len(), 1);
}

/// Completion is only useful if it knows columns, not just table names, and only cheap if
/// the whole schema arrives at once.
#[tokio::test(flavor = "multi_thread")]
async fn sqlite_lists_every_column_in_the_schema_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let mut driver = sqlite_driver(&dir, "columns.sqlite").await;
    seed(&mut driver).await;

    let columns = driver.schema_columns("main", "").await.expect("columns");
    assert_eq!(
        columns.get("users").map(Vec::as_slice),
        Some(
            ["id", "name", "email", "age", "balance", "bio"]
                .map(String::from)
                .as_slice()
        ),
        "columns come back in declaration order"
    );
    assert!(columns.contains_key("orders"), "every table is covered");
}

#[tokio::test(flavor = "multi_thread")]
async fn postgres_lists_every_column_in_the_schema_at_once() {
    let Some(credentials) = postgres_credentials() else {
        eprintln!("skipping: MIESQL_TEST_PG_URL is not set");
        return;
    };
    let mut driver = make_driver(credentials).unwrap();
    let info = driver.connect().await.expect("connect");
    driver
        .execute("DROP TABLE IF EXISTS completion_probe; CREATE TABLE completion_probe (id int, label text)")
        .await
        .expect("seed");

    let columns = driver
        .schema_columns(&info.current_database, "public")
        .await
        .expect("columns");
    assert_eq!(
        columns.get("completion_probe").map(Vec::as_slice),
        Some(["id", "label"].map(String::from).as_slice())
    );
    driver.execute("DROP TABLE completion_probe").await.ok();
}
