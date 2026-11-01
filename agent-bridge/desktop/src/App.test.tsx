import { StrictMode } from "react";
import { expect, test, vi } from "vitest";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "./App";
import { previewBridge } from "./preview";
import type { Bridge } from "./bridge";
import type { PairSession, Snapshot } from "./types";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test("revoke requires confirmation; cancelling does not mutate and failure stays visible", async () => {
  const api = previewBridge("normal");
  api.revokeDevice = vi
    .fn()
    .mockRejectedValue({ code: "storage_error", message: "无法保存撤销记录" });
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: "撤销 iPhone 16 Pro 的访问" }),
  );
  await userEvent.click(screen.getByRole("button", { name: "取消" }));
  expect(api.revokeDevice).not.toHaveBeenCalled();
  await userEvent.click(
    screen.getByRole("button", { name: "撤销 iPhone 16 Pro 的访问" }),
  );
  await userEvent.click(screen.getByRole("button", { name: "撤销" }));
  expect(api.revokeDevice).toHaveBeenCalledWith("preview-phone");
  await waitFor(() =>
    expect(screen.getByRole("dialog")).toHaveTextContent("无法保存撤销记录"),
  );
  expect(screen.getByRole("dialog")).toBeVisible();
});

test("subscribes before snapshot and ignores a stale response after a newer event", async () => {
  const api = previewBridge("normal");
  const initial = await api.snapshot();
  const pending = deferred<Snapshot>();
  let emit!: (snapshot: Snapshot) => void;
  const order: string[] = [];
  api.subscribe = vi.fn(async (callback) => {
    order.push("listen");
    emit = callback;
    return () => {};
  });
  api.snapshot = vi.fn(() => {
    order.push("snapshot");
    return pending.promise;
  });
  render(<App api={api} />);
  await waitFor(() => expect(api.snapshot).toHaveBeenCalled());
  expect(order).toEqual(["listen", "snapshot"]);
  act(() =>
    emit({
      ...initial,
      revision: "20",
      devices: [{ ...initial.devices[0], name: "新设备名称" }],
    }),
  );
  expect(await screen.findByText("新设备名称")).toBeVisible();
  await act(async () => pending.resolve(initial));
  expect(screen.getByText("新设备名称")).toBeVisible();
  expect(screen.queryByText("iPhone 16 Pro")).not.toBeInTheDocument();
});

test("unmount removes listeners even when registration resolves late", async () => {
  const api = previewBridge("normal");
  const registered = deferred<() => void>();
  const cleanup = vi.fn();
  api.subscribe = vi.fn(() => registered.promise);
  api.snapshot = vi.fn();
  const view = render(<App api={api} />);
  view.unmount();
  await act(async () => registered.resolve(cleanup));
  expect(cleanup).toHaveBeenCalledOnce();
  expect(api.snapshot).not.toHaveBeenCalled();
});

test("retired service events cannot replace a new service in one React batch", async () => {
  const api = previewBridge("normal");
  const original = await api.snapshot();
  let emit!: (snapshot: Snapshot) => void;
  api.subscribe = async (callback) => {
    emit = callback;
    return () => {};
  };
  render(<App api={api} />);
  await screen.findByText("iPhone 16 Pro");
  act(() => {
    emit({
      ...original,
      service_instance: "new-host",
      revision: "1",
      devices: [{ ...original.devices[0], name: "新主机设备" }],
    });
    emit({ ...original, revision: "999" });
  });
  expect(screen.getByText("新主机设备")).toBeVisible();
  expect(screen.queryByText("iPhone 16 Pro")).not.toBeInTheDocument();
});

test("settings reflects the actual autostart state after a failed change", async () => {
  const api = previewBridge("normal");
  api.setAutostart = vi
    .fn()
    .mockRejectedValue({ code: "native_error", message: "系统拒绝修改登录项" });
  api.getAutostart = vi.fn().mockResolvedValue({ enabled: false });
  render(<App api={api} />);
  await screen.findByText("iPhone 16 Pro");
  await userEvent.click(screen.getByRole("button", { name: "设置" }));
  const toggle = await screen.findByRole("switch", { name: "登录时启动" });
  await waitFor(() => expect(toggle).toBeEnabled());
  await userEvent.click(toggle);
  expect(await screen.findByText("系统拒绝修改登录项")).toBeVisible();
  expect(toggle).toHaveAttribute("aria-checked", "false");
  expect(api.setAutostart).toHaveBeenCalledWith(true);
});

