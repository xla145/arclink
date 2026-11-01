# Implementation
1. Extend agentd metadata discovery, attribution and tests.
2. Extend client record and regenerate Swift/static libraries.
3. Preserve source through cache and sync; unknown source explicit, imported histories read-only.
4. Rust regression tests and iOS unit tests/build.

## Current verification
- Backend: 16 agent_projects regression tests passed.
- Client: optional source deserialization regression passed.
- Real local catalog: 37 projects; 30 CLI (27 cli + 3 exec), 213 desktop, 4 unknown; 770 ms.
- iOS device/simulator libraries and generated bindings rebuilt successfully.
- Mac desktop cargo check passed.
- Final iOS simulator regression: 16 tests passed, 0 failures (ConversationTests + ConversationCacheTests).
- Full changed-tree whitespace check passed; focused cross-layer review found no remaining actionable issue.
- Changes remain uncommitted alongside pre-existing parallel work. Mac host and iOS app must both use the rebuilt code.
