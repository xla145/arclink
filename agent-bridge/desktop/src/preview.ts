// Imported only behind import.meta.env.DEV in main.tsx. Never used as a runtime fallback.
import type { Bridge } from "./bridge";
import type { Snapshot, ThreadSnapshot } from "./types";

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
  const managed: ThreadSnapshot = { environment_id: "preview", sequence: "1", thread: { id: "preview-thread", project_id: "preview-project", provider_id: "codex", title: "检查项目构建", cwd: "/Users/demo/project", status: "idle", revision: "1", created_at: "now", updated_at: "now" }, messages: [{ id: "user", thread_id: "preview-thread", run_id: "run", client_message_id: "input", role: "user", content: { text: "检查构建配置，并解释需要修改的地方。" }, revision: "1" }, { id: "answer", thread_id: "preview-thread", run_id: "run", client_message_id: null, role: "assistant", content: { text: "示例回复：项目构建已完成。手机和 Mac 会显示同一份消息记录。" }, revision: "1" }], runs: [], approvals: [], has_older_messages: false };
  return {
    managedEnvironment: async () => ({ capabilities: ["managed_execution_v1", "managed_claude_v1"] }),
    managedProjects: async () => state === "managed" ? [{ id: "preview-project", name: "ArcLink 示例项目", canonical_root: "/Users/demo/project", created_at: "now", updated_at: "now" }] : [],
    managedCreateProject: unavailable,
    managedShareProject: unavailable,
    managedThreads: async () => state === "managed" ? [managed.thread] : [],
    managedCreateThread: async (_commandId: string, _projectId: string, _title: string, _providerId?: string) => unavailable(),
    managedSnapshot: async () => managed,
    managedWait: async () => { await new Promise(resolve => setTimeout(resolve, 20000)); return { environment_id: "preview", thread_id: "preview-thread", sequence: "1", events: [], has_more: false }; },
    managedHistory: unavailable,
    managedSend: unavailable,
    managedInterrupt: unavailable,
    managedApproval: unavailable,
    managedProviderSet: unavailable,
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