test("StrictMode creates one pairing invitation and cancel addresses its session", async () => {
  const api = previewBridge("empty");
  const invitation = {
    session_id: "s1",
    endpoint_id: "endpoint",
    token: "secret",
    expires_at: new Date(Date.now() + 120000).toISOString(),
    qr_payload: "test-pairing-qr",
  };
  api.startPairing = vi.fn().mockResolvedValue(invitation);
  api.cancelPairing = vi.fn().mockResolvedValue(undefined);
  const popup = vi.spyOn(window, "open");
  render(
    <StrictMode>
      <App api={api} />
    </StrictMode>,
  );
  const panel = screen.getByRole("main");
  await userEvent.click(
    await screen.findByRole("button", { name: "配对新设备" }),
  );
  await screen.findByAltText("设备配对二维码");
  expect(screen.getByRole("main")).toBe(panel);
  expect(popup).not.toHaveBeenCalled();
  expect(api.startPairing).toHaveBeenCalledOnce();
  await userEvent.click(screen.getByRole("button", { name: "取消配对" }));
  expect(api.cancelPairing).toHaveBeenCalledWith("s1");
  expect(await screen.findByText("尚未配对任何设备")).toBeVisible();
  expect(screen.getByRole("main")).toBe(panel);
});

test("inline back waits for backend cancellation and keeps the invitation on failure", async () => {
  const api = previewBridge("empty");
  const cancelled = deferred<void>();
  api.cancelPairing = vi
    .fn()
    .mockReturnValueOnce(cancelled.promise)
    .mockRejectedValueOnce({ code: "conflict", message: "暂时无法取消配对" })
    .mockResolvedValue(undefined);
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: "配对新设备" }),
  );
  await screen.findByAltText("设备配对二维码");
  await userEvent.click(screen.getByRole("button", { name: "返回设备列表" }));
  expect(screen.getByAltText("设备配对二维码")).toBeVisible();
  expect(screen.queryByText("尚未配对任何设备")).not.toBeInTheDocument();
  await act(async () => cancelled.resolve());
  await userEvent.click(
    await screen.findByRole("button", { name: "配对新设备" }),
  );
  await screen.findByAltText("设备配对二维码");
  await userEvent.click(screen.getByRole("button", { name: "取消配对" }));
  expect(await screen.findByText("暂时无法取消配对")).toBeVisible();
  expect(screen.getByAltText("设备配对二维码")).toBeVisible();
  await userEvent.click(screen.getByRole("button", { name: "返回设备列表" }));
  expect(await screen.findByText("尚未配对任何设备")).toBeVisible();
});

test("successful pairing clears its QR and returns to devices in the same panel", async () => {
  const api = previewBridge("empty");
  const snapshot = await api.snapshot();
  let emit!: (snapshot: Snapshot) => void;
  api.subscribe = async (callback) => {
    emit = callback;
    return () => {};
  };
  api.startPairing = vi.fn().mockResolvedValue({
    session_id: "success",
    endpoint_id: "endpoint",
    token: "secret",
    expires_at: new Date(Date.now() + 120000).toISOString(),
    qr_payload: "test-success-qr",
  });
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: "配对新设备" }),
  );
  await screen.findByAltText("设备配对二维码");
  vi.useFakeTimers();
  try {
    act(() =>
      emit({
        ...snapshot,
        revision: "2",
        pairing: {
          session_id: "success",
          expires_at: null,
          request: null,
          state: "approved",
        },
        devices: [
          {
            device_id: "new-phone",
            name: "新配对手机",
            paired_at: new Date().toISOString(),
            last_seen: null,
            connection: "offline",
            permissions: ["view"],
          },
        ],
      }),
    );
    expect(screen.getByText("配对成功")).toBeVisible();
    expect(screen.queryByAltText("设备配对二维码")).not.toBeInTheDocument();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1200);
    });
    expect(screen.getByText("新配对手机")).toBeVisible();
    expect(screen.queryByText("配对成功")).not.toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test("hiding and focusing the panel retains the active invitation", async () => {
  const api = previewBridge("empty");
  const start = api.startPairing;
  api.startPairing = vi.fn(start);
  api.cancelPairing = vi.fn().mockResolvedValue(undefined);
  render(<App api={api} />);
  await userEvent.click(
    await screen.findByRole("button", { name: "配对新设备" }),
  );
  const qr = await screen.findByAltText("设备配对二维码");
  const source = qr.getAttribute("src");
  fireEvent.blur(window);
  fireEvent.focus(window);
  await waitFor(() =>
    expect(screen.getByAltText("设备配对二维码")).toHaveAttribute(
      "src",
      source,
    ),
  );
  expect(api.startPairing).toHaveBeenCalledOnce();
  expect(api.cancelPairing).not.toHaveBeenCalled();
});

