//! Claude stream-json protocol adapter. The public event algebra is shared with
//! Codex; native control payloads and thinking blocks never enter projections.
use crate::codex_protocol::{ApprovalRequest, CodexEvent, NativeId, ToolItem, MAX_LINE_BYTES};
use crate::codex_session::{
    Command, NativeWrite, SessionError, SessionEvent, SessionHandle, SessionOptions, SessionState,
    SessionTransport, TurnInput, MAX_INPUT_BYTES, MAX_TRANSPORT_CHUNK,
};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{timeout, Duration};

const DEADLINE: Duration = Duration::from_secs(30);
const MAX_ITEMS: usize = 128;

pub(crate) fn spawn(
    options: SessionOptions,
    transport: SessionTransport,
) -> (SessionHandle, mpsc::Receiver<SessionEvent>) {
    spawn_with_timeout(options, transport, DEADLINE)
}
fn spawn_with_timeout(
    options: SessionOptions,
    transport: SessionTransport,
    deadline: Duration,
) -> (SessionHandle, mpsc::Receiver<SessionEvent>) {
    let (commands, command_rx) = mpsc::channel(16);
    let (events, event_rx) = mpsc::channel(256);
    let (state, state_rx) = watch::channel(SessionState::Initializing);
    let actor = Actor {
        transport,
        deadline,
        events,
        state,
        thread_id: options
            .thread_id
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
        cwd: options.cwd,
        buffer: vec![],
        active: None,
        message_id: None,
        approvals: HashMap::new(),
        tools: HashMap::new(),
        seen: HashSet::new(),
        interrupted: false,
        had_text: false,
        completed: false,
    };
    tokio::spawn(actor.run(command_rx));
    (
        SessionHandle {
            commands,
            state: state_rx,
        },
        event_rx,
    )
}

