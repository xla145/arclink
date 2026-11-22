//! Bounded Codex session actor. ProcessManager supplies byte I/O and keeps
//! ownership of the OS process. No mutation is automatically replayed.
use crate::codex_protocol::{
    approval_response, unsupported_response, CodexEvent, Decoder, Incoming, NativeId,
    MAX_LINE_BYTES,
};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{timeout, Duration};

pub const MAX_INPUT_BYTES: usize = 256 * 1024;
pub const MAX_TRANSPORT_CHUNK: usize = 64 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct SessionOptions {
    pub cwd: String,
    pub thread_id: Option<String>,
    pub model: Option<String>,
}
#[derive(Clone, Debug)]
pub struct TurnInput {
    pub text: String,
    pub images: Vec<Vec<u8>>,
    pub client_message_id: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionError {
    Rejected,
    DeliveryUnknown,
    Unavailable,
    InvalidInput,
    Busy,
    ApprovalResolved,
    Closed,
}
impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Codex session: {self:?}")
    }
}
impl std::error::Error for SessionError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionState {
    Initializing,
    Ready(String),
    Failed(SessionError),
    Closed,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionEvent {
    Ready { thread_id: String },
    Codex(CodexEvent),
    Failed(SessionError),
    Closed,
}

/// The adapter must ACK only after the complete record was written. A queued
/// write is not success. It must never retry a failed/partially written record.
pub struct NativeWrite {
    pub bytes: Vec<u8>,
    pub done: oneshot::Sender<Result<(), SessionError>>,
}
pub struct SessionTransport {
    pub to_agent: mpsc::Sender<NativeWrite>,
    pub from_agent: mpsc::Receiver<Vec<u8>>,
}
pub struct SessionIo {
    pub from_client: mpsc::Receiver<NativeWrite>,
    /// Send chunks <= MAX_TRANSPORT_CHUNK. Dropping this sender signals EOF.
    pub to_client: mpsc::Sender<Vec<u8>>,
}
impl SessionTransport {
    pub fn channel() -> (Self, SessionIo) {
        let (to_agent, from_client) = mpsc::channel(1);
        let (to_client, from_agent) = mpsc::channel(32);
        (
            Self {
                to_agent,
                from_agent,
            },
            SessionIo {
                from_client,
                to_client,
            },
        )
    }
}
pub(crate) type Reply = oneshot::Sender<Result<Value, SessionError>>;
pub(crate) enum Command {
    Send(TurnInput, Reply),
    Interrupt(Reply),
    Approval(NativeId, bool, Reply),
    Close(Reply),
}
#[derive(Clone)]
pub struct SessionHandle {
    pub(crate) commands: mpsc::Sender<Command>,
    pub(crate) state: watch::Receiver<SessionState>,
}
impl SessionHandle {
    pub fn state(&self) -> SessionState {
        self.state.borrow().clone()
    }
    pub async fn ready(&self) -> Result<String, SessionError> {
        let mut state = self.state.clone();
        loop {
            let current = state.borrow().clone();
            match current {
                SessionState::Ready(id) => return Ok(id),
                SessionState::Failed(error) => return Err(error),
                SessionState::Closed => return Err(SessionError::Closed),
                SessionState::Initializing => {
                    state.changed().await.map_err(|_| SessionError::Closed)?
                }
            }
        }
    }
    async fn request(
        &self,
        command: Command,
        response: oneshot::Receiver<Result<Value, SessionError>>,
    ) -> Result<Value, SessionError> {
        if let SessionState::Failed(error) = self.state() {
            return Err(error);
        }
        self.commands
            .try_send(command)
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => SessionError::Busy,
                mpsc::error::TrySendError::Closed(_) => SessionError::Closed,
            })?;
        response.await.map_err(|_| SessionError::Closed)?
    }
    pub async fn send_turn(&self, input: TurnInput) -> Result<String, SessionError> {
        validate_input(&input)?;
        self.ready().await?;
        let (reply, response) = oneshot::channel();
        self.request(Command::Send(input, reply), response)
            .await?
            .as_str()
            .map(str::to_owned)
            .ok_or(SessionError::Unavailable)
    }
    pub async fn interrupt(&self) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.request(Command::Interrupt(reply), response)
            .await
            .map(|_| ())
    }
    pub async fn resolve_approval(&self, id: NativeId, approved: bool) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.request(Command::Approval(id, approved, reply), response)
            .await
            .map(|_| ())
    }
    pub async fn close(&self) -> Result<(), SessionError> {
        let (reply, response) = oneshot::channel();
        self.request(Command::Close(reply), response)
            .await
            .map(|_| ())
    }
}
pub fn spawn(
    options: SessionOptions,
    transport: SessionTransport,
) -> (SessionHandle, mpsc::Receiver<SessionEvent>) {
    spawn_with_timeout(options, transport, REQUEST_TIMEOUT)
}
fn spawn_with_timeout(
    options: SessionOptions,
    transport: SessionTransport,
    request_timeout: Duration,
) -> (SessionHandle, mpsc::Receiver<SessionEvent>) {
    let (commands, command_rx) = mpsc::channel(16);
    let (events, event_rx) = mpsc::channel(256);
    let (state, state_rx) = watch::channel(SessionState::Initializing);
    let actor = Actor {
        transport,
        events,
        state,
        request_timeout,
        decoder: Decoder::new(""),
        thread_id: String::new(),
        next_id: 0,
        buffer: Vec::new(),
        decoded: VecDeque::new(),
        approvals: HashMap::new(),
    };
    tokio::spawn(actor.run(options, command_rx));
    (
        SessionHandle {
            commands,
            state: state_rx,
        },
        event_rx,
    )
}

