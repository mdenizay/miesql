//! The registry of live connections.
//!
//! Each session owns its driver behind its own lock, so a slow query on one server never
//! blocks another — the same property the Swift version got from one actor per connection.
//! A single map-wide lock would have serialised every connection behind the slowest one.

use crate::drivers::{CancelSlot, Driver};
use crate::error::{DbError, DbResult};
use crate::models::ServerInfo;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

pub struct Session {
    pub driver: Mutex<Box<dyn Driver>>,
    /// Outside the driver lock on purpose: a query that is running holds that lock, so
    /// this is the only way to reach the connection while it is busy.
    pub cancel: CancelSlot,
    pub info: ServerInfo,
    /// Held for the life of the session: dropping it closes the forward, so the tunnel
    /// cannot outlive the connection that needed it.
    pub tunnel: Option<crate::ssh::SshTunnel>,
}

#[derive(Default)]
pub struct AppState {
    sessions: Mutex<HashMap<Uuid, Arc<Session>>>,
}

impl AppState {
    pub async fn insert(
        &self,
        id: Uuid,
        driver: Box<dyn Driver>,
        info: ServerInfo,
        tunnel: Option<crate::ssh::SshTunnel>,
    ) {
        let session = Arc::new(Session {
            cancel: driver.cancel_slot(),
            driver: Mutex::new(driver),
            info,
            tunnel,
        });
        self.sessions.lock().await.insert(id, session);
    }

    /// Hands back a reference without holding the map lock, which is what lets two
    /// connections run queries at the same time.
    pub async fn get(&self, id: Uuid) -> DbResult<Arc<Session>> {
        self.sessions
            .lock()
            .await
            .get(&id)
            .cloned()
            .ok_or_else(|| DbError::new("That connection is not open."))
    }

    pub async fn remove(&self, id: Uuid) -> Option<Arc<Session>> {
        self.sessions.lock().await.remove(&id)
    }

    pub async fn open_ids(&self) -> Vec<Uuid> {
        self.sessions.lock().await.keys().copied().collect()
    }
}
