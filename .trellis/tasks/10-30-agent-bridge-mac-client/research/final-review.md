# Final reviewer verification — 2026-10-31

## Fixed findings

- `crates/agentd/src/network.rs`: revoke followed immediately by regrant could preserve an old connection. Explicit matching revoke now closes it independently of current authorization; broadcast lag also closes conservatively. Real iroh regression added.
- `crates/abp-test-harness/tests/transport.rs`: added view-only permission regression covering allowed queries and denied process/I/O mutations.
- Core owner added a shared snapshot publication gate and bounded durable process history: indexed latest-64 query, bounded terminal snapshot merge retaining live processes, keyed historical lookup, and recovery querying formerly-live rows. Reviewed final paths; 200-history-row regression passes.
- Desktop owner fixed raw CLI version display, mandatory view permission, and retaining pairing ownership/cache after cancellation failure.
- Reviewer ran workspace formatter and fixed Clippy's `while_let_loop` finding in `desktop/src-tauri/src/runtime.rs`; event closure/lag behavior is preserved.

## Resolved follow-up

- Core fixed `stop_process` replay after eviction/restart: existing operation fingerprint/result is now checked before target lookup and returned metadata retains owner validation. Reviewer inspected the final path. Core reports 15 daemon + 2 adapter tests and Clippy passing, including the new regression (commit `09c2d26`). The earlier outstanding finding is resolved.

## Same-panel pairing and rounded-window follow-up

- Independently reviewed current frontend/native diff after user's explicit same-panel requirement. Pairing now mounts within the main panel; separate pairing window builder, commands and capability entry are removed. Only `main` is configured and authorized.
- React retains one invitation promise across StrictMode effect replay; native start also serializes and reuses only the matching active invitation.
- Cancel/back/Escape await backend cancellation; cancellation failure preserves the invitation for retry. Success, rejection, cancellation and expiry unmount/clear frontend QR/session; native event forwarding clears the matching terminal invitation cache. Approval hides QR immediately and returns to devices after 1.2 seconds. Expired QR is hidden even when cancellation fails.
- Native transparent/background settings, Cargo `macos-private-api` feature and Tauri `macOSPrivateApi` flag are aligned. Transparent document background and 14px clipping provide rounded outer corners.
- Independent latest `corepack pnpm exec tsc --noEmit && corepack pnpm test --run` from `agent-bridge/desktop/` passed: 19 tests (App 13, bridge 5, contract 1), including StrictMode, inline cancel failure/retry, success, expiry and invitation preservation across hide/focus.
- No new defect found in this focused review. Desktop owner reports latest `cargo check -p agent-bridge-desktop --locked`, Rust format and diff checks passed with transparency/private API enabled; native tests/Clippy were not rerun for this follow-up. Production packaging is in progress under desktop/main ownership; no competing Cargo build was started by reviewer.

## Commands and results

From `agent-bridge/`:

- `cargo fmt --all` — pass; normalized protocol assertion formatting.
- `cargo fmt --all -- --check` — pass after final runtime fix.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` — initial failure on runtime while-let lint; rerun pass after local fix.
- `cargo test --workspace --locked` — pass: 30 tests (protocol 5, transport 7, adapters 2, desktop 2, daemon 14), 1 ignored real-Codex test. All doc-test targets pass (0 tests).
- Earlier independent `cargo test -p abp-test-harness --locked real_codex_initialization_and_read_only_rpc_over_iroh -- --ignored` — 1 pass. Actual installed verified Codex paired, initialized, answered read-only RPC and stopped through local iroh. No model request or thread payload persisted.

From `agent-bridge/desktop/`:

- `corepack pnpm exec tsc --noEmit` — pass.
- `corepack pnpm test --run` — 14 passed (contract 1, bridge 4, App 9).

From repository root:

- `git diff --check` — pass.

Initial full-gate total: 45 (30 standard Rust + 1 explicit real-Codex + 14 frontend). Latest combined evidence: 51 distinct tests (31 Rust including core's stop regression + 1 explicit real-Codex + 19 frontend). The latest combined count includes owner-reported core results; it is not a claim that reviewer reran the full workspace after the transparency changes. Repeated scoped runs are not double-counted.

## Scope and limitations

- Backend host and frontend desktop specs reviewed; no obvious contract discrepancy. Document bounded history policy alongside the implementation.
- Native GUI smoke, production packaging/signing, and external-network/mobile interoperability belong to main-agent verification and are not asserted by these tests.
- Transport integration tests exercise actual local iroh with fake Agent and one verified real Codex; they do not demonstrate remote relay/NAT conditions.
