//! Durable turn intent. Callers authorize before entry; no native I/O occurs in transactions.
use super::{command_result, Store};
use crate::{
    domain::{Message, Run, Thread},
    types::{now, storage_error, BridgeError, Result},
};
use rusqlite::{params, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug)]
pub(crate) struct NewTurn {
    pub thread_id: String,
    pub client_message_id: String,
    pub content: Value,
    pub expected_revision: Option<u64>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct AcceptedTurn {
    pub run: Run,
    pub message: Message,
    pub effect_id: String,
}
#[derive(Clone, Debug)]
pub(crate) struct ClaimedTurn {
    pub effect_id: String,
    pub principal_id: String,
    pub run: Run,
    pub message: Message,
    pub thread: Thread,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TurnOutcome {
    Completed,
    Interrupted,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct TurnEffect {
    run_id: String,
    message_id: String,
    principal_id: String,
    provider_turn_id: Option<String>,
}

fn json(value: &impl Serialize) -> Result<String> {
    serde_json::to_string(value).map_err(storage_error)
}
fn next_revision(value: u64) -> Result<u64> {
    value
        .checked_add(1)
        .filter(|v| *v <= i64::MAX as u64)
        .ok_or_else(|| storage_error("revision overflow"))
}
fn read_thread(tx: &Transaction<'_>, id: &str) -> Result<Thread> {
    let raw: Option<String> = tx
        .query_row("SELECT payload FROM threads WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(storage_error)?;
    serde_json::from_str(
        &raw.ok_or_else(|| BridgeError::new("not_found", "Thread does not exist."))?,
    )
    .map_err(storage_error)
}
fn read_run(tx: &Transaction<'_>, id: &str) -> Result<Run> {
    let raw: String = tx
        .query_row("SELECT payload FROM runs WHERE id=?1", [id], |r| r.get(0))
        .map_err(storage_error)?;
    serde_json::from_str(&raw).map_err(storage_error)
}
fn read_effect(tx: &Transaction<'_>, id: &str) -> Result<(String, TurnEffect)> {
    let record: Option<(String, String)> = tx
        .query_row(
            "SELECT state,payload FROM effect_outbox WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(storage_error)?;
    let (state, raw) =
        record.ok_or_else(|| BridgeError::new("not_found", "Turn effect does not exist."))?;
    Ok((state, serde_json::from_str(&raw).map_err(storage_error)?))
}
fn event(
    tx: &Transaction<'_>,
    thread_id: &str,
    id: &str,
    kind: &str,
    payload: &impl Serialize,
) -> Result<()> {
    tx.execute("INSERT INTO domain_events(aggregate_id,thread_id,event_type,payload,created_at) VALUES(?1,?2,?3,?4,?5)", params![id,thread_id,kind,json(payload)?,now()]).map_err(storage_error)?;
    Ok(())
}
fn set_thread(tx: &Transaction<'_>, thread_id: &str, status: &str) -> Result<()> {
    let mut thread = read_thread(tx, thread_id)?;
    thread.status = status.into();
    thread.revision = next_revision(thread.revision)?;
    thread.updated_at = now();
    tx.execute(
        "UPDATE threads SET payload=?2,revision=?3 WHERE id=?1",
        params![thread.id, json(&thread)?, thread.revision as i64],
    )
    .map_err(storage_error)?;
    event(tx, &thread.id, &thread.id, "thread.updated", &thread)
}
fn set_run(tx: &Transaction<'_>, mut run: Run, status: &str) -> Result<Run> {
    if run.status == status {
        return Ok(run);
    }
    run.status = status.into();
    run.revision = next_revision(run.revision)?;
    tx.execute(
        "UPDATE runs SET status=?2,payload=?3,revision=?4 WHERE id=?1",
        params![run.id, run.status, json(&run)?, run.revision as i64],
    )
    .map_err(storage_error)?;
    event(tx, &run.thread_id, &run.id, "run.updated", &run)?;
    let thread_status = match status {
        "outcome_unknown" => "attention",
        "completed" | "failed" | "interrupted" => "idle",
        _ => "active",
    };
    set_thread(tx, &run.thread_id, thread_status)?;
    Ok(run)
}
fn terminal(run: &Run) -> bool {
    matches!(run.status.as_str(), "completed" | "failed" | "interrupted")
}

fn expire_approvals(tx: &Transaction<'_>, run: &Run) -> Result<()> {
    let mut stmt = tx
        .prepare("SELECT id,payload FROM approvals WHERE run_id=?1 AND state='pending'")
        .map_err(storage_error)?;
    let rows = stmt
        .query_map([&run.id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })
        .map_err(storage_error)?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(storage_error)?;
    drop(stmt);
    for (id, raw) in rows {
        let mut payload: Value = serde_json::from_str(&raw).map_err(storage_error)?;
        payload["approval"]["state"] = serde_json::json!("expired");
        tx.execute(
            "UPDATE approvals SET state='expired',payload=?2 WHERE id=?1",
            params![id, payload.to_string()],
        )
        .map_err(storage_error)?;
        event(
            tx,
            &run.thread_id,
            &id,
            "approval.updated",
            &payload["approval"],
        )?;
    }
    Ok(())
}

impl Store {
    pub(crate) fn reserve_turn(
        &self,
        principal: &str,
        command_id: &str,
        fingerprint: &str,
        input: &NewTurn,
    ) -> Result<AcceptedTurn> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        if let Some(result) = command_result(&tx, principal, command_id, fingerprint)? {
            return serde_json::from_str(&result).map_err(storage_error);
        }
        let max_content_bytes = if input.content.get("images").is_some() {
            700 * 1024
        } else {
            256 * 1024
        };
        if input.client_message_id.is_empty()
            || input.client_message_id.len() > 128
            || json(&input.content)?.len() > max_content_bytes
        {
            return Err(BridgeError::new(
                "invalid_params",
                "Invalid or oversized user message.",
            ));
        }
        let thread = read_thread(&tx, &input.thread_id)?;
        if input
            .expected_revision
            .is_some_and(|v| v != thread.revision)
        {
            return Err(BridgeError::new(
                "conflict",
                "Thread revision changed; refresh before sending.",
            ));
        }
        let active: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM runs WHERE thread_id=?1 AND status IN ('queued','starting','running','waiting_approval','outcome_unknown'))", [&input.thread_id], |r| r.get(0)).map_err(storage_error)?;
        if active {
            return Err(BridgeError::new(
                "thread_busy",
                "Thread already has an active or uncertain run.",
            ));
        }
        let duplicate: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM messages WHERE thread_id=?1 AND client_message_id=?2)",
                params![input.thread_id, input.client_message_id],
                |r| r.get(0),
            )
            .map_err(storage_error)?;
        if duplicate {
            return Err(BridgeError::new(
                "conflict",
                "Client message ID was already used; retry its original command.",
            ));
        }
        let run = Run {
            id: uuid::Uuid::new_v4().to_string(),
            thread_id: input.thread_id.clone(),
            status: "queued".into(),
            revision: 0,
        };
        let message = Message {
            id: uuid::Uuid::new_v4().to_string(),
            thread_id: input.thread_id.clone(),
            run_id: Some(run.id.clone()),
            client_message_id: Some(input.client_message_id.clone()),
            role: "user".into(),
            content: input.content.clone(),
            revision: 0,
        };
        let accepted = AcceptedTurn {
            run: run.clone(),
            message: message.clone(),
            effect_id: uuid::Uuid::new_v4().to_string(),
        };
        let effect = TurnEffect {
            run_id: run.id.clone(),
            message_id: message.id.clone(),
            principal_id: principal.into(),
            provider_turn_id: None,
        };
        tx.execute(
            "INSERT INTO runs(id,thread_id,status,payload,revision) VALUES(?1,?2,'queued',?3,0)",
            params![run.id, run.thread_id, json(&run)?],
        )
        .map_err(storage_error)?;
        tx.execute("INSERT INTO messages(id,thread_id,run_id,client_message_id,payload,revision) VALUES(?1,?2,?3,?4,?5,0)", params![message.id,message.thread_id,message.run_id,message.client_message_id,json(&message)?]).map_err(storage_error)?;
        tx.execute("INSERT INTO effect_outbox(id,thread_id,state,payload,created_at) VALUES(?1,?2,'pending',?3,?4)", params![accepted.effect_id,run.thread_id,json(&effect)?,now()]).map_err(storage_error)?;
        tx.execute("INSERT INTO command_receipts(principal_id,command_id,fingerprint,result,created_at) VALUES(?1,?2,?3,?4,?5)", params![principal,command_id,fingerprint,json(&accepted)?,now()]).map_err(storage_error)?;
        set_thread(&tx, &run.thread_id, "active")?;
        event(
            &tx,
            &run.thread_id,
            &message.id,
            "message.created",
            &message,
        )?;
        event(&tx, &run.thread_id, &run.id, "run.queued", &run)?;
        tx.commit().map_err(storage_error)?;
        Ok(accepted)
    }

