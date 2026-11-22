# Same-conversation Agent switch verification — 2026-11-22

## Delivered behavior
- Managed Thread/project/cwd/device identity stays fixed across Codex ↔ Claude.
- Fresh provider-native session per cross-provider transition; bounded public-history handoff on first next turn. Full ArcLink history remains visible; no private reasoning or tool-call replay.
- Dynamic iOS model catalog follows the authoritative Agent. Capability-gated selectors, draft retention, historical attribution/generic legacy labels and durable switch markers.
- Persisted command IDs survive unknown delivery and restart; retries reuse IDs. Send and configuration changes stay fenced until reconciliation. Invalid pending storage fails closed.
- Backend runtime membership mutex fences retired callbacks including Ready/native ID. No async wait while holding membership lock.

## Evidence
- Rust client library: 21 passed.
- Desktop: 50 tests passed; TypeScript + Vite production build passed.
- iOS AgentBridgeTests: 144 passed (0 failures), including managed state/persistence/attribution tests.
- Signed iPhone Debug build: passed. Installed to iPhone UDID 00008140-000C711434C2801C, bundle com.xula.ArcLink; installation container 04E3E6AD-E26C-47E2-B5CB-7A618A027240.
- Both iOS XCFramework slices and Swift UniFFI API regenerated together.
- Mac cargo check and Tauri debug app bundle passed; codesign --verify --deep --strict passed. Artifact: agent-bridge/target/debug/bundle/macos/ArcLink.app (local ad-hoc signing, not notarized).
- git diff --check passed.

## Review and limits
Read-only cross-layer review checked RPC receipts/ACL, native session fencing, handoff lifecycle, uncertain recovery and attribution. Fixed generic historical attribution and fail-closed pending-storage recovery in desktop. Shutdown/reopen regression from async gating was found and fixed with synchronous membership fencing.

Deterministic provider integration verifies routing/context transfer. This run does not claim physical multi-Mac or paid live Claude/Codex end-to-end acceptance. Existing native/imported chats are not silently migrated. The installed phone needs a Mac running this new host build for managed_provider_switch_v1. No commit, push, task archive, credentials or bundle identity changes.
