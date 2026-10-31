//! Embedded, byte-transparent Agent host. Business state stays with the peer.
pub mod identity;
pub mod network;
mod process;
mod store;
pub mod types;
use agent_adapters::AdapterSpec;
use fs2::FileExt;
pub use process::IoSession;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{File, OpenOptions},
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::sync::{broadcast, Mutex as AsyncMutex};
use types::*;
pub use types::{BridgeError, Result};
use uuid::Uuid;

struct EventHub {
    instance: String,
    revision: AtomicU64,
    events: broadcast::Sender<DaemonEvent>,
    snapshot_gate: Arc<Mutex<()>>,
}
impl EventHub {
    fn emit(&self, kind: &str, payload: serde_json::Value) {
        let revision = self.revision.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = self.events.send(DaemonEvent {
            service_instance: self.instance.clone(),
            revision: revision.to_string(),
            kind: kind.into(),
            payload,
        });
    }
}
struct Pairing {
    state: PairingState,
    digest: Option<Vec<u8>>,
    deadline: Option<Instant>,
}
impl Pairing {
    fn expire(&mut self) -> bool {
        if self.deadline.is_some_and(|d| d <= Instant::now())
            && matches!(self.state.state.as_str(), "waiting" | "pending")
        {
            self.state.state = "expired".into();
            if let Some(r) = &mut self.state.request {
                r.state = "expired".into();
            }
            self.digest = None;
            return true;
        }
        false
    }
}

