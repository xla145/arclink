# Research: State storage and one-decision arbitration

- Query: Storage choice for concurrent approvals and native-delivery ambiguity.
- Scope: internal design recommendation
- Date: 2026-10-30

## Findings

Recommend SQLite with WAL, foreign_keys=ON, bounded busy_timeout and synchronous=FULL for local daemon authoritative state; Rust rusqlite is sufficient behind one database writer. This is a recommendation, not a measured durability/performance result. Plain JSONL works for test evidence but cannot alone provide transactional approval CAS, operation de-duplication and snapshot/event consistency.

Minimal durable relations: sessions; runs with process generation; tasks; approvals; operations; events. Unique approval key `(run_id,native_request_id)` (preserve native numeric versus string ID type); additional native thread/turn/item/callback IDs for validation. Unique operation `(device_id,operation_id)` with canonical request digest. Keep pending approvals and unfinished operations independent of event retention.

One transaction: register operation id or return cached same-digest result/conflict; `UPDATE approvals SET state='Resolving', decision=?, operation_id=? WHERE approval_id=? AND run_id=? AND request_version=? AND state='Pending' AND expires_at > ?`; require exactly one changed row; append corresponding event and commit. Only the winner sends the native response. Competing operations return current state without sending. Expiry/cancellation also compete through conditional transitions, never auto-approve.

After commit, dispatch once and collect actual native evidence; a successful pipe write is not sufficient proof the Agent consumed the decision. Persist delivery/result states with events in another transaction. If crash or pipe failure leaves delivery uncertain, mark OutcomeUnknown; do not replay the decision automatically. There is no cross-process exactly-once transaction between SQLite and Agent. Recover new run ID; invalidate old clickable approvals. Use explicit reconciliation where native API supports it.

Snapshot and event watermark must be read in one consistent transaction. Persist schema version and reversible migrations; bound payload/event retention and handle SQLITE_FULL as a mutation stop. Test two connections racing opposite decisions, duplicate operation ID with changed payload, expired request, stale run, crash before/after send and restart. Unit mutex tests alone do not prove multi-process storage arbitration.

### Files found / related specs

- `doc/agent-bridge-plan.md` §03 approval lifecycle and operation deduplication; §04 authoritative state/events and failure behavior.
- `.trellis/spec/backend/database-guidelines.md`: unfilled template; no existing database technology or migration pattern.
- `phase0/schema/CommandExecutionRequestApprovalParams.json:535`: callback ID distinction reinforces native-request uniqueness rather than item-only keys.

## Caveats / Not Found

No SQLite implementation, concurrency benchmark or crash fault injection was performed here. Native response acknowledgement semantics must be established by the real runner; do not equate JSON-RPC response write with tool execution. Wall-clock expiry needs conservative restart policy and injected-clock tests; monotonic elapsed time is preferred within a process.
