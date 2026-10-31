# Design

## Boundaries and flow
`abp-protocol` owns schema, bounded length/type/protobuf framing, IDs and typed errors. `agent-store` owns SQLite transactions, migrations, durable state, device grants, operation claims and ordered events. `agent-adapters` owns a continuously polled native actor and bounded command interface. `agentd` owns authorization, runtime registry, reconciliation and network dispatch. `agent-bridge-client` owns connection negotiation and sync; `abp-test-harness` owns fake native peers and fault scenarios.

Commands flow from authenticated endpoint through stream and method permission checks, validation and durable operation registration, then to a per-session actor. Native events independently feed durable state transactions. Never retain the global session map lock across native I/O. Assign session/run/task IDs centrally and carry them through native correlation.

## Approval and uncertainty
Persist Pending before publishing. Atomic conditional claim validates run, request version, deadline, allowed decision and task state. A successful pipe write remains Resolving; matching serverRequest/resolved confirms receipt. Native termination invalidates outstanding requests. Timeout or ambiguous delivery becomes OutcomeUnknown. Unsupported approval types and unvalidated CLI versions fail closed. Native request string/number identity is preserved.

## Persistence and sync
Use SQLite transactions for authoritative records and associated event sequence; snapshot plus watermark comes from one read view. Device + operation ID is unique with canonical request digest and stored result. Register before external execution; unfinished operations reconcile to unknown on restart. Event retention does not delete live state. Cursor older than retention returns Gap; slow subscribers reconnect rather than stall native output. Capacity and retention limits are configurable with bounded defaults.

## Network and identity
Replace the unfinished JSON-line network prototype with explicit versioned ABP framing; native stdio remains bounded JSONL. Validate length before allocation, enforce stream kind/direction and protocol limits. Preserve endpoint identity in protected platform storage; production macOS target uses Keychain, tests inject ephemeral identity. Local grants bootstrap trusted devices; Pair is a restricted separate flow with one-use expiring token and local confirmation. Revocation closes live streams and prevents further operations.

## Client
Provide async typed methods and a runnable local CLI/example. Preserve operation IDs across retries, use GetOperation after timeout, and resynchronize before permitting stale approvals. Reconnect has bounded jittered backoff; authorization failure stops retries. Unsupported terminal/file APIs return Unsupported.

## Compatibility and rollback
No documented existing external client or deployed database was found. Freeze the new schema and migration version with compatibility tests; do not silently accept old unbounded JSON as ABP v1. Back up any real database before migration, reject unknown future versions, preserve Phase 0 fixtures. Implement in independently verified stages; leave unverified features disabled. Real-network, Keychain and native environment constraints are recorded as validation limitations, never counted as passes.
