# Cross-layer review targets

The original scaffold compiles neither adapter nor daemon and is not a working baseline. Existing Phase 0 evidence validates only local Codex 0.165.0 command approval; new product integration requires its own tests.

## High-risk seams
1. Submission registration vs early events: task identity must exist before turn/start can emit approval or completion. An event cannot be dropped merely because submit has not returned.
2. Approval delivery vs event processing: native actor must keep consuming stdout while respond_approval waits for serverRequest/resolved. Manager cannot deadlock event persistence behind a held runtime lock.
3. SQLite CAS vs actor side effects: independent SQLite connections compete on one Pending row; only successful claim can send. A request arriving after task completion/run invalidation must fail even if approval ID exists.
4. Result durability: mutation registered before native side effect; duplicate pending request must not execute again; missing final transaction means OutcomeUnknown. Same operation ID with different content conflicts, including after completion/restart.
5. Cancellation semantics: interrupt RPC acceptance is not task Cancelled. Native terminal status wins. Native error, EOF and process exit must not fabricate Completed.
6. Recovery: live runs become RecoveryRequired, tasks unknown, old approvals invalid. Restore conversation only through explicit resume with new run ID. No approval/operation replay on service startup.
7. Authorization: empty registry denies; authenticated endpoint is key, not caller-supplied device ID. Hello/stream/RPC and live event subscribers enforce revoke. Read-only devices cannot mutate or request terminal access.
8. Pairing: separate Pair flow, expiring one-use token bound to actual client identity, local confirmation before grants. Tokens never in ordinary logs; failure/connection limits bound work.
9. Framing: validate length before allocation, zero/oversize/unknown type reject, fragmented prefix/payload and EOF handled. Native JSONL likewise bounded before allocation, preserving UTF-8 across chunks.
10. Snapshot watermark: obtain both in one database read transaction. Replay never silently skips expired events; future/old cursors and retention edge conditions explicit. Subscriptions bound memory and cannot block native output.
11. Resource failure: disk/write failure stops new native mutations and surfaces unknown outcomes; no silent event/approval drops. Bound process/session count, connection/stream count, queues and response size.
12. Client: stable operation IDs, explicit query on timeout, reauthorization/resync after reconnect, no retry on revoked identity; RPC errors remain typed end-to-end.

## Verification evidence
Require actual production path assertions through fake runtime, store and network where applicable. Unit-only mutex competition cannot demonstrate SQLite arbitration. Tests must avoid external agents/network unless explicitly separated. Real Codex marker tests must use fresh paths, restricted fixed commands and current version check; old Phase 0 pass is not a new daemon pass.
