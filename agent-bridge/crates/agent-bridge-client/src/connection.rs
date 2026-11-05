//! Persistent iroh connection to the paired Mac: Control RPC and raw AgentIO
//! streaming, built on the same handshake `pair_over_iroh` already uses.
//! Each Control RPC opens its own bidirectional stream (one request/response),
//! matching the server loop in `agentd::network` and the `abp-test-harness`
//! reference client. AgentIO opens one long-lived stream for a process's
//! lifetime and pushes frames to Swift through a callback interface.
use crate::{endpoint::SharedEndpoint, read_frame, write_frame, CONNECT_TIMEOUT, HELLO_TIMEOUT};
use abp_protocol::{Frame, Hello, IoFrame, RpcRequest, StreamOpen};
use iroh::{
    endpoint::{Connection, RecvStream, SendStream},
    EndpointId,
};
use std::{
    str::FromStr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex as StdMutex,
    },
};
use tokio::{sync::Mutex as AsyncMutex, task::JoinHandle};

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum ConnectionState {
    Idle,
    Connecting,
    Connected,
    Disconnected,
    Failed { code: String, message: String },
}

#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{message}")]
    Failed { code: String, message: String },
}
impl BridgeError {
    pub(crate) fn new(code: &str, message: impl Into<String>) -> Self {
        Self::Failed {
            code: code.into(),
            message: message.into(),
        }
    }
    pub fn code(&self) -> String {
        match self {
            Self::Failed { code, .. } => code.clone(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub status: String,
    pub validation: String,
}

#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct ProcessInfo {
    pub process_id: String,
    pub generation: String,
    pub agent_id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub exit_code: Option<i32>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SystemInfo {
    pub running: bool,
    pub uptime_secs: u32,
    pub network_state: String,
    pub active_processes: u32,
    pub connected_devices: u32,
}

#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacThread {
    pub id: String,
    pub title: String,
    pub updated_at: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

/// One message in a conversation read back from the Mac's own session
/// records: `user` or `assistant`.
#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacMessage {
    pub role: String,
    pub text: String,
    pub timestamp: Option<String>,
    #[serde(default)]
    pub tool_call_id: Option<String>,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_phase: Option<String>,
    #[serde(default)]
    pub tool_failed: Option<bool>,
    #[serde(default)]
    pub assistant_phase: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacModel {
    pub id: String,
    pub name: String,
}

/// One subfolder of a folder on the Mac, for choosing a project path.
#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacDirectoryEntry {
    pub name: String,
    pub path: String,
    /// Contains `.git`; most likely a project root.
    pub is_project: bool,
}

/// A folder inside the Mac user's home directory and its visible subfolders.
#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacDirectoryListing {
    pub path: String,
    /// `None` at the home directory; browsing never goes above it.
    pub parent: Option<String>,
    pub entries: Vec<MacDirectoryEntry>,
    pub truncated: bool,
}

/// A project path the Mac's Agent already tracked itself, plus the newest
/// on-disk timestamp we could find for it (RFC3339), if any.
#[derive(uniffi::Record, Clone, Debug, serde::Deserialize)]
pub struct MacProject {
    pub path: String,
    pub last_seen: Option<String>,
    pub name: Option<String>,
    pub threads: Vec<MacThread>,
}
#[derive(serde::Deserialize)]
struct RawNetworkInfo {
    state: String,
}
#[derive(serde::Deserialize)]
struct RawDaemonStatus {
    running: bool,
    uptime_secs: u32,
    network: RawNetworkInfo,
    active_processes: u32,
    connected_devices: u32,
}

fn parse<T: serde::de::DeserializeOwned>(body: &str) -> Result<T, BridgeError> {
    serde_json::from_str(body)
        .map_err(|_| BridgeError::new("internal", "Could not parse the Mac's response."))
}

/// Pushed to Swift as AgentIO frames arrive. All methods must return quickly;
/// do real work on the Swift side asynchronously.
#[uniffi::export(callback_interface)]
pub trait AgentIoCallback: Send + Sync {
    fn on_stdout(&self, data: Vec<u8>, cursor: u64, offset: u64);
    fn on_stderr(&self, data: Vec<u8>, cursor: u64, offset: u64);
    fn on_gap(&self, affected_channel: i32, offset: u64, lost_bytes: u64);
    fn on_exit(&self, exit_code: Option<i32>);
    fn on_error(&self, code: String, message: String);
}

/// Handle to a live AgentIO stream for one process. Dropping it (Swift
/// `deinit`) aborts the background reader; call `close()` to do the same
/// explicitly and deterministically.
#[derive(uniffi::Object)]
pub struct IoHandle {
    send: AsyncMutex<SendStream>,
    reader: StdMutex<Option<JoinHandle<()>>>,
    lease_id: String,
    record_framed: bool,
    max_frame_bytes: usize,
}
#[uniffi::export(async_runtime = "tokio")]
impl IoHandle {
    pub fn lease_id(&self) -> String {
        self.lease_id.clone()
    }
    pub async fn write_stdin(&self, data: Vec<u8>) -> Result<(), BridgeError> {
        if data.is_empty() {
            return Ok(());
        }
        let mut send = self.send.lock().await;
        if self.record_framed && data.len() > 2 * 1024 * 1024 {
            return Err(BridgeError::new(
                "resource_limit",
                "Agent input record exceeds 2 MiB.",
            ));
        }
        let result = tokio::time::timeout(std::time::Duration::from_secs(30), async {
            for chunk in data.chunks((self.max_frame_bytes - 128).min(abp_protocol::MAX_IO_BYTES)) {
                let frame = Frame::Io(IoFrame {
                    channel: abp_protocol::CHANNEL_STDIN,
                    data: chunk.to_vec(),
                    ..Default::default()
                });
                write_frame(&mut send, &frame, self.max_frame_bytes)
                    .await
                    .map_err(|e| BridgeError::new("network_error", e))?;
            }
            Ok(())
        })
        .await;
        match result {
            Ok(result) => result,
            Err(_) => {
                let _ = send.reset(0u32.into());
                Err(BridgeError::new(
                    "network_error",
                    "Agent input write timed out; delivery is unknown.",
                ))
            }
        }
    }
    pub fn close(&self) {
        if let Some(handle) = self.reader.lock().unwrap_or_else(|e| e.into_inner()).take() {
            handle.abort();
        }
        // Best-effort: a dropped SendStream resets instead of cleanly
        // finishing (see the loopback test comment on this same behavior).
        // `try_lock` keeps `close()` synchronous for UniFFI/Swift `deinit`;
        // skip quietly if a concurrent `write_stdin` currently holds it.
        if let Ok(mut send) = self.send.try_lock() {
            let _ = send.finish();
        }
    }
}
impl Drop for IoHandle {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.reader.lock() {
            if let Some(handle) = guard.take() {
                handle.abort();
            }
        }
        if let Ok(mut send) = self.send.try_lock() {
            let _ = send.finish();
        }
    }
}