    /// Claim before any provider write; an executing effect is never claimable again.
    pub(crate) fn claim_turn(&self, effect_id: &str) -> Result<Option<ClaimedTurn>> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let (state, effect) = read_effect(&tx, effect_id)?;
        if state != "pending" {
            return Ok(None);
        }
        let run = read_run(&tx, &effect.run_id)?;
        if run.status != "queued" {
            return Err(BridgeError::new("conflict", "Turn is no longer queued."));
        }
        tx.execute(
            "UPDATE effect_outbox SET state='executing' WHERE id=?1",
            [effect_id],
        )
        .map_err(storage_error)?;
        let run = set_run(&tx, run, "starting")?;
        let raw: String = tx
            .query_row(
                "SELECT payload FROM messages WHERE id=?1",
                [&effect.message_id],
                |r| r.get(0),
            )
            .map_err(storage_error)?;
        let message = serde_json::from_str(&raw).map_err(storage_error)?;
        let thread = read_thread(&tx, &run.thread_id)?;
        tx.commit().map_err(storage_error)?;
        Ok(Some(ClaimedTurn {
            effect_id: effect_id.into(),
            principal_id: effect.principal_id,
            run,
            message,
            thread,
        }))
    }

    /// Provider ACK is delivery evidence, not turn completion. Late ACK cannot reopen a run.
    pub(crate) fn mark_turn_delivered(
        &self,
        effect_id: &str,
        provider_turn_id: &str,
    ) -> Result<Run> {
        if provider_turn_id.is_empty() || provider_turn_id.len() > 256 {
            return Err(BridgeError::new(
                "invalid_params",
                "Invalid provider turn ID.",
            ));
        }
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let (state, mut effect) = read_effect(&tx, effect_id)?;
        let run = read_run(&tx, &effect.run_id)?;
        if terminal(&run) || run.status == "outcome_unknown" {
            return Ok(run);
        }
        if let Some(old) = effect.provider_turn_id.as_deref() {
            if old != provider_turn_id {
                return Err(BridgeError::new("conflict", "Provider turn ID changed."));
            }
            return Ok(run);
        }
        if state != "executing" {
            return Err(BridgeError::new(
                "conflict",
                "Turn effect has not been claimed.",
            ));
        }
        effect.provider_turn_id = Some(provider_turn_id.into());
        tx.execute(
            "UPDATE effect_outbox SET state='completed',payload=?2 WHERE id=?1",
            params![effect_id, json(&effect)?],
        )
        .map_err(storage_error)?;
        let run = set_run(&tx, run, "running")?;
        tx.commit().map_err(storage_error)?;
        Ok(run)
    }

