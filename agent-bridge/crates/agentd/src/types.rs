pub use agent_adapters::AgentInfo;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}
impl BridgeError {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}
impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for BridgeError {}
pub type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NetworkInfo {
    pub state: String,
    pub endpoint_id: Option<String>,
    pub detail: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DaemonStatus {
    pub running: bool,
    pub uptime_secs: u32,
    pub network: NetworkInfo,
    pub active_processes: u32,
    pub connected_devices: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PairedDevice {
    pub device_id: String,
    pub name: String,
    pub paired_at: String,
    pub last_seen: Option<String>,
    pub connection: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path_kind: Option<String>,
    pub permissions: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProcessInfo {
    pub process_id: String,
    pub generation: String,
    pub agent_id: String,
    pub owner_device_id: String,
    pub pid: Option<u32>,
    pub state: String,
    pub started_at: String,
    pub exit_code: Option<i32>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppSettings {
    pub device_name: String,
}
impl Default for AppSettings {
    fn default() -> Self {
        Self {
            device_name: "ArcLink".into(),
        }
    }
}
/// A transient pairing-window response. Never emit this in events or logs.
#[derive(Clone, Serialize, Deserialize)]
pub struct PairSession {
    pub session_id: String,
    pub endpoint_id: String,
    pub token: String,
    pub expires_at: String,
    pub qr_payload: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PairRequest {
    pub request_id: String,
    pub session_id: String,
    pub device_id: String,
    pub name: String,
    pub permissions: Vec<String>,
    pub expires_at: String,
    pub state: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PairingState {
    pub session_id: Option<String>,
    pub expires_at: Option<String>,
    pub request: Option<PairRequest>,
    pub state: String,
}
impl Default for PairingState {
    fn default() -> Self {
        Self {
            session_id: None,
            expires_at: None,
            request: None,
            state: "idle".into(),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub service_instance: String,
    pub revision: String,
    pub status: DaemonStatus,
    pub agents: Vec<AgentInfo>,
    pub devices: Vec<PairedDevice>,
    pub processes: Vec<ProcessInfo>,
    pub pairing: PairingState,
    pub settings: AppSettings,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DaemonEvent {
    pub service_instance: String,
    pub revision: String,
    pub kind: String,
    pub payload: serde_json::Value,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputFrame {
    pub channel: String,
    pub offset: String,
    pub data: Vec<u8>,
    pub gap: bool,
}

pub(crate) fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
pub(crate) fn storage_error(_: impl std::fmt::Display) -> BridgeError {
    BridgeError::new(
        "storage_error",
        "Local metadata storage is unavailable. Check the application data directory.",
    )
}
pub(crate) fn invalid(message: &str) -> BridgeError {
    BridgeError::new("invalid_params", message)
}
pub(crate) fn validate_id(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        Err(invalid(
            "Identifier is empty, too long or contains control characters.",
        ))
    } else {
        Ok(())
    }
}
pub(crate) fn validate_name(value: &str) -> Result<()> {
    if value.trim().is_empty() || value.chars().count() > 80 || value.chars().any(char::is_control)
    {
        Err(invalid("Name must contain 1 to 80 printable characters."))
    } else {
        Ok(())
    }
}
