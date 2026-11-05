# Execution plan

Status: in_progress; user approved the final planning summary and task.py start completed on 2026-11-01.

## 1. Shared contracts and focused transport tests
- [x] Load package/layer specs and before-dev instructions in implementation context.
- [x] Snapshot current diffs; preserve unrelated iOS edits and never stage VPS credentials.
- [x] Implement typed bounded relay/address-hint validation and redacted secret handling.
- [x] Keep legacy APIs as wrappers and add optional config/hint entry points.
- [x] Create authenticated private relay fixtures using the version-pinned iroh server/test facilities.
- [x] Prove direct and forced-relay ABP RPC, invalid authentication, unreachable relay with direct hints, and path upgrade behavior.

## 2. Desktop configuration and invitation flow
- [x] Add separate relay Keychain credentials and public descriptor/write-only command contracts.
- [x] Add compact settings controls; preserve existing settings/DTO compatibility.
- [x] Configure host private relay with IP transports and HTTPS probes retained.
- [x] Apply changes without terminating running Agents; restore settings on failure and respect lifecycle guards.
- [x] Add optional relay/address metadata only to transient invitations; exclude secrets from events/snapshots/logs.
- [x] Add actual path-kind projection and status display.

## 3. iOS endpoint/configuration lifecycle
- [x] Extend shared endpoint registration by canonical relay origin with race-safe staged ownership and rollback.
- [x] Add typed QR parsing and iOS Keychain storage; keep old records, old QR and old FFI callers compatible.
- [x] Persist optional non-secret peer hints/credential references; restore before reconnect.
- [x] Add relay-refresh/re-scan behavior for existing devices without losing workspace or duplicating endpoints.
- [x] Preserve per-host connection isolation during failed pairing, removal and configuration changes.
- [x] Project actual selected path and localized actionable errors into existing settings/status rows.

## 4. Verification and generated artifacts
Run from `agent-bridge/` unless specified:

```sh
cargo test -p abp-protocol -p agentd -p agent-bridge-client -p abp-test-harness --locked
cargo check --manifest-path desktop/src-tauri/Cargo.toml --locked
bash scripts/ios-build-client.sh
```

If a shared network crate is introduced, add its focused test suite. First inspect existing test names/features for authenticated relay fixtures; do not broaden unrelated suites after relevant checks pass.

From `agent-bridge/desktop/`:

```sh
corepack pnpm test --run
corepack pnpm build
```

From `agent-bridge/ios/` use an available simulator from `xcrun simctl list devices available`:

