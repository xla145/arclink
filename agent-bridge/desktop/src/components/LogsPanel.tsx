import { useCallback, useEffect, useState } from "react";
import { normalizeError, type Bridge } from "../bridge";
import type { BridgeError, RecentLogs } from "../types";
import { ErrorBanner } from "./Common";

export function LogsPanel({ api }: { api: Bridge }) {
  const [logs, setLogs] = useState<RecentLogs | null>(null);
  const [error, setError] = useState<BridgeError | null>(null);
  const [busy, setBusy] = useState<string | null>("refresh");
  const [updated, setUpdated] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const refresh = useCallback(async () => {
    setBusy("refresh");
    setError(null);
    setNotice("");
    try {
      setLogs(await api.recentLogs());
      setUpdated(new Date().toLocaleTimeString());
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      setBusy(null);
    }
  }, [api]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  async function action(key: string, operation: () => Promise<unknown>) {
    setBusy(key);
    setError(null);
    setNotice("");
    try {
      const result = await operation();
      if (key === "copy") setNotice("最近日志已复制");
      if (key === "export") setNotice(result ? "最近日志已导出" : "已取消导出");
    } catch (cause) {
      setError(normalizeError(cause));
    } finally {
      setBusy(null);
    }
  }
  return (
    <section className="panel logs-panel" aria-label="运行日志">
      <div className="section-head">
        <h2>最近日志</h2>
        <button
          className="text-button"
          disabled={!!busy}
          onClick={() => void refresh()}
        >
          {busy === "refresh" ? "读取中…" : "刷新"}
        </button>
      </div>
      <p className="subtle">
        用于排查启动和连接问题{updated ? ` · 更新于 ${updated}` : ""}
      </p>
      {error && <ErrorBanner error={error} />}
      {logs?.truncated && (
        <p className="subtle">日志较长，仅显示最近部分（最多 256 KB）。</p>
      )}
      <pre className="log-view" tabIndex={0} aria-label="日志内容">
        {logs?.text ||
          (busy === "refresh" && !logs
            ? "正在读取日志…"
            : logs
              ? "暂无日志。应用运行后可点击刷新。"
              : "未能读取日志，请刷新重试。")}
      </pre>
      <div className="log-actions">
        <button
          className="button secondary"
          disabled={!!busy || !logs?.text}
          onClick={() => void action("copy", api.copyLogs)}
        >
          复制
        </button>
        <button
          className="button secondary"
          disabled={!!busy || !logs?.text}
          onClick={() => void action("export", api.exportLogs)}
        >
          {busy === "export" ? "导出中…" : "导出"}
        </button>
        <button
          className="text-button"
          disabled={!!busy}
          onClick={() => void action("folder", api.openLogs)}
        >
          打开文件夹
        </button>
      </div>
      <p className="subtle" role="status">
        {notice || "仅包含本机运行日志，不包含 Agent 对话内容。"}
      </p>
    </section>
  );
}
