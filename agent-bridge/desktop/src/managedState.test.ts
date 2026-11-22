import { describe, expect, it } from "vitest";
import { applyThreadReplay } from "./managedState";
import type { ManagedMessage, ThreadReplay, ThreadSnapshot } from "./types";

const message = (revision: string, text: string): ManagedMessage => ({ id: "m", thread_id: "t", run_id: "r", client_message_id: null, role: "assistant", content: { text }, revision });
const snapshot = (): ThreadSnapshot => ({ environment_id: "e", sequence: "9007199254740993", thread: { id: "t", project_id: "p", provider_id: "codex", title: "Test", cwd: "/tmp", status: "active", revision: "1", created_at: "now", updated_at: "now" }, messages: [message("2", "new")], runs: [], approvals: [], has_older_messages: false });
const batch = (): ThreadReplay => ({ environment_id: "e", thread_id: "t", sequence: "9007199254740994", has_more: false, events: [{ sequence: "9007199254740994", aggregate_id: "m", event_type: "message.updated", schema_version: 1, payload: message("3", "complete") }] });
describe("managed Thread reducer", () => {
  it("preserves host model selection and its reset through thread updates", () => {
    const original = snapshot();
    const replay = batch();
    replay.events[0] = { ...replay.events[0], aggregate_id: "t", event_type: "thread.updated", payload: { ...original.thread, model: "test-model", revision: "2" } };
    const selected = applyThreadReplay(original, replay);
    expect(selected.thread.model).toBe("test-model");
    const resetSequence = "9007199254740995";
    const reset = applyThreadReplay(selected, { ...replay, sequence: resetSequence, events: [{ ...replay.events[0], sequence: resetSequence, payload: { ...selected.thread, model: null, revision: "3" } }] });
    expect(reset.thread.model).toBeNull();
    expect(original.thread.model).toBeUndefined();
  });
  it("applies wide cursors without numeric precision loss and deduplicates replay", () => { const next = applyThreadReplay(snapshot(), batch()); expect(next.messages).toEqual([message("3", "complete")]); expect(next.sequence).toBe("9007199254740994"); expect(applyThreadReplay(next, batch())).toEqual(next); });
  it("does not replace a newer projection with an older revision", () => { const replay = batch(); replay.events[0].payload = message("1", "stale"); expect(applyThreadReplay(snapshot(), replay).messages[0].content.text).toBe("new"); });
  it("rejects foreign environments, regressive cursors, and events outside the batch", () => { expect(() => applyThreadReplay(snapshot(), { ...batch(), environment_id: "other" })).toThrow(); expect(() => applyThreadReplay(snapshot(), { ...batch(), sequence: "1" })).toThrow(); const replay = batch(); replay.events[0].sequence = "9007199254740995"; expect(() => applyThreadReplay(snapshot(), replay)).toThrow(); });
  it("keeps paged history and leaves the original state untouched on unsupported events", () => { const original = snapshot(); original.messages.unshift({ ...message("1", "older"), id: "old" }); expect(applyThreadReplay(original, batch()).messages).toHaveLength(2); const replay = batch(); replay.events[0].schema_version = 99; expect(() => applyThreadReplay(original, replay)).toThrow(); expect(original.sequence).toBe("9007199254740993"); });
});
