import type { ManagedApproval, ManagedMessage, ManagedRun, ManagedThread, ThreadReplay, ThreadSnapshot } from "./types";

export class UnsupportedThreadSchemaError extends Error {}

function merge<T extends { id: string }>(rows: T[], value: T): T[] {
  const index = rows.findIndex(row => row.id === value.id);
  if (index >= 0 && "revision" in rows[index] && "revision" in value && BigInt(String(rows[index].revision)) >= BigInt(String(value.revision))) return rows;
  if (index >= 0 && "state" in rows[index] && "state" in value && rows[index].state !== "pending" && value.state === "pending") return rows;
  return index < 0 ? [...rows, value] : rows.map((row, i) => i === index ? value : row);
}
/** Advance the cursor only after the complete durable batch is applied. */
export function applyThreadReplay(snapshot: ThreadSnapshot, replay: ThreadReplay): ThreadSnapshot {
  if (snapshot.environment_id !== replay.environment_id || snapshot.thread.id !== replay.thread_id) throw new Error("会话环境已改变，请重新同步。");
  if (BigInt(replay.sequence) < BigInt(snapshot.sequence)) throw new Error("会话游标回退，请重新同步。");
  let next = { ...snapshot };
  let previous = BigInt(snapshot.sequence);
  for (const event of replay.events) {
    if (BigInt(event.sequence) <= BigInt(snapshot.sequence)) continue;
    if (BigInt(event.sequence) <= previous) throw new Error("会话事件顺序无效。");
    previous = BigInt(event.sequence);
    if (BigInt(event.sequence) > BigInt(replay.sequence)) throw new Error("服务端事件批次游标无效。");
    if (event.schema_version !== 1) throw new UnsupportedThreadSchemaError("客户端需要更新才能读取会话事件。");
    switch (event.event_type) {
      case "message.created": case "message.updated": next.messages = merge(next.messages, event.payload as ManagedMessage); break;
      case "thread.updated": { const value = event.payload as ManagedThread; if (BigInt(value.revision) > BigInt(next.thread.revision)) next.thread = value; break; }
      case "run.queued": case "run.updated": next.runs = merge(next.runs ?? [], event.payload as ManagedRun); break;
      case "approval.updated": case "approval.created": next.approvals = merge(next.approvals ?? [], event.payload as ManagedApproval); break;
    }
  }
  return { ...next, sequence: replay.sequence };
}
