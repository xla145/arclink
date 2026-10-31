import { expect, test } from "vitest";
import fixture from "./snapshot-contract.json";
import type { Snapshot } from "../types";
import { newerSnapshot } from "../hooks/useSnapshot";

// JSON imports widen literal strings. Reassert only the three enum literals;
// all remaining fields must structurally satisfy the actual UI contract.
const snapshot: Snapshot = {
  ...fixture,
  status: {
    ...fixture.status,
    network: { ...fixture.status.network, state: "ready" },
  },
  agents: fixture.agents.map((agent) => ({
    ...agent,
    status: "available",
    validation: "verified",
  })),
};

test("shared Rust wire fixture preserves nulls and revisions above JS safe integer", () => {
  expect(snapshot).toEqual(fixture);
  const newer = { ...snapshot, revision: "9007199254740994" };
  expect(newerSnapshot(newer, snapshot)).toBe(newer);
  expect(newerSnapshot(snapshot, newer)).toBe(newer);
  expect(snapshot.processes[0].generation).toBe("9007199254740993");
  expect(snapshot.devices[0].last_seen).toBeNull();
});
