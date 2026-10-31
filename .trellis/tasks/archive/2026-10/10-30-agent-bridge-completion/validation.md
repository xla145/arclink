# Final verification — 2026-10-30

## Results
- `cargo test --workspace --locked --offline`: PASS, 37 tests, zero failures; one opt-in real test ignored by default.
- `cargo clippy --workspace --all-targets --locked --offline -- -D warnings`: PASS.
- `cargo fmt --all -- --check`: PASS.
- `cargo test -p abp-test-harness --test real_codex --offline -- --ignored --nocapture`: PASS separately, 17.23 seconds.
- Independent Trellis review: research/check-review.md; no outstanding critical findings.

## Coverage mapping
R1: adapter10 + daemon6 tests; real multi-turn test. Continuous native events, shutdown/start race and independent startup verified.
R2: independent SQLite claims, actual two-client loopback competition, request version/run/allowed-set checks, native acknowledgment/expiry tests. Real request advertised accept/cancel only; unavailable decline rejected and cancellation verified.
R3: transaction rollback, device-scoped dedup/content conflict, retained replay tombstones, independent database connections, recovered service refusing old cards/unknown operation replay. Injected event INSERT failure causes no native submit and sticky degraded mode.
R4: frozen typed protobuf envelopes and explicit JSON business bodies; frame bounds, compatibility, deny default, grants, revoke, one-use pairing plus local approval. Keychain code compiled; lock-screen behavior not tested.
R5: consistent snapshot/watermark, gap, response-loss dedup, reconnect/revoke, UTF8 chunks, oversized full-output rejection; small QUIC window + unread subscription proves other-client/task progress and slow-stream timeout. Rust client/CLI and heartbeat APIs implemented.
R6: README/status, sanitized real evidence, project code-spec, no placeholder crates remain.

## Boundaries
Physical disk-full/power-loss, iOS/device and Direct/Relay transitions require deployment validation. Authority archival/pagination and operation tombstone compaction are follow-ups; current oversized snapshots return ResourceLimit. Later plan phases (iOS, packaging, PTY, other agents, push/file preview) were excluded from this approved iteration.

## Repository
No .git exists at workspace or agent-bridge root. No repository initialized or commit fabricated. File changes delivered directly; bookkeeping uses no-commit mode.