```sh
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

- [x] Add meaningful rollback/isolation tests for new configuration behavior; keep mock and real-network evidence separate.
- [ ] Inspect changed desktop settings and iOS device settings in light/dark modes.
- [x] Audit fixture/generated/snapshot/log output for secret leakage.
- [x] Run Trellis quality check through the required reviewer; fix findings.

## 5. Authorized deployment integration and acceptance
- [x] Privately provision the current desktop Keychain from the protected VPS token; never place it in source or tool output.
- [ ] Verify public relay still healthy and existing websites unchanged if any server access is necessary.
- [ ] Launch the updated desktop and perform real iOS pairing/connection if a device is available. Desktop dev runtime is running and final physical app is installed; phone lock prevents launch/pairing.
- [ ] Record observed direct/relay path, relay-to-direct behavior and reconnection on network changes.
- [x] Record cellular/physical-signing limitations explicitly; do not substitute SSH-tunnel evidence for app acceptance.
- [x] Update the relevant host/desktop/iOS specs and READMEs with new contracts.
- [ ] Review the complete diff, report check results and limitations; commit only with authorization under the project's commit flow.

## Task context and dispatch

The main session owns PRD/design/scope, task activation, integration, specs and user communication. After final summary approval, use Trellis implementation/check subagents with curated context. Every dispatch begins with `Active task: .trellis/tasks/11-01-arclink-private-relay`. Tell writers they are not alone and must preserve others' edits. Prefer sequential ownership of shared Rust/FFI interfaces, then desktop/iOS consumers, to avoid concurrent generated-code conflicts.

## Rollback checkpoints

1. Before native storage writes: preserve prior credential/settings and use isolated test accounts.
2. Before transport apply: preserve daemon/process ownership and existing host identity.
3. Before FFI generation: capture generated diff and preserve unrelated source edits.
4. Before provisioning this machine: retain prior app relay metadata/Keychain entry privately; rollback only the new configuration, never the device identity.

## Scan-only refinement (authorized)

Gap: transport and QR already combine both paths, but settings exposed unnecessary credential forms. UI ownership is SettingsPanel.tsx and iOS SettingsViews.swift; update associated UI tests and docs. Remove manual entry, retain automatic QR import, existing-device refresh, native/admin provisioning and transport APIs. No protocol/identity changes or new cloud provisioning service. Validate frontend tests/build and iOS compilation; review scan-to-Keychain-to-reconnect flow.

Scan-only refinement: implementation/review complete, desktop20 tests + build passed, final simulator test build passed. UI/runtime test execution and real phone network acceptance remain open as documented in verification.md.

## Local conversation cache follow-up (authorized)

1. Read iOS state/spec and trace autoImportMacProjects + ProjectEditor direct RPC.
2. Persist successful cache freshness/catalog as needed, with old JSON compatibility, device/Agent isolation and stale/error behavior. Reuse one store loader for automatic import and project picker.
3. Keep cached rows immediate, add manual refresh and coalesce in-flight requests; do not mark failures fresh or apply late responses.
4. Focused cache tests assert RPC counts across relaunch, TTL/force/empty/error behavior, concurrent load and isolation. Build simulator test targets and physical app; execute XCTest only if simulator responds.
5. Trellis check, update cache contracts/docs and final installation; preserve unrelated edits and pending relay network acceptance.

Conversation cache follow-up: implementation/review/spec sync complete; final simulator test-target build and physical build passed,9 meaningful cache cases compile. Runtime XCTest remains blocked as recorded. Final device installation recorded in verification.md.

## Pairing follow-up (authorized)

- [x] Trace authenticated pairing, approval receipt, scanner presentation and nested device chooser.
- [x] Require approved/nonpending result; remove unauthenticated HTTP success fallback and guide legacy QR refresh.
- [x] Publish durable success and dismiss chooser/reset Home navigation, including same-device refresh. Show approval progress.
- [x] Add relay-only exported client pairing test with controlled pending/approved responses and Swift completion/cancellation/storage assertions.
- [x] Run focused Rust tests and Swift build/test; record physical cellular acceptance separately. 15 Rust and 24 Swift functional tests pass; unsigned native Keychain test fails separately as recorded in verification.md.

## No-Mac-reaction follow-up (authorized)

- [x] Separate actual protocol milestones from initial connecting UI.
- [x] Add whole-startup and fixed approval deadlines, preserving compatibility entry points.
- [x] Assert blocked setup returns bounded failure and never emits approval; force-relay success asserts stage order.
- [x] Integrate shared Apple OS DNS helper on mobile endpoint; verify root's actual-host DNS diagnosis independently of UI.
- [x] Rebuild both iOS slices/bindings, Swift tests and physical app; record live relay evidence and remaining physical scan limitations. Final Rust 16/16 and Swift functional 25/25 pass; signed physical app installed without reset.

## Slow successful catalog follow-up (authorized)

- [x] Measure actual native catalog and isolated local exported-client/ABP path.
- [x] Measure baseline production relay path; confirm RTT rather than disk/size cost.
- [x] Pipeline bounded Control Open and read-only catalog request; retain negotiation/auth validation and mutation ordering.
- [x] Add withheld-reply pipeline regression, incompatible/unauthorized cases, exact-once stream EOF, oversized fallback and mutation-after-ACK tests.
- [x] Review and compare real relay timings, rebuild slices and install signed phone app preserving data. Client18/18 plus strengthened exact-once regression pass; relay median3.205s→2.075s; signed phone app installed; launch blocked by locked phone (recorded), no repeated attempts.


## Combined reply and execution summary follow-up (authorized)

- [x] Trace imported/live message rendering and actual native tool result shapes.
- [x] Implement shared user-bounded display grouping without rewriting source records.
- [x] Add optional structured historical outcome and backward-compatible live turn metrics.
- [x] Verify grouping, images, tool correlation, unknown/failed outcomes, replay and old-storage compatibility; independent review.
- [x] Build updated native slices/FFI and Swift test targets; inspect light/dark and accessibility-size screenshots.
- [x] Install final signed iPhone build preserving data and record exact validation evidence.


- [x] Visual refinement: compact header/copy, body-first reply, compact process disclosure, typed metric footer; inspect light/dark render and rerun focused UI checks before final phone install.
