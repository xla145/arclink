# Herdr removal

User request: remove Herdr from supported Agents.

Removed host discovery registration, desktop preview entry and iOS selectable options/theme token. Retained decode-only legacy enum value to preserve old snapshots; old host discovery is filtered on iOS. Historical research artifacts remain as historical evidence.

Validation: agent-adapters 8 passed, 1 opt-in live probe ignored; desktop 45 tests and production build passed; iOS UnifiedProjectsTests 4 passed; signed device build passed; git diff --check passed. Workspace-wide cargo fmt --check reports pre-existing unrelated formatting differences.