pub struct Daemon {
    _lock: File,
    store: Arc<store::Store>,
    hub: Arc<EventHub>,
    processes: process::ProcessManager,
    network: Mutex<NetworkInfo>,
    connected: Mutex<HashSet<String>>,
    pairing: Arc<AsyncMutex<Pairing>>,
    adapters: Mutex<Vec<AdapterSpec>>,
    custom_adapters: bool,
    agents: Mutex<Vec<AgentInfo>>,
    probe_gate: AsyncMutex<()>,
    mutation_gate: AsyncMutex<()>,
    stopping: AtomicBool,
    started: Instant,
}
impl Daemon {
    pub fn open(data_dir: impl AsRef<Path>) -> Result<Arc<Self>> {
        Self::open_inner(data_dir.as_ref(), production_specs(), false)
    }
    /// Explicit dependency injection for deterministic transport/process tests.
    pub fn open_with_adapters(
        data_dir: impl AsRef<Path>,
        adapters: Vec<AdapterSpec>,
    ) -> Result<Arc<Self>> {
        Self::open_inner(data_dir.as_ref(), adapters, true)
    }
    fn open_inner(
        dir: &Path,
        adapters: Vec<AdapterSpec>,
        custom_adapters: bool,
    ) -> Result<Arc<Self>> {
        std::fs::create_dir_all(dir).map_err(storage_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
                .map_err(storage_error)?;
        }
        let mut options = OpenOptions::new();
        options.create(true).read(true).write(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(dir.join("host.lock")).map_err(storage_error)?;
        lock.try_lock_exclusive().map_err(|_| {
            BridgeError::new(
                "conflict",
                "Another Agent Bridge host is using this data directory.",
            )
        })?;
        let store = Arc::new(store::Store::open(&dir.join("host.sqlite3"))?);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                dir.join("host.sqlite3"),
                std::fs::Permissions::from_mode(0o600),
            )
            .map_err(storage_error)?;
        }
        let (events, _) = broadcast::channel(128);
        let hub = Arc::new(EventHub {
            instance: Uuid::new_v4().to_string(),
            revision: AtomicU64::new(0),
            events,
            snapshot_gate: Arc::new(Mutex::new(())),
        });
        let process_hub = hub.clone();
        let processes = process::ProcessManager::new(
            store.clone(),
            hub.snapshot_gate.clone(),
            Arc::new(move |info| {
                process_hub.emit(
                    "process-changed",
                    serde_json::to_value(info).unwrap_or_default(),
                );
            }),
        );
        Ok(Arc::new(Self {
            _lock: lock,
            store,
            hub,
            processes,
            network: Mutex::new(NetworkInfo {
                state: "starting".into(),
                endpoint_id: None,
                detail: None,
            }),
            connected: Mutex::new(HashSet::new()),
            pairing: Arc::new(AsyncMutex::new(Pairing {
                state: PairingState::default(),
                digest: None,
                deadline: None,
            })),
            adapters: Mutex::new(adapters),
            custom_adapters,
            agents: Mutex::new(Vec::new()),
            probe_gate: AsyncMutex::new(()),
            mutation_gate: AsyncMutex::new(()),
            stopping: AtomicBool::new(false),
            started: Instant::now(),
        }))
    }
    pub fn service_instance(&self) -> &str {
        &self.hub.instance
    }
    pub fn subscribe(&self) -> broadcast::Receiver<DaemonEvent> {
        self.hub.events.subscribe()
    }
    pub fn set_network(&self, state: &str, endpoint_id: Option<String>, detail: Option<String>) {
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        let info = NetworkInfo {
            state: state.into(),
            endpoint_id,
            detail,
        };
        *self.network.lock().unwrap() = info.clone();
        self.hub.emit(
            "network-changed",
            serde_json::to_value(info).unwrap_or_default(),
        );
    }
    pub fn set_device_connected(&self, peer: &str, connected: bool) -> Result<()> {
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        if connected {
            self.authorize(peer, &[])?;
            self.store.seen(peer)?;
            self.connected.lock().unwrap().insert(peer.into());
        } else {
            self.connected.lock().unwrap().remove(peer);
        }
        self.hub
            .emit("device-changed", serde_json::json!({"device_id":peer}));
        Ok(())
    }
    pub fn authorize(&self, peer: &str, permissions: &[&str]) -> Result<()> {
        self.store.authorize(peer, permissions)
    }
    pub fn settings(&self) -> Result<AppSettings> {
        self.store.settings()
    }
    pub fn update_settings(&self, settings: AppSettings) -> Result<()> {
        validate_name(&settings.device_name)?;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        self.store.save_settings(&settings)?;
        self.hub.emit("settings-changed", serde_json::json!({}));
        Ok(())
    }
    pub async fn list_agents(&self, refresh: bool) -> Result<Vec<AgentInfo>> {
        let _probe = self.probe_gate.lock().await;
        if self.stopping.load(Ordering::SeqCst) {
            return Err(BridgeError::new(
                "unavailable",
                "The host is shutting down.",
            ));
        }
        if !refresh {
            if let Some(cached) = self.store.cached_agents()? {
                let _snapshot = self.hub.snapshot_gate.lock().unwrap();
                *self.agents.lock().unwrap() = cached.clone();
                return Ok(self.with_running(cached));
            }
        }
        if !self.custom_adapters {
            *self.adapters.lock().unwrap() = production_specs();
        }
        let specs = self.adapters.lock().unwrap().clone();
        let mut infos = Vec::new();
        for spec in &specs {
            infos.push(agent_adapters::probe(spec).await);
        }
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        self.store.cache_agents(&infos)?;
        *self.agents.lock().unwrap() = infos.clone();
        self.hub.emit("agent-status-changed", serde_json::json!({}));
        Ok(self.with_running(infos))
    }
    fn with_running(&self, mut infos: Vec<AgentInfo>) -> Vec<AgentInfo> {
        let processes = self.processes.list();
        for info in &mut infos {
            if processes
                .iter()
                .any(|p| p.agent_id == info.id && p.state == "running")
            {
                info.status = "running".into();
            }
        }
        infos
    }
    pub async fn list_devices(&self) -> Result<Vec<PairedDevice>> {
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        self.devices_unlocked()
    }
    fn devices_unlocked(&self) -> Result<Vec<PairedDevice>> {
        let mut devices = self.store.devices()?;
        let connected = self.connected.lock().unwrap();
        for d in &mut devices {
            if connected.contains(&d.device_id) {
                d.connection = "online".into();
            }
        }
        Ok(devices)
    }
    pub async fn list_processes(&self) -> Vec<ProcessInfo> {
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        self.processes_unlocked()
    }
    fn processes_unlocked(&self) -> Vec<ProcessInfo> {
        let mut result = self.processes.list();
        if let Ok(saved) = self.store.processes() {
            for p in saved {
                if !result.iter().any(|live| live.process_id == p.process_id) {
                    result.push(p);
                }
            }
        }
        result.sort_by(|a, b| {
            b.started_at
                .cmp(&a.started_at)
                .then_with(|| b.process_id.cmp(&a.process_id))
        });
        let mut terminal = 0;
        result.retain(|p| {
            if matches!(p.state.as_str(), "starting" | "running" | "stopping") {
                true
            } else {
                terminal += 1;
                terminal <= 64
            }
        });
        result
    }
    pub async fn get_status(&self) -> Result<DaemonStatus> {
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        Ok(self.status_unlocked())
    }
    fn status_unlocked(&self) -> DaemonStatus {
        DaemonStatus {
            running: !self.stopping.load(Ordering::SeqCst),
            uptime_secs: self.started.elapsed().as_secs().min(u32::MAX as u64) as u32,
            network: self.network.lock().unwrap().clone(),
            active_processes: self
                .processes
                .list()
                .iter()
                .filter(|p| matches!(p.state.as_str(), "running" | "starting" | "stopping"))
                .count() as u32,
            connected_devices: self.connected.lock().unwrap().len() as u32,
        }
    }
    pub async fn snapshot(&self) -> Result<Snapshot> {
        self.list_agents(false).await?;
        // Pairing lock always precedes the synchronous publication gate.
        // No await is allowed while holding the publication gate.
        let mut pair = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        if pair.expire() {
            self.hub.emit(
                "pairing-progress",
                serde_json::to_value(&pair.state).unwrap_or_default(),
            );
        }
        Ok(Snapshot {
            service_instance: self.hub.instance.clone(),
            revision: self.hub.revision.load(Ordering::SeqCst).to_string(),
            status: self.status_unlocked(),
            agents: self.with_running(self.agents.lock().unwrap().clone()),
            devices: self.devices_unlocked()?,
            processes: self.processes_unlocked(),
            pairing: pair.state.clone(),
            settings: self.settings()?,
        })
    }
    pub async fn start_pairing(&self) -> Result<PairSession> {
        if self.stopping.load(Ordering::SeqCst) {
            return Err(BridgeError::new(
                "unavailable",
                "The host is shutting down.",
            ));
        }
        let endpoint_id = self
            .network
            .lock()
            .unwrap()
            .endpoint_id
            .clone()
            .ok_or_else(|| {
                BridgeError::new(
                    "network_error",
                    "The network endpoint is unavailable. Retry network startup first.",
                )
            })?;
        let mut pair = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        if self.stopping.load(Ordering::SeqCst) {
            return Err(BridgeError::new(
                "unavailable",
                "The host is shutting down.",
            ));
        }
        pair.expire();
        if matches!(pair.state.state.as_str(), "waiting" | "pending") {
            return Err(BridgeError::new(
                "conflict",
                "A pairing window is already active.",
            ));
        }
        let session_id = Uuid::new_v4().to_string();
        let token = hex::encode(rand::random::<[u8; 32]>());
        let expires_at = (chrono::Utc::now() + chrono::Duration::seconds(120))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        pair.state = PairingState {
            session_id: Some(session_id.clone()),
            expires_at: Some(expires_at.clone()),
            request: None,
            state: "waiting".into(),
        };
        pair.digest = Some(Sha256::digest(token.as_bytes()).to_vec());
        pair.deadline = Some(Instant::now() + Duration::from_secs(120));
        let qr_payload=serde_json::json!({"version":1,"session_id":session_id,"endpoint_id":endpoint_id,"token":token,"expires_at":expires_at,"device_name":self.settings()?.device_name}).to_string();
        self.hub.emit(
            "pairing-progress",
            serde_json::to_value(&pair.state).unwrap_or_default(),
        );
        drop(pair);
        let pairing = self.pairing.clone();
        let hub = self.hub.clone();
        let expected = session_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(120)).await;
            let mut p = pairing.lock().await;
            let _snapshot = hub.snapshot_gate.lock().unwrap();
            if p.state.session_id.as_deref() == Some(&expected) && p.expire() {
                hub.emit(
                    "pairing-progress",
                    serde_json::to_value(&p.state).unwrap_or_default(),
                );
            }
        });
        Ok(PairSession {
            session_id,
            endpoint_id,
            token,
            expires_at,
            qr_payload,
        })
    }
    pub async fn pairing_state(&self) -> PairingState {
        let mut p = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        if p.expire() {
            self.hub.emit(
                "pairing-progress",
                serde_json::to_value(&p.state).unwrap_or_default(),
            );
        }
        p.state.clone()
    }
    pub async fn submit_pair(&self, token: &str, peer: &str, name: &str) -> Result<PairRequest> {
        validate_id(peer)?;
        validate_name(name)?;
        let mut p = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        p.expire();
        let digest = Sha256::digest(token.as_bytes());
        let matches = p.digest.as_ref().is_some_and(|stored| {
            stored.len() == digest.len()
                && stored
                    .iter()
                    .zip(digest.iter())
                    .fold(0u8, |acc, (a, b)| acc | (a ^ b))
                    == 0
        });
        if token.len() != 64 || p.state.state != "waiting" || !matches {
            return Err(BridgeError::new(
                "unauthorized",
                "Pairing invitation is invalid, consumed or expired.",
            ));
        }
        p.digest = None;
        let request = PairRequest {
            request_id: Uuid::new_v4().to_string(),
            session_id: p.state.session_id.clone().unwrap_or_default(),
            device_id: peer.into(),
            name: name.into(),
            permissions: vec![
                "view".into(),
                "session".into(),
                "task".into(),
                "approval".into(),
            ],
            expires_at: p.state.expires_at.clone().unwrap_or_default(),
            state: "pending".into(),
        };
        p.state.state = "pending".into();
        p.state.request = Some(request.clone());
        self.hub.emit(
            "pairing-progress",
            serde_json::to_value(&p.state).unwrap_or_default(),
        );
        Ok(request)
    }
    pub async fn cancel_pairing(&self, session_id: &str) -> Result<()> {
        let mut p = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        if p.state.session_id.as_deref() != Some(session_id) {
            return Err(BridgeError::new(
                "conflict",
                "Pairing session is no longer current.",
            ));
        }
        if matches!(
            p.state.state.as_str(),
            "approved" | "rejected" | "expired" | "cancelled"
        ) {
            return Ok(());
        }
        p.state.state = "cancelled".into();
        p.digest = None;
        if let Some(r) = &mut p.state.request {
            r.state = "cancelled".into();
        }
        self.hub.emit(
            "pairing-progress",
            serde_json::to_value(&p.state).unwrap_or_default(),
        );
        Ok(())
    }
    pub async fn approve_pairing(
        &self,
        request_id: &str,
        mut permissions: Vec<String>,
    ) -> Result<PairedDevice> {
        let _mutation = self.mutation_gate.lock().await;
        let mut p = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        p.expire();
        let request = p
            .state
            .request
            .as_ref()
            .filter(|r| r.request_id == request_id && r.state == "pending")
            .cloned()
            .ok_or_else(|| {
                BridgeError::new("conflict", "The pairing request is no longer pending.")
            })?;
        permissions.sort();
        permissions.dedup();
        if !permissions.iter().any(|p| p == "view")
            || permissions.iter().any(|p| !request.permissions.contains(p))
        {
            return Err(invalid(
                "Select only permissions offered by this pairing request.",
            ));
        }
        if permissions.contains(&"task".into()) != permissions.contains(&"approval".into()) {
            return Err(invalid(
                "Opaque Agent I/O requires task and approval permissions together.",
            ));
        }
        let device = self
            .store
            .grant(&request.device_id, &request.name, permissions)?;
        p.state.state = "approved".into();
        if let Some(r) = &mut p.state.request {
            r.state = "approved".into();
        }
        self.hub.emit(
            "pairing-progress",
            serde_json::to_value(&p.state).unwrap_or_default(),
        );
        self.hub.emit(
            "device-changed",
            serde_json::json!({"device_id":device.device_id}),
        );
        Ok(device)
    }
    pub async fn reject_pairing(&self, request_id: &str) -> Result<()> {
        let mut p = self.pairing.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        p.expire();
        let r = p
            .state
            .request
            .as_mut()
            .filter(|r| r.request_id == request_id && r.state == "pending")
            .ok_or_else(|| {
                BridgeError::new("conflict", "The pairing request is no longer pending.")
            })?;
        r.state = "rejected".into();
        p.state.state = "rejected".into();
        p.digest = None;
        self.hub.emit(
            "pairing-progress",
            serde_json::to_value(&p.state).unwrap_or_default(),
        );
        Ok(())
    }
    pub async fn revoke_device(&self, device_id: &str) -> Result<()> {
        let _mutation = self.mutation_gate.lock().await;
        let _snapshot = self.hub.snapshot_gate.lock().unwrap();
        self.store.revoke(device_id)?;
        self.connected.lock().unwrap().remove(device_id);
        self.processes.notify_revocation();
        self.hub
            .emit("device-revoked", serde_json::json!({"device_id":device_id}));
        Ok(())
    }
    pub async fn start_process(
        &self,
        peer: &str,
        operation_id: &str,
        agent_id: &str,
        cwd: &str,
    ) -> Result<ProcessInfo> {
        validate_id(operation_id)?;
        self.authorize(peer, &["session"])?;
        let fingerprint =
            serde_json::json!({"method":"start","agent":agent_id,"cwd":cwd}).to_string();
        if let Some(info) = self
            .store
            .existing_operation(peer, operation_id, &fingerprint)?
        {
            return Ok(self.current_or_lost(info));
        }
        if !Path::new(cwd).is_absolute() || !Path::new(cwd).is_dir() {
            return Err(invalid(
                "Working directory must be an existing absolute directory.",
            ));
        }
        // Re-probe before a launch rather than trusting cached executable availability.
        let specs = self.adapters.lock().unwrap().clone();
        let spec = specs
            .into_iter()
            .find(|s| s.id == agent_id)
            .ok_or_else(|| BridgeError::new("agent_not_found", "Unknown Agent identifier."))?;
        let info = {
            let _probe = self.probe_gate.lock().await;
            if self.stopping.load(Ordering::SeqCst) {
                return Err(BridgeError::new(
                    "unavailable",
                    "The host is shutting down.",
                ));
            }
            agent_adapters::probe(&spec).await
        };
        if info.validation != "verified" {
            return Err(BridgeError::new(
                "agent_unavailable",
                "This Agent version does not have verified transport support.",
            ));
        }
        let _mutation = self.mutation_gate.lock().await;
        self.authorize(peer, &["session"])?;
        if self.stopping.load(Ordering::SeqCst) {
            return Err(BridgeError::new(
                "unavailable",
                "The host is shutting down.",
            ));
        }
        match self.store.reserve(peer, operation_id, &fingerprint)? {
            store::Reservation::Finished(info) => return Ok(self.current_or_lost(info)),
            store::Reservation::New => {}
        }
        let info = self.processes.start(peer, &spec, cwd).await?;
        self.store.finish(peer,operation_id,&info).map_err(|_|BridgeError::new("outcome_unknown","Process started but its operation result could not be persisted. Query status before retrying."))?;
        Ok(info)
    }
    fn current_or_lost(&self, mut info: ProcessInfo) -> ProcessInfo {
        if let Ok(current) = self.processes.get(&info.process_id, &info.generation) {
            return current;
        }
        if let Ok(Some(saved)) = self.store.process(&info.process_id) {
            if saved.generation == info.generation {
                return saved;
            }
        }
        if matches!(info.state.as_str(), "running" | "starting" | "stopping") {
            info.state = "lost".into();
            info.pid = None;
        }
        info
    }
    pub async fn process_status(
        &self,
        peer: &str,
        process_id: &str,
        generation: &str,
    ) -> Result<ProcessInfo> {
        self.authorize(peer, &["view"])?;
        self.owned_process(peer, process_id, generation)
    }
    fn owned_process(&self, peer: &str, process_id: &str, generation: &str) -> Result<ProcessInfo> {
        let info = self.processes.get(process_id, generation).or_else(|_| {
            self.store
                .process(process_id)?
                .filter(|p| p.generation == generation)
                .ok_or_else(|| {
                    BridgeError::new("process_gone", "Process generation is no longer known.")
                })
        })?;
        Self::check_process_owner(peer, info)
    }
    fn check_process_owner(peer: &str, info: ProcessInfo) -> Result<ProcessInfo> {
        if info.owner_device_id != peer {
            return Err(BridgeError::new(
                "unauthorized",
                "The process belongs to another device.",
            ));
        }
        Ok(info)
    }
    pub async fn stop_process(
        &self,
        peer: &str,
        operation_id: &str,
        process_id: &str,
        generation: &str,
    ) -> Result<ProcessInfo> {
        validate_id(operation_id)?;
        let _mutation = self.mutation_gate.lock().await;
        self.authorize(peer, &["session"])?;
        let fingerprint =
            serde_json::json!({"method":"stop","process":process_id,"generation":generation})
                .to_string();
        // A completed stop remains replayable after its in-memory entry is evicted
        // or the host restarts. Check the request fingerprint before target lookup.
        if let Some(info) = self
            .store
            .existing_operation(peer, operation_id, &fingerprint)?
        {
            return Ok(self.current_or_lost(Self::check_process_owner(peer, info)?));
        }
        let info = self.owned_process(peer, process_id, generation)?;
        if info.state == "lost" {
            return Err(BridgeError::new(
                "process_gone",
                "The process was lost when its host exited.",
            ));
        }
        match self.store.reserve(peer, operation_id, &fingerprint)? {
            store::Reservation::Finished(info) => {
                return Ok(self.current_or_lost(Self::check_process_owner(peer, info)?))
            }
            store::Reservation::New => {}
        }
        let info = if matches!(info.state.as_str(), "exited" | "failed") {
            info
        } else {
            self.processes.stop(process_id, generation).await?
        };
        self.store.finish(peer, operation_id, &info)?;
        Ok(info)
    }
    pub async fn attach_io(
        &self,
        peer: &str,
        process_id: &str,
        generation: &str,
    ) -> Result<IoSession> {
        self.processes.attach(peer, process_id, generation)
    }
    pub async fn shutdown(&self) -> Result<()> {
        let _mutation = self.mutation_gate.lock().await;
        {
            let mut pair = self.pairing.lock().await;
            let _snapshot = self.hub.snapshot_gate.lock().unwrap();
            self.stopping.store(true, Ordering::SeqCst);
            if matches!(pair.state.state.as_str(), "waiting" | "pending") {
                pair.state.state = "cancelled".into();
                pair.digest = None;
                if let Some(request) = &mut pair.state.request {
                    request.state = "cancelled".into();
                }
            }
            self.hub.emit("host-stopping", serde_json::json!({}));
        }
        // Finish any bounded discovery child before the native shell calls exit().
        let _probe = self.probe_gate.lock().await;
        let result = self.processes.shutdown().await;
        self.set_network("stopped", None, None);
        result
    }
}
fn production_specs() -> Vec<AdapterSpec> {
    let mut specs = agent_adapters::discover_specs();
    for s in &mut specs {
        if s.id == "codex" {
            s.verified_version = Some("codex-cli 0.165.0".into());
        }
    }
    specs
}

#[cfg(all(test, unix))]
mod tests;
