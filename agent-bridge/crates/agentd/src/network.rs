//! Authenticated ABP transport. No Agent business protocol parsing occurs here.
use crate::{types::BridgeError, Daemon, Result};
use abp_protocol::{self as wire, Frame, Hello, IoFrame, ProtocolError, RpcRequest, RpcResponse};
use iroh::{
    endpoint::{presets, Connection, RecvStream, SendStream},
    Endpoint, RelayMode, SecretKey,
};
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::AsyncReadExt,
    sync::{broadcast, Semaphore},
    task::{JoinHandle, JoinSet},
};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(8);
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 32;
const MAX_STREAMS: usize = 8;

pub struct NetworkServer {
    endpoint: Endpoint,
    task: Option<JoinHandle<()>>,
    daemon: Arc<Daemon>,
}
impl NetworkServer {
    pub async fn start(daemon: Arc<Daemon>, secret: [u8; 32], relay_enabled: bool) -> Result<Self> {
        daemon.set_network("starting", None, None);
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(SecretKey::from_bytes(&secret))
            .alpns(vec![wire::ALPN.to_vec()]);
        if !relay_enabled {
            builder = builder.relay_mode(RelayMode::Disabled);
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|_| error("network_error", "Could not bind the encrypted endpoint."))?;
        daemon.set_network(
            "ready",
            Some(endpoint.id().to_string()),
            Some("Encrypted endpoint ready; path is determined per connection.".into()),
        );
        let listener = endpoint.clone();
        let service = daemon.clone();
        let task = tokio::spawn(async move {
            let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
            let counts = Arc::new(Mutex::new(HashMap::<String, usize>::new()));
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    incoming = listener.accept() => {
                        let Some(incoming) = incoming else { break; };
                        let Ok(permit) = permits.clone().try_acquire_owned() else { incoming.refuse(); continue; };
                        let daemon = service.clone();
                        let counts = counts.clone();
                        connections.spawn(async move {
                            let _permit = permit;
                            if let Ok(Ok(connection)) = tokio::time::timeout(HANDSHAKE_TIMEOUT, incoming).await {
                                serve_connection(daemon, connection, counts).await;
                            }
                        });
                    }
                    _ = connections.join_next(), if !connections.is_empty() => {}
                }
            }
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        });
        Ok(Self {
            endpoint,
            task: Some(task),
            daemon,
        })
    }
    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }
    pub async fn shutdown(mut self) {
        self.endpoint.close().await;
        if let Some(task) = self.task.take() {
            task.abort();
            let _ = task.await;
        }
        self.daemon.set_network("stopped", None, None);
    }
}

impl Drop for NetworkServer {
    fn drop(&mut self) {
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}

struct ConnectionGuard {
    daemon: Arc<Daemon>,
    connection: Connection,
    counts: Arc<Mutex<HashMap<String, usize>>>,
    peer: String,
    registered: bool,
}
impl ConnectionGuard {
    fn register(&mut self) {
        if !self.registered && self.daemon.authorize(&self.peer, &[]).is_ok() {
            let mut counts = self.counts.lock().unwrap_or_else(|e| e.into_inner());
            *counts.entry(self.peer.clone()).or_default() += 1;
            self.registered = true;
            let _ = self.daemon.set_device_connected(&self.peer, true);
        }
    }
}
impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.connection.close(0u32.into(), b"connection ended");
        if self.registered {
            let mut counts = self.counts.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(count) = counts.get_mut(&self.peer) {
                *count = count.saturating_sub(1);
                if *count == 0 {
                    counts.remove(&self.peer);
                    let _ = self.daemon.set_device_connected(&self.peer, false);
                }
            }
        }
    }
}

