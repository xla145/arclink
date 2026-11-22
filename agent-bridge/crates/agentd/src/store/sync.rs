use super::Store;
use crate::{
    domain::{Message, Thread},
    sync::{ThreadEvent, ThreadReplay, ThreadSnapshot},
    types::{storage_error, BridgeError, Result},
};
use rusqlite::{params, OptionalExtension, Transaction};

const MAX_BATCH_BYTES: usize = 768 * 1024;
const MAX_EVENTS: usize = 100;
const MAX_MESSAGES: usize = 50;

fn identity_and_high_water(tx: &Transaction<'_>) -> Result<(String, i64)> {
    let id = tx
        .query_row(
            "SELECT value FROM metadata WHERE key='environment_id'",
            [],
            |row| row.get(0),
        )
        .map_err(storage_error)?;
    // sqlite_sequence survives pruning all rows. MAX(sequence) would regress to zero.
    let high_water = tx
        .query_row(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='domain_events'),0)",
            [],
            |row| row.get(0),
        )
        .map_err(storage_error)?;
    Ok((id, high_water))
}

fn thread(tx: &Transaction<'_>, id: &str) -> Result<Thread> {
    let value: Option<String> = tx
        .query_row("SELECT payload FROM threads WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .optional()
        .map_err(storage_error)?;
    serde_json::from_str(
        &value.ok_or_else(|| BridgeError::new("not_found", "Thread does not exist."))?,
    )
    .map_err(storage_error)
}

fn encoded_size(value: &impl serde::Serialize) -> Result<usize> {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .map_err(storage_error)
}

fn oversized() -> BridgeError {
    BridgeError::new(
        "resource_limit",
        "Thread synchronization exceeds the response budget; request paginated history.",
    )
}

impl Store {
    /// Caller must authorize access to the thread's project before entering this method.
    pub(crate) fn thread_snapshot(&self, thread_id: &str) -> Result<ThreadSnapshot> {
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        let (environment_id, high_water) = identity_and_high_water(&tx)?;
        let mut snapshot = ThreadSnapshot {
            environment_id,
            sequence: high_water.to_string(),
            thread: thread(&tx, thread_id)?,
            messages: vec![],
            runs: vec![],
            approvals: vec![],
            has_older_messages: false,
        };
        {
            let mut stmt = tx
                .prepare("SELECT payload FROM runs WHERE thread_id=?1 ORDER BY rowid DESC LIMIT 50")
                .map_err(storage_error)?;
            let rows = stmt
                .query_map([thread_id], |r| r.get::<_, String>(0))
                .map_err(storage_error)?;
            for row in rows {
                snapshot.runs.push(
                    serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error)?,
                );
            }
            let mut stmt=tx.prepare("SELECT a.payload,a.state FROM approvals a JOIN runs r ON r.id=a.run_id WHERE r.thread_id=?1 AND a.state='pending' AND r.status IN ('queued','starting','running','waiting_approval') LIMIT 129").map_err(storage_error)?;
            let rows = stmt
                .query_map([thread_id], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })
                .map_err(storage_error)?;
            for row in rows {
                let (raw, state) = row.map_err(storage_error)?;
                let value: serde_json::Value = serde_json::from_str(&raw).map_err(storage_error)?;
                let mut approval: crate::domain::Approval =
                    serde_json::from_value(value["approval"].clone()).map_err(storage_error)?;
                approval.state = state;
                snapshot.approvals.push(approval);
            }
            if snapshot.approvals.len() > 128 {
                return Err(oversized());
            }
        }
        let mut stmt = tx
            .prepare("SELECT payload FROM messages WHERE thread_id=?1 ORDER BY rowid DESC LIMIT ?2")
            .map_err(storage_error)?;
        let rows = stmt
            .query_map(params![thread_id, (MAX_MESSAGES + 1) as i64], |row| {
                row.get::<_, String>(0)
            })
            .map_err(storage_error)?;
        for row in rows {
            if snapshot.messages.len() == MAX_MESSAGES {
                snapshot.has_older_messages = true;
                break;
            }
            let message: Message =
                serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error)?;
            snapshot.messages.push(message);
            if encoded_size(&snapshot)? > MAX_BATCH_BYTES {
                snapshot.messages.pop();
                if snapshot.messages.is_empty() {
                    return Err(oversized());
                }
                snapshot.has_older_messages = true;
                break;
            }
        }
        snapshot.messages.reverse();
        if encoded_size(&snapshot)? > MAX_BATCH_BYTES {
            return Err(oversized());
        }
        Ok(snapshot)
    }

    pub(crate) fn thread_history(
        &self,
        thread_id: &str,
        before_id: Option<&str>,
    ) -> Result<crate::sync::ThreadHistory> {
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        thread(&tx, thread_id)?;
        let before = if let Some(id) = before_id {
            tx.query_row(
                "SELECT rowid FROM messages WHERE id=?1 AND thread_id=?2",
                params![id, thread_id],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .map_err(storage_error)?
            .ok_or_else(|| BridgeError::new("invalid_params", "Invalid history cursor."))?
        } else {
            i64::MAX
        };
        let mut page = crate::sync::ThreadHistory {
            thread_id: thread_id.into(),
            messages: vec![],
            has_more: false,
            next_before_id: None,
        };
        let mut stmt=tx.prepare("SELECT payload FROM messages WHERE thread_id=?1 AND rowid<?2 ORDER BY rowid DESC LIMIT 51").map_err(storage_error)?;
        let rows = stmt
            .query_map(params![thread_id, before], |r| r.get::<_, String>(0))
            .map_err(storage_error)?;
        for row in rows {
            if page.messages.len() == 50 {
                page.has_more = true;
                break;
            }
            page.messages
                .push(serde_json::from_str(&row.map_err(storage_error)?).map_err(storage_error)?);
            page.next_before_id = page.messages.last().map(|m| m.id.clone());
            if encoded_size(&page)? > MAX_BATCH_BYTES {
                page.messages.pop();
                page.next_before_id = page.messages.last().map(|m| m.id.clone());
                if page.messages.is_empty() {
                    return Err(oversized());
                }
                page.has_more = true;
                break;
            }
        }
        page.messages.reverse();
        page.next_before_id = page.messages.first().map(|m| m.id.clone());
        Ok(page)
    }

    /// The complete replay batch is read in one database snapshot with its pruning watermark.
    pub(crate) fn replay_thread(
        &self,
        environment_id: &str,
        thread_id: &str,
        after_sequence: &str,
    ) -> Result<ThreadReplay> {
        let cursor = after_sequence
            .parse::<i64>()
            .ok()
            .filter(|value| *value >= 0 && value.to_string() == after_sequence)
            .ok_or_else(|| {
                BridgeError::new(
                    "invalid_params",
                    "Cursor must be a canonical decimal sequence.",
                )
            })?;
        let mut conn = self.conn()?;
        let tx = conn.transaction().map_err(storage_error)?;
        let (actual_environment, high_water) = identity_and_high_water(&tx)?;
        if actual_environment != environment_id {
            return Err(BridgeError::new(
                "resync_required",
                "The cursor belongs to another environment.",
            ));
        }
        thread(&tx, thread_id)?;
        let pruned: i64 = tx
            .query_row(
                "SELECT pruned_through FROM sync_watermarks WHERE scope='environment'",
                [],
                |row| row.get(0),
            )
            .map_err(storage_error)?;
        if cursor < pruned || cursor > high_water {
            return Err(BridgeError::new(
                "resync_required",
                "The cursor is no longer resumable; request a snapshot.",
            ));
        }
        let mut replay = ThreadReplay {
            environment_id: actual_environment,
            thread_id: thread_id.into(),
            sequence: cursor.to_string(),
            events: vec![],
            has_more: false,
        };
        let mut stmt = tx.prepare("SELECT sequence,aggregate_id,event_type,payload FROM domain_events WHERE thread_id=?1 AND sequence>?2 AND sequence<=?3 ORDER BY sequence LIMIT ?4").map_err(storage_error)?;
        let rows = stmt
            .query_map(
                params![thread_id, cursor, high_water, (MAX_EVENTS + 1) as i64],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .map_err(storage_error)?;
        for row in rows {
            if replay.events.len() == MAX_EVENTS {
                replay.has_more = true;
                break;
            }
            let (sequence, aggregate_id, event_type, payload) = row.map_err(storage_error)?;
            let previous = replay.sequence.clone();
            replay.sequence = sequence.to_string();
            replay.events.push(ThreadEvent {
                sequence: sequence.to_string(),
                aggregate_id,
                event_type,
                schema_version: 1,
                payload: serde_json::from_str(&payload).map_err(storage_error)?,
            });
            if encoded_size(&replay)? > MAX_BATCH_BYTES {
                replay.events.pop();
                replay.sequence = previous;
                if replay.events.is_empty() {
                    return Err(oversized());
                }
                replay.has_more = true;
                break;
            }
        }
        if !replay.has_more {
            replay.sequence = high_water.to_string();
        }
        Ok(replay)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{domain::Project, types::now};

    fn setup() -> (tempfile::TempDir, Store, String) {
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(&directory.path().join("host.sqlite3")).unwrap();
        store
            .create_project(
                "phone",
                "p",
                "p",
                &Project {
                    id: "p".into(),
                    canonical_root: "/p".into(),
                    name: "P".into(),
                    created_at: now(),
                    updated_at: now(),
                },
            )
            .unwrap();
        store
            .create_thread(
                "phone",
                "t",
                "t",
                &Thread {
                    id: "t".into(),
                    project_id: "p".into(),
                    provider_id: "codex".into(),
                    model: None,
                    title: "T".into(),
                    cwd: "/p".into(),
                    status: "idle".into(),
                    revision: 0,
                    created_at: now(),
                    updated_at: now(),
                },
            )
            .unwrap();
        let environment = store.environment_id().unwrap();
        (directory, store, environment)
    }

    fn append(store: &Store, payload: &str) {
        store.conn().unwrap().execute("INSERT INTO domain_events(aggregate_id,thread_id,event_type,payload,created_at) VALUES('t','t','thread.updated',?1,'now')", [payload]).unwrap();
    }

    #[test]
    fn snapshot_cursor_replays_only_later_commits() {
        let (_dir, store, environment) = setup();
        let snapshot = store.thread_snapshot("t").unwrap();
        assert_eq!(snapshot.sequence, "2");
        append(&store, "{\"revision\":\"1\"}");
        let replay = store
            .replay_thread(&environment, "t", &snapshot.sequence)
            .unwrap();
        assert_eq!(replay.events.len(), 1);
        assert_eq!(replay.sequence, "3");
        assert!(!replay.has_more);
        assert!(serde_json::to_value(replay).unwrap()["sequence"].is_string());
    }

    #[test]
    fn stale_future_or_foreign_cursors_require_snapshot() {
        let (_dir, store, environment) = setup();
        assert_eq!(
            store.replay_thread("other", "t", "0").unwrap_err().code,
            "resync_required"
        );
        assert_eq!(
            store
                .replay_thread(&environment, "t", "3")
                .unwrap_err()
                .code,
            "resync_required"
        );
        for invalid in ["-1", "01", "9223372036854775808"] {
            assert_eq!(
                store
                    .replay_thread(&environment, "t", invalid)
                    .unwrap_err()
                    .code,
                "invalid_params"
            );
        }
        store.conn().unwrap().execute_batch("BEGIN IMMEDIATE; DELETE FROM domain_events; UPDATE sync_watermarks SET pruned_through=2; COMMIT;").unwrap();
        assert_eq!(
            store
                .replay_thread(&environment, "t", "1")
                .unwrap_err()
                .code,
            "resync_required"
        );
        assert_eq!(store.thread_snapshot("t").unwrap().sequence, "2");
        assert!(store
            .replay_thread(&environment, "t", "2")
            .unwrap()
            .events
            .is_empty());
    }

    #[test]
    fn bounded_batches_preserve_replay_cursor() {
        let (_dir, store, environment) = setup();
        for _ in 0..105 {
            append(&store, "{}");
        }
        let first = store.replay_thread(&environment, "t", "2").unwrap();
        assert_eq!(first.events.len(), 100);
        assert!(first.has_more);
        assert_eq!(first.sequence, "102");
        let rest = store
            .replay_thread(&environment, "t", &first.sequence)
            .unwrap();
        assert_eq!(rest.events.len(), 5);
        assert!(!rest.has_more);
        assert_eq!(rest.sequence, "107");
    }

    #[test]
    fn oversized_event_is_explicit_not_silently_skipped() {
        let (_dir, store, environment) = setup();
        append(
            &store,
            &serde_json::to_string(&"x".repeat(MAX_BATCH_BYTES)).unwrap(),
        );
        assert_eq!(
            store
                .replay_thread(&environment, "t", "2")
                .unwrap_err()
                .code,
            "resource_limit"
        );
    }

    #[test]
    fn snapshot_returns_recent_messages_with_explicit_history_marker() {
        let (_dir, store, _) = setup();
        for index in 0..55 {
            let message = Message {
                id: format!("m{index}"),
                thread_id: "t".into(),
                run_id: None,
                client_message_id: None,
                role: "assistant".into(),
                content: serde_json::json!({"text":index.to_string()}),
                revision: 0,
            };
            store
                .conn()
                .unwrap()
                .execute(
                    "INSERT INTO messages(id,thread_id,payload,revision) VALUES(?1,'t',?2,0)",
                    params![message.id, serde_json::to_string(&message).unwrap()],
                )
                .unwrap();
        }
        let snapshot = store.thread_snapshot("t").unwrap();
        assert_eq!(snapshot.messages.len(), 50);
        assert_eq!(snapshot.messages[0].id, "m5");
        assert!(snapshot.has_older_messages);
    }
}
