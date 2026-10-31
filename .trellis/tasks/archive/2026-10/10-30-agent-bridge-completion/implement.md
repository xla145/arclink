# Execution plan

Planning status: user approved the final scope with “开始”; task activated on 2026-10-30. Implementation delivered by three Trellis workers (protocol/store, native adapter, service/client/harness); independent Trellis check completed, final fault regressions and locked workspace verification passed.

1. Restore workspace compilation and add the deterministic fake-native harness. Record baseline and protect Phase 0 evidence.
2. Implement shared protocol contracts and bounded parsers, with malformed, fragmented, coalesced and oversized input tests.
3. Implement SQLite state/events/operations/grants and independent-connection CAS/restart tests; enforce state transition and uncertainty rules.
4. Refactor native adapter and session manager into independent continuously running actors. Validate ID correlation, multiple turns, competing approvals, expiry, cancel and process loss.
5. Wire daemon authorization, stable identity, bounded transport, local grants/revoke and restricted pairing. Wire transactional snapshots, event replay and retention gaps.
6. Implement Rust client and local example/CLI; verify two clients, disconnect/reconnect, lost response with same operation ID, slow reader and revoked connection.
7. Run real Codex command-approval scenarios only in a fresh isolated test workspace; reuse Phase 0 evidence contracts and record new outcomes separately. Disable unsupported approval capabilities.
8. Update README/configuration and phase completion matrix, record remaining iOS, packaging and expansion tasks. Run Trellis check review and remediate findings.

## Validation
- `cargo fmt --all -- --check`
- `cargo test --workspace --locked`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- Fake-native and SQLite tests must exercise actual production paths, not duplicate state machines.
- Transport tests use loopback endpoints and two independently authenticated clients; native integration checks pre-approval marker absence and post-decision effects.
- Restart tests reconstruct the service from the database and assert no native mutation replay.

## Ownership and gates
Implementation/check use Trellis sub-agents after explicit approval of this final planning summary. Curated manifests provide spec and research context. Changes are restricted to agent-bridge plus task/spec documentation; Phase 0 is reference evidence. Review after protocol/store contracts before wiring callers. If new evidence materially changes product scope, update planning and request review. There is no Git repository; retain file-level changes and report that commit is unavailable rather than creating a repository.

## Implementation evidence checkpoint
- Native actor tests: 10 pass; protocol/store tests: 13 pass; service regression tests: 6 pass; transport harness first 6 pass.
- Real Codex daemon/client loopback marker scenario passed (17.23 seconds); actual available decisions accept/cancel enforced. Sanitized record: agent-bridge/fixtures/validation/real-codex-2026-10-30.json.
- Independent review fixed present-null RPC response, UTF-8 byte retention and coordinated lifecycle/approval serialization races. See research/check-review.md.
- README and IMPLEMENTATION_STATUS.md document operation tombstone growth and absent archival/pagination, physical-device and Keychain deployment checks.

Final result: all eight implementation stages completed for the approved Rust delivery boundary. See validation.md for 37-test suite, separate real Codex run and deployment limitations.
