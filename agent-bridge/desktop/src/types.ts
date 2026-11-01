// Wire contract: agentd::types. Snake-case enums/fields; u64 values are strings.
export interface BridgeError {
  code: string;
  message: string;
}
export interface AgentInfo {
  id: string;
  name: string;
  version: string | null;
  status:
    | "not_found"
    | "installed"
    | "available"
    | "running"
    | "version_mismatch"
    | "probe_failed";
  validation: "unverified" | "verified" | "failed";
  capabilities: string[];
  diagnostic: string | null;
}
export interface NetworkInfo {
  state: "starting" | "ready" | "error" | "stopped";
  endpoint_id: string | null;
  detail: string | null;
}
export interface DaemonStatus {
  running: boolean;
  uptime_secs: number;
  network: NetworkInfo;
  active_processes: number;
  connected_devices: number;
}
export interface PairedDevice {
  device_id: string;
  name: string;
  paired_at: string;
  last_seen: string | null;
  connection: string;
  path_kind?: "direct" | "relay" | "unknown" | null;
  permissions: string[];
}
export interface ProcessInfo {
  process_id: string;
  generation: string;
  agent_id: string;
  owner_device_id: string;
  pid: number | null;
  state: string;
  started_at: string;
  exit_code: number | null;
}
export interface AppSettings {
  device_name: string;
}
export interface PairSession {
  session_id: string;
  endpoint_id: string;
  token: string;
  expires_at: string;
  qr_payload: string;
}
export interface PairRequest {
  request_id: string;
  session_id: string;
  device_id: string;
  name: string;
  permissions: string[];
  expires_at: string;
  state: string;
}
export interface PairingState {
  session_id: string | null;
  expires_at: string | null;
  request: PairRequest | null;
  state: string;
}
export interface Snapshot {
  service_instance: string;
  revision: string;
  status: DaemonStatus;
  agents: AgentInfo[];
  devices: PairedDevice[];
  processes: ProcessInfo[];
  pairing: PairingState;
  settings: AppSettings;
}
export interface AutostartStatus {
  enabled: boolean;
}

export interface NetworkSettings {
  enabled: boolean;
  relay_url: string;
  has_access_key: boolean;
}
export interface NetworkUpdate {
  enabled: boolean;
  relay_url: string;
  access_key: string | null;
}
