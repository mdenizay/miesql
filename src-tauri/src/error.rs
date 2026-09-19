//! One error type across every driver. It carries the server's own wording, because a
//! database's message is almost always more useful than anything we could write over it.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, thiserror::Error)]
#[serde(rename_all = "camelCase")]
pub struct DbError {
    pub message: String,
    /// SQLSTATE or engine error number, when the server supplies one.
    pub code: Option<String>,
    pub detail: Option<String>,
}

impl DbError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: None,
            detail: None,
        }
    }

    pub fn with_code(message: impl Into<String>, code: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: Some(code.into()),
            detail: None,
        }
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        let detail = detail.into();
        self.detail = if detail.is_empty() {
            None
        } else {
            Some(detail)
        };
        self
    }

    /// Raised when a read-only connection is asked to change something.
    pub fn read_only(keyword: &str) -> Self {
        Self::with_code(
            format!(
                "This connection is marked read-only. {} statements are blocked.",
                keyword.to_uppercase()
            ),
            "MIESQL_READONLY",
        )
    }

    pub fn not_connected() -> Self {
        Self::new("Not connected.")
    }
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.code {
            Some(code) => write!(f, "[{code}] {}", self.message)?,
            None => write!(f, "{}", self.message)?,
        }
        if let Some(detail) = &self.detail {
            write!(f, "\n{detail}")?;
        }
        Ok(())
    }
}

pub type DbResult<T> = std::result::Result<T, DbError>;
