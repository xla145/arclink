# Implementation plan - greenfield desktop

Status: in progress. User approved the latest greenfield plan. Task activated
and implementation delegated with explicit file ownership.

## 1. Contract and build foundation
- [ ] Load trellis-before-dev and relevant current task research/spec context.
- [ ] Create agent-bridge Cargo workspace and pnpm React/Vite/Tauri 2 project.
- [ ] Pin compatible dependencies; compile a minimal Rust command round trip.
- [ ] Define protobuf field tags, DTO serialization and shared error types.
- [ ] Establish fixtures and document raw-I/O permission coupling and limits.

## 2. Daemon core and network
- [ ] Add secure identity, data lock, versioned SQLite and transactional dedup.
- [ ] Add bounded Agent probes and an evidence-backed compatibility registry.
- [ ] Implement process ownership, byte-budgeted relay, stdin serialization,
      exit/generation events and graceful/forced owned cleanup.
- [ ] Implement real iroh endpoint, hello/stream framing, pair/local consent,
      device grants, per-operation authorization, revocation and reconnect.
- [ ] Build test peer/fake Agent coverage before exposing remote mutation UI.

## 3. Native shell and product UI
- [ ] Implement Tauri service setup and command/event adapters using daemon APIs.
- [ ] Implement tray positioning, accessory/template behavior, single instance,
      main hide behavior, inline pairing view and guarded shutdown.
- [ ] Recreate prototype hierarchy with components, hooks, styles and bridge.
- [ ] Wire real device/Agent/process data, QR/permissions/revoke, errors/retry,
      settings, autostart and log actions; keep fixtures preview/test-only.
- [ ] Validate race handling, stale snapshots, busy/error UX and cleanup.
- [ ] Apply latest user UX direction: prototype outer/card radii and pairing QR
      inside the existing panel, with no secondary native window. Verify return
      navigation, cancellation failure and successful/expired invitation cleanup.

## 4. Verification and delivery
- [ ] Run automated gates below and fix failures within assigned scope.
- [ ] Validate browser UI states at panel size in light/dark; record previews.
- [ ] Build/launch native macOS app and inspect actual tray/window/quit behavior.
- [ ] Inspect bundle assets, icons, architecture and signature; build DMG.
- [ ] Run independent Trellis check against PRD acceptance, not historical tests.
- [ ] Update applicable host specs and README; record exact evidence, deferred
      platform/native-Agent checks, build outputs and journal progress.
- [ ] Review diff, preserve unrelated user edits and follow commit/wrap-up rules.

## Commands (Rust from agent-bridge; pnpm from agent-bridge/desktop)
- cargo fmt --all -- --check
- cargo clippy --workspace --all-targets --locked -- -D warnings
- cargo test --workspace --locked
- corepack pnpm install --frozen-lockfile
- corepack pnpm exec tsc --noEmit
- corepack pnpm test --run
- corepack pnpm build
- corepack pnpm tauri build --bundles app,dmg
Define the listed frontend scripts in the new package. Initial dependency
resolution creates the lockfiles; all subsequent checks use them. If the
installed Corepack cannot supply pnpm, resolve that toolchain issue explicitly
without creating a second package-manager lockfile.

## Required behavioral evidence
Protocol: fragmented/coalesced/zero/oversize/truncated/unknown frames, version
negotiation, resource limits and serialization parity/null/u64 boundaries.
Store: independent connection races for pairing/operations, expiry, revoke,
request fingerprint conflicts, crash/unknown transitions and restart loading.
Relay: actual fake child pipes, slow receiver overflow/gap, stderr separation,
large concurrent stdin writes, detach, EOF, exit, old generations and process
cleanup. Test helpers cannot leak spawned processes on assertion failure.
Network: real iroh peer pair/approve/start/I/O/stop/revoke, response loss and
same-operation retry, unauthorized/wrong-peer streams and revoked live input.
UI: successful/failed commands, confirmation cancel, expiry/cancel/reopen,
subscription cleanup, out-of-order responses, no production mock fallback.
Native: tray show/hide, Esc/blur, second launch, bounded layout, quit with active
owned child, Keychain errors and login setting behavior without silently
registering login during tests.

## Delegation and sequencing
After user review and task.py start, dispatch Trellis implement/check agents
with Active task in the prompt and native context injection or child fallback.
First freeze compileable protocol/daemon DTO contracts; then split ownership
between Rust core, desktop UI and native integration only when boundaries are
stable. Workers must not revert other agents' edits. Keep Cargo.lock/shared
contracts owned by one worker. Main session owns planning/spec/journal changes
and integration decisions. Independent check runs after integrated behavior.

## Risks and rollback gates
- Dependency/network/Keychain restrictions may require environmental approval;
  record failures instead of pretending the native app ran.
- Existing doc/agent-bridge-plan.md modifications, mobile HTML and IMG files
  are user work; do not revert, reformat or stage them for this task.
- New authoritative schemas/contracts precede implementations; breaking a
  reviewed scope decision returns to planning, not an undocumented shortcut.
- Never enable an unverified Agent or infer remote reachability from startup.
- Final planning summary was approved before product implementation started.
