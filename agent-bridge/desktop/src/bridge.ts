import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type {
  KeepAwakeStatus,
  RecentLogs,
  UpdateStatus,
  NetworkSettings,
  NetworkUpdate,
  AppSettings,
  AutostartStatus,
  BridgeError,
  PairSession,
  Snapshot,
} from "./types";

export function normalizeError(error: unknown): BridgeError {
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return {
      code:
        "code" in error && typeof error.code === "string"
          ? error.code
          : "unknown",
      message: error.message,
    };
  }
  return {
    code: "unknown",
    message: typeof error === "string" ? error : "操作失败，请重试或查看日志。",
  };
}

async function call<T>(
  command: string,
  args?: Record<string, unknown>,
): Promise<T> {
  if (!isTauri())
    throw {
      code: "desktop_required",
      message: "请在 ArcLink 桌面客户端中打开。浏览器无法访问本机服务。",
    } satisfies BridgeError;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    // A user may leave the native save dialog open beyond the normal IPC timeout.
    if (command === "export_recent_logs") return await invoke<T>(command, args);
    return await Promise.race([
      invoke<T>(command, args),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () =>
            reject({
              code:
                command.startsWith("get_") || command === "refresh_agents"
                  ? "timeout"
                  : "outcome_unknown",
              message: "操作超时，结果尚不确定。请刷新状态后再决定是否重试。",
            } satisfies BridgeError),
          30_000,
        );
      }),
    ]);
  } catch (error) {
    throw normalizeError(error);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

export const bridge = {
  updateStatus: () => call<UpdateStatus>("get_update_status"),
  checkUpdate: (startup = false) =>
    call<UpdateStatus>("check_for_update", { startup }),
  downloadUpdate: (version: string) =>
    call<UpdateStatus>("download_update", { version }),
  installUpdate: (version: string, confirmed: boolean) =>
    call<UpdateStatus>("install_update", { version, confirmed }),
  snapshot: () => call<Snapshot>("get_snapshot"),
  refreshAgents: () => call<void>("refresh_agents"),
  startPairing: () => call<PairSession>("start_pairing"),
  cancelPairing: (sessionId: string | null) =>
    call<void>("cancel_pairing", { sessionId }),
  approvePairing: (requestId: string, permissions: string[]) =>
    call<void>("approve_pairing", { requestId, permissions }),
  rejectPairing: (requestId: string) =>
    call<void>("reject_pairing", { requestId }),
  revokeDevice: (deviceId: string) => call<void>("revoke_device", { deviceId }),
  updateSettings: (settings: AppSettings) =>
    call<void>("update_settings", { settings }),
  getNetworkSettings: () => call<NetworkSettings>("get_network_settings"),
  updateNetworkSettings: (settings: NetworkUpdate) =>
    call<NetworkSettings>("update_network_settings", { settings }),
  getAutostart: () => call<AutostartStatus>("get_autostart"),
  setAutostart: (enabled: boolean) =>
    call<AutostartStatus>("set_autostart", { enabled }),
  getKeepAwake: () => call<KeepAwakeStatus>("get_keep_awake"),
  setKeepAwake: (enabled: boolean) =>
    call<KeepAwakeStatus>("set_keep_awake", { enabled }),
  recentLogs: () => call<RecentLogs>("get_recent_logs"),
  copyLogs: () => call<void>("copy_recent_logs"),
  exportLogs: () => call<boolean>("export_recent_logs"),
  openLogs: () => call<void>("open_logs"),
  retry: () => call<void>("retry_daemon"),
  hide: () => call<void>("hide_panel"),
  exit: (confirmed: boolean) => call<void>("request_exit", { confirmed }),
  subscribe: async (
    onSnapshot: (snapshot: Snapshot) => void,
    onChanged: () => void,
    onSettings: () => void,
    onExit: () => void,
  ) => {
    if (!isTauri()) return () => {};
    const cleanup: Array<() => void> = [];
    try {
      cleanup.push(
        await listen<Snapshot>("bridge-snapshot", (event) =>
          onSnapshot(event.payload),
        ),
      );
      cleanup.push(await listen("bridge-changed", onChanged));
      cleanup.push(await listen("show-settings", onSettings));
      cleanup.push(await listen("confirm-exit", onExit));
      return () => cleanup.forEach((unlisten) => unlisten());
    } catch (error) {
      cleanup.forEach((unlisten) => unlisten());
      throw normalizeError(error);
    }
  },
};

export type Bridge = typeof bridge;
