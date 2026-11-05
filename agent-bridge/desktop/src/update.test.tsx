import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vitest";
import { App } from "./App";
import { previewBridge } from "./preview";
import type { UpdateStatus } from "./types";

const available: UpdateStatus = {
  revision: "1",
  current_version: "0.1.0",
  phase: "available",
  version: "0.2.0",
  notes: "修复连接问题",
  downloaded: 0,
  total: null,
  error: null,
  restart_required: false,
};
function updater() {
  const api = previewBridge("normal");
  api.updateStatus = vi.fn().mockResolvedValue(available);
  api.checkUpdate = vi.fn().mockResolvedValue(available);
  api.downloadUpdate = vi
    .fn()
    .mockResolvedValue({ ...available, revision: "2", phase: "downloading" });
  api.installUpdate = vi
    .fn()
    .mockResolvedValue({ ...available, revision: "4", phase: "installing" });
  return api;
}
afterEach(() => vi.useRealTimers());

test("startup announces an update but download and installation require user actions", async () => {
  const api = updater();
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: /新版本 0.2.0 可用/ }),
  );
  expect(api.checkUpdate).toHaveBeenCalledWith(true);
  expect(api.downloadUpdate).not.toHaveBeenCalled();
  expect(api.installUpdate).not.toHaveBeenCalled();
  const applicationHeading = screen.getByRole("heading", { name: "应用" });
  const updatePanel = screen.getByLabelText("软件更新");
  expect(
    applicationHeading.compareDocumentPosition(updatePanel) &
      Node.DOCUMENT_POSITION_FOLLOWING,
  ).toBeTruthy();
  expect(screen.getAllByLabelText("软件更新")).toHaveLength(1);
  await userEvent.click(screen.getByRole("button", { name: "下载更新" }));
  expect(api.downloadUpdate).toHaveBeenCalledExactlyOnceWith("0.2.0");
  expect(screen.getByRole("button", { name: "检查更新" })).toBeDisabled();
  expect(api.installUpdate).not.toHaveBeenCalled();
});

test("ready update confirms interruption; cancellation does not install", async () => {
  const api = updater();
  const ready = { ...available, phase: "ready" as const };
  api.updateStatus = vi.fn().mockResolvedValue(ready);
  api.checkUpdate = vi.fn().mockResolvedValue(ready);
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: /新版本 0.2.0 可用/ }),
  );
  await userEvent.click(screen.getByRole("button", { name: "安装并重启" }));
  expect(screen.getByRole("dialog")).toHaveTextContent(
    "1 个 Agent 进程将被停止",
  );
  await userEvent.click(screen.getByRole("button", { name: "取消" }));
  expect(api.installUpdate).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole("button", { name: "安装并重启" }));
  await userEvent.click(screen.getByRole("button", { name: "停止任务并重启" }));
  expect(api.installUpdate).toHaveBeenCalledExactlyOnceWith("0.2.0", true);
  expect(screen.getByRole("button", { name: "处理中…" })).toBeDisabled();
});

test("check failure stays distinct from up to date and permits a manual retry", async () => {
  const api = updater();
  const failed: UpdateStatus = {
    ...available,
    version: null,
    phase: "error",
    error: { code: "update_check_failed", message: "网络不可用" },
  };
  api.updateStatus = vi.fn().mockResolvedValue(failed);
  api.checkUpdate = vi
    .fn()
    .mockResolvedValueOnce(failed)
    .mockResolvedValue({ ...available, revision: "2", phase: "checking" });
  render(<App api={api} />);
  await userEvent.click(await screen.findByRole("button", { name: "设置" }));
  expect(await screen.findByText("网络不可用")).toBeVisible();
  expect(screen.queryByText("已是最新版本")).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "检查更新" }));
  expect(api.checkUpdate).toHaveBeenLastCalledWith();
  expect(await screen.findByText("正在检查更新…")).toBeVisible();
});

test("stale poll cannot undo a newer download state and unmount stops polling", async () => {
  const api = updater();
  let resolve!: (status: UpdateStatus) => void;
  api.updateStatus = vi.fn().mockReturnValue(
    new Promise<UpdateStatus>((done) => {
      resolve = done;
    }),
  );
  const view = render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: /新版本 0.2.0 可用/ }),
  );
  await userEvent.click(screen.getByRole("button", { name: "下载更新" }));
  await act(async () => resolve(available));
  expect(screen.getByText("正在下载并验证更新…")).toBeVisible();
  view.unmount();
  vi.useFakeTimers();
  await act(async () => vi.advanceTimersByTimeAsync(5000));
  expect(api.updateStatus).toHaveBeenCalledOnce();
});

test("install failure preserves explicit recovery and never auto retries", async () => {
  const api = updater();
  const failed: UpdateStatus = {
    ...available,
    phase: "error",
    restart_required: true,
    error: { code: "update_install_failed", message: "安装失败" },
  };
  api.updateStatus = vi.fn().mockResolvedValue(failed);
  api.checkUpdate = vi.fn().mockResolvedValue(failed);
  render(<App api={api} />);
  await userEvent.click(await screen.findByRole("button", { name: "设置" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "检查更新" })).toBeDisabled(),
  );
  expect(screen.getByRole("button", { name: "安装并重启" })).toBeEnabled();
  expect(api.installUpdate).not.toHaveBeenCalled();
});