struct Actor {
    deadline: Duration,
    transport: SessionTransport,
    events: mpsc::Sender<SessionEvent>,
    state: watch::Sender<SessionState>,
    thread_id: String,
    cwd: String,
    buffer: Vec<u8>,
    active: Option<String>,
    message_id: Option<String>,
    approvals: HashMap<NativeId, Value>,
    tools: HashMap<String, String>,
    seen: HashSet<String>,
    interrupted: bool,
    had_text: bool,
    completed: bool,
}
impl Actor {
    fn emit(&self, event: CodexEvent) -> Result<(), SessionError> {
        self.events
            .try_send(SessionEvent::Codex(event))
            .map_err(|_| SessionError::Unavailable)
    }
    async fn write(&self, value: Value) -> Result<(), SessionError> {
        let mut bytes = serde_json::to_vec(&value).map_err(|_| SessionError::InvalidInput)?;
        if bytes.len() >= MAX_LINE_BYTES {
            return Err(SessionError::InvalidInput);
        }
        bytes.push(b'\n');
        let (done, ack) = oneshot::channel();
        timeout(self.deadline, async {
            self.transport
                .to_agent
                .send(NativeWrite { bytes, done })
                .await
                .map_err(|_| SessionError::Closed)?;
            ack.await.map_err(|_| SessionError::DeliveryUnknown)?
        })
        .await
        .map_err(|_| SessionError::DeliveryUnknown)?
    }
    // State lives on the actor so cancellation by select never drops partial UTF-8.
    async fn next(&mut self) -> Result<Value, SessionError> {
        loop {
            if let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
                if end > MAX_LINE_BYTES {
                    return Err(SessionError::Unavailable);
                }
                let line: Vec<_> = self.buffer.drain(..=end).collect();
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                return serde_json::from_slice(&line).map_err(|_| SessionError::Unavailable);
            }
            if self.buffer.len() > MAX_LINE_BYTES {
                return Err(SessionError::Unavailable);
            }
            let bytes = self
                .transport
                .from_agent
                .recv()
                .await
                .ok_or(SessionError::DeliveryUnknown)?;
            if bytes.len() > MAX_TRANSPORT_CHUNK {
                return Err(SessionError::Unavailable);
            }
            self.buffer.extend(bytes);
        }
    }
    async fn control(&mut self, subtype: &str) -> Result<(), SessionError> {
        let id = uuid::Uuid::new_v4().to_string();
        self.write(json!({"type":"control_request","request_id":id,"request":{"subtype":subtype,"hooks":{}}})).await?;
        timeout(self.deadline, async {
            let mut completion = None;
            loop {
                let value = self.next().await?;
                if value["type"] == "control_response" && value["response"]["request_id"] == id {
                    let accepted = value["response"]["subtype"] == "success";
                    if subtype == "interrupt" {
                        self.interrupted = accepted;
                    }
                    if let Some(result) = completion {
                        self.event(result).await?;
                    }
                    return if accepted {
                        Ok(())
                    } else {
                        Err(SessionError::Rejected)
                    };
                }
                if subtype == "interrupt" && value["type"] == "result" {
                    // Completion may race the control ACK. Classify it only
                    // once native acceptance/rejection of interrupt is known.
                    if completion.replace(value).is_some() {
                        return Err(SessionError::Unavailable);
                    }
                } else {
                    self.event(value).await?;
                }
            }
        })
        .await
        .map_err(|_| SessionError::DeliveryUnknown)?
    }
    async fn run(mut self, mut commands: mpsc::Receiver<Command>) {
        let result = self.execute(&mut commands).await;
        let error = result.err().unwrap_or(SessionError::Closed);
        self.state.send_replace(if error == SessionError::Closed {
            SessionState::Closed
        } else {
            SessionState::Failed(error.clone())
        });
        let _ = self.events.try_send(if error == SessionError::Closed {
            SessionEvent::Closed
        } else {
            SessionEvent::Failed(error.clone())
        });
        commands.close();
        while let Some(command) = commands.recv().await {
            let reply = match command {
                Command::Send(_, r)
                | Command::Interrupt(r)
                | Command::Approval(_, _, r)
                | Command::Close(r) => r,
            };
            let _ = reply.send(Err(error.clone()));
        }
    }
    async fn execute(
        &mut self,
        commands: &mut mpsc::Receiver<Command>,
    ) -> Result<(), SessionError> {
        self.control("initialize").await?;
        self.state
            .send_replace(SessionState::Ready(self.thread_id.clone()));
        self.events
            .try_send(SessionEvent::Ready {
                thread_id: self.thread_id.clone(),
            })
            .map_err(|_| SessionError::Unavailable)?;
        loop {
            // Claude results carry no turn identifier. Retire this process after
            // a result; next input resumes the persisted session in a fresh
            // process so late stdout can never be attributed to a new Run.
            if self.completed {
                return Ok(());
            }
            tokio::select! {
                command = commands.recv() => {
                    let Some(command) = command else { return Ok(()); };
                    let (result, reply) = match command {
                        Command::Send(input, reply) => (self.send(input).await, reply),
                        Command::Interrupt(reply) => {
                            let result = if self.active.is_none() { Err(SessionError::ApprovalResolved) } else {
                                match self.control("interrupt").await {
                                    Ok(()) => Ok(Value::Null),
                                    Err(SessionError::Rejected) => { self.interrupted = false; Err(SessionError::Rejected) },
                                    Err(error) => Err(error),
                                }
                            };
                            (result, reply)
                        },
                        Command::Approval(id, approved, reply) => (self.approve(id, approved).await.map(|_| Value::Null), reply),
                        Command::Close(reply) => { let _ = reply.send(Ok(Value::Null)); return Ok(()); }
                    };
                    let fatal = matches!(result, Err(SessionError::DeliveryUnknown | SessionError::Unavailable | SessionError::Closed));
                    let error = result.as_ref().err().cloned();
                    let _ = reply.send(result);
                    if fatal { return Err(error.unwrap()); }
                }
                value = self.next() => self.event(value?).await?,
            }
        }
    }
    async fn send(&mut self, input: TurnInput) -> Result<Value, SessionError> {
        if (input.text.trim().is_empty() && input.images.is_empty())
            || input.text.len() > MAX_INPUT_BYTES
            || input.client_message_id.len() > 128
            || input.images.len() > 4
            || input
                .images
                .iter()
                .any(|i| i.len() > 256 * 1024 || !i.starts_with(&[0xff, 0xd8]))
            || input.images.iter().map(Vec::len).sum::<usize>() > 1024 * 1024
        {
            return Err(SessionError::InvalidInput);
        }
        if self.active.is_some() {
            return Err(SessionError::Busy);
        }
        let turn = uuid::Uuid::new_v4().to_string();
        // No native turn ID exists in Claude's stream; one active user input is
        // correlated until its result. Never queue a second input before result.
        let content = if input.images.is_empty() {
            json!(input.text)
        } else {
            let mut blocks = Vec::with_capacity(input.images.len() + 1);
            if !input.text.trim().is_empty() {
                blocks.push(json!({"type": "text", "text": input.text}));
            }
            for image in &input.images {
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": crate::codex_session::base64_encode(image),
                    }
                }));
            }
            Value::Array(blocks)
        };
        self.write(json!({"type":"user","session_id":self.thread_id,"uuid":input.client_message_id,"parent_tool_use_id":null,"message":{"role":"user","content":content}})).await?;
        self.active = Some(turn.clone());
        self.message_id = None;
        self.approvals.clear();
        self.tools.clear();
        self.seen.clear();
        self.interrupted = false;
        self.had_text = false;
        self.emit(CodexEvent::TurnStarted {
            turn_id: turn.clone(),
        })?;
        Ok(json!(turn))
    }
    async fn approve(&mut self, id: NativeId, approved: bool) -> Result<(), SessionError> {
        let input = self
            .approvals
            .remove(&id)
            .ok_or(SessionError::ApprovalResolved)?;
        let response = if approved {
            json!({"behavior":"allow","updatedInput":input})
        } else {
            json!({"behavior":"deny","message":"Denied by the user."})
        };
        self.write(json!({"type":"control_response","response":{"subtype":"success","request_id":id.value(),"response":response}})).await?;
        self.emit(CodexEvent::ApprovalResolved { native_id: id })
    }
    async fn refuse(&self, id: &Value) -> Result<(), SessionError> {
        self.write(json!({"type":"control_response","response":{"subtype":"error","request_id":id,"error":"Unsupported control request."}})).await
    }
    async fn event(&mut self, value: Value) -> Result<(), SessionError> {
        if let Some(id) = value.get("session_id").and_then(Value::as_str) {
            if !id.is_empty() && id != self.thread_id {
                return Err(SessionError::Unavailable);
            }
        }
        if value["type"] == "control_request" {
            let id = NativeId::from_value(&value["request_id"]).ok_or(SessionError::Unavailable)?;
            let request = &value["request"];
            if request["subtype"] != "can_use_tool"
                || self.active.is_none()
                || !request["input"].is_object()
            {
                return self.refuse(&id.value()).await;
            }
            if self.approvals.contains_key(&id) {
                return Ok(());
            }
            if self.approvals.len() >= MAX_ITEMS {
                return Err(SessionError::Unavailable);
            }
            let detail =
                serde_json::to_string(&request["input"]).map_err(|_| SessionError::Unavailable)?;
            if detail.len() > 64 * 1024 {
                return Err(SessionError::Unavailable);
            }
            let tool = string(&request["tool_name"])?;
            let item = request
                .get("tool_use_id")
                .and_then(Value::as_str)
                .unwrap_or(&tool)
                .to_owned();
            self.approvals.insert(id.clone(), request["input"].clone());
            return self.emit(CodexEvent::ApprovalRequested(ApprovalRequest {
                native_id: id,
                turn_id: self.active.clone().unwrap(),
                item_id: item,
                kind: tool,
                target: self.cwd.clone(),
                detail,
            }));
        }
        if value["type"] == "control_cancel_request" {
            if let Some(id) = NativeId::from_value(&value["request_id"]) {
                if self.approvals.remove(&id).is_some() {
                    self.emit(CodexEvent::ApprovalResolved { native_id: id })?;
                }
            }
            return Ok(());
        }
        let Some(turn) = self.active.clone() else {
            if value["type"] == "result" && value["is_error"] == true {
                return Err(SessionError::Rejected);
            }
            return Ok(());
        };
        // Child-agent stream text is excluded; its tool lifecycle remains visible.
        if value
            .get("parent_tool_use_id")
            .is_some_and(|v| !v.is_null())
        {
            return Ok(());
        }
        match value["type"].as_str() {
            Some("stream_event") => {
                let event = &value["event"];
                match event["type"].as_str() {
                    Some("message_start") => {
                        self.message_id = Some(string(&event["message"]["id"])?);
                    }
                    Some("content_block_delta") if event["delta"]["type"] == "text_delta" => {
                        let message = self.message_id.as_ref().ok_or(SessionError::Unavailable)?;
                        let index = event["index"].as_u64().ok_or(SessionError::Unavailable)?;
                        if index >= MAX_ITEMS as u64 {
                            return Err(SessionError::Unavailable);
                        }
                        let text = text(&event["delta"]["text"])?;
                        self.emit(CodexEvent::AssistantDelta {
                            turn_id: turn,
                            item_id: format!("{message}:{index}"),
                            text,
                        })?;
                        self.had_text = true;
                    }
                    _ => (), // Never project thinking/signature/input-json deltas.
                }
            }
            Some("assistant") => {
                let id = string(&value["message"]["id"])?;
                if self.seen.contains(&id) {
                    return Ok(());
                }
                if self.seen.len() >= MAX_ITEMS {
                    return Err(SessionError::Unavailable);
                }
                self.seen.insert(id.clone());
                let blocks = value["message"]["content"]
                    .as_array()
                    .ok_or(SessionError::Unavailable)?;
                if blocks.len() > MAX_ITEMS {
                    return Err(SessionError::Unavailable);
                }
                for (index, block) in blocks.iter().enumerate() {
                    match block["type"].as_str() {
                        Some("text") => {
                            self.emit(CodexEvent::AssistantCompleted {
                                turn_id: turn.clone(),
                                item_id: format!("{id}:{index}"),
                                text: text(&block["text"])?,
                            })?;
                            self.had_text = true;
                        }
                        Some("tool_use") => {
                            let tool_id = string(&block["id"])?;
                            let name = string(&block["name"])?;
                            if self.tools.len() >= MAX_ITEMS {
                                return Err(SessionError::Unavailable);
                            }
                            let input = block["input"].to_string();
                            if input.len() > MAX_INPUT_BYTES {
                                return Err(SessionError::Unavailable);
                            }
                            self.tools.insert(tool_id.clone(), name.clone());
                            self.emit(CodexEvent::ToolItem {
                                turn_id: turn.clone(),
                                item: ToolItem {
                                    id: tool_id,
                                    kind: name,
                                    completed: false,
                                    failed: None,
                                    input: Some(input),
                                    output: None,
                                },
                            })?;
                        }
                        _ => (),
                    }
                }
            }
            Some("user") => {
                if let Some(blocks) = value["message"]["content"].as_array() {
                    for block in blocks.iter().filter(|b| b["type"] == "tool_result") {
                        let id = string(&block["tool_use_id"])?;
                        let output = match &block["content"] {
                            Value::String(s) => s.clone(),
                            Value::Array(blocks) => blocks
                                .iter()
                                .filter(|b| b["type"] == "text")
                                .filter_map(|b| b["text"].as_str())
                                .collect::<Vec<_>>()
                                .join("\n"),
                            _ => String::new(),
                        };
                        if output.len() > MAX_INPUT_BYTES {
                            return Err(SessionError::Unavailable);
                        }
                        self.emit(CodexEvent::ToolItem {
                            turn_id: turn.clone(),
                            item: ToolItem {
                                kind: self
                                    .tools
                                    .get(&id)
                                    .cloned()
                                    .unwrap_or_else(|| "tool".into()),
                                id,
                                completed: true,
                                failed: block["is_error"].as_bool(),
                                input: None,
                                output: Some(output),
                            },
                        })?;
                    }
                }
            }
            Some("result") => {
                if !self.had_text {
                    if let Some(result) = value["result"].as_str() {
                        self.emit(CodexEvent::AssistantCompleted {
                            turn_id: turn.clone(),
                            item_id: "result".into(),
                            text: text(&json!(result))?,
                        })?;
                    }
                }
                let status = if self.interrupted {
                    "interrupted"
                } else if value["is_error"] == true || value["subtype"] != "success" {
                    "failed"
                } else {
                    "completed"
                };
                for id in self.approvals.keys() {
                    self.emit(CodexEvent::ApprovalResolved {
                        native_id: id.clone(),
                    })?;
                }
                self.approvals.clear();
                // Fence reuse before the persistence consumer releases Thread busy.
                self.state.send_replace(SessionState::Closed);
                self.emit(CodexEvent::TurnCompleted {
                    turn_id: turn,
                    status: status.into(),
                })?;
                self.active = None;
                self.completed = true;
            }
            _ => (),
        }
        Ok(())
    }
}
fn string(value: &Value) -> Result<String, SessionError> {
    value
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 400)
        .map(str::to_owned)
        .ok_or(SessionError::Unavailable)
}
fn text(value: &Value) -> Result<String, SessionError> {
    value
        .as_str()
        .filter(|v| v.len() <= MAX_INPUT_BYTES)
        .map(str::to_owned)
        .ok_or(SessionError::Unavailable)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_session::SessionIo;
    async fn record(io: &mut SessionIo) -> Value {
        let request = timeout(Duration::from_secs(2), io.from_client.recv())
            .await
            .unwrap()
            .unwrap();
        let value = serde_json::from_slice(&request.bytes).unwrap();
        request.done.send(Ok(())).unwrap();
        value
    }
    async fn push(io: &SessionIo, value: Value) {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        // Exercise framing across arbitrary UTF-8 and JSON boundaries.
        for chunk in bytes.chunks(7) {
            io.to_client.send(chunk.to_vec()).await.unwrap();
        }
    }
    async fn setup() -> (SessionHandle, mpsc::Receiver<SessionEvent>, SessionIo) {
        let (transport, mut io) = SessionTransport::channel();
        let (handle, mut events) = spawn(
            SessionOptions {
                cwd: "/tmp/project".into(),
                thread_id: Some("session".into()),
                model: None,
            },
            transport,
        );
        let init = record(&mut io).await;
        assert_eq!(init["request"]["subtype"], "initialize");
        assert_eq!(handle.state(), SessionState::Initializing);
        push(&io, json!({"type":"system","subtype":"hook_started"})).await;
        push(&io, json!({"type":"control_response","response":{"subtype":"success","request_id":init["request_id"],"response":{}}})).await;
        assert_eq!(handle.ready().await.unwrap(), "session");
        assert!(matches!(
            events.recv().await,
            Some(SessionEvent::Ready { .. })
        ));
        (handle, events, io)
    }
    async fn start(handle: &SessionHandle, io: &mut SessionIo) -> String {
        let h = handle.clone();
        let turn = tokio::spawn(async move {
            h.send_turn(TurnInput {
                text: "hello".into(),
                images: vec![],
                client_message_id: "client-message".into(),
            })
            .await
        });
        let user = record(io).await;
        assert_eq!(user["message"]["content"], "hello");
        turn.await.unwrap().unwrap()
    }
    async fn next(events: &mut mpsc::Receiver<SessionEvent>) -> CodexEvent {
        match timeout(Duration::from_secs(2), events.recv())
            .await
            .unwrap()
            .unwrap()
        {
            SessionEvent::Codex(event) => event,
            other => panic!("unexpected {other:?}"),
        }
    }
    #[tokio::test]
    async fn split_stream_final_and_private_blocks_share_public_item_identity() {
        let (handle, mut events, mut io) = setup().await;
        let turn = start(&handle, &mut io).await;
        assert_eq!(
            next(&mut events).await,
            CodexEvent::TurnStarted {
                turn_id: turn.clone()
            }
        );
        push(&io, json!({"type":"stream_event","event":{"type":"message_start","message":{"id":"message"}}})).await;
        push(&io, json!({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}})).await;
        assert_eq!(
            next(&mut events).await,
            CodexEvent::AssistantDelta {
                turn_id: turn.clone(),
                item_id: "message:0".into(),
                text: "你好".into()
            }
        );
        push(&io, json!({"type":"assistant","message":{"id":"message","content":[{"type":"text","text":"你好世界"},{"type":"thinking","thinking":"SECRET"}]}})).await;
        assert_eq!(
            next(&mut events).await,
            CodexEvent::AssistantCompleted {
                turn_id: turn.clone(),
                item_id: "message:0".into(),
                text: "你好世界".into()
            }
        );
        push(
            &io,
            json!({"type":"result","subtype":"success","is_error":false,"result":"你好世界"}),
        )
        .await;
        assert_eq!(
            next(&mut events).await,
            CodexEvent::TurnCompleted {
                turn_id: turn,
                status: "completed".into()
            }
        );
        assert!(!matches!(events.try_recv(), Ok(SessionEvent::Codex(_))));
        assert!(timeout(Duration::from_secs(1), io.from_client.recv())
            .await
            .unwrap()
            .is_none());
    }
    #[tokio::test]
    async fn approval_preserves_original_input_and_is_one_shot() {
        let (handle, mut events, mut io) = setup().await;
        start(&handle, &mut io).await;
        next(&mut events).await;
        let input = json!({"command":"echo safe","nested":{"x":1}});
        push(&io, json!({"type":"control_request","request_id":"approval","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool","input":input}})).await;
        assert!(matches!(
            next(&mut events).await,
            CodexEvent::ApprovalRequested(_)
        ));
        let h = handle.clone();
        let approval = tokio::spawn(async move {
            h.resolve_approval(NativeId::String("approval".into()), true)
                .await
        });
        let response = record(&mut io).await;
        assert_eq!(response["type"], "control_response");
        assert_eq!(response["response"]["request_id"], "approval");
        assert_eq!(response["response"]["response"]["updatedInput"], input);
        approval.await.unwrap().unwrap();
        assert!(matches!(
            next(&mut events).await,
            CodexEvent::ApprovalResolved { .. }
        ));
        assert_eq!(
            handle
                .resolve_approval(NativeId::String("approval".into()), true)
                .await,
            Err(SessionError::ApprovalResolved)
        );
        handle.close().await.unwrap();
    }
    #[tokio::test]
    async fn eof_after_input_is_unknown_without_replay() {
        let (handle, mut events, mut io) = setup().await;
        start(&handle, &mut io).await;
        next(&mut events).await;
        drop(io.to_client);
        assert_eq!(
            timeout(Duration::from_secs(2), events.recv())
                .await
                .unwrap(),
            Some(SessionEvent::Failed(SessionError::DeliveryUnknown))
        );
        assert!(io.from_client.recv().await.is_none());
    }
    #[tokio::test]
    async fn interrupt_waits_for_control_ack_and_authoritative_result() {
        let (handle, mut events, mut io) = setup().await;
        let turn = start(&handle, &mut io).await;
        next(&mut events).await;
        let h = handle.clone();
        let interrupt = tokio::spawn(async move { h.interrupt().await });
        let request = record(&mut io).await;
        assert_eq!(request["request"]["subtype"], "interrupt");
        push(&io, json!({"type":"control_response","response":{"subtype":"success","request_id":request["request_id"],"response":{}}})).await;
        interrupt.await.unwrap().unwrap();
        assert!(events.try_recv().is_err());
        push(
            &io,
            json!({"type":"result","subtype":"error_during_execution","is_error":true}),
        )
        .await;
        assert_eq!(
            next(&mut events).await,
            CodexEvent::TurnCompleted {
                turn_id: turn,
                status: "interrupted".into()
            }
        );
        assert!(timeout(Duration::from_secs(1), io.from_client.recv())
            .await
            .unwrap()
            .is_none());
    }
}

