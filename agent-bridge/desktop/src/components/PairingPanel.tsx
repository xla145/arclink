import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from "react";
import QRCode from "qrcode";
import { normalizeError, type Bridge } from "../bridge";
import type { BridgeError, PairSession, Snapshot } from "../types";
import { ErrorBanner } from "./Common";
import { Icon } from "./Icons";

const permissionLabels: Record<string, string> = {
  view: "查看 Agent 和进程",
  session: "启动与停止进程",
  task: "发送 Agent 输入",
  approval: "传递审批决定",
};
export interface PairingHandle {
  cancel: () => Promise<void>;
}

export const PairingPanel = forwardRef<
  PairingHandle,
  {
    api: Bridge;
    snapshot: Snapshot | null;
    onFinished: () => void;
    onBusyChange: (busy: boolean) => void;
  }
>(function PairingPanel({ api, snapshot, onFinished, onBusyChange }, ref) {
  const [session, setSession] = useState<PairSession | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [error, setError] = useState<BridgeError | null>(null);
  const [busy, setBusy] = useState(false);
  const [permissions, setPermissions] = useState<string[]>([
    "view",
    "session",
    "task",
    "approval",
  ]);
  const invitation = useRef<Promise<PairSession> | null>(null);
  const closing = useRef(false);
  const operation = useRef(false);
  useEffect(() => {
    onBusyChange(busy);
  }, [busy, onBusyChange]);
  useEffect(() => {
    let live = true;
    invitation.current ??= api.startPairing();
    void invitation.current
      .then(async (value) => {
        if (!live) return;
        setNow(Date.now());
        setSession(value);
        const data = await QRCode.toDataURL(value.qr_payload, {
          width: 240,
          margin: 2,
          errorCorrectionLevel: "M",
          color: { dark: "#111827", light: "#ffffff" },
        });
        if (live && !closing.current) setQr(data);
      })
      .catch((cause) => {
        if (live) setError(normalizeError(cause));
      });
    const timer = window.setInterval(() => setNow(Date.now()), 500);
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [api]);
  const seconds = session
    ? Math.max(0, Math.ceil((Date.parse(session.expires_at) - now) / 1000))
    : 120;
  const state =
    snapshot?.pairing.session_id === session?.session_id
      ? snapshot?.pairing
      : null;
  const request = state?.request?.state === "pending" ? state.request : null;
  const finish = useCallback(() => {
    closing.current = true;
    setQr(null);
    setSession(null);
    onFinished();
  }, [onFinished]);
  const cancel = useCallback(async () => {
    if (operation.current || closing.current) return;
    operation.current = true;
    setBusy(true);
    setError(null);
    try {
      // Null cancels the native-owned pending invitation if its response was lost.
      await api.cancelPairing(session?.session_id ?? null);
      finish();
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      operation.current = false;
      setBusy(false);
    }
  }, [api, finish, session]);
  useImperativeHandle(ref, () => ({ cancel }), [cancel]);
  useEffect(() => {
    if (!session || closing.current) return;
    if (state?.state === "approved") {
      setQr(null);
      const timer = window.setTimeout(finish, 1200);
      return () => window.clearTimeout(timer);
    }
    if (["expired", "cancelled", "rejected"].includes(state?.state ?? "")) {
      finish();
    } else if (seconds === 0) {
      setQr(null); // Never leave an expired QR visible, even if cancellation fails.
      void cancel();
    }
  }, [cancel, finish, seconds, session, state?.state]);
  async function decide(approve: boolean) {
    if (!request || operation.current) return;
    operation.current = true;
    setBusy(true);
    setError(null);
    try {
      if (approve)
        await api.approvePairing(
          request.request_id,
          permissions.filter((permission) =>
            request.permissions.includes(permission),
          ),
        );
      else await api.rejectPairing(request.request_id);
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      operation.current = false;
      setBusy(false);
    }
  }
  return (
    <div className="pairing-content">
      {error && <ErrorBanner error={error} />}
      {state?.state === "approved" ? (
        <div className="pair-success">
          <Icon name="check" size={36} />
          <h2>配对成功</h2>
          <p>设备现在可以连接这台主机。</p>
        </div>
      ) : request ? (
        <>
          <div className="pair-device">
            <span className="device-icon">
              <Icon name="phone" size={22} />
            </span>
            <h2>{request.name}</h2>
            <p>请求连接这台主机</p>
          </div>
          <code className="endpoint">{request.device_id}</code>
          <div className="permission-list">
            {request.permissions.map((permission) => (
              <label key={permission}>
                <input
                  type="checkbox"
                  checked={permissions.includes(permission)}
                  disabled={busy || permission === "view"}
                  onChange={(event) =>
                    setPermissions((current) => {
                      const group =
                        permission === "task" || permission === "approval"
                          ? ["task", "approval"]
                          : [permission];
                      return event.target.checked
                        ? [...new Set([...current, ...group])]
                        : current.filter((value) => !group.includes(value));
                    })
                  }
                />
                {permissionLabels[permission] ?? permission}
                {permission === "view" && (
                  <span className="subtle">（必选）</span>
                )}
              </label>
            ))}
          </div>
          <p className="subtle">
            任务与审批通过同一 Agent 输入通道传输，需一并授权。
          </p>
          <div className="dialog-actions">
            <button
              className="button secondary"
              disabled={busy}
              onClick={() => void decide(false)}
            >
              拒绝
            </button>
            <button
              className="button primary"
              disabled={busy || !permissions.includes("view") || seconds === 0}
              onClick={() => void decide(true)}
            >
              {busy ? "处理中…" : "确认配对"}
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="qr-frame">
            {qr && seconds > 0 ? (
              <img src={qr} width="216" height="216" alt="设备配对二维码" />
            ) : (
              <div className="qr-loading">
                {seconds === 0
                  ? "二维码已过期"
                  : error
                    ? "二维码暂不可用"
                    : "正在生成二维码…"}
              </div>
            )}
          </div>
          <div className="pairing-timer">
            二维码有效期{" "}
            <strong>
              {Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, "0")}
            </strong>
          </div>
          <p className="pairing-hint">使用兼容的 ArcLink 客户端扫描</p>
          <p className="subtle centered">扫描后仍需在这台主机确认授权</p>
        </>
      )}
      {state?.state !== "approved" && (
        <button
          className="button secondary full"
          disabled={busy}
          onClick={() => void cancel()}
        >
          取消配对
        </button>
      )}
    </div>
  );
});