struct Actor {
    transport: SessionTransport,
    events: mpsc::Sender<SessionEvent>,
    state: watch::Sender<SessionState>,
    request_timeout: Duration,
    decoder: Decoder,
    thread_id: String,
    next_id: u64,
    buffer: Vec<u8>,
    decoded: VecDeque<Incoming>,
    /// false = pending, true = decision submitted; retained until native settlement.
    approvals: HashMap<NativeId, bool>,
}
impl Actor {
    fn emit(&self, event: SessionEvent) -> Result<(), SessionError> {
        // A stalled persistence consumer must fail visibly, not lose events.
        self.events
            .try_send(event)
            .map_err(|_| SessionError::Unavailable)
    }
    async fn write(&self, value: Value) -> Result<(), SessionError> {
        let mut bytes = serde_json::to_vec(&value).map_err(|_| SessionError::InvalidInput)?;
        if bytes.len() >= MAX_LINE_BYTES {
            return Err(SessionError::InvalidInput);
        }
        bytes.push(b'\n');
        let (done, ack) = oneshot::channel();
        timeout(self.request_timeout, async {
            self.transport
                .to_agent
                .send(NativeWrite { bytes, done })
                .await
                .map_err(|_| SessionError::Unavailable)?;
            ack.await.map_err(|_| SessionError::Unavailable)?
        })
        .await
        .map_err(|_| SessionError::DeliveryUnknown)?
    }