/// A persistent handle to one Mac. Binds its iroh `Endpoint` once (reusing
/// the phone's paired identity) and keeps a `Connection` alive across
/// Control RPCs and AgentIO streams; `reconnect()` only replaces the
/// `Connection`, never the bound identity.
#[derive(uniffi::Object)]
pub struct BridgeConnection {
    endpoint: Arc<SharedEndpoint>,
    operation: AsyncMutex<()>,
    generation: AtomicU64,
    endpoint_id: String,
    connection: AsyncMutex<Option<Connection>>,
    state: StdMutex<ConnectionState>,
    next_rpc: AtomicU64,
    network: bridge_network::PeerNetwork,
    relay_lease: AsyncMutex<Option<crate::endpoint::RelayLease>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl BridgeConnection {
    #[uniffi::constructor]
    pub fn new(key_path: String, endpoint_id: String) -> Arc<Self> {
        Arc::new(Self {
            endpoint: SharedEndpoint::for_key(&key_path),
            operation: AsyncMutex::new(()),
            generation: AtomicU64::new(0),
            endpoint_id,
            connection: AsyncMutex::new(None),
            state: StdMutex::new(ConnectionState::Idle),
            next_rpc: AtomicU64::new(0),
            network: Default::default(),
            relay_lease: AsyncMutex::new(None),
        })
    }

    #[uniffi::constructor]
    pub fn with_network(
        key_path: String,
        endpoint_id: String,
        network: crate::PeerNetworkConfig,
    ) -> Result<Arc<Self>, BridgeError> {
        let network = network.validated()?;
        network
            .peer_addr(&endpoint_id)
            .map_err(|_| BridgeError::new("invalid_params", "Invalid Mac endpoint id."))?;
        Ok(Arc::new(Self {
            endpoint: SharedEndpoint::for_key(&key_path),
            operation: AsyncMutex::new(()),
            generation: AtomicU64::new(0),
            endpoint_id,
            connection: AsyncMutex::new(None),
            state: StdMutex::new(ConnectionState::Idle),
            next_rpc: AtomicU64::new(0),
            network,
            relay_lease: AsyncMutex::new(None),
        }))
    }

    pub async fn path_kind(&self) -> String {
        self.connection
            .lock()
            .await
            .as_ref()
            .map(bridge_network::selected_path)
            .unwrap_or("unknown")
            .to_owned()
    }

    pub fn state(&self) -> ConnectionState {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Connects if idle/disconnected; a no-op (besides re-reporting state)
    /// when already connected. Use `reconnect()` to force a fresh attempt.
    pub async fn connect(&self) -> ConnectionState {
        self.connect_inner(false).await
    }

    /// Drops the current `Connection` (if any) and dials again on the same
    /// bound `Endpoint`/identity.
    pub async fn reconnect(&self) -> ConnectionState {
        self.connect_inner(true).await
    }

    pub async fn disconnect(&self) {
        // Invalidate a dial before waiting for its operation lock, so a late
        // success cannot resurrect a connection the user has removed.
        self.generation.fetch_add(1, Ordering::SeqCst);
        let _operation = self.operation.lock().await;
        if let Some(connection) = self.connection.lock().await.take() {
            connection.close(0u32.into(), b"client closed");
        }
        if let Some(lease) = self.relay_lease.lock().await.take() {
            lease.release().await;
        }
        self.set_state(ConnectionState::Disconnected);
    }

    pub async fn ping(&self) -> Result<(), BridgeError> {
        self.call("Ping", "null".into(), 5_000).await.map(|_| ())
    }
    pub async fn get_system_info(&self) -> Result<SystemInfo, BridgeError> {
        let raw: RawDaemonStatus = parse(&self.call("GetSystemInfo", "null".into(), 5_000).await?)?;
        Ok(SystemInfo {
            running: raw.running,
            uptime_secs: raw.uptime_secs,
            network_state: raw.network.state,
            active_processes: raw.active_processes,
            connected_devices: raw.connected_devices,
        })
    }
    pub async fn list_agents(&self) -> Result<Vec<AgentInfo>, BridgeError> {
        parse(&self.call("ListAgents", "null".into(), 5_000).await?)
    }
    /// Real, on-disk project paths the Agent itself already tracked on the
    /// Mac (Codex's `~/.codex/config.toml`, Claude Code's
    /// `~/.claude/projects/`) — not anything this phone invented. Empty is
    /// the normal "never ran here" case, not a failure.
    pub async fn list_agent_projects(
        &self,
        agent_id: String,
    ) -> Result<Vec<MacProject>, BridgeError> {
        let body = serde_json::json!({"agent_id": agent_id}).to_string();
        parse(&self.call("ListAgentProjects", body, 5_000).await?)
    }
    /// Subfolders of `path` (absolute, `~` or `~/…`; `None` = home) on the Mac.
    /// The Mac refuses anything outside the home directory with `forbidden`;
    /// a Mac without this request answers `unsupported`.
    pub async fn list_directory(&self, path: Option<String>) -> Result<MacDirectoryListing, BridgeError> {
        let body = serde_json::json!({"path": path}).to_string();
        parse(&self.call("ListDirectory", body, 5_000).await?)
    }
    pub async fn list_agent_models(&self, agent_id: String) -> Result<Vec<MacModel>, BridgeError> {
        let body = serde_json::json!({"agent_id": agent_id}).to_string();
        parse(&self.call("ListAgentModels", body, 15_000).await?)
    }

    /// The user/assistant turns of one conversation, read from the Agent's
    /// own session records on the Mac. Tool calls, reasoning, and system
    /// prompts are filtered out server-side.
    pub async fn get_thread_messages(
        &self,
        agent_id: String,
        thread_id: String,
    ) -> Result<Vec<MacMessage>, BridgeError> {
        let body = serde_json::json!({"agent_id": agent_id, "thread_id": thread_id}).to_string();
        parse(&self.call("GetThreadMessages", body, 10_000).await?)
    }
    pub async fn list_processes(&self) -> Result<Vec<ProcessInfo>, BridgeError> {
        parse(&self.call("ListProcesses", "null".into(), 5_000).await?)
    }
    pub async fn start_process(
        &self,
        operation_id: String,
        agent_id: String,
        cwd: String,
    ) -> Result<ProcessInfo, BridgeError> {
        let body =
            serde_json::json!({"operation_id": operation_id, "agent_id": agent_id, "cwd": cwd})
                .to_string();
        parse(&self.call("StartProcess", body, 15_000).await?)
    }
    pub async fn stop_process(
        &self,
        operation_id: String,
        process_id: String,
        generation: String,
    ) -> Result<ProcessInfo, BridgeError> {
        let body = serde_json::json!({
            "operation_id": operation_id, "process_id": process_id, "generation": generation
        })
        .to_string();
        parse(&self.call("StopProcess", body, 15_000).await?)
    }
    pub async fn get_process_status(
        &self,
        process_id: String,
        generation: String,
    ) -> Result<ProcessInfo, BridgeError> {
        let body =
            serde_json::json!({"process_id": process_id, "generation": generation}).to_string();
        parse(&self.call("GetProcessStatus", body, 5_000).await?)
    }

    /// Opens a dedicated `STREAM_AGENT_IO` stream for a process the Mac
    /// already knows about and pushes every frame to `callback` until the
    /// process exits, the stream errors, or `IoHandle::close()` is called.
    pub async fn attach_io(
        &self,
        process_id: String,
        generation: String,
        callback: Box<dyn AgentIoCallback>,
    ) -> Result<Arc<IoHandle>, BridgeError> {
        let connection = self.live_connection().await?;
        let my_id = self.local_id().await;
        let (send, recv, max) = open_stream(
            &connection,
            &my_id,
            abp_protocol::STREAM_AGENT_IO,
            &process_id,
            &generation,
        )
        .await?;
        Ok(io_handle(send, recv, max, callback, String::new(), false))
    }
    /// Opens an atomic NDJSON input stream with proven reconnect capabilities.
    pub async fn attach_chat_io(
        &self,
        process_id: String,
        generation: String,
        callback: Box<dyn AgentIoCallback>,
    ) -> Result<Arc<IoHandle>, BridgeError> {
        self.chat_io(process_id, generation, None, callback).await
    }
    pub async fn resume_chat_io(
        &self,
        process_id: String,
        generation: String,
        stdout_offset: u64,
        stderr_offset: u64,
        previous_lease_id: String,
        callback: Box<dyn AgentIoCallback>,
    ) -> Result<Arc<IoHandle>, BridgeError> {
        if previous_lease_id.is_empty() || previous_lease_id.len() > 128 {
            return Err(BridgeError::new(
                "invalid_params",
                "A prior input lease is required.",
            ));
        }
        self.chat_io(
            process_id,
            generation,
            Some(abp_protocol::IoResume {
                stdout_offset,
                stderr_offset,
                previous_lease_id,
            }),
            callback,
        )
        .await
    }
}

// Private helpers. Kept out of the `#[uniffi::export]` block above: that
// macro tries to turn every method's signature into FFI scaffolding, and
// plain internal types/`impl Trait` (e.g. `Connection`, `impl Into<String>`)
// are not UniFFI-representable.
impl BridgeConnection {
    async fn chat_io(
        &self,
        process_id: String,
        generation: String,
        resume: Option<abp_protocol::IoResume>,
        callback: Box<dyn AgentIoCallback>,
    ) -> Result<Arc<IoHandle>, BridgeError> {
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let capabilities = self
                .call("GetCapabilities", "null".into(), 10_000)
                .await
                .map_err(|error| {
                    if error.code() == "unsupported" {
                        BridgeError::new(
                            "unsupported",
                            "Update the Mac client to support chat recovery and images.",
                        )
                    } else {
                        error
                    }
                })?;
            let supported: Vec<String> = serde_json::from_str(&capabilities).map_err(|_| {
                BridgeError::new("incompatible", "Invalid Mac capability response.")
            })?;
            if [
                "io_resume_offsets_v1",
                "io_lease_replace_v1",
                "io_ndjson_records_v1",
            ]
            .iter()
            .any(|required| !supported.iter().any(|value| value == required))
            {
                return Err(BridgeError::new(
                    "unsupported",
                    "Update the Mac client to support chat recovery and images.",
                ));
            }
            let connection = self.live_connection().await?;
            let my_id = self.local_id().await;
            let (send, recv, max, response) = open_stream_options(
                &connection,
                &my_id,
                StreamOpen {
                    kind: abp_protocol::STREAM_AGENT_IO,
                    process_id,
                    generation,
                    resume,
                    record_framed: true,
                    ..Default::default()
                },
                None,
            )
            .await?;
            let body: serde_json::Value = serde_json::from_str(&response).map_err(|_| {
                BridgeError::new("incompatible", "Mac did not return an input lease.")
            })?;
            let lease_id = body["lease_id"]
                .as_str()
                .filter(|value| !value.is_empty() && value.len() <= 128)
                .ok_or_else(|| {
                    BridgeError::new("incompatible", "Mac did not return an input lease.")
                })?
                .to_owned();
            Ok(io_handle(send, recv, max, callback, lease_id, true))
        })
        .await
        .map_err(|_| BridgeError::new("timeout", "Opening the Mac chat stream timed out."))?
    }
    async fn connect_inner(&self, force: bool) -> ConnectionState {
        self.connect_with_timeout(force, CONNECT_TIMEOUT).await
    }

