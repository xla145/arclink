import type { BridgeError, UpdateStatus } from "../types";
import { ErrorBanner } from "./Common";

export function UpdatePanel({
  status,
  error,
  disabled,
  onCheck,
  onDownload,
  onInstall,
}: {
  status: UpdateStatus | null;
  error: BridgeError | null;
  disabled: boolean;
  onCheck: () => void;
  onDownload: () => void;
  onInstall: () => void;
}) {
  const phase = status?.phase;
  const busy =
    disabled ||
    phase === "checking" ||
    phase === "downloading" ||
    phase === "installing";
  const labels: Record<UpdateStatus["phase"], string> = {
    idle: "尚未检查更新",
    checking: "正在检查更新…",
    current: "已是最新版本",
    available: `发现新版本 ${status?.version ?? ""}`,
    downloading: "正在下载并验证更新…",
    ready: `更新 ${status?.version ?? ""} 已就绪`,
    installing: "正在安装，即将重启…",
    error: "更新未完成",
  };
  return (
    <div className="field update-panel" aria-label="软件更新">
      <label>软件更新{status ? ` · ${status.current_version}` : ""}</label>
      <p role="status">{phase ? labels[phase] : "正在读取更新状态…"}</p>
      {(error ?? status?.error) && (
        <ErrorBanner error={(error ?? status?.error)!} />
      )}
      {status?.notes && (
        <details>
          <summary>版本说明</summary>
          <p className="update-notes">{status.notes}</p>
        </details>
      )}
      {phase === "downloading" && (
        <>
          <progress
            aria-label="更新下载进度"
            value={status?.total ? status.downloaded : undefined}
            max={status?.total || undefined}
          />
          <span className="subtle">
            已下载 {Math.floor((status?.downloaded ?? 0) / 1024 / 1024)} MB
          </span>
        </>
      )}
      {status?.restart_required && (
        <p className="danger-text">
          本机服务已停止，请重试安装或退出后重新打开。
        </p>
      )}
      <div className="inline-actions">
        <button
          className="button secondary"
          disabled={busy || status?.restart_required}
          onClick={onCheck}
        >
          检查更新
        </button>
        {(phase === "available" ||
          (phase === "error" &&
            status?.version &&
            !status.restart_required)) && (
          <button
            className="button primary"
            disabled={busy}
            onClick={onDownload}
          >
            下载更新
          </button>
        )}
        {(phase === "ready" || status?.restart_required) && (
          <button
            className="button primary"
            disabled={busy}
            onClick={onInstall}
          >
            安装并重启
          </button>
        )}
      </div>
    </div>
  );
}
