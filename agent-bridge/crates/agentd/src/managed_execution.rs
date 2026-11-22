//! Managed execution orchestration. A service-owned consumer persists native
//! events independently of the lifetime of any phone or desktop request.
use crate::{
    codex_protocol::CodexEvent,
    codex_session::{
        SessionError, SessionEvent, SessionHandle, SessionOptions, SessionState, TurnInput,
    },
    domain::Thread,
    store::{AcceptedTurn, TurnOutcome},
    BridgeError, Daemon, Result,
};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex, Weak},
};
use tokio::sync::mpsc;

#[derive(Clone)]
struct ActiveRun {
    effect_id: String,
    run_id: String,
    native_turn_id: Option<String>,
}
struct Entry {
    handle: SessionHandle,
    claude: bool,
    model: Option<String>,
    provider_id: String,
    handoff: Mutex<Option<String>>,
    native_session: Mutex<Option<String>>,
    process: crate::types::ProcessInfo,
    active: Mutex<Option<ActiveRun>>,
    completed_turns: Mutex<VecDeque<String>>,
}
pub(crate) struct ManagedSessions(Mutex<HashMap<String, Arc<Entry>>>);
impl ManagedSessions {
    pub(crate) fn new() -> Self {
        Self(Mutex::new(HashMap::new()))
    }
    pub(crate) async fn close(&self) {
        let handles: Vec<_> = self
            .0
            .lock()
            .unwrap()
            .values()
            .map(|e| e.handle.clone())
            .collect();
        for handle in handles {
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), handle.close()).await;
        }
    }
}

impl Daemon {
    pub(crate) async fn retire_managed_session(&self, thread_id: &str) -> Result<()> {
        // Remove before closing, so Ready/Closed/late output from the old consumer is fenced.
        let entry = self.managed_sessions.0.lock().unwrap().remove(thread_id);
        if let Some(entry) = entry {
            let _ =
                tokio::time::timeout(std::time::Duration::from_secs(2), entry.handle.close()).await;
            self.processes
                .stop(&entry.process.process_id, &entry.process.generation)
                .await?;
        }
        Ok(())
    }
    fn managed_entry_is_current(&self, thread_id: &str, entry: &Arc<Entry>) -> bool {
        self.managed_sessions
            .0
            .lock()
            .unwrap()
            .get(thread_id)
            .is_some_and(|current| Arc::ptr_eq(current, entry))
    }

    /// Caller holds mutation_gate and has checked provider availability and current access.
    pub(crate) async fn ensure_managed_session(self: &Arc<Self>, thread: &Thread) -> Result<()> {
        let model = thread
            .model
            .clone()
            .or(self.store.provider_default_model(&thread.id)?);
        let existing = self
            .managed_sessions
            .0
            .lock()
            .unwrap()
            .get(&thread.id)
            .cloned();
        if let Some(entry) = existing {
            if matches!(entry.handle.state(), SessionState::Ready(_))
                && entry.model == model
                && entry.provider_id == thread.provider_id
            {
                return Ok(());
            }
            // A retired Claude process may still hold its transcript lock.
            // Reap it before resuming that session in the next process.
            if entry.claude || entry.model != model {
                let _ = entry.handle.close().await;
                self.processes
                    .stop(&entry.process.process_id, &entry.process.generation)
                    .await?;
            }
            self.managed_sessions.0.lock().unwrap().remove(&thread.id);
        }
        let spec = self
            .adapters
            .lock()
            .unwrap()
            .iter()
            .find(|s| s.id == thread.provider_id)
            .cloned()
            .ok_or_else(|| BridgeError::new("agent_not_found", "Unknown Agent identifier."))?;
        let runtime = self
            .start_managed_provider(
                &spec,
                SessionOptions {
                    cwd: thread.cwd.clone(),
                    thread_id: self.store.provider_thread_id(&thread.id)?,
                    model: model.clone(),
                },
            )
            .await?;
        let entry = Arc::new(Entry {
            handle: runtime.handle,
            process: runtime.process,
            claude: thread.provider_id == "claude",
            model,
            provider_id: thread.provider_id.clone(),
            handoff: Mutex::new(self.store.provider_handoff(&thread.id)?),
            native_session: Mutex::new(None),
            active: Mutex::new(None),
            completed_turns: Mutex::new(VecDeque::new()),
        });
        self.managed_sessions
            .0
            .lock()
            .unwrap()
            .insert(thread.id.clone(), entry.clone());
        let daemon = Arc::downgrade(self);
        let thread_id = thread.id.clone();
        let consumer_entry = entry.clone();
        tokio::spawn(consume_events(
            daemon,
            thread_id,
            consumer_entry,
            runtime.events,
        ));
        let native = entry.handle.ready().await.map_err(session_error)?;
        // Ready can wake before the event consumer commits the corresponding event.
        // Persist before accepting user input, so restart can always resume this thread.
        *entry.native_session.lock().unwrap() = Some(native.clone());
        // Claude initialize allocates an ID but does not persist a transcript.
        // Save it on the first successfully written turn event instead.
        if !entry.claude {
            self.store.save_provider_session(&thread.id, &native)?;
        }
        Ok(())
    }

