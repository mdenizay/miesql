//! Proves the two claims the PostgreSQL driver design rests on, against a real server:
//!
//! 1. `simple_query` reports the row description even when the query returns no rows,
//!    which is what fixes the Swift version's "zero rows shows no column headers".
//! 2. Every value arrives as text, whatever its type, so there is no binary decoding to
//!    write and no per-type decoder to keep correct.
//!
//! Skipped unless MIESQL_TEST_PG is set, so it never blocks a build on a machine with no
//! PostgreSQL to talk to.

use tokio_postgres::{NoTls, SimpleQueryMessage};

fn connection_string() -> Option<String> {
    std::env::var("MIESQL_TEST_PG").ok()
}

#[tokio::test]
async fn simple_query_reports_columns_even_with_no_rows() {
    let Some(dsn) = connection_string() else {
        eprintln!("skipping: MIESQL_TEST_PG is not set");
        return;
    };

    let (client, connection) = tokio_postgres::connect(&dsn, NoTls).await.expect("connect");
    tokio::spawn(async move {
        let _ = connection.await;
    });

    let messages = client
        .simple_query("SELECT id, name, amount FROM types_probe WHERE false")
        .await
        .expect("query");

    let mut saw_row_description = false;
    let mut row_count = 0;
    for message in &messages {
        match message {
            SimpleQueryMessage::RowDescription(columns) => {
                saw_row_description = true;
                let names: Vec<&str> = columns.iter().map(|c| c.name()).collect();
                assert_eq!(names, vec!["id", "name", "amount"]);
            }
            SimpleQueryMessage::Row(_) => row_count += 1,
            _ => {}
        }
    }

    assert!(saw_row_description, "no RowDescription for an empty result");
    assert_eq!(row_count, 0);
}

#[tokio::test]
async fn every_type_arrives_as_text() {
    let Some(dsn) = connection_string() else {
        eprintln!("skipping: MIESQL_TEST_PG is not set");
        return;
    };

    let (client, connection) = tokio_postgres::connect(&dsn, NoTls).await.expect("connect");
    tokio::spawn(async move {
        let _ = connection.await;
    });

    let messages = client
        .simple_query(
            "SELECT amount, ratio, when_ts, when_d, flag, ident, doc, tags, raw \
             FROM types_probe WHERE name = 'ada'",
        )
        .await
        .expect("query");

    let row = messages
        .iter()
        .find_map(|m| match m {
            SimpleQueryMessage::Row(row) => Some(row),
            _ => None,
        })
        .expect("one row");

    // Values are already rendered the way the server would print them.
    assert_eq!(row.get(0), Some("1234.5600"));
    assert_eq!(row.get(1), Some("0.5"));
    assert_eq!(row.get(4), Some("t"));
    assert_eq!(row.get(5), Some("12345678-9abc-def0-1234-56789abcdef0"));
    assert_eq!(row.get(7), Some("{a,b}"));
    assert_eq!(row.get(8), Some("\\x00ff10"));
    assert!(row.get(2).expect("timestamp").starts_with("2026-01-02"));
    assert_eq!(row.get(3), Some("2026-01-02"));
    assert!(row.get(6).expect("jsonb").contains("\"k\""));

    // NULL is distinguishable from an empty string, which the grid depends on.
    let null_messages = client
        .simple_query("SELECT amount, doc FROM types_probe WHERE name = 'nulls'")
        .await
        .expect("query");
    let null_row = null_messages
        .iter()
        .find_map(|m| match m {
            SimpleQueryMessage::Row(row) => Some(row),
            _ => None,
        })
        .expect("one row");
    assert_eq!(null_row.get(0), None);
    assert_eq!(null_row.get(1), None);
}

#[tokio::test]
async fn command_tag_reports_affected_rows() {
    let Some(dsn) = connection_string() else {
        eprintln!("skipping: MIESQL_TEST_PG is not set");
        return;
    };

    let (client, connection) = tokio_postgres::connect(&dsn, NoTls).await.expect("connect");
    tokio::spawn(async move {
        let _ = connection.await;
    });

    client
        .simple_query("CREATE TEMP TABLE affected_probe (id int)")
        .await
        .expect("create");
    let messages = client
        .simple_query("INSERT INTO affected_probe VALUES (1), (2), (3)")
        .await
        .expect("insert");

    let affected = messages.iter().find_map(|m| match m {
        SimpleQueryMessage::CommandComplete(rows) => Some(*rows),
        _ => None,
    });
    assert_eq!(affected, Some(3));
}
