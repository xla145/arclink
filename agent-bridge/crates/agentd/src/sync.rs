//! Durable managed-thread synchronization DTOs. Sequence numbers are decimal strings.
use crate::domain::{Approval, Message, Run, Thread};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThreadSnapshot {
    pub environment_id: String,
    pub sequence: String,
    pub thread: Thread,
    pub messages: Vec<Message>,
    pub runs: Vec<Run>,
    pub approvals: Vec<Approval>,
    pub has_older_messages: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThreadHistory {
    pub thread_id: String,
    pub messages: Vec<Message>,
    pub has_more: bool,
    pub next_before_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThreadEvent {
    pub sequence: String,
    pub aggregate_id: String,
    pub event_type: String,
    pub schema_version: u32,
    pub payload: serde_json::Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThreadReplay {
    pub environment_id: String,
    pub thread_id: String,
    /// Applied only after the complete batch. May skip other threads' events.
    pub sequence: String,
    pub events: Vec<ThreadEvent>,
    pub has_more: bool,
}
