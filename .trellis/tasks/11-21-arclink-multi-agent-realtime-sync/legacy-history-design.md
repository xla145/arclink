# Legacy history compatibility — 2026-11-22

## Gap and owner
Unified projects currently combine only project identities. Native/imported histories and managed threads have separate ordering, project activity ignores managed updates, and successful empty/partial native catalogs remove persisted history. The iOS AppStore owns source reconciliation; UnifiedProjects owns presentation; ChatView owns explicit read-only history continuation.

## Implementation boundary
- AppModel.swift: retain imported project/session/message/approval identities on source omission, mark sourceUnavailable on imported sessions, clear when rediscovered. Add backward-compatible persisted field. Keep explicit local deletion and source cache freshness/rollback/generation rules.
- UnifiedProjects.swift and HomeView.swift: derive one ordered list/activity/count from managed and legacy conversations; preserve original routes and per-device/project identity.
- ChatView.swift, NewManagedTaskSheet.swift and a small ImportedHistoryContinuation helper: explicit public-history continuation creates a new managed thread using existing durable task IDs. User picks Agent/model and sends; original native history remains read-only. Capture source device/path, keep continuation on same device/project, quote bounded public user/final-answer text; exclude tools/reasoning/images. Show source/context preview. No automatic external send or native takeover.
- XCTest: empty/partial source, reappearance, rollback, persistence migration, mixed ordering/count, continuation filtering/bounds and retry payload preservation.

## Limits
No new backend protocol/schema/FFI, native history migration, automatic deletion, cross-device continuation, private reasoning/tool-call replay or duplicate identity heuristics. Missing source indicates unavailable catalog data, not proof of deletion. Cached message body persistence is unchanged.

## Validation
Relevant XCTest then full AgentBridgeTests, signed device build/install, git diff --check. Record concrete outcomes, keep task active/uncommitted.

## Final verification — 2026-11-22

- Compatibility tests: 28 passed, 0 failures.
- Full iOS `AgentBridgeTests`: 155 passed, 0 failures.
- `git diff --check`: passed.
- Device build: `** BUILD SUCCEEDED **` for `com.xula.ArcLink`.
- Device install: succeeded on iPhone UDID `00008140-000C711434C2801C`.

The device build emitted two pre-existing Swift warnings (`withAnimation` unused result and mutable weak callback owner under Swift 6); neither is related to legacy-history reconciliation.

## New-task failure follow-up — 2026-11-22

Repeated new tasks against an already registered canonical project root attempted a second INSERT into the unique projects.canonical_root column. The host returned a storage error; iOS incorrectly grouped that response with uncertain delivery and hid the failing step. Project registration now reuses the authorized existing identity, records the new command receipt without emitting another project-created event, preserves the existing name, and rejects conflicting names or unauthorized principals. Regression tests cover reuse, access isolation, replay after directory removal and changed fingerprints.

Validation: full agentd tests 127 passed; signed iPhone build and installation succeeded. The iOS notice now names the failing stage and error code while retaining immutable command IDs. The Mac development client also encountered a saved UDP port collision with verge-mihomo (49772); the prior bind configuration was backed up to /tmp/arclink-network-bind-before-project-fix.json, then changed to an unused IPv4 port. Host initialization succeeded afterward. Pairing identity and history were preserved. End-to-end phone retry still requires the user's original pending task.
