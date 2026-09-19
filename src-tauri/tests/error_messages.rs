//! A connection failure has to say what to do about it. "invalid configuration" does not.

use miesql_lib::drivers::{make_driver, Credentials};
use miesql_lib::models::{ConnectionProfile, DatabaseKind, SslMode};

#[tokio::test(flavor = "multi_thread")]
async fn a_missing_password_explains_itself() {
    let Ok(url) = std::env::var("MIESQL_TEST_PG_URL") else {
        eprintln!("skipping: MIESQL_TEST_PG_URL is not set");
        return;
    };
    let parsed = miesql_lib::connection_url::parse(&url).unwrap();
    if parsed.password.is_none() {
        eprintln!("skipping: the test server does not require a password");
        return;
    }

    // Same profile, password deliberately withheld — the shape of the bug a failed
    // keychain write produces.
    let mut driver = make_driver(Credentials::new(parsed.profile, None)).unwrap();
    let error = driver.connect().await.unwrap_err();

    assert!(
        !error.message.contains("invalid configuration"),
        "the raw driver wording leaked through: {}",
        error.message
    );
    assert!(
        error.message.to_lowercase().contains("password"),
        "the message should name the missing password: {}",
        error.message
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unreachable_host_does_not_say_invalid_configuration() {
    let mut profile = ConnectionProfile::new(DatabaseKind::Postgres);
    profile.host = "127.0.0.1".into();
    // Nothing listens here; the message should be about reaching the server.
    profile.port = 1;
    profile.username = "nobody".into();
    profile.database = "nothing".into();
    profile.ssl_mode = SslMode::Disable;
    profile.connect_timeout_seconds = 3;

    let mut driver = make_driver(Credentials::new(profile, Some("x".into()))).unwrap();
    let error = driver.connect().await.unwrap_err();
    assert!(!error.message.is_empty());
    assert!(
        !error.message.contains("invalid configuration"),
        "{}",
        error.message
    );
}