async fn serve_connection(
    daemon: Arc<Daemon>,
    connection: Connection,
    counts: Arc<Mutex<HashMap<String, usize>>>,
) {
    let peer = connection.remote_id().to_string();
    let mut guard = ConnectionGuard {
        daemon: daemon.clone(),
        connection: connection.clone(),
        counts,
        peer: peer.clone(),
        registered: false,
    };
    guard.register();
    let mut events = daemon.subscribe();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let streams = Arc::new(Semaphore::new(MAX_STREAMS));
    let limiter = Arc::new(Mutex::new(RateLimit::new()));
    let mut tasks = JoinSet::new();
    let accepted_at = Instant::now();
    loop {
        tokio::select! {
            result = connection.accept_bi() => {
                let Ok((send, recv)) = result else { break; };
                let Ok(permit) = streams.clone().try_acquire_owned() else { connection.close(1u32.into(), b"stream limit"); break; };
                if !limiter.lock().unwrap_or_else(|e| e.into_inner()).take() { connection.close(1u32.into(), b"request limit"); break; }
                let daemon = daemon.clone(); let peer = peer.clone(); let limiter = limiter.clone();
                tasks.spawn(async move { let _permit = permit; serve_stream(daemon, peer, send, recv, limiter).await; });
            }
            event = events.recv() => {
                match event {
                    // Revocation invalidates this connection even when the same
                    // identity receives a fresh grant before we process the event.
                    Ok(event) if event.kind == "device-revoked"
                        && event.payload.get("device_id").and_then(serde_json::Value::as_str)
                            == Some(peer.as_str()) => break,
                    // A missed event may have revoked an earlier grant. Require a
                    // fresh connection instead of trusting a possibly newer grant.
                    Err(broadcast::error::RecvError::Lagged(_) | broadcast::error::RecvError::Closed) => break,
                    _ => {}
                }
                if guard.registered && daemon.authorize(&peer, &[]).is_err() { break; }
                guard.register();
            }
            _ = tick.tick() => {
                if guard.registered && daemon.authorize(&peer, &[]).is_err() { break; }
                guard.register();
                if !guard.registered && accepted_at.elapsed() > Duration::from_secs(130) { break; }
            }
            _ = connection.closed() => break,
            _ = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
}

struct RateLimit {
    started: Instant,
    count: u32,
}
impl RateLimit {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            count: 0,
        }
    }
    fn take(&mut self) -> bool {
        if self.started.elapsed() >= Duration::from_secs(60) {
            self.started = Instant::now();
            self.count = 0;
        }
        self.count += 1;
        self.count <= 120
    }
}
fn error(code: &str, message: &str) -> BridgeError {
    BridgeError {
        code: code.into(),
        message: message.into(),
    }
}
async fn read(recv: &mut RecvStream, max: usize, timeout: Duration) -> Result<Frame> {
    tokio::time::timeout(timeout, wire::read_frame(recv, max))
        .await
        .map_err(|_| error("timeout", "Stream timed out."))?
        .map_err(|_| error("protocol_error", "Malformed or incomplete frame."))
}
// A quiet AgentIO stdin is normal while an Agent works. Start the framing
// deadline only once a byte arrives; the connection owns idle liveness.
async fn read_io(recv: &mut RecvStream, max: usize) -> Result<Frame> {
    let first = recv
        .read_u8()
        .await
        .map_err(|_| error("network_error", "Input stream closed."))?;
    let prefix = [first];
    let mut reader = prefix.as_slice().chain(recv);
    tokio::time::timeout(IDLE_TIMEOUT, wire::read_frame(&mut reader, max))
        .await
        .map_err(|_| error("timeout", "Incomplete input frame timed out."))?
        .map_err(|_| error("protocol_error", "Malformed or incomplete input frame."))
}

