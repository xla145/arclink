//! Codex app-server protocol boundary for service-owned sessions.
//!
//! The decoder emits public events only. Responses remain internal to request
//! correlation; never send their unfiltered result to clients or persist it.
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

pub const MAX_LINE_BYTES: usize = 2 * 1024 * 1024;
const MAX_ITEMS: usize = 128;
const MAX_TEXT_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum NativeId {
    String(String),
    Number(i64),
}
impl NativeId {
    /// Type-prefixed keys avoid collisions between JSON id 7 and id "7".
    pub fn key(&self) -> String {
        match self {
            Self::String(value) => format!("s:{value}"),
            Self::Number(value) => format!("n:{value}"),
        }
    }
    pub fn from_value(value: &Value) -> Option<Self> {
        match value {
            Value::String(value) if !value.is_empty() && value.len() <= 512 => {
                Some(Self::String(value.clone()))
            }
            Value::Number(value) => value.as_i64().map(Self::Number),
            _ => None,
        }
    }
    pub fn value(&self) -> Value {
        match self {
            Self::String(value) => json!(value),
            Self::Number(value) => json!(value),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolItem {
    pub id: String,
    pub kind: String,
    pub completed: bool,
    pub failed: Option<bool>,
    pub input: Option<String>,
    pub output: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalRequest {
    pub native_id: NativeId,
    pub turn_id: String,
    pub item_id: String,
    pub kind: String,
    pub target: String,
    pub detail: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexEvent {
    TurnStarted {
        turn_id: String,
    },
    AssistantDelta {
        turn_id: String,
        item_id: String,
        text: String,
    },
    PublicSummary {
        turn_id: String,
        item_id: String,
        text: String,
    },
    AssistantCompleted {
        turn_id: String,
        item_id: String,
        text: String,
    },
    AssistantPhase {
        turn_id: String,
        item_id: String,
        phase: String,
    },
    ToolItem {
        turn_id: String,
        item: ToolItem,
    },
    TurnCompleted {
        turn_id: String,
        status: String,
    },
    ApprovalRequested(ApprovalRequest),
    ApprovalResolved {
        native_id: NativeId,
    },
    ProviderError,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Incoming {
    Event(CodexEvent),
    /// Internal response only. The caller must extract expected fields for the
    /// pending method; this is not a client-facing event or message.
    Response {
        id: NativeId,
        result: Value,
    },
    Rejected {
        id: NativeId,
    },
    RefuseRequest {
        id: NativeId,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProtocolError {
    InvalidJson,
    InvalidMessage,
    LineTooLarge,
    ResourceLimit,
}
impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Codex protocol error: {self:?}")
    }
}
impl std::error::Error for ProtocolError {}

pub struct Decoder {
    thread_id: String,
    active_turn: Option<String>,
    buffer: Vec<u8>,
    completed_turns: HashSet<String>,
    summaries: HashMap<String, BTreeMap<u64, String>>,
    approvals: HashSet<NativeId>,
}
impl Decoder {
    pub fn new(thread_id: impl Into<String>) -> Self {
        Self {
            thread_id: thread_id.into(),
            active_turn: None,
            buffer: Vec::new(),
            completed_turns: HashSet::new(),
            summaries: HashMap::new(),
            approvals: HashSet::new(),
        }
    }
    /// Called for the native turn/start ACK. A late ACK cannot revive a turn
    /// whose completion notification already arrived.
    pub fn set_active_turn(&mut self, turn_id: String) {
        if !self.completed_turns.contains(&turn_id) {
            self.active_turn = Some(turn_id);
        }
    }
    pub fn active_turn(&self) -> Option<&str> {
        self.active_turn.as_deref()
    }

    /// Input may be fragmented at any byte boundary. No partial record is
    /// exposed. On error the owner must retire this decoder/session.
    pub fn push(&mut self, mut bytes: &[u8]) -> Result<Vec<Incoming>, ProtocolError> {
        let mut output = Vec::new();
        while !bytes.is_empty() {
            let end = bytes.iter().position(|b| *b == b'\n');
            let count = end.unwrap_or(bytes.len());
            if self.buffer.len().saturating_add(count) > MAX_LINE_BYTES {
                return Err(ProtocolError::LineTooLarge);
            }
            self.buffer.extend_from_slice(&bytes[..count]);
            if end.is_none() {
                break;
            }
            bytes = &bytes[count + 1..];
            let record = std::mem::take(&mut self.buffer);
            if record.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let value: Value =
                serde_json::from_slice(&record).map_err(|_| ProtocolError::InvalidJson)?;
            output.extend(self.decode(value)?);
        }
        Ok(output)
    }

    fn decode(&mut self, value: Value) -> Result<Vec<Incoming>, ProtocolError> {
        let object = value.as_object().ok_or(ProtocolError::InvalidMessage)?;
        let id = object
            .get("id")
            .map(|v| NativeId::from_value(v).ok_or(ProtocolError::InvalidMessage))
            .transpose()?;
        if let Some(method) = object.get("method").and_then(Value::as_str) {
            let empty = Map::new();
            let params = object
                .get("params")
                .and_then(Value::as_object)
                .unwrap_or(&empty);
            if let Some(id) = id {
                if !self.belongs(params)
                    || field(params, "itemId").is_none()
                    || !matches!(
                        method,
                        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval"
                    )
                {
                    return Ok(vec![Incoming::RefuseRequest { id }]);
                }
                if self.approvals.contains(&id) {
                    return Ok(vec![]);
                }
                if self.approvals.len() >= MAX_ITEMS {
                    return Err(ProtocolError::ResourceLimit);
                }
                self.approvals.insert(id.clone());
                return Ok(vec![Incoming::Event(CodexEvent::ApprovalRequested(
                    approval(method, id, params),
                ))]);
            }
            return self.notification(method, params);
        }
        let id = id.ok_or(ProtocolError::InvalidMessage)?;
        if object.get("error").is_some_and(|e| !e.is_null()) {
            return Ok(vec![Incoming::Rejected { id }]);
        }
        let result = object
            .get("result")
            .cloned()
            .ok_or(ProtocolError::InvalidMessage)?;
        Ok(vec![Incoming::Response { id, result }])
    }

    fn belongs(&self, params: &Map<String, Value>) -> bool {
        field(params, "threadId") == Some(self.thread_id.as_str())
            && self
                .active_turn
                .as_deref()
                .is_some_and(|turn| field(params, "turnId") == Some(turn))
    }
    fn notification(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Vec<Incoming>, ProtocolError> {
        if field(params, "threadId") != Some(self.thread_id.as_str()) {
            return Ok(vec![]);
        }
        let mut events = Vec::new();
        match method {
            "turn/started" => {
                if let Some(id) = params
                    .get("turn")
                    .and_then(|t| t.get("id"))
                    .and_then(Value::as_str)
                {
                    if !self.completed_turns.contains(id)
                        && self
                            .active_turn
                            .as_deref()
                            .is_none_or(|active| active == id)
                    {
                        self.active_turn = Some(id.into());
                        events.push(CodexEvent::TurnStarted { turn_id: id.into() });
                    }
                }
            }
            "turn/completed" => {
                if let Some(turn) = params.get("turn").and_then(Value::as_object) {
                    if let Some(id) = field(turn, "id") {
                        if !self.completed_turns.contains(id)
                            && self
                                .active_turn
                                .as_deref()
                                .is_none_or(|active| active == id)
                        {
                            self.active_turn = None;
                            if self.completed_turns.len() == MAX_ITEMS {
                                self.completed_turns.clear();
                            }
                            self.completed_turns.insert(id.into());
                            for native_id in self.approvals.drain() {
                                events.push(CodexEvent::ApprovalResolved { native_id });
                            }
                            self.summaries.clear();
                            let status = match field(turn, "status") {
                                Some("completed") => "completed",
                                Some("interrupted") => "interrupted",
                                _ => "failed",
                            };
                            events.push(CodexEvent::TurnCompleted {
                                turn_id: id.into(),
                                status: status.into(),
                            });
                        }
                    }
                }
            }
            "serverRequest/resolved" => {
                if let Some(id) = params.get("requestId").and_then(NativeId::from_value) {
                    if self.approvals.remove(&id) {
                        events.push(CodexEvent::ApprovalResolved { native_id: id });
                    }
                }
            }
            "error" if params.get("willRetry").and_then(Value::as_bool) == Some(false) => {
                events.push(CodexEvent::ProviderError)
            }
            "item/agentMessage/delta" if self.belongs(params) => {
                if let (Some(item_id), Some(text), Some(turn_id)) = (
                    field(params, "itemId"),
                    field(params, "delta"),
                    field(params, "turnId"),
                ) {
                    events.push(CodexEvent::AssistantDelta {
                        turn_id: turn_id.into(),
                        item_id: item_id.into(),
                        text: checked_text(text)?,
                    });
                }
            }
            "item/reasoning/summaryTextDelta" if self.belongs(params) => {
                if let (Some(item_id), Some(delta), Some(turn_id), Some(index)) = (
                    field(params, "itemId"),
                    field(params, "delta"),
                    field(params, "turnId"),
                    params
                        .get("summaryIndex")
                        .and_then(Value::as_u64)
                        .filter(|i| *i < 128),
                ) {
                    if !self.summaries.contains_key(item_id) && self.summaries.len() >= MAX_ITEMS {
                        return Err(ProtocolError::ResourceLimit);
                    }
                    let parts = self.summaries.entry(item_id.into()).or_default();
                    let part = parts.entry(index).or_default();
                    if part.len().saturating_add(delta.len()) > MAX_TEXT_BYTES {
                        return Err(ProtocolError::ResourceLimit);
                    }
                    part.push_str(delta);
                    let text = parts.values().cloned().collect::<Vec<_>>().join("\n\n");
                    if text.len() > MAX_TEXT_BYTES {
                        return Err(ProtocolError::ResourceLimit);
                    }
                    events.push(CodexEvent::PublicSummary {
                        turn_id: turn_id.into(),
                        item_id: item_id.into(),
                        text,
                    });
                }
            }
            "item/started" | "item/completed" if self.belongs(params) => {
                if let (Some(item), Some(turn_id)) = (
                    params.get("item").and_then(Value::as_object),
                    field(params, "turnId"),
                ) {
                    public_item(item, turn_id, method == "item/completed", &mut events)?;
                }
            }
            _ => {} // No private reasoning or unknown payload projection.
        }
        Ok(events.into_iter().map(Incoming::Event).collect())
    }
}

pub fn approval_response(id: &NativeId, approved: bool) -> Value {
    json!({"id": id.value(), "result": {"decision": if approved { "accept" } else { "decline" }}})
}
pub fn unsupported_response(id: &NativeId) -> Value {
    json!({"id": id.value(), "error": {"code": -32601, "message": "Unsupported request on this client"}})
}
fn field<'a>(values: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    values.get(key).and_then(Value::as_str)
}
fn bounded(value: &str, max: usize) -> String {
    let mut end = value.len().min(max);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}
fn approval(method: &str, native_id: NativeId, params: &Map<String, Value>) -> ApprovalRequest {
    let command = method == "item/commandExecution/requestApproval";
    let mut detail = if command {
        format!(
            "工作目录：{}",
            bounded(field(params, "cwd").unwrap_or("未知"), 4096)
        )
    } else {
        "Codex 未提供可显示的文件差异，请在 Mac 上确认。".into()
    };
    if let Some(reason) = field(params, "reason") {
        detail.push_str("\n\n");
        detail.push_str(&bounded(reason, 4096));
    }
    ApprovalRequest {
        native_id,
        turn_id: field(params, "turnId").unwrap_or_default().into(),
        item_id: field(params, "itemId").unwrap_or_default().into(),
        kind: if command { "command" } else { "file_change" }.into(),
        target: bounded(
            field(params, if command { "command" } else { "grantRoot" }).unwrap_or(if command {
                "命令详情不可用"
            } else {
                "项目文件"
            }),
            16_384,
        ),
        detail,
    }
}
fn public_item(
    item: &Map<String, Value>,
    turn_id: &str,
    completed: bool,
    events: &mut Vec<CodexEvent>,
) -> Result<(), ProtocolError> {
    let Some(id) = field(item, "id") else {
        return Ok(());
    };
    match field(item, "type") {
        Some("agentMessage") => {
            if let Some(phase) = ["phase", "channel"]
                .iter()
                .filter_map(|key| field(item, key))
                .find_map(|phase| match phase {
                    "commentary" => Some("commentary"),
                    "final" | "final_answer" => Some("final_answer"),
                    _ => None,
                })
            {
                events.push(CodexEvent::AssistantPhase {
                    turn_id: turn_id.into(),
                    item_id: id.into(),
                    phase: phase.into(),
                });
            }
            if completed {
                if let Some(text) = field(item, "text") {
                    events.push(CodexEvent::AssistantCompleted {
                        turn_id: turn_id.into(),
                        item_id: id.into(),
                        text: checked_text(text)?,
                    });
                }
            }
        }
        Some("reasoning") => {
            if let Some(parts) = item.get("summary").and_then(Value::as_array) {
                let text = parts
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("\n\n");
                events.push(CodexEvent::PublicSummary {
                    turn_id: turn_id.into(),
                    item_id: id.into(),
                    text: checked_text(&text)?,
                });
            }
        }
        Some(
            kind @ ("commandExecution" | "fileChange" | "mcpToolCall" | "dynamicToolCall"
            | "webSearch"),
        ) => {
            let failed = if !completed {
                None
            } else if matches!(
                field(item, "status"),
                Some("failed" | "declined" | "cancelled")
            ) {
                Some(true)
            } else if let Some(code) = item.get("exitCode").and_then(Value::as_i64) {
                Some(code != 0)
            } else if let Some(success) = item.get("success").and_then(Value::as_bool) {
                Some(!success)
            } else if item.get("error").is_some_and(|e| !e.is_null()) {
                Some(true)
            } else if let Some(error) = item
                .get("result")
                .and_then(|r| r.get("isError"))
                .and_then(Value::as_bool)
            {
                Some(error)
            } else if field(item, "status") == Some("completed") {
                Some(false)
            } else {
                None
            };
            // Only fields explicitly representing tool inputs/outputs are public.
            // Tool errors are represented by status, never arbitrary diagnostics.
            let input = ["command", "arguments", "changes", "action"]
                .iter()
                .find_map(|key| public_value(item.get(*key)));
            let output = ["aggregatedOutput", "result", "contentItems"]
                .iter()
                .find_map(|key| public_value(item.get(*key)));
            events.push(CodexEvent::ToolItem {
                turn_id: turn_id.into(),
                item: ToolItem {
                    id: id.into(),
                    kind: kind.into(),
                    completed,
                    failed,
                    input,
                    output,
                },
            });
        }
        _ => {}
    }
    Ok(())
}
fn checked_text(text: &str) -> Result<String, ProtocolError> {
    if text.len() > MAX_TEXT_BYTES {
        return Err(ProtocolError::ResourceLimit);
    }
    Ok(text.to_owned())
}
fn public_value(value: Option<&Value>) -> Option<String> {
    value.filter(|v| !v.is_null()).map(|v| {
        bounded(
            v.as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| v.to_string())
                .as_str(),
            16_384,
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn feed(decoder: &mut Decoder, value: Value) -> Vec<Incoming> {
        decoder.push(format!("{value}\n").as_bytes()).unwrap()
    }
    fn active() -> Decoder {
        let mut d = Decoder::new("thread");
        d.set_active_turn("turn".into());
        d
    }
    #[test]
    fn fragmented_utf8_and_multiple_records_are_decoded_once() {
        let mut d = active();
        let line = json!({"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"turn","itemId":"item","delta":"你好"}}).to_string() + "\n";
        let split = line.find('你').unwrap() + 1;
        assert!(d.push(&line.as_bytes()[..split]).unwrap().is_empty());
        assert_eq!(
            d.push(&line.as_bytes()[split..]).unwrap(),
            vec![Incoming::Event(CodexEvent::AssistantDelta {
                turn_id: "turn".into(),
                item_id: "item".into(),
                text: "你好".into()
            })]
        );
    }
    #[test]
    fn other_thread_and_private_reasoning_never_project() {
        let mut d = active();
        for params in [
            json!({"threadId":"child","turnId":"turn","itemId":"item","delta":"secret"}),
            json!({"threadId":"thread","turnId":"old","itemId":"item","delta":"secret"}),
        ] {
            assert!(feed(
                &mut d,
                json!({"method":"item/agentMessage/delta","params":params})
            )
            .is_empty());
        }
        assert!(feed(&mut d, json!({"method":"item/started","params":{"threadId":"thread","turnId":"turn","item":{"id":"i","type":"reasoning","content":["secret"],"encryptedContent":"secret"}}})).is_empty());
    }
    #[test]
    fn public_summary_parts_preserve_index_order() {
        let mut d = active();
        for (index, delta) in [(1, "second"), (0, "first")] {
            let out = feed(
                &mut d,
                json!({"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread","turnId":"turn","itemId":"i","summaryIndex":index,"delta":delta}}),
            );
            if index == 0 {
                assert!(
                    matches!(&out[0], Incoming::Event(CodexEvent::PublicSummary { text, .. }) if text == "first\n\nsecond")
                );
            }
        }
    }
    #[test]
    fn completed_before_ack_cannot_revive_turn() {
        let mut d = active();
        let out = feed(
            &mut d,
            json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}}),
        );
        assert!(
            matches!(&out[0], Incoming::Event(CodexEvent::TurnCompleted {status,..}) if status=="completed")
        );
        d.set_active_turn("turn".into());
        assert_eq!(d.active_turn(), None);
    }
    #[test]
    fn approval_ids_are_type_safe_and_unsupported_requests_are_refused() {
        let mut d = active();
        for id in [json!(7), json!("7")] {
            let out = feed(
                &mut d,
                json!({"id":id,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"i","command":"echo ok"}}),
            );
            let Incoming::Event(CodexEvent::ApprovalRequested(a)) = &out[0] else {
                panic!()
            };
            assert_eq!(
                approval_response(&a.native_id, true),
                json!({"id":id,"result":{"decision":"accept"}})
            );
        }
        assert_ne!(
            NativeId::Number(7).key(),
            NativeId::String("7".into()).key()
        );
        let out = feed(
            &mut d,
            json!({"id":9,"method":"unsupported","params":{"private":"secret"}}),
        );
        assert_eq!(
            out,
            vec![Incoming::RefuseRequest {
                id: NativeId::Number(9)
            }]
        );
        assert_eq!(
            unsupported_response(&NativeId::Number(9))["error"]["code"],
            -32601
        );
    }
    #[test]
    fn tool_failure_uses_exit_code_before_completed_status() {
        let mut d = active();
        let out = feed(
            &mut d,
            json!({"method":"item/completed","params":{"threadId":"thread","turnId":"turn","item":{"id":"i","type":"commandExecution","status":"completed","exitCode":1,"command":"false","aggregatedOutput":"failed"}}}),
        );
        assert!(
            matches!(&out[0],Incoming::Event(CodexEvent::ToolItem{item,..}) if item.failed==Some(true) && item.output.as_deref()==Some("failed"))
        );
    }
    #[test]
    fn complete_message_never_silently_truncates() {
        let mut d = active();
        let value = json!({"method":"item/completed","params":{"threadId":"thread","turnId":"turn","item":{"id":"i","type":"agentMessage","text":"x".repeat(MAX_TEXT_BYTES + 1)}}});
        assert_eq!(
            d.push(format!("{value}\n").as_bytes()),
            Err(ProtocolError::ResourceLimit)
        );
    }
    #[test]
    fn completion_settles_approvals_and_replayed_requests_are_deduplicated() {
        let mut d = active();
        let request = json!({"id":"request","method":"item/fileChange/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"i","grantRoot":"/project"}});
        assert_eq!(feed(&mut d, request.clone()).len(), 1);
        assert!(feed(&mut d, request).is_empty());
        let events = feed(
            &mut d,
            json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"interrupted"}}}),
        );
        assert!(
            events.contains(&Incoming::Event(CodexEvent::ApprovalResolved {
                native_id: NativeId::String("request".into())
            }))
        );
    }
    #[test]
    fn oversized_and_invalid_records_fail_without_echoing_input() {
        let mut d = active();
        assert_eq!(
            d.push(&vec![b'x'; MAX_LINE_BYTES + 1]),
            Err(ProtocolError::LineTooLarge)
        );
        let mut d = active();
        assert_eq!(
            d.push(b"secret-not-json\n"),
            Err(ProtocolError::InvalidJson)
        );
        assert!(!ProtocolError::InvalidJson.to_string().contains("secret"));
    }
}
