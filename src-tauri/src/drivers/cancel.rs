//! Stopping a query that is already running.
//!
//! The handle deliberately lives outside the driver's mutex. While a query runs the driver
//! is locked, so anything that had to take that lock in order to cancel could only ever do
//! so after the query had already finished — which is not cancelling at all. Each driver
//! instead publishes its handle into a slot that the session holds a second reference to,
//! and the cancel command reads the slot without touching the driver.

use crate::error::DbResult;
use async_trait::async_trait;
use std::sync::{Arc, Mutex};

/// Stops whatever the connection is currently doing. Cancelling when nothing is running
/// is a no-op on every engine here, so the caller never has to check first.
#[async_trait]
pub trait Canceller: Send + Sync {
    async fn cancel(&self) -> DbResult<()>;
}

/// Shared between a driver and its session.
///
/// The lock is a plain mutex and is never held across an await, so reading it cannot end
/// up waiting on the very query it is trying to stop.
#[derive(Clone, Default)]
pub struct CancelSlot(Arc<Mutex<Option<Arc<dyn Canceller>>>>);

impl CancelSlot {
    pub fn set(&self, canceller: Arc<dyn Canceller>) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = Some(canceller);
        }
    }

    pub fn clear(&self) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = None;
        }
    }

    /// The handle is cloned out rather than used in place, so the lock is released before
    /// the caller awaits the cancellation.
    pub fn get(&self) -> Option<Arc<dyn Canceller>> {
        self.0.lock().ok().and_then(|slot| slot.clone())
    }
}

impl std::fmt::Debug for CancelSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CancelSlot")
            .field("armed", &self.get().is_some())
            .finish()
    }
}
