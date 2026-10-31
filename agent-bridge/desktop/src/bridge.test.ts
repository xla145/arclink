import { afterEach, expect, test, vi } from "vitest";
import { bridge, normalizeError } from "./bridge";

const native = vi.hoisted(() => ({ enabled: false, invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({
  isTauri: () => native.enabled,
  invoke: native.invoke,
}));
afterEach(() => {
  native.enabled = false;
  native.invoke.mockReset();
  vi.useRealTimers();
});

test("browser runtime fails explicitly rather than returning preview state", async () => {
  await expect(bridge.snapshot()).rejects.toMatchObject({
    code: "desktop_required",
  });
  await expect(bridge.openPairing()).rejects.toMatchObject({
    code: "desktop_required",
  });
});

test("bridge preserves structured error codes without exposing unknown objects", () => {
  expect(normalizeError({ code: "conflict", message: "状态已变化" })).toEqual({
    code: "conflict",
    message: "状态已变化",
  });
  expect(
    normalizeError({ token: "must-not-be-displayed" }).message,
  ).not.toContain("must-not-be-displayed");
});

test("browser subscription installs no native listener", async () => {
  const callback = vi.fn();
  const cleanup = await bridge.subscribe(
    callback,
    callback,
    callback,
    callback,
  );
  cleanup();
  expect(callback).not.toHaveBeenCalled();
});

test("mutation timeout is uncertain and never automatically invokes again", async () => {
  native.enabled = true;
  native.invoke.mockImplementation(() => new Promise(() => {}));
  vi.useFakeTimers();
  const response = bridge.revokeDevice("peer");
  const assertion = expect(response).rejects.toMatchObject({
    code: "outcome_unknown",
  });
  await vi.advanceTimersByTimeAsync(30_000);
  await assertion;
  expect(native.invoke).toHaveBeenCalledExactlyOnceWith("revoke_device", {
    deviceId: "peer",
  });
  await vi.advanceTimersByTimeAsync(60_000);
  expect(native.invoke).toHaveBeenCalledOnce();
});