    pub(crate) fn dispatch_managed_turn(self: &Arc<Self>, accepted: &AcceptedTurn) -> Result<()> {
        let entry = self
            .managed_sessions
            .0
            .lock()
            .unwrap()
            .get(&accepted.run.thread_id)
            .cloned()
            .ok_or_else(|| BridgeError::new("unavailable", "Provider session is not ready."))?;
        let claimed = self.store.claim_turn(&accepted.effect_id)?.ok_or_else(|| {
            BridgeError::new("outcome_unknown", "This turn has already been dispatched.")
        })?;
        if claimed.thread.id != accepted.run.thread_id || claimed.principal_id.is_empty() {
            return Err(BridgeError::new(
                "storage_error",
                "Stored turn identity is invalid.",
            ));
        }
        let text = claimed
            .message
            .content
            .get("text")
            .and_then(|value| value.as_str())
            .ok_or_else(|| BridgeError::new("storage_error", "Stored turn content is invalid."))?
            .to_owned();
        let context = ActiveRun {
            effect_id: claimed.effect_id,
            run_id: claimed.run.id,
            native_turn_id: None,
        };
        *entry.active.lock().unwrap() = Some(context.clone());
        let handoff = entry.handoff.lock().unwrap().take();
        let text = if let Some(prefix) = handoff.as_deref() {
            if prefix.len() + text.len() > crate::codex_session::MAX_INPUT_BYTES {
                // Do not silently discard the current instruction to fit historical context.
                *entry.handoff.lock().unwrap() = handoff;
                self.store.fail_turn(&context.effect_id)?;
                *entry.active.lock().unwrap() = None;
                return Err(BridgeError::new("invalid_params", "Message and Agent handoff exceed the input budget; shorten the current message."));
            }
            format!("{prefix}{text}")
        } else {
            text
        };
        let images: Vec<Vec<u8>> = claimed
            .message
            .content
            .get("images")
            .and_then(|value| value.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|v| v.as_str().and_then(crate::codex_session::base64_decode))
                    .collect()
            })
            .unwrap_or_default();
        let input = TurnInput {
            text,
            images,
            client_message_id: claimed.message.client_message_id.unwrap_or_default(),
        };
        let daemon = Arc::downgrade(self);
        let accepted_thread_id = accepted.run.thread_id.clone();
        tokio::spawn(async move {
            let result = entry.handle.send_turn(input).await;
            if let Some(daemon) = daemon.upgrade() {
                let _guard = daemon.mutation_gate.lock().await;
                if !daemon.managed_entry_is_current(&accepted_thread_id, &entry) {
                    return;
                }
                let saved = match result {
                    Ok(native_id) => {
                        if handoff.is_some() {
                            let _ = daemon.store.finish_provider_handoff(&accepted_thread_id);
                        }

                        let mut mismatch = false;
                        if let Some(active) = entry.active.lock().unwrap().as_mut() {
                            if active.run_id == context.run_id {
                                mismatch = active
                                    .native_turn_id
                                    .as_ref()
                                    .is_some_and(|expected| expected != &native_id);
                                if !mismatch {
                                    active.native_turn_id = Some(native_id.clone());
                                }
                            }
                        }
                        if mismatch {
                            let _ = entry.handle.close().await;
                            daemon.store.mark_turn_unknown(&context.effect_id)
                        } else {
                            daemon
                                .store
                                .mark_turn_delivered(&context.effect_id, &native_id)
                        }
                    }
                    Err(
                        SessionError::Rejected | SessionError::InvalidInput | SessionError::Busy,
                    ) => {
                        *entry.handoff.lock().unwrap() = handoff;
                        daemon.store.fail_turn(&context.effect_id)
                    }
                    Err(_) => daemon.store.mark_turn_unknown(&context.effect_id),
                };
                if saved.is_err() {
                    let _ = entry.handle.close().await;
                }
                if matches!(saved, Ok(ref run) if matches!(run.status.as_str(), "failed" | "outcome_unknown"))
                {
                    let mut active = entry.active.lock().unwrap();
                    if active
                        .as_ref()
                        .is_some_and(|run| run.run_id == context.run_id)
                    {
                        *active = None;
                    }
                }
            }
        });
        Ok(())
    }

    pub(crate) async fn interrupt_managed_session(&self, thread_id: &str) -> Result<()> {
        let entry = self
            .managed_sessions
            .0
            .lock()
            .unwrap()
            .get(thread_id)
            .cloned()
            .ok_or_else(|| {
                BridgeError::new("already_processed", "There is no live run to interrupt.")
            })?;
        if entry.active.lock().unwrap().is_none() {
            return Err(BridgeError::new(
                "already_processed",
                "The run has already ended.",
            ));
        }
        entry.handle.interrupt().await.map_err(session_error)
    }

    pub(crate) async fn approve_managed_session(
        &self,
        thread_id: &str,
        native_id: crate::codex_protocol::NativeId,
        approved: bool,
    ) -> Result<()> {
        let entry = self
            .managed_sessions
            .0
            .lock()
            .unwrap()
            .get(thread_id)
            .cloned()
            .ok_or_else(|| {
                BridgeError::new(
                    "outcome_unknown",
                    "The provider session is no longer active.",
                )
            })?;
        entry
            .handle
            .resolve_approval(native_id, approved)
            .await
            .map_err(session_error)
    }
}

