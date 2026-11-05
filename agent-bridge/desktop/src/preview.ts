// Imported only behind import.meta.env.DEV in main.tsx. Never used as a runtime fallback.
import type { Bridge } from "./bridge";
import type { Snapshot } from "./types";

export function previewBridge(state: string): Bridge {
  const snapshot: Snapshot = {
    service_instance: "preview",
    revision: "1",
    status: {
      running: true,
      uptime_secs: 15780,
      network: {
        state: state === "error" ? "error" : "ready",
        endpoint_id: "preview-endpoint-not-a-real-device",
        detail:
          state === "error" ? "iroh 端点连接中断，请检查网络后重试。" : null,
      },
      active_processes: state === "empty" ? 0 : 1,
      connected_devices: state === "empty" || state === "error" ? 0 : 1,
    },
    agents: [
      {
        id: "claude",
        name: "Claude Code",
        version: "2.1.314",
        status: "version_mismatch",
        validation: "unverified",
        capabilities: [],
        diagnostic: "当前版本尚未验证控制能力。",
      },
      {
        id: "codex",
        name: "Codex CLI",
        version: "0.165.0",
        status: state === "empty" ? "available" : "running",
        validation: "verified",
        capabilities: ["stdio"],
        diagnostic: null,
      },
      {
        id: "herdr",
        name: "Herdr",
        version: null,
        status: "not_found",
        validation: "unverified",
        capabilities: [],
        diagnostic: null,
      },
    ],
    devices:
      state === "empty"
        ? []
        : [
            {
              device_id: "preview-phone",
              name: "iPhone 16 Pro",
              paired_at: new Date().toISOString(),
              last_seen: new Date().toISOString(),
              connection: state === "error" ? "offline" : "online",
              permissions: ["view", "session", "task", "approval"],
            },
            {
              device_id: "preview-tablet",
              name: "iPad Air",
              paired_at: new Date().toISOString(),
              last_seen: new Date(Date.now() - 7200000).toISOString(),
              connection: "offline",
              permissions: ["view"],
            },
          ],
    processes:
      state === "empty"
        ? []
        : [
            {
              process_id: "preview-process",
              generation: "1",
              agent_id: "codex",
              owner_device_id: "preview-phone",
              pid: 4521,
              state: "running",
              started_at: new Date().toISOString(),
              exit_code: null,
            },
          ],
    pairing: {
      session_id: null,
      expires_at: null,
      request: null,
      state: "idle",
    },
    settings: { device_name: "MacBook Pro" },
  };
  const unavailable = async (): Promise<never> => {
    throw { code: "preview", message: "这是界面预览，操作不会修改本机服务。" };
  };
  return {
    updateStatus: unavailable,
    checkUpdate: unavailable,
    downloadUpdate: unavailable,
    installUpdate: unavailable,
    snapshot: async () => snapshot,
    subscribe: async () => () => {},
    refreshAgents: unavailable,
    startPairing: async () => ({
      session_id: "preview-pair",
      endpoint_id: "preview",
      token: "preview-not-a-real-token",
      expires_at: new Date(Date.now() + 120000).toISOString(),
      qr_payload: "agent-bridge:preview-only-not-a-pairing-invitation",
    }),
    cancelPairing: async () => {},
    approvePairing: unavailable,
    rejectPairing: unavailable,
    revokeDevice: unavailable,
    updateSettings: unavailable,
    getNetworkSettings: async () => ({
      enabled: false,
      relay_url: "https://iroh.classktv.com/",
      has_access_key: false,
    }),
    updateNetworkSettings: unavailable,
    getAutostart: async () => ({ enabled: false }),
    setAutostart: unavailable,
    getKeepAwake: async () => ({
      enabled: false,
      active: false,
      supported: true,
      error: null,
    }),
    setKeepAwake: unavailable,
    recentLogs: async () => ({
      text:
        state === "empty"
          ? ""
          : "[示例] ArcLink 本机服务已启动\n[示例] 等待设备连接\n",
      truncated: false,
    }),
    copyLogs: unavailable,
    exportLogs: unavailable,
    openLogs: unavailable,
    retry: unavailable,
    hide: unavailable,
    exit: unavailable,
  };
}