    pub(crate) fn mark_turn_unknown(&self, effect_id: &str) -> Result<Run> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let (state, effect) = read_effect(&tx, effect_id)?;
        let run = read_run(&tx, &effect.run_id)?;
        if terminal(&run) || run.status == "outcome_unknown" {
            return Ok(run);
        }
        if state == "pending" {
            return Err(BridgeError::new(
                "conflict",
                "Unclaimed turns cannot have an uncertain delivery.",
            ));
        }
        tx.execute(
            "UPDATE effect_outbox SET state='outcome_unknown' WHERE id=?1",
            [effect_id],
        )
        .map_err(storage_error)?;
        let run = set_run(&tx, run, "outcome_unknown")?;
        expire_approvals(&tx, &run)?;
        tx.commit().map_err(storage_error)?;
        Ok(run)
    }

    /// Use only for a definite pre-send failure. Ambiguous writes must call mark_turn_unknown.
    pub(crate) fn fail_turn(&self, effect_id: &str) -> Result<Run> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let (state, effect) = read_effect(&tx, effect_id)?;
        let run = read_run(&tx, &effect.run_id)?;
        if terminal(&run) || run.status == "outcome_unknown" {
            return Ok(run);
        }
        if effect.provider_turn_id.is_some() || !matches!(state.as_str(), "pending" | "executing") {
            return Err(BridgeError::new(
                "conflict",
                "Delivered turns require an authoritative completion result.",
            ));
        }
        tx.execute(
            "UPDATE effect_outbox SET state='completed' WHERE id=?1",
            [effect_id],
        )
        .map_err(storage_error)?;
        let run = set_run(&tx, run, "failed")?;
        tx.commit().map_err(storage_error)?;
        Ok(run)
    }

    /// Call only with an authoritative Provider terminal notification/readback. This is the
    /// explicit reconciliation path permitted to settle an outcome_unknown run.
    pub(crate) fn finish_turn(&self, effect_id: &str, outcome: TurnOutcome) -> Result<Run> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let (state, effect) = read_effect(&tx, effect_id)?;
        let run = read_run(&tx, &effect.run_id)?;
        if terminal(&run) {
            return Ok(run);
        }
        if state == "pending" {
            return Err(BridgeError::new(
                "conflict",
                "Unclaimed turn cannot receive provider completion.",
            ));
        }
        let status = match outcome {
            TurnOutcome::Completed => "completed",
            TurnOutcome::Interrupted => "interrupted",
            TurnOutcome::Failed => "failed",
        };
        tx.execute(
            "UPDATE effect_outbox SET state='completed' WHERE id=?1",
            [effect_id],
        )
        .map_err(storage_error)?;
        let run = set_run(&tx, run, status)?;
        tx.commit().map_err(storage_error)?;
        Ok(run)
    }

    /// Startup only. Fail never-claimed queued turns, quarantine all possibly sent work.
    /// Called while Daemon owns the exclusive host lock, before workers are admitted.
    pub(crate) fn reconcile_effects(&self) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage_error)?;
        let mut stmt = tx.prepare("SELECT e.id,e.state,e.payload FROM effect_outbox e JOIN runs r ON r.id=json_extract(e.payload,'$.run_id') WHERE r.status IN ('queued','starting','running','waiting_approval','outcome_unknown')").map_err(storage_error)?;
        let rows: Vec<(String, String, String)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(storage_error)?
            .collect::<std::result::Result<_, _>>()
            .map_err(storage_error)?;
        drop(stmt);
        for (id, state, payload) in rows {
            let effect: TurnEffect = serde_json::from_str(&payload).map_err(storage_error)?;
            let (effect_state, run_status) = if state == "pending" {
                ("completed", "failed")
            } else {
                ("outcome_unknown", "outcome_unknown")
            };
            tx.execute(
                "UPDATE effect_outbox SET state=?2 WHERE id=?1",
                params![id, effect_state],
            )
            .map_err(storage_error)?;
            set_run(&tx, read_run(&tx, &effect.run_id)?, run_status)?;
            // Native approval request IDs belong to the lost process session.
            // Never offer them as actionable approvals after a host restart.
            let run = read_run(&tx, &effect.run_id)?;
            expire_approvals(&tx, &run)?;
        }
        tx.commit().map_err(storage_error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Project;

    fn setup() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("host.sqlite3")).unwrap();
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
        (dir, store)
    }
    fn input() -> NewTurn {
        NewTurn {
            thread_id: "t".into(),
            client_message_id: "client-message".into(),
            content: serde_json::json!([{"type":"text","text":"Hello"}]),
            expected_revision: Some(0),
        }
    }
    fn count(store: &Store, table: &str) -> i64 {
        store
            .conn()
            .unwrap()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn duplicate_command_is_atomic_and_conflicting_retry_is_rejected() {
        let (_dir, store) = setup();
        let accepted = store
            .reserve_turn("phone", "send", "fingerprint", &input())
            .unwrap();
        let events = count(&store, "domain_events");
        assert_eq!(
            store
                .reserve_turn("phone", "send", "fingerprint", &input())
                .unwrap(),
            accepted
        );
        assert_eq!(
            store
                .reserve_turn("phone", "send", "different", &input())
                .unwrap_err()
                .code,
            "conflict"
        );
        assert_eq!(count(&store, "domain_events"), events);
        assert_eq!(count(&store, "runs"), 1);
        assert_eq!(count(&store, "messages"), 1);
        assert_eq!(count(&store, "effect_outbox"), 1);
        assert_eq!(store.thread("t").unwrap().unwrap().status, "active");
        let snapshot = store.thread_snapshot("t").unwrap();
        assert_eq!(snapshot.messages, vec![accepted.message]);
    }

    #[test]
    fn failed_event_commit_leaves_no_run_message_effect_or_receipt() {
        let (_dir, store) = setup();
        store.conn().unwrap().execute_batch("CREATE TRIGGER fail_turn_event BEFORE INSERT ON domain_events BEGIN SELECT RAISE(ABORT,'failure'); END;").unwrap();
        assert!(store.reserve_turn("phone", "send", "fp", &input()).is_err());
        for table in ["runs", "messages", "effect_outbox"] {
            assert_eq!(count(&store, table), 0);
        }
        assert!(store
            .command_receipt("phone", "send", "fp")
            .unwrap()
            .is_none());
        assert_eq!(store.thread("t").unwrap().unwrap().revision, 0);
    }

    #[test]
    fn competing_connections_accept_only_one_active_run() {
        let (dir, one) = setup();
        let two = Store::open(&dir.path().join("host.sqlite3")).unwrap();
        let results = std::thread::scope(|scope| {
            let a = scope.spawn(|| {
                one.reserve_turn(
                    "phone",
                    "a",
                    "a",
                    &NewTurn {
                        expected_revision: None,
                        ..input()
                    },
                )
            });
            let b = scope.spawn(|| {
                two.reserve_turn(
                    "phone",
                    "b",
                    "b",
                    &NewTurn {
                        expected_revision: None,
                        ..input()
                    },
                )
            });
            [a.join().unwrap(), b.join().unwrap()]
        });
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(
            results.iter().find_map(|r| r.as_ref().err()).unwrap().code,
            "thread_busy"
        );
        assert_eq!(count(&one, "runs"), 1);
    }

    #[test]
    fn claim_once_completion_before_ack_and_late_ack_cannot_reopen() {
        let (_dir, store) = setup();
        let accepted = store.reserve_turn("phone", "send", "fp", &input()).unwrap();
        let claimed = store.claim_turn(&accepted.effect_id).unwrap().unwrap();
        assert_eq!(claimed.effect_id, accepted.effect_id);
        assert_eq!(claimed.principal_id, "phone");
        assert_eq!(claimed.run.status, "starting");
        assert_eq!(claimed.message, accepted.message);
        assert_eq!(claimed.thread.id, "t");
        assert!(store.claim_turn(&accepted.effect_id).unwrap().is_none());
        let finished = store
            .finish_turn(&accepted.effect_id, TurnOutcome::Completed)
            .unwrap();
        let sequence = store.thread_snapshot("t").unwrap().sequence;
        assert_eq!(
            store
                .mark_turn_delivered(&accepted.effect_id, "native-turn")
                .unwrap(),
            finished
        );
        assert_eq!(
            store
                .finish_turn(&accepted.effect_id, TurnOutcome::Completed)
                .unwrap(),
            finished
        );
        assert_eq!(store.thread_snapshot("t").unwrap().sequence, sequence);
        assert_eq!(store.thread("t").unwrap().unwrap().status, "idle");
    }

    #[test]
    fn ack_means_running_and_unknown_requires_authoritative_completion() {
        let (_dir, store) = setup();
        let accepted = store.reserve_turn("phone", "send", "fp", &input()).unwrap();
        store.claim_turn(&accepted.effect_id).unwrap().unwrap();
        assert_eq!(
            store
                .mark_turn_delivered(&accepted.effect_id, "native-turn")
                .unwrap()
                .status,
            "running"
        );
        assert_eq!(
            store
                .mark_turn_delivered(&accepted.effect_id, "different")
                .unwrap_err()
                .code,
            "conflict"
        );
        let unknown = store.mark_turn_unknown(&accepted.effect_id).unwrap();
        assert_eq!(unknown.status, "outcome_unknown");
        assert_eq!(
            store
                .mark_turn_delivered(&accepted.effect_id, "native-turn")
                .unwrap(),
            unknown
        );
        assert_eq!(store.fail_turn(&accepted.effect_id).unwrap(), unknown);
        assert_eq!(
            store
                .finish_turn(&accepted.effect_id, TurnOutcome::Interrupted)
                .unwrap()
                .status,
            "interrupted"
        );
    }

    #[test]
    fn reopen_fails_unsent_work_and_quarantines_sent_work_without_claiming_again() {
        for delivered in [None, Some(false), Some(true)] {
            let (dir, store) = setup();
            let accepted = store.reserve_turn("phone", "send", "fp", &input()).unwrap();
            if let Some(acked) = delivered {
                store.claim_turn(&accepted.effect_id).unwrap();
                if acked {
                    store
                        .mark_turn_delivered(&accepted.effect_id, "native-turn")
                        .unwrap();
                }
            }
            drop(store);
            let store = Store::open(&dir.path().join("host.sqlite3")).unwrap();
            let conn = store.conn().unwrap();
            let status: String = conn
                .query_row(
                    "SELECT status FROM runs WHERE id=?1",
                    [&accepted.run.id],
                    |r| r.get(0),
                )
                .unwrap();
            drop(conn);
            assert_eq!(
                status,
                if delivered.is_some() {
                    "outcome_unknown"
                } else {
                    "failed"
                }
            );
            assert!(store.claim_turn(&accepted.effect_id).unwrap().is_none());
            assert_eq!(
                store.reserve_turn("phone", "send", "fp", &input()).unwrap(),
                accepted
            );
            let seq = store.thread_snapshot("t").unwrap().sequence;
            store.reconcile_effects().unwrap();
            assert_eq!(store.thread_snapshot("t").unwrap().sequence, seq);
        }
    }

    #[test]
    fn definite_failure_and_authoritative_failure_settle_different_stages() {
        let (_dir, store) = setup();
        let accepted = store.reserve_turn("phone", "send", "fp", &input()).unwrap();
        assert_eq!(
            store.fail_turn(&accepted.effect_id).unwrap().status,
            "failed"
        );
        let second = store
            .reserve_turn(
                "phone",
                "send2",
                "fp2",
                &NewTurn {
                    client_message_id: "client-message-2".into(),
                    expected_revision: None,
                    ..input()
                },
            )
            .unwrap();
        store.claim_turn(&second.effect_id).unwrap();
        store
            .mark_turn_delivered(&second.effect_id, "native-turn")
            .unwrap();
        assert_eq!(
            store.fail_turn(&second.effect_id).unwrap_err().code,
            "conflict"
        );
        assert_eq!(
            store
                .finish_turn(&second.effect_id, TurnOutcome::Failed)
                .unwrap()
                .status,
            "failed"
        );
    }

    #[test]
    fn startup_reconciliation_failure_is_reported_and_transaction_rolls_back() {
        let (dir, store) = setup();
        let accepted = store.reserve_turn("phone", "send", "fp", &input()).unwrap();
        store.claim_turn(&accepted.effect_id).unwrap();
        store.conn().unwrap().execute_batch("CREATE TRIGGER fail_recovery BEFORE INSERT ON domain_events BEGIN SELECT RAISE(ABORT,'failure'); END;").unwrap();
        drop(store);
        let path = dir.path().join("host.sqlite3");
        assert!(Store::open(&path).is_err());
        let conn = rusqlite::Connection::open(path).unwrap();
        let effect_state: String = conn
            .query_row(
                "SELECT state FROM effect_outbox WHERE id=?1",
                [&accepted.effect_id],
                |row| row.get(0),
            )
            .unwrap();
        let run_status: String = conn
            .query_row(
                "SELECT status FROM runs WHERE id=?1",
                [&accepted.run.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(effect_state, "executing");
        assert_eq!(run_status, "starting");
    }
}