    async fn connect_with_timeout(
        &self,
        force: bool,
        timeout: std::time::Duration,
    ) -> ConnectionState {
        let generation = self.generation.load(Ordering::SeqCst);
        let _operation = self.operation.lock().await;
        if generation != self.generation.load(Ordering::SeqCst) {
            return ConnectionState::Disconnected;
        }
        if !force
            && self
                .connection
                .lock()
                .await
                .as_ref()
                .is_some_and(|c| c.close_reason().is_none())
        {
            return self.state();
        }
        self.set_state(ConnectionState::Connecting);
        if let Some(old) = self.connection.lock().await.take() {
            old.close(0u32.into(), b"reconnecting");
        }
        // Include endpoint initialization and relay registration in the budget,
        // not just the final QUIC handshake.
        let result = tokio::time::timeout(timeout, self.dial())
            .await
            .unwrap_or_else(|_| Err(("timeout", "Connecting to the Mac timed out.".into())));
        if generation != self.generation.load(Ordering::SeqCst) {
            if let Ok(connection) = result {
                connection.close(0u32.into(), b"dial cancelled");
            }
            self.set_state(ConnectionState::Disconnected);
            return ConnectionState::Disconnected;
        }
        match result {
            Ok(connection) => {
                *self.connection.lock().await = Some(connection);
                self.set_state(ConnectionState::Connected);
                ConnectionState::Connected
            }
            Err((code, message)) => self.fail(code, message),
        }
    }

