# Agent Bridge durable control contract

> Historical architecture. The greenfield desktop host uses
> [agent-bridge-host.md](./agent-bridge-host.md); it does not persist or parse
> mobile session/task/approval business state on the desktop.

## 1. Scope / Trigger
Applies to `agent-bridge/crates/{abp-protocol,agent-store,agent-adapters,agentd,agent-bridge-client,abp-test-harness}`. Read the Phase 0 contract before modifying native permissions. Production is macOS single-Codex; transport and store tests inject endpoints and adapters.

## 2. Signatures
- `agentd DATABASE serve [--pair]`; local `grant ENDPOINT NAME PERMISSIONS`, `revoke ENDPOINT`, `devices`, `pairs`, `approve PAIR_ID PERMISSIONS`.
- `agentctl IDENTITY_FILE id`; `agentctl IDENTITY_FILE SERVER_ID snapshot|agents|approvals|rpc|events CURSOR|pair TOKEN NAME`.
- `SessionManager::with_adapters(Arc<Store>, Vec<Arc<dyn AgentAdapter>>)`; `Daemon::with_endpoint(endpoint, store, manager)`; `Client::connect(endpoint, address)` are test injection boundaries.
- `Store::{commit_session,snapshot,events_after,claim_approval,finish_approval,begin_operation,finish_operation,recover}` own durable transactions.
- SQLite schema version 1: sessions, approvals, events, operations, devices, pairs and metadata. `operations(device,id)` is the unique deduplication key; event `seq` is monotonic.

## 3. Contracts
ABP ALPN is `agent-bridge/1`. Frame length is big-endian u32 and includes type byte plus protobuf payload; default upper bound 1 MiB. Hello, StreamOpen, RPC, error and event envelopes use frozen protobuf tags in `schema/abp-v1.proto`; business payload JSON is explicit within the schema. Preserve JSON null as a present successful RPC result.

Generate session/run/task identities centrally before native task submission, since native events may arrive before its RPC response. Native stdout processing continues independently of command waits. Native request numeric and string IDs remain distinct. `serverRequest/resolved` must match request ID and thread; pipe write alone does not resolve an approval. Only native permitted decisions are exposed: live requests can omit decline even when older evidence included it.

Persist operation registration before side effects, state with matching events atomically, and approval Pending→Resolving with a database transaction. Serialize each session's snapshot writes and final approval aggregation with the same state gate; do not await native I/O under the global sessions lock. Successful native acknowledgment and simultaneous task completion must not resurrect an ended approval.

Authenticate the peer using iroh, never a supplied device ID. Empty grants deny control. Per-stream and per-method checks enforce permission expiry/revocation; pairing requires one-use token plus separate local grant approval. Mac identity is Keychain-backed; development client file identity is created mode0600. Acquire the database daemon lock before recover; opening another administrative Store must not invalidate live runs.

On restart, pending operations become OutcomeUnknown and live sessions require explicit recovery. Preserve tombstones against replay; do not auto-resubmit native work. Resume means conversation history with a new run, not process survival. Event pruning cannot remove authoritative state.

## 4. Validation & Error Matrix
- Unauthorized/expired grant → Unauthorized, no mutation.
- Stale run → SessionGone; unavailable capability → Unsupported.
- Disallowed decision or malformed params → InvalidParams; wrong approval version or reused operation with new content → Conflict.
- Ended/expired approval → ApprovalEnded; no native write.
- Ambiguous delivery/storage-after-side-effect failure → OutcomeUnknown; no automatic retry.
- Cursor predates retention → SyncGap; fetch snapshot again.
- Oversized/malformed frame → stream failure before allocation/execution; bounded output/response exhaustion → ResourceLimit.

## 5. Good / Base / Bad Cases
Good: persist task before turn/start; receive real Pending request; atomically claim once; match native resolved acknowledgment; observe native terminal status independently.
Base: two clients race; one decision wins, the loser sees ended/conflict. Disconnect releases network resources while native work remains managed.
Bad: approve from assistant text, force decline when native allowed only accept/cancel, treat cancel RPC acceptance as terminal Cancelled, or infer success from writing stdin.

## 6. Tests Required
Protocol tests: fragmented prefix/payload, UTF-8, zero/oversize/truncated/unknown frames, incompatible Hello, frozen protobuf tags and present-null RPC results.
Store tests: independent SQLite connections racing on claims, transaction rollback, snapshot/watermark consistency, pruning gap, restart unknown records and device/pair expiry.
Native tests: fake executable with approvals before submit return, wrong thread/ID, missing acknowledgment, EOF, unsupported request, expiry, next turn, cancel/resume.
Harness: actual loopback iroh + daemon/store/client with two authenticated clients; dedup after lost response, read/revoke checks, reconnect, gaps and reconstructed service recovery.
Opt-in `cargo test -p abp-test-harness --test real_codex -- --ignored --nocapture` uses actual authenticated Codex. Only exact fixed marker commands inside a newly created directory may be approved. Assert marker absence before decision and expected effect afterwards. Preserve simulation vs real-model evidence separately.

## 7. Wrong vs Correct
Wrong: update approval in one transaction, overwrite the task later using an old snapshot; this can regress Completed to Running.
Correct: update approval and aggregate task state transactionally, serializing all competing session writes with the same state gate.

Wrong: prune old operation IDs so retrying an old identifier starts a new task.
Correct: preserve a rejection tombstone after the replay window; resynchronization and a fresh operation ID are explicit caller actions.
