//! Everything MieSQL writes lives under one folder, so "all data stays on this device" is
//! something a user can verify by looking at a single directory. Passwords are the one
//! exception: they go to the OS credential store, never to a file here.

use crate::error::{DbError, DbResult};
use crate::models::ConnectionProfile;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub fn support_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| dirs::home_dir().unwrap_or_default());
    let dir = base.join("MieSQL");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn connections_file() -> PathBuf {
    support_dir().join("connections.json")
}
fn settings_file() -> PathBuf {
    support_dir().join("settings.json")
}
fn history_file() -> PathBuf {
    support_dir().join("query-history.json")
}
fn snippets_file() -> PathBuf {
    support_dir().join("snippets.json")
}

/// Writes through a temporary file so an interrupted save cannot leave a half-written
/// file behind.
fn write_atomic<T: Serialize>(path: &PathBuf, value: &T) -> DbResult<()> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|e| DbError::new(format!("Could not encode {}: {e}", path.display())))?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, json)
        .map_err(|e| DbError::new(format!("Could not write {}: {e}", temporary.display())))?;
    std::fs::rename(&temporary, path)
        .map_err(|e| DbError::new(format!("Could not replace {}: {e}", path.display())))?;
    restrict_permissions(path);
    Ok(())
}

/// The connection file holds host names and usernames, so it stays readable only by its
/// owner. A no-op on Windows, where the user profile directory already does this.
fn restrict_permissions(path: &PathBuf) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

fn read_or_default<T: for<'de> Deserialize<'de> + Default>(path: &PathBuf) -> T {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

// MARK: - Connections

pub fn load_profiles() -> Vec<ConnectionProfile> {
    read_or_default::<Vec<ConnectionProfile>>(&connections_file())
}

pub fn save_profiles(profiles: &[ConnectionProfile]) -> DbResult<()> {
    write_atomic(&connections_file(), &profiles)
}

// MARK: - Credentials

const CREDENTIAL_SERVICE: &str = "app.miesql.connections";

/// Writes a password, healing the case where an item already exists under a different
/// code signature.
///
/// macOS ties a keychain item to the identity that created it. An unsigned or ad-hoc
/// signed app gets a new identity on every build, so an item written by yesterday's build —
/// or by a previous version of MieSQL entirely — is one this build is not allowed to
/// overwrite, and the write comes back as an opaque "platform secure storage failure".
/// Removing the stale item and writing fresh turns that dead end into a no-op the user
/// never sees.
pub fn save_password(account: &str, password: &str) -> DbResult<()> {
    let entry = keyring::Entry::new(CREDENTIAL_SERVICE, account)
        .map_err(|e| credential_error("open the credential store", &e))?;

    match entry.set_password(password) {
        Ok(()) => Ok(()),
        Err(first) => {
            let _ = entry.delete_credential();
            entry
                .set_password(password)
                // Two failures in a row is a real problem, not a stale item.
                .map_err(|_| credential_error("save the password", &first))
        }
    }
}

/// A password that cannot be read is treated as one that was never saved: the app asks
/// for it again rather than failing. That is what makes the signature change above
/// recoverable instead of fatal.
pub fn load_password(account: &str) -> Option<String> {
    keyring::Entry::new(CREDENTIAL_SERVICE, account)
        .ok()?
        .get_password()
        .ok()
}

pub fn delete_password(account: &str) {
    if let Ok(entry) = keyring::Entry::new(CREDENTIAL_SERVICE, account) {
        let _ = entry.delete_credential();
    }
}

/// True when the OS has somewhere to put a password at all.
///
/// A headless Linux box, or a desktop with no keyring daemon running, has no Secret
/// Service — so "save password" is a promise the app cannot keep there, and it is better
/// to say so than to fail at the moment someone tries.
pub fn credential_store_available() -> bool {
    let probe = "miesql-availability-probe";
    match keyring::Entry::new(CREDENTIAL_SERVICE, probe) {
        Ok(entry) => {
            let ok = entry.set_password("probe").is_ok();
            if ok {
                let _ = entry.delete_credential();
            }
            ok
        }
        Err(_) => false,
    }
}

fn credential_error(action: &str, error: &keyring::Error) -> DbError {
    let detail = format!("{error}\n{error:?}");
    // The Secret Service being absent is not a failure the user can debug from a DBus
    // message; it is a missing component with a known fix.
    if detail.contains("org.freedesktop.secrets") || detail.contains("ServiceUnknown") {
        return DbError::new("No credential store is available, so the password cannot be saved.")
            .with_detail(
                "Linux keeps passwords in the Secret Service. Install and start \
                 gnome-keyring or KWallet, or clear \"Save password\" and enter the \
                 password each time.",
            );
    }
    DbError::new(format!("Could not {action}."))
        // keyring's Display collapses every platform failure into one sentence, which
        // leaves nothing to act on; the Debug form carries the OS status code.
        .with_detail(detail)
}

// MARK: - Settings

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    /// "system", "light" or "dark".
    pub appearance: String,
    /// BCP-47 tag, or "system" to follow the OS.
    pub language_code: String,
    pub editor_font_size: f64,
    pub grid_font_size: f64,
    pub page_size: u64,
    pub max_result_rows: usize,
    pub confirm_destructive_statements: bool,
    pub history_limit: usize,
    pub show_line_numbers: bool,
    pub wrap_long_lines: bool,
    /// Look for a new version shortly after launch.
    pub check_for_updates: bool,
    /// Download a found update without asking. Installing still waits for a restart, so an
    /// update can never interrupt a query that is running.
    pub download_updates_automatically: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            appearance: "system".into(),
            language_code: "system".into(),
            editor_font_size: 13.0,
            grid_font_size: 12.0,
            page_size: 200,
            max_result_rows: 50_000,
            confirm_destructive_statements: true,
            history_limit: 500,
            show_line_numbers: true,
            wrap_long_lines: false,
            check_for_updates: true,
            download_updates_automatically: true,
        }
    }
}

pub fn load_settings() -> AppSettings {
    std::fs::read_to_string(settings_file())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn save_settings(settings: &AppSettings) -> DbResult<()> {
    write_atomic(&settings_file(), settings)
}

// MARK: - History and snippets

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub sql: String,
    pub connection_name: String,
    pub database: String,
    pub executed_at: String,
    pub duration_ms: f64,
    pub succeeded: bool,
    pub row_count: Option<usize>,
    pub error_message: Option<String>,
}

pub fn load_history() -> Vec<HistoryEntry> {
    read_or_default::<Vec<HistoryEntry>>(&history_file())
}

pub fn append_history(entry: HistoryEntry, limit: usize) -> DbResult<Vec<HistoryEntry>> {
    let mut entries = load_history();
    entries.insert(0, entry);
    entries.truncate(limit.max(1));
    write_atomic(&history_file(), &entries)?;
    Ok(entries)
}

pub fn clear_history() -> DbResult<()> {
    write_atomic(&history_file(), &Vec::<HistoryEntry>::new())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    pub id: String,
    pub name: String,
    pub sql: String,
    pub updated_at: String,
}

pub fn load_snippets() -> Vec<Snippet> {
    read_or_default::<Vec<Snippet>>(&snippets_file())
}

pub fn save_snippets(snippets: &[Snippet]) -> DbResult<()> {
    write_atomic(&snippets_file(), &snippets)
}
