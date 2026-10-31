# Independent Trellis review

Reviewed protocol framing/envelopes, SQLite operations/approvals/recovery, daemon authorization/session lifecycle and client behavior against the task artifacts and review matrix.

## Fixed directly
- `abp-protocol/src/messages.rs`: valid successful `result: null` was deserialized as an absent result, corrupting protobuf responses and unknown-operation queries. A present-result deserializer now preserves `Some(Value::Null)`; wire round-trip regression added.
- `agent-store/src/lib.rs`: event retention used SQLite `length(TEXT)` and counted Unicode characters rather than UTF-8 bytes. Both budget sum and removal accounting now cast to BLOB. A Chinese-text retention regression proves a 3000-byte message cannot fit a 2500-byte budget.

## Coordinated fixes verified with service worker
- Stopping an old runtime must remove the registry entry only when its run still matches; otherwise a concurrent resumed runtime can be removed.
- A global start gate must not remain held during native process startup. Capacity covers starting and live sessions while per-ID registration stays serialized.
- Shutdown must reject mutations before closing transport and wait for in-flight native starts before collecting runtimes; started runtimes finishing during shutdown are stopped instead of installed.
- Cancel/stop delivery errors must report OutcomeUnknown, not generic NativeFailure that gets persisted as known completion.

## Verification
- Protocol/store tests: 13 pass (6 protocol, 7 store).
- `cargo check --workspace --locked --offline`: pass.
- `cargo clippy --workspace --all-targets --locked --offline -- -D warnings`: pass at the review checkpoint; parent runs final workspace verification after all additions.
- Service lifecycle regressions: six tests passed, including concurrent native startups and shutdown waiting for/stopping a late runtime. Reviewed the final guard/Notify ordering and run-conditional registry removal.
- Network harness: eight tests passed (worker result, code independently reviewed). New stalled-reader test constrains stream credit to 1 KiB and daemon send window to 4 KiB, holds an unread 512 KiB event burst, verifies a fast client completes the task and next native turn, and observes the five-second writer timeout terminating the stalled stream.
- New SQLite fault test installs a BEFORE INSERT events trigger that raises failure, asserts state/event rollback, zero native submissions, OutcomeUnknown response, and persistent mutation rejection even after removing the trigger. This demonstrates database-write failure handling, not literal physical disk exhaustion.

## Limits requiring honest release notes
- Fake transport tests now cover response loss, competing approvals, disconnect/revoke, pairing, event gaps, restart, stalled-reader backpressure and injected SQLite write failure. Physical disk-full/power-loss and deployment filesystem behavior remain unverified.
- Operation tombstones and authoritative historical session/approval records remain retained. Snapshot construction reads all records before frame-budget checking. This preserves authority but is not a bounded long-term archive design; oversized responses are explicit resource errors rather than pagination.
- Native and deployment/device tests are distinct. Old Phase 0 evidence does not count as current daemon validation.