    async fn dial(&self) -> Result<Connection, (&'static str, String)> {
        let node = EndpointId::from_str(&self.endpoint_id)
            .map_err(|_| ("invalid_params", "Invalid Mac endpoint id.".into()))?;
        let endpoint = self.endpoint.get().await?;
        let mut lease = self.relay_lease.lock().await;
        if lease.is_none() {
            *lease = self.endpoint.register_relay(&self.network).await?;
        }
        drop(lease);
        let addr = self
            .network
            .peer_addr(&node.to_string())
            .map_err(|_| ("invalid_network", "Invalid peer address hints.".into()))?;
        endpoint
            .connect(addr, abp_protocol::ALPN)
            .await
            .map_err(|_| {
                (
                    "unreachable",
                    "Could not reach the Mac. Check both networks.".into(),
                )
            })
    }

    async fn live_connection(&self) -> Result<Connection, BridgeError> {
        self.connection
            .lock()
            .await
            .clone()
            .ok_or_else(|| BridgeError::new("disconnected", "Not connected to the Mac."))
    }
    async fn local_id(&self) -> String {
        self.endpoint
            .get()
            .await
            .map(|e| e.id().to_string())
            .unwrap_or_default()
    }

    async fn call(
        &self,
        method: &str,
        body_json: String,
        timeout_ms: u32,
    ) -> Result<String, BridgeError> {
        let connection = self.live_connection().await?;
        let my_id = self.local_id().await;
        let rpc_id = format!("rpc-{}", self.next_rpc.fetch_add(1, Ordering::SeqCst));
        let request = Frame::Request(RpcRequest {
            rpc_id,
            method: method.into(),
            body_json,
            timeout_ms,
        });
        // This read-only catalog request is safe to buffer before negotiation:
        // it fits every accepted ABP v1 frame limit. Mutations still wait for ACK.
        let early_request = (method == "ListAgentProjects"
            && request.encode(MIN_PEER_FRAME_BYTES).is_ok())
        .then_some(&request);
        let (mut send, mut recv, max, _) = open_stream_options(
            &connection,
            &my_id,
            StreamOpen {
                kind: abp_protocol::STREAM_CONTROL,
                ..Default::default()
            },
            early_request,
        )
        .await?;
        if early_request.is_none() {
            write_frame(&mut send, &request, max)
                .await
                .map_err(|e| BridgeError::new("network_error", e))?;
        }
        let deadline = std::time::Duration::from_millis(u64::from(timeout_ms) + 5_000);
        let outcome = match tokio::time::timeout(deadline, read_frame(&mut recv, max)).await {
            Ok(Ok(Frame::Response(r))) if r.error_code.is_empty() => Ok(r.body_json),
            Ok(Ok(Frame::Response(r))) => Err(BridgeError::new(&r.error_code, r.error_message)),
            Ok(Ok(Frame::Error(e))) => Err(BridgeError::new(&e.code, e.message)),
            Ok(Ok(_)) => Err(BridgeError::new(
                "protocol_error",
                "Unexpected reply from the Mac.",
            )),
            Ok(Err(message)) => Err(BridgeError::new("protocol_error", message)),
            Err(_) => Err(BridgeError::new(
                "timeout",
                "The Mac did not respond in time.",
            )),
        };
        let _ = send.finish();
        outcome
    }

    fn set_state(&self, state: ConnectionState) {
        *self.state.lock().unwrap_or_else(|e| e.into_inner()) = state;
    }
    fn fail(&self, code: &str, message: impl Into<String>) -> ConnectionState {
        let state = ConnectionState::Failed {
            code: code.into(),
            message: message.into(),
        };
        self.set_state(state.clone());
        state
    }
}

fn io_handle(
    send: SendStream,
    mut recv: RecvStream,
    max: usize,
    callback: Box<dyn AgentIoCallback>,
    lease_id: String,
    record_framed: bool,
) -> Arc<IoHandle> {
    let callback: Arc<dyn AgentIoCallback> = Arc::from(callback);
    let reader = tokio::spawn(async move {
        loop {
            match read_frame(&mut recv, max).await {
                Ok(Frame::Io(io)) => match io.channel {
                    c if c == abp_protocol::CHANNEL_STDOUT => {
                        callback.on_stdout(io.data, io.cursor, io.offset)
                    }
                    c if c == abp_protocol::CHANNEL_STDERR => {
                        callback.on_stderr(io.data, io.cursor, io.offset)
                    }
                    c if c == abp_protocol::CHANNEL_GAP => {
                        callback.on_gap(io.affected_channel, io.offset, io.lost_bytes)
                    }
                    c if c == abp_protocol::CHANNEL_EXIT => {
                        callback.on_exit(io.exit_code);
                        break;
                    }
                    _ => {}
                },
                Ok(Frame::Error(e)) => {
                    callback.on_error(e.code, e.message);
                    break;
                }
                Ok(_) => {
                    callback.on_error(
                        "protocol_error".into(),
                        "Unexpected frame on the AgentIO stream.".into(),
                    );
                    break;
                }
                Err(message) => {
                    callback.on_error("network_error".into(), message);
                    break;
                }
            }
        }
    });
    Arc::new(IoHandle {
        send: AsyncMutex::new(send),
        reader: StdMutex::new(Some(reader)),
        lease_id,
        record_framed,
        max_frame_bytes: max,
    })
}

/// Shared stream-open sequence. Small CONTROL opens may be pipelined with Hello;
/// every caller still validates the negotiated Hello and the Mac's Open ACK.
async fn open_stream(
    connection: &Connection,
    my_id: &str,
    kind: i32,
    process_id: &str,
    generation: &str,
) -> Result<(SendStream, RecvStream, usize), BridgeError> {
    let (send, recv, max, _) = open_stream_options(
        connection,
        my_id,
        StreamOpen {
            kind,
            process_id: process_id.into(),
            generation: generation.into(),
            ..Default::default()
        },
        None,
    )
    .await?;
    Ok((send, recv, max))
}
// Hello::negotiate rejects peers advertising less than 1024 bytes in ABP v1.
const MIN_PEER_FRAME_BYTES: usize = 1024;

