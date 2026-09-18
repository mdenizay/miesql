//! The Tauri command surface: the only way the UI reaches the core.
//!
//! Commands take and return plain serialisable types, and every failure comes back as a
//! `DbError` carrying the server's own wording.

use crate::drivers::{make_driver, Credentials};
use crate::error::DbError;
use crate::models::*;
use crate::state::AppState;
use crate::{connection_url, storage};
use tauri::State;
use uuid::Uuid;

type R<T> = std::result::Result<T, DbError>;

// MARK: - Profiles

#[tauri::command]
pub fn list_profiles() -> Vec<ConnectionProfile> {
    storage::load_profiles()
}

#[tauri::command]
pub fn save_profile(
    profile: ConnectionProfile,
    password: Option<String>,
) -> R<Vec<ConnectionProfile>> {
    let mut profiles = storage::load_profiles();
    match profiles.iter_mut().find(|p| p.id == profile.id) {
        Some(existing) => *existing = profile.clone(),
        None => profiles.push(profile.clone()),
    }
    storage::save_profiles(&profiles)?;

    let account = profile.credential_account();
    match (profile.save_password, password) {
        (true, Some(password)) if !password.is_empty() => {
            storage::save_password(&account, &password)?
        }
        (false, _) => storage::delete_password(&account),
        _ => {}
    }
    Ok(profiles)
}

#[tauri::command]
pub fn delete_profile(id: Uuid) -> R<Vec<ConnectionProfile>> {
    let mut profiles = storage::load_profiles();
    if let Some(profile) = profiles.iter().find(|p| p.id == id) {
        storage::delete_password(&profile.credential_account());
    }
    profiles.retain(|p| p.id != id);
    storage::save_profiles(&profiles)?;
    Ok(profiles)
}

// MARK: - Connection URLs

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParsedUrlPayload {
    pub profile: ConnectionProfile,
    pub password: Option<String>,
    pub warnings: Vec<String>,
}

#[tauri::command]
pub fn parse_connection_url(url: String) -> R<ParsedUrlPayload> {
    let parsed = connection_url::parse(&url).map_err(|e| DbError::new(e.to_string()))?;
    Ok(ParsedUrlPayload {
        profile: parsed.profile,
        password: parsed.password,
        warnings: parsed.warnings,
    })
}

#[tauri::command]
pub fn looks_like_connection_url(text: String) -> bool {
    connection_url::looks_like_connection_url(&text)
}

/// Builds a shareable URL. The password is left out, so this is safe to paste anywhere.
#[tauri::command]
pub fn connection_url_for_profile(profile: ConnectionProfile) -> String {
    connection_url::to_string(&profile, None, false)
}

// MARK: - Sessions

fn resolve_password(profile: &ConnectionProfile, given: Option<String>) -> Option<String> {
    given.filter(|p| !p.is_empty()).or_else(|| {
        profile
            .save_password
            .then(|| storage::load_password(&profile.credential_account()))
            .flatten()
    })
}

#[tauri::command]
pub async fn connect(
    state: State<'_, AppState>,
    profile: ConnectionProfile,
    password: Option<String>,
) -> R<ServerInfo> {
    let password = resolve_password(&profile, password);
    let id = profile.id;
    let mut driver = make_driver(Credentials::new(profile, password))?;
    let info = driver.connect().await?;
    state.insert(id, driver, info.clone()).await;
    Ok(info)
}

/// Opens and closes a connection without adding it to the sidebar.
#[tauri::command]
pub async fn test_connection(
    profile: ConnectionProfile,
    password: Option<String>,
) -> R<ServerInfo> {
    let password = resolve_password(&profile, password);
    let mut driver = make_driver(Credentials::new(profile, password))?;
    let info = driver.connect().await?;
    driver.disconnect().await;
    Ok(info)
}

#[tauri::command]
pub async fn disconnect(state: State<'_, AppState>, id: Uuid) -> R<()> {
    if let Some(session) = state.remove(id).await {
        session.driver.lock().await.disconnect().await;
    }
    Ok(())
}

#[tauri::command]
pub async fn open_connection_ids(state: State<'_, AppState>) -> R<Vec<Uuid>> {
    Ok(state.open_ids().await)
}

