# Implementation Plan

## Phase 1 — contracts and persistence

- Add migration runner and domain tables in `crates/agentd/src/store.rs`.
- Add Rust domain DTOs and state enums in `crates/agentd/src/types.rs`.
- Add command receipt and event-store transactions.
- Add unit tests for migration, duplicate commands, conflicts and event sequence.

## Phase 2 — Thread service and Codex runtime

- Add application service modules for projects, threads, runs and subscriptions.
- Add Provider trait and Codex driver using the existing app-server semantics.
- Link ProviderSession to ProcessManager without exposing raw stdin to managed clients.
- Add restart reconciliation and outcome_unknown handling.

## Phase 3 — ABP and client synchronization

- Add capability negotiation and Thread RPC DTOs to `abp-protocol`.
- Add snapshot/replay subscription handling to `agent-bridge-client`.
- Expose typed UniFFI Thread events and commands.
- Refactor iOS managed-chat path to use Thread events and service cursors.

## Phase 4 — desktop UI and integration

- Add desktop Thread/project/chat state and approval/interruption actions.
- Keep existing device/process diagnostics.
- Add end-to-end tests: iOS-like client + desktop-like client against deterministic fake Agent.

## Validation

- `cargo fmt --check`
- `cargo test -p agentd --locked`
- `cargo test -p abp-protocol --locked`
- `cargo test -p agent-bridge-client --locked`
- `cargo test -p abp-test-harness --locked`
- `pnpm --dir agent-bridge/desktop test`
- iOS build and protocol fixture tests after regenerating UniFFI bindings

## Rollback points

- Before schema migration: restore SQLite backup and disable Thread capability.
- Before enabling managed Codex: old Process RPC remains the fallback.
- Before replacing iOS chat path: retain legacy CodexChatSession behind the feature gate.

## Claude extension execution

1. Verify official SDK wire shapes and installed CLI read-only initialization.
2. Add bounded Claude protocol/session actor and provider dispatch; retain Codex behavior.
3. Add real transport probe, launch/resume flags and authorized service provider selection.
4. Add desktop/iOS provider selection and provider-aware labels; reuse existing Thread DTOs.
5. Cover streaming/final deduplication, approvals, interrupt, EOF, unknown writes, resume and two-client synchronization; run backend/client/desktop/iOS regression.

## Same-conversation Agent switching
1. Persist provider change, receipt/event, native-binding reset and context transfer; fence retired runtime.
2. Add capability-negotiated client API; regenerate bindings and both XCFramework slices.
3. Add in-chat Agent picker, dynamic model reload and uncertain-command recovery without losing drafts.
4. Validate deterministic cross-provider handoffs, Rust/desktop/Swift regressions and install signed iPhone build.