async fn consume_events(
    daemon: Weak<Daemon>,
    thread_id: String,
    entry: Arc<Entry>,
    mut events: mpsc::Receiver<SessionEvent>,
) {
    while let Some(event) = events.recv().await {
        let Some(owner) = daemon.upgrade() else {
            break;
        };
        let result = {
            // Membership lock fences synchronous projection against session retirement.
            let entries = owner.managed_sessions.0.lock().unwrap();
            if !entries
                .get(&thread_id)
                .is_some_and(|current| Arc::ptr_eq(current, &entry))
            {
                break;
            }
            let current = entry.active.lock().unwrap().clone();
            match event {
                SessionEvent::Ready {
                    thread_id: native_id,
                } => {
                    *entry.native_session.lock().unwrap() = Some(native_id.clone());
                    if entry.claude {
                        Ok(())
                    } else {
                        owner.store.save_provider_session(&thread_id, &native_id)
                    }
                }
                SessionEvent::Codex(event) => {
                    if let Some(context) = current {
                        if let Some(native) = event_turn_id(&event) {
                            if entry
                                .completed_turns
                                .lock()
                                .unwrap()
                                .iter()
                                .any(|id| id == native)
                            {
                                continue;
                            }
                            let mut active = entry.active.lock().unwrap();
                            let Some(active) = active
                                .as_mut()
                                .filter(|active| active.run_id == context.run_id)
                            else {
                                continue;
                            };
                            match active.native_turn_id.as_deref() {
                                Some(expected) if expected != native => continue,
                                None => active.native_turn_id = Some(native.into()),
                                _ => (),
                            }
                        }
                        let session_saved = if entry.claude {
                            match entry.native_session.lock().unwrap().as_deref() {
                                Some(native) => {
                                    owner.store.save_provider_session(&thread_id, native)
                                }
                                None => Err(BridgeError::new(
                                    "storage_error",
                                    "Missing native session identity.",
                                )),
                            }
                        } else {
                            Ok(())
                        };
                        let projected = session_saved.and_then(|_| {
                            owner
                                .store
                                .project_codex_event(&thread_id, &context.run_id, &event)
                        });
                        if projected.is_err() {
                            projected
                        } else if let CodexEvent::TurnCompleted { status, turn_id } = event {
                            let outcome = match status.as_str() {
                                "completed" => TurnOutcome::Completed,
                                "interrupted" => TurnOutcome::Interrupted,
                                _ => TurnOutcome::Failed,
                            };
                            let result = owner
                                .store
                                .finish_turn(&context.effect_id, outcome)
                                .map(|_| ());
                            if result.is_ok() {
                                let mut completed = entry.completed_turns.lock().unwrap();
                                completed.push_back(turn_id);
                                if completed.len() > 128 {
                                    completed.pop_front();
                                }
                                *entry.active.lock().unwrap() = None;
                            }
                            result
                        } else if matches!(event, CodexEvent::ProviderError) {
                            owner
                                .store
                                .mark_turn_unknown(&context.effect_id)
                                .map(|_| ())
                        } else {
                            Ok(())
                        }
                    } else {
                        Ok(())
                    }
                }
                SessionEvent::Failed(_) | SessionEvent::Closed => {
                    if let Some(context) = current {
                        owner
                            .store
                            .mark_turn_unknown(&context.effect_id)
                            .map(|_| ())
                    } else {
                        Ok(())
                    }
                }
            }
        };
        if result.is_err() {
            if let Some(context) = entry.active.lock().unwrap().clone() {
                let _ = owner.store.mark_turn_unknown(&context.effect_id);
            }
            let _ = entry.handle.close().await;
            break;
        }
    }
    if let Some(owner) = daemon.upgrade() {
        let mut entries = owner.managed_sessions.0.lock().unwrap();
        if !entries
            .get(&thread_id)
            .is_some_and(|current| Arc::ptr_eq(current, &entry))
        {
            return;
        }
        if let Some(context) = entry.active.lock().unwrap().clone() {
            let _ = owner.store.mark_turn_unknown(&context.effect_id);
        }
        if !entry.claude
            && entries
                .get(&thread_id)
                .is_some_and(|current| Arc::ptr_eq(current, &entry))
        {
            entries.remove(&thread_id);
        }
    }
}