    /// Parse one native record at a time. A thread/start response can therefore
    /// set the thread ID before a following notification in the same byte chunk.
    async fn next(&mut self) -> Result<Incoming, SessionError> {
        loop {
            if let Some(item) = self.decoded.pop_front() {
                return Ok(item);
            }
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let bytes: Vec<u8> = self.buffer.drain(..=end).collect();
                self.decoded.extend(
                    self.decoder
                        .push(&bytes)
                        .map_err(|_| SessionError::Unavailable)?,
                );
                continue;
            }
            if self.buffer.len() > MAX_LINE_BYTES {
                return Err(SessionError::Unavailable);
            }
            let bytes = self
                .transport
                .from_agent
                .recv()
                .await
                .ok_or(SessionError::Unavailable)?;
            if bytes.len() > MAX_TRANSPORT_CHUNK {
                return Err(SessionError::Unavailable);
            }
            self.buffer.extend(bytes);
        }
    }
    async fn event(&mut self, incoming: Incoming) -> Result<(), SessionError> {
        match incoming {
            Incoming::Event(event) => {
                match &event {
                    CodexEvent::ApprovalRequested(request) => {
                        self.approvals
                            .entry(request.native_id.clone())
                            .or_insert(false);
                    }
                    CodexEvent::ApprovalResolved { native_id } => {
                        self.approvals.remove(native_id);
                    }
                    CodexEvent::TurnCompleted { .. } => self.approvals.clear(),
                    _ => {}
                }
                self.emit(SessionEvent::Codex(event))
            }
            Incoming::RefuseRequest { id } => self.write(unsupported_response(&id)).await,
            // Responses that do not match the sole pending request cannot
            // settle it, and are not forwarded as public data.
            Incoming::Response { .. } | Incoming::Rejected { .. } => Ok(()),
        }
    }
    async fn exchange(
        &mut self,
        method: &str,
        params: Value,
        mutation: bool,
    ) -> Result<Value, SessionError> {
        self.next_id += 1;
        let native_id = NativeId::String(format!("arclink-{}", self.next_id));
        let request = json!({"id":native_id.value(),"method":method,"params":params});
        let duration = self.request_timeout;
        let result = timeout(duration, async {
            self.write(request).await?;
            loop {
                match self.next().await? {
                    Incoming::Response { id, result } if id == native_id => return Ok(result),
                    Incoming::Rejected { id } if id == native_id => {
                        return Err(SessionError::Rejected)
                    }
                    event => self.event(event).await?,
                }
            }
        })
        .await
        .unwrap_or(Err(SessionError::DeliveryUnknown));
        match result {
            Err(SessionError::Unavailable | SessionError::DeliveryUnknown) if mutation => {
                Err(SessionError::DeliveryUnknown)
            }
            other => other,
        }
    }
    async fn initialize(&mut self, options: SessionOptions) -> Result<(), SessionError> {
        if options.cwd.is_empty()
            || options.cwd.len() > 4096
            || options
                .thread_id
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 512)
        {
            return Err(SessionError::InvalidInput);
        }
        self.exchange("initialize", json!({"clientInfo":{"name":"arclink_agentd","title":"ArcLink","version":env!("CARGO_PKG_VERSION")}}), false).await?;
        self.write(json!({"method":"initialized","params":{}}))
            .await?;
        let mut params = json!({"cwd":options.cwd,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"});
        if let Some(model) = options.model {
            if model.is_empty() || model.len() > 256 {
                return Err(SessionError::InvalidInput);
            }
            params["model"] = json!(model);
        }
        let method = if let Some(id) = options.thread_id {
            params["threadId"] = json!(id);
            params["excludeTurns"] = json!(true);
            "thread/resume"
        } else {
            "thread/start"
        };
        let result = self.exchange(method, params, true).await?;
        let id = result
            .get("thread")
            .and_then(|v| v.get("id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= 512)
            .ok_or(SessionError::DeliveryUnknown)?;
        self.thread_id = id.into();
        self.decoder = Decoder::new(id);
        self.state.send_replace(SessionState::Ready(id.into()));
        self.emit(SessionEvent::Ready {
            thread_id: id.into(),
        })
    }
    async fn send(&mut self, input: TurnInput) -> Result<Value, SessionError> {
        if self.decoder.active_turn().is_some() {
            return Err(SessionError::Busy);
        }
        validate_input(&input)?;
        let mut content = Vec::new();
        if !input.text.trim().is_empty() {
            content.push(json!({"type":"text","text":input.text}));
        }
        for image in input.images {
            content.push(json!({"type":"image","url":format!("data:image/jpeg;base64,{}", base64_encode(&image))}));
        }
        let params = json!({"threadId":self.thread_id,"clientUserMessageId":input.client_message_id,"input":content});
        let result = self.exchange("turn/start", params, true).await?;
        let id = result
            .get("turn")
            .and_then(|t| t.get("id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or(SessionError::DeliveryUnknown)?
            .to_owned();
        let had_turn = self.decoder.active_turn().is_some();
        self.decoder.set_active_turn(id.clone());
        if !had_turn && self.decoder.active_turn() == Some(id.as_str()) {
            self.emit(SessionEvent::Codex(CodexEvent::TurnStarted {
                turn_id: id.clone(),
            }))?;
        }
        Ok(Value::String(id))
    }
    async fn interrupt(&mut self) -> Result<Value, SessionError> {
        let turn_id = self
            .decoder
            .active_turn()
            .ok_or(SessionError::Rejected)?
            .to_owned();
        self.exchange(
            "turn/interrupt",
            json!({"threadId":self.thread_id,"turnId":turn_id}),
            true,
        )
        .await?;
        // The ACK is not completion; only turn/completed clears active state.
        Ok(Value::Null)
    }
    async fn approval(&mut self, id: NativeId, approved: bool) -> Result<Value, SessionError> {
        match self.approvals.get_mut(&id) {
            Some(submitted) if !*submitted => *submitted = true,
            _ => return Err(SessionError::ApprovalResolved),
        }
        self.write(approval_response(&id, approved))
            .await
            .map_err(|_| SessionError::DeliveryUnknown)?;
        Ok(Value::Null)
    }
    async fn run(mut self, options: SessionOptions, mut commands: mpsc::Receiver<Command>) {
        let result = self.initialize(options).await;
        if let Err(error) = result {
            self.fail(error, &mut commands);
            return;
        }
        loop {
            tokio::select! {
                // next() retains partial bytes in self.buffer and never awaits
                // after taking a complete record, so cancellation is safe.
                incoming = self.next() => {
                    let result = match incoming {
                        Ok(event) => self.event(event).await,
                        Err(_) if self.decoder.active_turn().is_some() => Err(SessionError::DeliveryUnknown),
                        Err(error) => Err(error),
                    };
                    if let Err(error) = result { self.fail(error, &mut commands); return; }
                }
                command = commands.recv() => {
                    let Some(command) = command else { self.state.send_replace(SessionState::Closed); return; };
                    let (result, reply) = match command {
                        Command::Send(input, reply) => (self.send(input).await, reply),
                        Command::Interrupt(reply) => (self.interrupt().await, reply),
                        Command::Approval(id, approved, reply) => (self.approval(id, approved).await, reply),
                        Command::Close(reply) => { let _ = reply.send(Ok(Value::Null)); self.state.send_replace(SessionState::Closed); let _ = self.emit(SessionEvent::Closed); return; }
                    };
                    let fatal = matches!(result, Err(SessionError::DeliveryUnknown | SessionError::Unavailable));
                    let failure = result.as_ref().err().cloned();
                    let _ = reply.send(result);
                    if fatal { self.fail(failure.unwrap(), &mut commands); return; }
                }
            }
        }
    }
    fn fail(&self, error: SessionError, commands: &mut mpsc::Receiver<Command>) {
        self.state.send_replace(SessionState::Failed(error.clone()));
        let _ = self.emit(SessionEvent::Failed(error.clone()));
        commands.close();
        while let Ok(command) = commands.try_recv() {
            let reply = match command {
                Command::Send(_, r)
                | Command::Interrupt(r)
                | Command::Approval(_, _, r)
                | Command::Close(r) => r,
            };
            let _ = reply.send(Err(error.clone()));
        }
    }
}
fn validate_input(input: &TurnInput) -> Result<(), SessionError> {
    if (input.text.trim().is_empty() && input.images.is_empty())
        || input.text.len() > MAX_INPUT_BYTES
        || input.client_message_id.is_empty()
        || input.client_message_id.len() > 512
        || input.images.len() > 4
        || input
            .images
            .iter()
            .any(|i| i.len() > 256 * 1024 || !i.starts_with(&[0xff, 0xd8]))
        || input.images.iter().map(Vec::len).sum::<usize>() > 1024 * 1024
    {
        return Err(SessionError::InvalidInput);
    }
    Ok(())
}
pub(crate) fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let a = c[0] as usize;
        let b = c.get(1).copied().unwrap_or(0) as usize;
        let d = c.get(2).copied().unwrap_or(0) as usize;
        out.push(TABLE[a >> 2] as char);
        out.push(TABLE[((a & 3) << 4) | (b >> 4)] as char);
        out.push(if c.len() > 1 {
            TABLE[((b & 15) << 2) | (d >> 6)] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            TABLE[d & 63] as char
        } else {
            '='
        });
    }
    out
}

pub(crate) fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let clean: Vec<u8> = input.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if clean.len() % 4 != 0 {
        return None;
    }
    let val = |b: u8| -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let mut out = Vec::with_capacity(clean.len() / 4 * 3);
    for chunk in clean.chunks_exact(4) {
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        out.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = val(chunk[2])?;
            out.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = val(chunk[3])?;
                out.push((c << 6) | d);
            }
        } else if chunk[3] != b'=' {
            return None;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn read(io: &mut SessionIo) -> Value {
        let write = timeout(Duration::from_secs(1), io.from_client.recv())
            .await
            .unwrap()
            .unwrap();
        let value = serde_json::from_slice(&write.bytes).unwrap();
        write.done.send(Ok(())).unwrap();
        value
    }
    async fn send(io: &SessionIo, value: Value) {
        io.to_client
            .send(format!("{value}\n").into_bytes())
            .await
            .unwrap();
    }
    async fn initialized(
        resume: bool,
        request_timeout: Duration,
    ) -> (SessionHandle, mpsc::Receiver<SessionEvent>, SessionIo) {
        let (transport, mut io) = SessionTransport::channel();
        let (handle, mut events) = spawn_with_timeout(
            SessionOptions {
                cwd: "/project".into(),
                thread_id: resume.then(|| "thread".into()),
                model: Some("fixture-model".into()),
            },
            transport,
            request_timeout,
        );
        let init = read(&mut io).await;
        assert_eq!(init["method"], "initialize");
        send(&io, json!({"id":init["id"],"result":{}})).await;
        assert_eq!(read(&mut io).await["method"], "initialized");
        let start = read(&mut io).await;
        assert_eq!(
            start["method"],
            if resume {
                "thread/resume"
            } else {
                "thread/start"
            }
        );
        assert_eq!(start["params"]["sandbox"], "workspace-write");
        assert_eq!(start["params"]["model"], "fixture-model");
        if resume {
            assert_eq!(start["params"]["threadId"], "thread");
        }
        send(
            &io,
            json!({"id":start["id"],"result":{"thread":{"id":"thread"}}}),
        )
        .await;
        assert_eq!(handle.ready().await.unwrap(), "thread");
        assert_eq!(
            events.recv().await.unwrap(),
            SessionEvent::Ready {
                thread_id: "thread".into()
            }
        );
        (handle, events, io)
    }
    fn input() -> TurnInput {
        TurnInput {
            text: "hello".into(),
            images: vec![],
            client_message_id: "client-1".into(),
        }
    }
    #[tokio::test]
    async fn handshake_and_turn_round_trip_with_notifications_before_ack() {
        let (handle, mut events, mut io) = initialized(false, Duration::from_secs(1)).await;
        let h = handle.clone();
        let task = tokio::spawn(async move { h.send_turn(input()).await });
        let turn = read(&mut io).await;
        assert_eq!(turn["method"], "turn/start");
        assert_eq!(turn["params"]["clientUserMessageId"], "client-1");
        send(
            &io,
            json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
        )
        .await;
        send(&io, json!({"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"turn","itemId":"i","delta":"hello"}})).await;
        send(&io, json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}})).await;
        send(
            &io,
            json!({"id":turn["id"],"result":{"turn":{"id":"turn"}}}),
        )
        .await;
        assert_eq!(task.await.unwrap().unwrap(), "turn");
        assert!(matches!(
            events.recv().await.unwrap(),
            SessionEvent::Codex(CodexEvent::TurnStarted { .. })
        ));
        assert!(matches!(
            events.recv().await.unwrap(),
            SessionEvent::Codex(CodexEvent::AssistantDelta { .. })
        ));
        assert!(matches!(
            events.recv().await.unwrap(),
            SessionEvent::Codex(CodexEvent::TurnCompleted { .. })
        ));
        assert!(events.try_recv().is_err()); // late ACK did not revive turn
        handle.close().await.unwrap();
    }
    #[tokio::test]
    async fn resume_and_approval_preserve_native_id_and_one_shot_fence() {
        let (handle, mut events, mut io) = initialized(true, Duration::from_secs(1)).await;
        send(
            &io,
            json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
        )
        .await;
        events.recv().await.unwrap();
        send(&io, json!({"id":4,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"item","command":"echo ok"}})).await;
        assert!(matches!(
            events.recv().await.unwrap(),
            SessionEvent::Codex(CodexEvent::ApprovalRequested(_))
        ));
        let h = handle.clone();
        let approve =
            tokio::spawn(async move { h.resolve_approval(NativeId::Number(4), true).await });
        assert_eq!(
            read(&mut io).await,
            json!({"id":4,"result":{"decision":"accept"}})
        );
        approve.await.unwrap().unwrap();
        assert_eq!(
            handle.resolve_approval(NativeId::Number(4), true).await,
            Err(SessionError::ApprovalResolved)
        );
        send(
            &io,
            json!({"id":"unsupported","method":"unknown/request","params":{}}),
        )
        .await;
        assert_eq!(read(&mut io).await["error"]["code"], -32601);
        handle.close().await.unwrap();
    }
    #[tokio::test]
    async fn missing_ack_times_out_without_replaying_mutation() {
        let (handle, mut events, mut io) = initialized(false, Duration::from_millis(150)).await;
        let h = handle.clone();
        let task = tokio::spawn(async move { h.send_turn(input()).await });
        let request = read(&mut io).await;
        assert_eq!(request["method"], "turn/start");
        assert_eq!(task.await.unwrap(), Err(SessionError::DeliveryUnknown));
        assert_eq!(
            events.recv().await.unwrap(),
            SessionEvent::Failed(SessionError::DeliveryUnknown)
        );
        assert_eq!(
            handle.send_turn(input()).await,
            Err(SessionError::DeliveryUnknown)
        );
        assert!(io.from_client.recv().await.is_none());
    }
    #[tokio::test]
    async fn eof_fails_pending_mutation() {
        let (handle, _events, mut io) = initialized(false, Duration::from_secs(1)).await;
        let h = handle.clone();
        let task = tokio::spawn(async move { h.send_turn(input()).await });
        read(&mut io).await;
        drop(io.to_client);
        assert_eq!(task.await.unwrap(), Err(SessionError::DeliveryUnknown));
    }
    #[tokio::test]
    async fn rejects_invalid_images_and_empty_input_before_writing() {
        let (handle, _events, mut io) = initialized(false, Duration::from_secs(1)).await;
        for input in [
            TurnInput {
                text: "".into(),
                images: vec![],
                client_message_id: "x".into(),
            },
            TurnInput {
                text: "".into(),
                images: vec![b"not jpeg".to_vec()],
                client_message_id: "x".into(),
            },
            TurnInput {
                text: "x".repeat(MAX_INPUT_BYTES + 1),
                images: vec![],
                client_message_id: "x".into(),
            },
        ] {
            assert_eq!(
                handle.send_turn(input).await,
                Err(SessionError::InvalidInput)
            );
        }
        assert!(io.from_client.try_recv().is_err());
        handle.close().await.unwrap();
    }
    #[tokio::test]
    async fn missing_stdin_ack_retires_session_without_a_second_write() {
        let (handle, mut events, mut io) = initialized(false, Duration::from_millis(150)).await;
        let h = handle.clone();
        let task = tokio::spawn(async move { h.send_turn(input()).await });
        let pending_write = io.from_client.recv().await.unwrap();
        let request: Value = serde_json::from_slice(&pending_write.bytes).unwrap();
        assert_eq!(request["method"], "turn/start");
        // Keep the ACK alive but deliberately never acknowledge the OS write.
        assert_eq!(task.await.unwrap(), Err(SessionError::DeliveryUnknown));
        assert_eq!(
            events.recv().await.unwrap(),
            SessionEvent::Failed(SessionError::DeliveryUnknown)
        );
        assert!(io.from_client.recv().await.is_none());
        assert!(pending_write.done.send(Ok(())).is_err());
    }

    #[tokio::test]
    async fn closed_event_consumer_retires_actor_and_fails_pending_command() {
        let (handle, events, mut io) = initialized(false, Duration::from_secs(1)).await;
        drop(events);
        let h = handle.clone();
        let task = tokio::spawn(async move { h.send_turn(input()).await });
        read(&mut io).await;
        send(
            &io,
            json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
        )
        .await;
        assert_eq!(task.await.unwrap(), Err(SessionError::DeliveryUnknown));
        assert_eq!(
            handle.state(),
            SessionState::Failed(SessionError::DeliveryUnknown)
        );
    }

    #[tokio::test]
    async fn turn_completion_releases_pending_approval() {
        let (handle, mut events, io) = initialized(false, Duration::from_secs(1)).await;
        send(
            &io,
            json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
        )
        .await;
        events.recv().await.unwrap();
        send(&io, json!({"id":"approval","method":"item/fileChange/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"item","grantRoot":"/project"}})).await;
        assert!(matches!(
            events.recv().await,
            Some(SessionEvent::Codex(CodexEvent::ApprovalRequested(_)))
        ));
        send(&io, json!({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}})).await;
        assert!(matches!(
            events.recv().await,
            Some(SessionEvent::Codex(CodexEvent::ApprovalResolved { .. }))
        ));
        assert!(matches!(
            events.recv().await,
            Some(SessionEvent::Codex(CodexEvent::TurnCompleted { .. }))
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
    async fn active_turn_eof_is_unknown_not_success() {
        let (handle, mut events, io) = initialized(false, Duration::from_secs(1)).await;
        send(
            &io,
            json!({"method":"turn/started","params":{"threadId":"thread","turn":{"id":"turn"}}}),
        )
        .await;
        events.recv().await.unwrap();
        drop(io.to_client);
        assert_eq!(
            events.recv().await.unwrap(),
            SessionEvent::Failed(SessionError::DeliveryUnknown)
        );
        assert_eq!(
            handle.state(),
            SessionState::Failed(SessionError::DeliveryUnknown)
        );
    }

    #[test]
    fn jpeg_base64_encoding_is_correct() {
        assert_eq!(base64_encode(&[0xff, 0xd8, 0xff]), "/9j/");
        assert_eq!(base64_encode(&[0xff, 0xd8]), "/9g=");
        assert_eq!(base64_encode(&[0xff]), "/w==");
    }
}
