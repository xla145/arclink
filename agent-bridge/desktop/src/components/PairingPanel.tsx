import { useEffect, useRef, useState } from "react";
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
export function PairingPanel({
  api,
  snapshot,
}: {
  api: Bridge;
  snapshot: Snapshot | null;
}) {
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
  useEffect(() => {
    let live = true;
    invitation.current ??= api.startPairing();
    void invitation.current
      .then(async (value) => {
        if (!live) return;
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
  useEffect(() => {
    if (!session || closing.current) return;
    if (state?.state === "approved") {
      const timer = window.setTimeout(() => {
        closing.current = true;
        void api
          .closePairing()
          .catch((cause) => setError(normalizeError(cause)));
      }, 1200);
      return () => window.clearTimeout(timer);
    }
    if (
      seconds === 0 ||
      ["expired", "cancelled", "rejected"].includes(state?.state ?? "")
    ) {
      closing.current = true;
      setQr(null);
      setSession(null);
      void api.closePairing().catch((cause) => {
        closing.current = false;
        setError(normalizeError(cause));
      });
    }
  }, [api, seconds, session, state?.state]);
  async function cancel() {
    setBusy(true);
    setError(null);
    try {
      if (session) await api.cancelPairing(session.session_id);
      await api.closePairing();
    } catch (cause) {
      setError(normalizeError(cause));
      setBusy(false);
    }
  }
  async function decide(approve: boolean) {
    if (!request) return;
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
            {qr ? (
              <img src={qr} width="216" height="216" alt="设备配对二维码" />
            ) : (
              <div className="qr-loading">
                {error ? "二维码暂不可用" : "正在生成二维码…"}
              </div>
            )}
          </div>
          <div className="pairing-timer">
            二维码有效期{" "}
            <strong>
              {Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, "0")}
            </strong>
          </div>
          <p className="pairing-hint">使用兼容的 Agent Bridge 客户端扫描</p>
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
}
