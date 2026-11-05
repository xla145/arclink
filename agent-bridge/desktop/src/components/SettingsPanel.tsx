import { useEffect, useState, type ReactNode } from "react";
import { normalizeError, type Bridge } from "../bridge";
import type {
  AppSettings,
  BridgeError,
  KeepAwakeStatus,
  Snapshot,
} from "../types";
import { ErrorBanner } from "./Common";

export function SettingsPanel({
  api,
  snapshot,
  onExit,
  onSaved,
  onLogs,
  application,
}: {
  api: Bridge;
  snapshot: Snapshot;
  onExit: () => void;
  onSaved: () => void;
  onLogs: () => void;
  application?: ReactNode;
}) {
  const [settings, setSettings] = useState<AppSettings>(snapshot.settings);
  const [autostart, setAutostart] = useState<boolean | null>(null);
  const [awake, setAwake] = useState<KeepAwakeStatus | null>(null);
  const [awakeLoading, setAwakeLoading] = useState(true);
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
    const readAwake = () => {
      setAwakeLoading(true);
      void api
        .getKeepAwake()
        .then((status) => {
          if (live) setAwake(status);
        })
        .catch((cause) => {
          if (live) setError(normalizeError(cause));
        })
        .finally(() => {
          if (live) setAwakeLoading(false);
        });
    };
    readAwake();
    window.addEventListener("focus", readAwake);
    return () => {
      live = false;
      window.removeEventListener("focus", readAwake);
    };
  }, [api]);
  async function reloadAwake() {
    setAwakeLoading(true);
    setError(null);
    try {
      setAwake(await api.getKeepAwake());
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      setAwakeLoading(false);
    }
  }
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
  async function toggleAwake() {
    if (!awake) return;
    setBusy(true);
    setError(null);
    try {
      setAwake(await api.setKeepAwake(!awake.enabled));
    } catch (cause) {
      setError(normalizeError(cause));
      try {
        setAwake(await api.getKeepAwake());
      } catch {
        setAwake(null);
      }
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="settings-content">
      {error && <ErrorBanner error={error} />}
      <h2 className="settings-heading">通用</h2>
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
      <div className="setting-row">
        <div>
          <strong>保持电脑活跃</strong>
          <p>防止自动休眠，允许熄屏和锁屏</p>
        </div>
        <button
          type="button"
          role="switch"
          aria-label="保持电脑活跃"
          aria-checked={awake?.enabled ?? false}
          className={`switch ${awake?.enabled ? "enabled" : ""}`}
          disabled={busy || awakeLoading || !awake?.supported}
          onClick={() => void toggleAwake()}
        >
          <span />
        </button>
      </div>
      <p className="subtle" role="status">
        {awakeLoading
          ? "正在读取保持活跃状态…"
          : !awake
            ? "未能读取保持活跃状态"
            : !awake.supported
              ? "当前系统暂不支持保持活跃"
              : awake.active
                ? "已生效 · ArcLink 运行期间保持电脑活跃"
                : awake.enabled
                  ? "已开启偏好，但当前未生效"
                  : "关闭时遵循系统休眠设置"}
      </p>
      {!awake && !awakeLoading && (
        <button className="text-button" onClick={() => void reloadAwake()}>
          重试读取保持活跃状态
        </button>
      )}
      {awake?.error && <ErrorBanner error={awake.error} />}
      <h2 className="settings-heading">连接</h2>
      <div className="field">
        <label>连接方式</label>
        <strong>自动连接 · 优先直连</strong>
        <p className="subtle">
          手机扫码即可连接，直连不可用时自动使用中继，无需填写地址或密钥。
        </p>
      </div>
      <div className="field">
        <label>连接身份</label>
        <code className="endpoint">
          {snapshot.status.network.endpoint_id ?? "等待网络服务启动"}
        </code>
        <p className="subtle">仅向你信任的设备授予访问权限。</p>
      </div>
      <h2 className="settings-heading">诊断</h2>
      <button className="settings-link" onClick={onLogs}>
        <span>
          <strong>运行日志</strong>
          <small>查看最近记录、复制或导出</small>
        </span>
        <span aria-hidden="true">›</span>
      </button>
      <h2 className="settings-heading">应用</h2>
      {application}
      <div className="setting-row">
        <span className="subtle">ArcLink</span>
        <button className="text-button danger-text" onClick={onExit}>
          退出应用
        </button>
      </div>
    </div>
  );
}
