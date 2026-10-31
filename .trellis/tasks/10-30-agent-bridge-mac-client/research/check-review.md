# Mac client independent review

## Scope
Reviewed the versioned local Rust administration channel, CLI lifecycle integration, Swift Codable/framing/process transport, menu-bar model/UI, login integration and app packaging against approved task artifacts and frontend/agent-bridge-macos.md. Product fixes were coordinated with implementers to avoid overlapping file edits.

## Fixed with Swift owner
- `AppModel.start` originally awaited transport.stop before claiming Starting/generation, permitting duplicate startup coroutines to stop each other. It now claims state before suspension; reviewer regression suspends stop and proves only one native start occurs.
- Pairing result originally mutated invitation before checking generation, and old mutation defer could reset new generation busy state. Result application and cleanup now check generation; reviewer regression delivers an old invitation while a new generation mutation is active.
- Old startup refresh could resume and cancel/install polling for a new generation. Poll installation and refreshing cleanup now check generation.
- User Retry now explicitly clears a recovered refresh error; mutation failures remain visible. The regression proves status authority and mutation enablement are restored.
- Pipe writes are serialized; two48KiB concurrent requests exercise data larger than PIPE_BUF. Stdout EOF fails pending requests immediately. Swift6 capture/type errors were removed by the owning implementer.
- Quit confirmation also handles unknown state while failed/starting rather than assuming no tasks exist.

## Reviewer-owned regression tests
`macos/Tests/BridgeCoreTests/AppModelTests.swift` adds4 tests: concurrent startup, old invitation/new busy state, failed status then successful retry, and expired/invalid-permission pairing rejected before any transport mutation. Tests call production model methods with a controllable transport, rather than duplicate the state machine.

## Rust review
Bounded incremental64KiB request parsing, version/id responses, stdout purity, no token in parse errors, explicit permissions including Read, local-only pipe boundary, bounded3s/4KiB Codex probe and actual datastore pairing/revoke behavior are consistent. Existing CLI remains supported; stdin EOF/acknowledged shutdown routes through Daemon.shutdown. Reachability stays explicitly unverified.

## Verification
- `cargo test -p agentd --locked --offline`: PASS12/12 (including6 new local-control tests).
- `cargo clippy -p agentd --all-targets --locked --offline -- -D warnings`: PASS.
- `swift test --package-path macos --scratch-path target/macos-review`: PASS10/10; Swift6 build clean. Requires approved access to standard Swift compiler caches.
- Full package build, signing and visual smoke verification owned by parent. Scripts reviewed for explicit local bundle, helper inclusion and no installation/login registration.

## Remaining boundaries
No outstanding critical code findings. This panel is local host administration, not a full remote task workbench. No mobile app/Relay connectivity or device last-seen is fabricated. Keychain/SMAppService approval, notarization and production distribution remain deployment-specific; automated tests do not register login items. Pair token copied by deliberate user action may remain in the system clipboard; it is not logged or persisted by app settings.
