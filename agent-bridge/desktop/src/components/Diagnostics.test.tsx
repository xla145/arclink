import { expect, test, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { previewBridge } from "../preview";
import { LogsPanel } from "./LogsPanel";
import { SettingsPanel } from "./SettingsPanel";

test("failed initial keep-awake read ends loading and can be retried", async () => {
  const api = previewBridge("normal");
  api.getKeepAwake = vi
    .fn()
    .mockRejectedValueOnce({ code: "native_error", message: "暂不可用" })
    .mockResolvedValue({
      enabled: false,
      active: false,
      supported: true,
      error: null,
    });
  render(
    <SettingsPanel
      api={api}
      snapshot={await api.snapshot()}
      onExit={() => {}}
      onSaved={() => {}}
      onLogs={() => {}}
    />,
  );
  expect(await screen.findByText("未能读取保持活跃状态")).toBeVisible();
  expect(screen.queryByText("正在读取保持活跃状态…")).not.toBeInTheDocument();
  await userEvent.click(
    screen.getByRole("button", { name: "重试读取保持活跃状态" }),
  );
  await waitFor(() =>
    expect(screen.getByRole("switch", { name: "保持电脑活跃" })).toBeEnabled(),
  );
  expect(screen.queryByText("暂不可用")).not.toBeInTheDocument();
});

test("failed keep-awake mutation reconciles authoritative active state", async () => {
  const api = previewBridge("normal");
  api.setKeepAwake = vi
    .fn()
    .mockRejectedValue({ code: "outcome_unknown", message: "状态待确认" });
  api.getKeepAwake = vi
    .fn()
    .mockResolvedValueOnce({
      enabled: false,
      active: false,
      supported: true,
      error: null,
    })
    .mockResolvedValue({
      enabled: true,
      active: true,
      supported: true,
      error: null,
    });
  render(
    <SettingsPanel
      api={api}
      snapshot={await api.snapshot()}
      onExit={() => {}}
      onSaved={() => {}}
      onLogs={() => {}}
    />,
  );
  const toggle = screen.getByRole("switch", { name: "保持电脑活跃" });
  await waitFor(() => expect(toggle).toBeEnabled());
  await userEvent.click(toggle);
  await waitFor(() => expect(toggle).toHaveAttribute("aria-checked", "true"));
  expect(api.setKeepAwake).toHaveBeenCalledExactlyOnceWith(true);
  expect(screen.getByText(/已生效/)).toBeVisible();
  expect(screen.getByText("状态待确认")).toBeVisible();
});

test("reopening the panel refreshes actual keep-awake ownership", async () => {
  const api = previewBridge("normal");
  api.getKeepAwake = vi
    .fn()
    .mockResolvedValueOnce({
      enabled: true,
      active: true,
      supported: true,
      error: null,
    })
    .mockResolvedValue({
      enabled: true,
      active: false,
      supported: true,
      error: null,
    });
  const view = render(
    <SettingsPanel
      api={api}
      snapshot={await api.snapshot()}
      onExit={() => {}}
      onSaved={() => {}}
      onLogs={() => {}}
    />,
  );
  expect(await screen.findByText(/已生效/)).toBeVisible();
  fireEvent.focus(window);
  expect(await screen.findByText("已开启偏好，但当前未生效")).toBeVisible();
  view.unmount();
  fireEvent.focus(window);
  expect(api.getKeepAwake).toHaveBeenCalledTimes(2);
});

test("logs preserve loaded content after refresh failure", async () => {
  const api = previewBridge("normal");
  api.recentLogs = vi
    .fn()
    .mockResolvedValueOnce({ text: "actual log line", truncated: false })
    .mockRejectedValue({ code: "io", message: "读取失败" });
  render(<LogsPanel api={api} />);
  expect(await screen.findByText("actual log line")).toBeVisible();
  await userEvent.click(screen.getByRole("button", { name: "刷新" }));
  expect(await screen.findByText("读取失败")).toBeVisible();
  expect(screen.getByText("actual log line")).toBeVisible();
});

test("cancelled export is neutral", async () => {
  const api = previewBridge("normal");
  api.exportLogs = vi.fn().mockResolvedValue(false);
  render(<LogsPanel api={api} />);
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "导出" })).toBeEnabled(),
  );
  await userEvent.click(screen.getByRole("button", { name: "导出" }));
  expect(await screen.findByText("已取消导出")).toBeVisible();
  expect(screen.queryByText("最近日志已导出")).not.toBeInTheDocument();
});