fn event_turn_id(event: &CodexEvent) -> Option<&str> {
    match event {
        CodexEvent::TurnStarted { turn_id }
        | CodexEvent::AssistantDelta { turn_id, .. }
        | CodexEvent::PublicSummary { turn_id, .. }
        | CodexEvent::AssistantCompleted { turn_id, .. }
        | CodexEvent::AssistantPhase { turn_id, .. }
        | CodexEvent::TurnCompleted { turn_id, .. }
        | CodexEvent::ToolItem { turn_id, .. } => Some(turn_id),
        CodexEvent::ApprovalRequested(request) => Some(&request.turn_id),
        CodexEvent::ApprovalResolved { .. } | CodexEvent::ProviderError => None,
    }
}

pub(crate) fn session_error(error: SessionError) -> BridgeError {
    let (code, message) = match error {
        SessionError::DeliveryUnknown => (
            "outcome_unknown",
            "Provider delivery is uncertain. Do not resend automatically.",
        ),
        SessionError::ApprovalResolved => {
            ("already_processed", "This approval was already processed.")
        }
        SessionError::Busy => ("thread_busy", "This thread already has an active turn."),
        SessionError::InvalidInput => ("invalid_params", "Invalid managed message input."),
        SessionError::Rejected => ("rejected", "The provider rejected the command."),
        SessionError::Unavailable | SessionError::Closed => {
            ("unavailable", "The provider session is unavailable.")
        }
    };
    BridgeError::new(code, message)
}

