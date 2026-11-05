import { useEffect, useRef, type ReactNode } from "react";
import type { BridgeError } from "../types";
import { Icon } from "./Icons";

export function ErrorBanner({
  error,
  onRetry,
  onLogs,
}: {
  error: BridgeError;
  onRetry?: () => void;
  onLogs?: () => void;
}) {
  return (
    <div className="error-banner" role="alert">
      <Icon name="alert" />
      <div>
        <strong>暂时无法完成操作</strong>
        <p>{error.message}</p>
        <div className="inline-actions">
          {onRetry && <button onClick={onRetry}>重试</button>}
          {onLogs && <button onClick={onLogs}>查看日志</button>}
        </div>
      </div>
    </div>
  );
}

export function EmptyState({
  title,
  description,
  children,
  icon = "phone",
}: {
  title: string;
  description: string;
  children?: ReactNode;
  icon?: "phone" | "terminal";
}) {
  return (
    <div className="empty-state">
      <div className="empty-icon">
        <Icon name={icon} size={24} />
      </div>
      <h2>{title}</h2>
      <p>{description}</p>
      {children}
    </div>
  );
}

export function ConfirmDialog({
  title,
  children,
  confirm,
  busy,
  onCancel,
  onConfirm,
}: {
  title: string;
  children: ReactNode;
  confirm: string;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const dialog = useRef<HTMLDivElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    if (busy) dialog.current?.focus();
    else cancel.current?.focus();
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (!busy) onCancel();
      }
      if (event.key === "Tab") {
        const buttons = dialog.current?.querySelectorAll<HTMLButtonElement>(
          "button:not(:disabled)",
        );
        if (!buttons?.length) {
          event.preventDefault();
          dialog.current?.focus();
          return;
        }
        const first = buttons[0],
          last = buttons[buttons.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", keydown, true);
    return () => {
      document.removeEventListener("keydown", keydown, true);
      previous?.focus();
    };
  }, [busy, onCancel]);
  return (
    <div className="dialog-overlay">
      <div
        ref={dialog}
        className="dialog-box"
        role="dialog"
        tabIndex={-1}
        aria-modal="true"
        aria-labelledby="confirm-title"
      >
        <h2 id="confirm-title">{title}</h2>
        <div className="dialog-body">{children}</div>
        <div className="dialog-actions">
          <button
            ref={cancel}
            className="button secondary"
            onClick={onCancel}
            disabled={busy}
          >
            取消
          </button>
          <button className="button danger" onClick={onConfirm} disabled={busy}>
            {busy ? "处理中…" : confirm}
          </button>
        </div>
      </div>
    </div>
  );
}

export function relativeTime(value: string | null): string {
  if (!value) return "尚无连接记录";
  const seconds = Math.max(0, (Date.now() - Date.parse(value)) / 1000);
  if (!Number.isFinite(seconds)) return "时间未知";
  if (seconds < 60) return "刚刚连接";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  return `${Math.floor(seconds / 86400)} 天前`;
}