async fn write(send: &mut SendStream, frame: Frame, max: usize) -> Result<()> {
    tokio::time::timeout(WRITE_TIMEOUT, wire::write_frame(send, &frame, max))
        .await
        .map_err(|_| error("timeout", "Peer is not receiving data."))?
        .map_err(|_| error("network_error", "Could not send frame."))
}
async fn serve_stream(
    daemon: Arc<Daemon>,
    peer: String,
    mut send: SendStream,
    recv: RecvStream,
    limiter: Arc<Mutex<RateLimit>>,
) {
    let result = stream_inner(&daemon, &peer, &mut send, recv, limiter).await;
    if let Err(err) = result {
        let _ = write(
            &mut send,
            Frame::Error(ProtocolError {
                code: err.code,
                message: err.message,
            }),
            wire::MAX_FRAME_BYTES,
        )
        .await;
    }
    let _ = send.finish();
}
async fn stream_inner(
    daemon: &Arc<Daemon>,
    peer: &str,
    send: &mut SendStream,
    mut recv: RecvStream,
    limiter: Arc<Mutex<RateLimit>>,
) -> Result<()> {
    let Frame::Hello(hello) = read(&mut recv, wire::MAX_FRAME_BYTES, HANDSHAKE_TIMEOUT).await?
    else {
        return Err(error("protocol_error", "Hello must be first."));
    };
    let max = hello
        .negotiate()
        .map_err(|_| error("incompatible", "Unsupported protocol version or limits."))?;
    let instance = daemon.service_instance().to_owned();
    write(
        send,
        Frame::Hello(Hello {
            max_frame_bytes: max as u32,
            ..Hello::new(instance)
        }),
        max,
    )
    .await?;
    let Frame::Open(open) = read(&mut recv, max, HANDSHAKE_TIMEOUT).await? else {
        return Err(error("protocol_error", "StreamOpen required."));
    };
    if open.process_id.len() > 256 || open.generation.len() > 256 {
        return Err(error("invalid_params", "Process identity exceeds limits."));
    }
    match open.kind {
        wire::STREAM_PAIR => {
            write(send, success("", "null"), max).await?;
            pair(daemon, peer, send, &mut recv, max).await
        }
        wire::STREAM_CONTROL => {
            daemon.authorize(peer, &[])?;
            write(send, success("", "null"), max).await?;
            loop {
                let Frame::Request(request) = read(&mut recv, max, IDLE_TIMEOUT).await? else {
                    return Err(error("protocol_error", "RPC request required."));
                };
                if request.rpc_id.is_empty()
                    || request.rpc_id.len() > 128
                    || request.method.len() > 64
                    || !limiter.lock().unwrap_or_else(|e| e.into_inner()).take()
                {
                    return Err(error(
                        "resource_limit",
                        "Invalid RPC identifier or request limit exceeded.",
                    ));
                }
                daemon.authorize(peer, &[])?;
                let id = request.rpc_id.clone();
                // A timeout drops the caller wait, not an external effect. The core reserves
                // operation IDs durably and records crash/cancellation ambiguity.
                let deadline =
                    Duration::from_millis(u64::from(request.timeout_ms.clamp(100, 30_000)));
                let outcome = tokio::time::timeout(deadline, rpc(daemon, peer, request))
                    .await
                    .unwrap_or_else(|_| {
                        Err(error(
                            "outcome_unknown",
                            "Deadline elapsed; query state before retrying a mutation.",
                        ))
                    });
                let response = match outcome {
                    Ok(body) => success(&id, &body),
                    Err(err) => Frame::Response(RpcResponse {
                        rpc_id: id,
                        error_code: err.code,
                        error_message: err.message,
                        body_json: String::new(),
                    }),
                };
                write(send, response, max).await?;
            }
        }
        wire::STREAM_AGENT_IO => {
            if open.cursor != 0 {
                return Err(error(
                    "unsupported",
                    "Only retained output is available; a replay cursor is not supported.",
                ));
            }
            let mut io = daemon
                .attach_io(peer, &open.process_id, &open.generation)
                .await?;
            write(send, success("", "null"), max).await?;
            // A dedicated reader owns framing across select! cancellations; dropping
            // read_exact midway would otherwise lose consumed prefix/payload bytes.
            let (input_tx, mut inputs) = tokio::sync::mpsc::channel(4);
            let reader = tokio::spawn(async move {
                loop {
                    let frame = read_io(&mut recv, max).await;
                    let failed = frame.is_err();
                    if input_tx.send(frame).await.is_err() || failed {
                        break;
                    }
                }
            });
            let _reader_guard = AbortTask(reader);
            let mut sequence = 0u64;
            let mut offsets = HashMap::<String, u64>::new();
            loop {
                tokio::select! {
                    incoming = inputs.recv() => {
                        let Frame::Io(input) = incoming.ok_or_else(|| error("network_error", "Input stream closed."))?? else { return Err(error("protocol_error", "I/O frame required.")); };
                        if input.channel != wire::CHANNEL_STDIN || input.data.len() > wire::MAX_IO_BYTES || input.data.is_empty() {
                            return Err(error("invalid_params", "Invalid stdin frame or size."));
                        }
                        daemon.authorize(peer, &["task", "approval"])?;
                        io.write(input.data).await?;
                    }
                    output = io.next() => {
                        let Some(output) = output? else {
                            let status = daemon.process_status(peer, &open.process_id, &open.generation).await?;
                            write(send, Frame::Io(IoFrame { channel: wire::CHANNEL_EXIT, exit_code: status.exit_code, ..Default::default() }), max).await?;
                            return Ok(());
                        };
                        daemon.authorize(peer, &["task", "approval"])?;
                        let offset = output.offset.parse::<u64>().map_err(|_| error("internal", "Invalid output offset."))?;
                        let previous = offsets.get(&output.channel).copied().unwrap_or(0);
                        if output.gap || offset != previous {
                            write(send, Frame::Io(IoFrame { channel: wire::CHANNEL_GAP, affected_channel: if offset == previous { 0 } else if output.channel == "stdout" { wire::CHANNEL_STDOUT } else { wire::CHANNEL_STDERR }, offset, lost_bytes: offset.saturating_sub(previous), cursor: sequence, ..Default::default() }), max).await?;
                        }
                        offsets.insert(output.channel.clone(), offset + output.data.len() as u64);
                        let channel = match output.channel.as_str() { "stdout" => wire::CHANNEL_STDOUT, "stderr" => wire::CHANNEL_STDERR, _ => return Err(error("internal", "Unknown output channel.")) };
                        // Reserve space for protobuf tags/varints and the frame type.
                        let chunk_size = (max - 128).min(wire::MAX_IO_BYTES);
                        for (index, chunk) in output.data.chunks(chunk_size).enumerate() {
                            sequence += 1;
                            write(send, Frame::Io(IoFrame { channel, data: chunk.to_vec(), cursor: sequence, offset: offset + (index * chunk_size) as u64, ..Default::default() }), max).await?;
                        }
                    }
                }
            }
        }
        _ => Err(error("unsupported", "Unsupported stream kind.")),
    }
}
fn success(id: &str, body: &str) -> Frame {
    Frame::Response(RpcResponse {
        rpc_id: id.into(),
        body_json: body.into(),
        ..Default::default()
    })
}
async fn pair(
    daemon: &Arc<Daemon>,
    peer: &str,
    send: &mut SendStream,
    recv: &mut RecvStream,
    max: usize,
) -> Result<()> {
    let Frame::Pair(request) = read(recv, max, HANDSHAKE_TIMEOUT).await? else {
        return Err(error("protocol_error", "Pair request required."));
    };
    if request.token.len() > 256 || request.name.len() > 128 || request.session_id.len() > 128 {
        return Err(error("invalid_params", "Pair request exceeds limits."));
    }
    let state = daemon.pairing_state().await;
    if state.session_id.as_deref() != Some(request.session_id.as_str()) {
        return Err(error("unauthorized", "Invitation is no longer active."));
    }
    let pending = daemon
        .submit_pair(&request.token, peer, &request.name)
        .await?;
    write(send, success("pair", &json(&pending)?), max).await?;
    let mut events = daemon.subscribe();
    let mut tick = tokio::time::interval(Duration::from_millis(200));
    let deadline = tokio::time::sleep(Duration::from_secs(125));
    tokio::pin!(deadline);
    loop {
        let current = daemon.pairing_state().await;
        if current.session_id != Some(request.session_id.clone()) {
            return Err(error("cancelled", "Pairing session ended."));
        }
        if let Some(ref item) = current.request {
            if item.request_id != pending.request_id {
                return Err(error("cancelled", "Pairing request replaced."));
            }
            match item.state.as_str() {
                "approved" => {
                    daemon.authorize(peer, &[])?;
                    write(send, success("pair", &json(item)?), max).await?;
                    return Ok(());
                }
                "pending" => {}
                _ => {
                    return Err(error(
                        "unauthorized",
                        "Pairing was rejected, cancelled or expired.",
                    ))
                }
            }
        }
        if matches!(current.state.as_str(), "expired" | "cancelled" | "rejected") {
            return Err(error(
                "unauthorized",
                "Pairing ended without authorization.",
            ));
        }
        tokio::select! {
            _ = &mut deadline => return Err(error("timeout", "Pairing timed out.")),
            _ = tick.tick() => {},
            event = events.recv() => { if matches!(event, Err(broadcast::error::RecvError::Closed)) { return Err(error("unavailable", "Service stopped.")); } }
        }
    }
}
fn json(value: &impl serde::Serialize) -> Result<String> {
    serde_json::to_string(value).map_err(|_| error("internal", "Could not encode response."))
}
fn body<T: serde::de::DeserializeOwned>(value: &str) -> Result<T> {
    serde_json::from_str(value).map_err(|_| error("invalid_params", "Invalid request parameters."))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StartBody {
    operation_id: String,
    agent_id: String,
    cwd: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProcessBody {
    process_id: String,
    generation: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct StopBody {
    operation_id: String,
    process_id: String,
    generation: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentProjectsBody {
    agent_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ThreadMessagesBody {
    agent_id: String,
    thread_id: String,
}
async fn rpc(daemon: &Daemon, peer: &str, request: RpcRequest) -> Result<String> {
    match request.method.as_str() {
        "Ping" => {
            daemon.authorize(peer, &["view"])?;
            Ok("null".into())
        }
        "GetSystemInfo" => {
            daemon.authorize(peer, &["view"])?;
            json(&daemon.get_status().await?)
        }
        "ListAgents" => {
            daemon.authorize(peer, &["view"])?;
            json(&daemon.list_agents(false).await?)
        }
        "ListAgentProjects" => {
            daemon.authorize(peer, &["view"])?;
            let args: AgentProjectsBody = body(&request.body_json)?;
            let base = dirs::home_dir().unwrap_or_default();
            json(&crate::agent_projects::list_agent_projects(
                &args.agent_id,
                &base,
            ))
        }
        "GetThreadMessages" => {
            daemon.authorize(peer, &["view"])?;
            let args: ThreadMessagesBody = body(&request.body_json)?;
            let base = dirs::home_dir().unwrap_or_default();
            json(&crate::agent_projects::list_thread_messages(
                &args.agent_id,
                &args.thread_id,
                &base,
            ))
        }
        "ListProcesses" => {
            daemon.authorize(peer, &["view"])?;
            let processes: Vec<_> = daemon
                .list_processes()
                .await
                .into_iter()
                .filter(|p| p.owner_device_id == peer)
                .collect();
            json(&processes)
        }
        "StartProcess" => {
            let args: StartBody = body(&request.body_json)?;
            json(
                &daemon
                    .start_process(peer, &args.operation_id, &args.agent_id, &args.cwd)
                    .await?,
            )
        }
        "StopProcess" => {
            let args: StopBody = body(&request.body_json)?;
            json(
                &daemon
                    .stop_process(peer, &args.operation_id, &args.process_id, &args.generation)
                    .await?,
            )
        }
        "GetProcessStatus" => {
            let args: ProcessBody = body(&request.body_json)?;
            json(
                &daemon
                    .process_status(peer, &args.process_id, &args.generation)
                    .await?,
            )
        }
        _ => Err(error("unsupported", "Unknown method.")),
    }
}

struct AbortTask(JoinHandle<()>);
impl Drop for AbortTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}