test("opaque I/O permission toggles stay coupled and consent sends displayed permissions", async () => {
  const api = previewBridge("empty");
  const snapshot = await api.snapshot();
  const expires = new Date(Date.now() + 120000).toISOString();
  snapshot.pairing = {
    session_id: "s1",
    expires_at: expires,
    state: "pending",
    request: {
      request_id: "r1",
      session_id: "s1",
      device_id: "peer",
      name: "新手机",
      permissions: ["view", "session", "task", "approval"],
      expires_at: expires,
      state: "pending",
    },
  };
  api.snapshot = async () => snapshot;
  api.startPairing = vi.fn().mockResolvedValue({
    session_id: "s1",
    endpoint_id: "endpoint",
    token: "secret",
    expires_at: expires,
    qr_payload: "test-qr",
  });
  api.approvePairing = vi.fn().mockResolvedValue(undefined);
  render(<App api={api} initialPairing />);
  await userEvent.click(await screen.findByLabelText("发送 Agent 输入"));
  expect(screen.getByLabelText("传递审批决定")).not.toBeChecked();
  await userEvent.click(screen.getByRole("button", { name: "确认配对" }));
  expect(api.approvePairing).toHaveBeenCalledWith("r1", ["view", "session"]);
});

test("expired invitation clears the QR and returns inline without generating another token", async () => {
  vi.useFakeTimers();
  const api = previewBridge("empty");
  api.cancelPairing = vi.fn().mockResolvedValue(undefined);
  api.startPairing = vi.fn().mockResolvedValue({
    session_id: "expiry",
    endpoint_id: "endpoint",
    token: "secret",
    expires_at: new Date(Date.now() + 120000).toISOString(),
    qr_payload: "test-expiry-qr",
  });
  try {
    render(<App api={api} initialPairing />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(100);
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(121000);
    });
    expect(api.cancelPairing).toHaveBeenCalledExactlyOnceWith("expiry");
    expect(screen.getByText("尚未配对任何设备")).toBeVisible();
    expect(api.startPairing).toHaveBeenCalledOnce();
    expect(screen.queryByAltText("设备配对二维码")).not.toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test("a delayed invitation starts its display at the actual 120-second validity", async () => {
  vi.useFakeTimers();
  const api = previewBridge("empty");
  const pending = deferred<PairSession>();
  api.startPairing = vi.fn(() => pending.promise);
  try {
    render(<App api={api} initialPairing />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(750);
    });
    await act(async () =>
      pending.resolve({
        session_id: "delayed",
        endpoint_id: "endpoint",
        token: "secret",
        expires_at: new Date(Date.now() + 120000).toISOString(),
        qr_payload: "test-delayed-qr",
      }),
    );
    expect(screen.getByText("2:00")).toBeVisible();
    expect(screen.queryByText("2:01")).not.toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test("native exit event asks confirmation and Esc cancels without hiding the app", async () => {
  const api = previewBridge("normal");
  let askExit!: () => void;
  api.subscribe = async (_snapshot, _changed, _settings, onExit) => {
    askExit = onExit;
    return () => {};
  };
  api.exit = vi.fn().mockResolvedValue(undefined);
  api.hide = vi.fn().mockResolvedValue(undefined);
  render(<App api={api} />);
  await screen.findByText("iPhone 16 Pro");
  act(() => askExit());
  expect(screen.getByRole("dialog")).toHaveTextContent(
    "1 个 Agent 进程将被停止",
  );
  fireEvent.keyDown(document, { key: "Escape" });
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(api.exit).not.toHaveBeenCalled();
  expect(api.hide).not.toHaveBeenCalled();
});

test("pairing network configuration is automatic without credential entry", async () => {
  const api = previewBridge("normal");
  api.updateNetworkSettings = vi.fn();
  render(<App api={api} />);
  await screen.findByText("iPhone 16 Pro");
  await userEvent.click(screen.getByRole("button", { name: "设置" }));
  expect(screen.getByText("自动连接 · 优先直连")).toBeVisible();
  expect(
    screen.getByText(/手机扫码即可连接，直连不可用时自动使用中继/),
  ).toBeVisible();
  expect(screen.queryByLabelText("中继地址")).not.toBeInTheDocument();
  expect(screen.queryByLabelText("访问密钥")).not.toBeInTheDocument();
  expect(
    screen.queryByRole("button", { name: "保存连接设置" }),
  ).not.toBeInTheDocument();
  expect(api.updateNetworkSettings).not.toHaveBeenCalled();
  await userEvent.click(screen.getByRole("button", { name: "返回面板" }));
  await userEvent.click(screen.getByRole("button", { name: "+ 配对" }));
  expect(
    await screen.findByRole("img", { name: "设备配对二维码" }),
  ).toBeVisible();
});
