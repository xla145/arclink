import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AgentList } from "./AgentList";

describe("Agent detection presentation", () => {
  it("distinguishes installation from transport readiness and shows the selected path", () => {
    render(<AgentList agents={[{
      id: "claude", name: "Claude Code", version: "2.1.45",
      status: "installed", validation: "unverified", capabilities: [],
      diagnostic: "接入协议尚未验证", executable_path: "/custom/bin/claude",
    }]} />);
    expect(screen.getByText("已安装")).toBeInTheDocument();
    expect(screen.getByText("路径：/custom/bin/claude")).toBeInTheDocument();
    expect(screen.queryByText("就绪")).not.toBeInTheDocument();
    expect(screen.queryByText("未验证")).not.toBeInTheDocument();
  });
});
