# Runtime API (authoritative integration contract)

Rust DTOs owned by `agentd::types`, all fields snake_case, enum strings snake_case.
`BridgeError { code: String, message: String }`, `Result<T>` alias.
`Daemon::open(data_dir: impl AsRef<Path>) -> Result<Arc<Daemon>>` synchronous,
opens metadata/lock only. Network startup is separate; UI remains usable on failure.
`identity::load_or_create() -> Result<[u8;32]>` OS secure key (blocking).
`Daemon::open_with_adapters(data_dir, Vec<agent_adapters::AdapterSpec>)` for harness.

## Shared DTOs
- AgentInfo { id, name, version: Option<String>, status, validation, capabilities: Vec<String>, diagnostic: Option<String> }. status: not_found/installed/available/running/version_mismatch/probe_failed. validation: unverified/verified/failed.
- NetworkInfo { state: String, endpoint_id: Option<String>, detail: Option<String> }. state: starting/ready/error/stopped (no fabricated direct/relay).
- DaemonStatus { running: bool, uptime_secs: u32, network: NetworkInfo, active_processes: u32, connected_devices: u32 }.
- PairedDevice { device_id, name, paired_at, last_seen: Option<String>, connection: String, permissions: Vec<String> }.
- ProcessInfo { process_id, generation: String, agent_id, owner_device_id, pid: Option<u32>, state: String, started_at, exit_code: Option<i32> }. state starting/running/stopping/exited/failed/lost.
- AppSettings { device_name: String }. Autostart is queried/changed by native shell, not stored as an assumed value.
- PairSession { session_id, endpoint_id, token, expires_at, qr_payload }. Only returned by start_pairing; never included in snapshots/events.
- PairRequest { request_id, session_id, device_id, name, permissions: Vec<String>, expires_at, state: String }. state pending/approved/rejected/expired/cancelled.
- PairingState { session_id: Option<String>, expires_at: Option<String>, request: Option<PairRequest>, state: String }. state idle/waiting/pending/approved/rejected/expired/cancelled. No token.
- Snapshot { service_instance, revision: String, status: DaemonStatus, agents: Vec<AgentInfo>, devices: Vec<PairedDevice>, processes: Vec<ProcessInfo>, pairing: PairingState, settings: AppSettings }.
- DaemonEvent { service_instance, revision: String, kind: String, payload: serde_json::Value }. No tokens. UI can fetch snapshot on event. Receiver lag also triggers snapshot.

## Local admin methods
All `&self`, async unless marked sync:
- snapshot() -> Result<Snapshot>
- list_agents(refresh: bool) -> Result<Vec<AgentInfo>>
- get_status() -> Result<DaemonStatus>
- list_devices() -> Result<Vec<PairedDevice>>
- list_processes() -> Vec<ProcessInfo>
- start_pairing() -> Result<PairSession> (network must have endpoint_id)
- cancel_pairing(session_id: &str) -> Result<()>
- approve_pairing(request_id: &str, permissions: Vec<String>) -> Result<PairedDevice>
- reject_pairing(request_id: &str) -> Result<()>
- revoke_device(device_id: &str) -> Result<()>
- settings() -> Result<AppSettings> (sync)
- update_settings(settings: AppSettings) -> Result<()> (sync)
- subscribe() -> tokio::sync::broadcast::Receiver<DaemonEvent> (sync)
- shutdown() -> Result<()>

## Network methods
- set_network(state: &str, endpoint_id: Option<String>, detail: Option<String>) (sync)
- set_device_connected(peer: &str, connected: bool) -> Result<()> (sync); transport tracks connection counts before calling disconnect.
- authorize(peer: &str, permissions: &[&str]) -> Result<()> (sync)
- submit_pair(token: &str, peer: &str, name: &str) -> Result<PairRequest> (async); token atomically consumed; default offered permissions view/session/task/approval.
- pairing_state() -> PairingState (async), contains latest request disposition.
- start_process(peer: &str, operation_id: &str, agent_id: &str, cwd: &str) -> Result<ProcessInfo> (async)
- stop_process(peer: &str, operation_id: &str, process_id: &str, generation: &str) -> Result<ProcessInfo> (async)
- process_status(peer: &str, process_id: &str, generation: &str) -> Result<ProcessInfo> (async)
- attach_io(peer: &str, process_id: &str, generation: &str) -> Result<IoSession> (async), enforces task+approval and ownership, one writer.
IoSession has `write(&self, bytes: Vec<u8>) -> Result<()>` async, `next(&mut self) -> Result<Option<OutputFrame>>` async; Drop releases lease. OutputFrame { channel: String, offset: String, data: Vec<u8>, gap: bool }; channel stdout/stderr, gap indicates missing output before this chunk. next returns None after both drains close. Store cursor starts at retained head; gap true if prior bytes dropped. Revocation must cancel active connections from daemon event `device-revoked` payload `{ device_id }`; write/next also check current grant. `generation` comparison mandatory.

Network worker owns `NetworkServer` startup/shutdown API and notifies desktop.
