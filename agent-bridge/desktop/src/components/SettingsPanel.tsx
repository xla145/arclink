import { useEffect, useState } from "react";
import { normalizeError, type Bridge } from "../bridge";
import type { AppSettings, BridgeError, Snapshot } from "../types";
import { ErrorBanner } from "./Common";

export function SettingsPanel({
  api,
  snapshot,
  onExit,
  onSaved,
}: {
  api: Bridge;
  snapshot: Snapshot;
  onExit: () => void;
  onSaved: () => void;
}) {
  const [settings, setSettings] = useState<AppSettings>(snapshot.settings);
  const [autostart, setAutostart] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<BridgeError | null>(null);
  useEffect(() => {
    let live = true;
    void api
      .getAutostart()
      .then((status) => {
        if (live) setAutostart(status.enabled);
      })
      .catch((cause) => {
        if (live) setError(normalizeError(cause));
      });
    return () => {
      live = false;
    };
  }, [api]);
  async function save() {
    setBusy(true);
    setSaved(false);
    setError(null);
    try {
      await api.updateSettings({ device_name: settings.device_name.trim() });
      setSaved(true);
      onSaved();
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      setBusy(false);
    }
  }
  async function toggleAutostart() {
    if (autostart === null) return;
    setBusy(true);
    setError(null);
    try {
      const result = await api.setAutostart(!autostart);
      setAutostart(result.enabled);
    } catch (cause) {
      setError(normalizeError(cause));
      try {
        setAutostart((await api.getAutostart()).enabled);
      } catch {
        setAutostart(null);
      }
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="settings-content">
      {error && <ErrorBanner error={error} />}
      <div className="field">
        <label htmlFor="device-name">主机名称</label>
        <input
          id="device-name"
          value={settings.device_name}
          maxLength={64}
          onChange={(event) => {
            setSettings({ device_name: event.target.value });
            setSaved(false);
          }}
        />
        <button
          className="button secondary"
          onClick={() => void save()}
          disabled={
            busy ||
            !settings.device_name.trim() ||
            settings.device_name === snapshot.settings.device_name
          }
        >
          {saved ? "已保存" : busy ? "保存中…" : "保存名称"}
        </button>
      </div>
      <div className="setting-row">
        <div>
          <strong>登录时启动</strong>
          <p>登录后在菜单栏保持可用</p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={autostart ?? false}
          aria-label="登录时启动"
          className={`switch ${autostart ? "enabled" : ""}`}
          disabled={busy || autostart === null}
          onClick={() => void toggleAutostart()}
        >
          <span />
        </button>
      </div>
      {autostart === null && <p className="subtle">尚未读取系统登录启动状态</p>}
      <div className="field">
        <label>连接身份</label>
        <code className="endpoint">
          {snapshot.status.network.endpoint_id ?? "等待网络服务启动"}
        </code>
        <p className="subtle">仅向你信任的设备授予访问权限。</p>
      </div>
      <div className="setting-row">
        <span className="subtle">Agent Bridge 0.1.0</span>
        <button className="text-button danger-text" onClick={onExit}>
          退出应用
        </button>
      </div>
    </div>
  );
}
