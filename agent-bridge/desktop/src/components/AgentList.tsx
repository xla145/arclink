import type { AgentInfo } from "../types";
import { Icon } from "./Icons";

const labels: Record<AgentInfo["status"], string> = {
  not_found: "未发现",
  installed: "已安装",
  available: "就绪",
  running: "运行中",
  version_mismatch: "未验证",
  probe_failed: "检测失败",
};
export function AgentList({
  agents,
  compact = false,
}: {
  agents: AgentInfo[];
  compact?: boolean;
}) {
  return (
    <div className="agent-list">
      {agents.map((agent) => {
        const tone =
          agent.status === "running"
            ? "accent"
            : agent.status === "available"
              ? "success"
              : agent.status === "not_found"
                ? "muted"
                : "warning";
        return (
          <div className="agent-row" key={agent.id}>
            <span className={`agent-indicator ${tone}`}>
              {agent.status === "available" ? (
                <Icon name="check" size={12} />
              ) : agent.status === "running" ? (
                "▶"
              ) : agent.status === "not_found" ? (
                "−"
              ) : (
                "!"
              )}
            </span>
            <div className="agent-info">
              <div className="name">{agent.name}</div>
              <div className="agent-detail">
                {agent.version
                  ? /^v?\d/.test(agent.version)
                    ? `v${agent.version.replace(/^v/, "")}`
                    : agent.version
                  : agent.status === "not_found"
                    ? "未安装"
                    : "版本未知"}
              </div>
              {!compact && agent.diagnostic && (
                <p className="diagnostic">{agent.diagnostic}</p>
              )}
            </div>
            <span className={`badge ${tone}`}>{labels[agent.status]}</span>
          </div>
        );
      })}
      {!agents.length && <p className="subtle">正在检查本机 Agent…</p>}
    </div>
  );
}
