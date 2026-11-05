# Execution plan

## Entry gate

- [x] User approved task creation and confirmed idle-system-sleep-only behavior.
- [x] PRD, design and manifests prepared; requirements convergence pass complete.
- [ ] Present final summary and receive explicit implementation approval before `task.py start`.

## Implementation order

1. Record current diffs in affected files; preserve unrelated edits. Read desktop/updater contracts and phase 2.1 context. Dispatch Trellis implementer with active task path and curated manifests after start.
2. Add desktop-native keep-awake ownership, atomic preference storage, bounded diagnostics retrieval/export and typed commands. Register commands and hook startup/shutdown/update lifecycle. Cover native state transitions and IO boundaries using injected test storage/OS backend.
3. Extend bridge types and adapters, including test/preview adapters without fabricated mutation success. Implement grouped settings and one shared log view, navigation/back/Escape, clipboard and export feedback; preserve current updater and exit flows.
4. Add meaningful behavioral coverage for switch errors/state reconciliation, persistence/restore, assertion release, log bounds/rotation and export cancellation. Avoid tests that only mirror CSS or text.
5. Dispatch Trellis checker for full task diff, spec consistency, cross-layer contracts and regression checks. Fix findings and update the desktop spec with final contracts.

## Validation

From `agent-bridge/desktop`: `corepack pnpm test --run`, `corepack pnpm build`.

From `agent-bridge`: `cargo fmt --all -- --check`, `cargo test -p agent-bridge-desktop --lib`, `cargo clippy -p agent-bridge-desktop --all-targets -- -D warnings`. Distinguish pre-existing unrelated formatting/build issues from task failures; do not reformat the whole dirty repository.

Render settings and logs at 320×480 in light/dark appearances, including loading, empty/error, long text and overflow. Run the native app to verify assertion presence with `pmset -g assertions`, switch-off release, restore across restart, hidden-panel continuity and exit cleanup. Check export cancellation and dialog focus. Build the macOS desktop bundle using the existing Tauri packaging path. Report any native verification blocked by environment instead of substituting browser evidence.

## Integration and rollback

Review shared App navigation, runtime lifecycle and updater stop paths carefully. Revert only task-owned hunks if integration fails. Finalize specs, follow repository commit/wrap-up process, and report validation plus any unverified native behavior.