#[cfg(test)]
mod provider_switch_tests {
    use super::*;
    use crate::{codex_session::SessionTransport, domain::Project, types::now};

    fn entry(provider: &str) -> Arc<Entry> {
        let (transport, _io) = SessionTransport::channel();
        let (handle, _events) = crate::codex_session::spawn(
            SessionOptions {
                cwd: "/tmp".into(),
                thread_id: None,
                model: None,
            },
            transport,
        );
        Arc::new(Entry {
            handle,
            claude: provider == "claude",
            provider_id: provider.into(),
            model: None,
            handoff: Mutex::new(None),
            native_session: Mutex::new(None),
            process: crate::types::ProcessInfo {
                process_id: provider.into(),
                generation: provider.into(),
                agent_id: provider.into(),
                owner_device_id: "host".into(),
                pid: None,
                state: "stopped".into(),
                started_at: now(),
                exit_code: None,
            },
            active: Mutex::new(None),
            completed_turns: Mutex::new(VecDeque::new()),
        })
    }

    #[tokio::test]
    async fn retired_runtime_ready_output_and_cleanup_cannot_touch_replacement() {
        let dir = tempfile::tempdir().unwrap();
        let daemon = Daemon::open_with_adapters(dir.path(), vec![]).unwrap();
        let project = Project {
            id: "p".into(),
            name: "P".into(),
            canonical_root: "/tmp".into(),
            created_at: now(),
            updated_at: now(),
        };
        daemon
            .store
            .create_project("local-host", "p", "p", &project)
            .unwrap();
        daemon
            .store
            .create_thread(
                "local-host",
                "t",
                "t",
                &Thread {
                    id: "t".into(),
                    project_id: "p".into(),
                    provider_id: "claude".into(),
                    model: None,
                    title: "T".into(),
                    cwd: "/tmp".into(),
                    status: "idle".into(),
                    revision: 0,
                    created_at: now(),
                    updated_at: now(),
                },
            )
            .unwrap();
        daemon
            .store
            .save_provider_session("t", "current-claude-session")
            .unwrap();
        let old = entry("codex");
        let current = entry("claude");
        daemon
            .managed_sessions
            .0
            .lock()
            .unwrap()
            .insert("t".into(), current.clone());
        for event in [
            SessionEvent::Ready {
                thread_id: "retired-codex-session".into(),
            },
            SessionEvent::Codex(CodexEvent::AssistantDelta {
                turn_id: "late".into(),
                item_id: "late".into(),
                text: "MUST NOT APPEAR".into(),
            }),
            SessionEvent::Closed,
        ] {
            let (tx, rx) = mpsc::channel(1);
            tx.send(event).await.unwrap();
            drop(tx);
            consume_events(Arc::downgrade(&daemon), "t".into(), old.clone(), rx).await;
        }
        assert_eq!(
            daemon.store.provider_thread_id("t").unwrap().as_deref(),
            Some("current-claude-session")
        );
        assert!(daemon
            .store
            .thread_snapshot("t")
            .unwrap()
            .messages
            .is_empty());
        assert!(daemon.managed_entry_is_current("t", &current));
        daemon.shutdown().await.unwrap();
    }
}