async fn open_stream_options(
    connection: &Connection,
    my_id: &str,
    open: StreamOpen,
    early_request: Option<&Frame>,
) -> Result<(SendStream, RecvStream, usize, String), BridgeError> {
    let (mut send, mut recv) = connection
        .open_bi()
        .await
        .map_err(|_| BridgeError::new("network_error", "Could not open a stream."))?;
    let hello = Frame::Hello(Hello::new(my_id.to_string()));
    write_frame(&mut send, &hello, abp_protocol::MAX_FRAME_BYTES)
        .await
        .map_err(|e| BridgeError::new("network_error", e))?;
    let pipelined_open = open.kind == abp_protocol::STREAM_CONTROL
        && Frame::Open(open.clone())
            .encode(MIN_PEER_FRAME_BYTES)
            .is_ok();
    let open = Frame::Open(open);
    if pipelined_open {
        write_frame(&mut send, &open, MIN_PEER_FRAME_BYTES)
            .await
            .map_err(|e| BridgeError::new("network_error", e))?;
        if let Some(request) = early_request {
            write_frame(&mut send, request, MIN_PEER_FRAME_BYTES)
                .await
                .map_err(|e| BridgeError::new("network_error", e))?;
        }
    }
    let peer_hello = match tokio::time::timeout(
        HELLO_TIMEOUT,
        read_frame(&mut recv, abp_protocol::MAX_FRAME_BYTES),
    )
    .await
    {
        Ok(Ok(Frame::Hello(hello))) => hello,
        Ok(Ok(_)) => {
            return Err(BridgeError::new(
                "protocol_error",
                "The Mac did not answer with Hello.",
            ))
        }
        Ok(Err(message)) => return Err(BridgeError::new("protocol_error", message)),
        Err(_) => {
            return Err(BridgeError::new(
                "timeout",
                "The handshake with the Mac timed out.",
            ))
        }
    };
    let max = peer_hello.negotiate().map_err(|_| {
        BridgeError::new("incompatible", "The Mac speaks an incompatible protocol.")
    })?;
    if !pipelined_open {
        write_frame(&mut send, &open, max)
            .await
            .map_err(|e| BridgeError::new("network_error", e))?;
    }
    let response = match tokio::time::timeout(HELLO_TIMEOUT, read_frame(&mut recv, max)).await {
        Ok(Ok(Frame::Response(r))) if r.error_code.is_empty() => r.body_json,
        Ok(Ok(Frame::Response(r))) => return Err(BridgeError::new(&r.error_code, r.error_message)),
        Ok(Ok(Frame::Error(e))) => return Err(BridgeError::new(&e.code, e.message)),
        Ok(Ok(_)) => {
            return Err(BridgeError::new(
                "protocol_error",
                "Unexpected reply while opening the stream.",
            ))
        }
        Ok(Err(message)) => return Err(BridgeError::new("protocol_error", message)),
        Err(_) => {
            return Err(BridgeError::new(
                "timeout",
                "The Mac did not acknowledge the stream.",
            ))
        }
    };
    Ok((send, recv, max, response))
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn connect_deadline_includes_pre_dial_setup_and_publishes_failure() {
        let directory = tempfile::tempdir().unwrap();
        let peer = iroh::SecretKey::generate().public().to_string();
        let client = BridgeConnection::new(
            directory
                .path()
                .join("phone.key")
                .to_string_lossy()
                .into_owned(),
            peer,
        );
        // Hold a setup resource before the QUIC dial can start. The old timeout
        // around endpoint.connect alone could never stop this connection.
        let setup = client.relay_lease.lock().await;
        let state = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            client.connect_with_timeout(false, std::time::Duration::from_millis(40)),
        )
        .await
        .expect("setup must obey the connection deadline");
        assert!(matches!(state, ConnectionState::Failed { ref code, .. } if code == "timeout"));
        assert_eq!(client.state(), state);
        drop(setup);
    }

    #[test]
    fn historical_tool_metadata_is_optional_for_older_hosts() {
        let old: MacMessage =
            serde_json::from_str(r#"{"role":"tool","text":"legacy output","timestamp":null}"#)
                .unwrap();
        assert!(old.tool_call_id.is_none());
        assert!(old.tool_phase.is_none());
        assert!(old.tool_failed.is_none());
        assert!(old.assistant_phase.is_none());
        let phased: MacMessage = serde_json::from_str(r#"{"role":"assistant","text":"progress","timestamp":null,"assistant_phase":"commentary"}"#).unwrap();
        assert_eq!(phased.assistant_phase.as_deref(), Some("commentary"));
        let current: MacMessage = serde_json::from_str(r#"{"role":"tool","text":"result","tool_call_id":"a","tool_name":"Read","tool_phase":"output","tool_failed":true}"#).unwrap();
        assert_eq!(current.tool_call_id.as_deref(), Some("a"));
        assert_eq!(current.tool_phase.as_deref(), Some("output"));
        assert_eq!(current.tool_failed, Some(true));
    }

    #[test]
    fn catalog_source_is_optional_for_older_hosts() {
        let legacy: super::MacThread =
            serde_json::from_str(r#"{"id":"old","title":"History","updated_at":null}"#).unwrap();
        assert_eq!(legacy.source, None);
        let current: super::MacThread = serde_json::from_str(
            r#"{"id":"cli","title":"History","updated_at":null,"source":"cli"}"#,
        )
        .unwrap();
        assert_eq!(current.source.as_deref(), Some("cli"));
    }

    use super::*;
    use abp_protocol::{self as wire, RpcResponse};
    use iroh::{endpoint::presets, Endpoint, RelayMode, SecretKey};

    /// Minimal fake Mac daemon: accepts one connection, serves STREAM_CONTROL
    /// (one request -> a canned response) and STREAM_AGENT_IO (one stdout
    /// chunk, a gap, then exit), mirroring `agentd::network::stream_inner`.
    async fn spawn_fake_mac(
        canned: &'static str,
    ) -> (
        iroh::EndpointAddr,
        iroh::Endpoint,
        tokio::task::JoinHandle<()>,
    ) {
        let endpoint = Endpoint::builder(presets::N0)
            .secret_key(SecretKey::generate())
            .alpns(vec![wire::ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .unwrap();
        let addr = endpoint.addr();
        let listener = endpoint.clone();
        let handle = tokio::spawn(async move {
            let Some(incoming) = listener.accept().await else {
                return;
            };
            let Ok(connection) = incoming.await else {
                return;
            };
            let Ok((mut send, mut recv)) = connection.accept_bi().await else {
                return;
            };
            let Frame::Hello(hello) = wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                .await
                .unwrap()
            else {
                panic!("expected hello")
            };
            let max = hello.negotiate().unwrap();
            wire::write_frame(&mut send, &Frame::Hello(Hello::new("fake-mac")), max)
                .await
                .unwrap();
            let Frame::Open(open) = wire::read_frame(&mut recv, max).await.unwrap() else {
                panic!("expected open")
            };
            wire::write_frame(&mut send, &Frame::Response(RpcResponse::default()), max)
                .await
                .unwrap();
            if open.kind == wire::STREAM_CONTROL {
                let Frame::Request(request) = wire::read_frame(&mut recv, max).await.unwrap()
                else {
                    panic!("expected request")
                };
                let response = Frame::Response(RpcResponse {
                    rpc_id: request.rpc_id,
                    body_json: canned.into(),
                    ..Default::default()
                });
                wire::write_frame(&mut send, &response, max).await.unwrap();
            } else if open.kind == wire::STREAM_AGENT_IO {
                wire::write_frame(
                    &mut send,
                    &Frame::Io(IoFrame {
                        channel: wire::CHANNEL_STDOUT,
                        data: b"hello".to_vec(),
                        ..Default::default()
                    }),
                    max,
                )
                .await
                .unwrap();
                wire::write_frame(
                    &mut send,
                    &Frame::Io(IoFrame {
                        channel: wire::CHANNEL_GAP,
                        offset: 5,
                        lost_bytes: 2,
                        ..Default::default()
                    }),
                    max,
                )
                .await
                .unwrap();
                wire::write_frame(
                    &mut send,
                    &Frame::Io(IoFrame {
                        channel: wire::CHANNEL_EXIT,
                        exit_code: Some(0),
                        ..Default::default()
                    }),
                    max,
                )
                .await
                .unwrap();
            }
            // A dropped SendStream without `finish()` resets rather than
            // cleanly closes. More importantly, dropping the whole
            // `Connection` right after can race ahead of that FIN/data
            // actually reaching the peer (quinn/iroh tears the connection
            // down on Drop) — real agentd never hits this because one
            // `Connection` serves many streams over its lifetime and only
            // closes at session end (`ConnectionGuard::drop`). Hold this
            // one open briefly so the client's read in this short-lived
            // test harness has time to land first.
            let _ = send.finish();
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        });
        (addr, endpoint, handle)
    }

    #[test]
    fn directory_listing_parses_the_macs_response() {
        let body = r#"{"path":"/Users/me/work","parent":"/Users/me","truncated":false,
            "entries":[{"name":"app","path":"/Users/me/work/app","is_project":true}]}"#;
        let listing: MacDirectoryListing = parse(body).unwrap();
        assert_eq!(listing.parent.as_deref(), Some("/Users/me"));
        assert_eq!(listing.entries.len(), 1);
        assert!(listing.entries[0].is_project);
        let home: MacDirectoryListing = parse(r#"{"path":"/Users/me","parent":null,"entries":[],"truncated":true}"#).unwrap();
        assert!(home.parent.is_none() && home.truncated);
    }

    #[tokio::test]
    async fn catalog_is_pipelined_once_but_invalid_hello_or_ack_never_succeeds() {
        for mode in ["success", "incompatible", "unauthorized"] {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                let host = Endpoint::builder(presets::Minimal).alpns(vec![wire::ALPN.to_vec()]).bind().await.unwrap();
                let directory = tempfile::tempdir().unwrap();
                let client = BridgeConnection::with_network(directory.path().join("phone.key").to_string_lossy().into_owned(),
                    host.id().to_string(), crate::PeerNetworkConfig { relay_url: None, relay_access_key: None,
                        direct_addresses: host.addr().ip_addrs().map(ToString::to_string).collect() }).unwrap();
                let listener = host.clone();
                let server = tokio::spawn(async move {
                    let conn = listener.accept().await.unwrap().await.unwrap();
                    let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                    // Withhold every response until all three frames arrive. A serial
                    // Hello/Open/Request client deadlocks here, proving the RTT saving.
                    assert!(matches!(wire::read_frame(&mut recv, 1024).await.unwrap(), Frame::Hello(_)));
                    assert!(matches!(wire::read_frame(&mut recv, 1024).await.unwrap(), Frame::Open(open) if open.kind == wire::STREAM_CONTROL));
                    let Frame::Request(request) = wire::read_frame(&mut recv, 1024).await.unwrap() else { panic!("catalog request") };
                    assert_eq!(request.method, "ListAgentProjects");
                    assert_eq!(serde_json::from_str::<serde_json::Value>(&request.body_json).unwrap()["agent_id"], "codex");
                    let mut hello = Hello::new("pipeline-host");
                    hello.max_frame_bytes = 1024;
                    if mode == "incompatible" { hello.major += 1; }
                    wire::write_frame(&mut send, &Frame::Hello(hello), 1024).await.unwrap();
                    if mode != "incompatible" {
                        wire::write_frame(&mut send, &Frame::Response(RpcResponse {
                            error_code: if mode == "unauthorized" { "unauthorized".into() } else { String::new() },
                            ..Default::default()
                        }), 1024).await.unwrap();
                        wire::write_frame(&mut send, &Frame::Response(RpcResponse {
                            rpc_id: request.rpc_id, body_json: "[]".into(), ..Default::default()
                        }), 1024).await.unwrap();
                    }
                    send.finish().unwrap();
                    let _ = send.stopped().await;
                    if mode == "success" {
                        assert!(wire::read_frame(&mut recv, 1024).await.is_err(), "catalog must be submitted exactly once");
                    }
                });
                assert_eq!(client.connect().await, ConnectionState::Connected);
                let result = client.list_agent_projects("codex".into()).await;
                match mode {
                    "success" => assert!(result.unwrap().is_empty()),
                    _ => assert_eq!(result.unwrap_err().code(), mode),
                }
                if mode == "success" {
                    // Observe stream EOF while the QUIC connection is still alive:
                    // closing the connection could hide a queued duplicate request.
                    server.await.unwrap();
                    client.disconnect().await;
                } else {
                    client.disconnect().await;
                    server.await.unwrap();
                }
                host.close().await;
            }).await.expect("pipelined catalog must not wait for an early reply");
        }
    }

    #[tokio::test]
    async fn mutations_and_oversize_catalog_wait_for_open_ack() {
        for (method, body) in [
            ("StartProcess", "{}".to_owned()),
            ("ListAgentProjects", "x".repeat(2048)),
        ] {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                let host = Endpoint::builder(presets::Minimal)
                    .alpns(vec![wire::ALPN.to_vec()])
                    .bind()
                    .await
                    .unwrap();
                let directory = tempfile::tempdir().unwrap();
                let client = BridgeConnection::with_network(
                    directory
                        .path()
                        .join("phone.key")
                        .to_string_lossy()
                        .into_owned(),
                    host.id().to_string(),
                    crate::PeerNetworkConfig {
                        relay_url: None,
                        relay_access_key: None,
                        direct_addresses: host.addr().ip_addrs().map(ToString::to_string).collect(),
                    },
                )
                .unwrap();
                let listener = host.clone();
                let server = tokio::spawn(async move {
                    let conn = listener.accept().await.unwrap().await.unwrap();
                    let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                    assert!(matches!(
                        wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                            .await
                            .unwrap(),
                        Frame::Hello(_)
                    ));
                    assert!(matches!(
                        wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                            .await
                            .unwrap(),
                        Frame::Open(_)
                    ));
                    // No request bytes may precede the validated Hello/Open ACK.
                    assert!(tokio::time::timeout(
                        std::time::Duration::from_millis(50),
                        wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                    )
                    .await
                    .is_err());
                    wire::write_frame(
                        &mut send,
                        &Frame::Hello(Hello::new("pipeline-host")),
                        wire::MAX_FRAME_BYTES,
                    )
                    .await
                    .unwrap();
                    wire::write_frame(
                        &mut send,
                        &Frame::Response(RpcResponse::default()),
                        wire::MAX_FRAME_BYTES,
                    )
                    .await
                    .unwrap();
                    let Frame::Request(request) =
                        wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                            .await
                            .unwrap()
                    else {
                        panic!("request")
                    };
                    assert_eq!(request.method, method);
                    wire::write_frame(
                        &mut send,
                        &Frame::Response(RpcResponse {
                            rpc_id: request.rpc_id,
                            body_json: "null".into(),
                            ..Default::default()
                        }),
                        wire::MAX_FRAME_BYTES,
                    )
                    .await
                    .unwrap();
                    send.finish().unwrap();
                    let _ = send.stopped().await;
                });
                assert_eq!(client.connect().await, ConnectionState::Connected);
                assert_eq!(client.call(method, body, 1000).await.unwrap(), "null");
                client.disconnect().await;
                server.await.unwrap();
                host.close().await;
            })
            .await
            .expect("control stream deadline");
        }
    }

    #[tokio::test]
    async fn call_round_trips_through_a_fresh_stream() {
        let (addr, _mac_endpoint, mac_task) = spawn_fake_mac(r#"{"ok":true}"#).await;
        let client = Endpoint::builder(presets::N0)
            .secret_key(SecretKey::generate())
            .alpns(vec![wire::ALPN.to_vec()])
            .relay_mode(RelayMode::Disabled)
            .bind()
            .await
            .unwrap();
        let connection = client.connect(addr, wire::ALPN).await.unwrap();
        let client_fut = async {
            let (mut send, mut recv, max) =
                open_stream(&connection, "phone", wire::STREAM_CONTROL, "", "")
                    .await
                    .map_err(|e| e.to_string())?;
            write_frame(
                &mut send,
                &Frame::Request(RpcRequest {
                    rpc_id: "1".into(),
                    method: "Ping".into(),
                    body_json: "null".into(),
                    timeout_ms: 5_000,
                }),
                max,
            )
            .await?;
            read_frame(&mut recv, max).await
        };
        let (client_result, mac_result): (Result<Frame, String>, _) =
            tokio::join!(client_fut, mac_task);
        mac_result.expect("mac task join");
        let Frame::Response(response) = client_result.expect("client round trip") else {
            panic!("expected response")
        };
        assert_eq!(response.body_json, r#"{"ok":true}"#);
    }

    /// Serves multiple RPC streams until explicitly disconnected.
    async fn persistent_mac(name: &'static str) -> (Endpoint, tokio::task::JoinHandle<()>) {
        let endpoint = Endpoint::builder(presets::N0)
            .relay_mode(RelayMode::Disabled)
            .alpns(vec![wire::ALPN.to_vec()])
            .bind()
            .await
            .unwrap();
        let listener = endpoint.clone();
        let task = tokio::spawn(async move {
            while let Some(incoming) = listener.accept().await {
                tokio::spawn(async move {
                    let Ok(connection) = incoming.await else {
                        return;
                    };
                    while let Ok((mut send, mut recv)) = connection.accept_bi().await {
                        let Frame::Hello(hello) =
                            wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                                .await
                                .unwrap()
                        else {
                            panic!("hello")
                        };
                        let max = hello.negotiate().unwrap();
                        wire::write_frame(&mut send, &Frame::Hello(Hello::new("test-mac")), max)
                            .await
                            .unwrap();
                        let Frame::Open(_) = wire::read_frame(&mut recv, max).await.unwrap() else {
                            panic!("open")
                        };
                        wire::write_frame(&mut send, &Frame::Response(RpcResponse::default()), max)
                            .await
                            .unwrap();
                        let request_frame = wire::read_frame(&mut recv, max).await.unwrap();
                        if let Frame::Pair(_) = request_frame {
                            wire::write_frame(
                                &mut send,
                                &Frame::Response(RpcResponse {
                                    body_json: r#"{"state":"pending"}"#.into(),
                                    ..Default::default()
                                }),
                                max,
                            )
                            .await
                            .unwrap();
                            wire::write_frame(
                                &mut send,
                                &Frame::Response(RpcResponse {
                                    body_json: r#"{"state":"approved"}"#.into(),
                                    ..Default::default()
                                }),
                                max,
                            )
                            .await
                            .unwrap();
                            let _ = send.finish();
                            continue;
                        }
                        let Frame::Request(request) = request_frame else {
                            panic!("request")
                        };
                        let body = if request.method == "ListAgents" {
                            format!(
                                r#"[{{"id":"{name}","name":"{name}","version":null,"status":"ready","validation":"verified"}}]"#
                            )
                        } else {
                            "null".into()
                        };
                        wire::write_frame(
                            &mut send,
                            &Frame::Response(RpcResponse {
                                rpc_id: request.rpc_id,
                                body_json: body,
                                ..Default::default()
                            }),
                            max,
                        )
                        .await
                        .unwrap();
                        let _ = send.finish();
                    }
                });
            }
        });
        (endpoint, task)
    }

    #[tokio::test]
    async fn two_macs_share_identity_and_disconnect_independently() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("phone-key").to_str().unwrap().to_owned();
        let (mac_a, task_a) = persistent_mac("A").await;
        let (mac_b, task_b) = persistent_mac("B").await;
        let a = BridgeConnection::new(path.clone(), mac_a.id().to_string());
        let b = BridgeConnection::new(path.clone(), mac_b.id().to_string());
        assert!(Arc::ptr_eq(&a.endpoint, &b.endpoint));
        let (ea, eb) = tokio::join!(a.endpoint.get(), b.endpoint.get());
        let endpoint = ea.unwrap();
        assert_eq!(endpoint.id(), eb.unwrap().id());
        let lookup = iroh::address_lookup::memory::MemoryLookup::new();
        lookup.add_endpoint_info(mac_a.addr());
        lookup.add_endpoint_info(mac_b.addr());
        endpoint.address_lookup().unwrap().add(lookup);
        let (sa, sb) = tokio::join!(a.connect(), b.connect());
        assert_eq!(sa, ConnectionState::Connected);
        assert_eq!(sb, ConnectionState::Connected);
        let (ra, rb) = tokio::join!(a.list_agents(), b.list_agents());
        assert_eq!(ra.unwrap()[0].id, "A");
        assert_eq!(rb.unwrap()[0].id, "B");
        let (mac_c, task_c) = persistent_mac("C").await;
        let lookup_c = iroh::address_lookup::memory::MemoryLookup::new();
        lookup_c.add_endpoint_info(mac_c.addr());
        endpoint.address_lookup().unwrap().add(lookup_c);
        let (pair, ping_a, ping_b) = tokio::join!(
            crate::pair_over_iroh(
                mac_c.id().to_string(),
                "session".into(),
                "token".into(),
                "phone".into(),
                path.clone()
            ),
            a.ping(),
            b.ping()
        );
        assert!(pair.ok, "{}", pair.error_message);
        assert_eq!(pair.device_id, endpoint.id().to_string());
        ping_a.unwrap();
        ping_b.unwrap();
        mac_c.close().await;
        task_c.abort();
        a.disconnect().await;
        assert!(a.ping().await.is_err());
        b.ping().await.unwrap();
        assert_eq!(b.state(), ConnectionState::Connected);
        assert_eq!(a.connect().await, ConnectionState::Connected);
        mac_a.close().await;
        assert!(a.ping().await.is_err());
        b.ping().await.unwrap();
        // Pairing uses this exact registry entry without replacing either
        // established connection (invalid payload cannot disturb B).
        let outcome =
            crate::pair_over_iroh("invalid".into(), "".into(), "".into(), "phone".into(), path)
                .await;
        assert_eq!(outcome.error_code, "invalid_params");
        assert_eq!(outcome.device_id, endpoint.id().to_string());
        b.ping().await.unwrap();
        b.disconnect().await;
        mac_b.close().await;
        task_a.abort();
        task_b.abort();
    }

    #[tokio::test]
    async fn disconnect_invalidates_queued_connect() {
        let dir = tempfile::tempdir().unwrap();
        let client = BridgeConnection::new(
            dir.path().join("key").display().to_string(),
            "invalid".into(),
        );
        let gate = client.operation.lock().await;
        let connecting = {
            let client = client.clone();
            tokio::spawn(async move { client.connect().await })
        };
        tokio::task::yield_now().await;
        let disconnecting = {
            let client = client.clone();
            tokio::spawn(async move { client.disconnect().await })
        };
        tokio::task::yield_now().await;
        drop(gate);
        assert_eq!(connecting.await.unwrap(), ConnectionState::Disconnected);
        disconnecting.await.unwrap();
        assert_eq!(client.state(), ConnectionState::Disconnected);
    }

    #[test]
    fn bridge_error_carries_code_and_message() {
        let error = BridgeError::new("timeout", "took too long");
        assert_eq!(error.code(), "timeout");
        assert_eq!(error.to_string(), "took too long");
    }

    #[test]
    fn write_stdin_chunk_size_matches_max_io_bytes() {
        let data = vec![7u8; abp_protocol::MAX_IO_BYTES * 2 + 3];
        let chunks: Vec<_> = data.chunks(abp_protocol::MAX_IO_BYTES).collect();
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].len(), abp_protocol::MAX_IO_BYTES);
        assert_eq!(chunks[2].len(), 3);
    }
    struct NoChatCallback;
    impl AgentIoCallback for NoChatCallback {
        fn on_stdout(&self, _: Vec<u8>, _: u64, _: u64) {}
        fn on_stderr(&self, _: Vec<u8>, _: u64, _: u64) {}
        fn on_gap(&self, _: i32, _: u64, _: u64) {}
        fn on_exit(&self, _: Option<i32>) {}
        fn on_error(&self, _: String, _: String) {}
    }
    #[tokio::test]
    async fn chat_capability_gate_rejects_legacy_host_before_agent_io() {
        let (addr, mac, task) = spawn_fake_mac("[]").await;
        let dir = tempfile::tempdir().unwrap();
        let client = BridgeConnection::new(
            dir.path().join("key").display().to_string(),
            mac.id().to_string(),
        );
        let endpoint = client.endpoint.get().await.unwrap();
        let lookup = iroh::address_lookup::memory::MemoryLookup::new();
        lookup.add_endpoint_info(addr);
        endpoint.address_lookup().unwrap().add(lookup);
        assert_eq!(client.connect().await, ConnectionState::Connected);
        let error = client
            .attach_chat_io(
                "process".into(),
                "generation".into(),
                Box::new(NoChatCallback),
            )
            .await
            .err()
            .unwrap();
        assert_eq!(error.code(), "unsupported");
        task.await.unwrap();
        client.disconnect().await;
        mac.close().await;
    }
}
