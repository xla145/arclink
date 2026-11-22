# Technical Design

## Boundaries

`agentd` owns the Environment, Project, Thread, Run, ProviderSession, messages, approvals and event projections. `ProcessManager` owns OS process lifecycle and bounded byte I/O only. `agent-bridge-client` owns connection, subscription and replay recovery. iOS and desktop render projections and send typed commands.

The local desktop Tauri command path and remote ABP path call the same application service. Provider protocol parsing exists only in Rust. Existing iOS native Codex protocol code remains available behind a legacy feature during migration but must not drive a managed Thread concurrently.

## State flow

`command -> authorization/idempotency -> transactional state + event + outbox -> Provider worker -> normalized event -> projection -> subscription`.

The bounded wait loop checks committed events and current authorization; it is not an unbounded push stream. The authoritative cursor is a SQLite sequence. A subscriber requests a snapshot when its cursor is outside the retained window, otherwise it replays events after the cursor.

## Storage

Extend the current schema through ordered migrations rather than a schema string equality check. Add `projects`, `threads`, `provider_sessions`, `runs`, `messages`, `approvals`, `domain_events`, `command_receipts`, and `effect_outbox`, with unique command and external-provider identifiers. Keep existing `operations` and `processes` for compatibility.

## Protocol

Advertise `managed_catalog_v1`, `thread_sync_reads_v1`, `managed_execution_v1`, `thread_events_v1`, `history_pages_v1`, and `approval_api_v1`. Use typed JSON DTOs inside existing RpcRequest/RpcResponse. Live subscriptions use bounded `threads.wait` and durable replay over Control RPC; no new stream kind is introduced. Events carry environment ID, sequence, aggregate ID, revision, schema version and payload. Keep all existing frame limits and raw AgentIO behavior.

## Provider migration

Implement the first provider through the concrete Rust Codex session actor with open/resume/send/interrupt/approval and normalized events. A shared Provider trait and fork are deferred until a second provider requires them. A ProviderSession is the only reader/writer of a managed Codex app-server process. iOS sends `threads.send`; it does not write Codex stdin directly for new managed Threads.

## Compatibility and rollout

Feature-gate server-managed Codex. Existing Process RPC continues to require owner_device_id and operates as before. New Thread RPCs use Thread permissions and do not inherit creator-device ownership. Old provider history remains a separate read-only catalog; managed Threads do not implicitly take over those sessions.

## Recovery

On restart, mark active sessions for reconciliation. Query provider-native state when supported; otherwise persist `outcome_unknown` and never retry a user message automatically. Process generations fence stale leases. Snapshot and event cursors are committed together on the client.

## Claude extension

Add a Claude stream-json actor behind a provider-neutral managed session dispatch boundary, sharing the existing normalized public event projection and bounded process pump. Native control initialize/interrupt/can_use_tool exchanges follow the official Anthropic Agent SDK. Launch with verbose partial stream output and host permission prompts, persist the native session UUID, and pass explicit resume only for a stored ArcLink-owned session. Claude input full-write acknowledgement does not imply model completion; EOF before result is unknown. UI creates threads using explicit provider identity and labels messages accordingly. The legacy iOS-owned Claude draft plan is superseded for this managed path.