#[cfg(test)]
mod boundary_tests {
    use super::*;
    use crate::codex_session::SessionIo;
    async fn setup() -> (SessionHandle, mpsc::Receiver<SessionEvent>, SessionIo) {
        let (transport, mut io) = SessionTransport::channel();
        let (handle, events) = spawn(
            SessionOptions {
                cwd: "/tmp".into(),
                thread_id: Some("session".into()),
                model: None,
            },
            transport,
        );
        let request = timeout(Duration::from_secs(1), io.from_client.recv())
            .await
            .unwrap()
            .unwrap();
        let value: Value = serde_json::from_slice(&request.bytes).unwrap();
        request.done.send(Ok(())).unwrap();
        push(&io, json!({"type":"control_response","response":{"subtype":"success","request_id":value["request_id"],"response":{}}})).await;
        handle.ready().await.unwrap();
        (handle, events, io)
    }
    async fn push(io: &SessionIo, value: Value) {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        io.to_client.send(bytes).await.unwrap();
    }
    async fn request(io: &mut SessionIo) -> Value {
        let req = io.from_client.recv().await.unwrap();
        let v = serde_json::from_slice(&req.bytes).unwrap();
        req.done.send(Ok(())).unwrap();
        v
    }
    #[tokio::test]
    async fn deny_sends_explicit_denial_and_unknown_control_requests_fail_closed() {
        let (handle, mut events, mut io) = setup().await;
        let send = {
            let h = handle.clone();
            tokio::spawn(async move {
                h.send_turn(TurnInput {
                    text: "x".into(),
                    images: vec![],
                    client_message_id: "c".into(),
                })
                .await
            })
        };
        request(&mut io).await;
        send.await.unwrap().unwrap();
        let _ = events.recv().await;
        push(&io, json!({"type":"control_request","request_id":"deny","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /"}}})).await;
        let _ = events.recv().await;
        let deny = {
            let h = handle.clone();
            tokio::spawn(async move {
                h.resolve_approval(NativeId::String("deny".into()), false)
                    .await
            })
        };
        let response = request(&mut io).await;
        deny.await.unwrap().unwrap();
        assert_eq!(response["response"]["response"]["behavior"], "deny");
        push(&io, json!({"type":"control_request","request_id":"unknown","request":{"subtype":"unknown_request","input":{}}})).await;
        let response = request(&mut io).await;
        assert_eq!(response["response"]["subtype"], "error");
        handle.close().await.unwrap();
    }
    #[tokio::test]
    async fn mismatched_session_event_is_rejected_before_projection() {
        let (handle, mut events, io) = setup().await;
        events.recv().await;
        push(&io, json!({"type":"assistant","session_id":"other","message":{"id":"m","content":[{"type":"text","text":"leak"}]}})).await;
        assert_eq!(
            timeout(Duration::from_secs(1), events.recv())
                .await
                .unwrap(),
            Some(SessionEvent::Failed(SessionError::Unavailable))
        );
        assert!(handle
            .send_turn(TurnInput {
                text: "x".into(),
                images: vec![],
                client_message_id: "c".into()
            })
            .await
            .is_err());
    }
    #[tokio::test]
    async fn initialize_response_and_write_ack_deadlines_retire_transport() {
        for acknowledge in [true, false] {
            let (transport, mut io) = SessionTransport::channel();
            let (handle, mut events) = spawn_with_timeout(
                SessionOptions {
                    cwd: "/tmp".into(),
                    thread_id: Some("session".into()),
                    model: None,
                },
                transport,
                Duration::from_millis(20),
            );
            let request = io.from_client.recv().await.unwrap();
            if acknowledge {
                request.done.send(Ok(())).unwrap();
            } else {
                // Keep the sender alive past the deadline, emulating a stalled writer.
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    drop(request);
                });
            }
            assert_eq!(
                timeout(Duration::from_secs(1), handle.ready())
                    .await
                    .unwrap(),
                Err(SessionError::DeliveryUnknown)
            );
            assert_eq!(
                events.recv().await,
                Some(SessionEvent::Failed(SessionError::DeliveryUnknown))
            );
            assert!(io.from_client.recv().await.is_none());
        }
    }
    #[tokio::test]
    async fn result_before_rejected_interrupt_ack_keeps_natural_completion() {
        let (handle, mut events, mut io) = setup().await;
        events.recv().await;
        let h = handle.clone();
        let send = tokio::spawn(async move {
            h.send_turn(TurnInput {
                text: "x".into(),
                images: vec![],
                client_message_id: "id".into(),
            })
            .await
        });
        request(&mut io).await;
        send.await.unwrap().unwrap();
        events.recv().await;
        let h = handle.clone();
        let interrupt = tokio::spawn(async move { h.interrupt().await });
        let control = request(&mut io).await;
        push(
            &io,
            json!({"type":"result","subtype":"success","is_error":false}),
        )
        .await;
        push(&io, json!({"type":"control_response","response":{"subtype":"error","request_id":control["request_id"],"error":"already complete"}})).await;
        assert_eq!(interrupt.await.unwrap(), Err(SessionError::Rejected));
        assert!(
            matches!(events.recv().await, Some(SessionEvent::Codex(CodexEvent::TurnCompleted { status, .. })) if status == "completed")
        );
        assert_eq!(handle.state(), SessionState::Closed);
        assert!(io.from_client.recv().await.is_none());
    }
}
