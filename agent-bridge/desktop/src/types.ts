// Wire contract: agentd::types. Snake-case enums/fields; u64 values are strings.
export interface BridgeError {
  code: string;
  message: string;
}
export interface AgentInfo {
  id: string;
  name: string;
  version: string | null;
  executable_path?: string | null;
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

export interface UpdateStatus {
  revision: string;
  current_version: string;
  phase:
    | "idle"
    | "checking"
    | "current"
    | "available"
    | "downloading"
    | "ready"
    | "installing"
    | "error";
  version: string | null;
  notes: string | null;
  downloaded: number;
  total: number | null;
  error: BridgeError | null;
  restart_required: boolean;
}

export interface KeepAwakeStatus {
  enabled: boolean;
  active: boolean;
  supported: boolean;
  error: BridgeError | null;
}
export interface RecentLogs {
  text: string;
  truncated: boolean;
}

export interface ManagedProject { id: string; name: string; canonical_root: string; created_at: string; updated_at: string }
export interface ManagedThread { id: string; project_id: string; provider_id: string; model?: string | null; title: string; cwd: string; status: string; revision: string; created_at: string; updated_at: string }
export interface ManagedMessage { id: string; thread_id: string; run_id: string | null; client_message_id: string | null; role: string; content: { text?: string; phase?: string; tool_name?: string; completed?: boolean; failed?: boolean; provider_id?: string; type?: string; from_provider_id?: string; to_provider_id?: string; model?: string | null }; revision: string }
export interface ManagedRun { id: string; thread_id: string; status: string; revision: string }
export interface ManagedApproval { id: string; run_id: string; state: string; kind: string; target: string; detail: string }
export interface ThreadSnapshot { environment_id: string; sequence: string; thread: ManagedThread; messages: ManagedMessage[]; runs: ManagedRun[]; approvals: ManagedApproval[]; has_older_messages: boolean }
export interface ThreadEvent { sequence: string; aggregate_id: string; event_type: string; schema_version: number; payload: unknown }
export interface ThreadReplay { environment_id: string; thread_id: string; sequence: string; events: ThreadEvent[]; has_more: boolean }
export interface ThreadHistory { thread_id: string; messages: ManagedMessage[]; has_more: boolean; next_before_id: string | null }
