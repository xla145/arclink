import arclinkIcon from "./assets/arclink-icon.svg";
import { useCallback, useEffect, useRef, useState } from "react";
import { bridge, normalizeError, type Bridge } from "./bridge";
import { useSnapshot } from "./hooks/useSnapshot";
import { useUptime } from "./hooks/useUptime";
import type { BridgeError, PairedDevice } from "./types";
import { Icon } from "./components/Icons";
import { AgentList } from "./components/AgentList";
import {
  ConfirmDialog,
  EmptyState,
  ErrorBanner,
  relativeTime,
} from "./components/Common";
import { PairingPanel, type PairingHandle } from "./components/PairingPanel";
import { SettingsPanel } from "./components/SettingsPanel";

export function App({
  api = bridge,
  initialPairing = false,
  preview = false,
}: {
  api?: Bridge;
  initialPairing?: boolean;
  preview?: boolean;
}) {
  const [tab, setTab] = useState<"devices" | "agents" | "processes">("devices");
  const [settings, setSettings] = useState(false);
  const [pairing, setPairing] = useState(initialPairing);
  const [pairingBusy, setPairingBusy] = useState(false);
  const pairingRef = useRef<PairingHandle>(null);
  const [error, setError] = useState<BridgeError | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [revoke, setRevoke] = useState<PairedDevice | null>(null);
  const [exit, setExit] = useState(false);
  const openSettings = useCallback(() => setSettings(true), []);
  const confirmExit = useCallback(() => setExit(true), []);
  const {
    snapshot,
    error: loadError,
    loading,
    refresh,
  } = useSnapshot(api, openSettings, confirmExit);
  const finishPairing = useCallback(() => {
    setPairing(false);
    setPairingBusy(false);
    setSettings(false);
    setTab("devices");
    void refresh();
  }, [refresh]);
  const beginPairing = () => {
    setError(null);
    setPairing(true);
  };
  const cancelRevoke = useCallback(() => setRevoke(null), []);
  const cancelExit = useCallback(() => setExit(false), []);
  async function action(key: string, operation: () => Promise<unknown>) {
    if (busy) return;
    setBusy(key);
    setError(null);
    try {
      await operation();
      await refresh();
    } catch (cause) {
      setError(normalizeError(cause));
      await refresh();
    } finally {
      setBusy(null);
    }
  }
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || revoke || exit) return;
      if (pairing) void pairingRef.current?.cancel();
      else if (settings) setSettings(false);
      else void api.hide().catch((cause) => setError(normalizeError(cause)));
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, [api, pairing, settings, revoke, exit]);
  const network = snapshot?.status.network;
  const running = snapshot?.status.running ?? false;
  const networkError =
    network?.state === "error"
      ? {
          code: "network_error",
          message: network.detail ?? "网络连接失败，请重试或查看日志。",
        }
      : null;
  const shownError = error ?? loadError ?? networkError;
  const processes =
    snapshot?.processes.filter((process) =>
      ["starting", "running", "stopping"].includes(process.state),
    ) ?? [];
  const uptime = useUptime(snapshot);
  const uptimeLabel =
    uptime >= 3600
      ? `${Math.floor(uptime / 3600)}h ${Math.floor((uptime % 3600) / 60)}m`
      : uptime >= 60
        ? `${Math.floor(uptime / 60)}m`
        : `${uptime}s`;
  return (
    <main className="shell">
      {preview && <div className="preview-label">界面预览 · 示例数据</div>}
      <header className="panel header-panel">
        <div className="header">
          <div className="header-left">
            {settings || pairing ? (
              <button
                className="icon-button"
                aria-label={pairing ? "返回设备列表" : "返回面板"}
                disabled={pairingBusy}
                onClick={() =>
                  pairing
                    ? void pairingRef.current?.cancel()
                    : setSettings(false)
                }
              >
                <Icon name="arrow" />
              </button>
            ) : (
              <div className="logo">
                <img src={arclinkIcon} width={28} height={28} alt="" />
              </div>
            )}
            <h1>{pairing ? "配对新设备" : settings ? "设置" : "ArcLink"}</h1>
          </div>
          {!pairing && !settings && (
            <button
              className="icon-button"
              aria-label="设置"
              onClick={() => setSettings(true)}
            >
              <Icon name="settings" />
            </button>
          )}
        </div>
        {!pairing && !settings && (
          <>
            <div className="status-bar" aria-live="polite">
              <span
                className={`status-dot ${running && network?.state !== "error" ? "online" : loading || network?.state === "starting" ? "connecting" : "offline"}`}
              />
              <span>
                {loading
                  ? "正在启动"
                  : running
                    ? network?.state === "error"
                      ? "网络异常"
                      : "运行中"
                    : "服务不可用"}
              </span>
              <span className="status-detail">
                {snapshot?.status.connected_devices
                  ? `${snapshot.status.connected_devices} 台在线`
                  : network?.state === "ready"
                    ? "等待连接"
                    : network?.state === "starting"
                      ? "连接中"
                      : "未连接"}
              </span>
            </div>
            <nav className="view-tabs" aria-label="面板视图">
              {(["devices", "agents", "processes"] as const).map((value) => (
                <button
                  key={value}
                  className={`view-tab ${tab === value ? "active" : ""}`}
                  aria-current={tab === value ? "page" : undefined}
                  onClick={() => setTab(value)}
                >
                  {value === "devices"
                    ? "设备"
                    : value === "agents"
                      ? "Agent"
                      : "进程"}
                  {value === "processes" && processes.length > 0 && (
                    <span className="tab-count">{processes.length}</span>
                  )}
                </button>
              ))}
            </nav>
          </>
        )}
      </header>
      <div className="scroll-content">
        {!pairing && shownError && (
          <section className="panel">
            <ErrorBanner
              error={shownError}
              onRetry={() =>
                void action("retry", async () => {
                  await api.retry();
                  await refresh();
                })
              }
              onLogs={() => void action("logs", api.openLogs)}
            />
          </section>
        )}
        {pairing ? (
          <section className="panel">
            <PairingPanel
              ref={pairingRef}
              api={api}
              snapshot={snapshot}
              onFinished={finishPairing}
              onBusyChange={setPairingBusy}
            />
          </section>
        ) : settings ? (
          snapshot ? (
            <section className="panel">
              <SettingsPanel
                api={api}
                snapshot={snapshot}
                onExit={() => setExit(true)}
                onSaved={() => void refresh()}
              />
            </section>
          ) : (
            <section className="panel">
              <p className="subtle">服务启动后可修改设置。</p>
              <button
                className="button secondary full"
                onClick={() => setExit(true)}
              >
                退出应用
              </button>
            </section>
          )
        ) : loading && !snapshot ? (
          <section className="panel">
            <div className="loading-state">
              <span className="spinner" />
              <p>正在连接本机服务…</p>
            </div>
          </section>
        ) : (
          snapshot && (
            <>
              {tab === "devices" && (
                <section className="panel">
                  {snapshot.devices.length ? (
                    <>
                      <div className="section-head">
                        <h2>已配对设备</h2>
                        <button
                          className="text-button"
                          disabled={!!busy || network?.state !== "ready"}
                          onClick={beginPairing}
                        >
                          + 配对
                        </button>
                      </div>
                      <div className="device-list">
                        {snapshot.devices.map((device) => (
                          <div className="device-card" key={device.device_id}>
                            <span className="device-icon">
                              <Icon name="phone" />
                            </span>
                            <div className="device-info">
                              <div className="name" title={device.name}>
                                {device.name}
                              </div>
                              <div className="device-meta">
                                <span
                                  className={`status-dot ${device.connection === "online" ? "online" : "offline"}`}
                                />
                                {device.connection === "online"
                                  ? device.path_kind === "direct"
                                    ? "直连"
                                    : device.path_kind === "relay"
                                      ? "中继"
                                      : "在线"
                                  : "离线"}{" "}
                                · {relativeTime(device.last_seen)}
                              </div>
                            </div>
                            <button
                              className="icon-button revoke-button"
                              aria-label={`撤销 ${device.name} 的访问`}
                              onClick={() => setRevoke(device)}
                            >
                              <Icon name="close" size={13} />
                            </button>
                          </div>
                        ))}
                      </div>
                    </>
                  ) : (
                    <EmptyState
                      title="尚未配对任何设备"
                      description="连接你的手机，让本机 Agent 随时为你工作。"
                    >
                      <button
                        className="button primary full"
                        disabled={!!busy || network?.state !== "ready"}
                        onClick={beginPairing}
                      >
                        配对新设备
                      </button>
                    </EmptyState>
                  )}
                </section>
              )}
              {tab === "agents" && (
                <section className="panel">
                  <div className="section-head">
                    <h2>已发现 Agent</h2>
                    <button
                      className="text-button"
                      disabled={!!busy}
                      onClick={() => void action("refresh", api.refreshAgents)}
                    >
                      {busy === "refresh" ? "检测中…" : "刷新"}
                    </button>
                  </div>
                  <AgentList agents={snapshot.agents} />
                  <p className="section-note">
                    仅经过协议验证的版本可接受远程控制。
                  </p>
                </section>
              )}
              {tab === "devices" && !snapshot.devices.length && (
                <section className="panel">
                  <div className="section-head">
                    <h2>已发现 Agent</h2>
                    <button
                      className="text-button"
                      onClick={() => setTab("agents")}
                    >
                      查看全部
                    </button>
                  </div>
                  <AgentList agents={snapshot.agents.slice(0, 2)} compact />
                </section>
              )}
              {tab === "processes" && (
                <section className="panel">
                  <div className="section-head">
                    <h2>活跃进程</h2>
                    <span className="subtle">{processes.length} 个运行中</span>
                  </div>
                  {processes.length ? (
                    <div className="process-list">
                      {processes.map((process) => (
                        <div
                          className="process-card"
                          key={`${process.process_id}:${process.generation}`}
                        >
                          <div className="process-top">
                            <span className="name">
                              {snapshot.agents.find(
                                (agent) => agent.id === process.agent_id,
                              )?.name ?? process.agent_id}
                            </span>
                            <code>PID {process.pid ?? "—"}</code>
                          </div>
                          <div className="process-meta">
                            <span className="status-dot online" />
                            {process.state === "running"
                              ? "进程运行中"
                              : process.state === "stopping"
                                ? "正在停止"
                                : "正在启动"}
                          </div>
                          <p className="subtle">
                            由{" "}
                            {snapshot.devices.find(
                              (device) =>
                                device.device_id === process.owner_device_id,
                            )?.name ?? "已授权设备"}{" "}
                            启动
                          </p>
                        </div>
                      ))}
                    </div>
                  ) : (
                    <EmptyState
                      title="暂无活跃进程"
                      description="从已配对的客户端启动 Agent 后，可在这里查看进程状态。"
                      icon="terminal"
                    />
                  )}
                </section>
              )}
            </>
          )
        )}
      </div>
      {!pairing && (
        <footer className="panel footer">
          <span>agentd · {running ? `运行 ${uptimeLabel}` : "等待启动"}</span>
          <button
            className="text-button"
            disabled={!!busy}
            onClick={() => void action("logs", api.openLogs)}
          >
            查看日志
          </button>
        </footer>
      )}
      {revoke && (
        <ConfirmDialog
          title="撤销设备访问"
          confirm="撤销"
          busy={busy === "revoke"}
          onCancel={cancelRevoke}
          onConfirm={() =>
            void action("revoke", async () => {
              await api.revokeDevice(revoke.device_id);
              setRevoke(null);
            })
          }
        >
          <p>
            确定撤销 <strong>{revoke.name}</strong> 的访问权限？
          </p>
          <ul>
            <li>将立即断开当前连接</li>
            <li>正在运行的 Agent 进程不会停止，但该设备无法继续控制</li>
            <li>需要重新配对才能连接</li>
          </ul>
          {error && (
            <p role="alert" className="danger-text">
              {error.message}
            </p>
          )}
        </ConfirmDialog>
      )}
      {exit && (
        <ConfirmDialog
          title="退出 ArcLink"
          confirm="退出应用"
          busy={busy === "exit"}
          onCancel={cancelExit}
          onConfirm={() => void action("exit", () => api.exit(true))}
        >
          <p>
            {processes.length
              ? `当前 ${processes.length} 个 Agent 进程将被停止，已连接设备会断开。`
              : "本机服务将停止，已连接设备会断开。"}
          </p>
          {error && (
            <p role="alert" className="danger-text">
              {error.message}
            </p>
          )}
        </ConfirmDialog>
      )}
    </main>
  );
}
