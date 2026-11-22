use crate::{
    sync::{ThreadHistory, ThreadReplay},
    Daemon, Result,
};
use std::time::{Duration, Instant};
impl Daemon {
    pub fn managed_thread_history(
        &self,
        peer: &str,
        thread_id: &str,
        before_id: Option<&str>,
    ) -> Result<ThreadHistory> {
        self.managed_thread(peer, thread_id)?;
        self.store.thread_history(thread_id, before_id)
    }
    /// A bounded long poll over the durable log. Each iteration rechecks ACL, so
    /// revocation cannot leave a stale subscriber observing later events.
    pub async fn wait_managed_thread(
        &self,
        peer: &str,
        environment_id: &str,
        thread_id: &str,
        after_sequence: &str,
    ) -> Result<ThreadReplay> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let result =
                self.replay_managed_thread(peer, environment_id, thread_id, after_sequence)?;
            if !result.events.is_empty() || Instant::now() >= deadline {
                return Ok(result);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    pub(crate) async fn wait_local_managed_thread(
        &self,
        environment_id: &str,
        thread_id: &str,
        after_sequence: &str,
    ) -> Result<ThreadReplay> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let result = self
                .store
                .replay_thread(environment_id, thread_id, after_sequence)?;
            if !result.events.is_empty() || Instant::now() >= deadline {
                return Ok(result);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}
