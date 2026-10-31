# Agent Bridge control and recovery completion

## Goal
Complete the existing `agent-bridge/` Rust workspace against `doc/agent-bridge-plan.md`, prioritizing a verifiable single-Codex control loop and Phase 1 foundations. Deliver a usable Rust client and daemon with durable authoritative state and regression coverage.

## Evidence
- `agent-bridge/crates/agent-store/src/lib.rs:1`, `agent-bridge/crates/agent-bridge-client/src/lib.rs:1`, and `agent-bridge/crates/abp-test-harness/src/lib.rs:1` are placeholders.
- `agent-bridge/crates/agent-adapters/src/codex.rs:427` and `agent-bridge/crates/agent-adapters/src/jsonrpc.rs:32` prevent baseline compilation (`cargo test --workspace --locked --offline`, exit 101).
- `agent-bridge/crates/agentd/src/session_manager.rs` has no continuous event consumer, retains completed tasks as active, and holds the global sessions lock during native calls.
- `agent-bridge/crates/agentd/src/endpoint.rs` accepts connections without enforcing the device registry; empty registry permits everyone.
- `agent-bridge/crates/agentd/src/handler.rs:171` returns no approvals and a zero watermark. Run and operation identifiers are not enforced.
- `phase0/compat-record.md` and `phase0/validation.json` document successful local command-approval validation for Codex 0.165.0. This does not validate the current daemon, file-change approvals, or network races.

## Requirements and Acceptance
R1 Build and native lifecycle: workspace compiles; an independent event loop observes approvals, terminal statuses and process exit; a completed/cancelled turn permits the next turn. Concurrent sessions must not block behind a global native I/O lock.
R2 Approval integrity: correlate daemon session/run/task and opaque native IDs, enforce request version and allowed decisions, allow one atomic winner, and confirm native receipt before Resolved. Expired, old-run and completed-task requests cannot write a decision. Unknown delivery cannot auto-retry. Only the validated command-approval subset is enabled.
R3 Durable state: SQLite migrations, atomic state/event writes, device-scoped operation IDs with content conflict detection and at least seven-day retention. Restart preserves records, invalidates old runs/approvals and records uncertain outcomes without replaying side effects. Storage failure rejects new mutations.
R4 Transport and authority: bounded ABP protobuf frames, Hello/StreamOpen validation, stable endpoint identity, explicit local device permissions, deny-by-default, per-operation checks and revocation affecting live connections. Add restricted pairing with local confirmation. Unknown operations and malformed/oversized frames fail explicitly.
R5 Sync and client: implement consistent snapshots/watermarks, incremental replay, explicit retention gaps, bounded subscriptions and Rust client APIs plus a runnable CLI/example. Disconnect does not terminate or block native work; reconnect reauthorizes and resynchronizes. System uptime and task summaries are real values.
R6 Validation and documentation: deterministic fake-native fault tests, database race/restart tests, local two-client transport tests, usage/configuration documentation and an honest phase-status matrix. Real Codex validation is reported separately from simulated tests.

## Proposed delivery boundary for review
This iteration targets the six Rust crates and local development scripts/docs. iOS/UniFFI packaging and device validation, LaunchAgent/menu-bar release packaging, Generic PTY, additional agents, APNs and file preview remain explicitly tracked follow-ups from Phases 2–4. No claims of complete product delivery or surviving OS process recovery.

## Constraints
Preserve existing Phase 0 evidence. Use native permission mode on-request/user/read-only. Do not approve arbitrary commands in validation. No Git repository currently exists at the project path; do not initialize or claim commits implicitly.
