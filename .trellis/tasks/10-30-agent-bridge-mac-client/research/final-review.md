# Final reviewer verification — 2026-10-31

## Fixed findings

- `crates/agentd/src/network.rs`: revoke followed immediately by regrant could preserve an old connection. Explicit matching revoke now closes it independently of current authorization; broadcast lag also closes conservatively. Real iroh regression added.
- `crates/abp-test-harness/tests/transport.rs`: added view-only permission regression covering allowed queries and denied process/I/O mutations.
- Core owner added a shared snapshot publication gate and bounded durable process history: indexed latest-64 query, bounded terminal snapshot merge retaining live processes, keyed historical lookup, and recovery querying formerly-live rows. Reviewed final paths; 200-history-row regression passes.
- Desktop owner fixed raw CLI version display, mandatory view permission, and retaining pairing ownership/cache after cancellation failure.
- Reviewer ran workspace formatter and fixed Clippy's `while_let_loop` finding in `desktop/src-tauri/src/runtime.rs`; event closure/lag behavior is preserved.

## Remaining finding

- `crates/agentd/src/lib.rs`, `stop_process`: current in-memory process lookup precedes completed-operation lookup. A repeated successful stop after terminal entry eviction or daemon restart returns `process_gone` rather than the stored result. No duplicate side effect occurs. Reported to main agent for follow-up; recommended checking existing operation fingerprint/result before requiring a live entry, retaining ownership checks. This finding is not covered by the passing gate below.

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

Total distinct passing tests: 45 (30 standard Rust + 1 explicit real-Codex + 14 frontend). Repeated scoped runs are not double-counted.

## Scope and limitations

- Backend host and frontend desktop specs reviewed; no obvious contract discrepancy. Document bounded history policy alongside the implementation.
- Native GUI smoke, production packaging/signing, and external-network/mobile interoperability belong to main-agent verification and are not asserted by these tests.
- Transport integration tests exercise actual local iroh with fake Agent and one verified real Codex; they do not demonstrate remote relay/NAT conditions.