// MARK: - Queries

#[tauri::command]
pub async fn execute_sql(
    state: State<'_, AppState>,
    id: Uuid,
    sql: String,
    max_rows: Option<usize>,
) -> R<Vec<QueryResult>> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    let mut results = driver.execute(&sql).await?;

    // A runaway SELECT should not fill memory; the cap is a user setting, and the grid is
    // told it was applied rather than silently showing a truncated answer.
    if let Some(cap) = max_rows.filter(|c| *c > 0) {
        for result in results.iter_mut() {
            if result.rows.len() > cap {
                result.rows.truncate(cap);
                result
                    .messages
                    .push(format!("Showing the first {cap} rows."));
            }
        }
    }
    Ok(results)
}

#[tauri::command]
pub async fn list_databases(state: State<'_, AppState>, id: Uuid) -> R<Vec<String>> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.list_databases().await
}

#[tauri::command]
pub async fn list_schemas(
    state: State<'_, AppState>,
    id: Uuid,
    database: String,
) -> R<Vec<String>> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.list_schemas(&database).await
}

#[tauri::command]
pub async fn list_tables(
    state: State<'_, AppState>,
    id: Uuid,
    database: String,
    schema: String,
) -> R<Vec<TableRef>> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.list_tables(&database, &schema).await
}

#[tauri::command]
pub async fn describe_table(
    state: State<'_, AppState>,
    id: Uuid,
    table: TableRef,
) -> R<TableDetails> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.describe(&table).await
}

#[tauri::command]
pub async fn create_statement(state: State<'_, AppState>, id: Uuid, table: TableRef) -> R<String> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.create_statement(&table).await
}

#[tauri::command]
pub async fn use_database(state: State<'_, AppState>, id: Uuid, database: String) -> R<()> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.use_database(&database).await
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchRowsArgs {
    pub table: TableRef,
    #[serde(default)]
    pub where_clause: String,
    #[serde(default)]
    pub order_by: Vec<(String, bool)>,
    pub limit: u64,
    pub offset: u64,
}

#[tauri::command]
pub async fn fetch_rows(
    state: State<'_, AppState>,
    id: Uuid,
    args: FetchRowsArgs,
) -> R<QueryResult> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver
        .fetch_rows(
            &args.table,
            &args.where_clause,
            &args.order_by,
            args.limit,
            args.offset,
        )
        .await
}

#[tauri::command]
pub async fn count_rows(
    state: State<'_, AppState>,
    id: Uuid,
    table: TableRef,
    where_clause: String,
) -> R<i64> {
    let session = state.get(id).await?;
    let mut driver = session.driver.lock().await;
    driver.count_rows(&table, &where_clause).await
}

// MARK: - Settings, history, snippets

#[tauri::command]
pub fn get_settings() -> storage::AppSettings {
    storage::load_settings()
}

#[tauri::command]
pub fn set_settings(settings: storage::AppSettings) -> R<()> {
    storage::save_settings(&settings)
}

#[tauri::command]
pub fn get_history() -> Vec<storage::HistoryEntry> {
    storage::load_history()
}

#[tauri::command]
pub fn add_history(entry: storage::HistoryEntry, limit: usize) -> R<Vec<storage::HistoryEntry>> {
    storage::append_history(entry, limit)
}

#[tauri::command]
pub fn clear_history() -> R<()> {
    storage::clear_history()
}

#[tauri::command]
pub fn get_snippets() -> Vec<storage::Snippet> {
    storage::load_snippets()
}

#[tauri::command]
pub fn set_snippets(snippets: Vec<storage::Snippet>) -> R<()> {
    storage::save_snippets(&snippets)
}

/// Whether this machine can store a password at all, so the connection editor can warn
/// instead of letting someone tick "Save password" and discover later that it did nothing.
#[tauri::command]
pub fn credential_store_available() -> bool {
    storage::credential_store_available()
}

/// Where everything is kept, shown in Settings so the privacy claim is checkable.
#[tauri::command]
pub fn data_directory() -> String {
    storage::support_dir().to_string_lossy().to_string()
}
