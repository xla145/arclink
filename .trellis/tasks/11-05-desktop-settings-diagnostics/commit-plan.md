# Proposed commit plan

User approved this plan with “可以”. Execute the single feature commit below, then archive this task and record the session.

## Commit 1

`feat(桌面客户端): 优化设置与日志并增加保持活跃`

Includes desktop implementation, dependency lock changes, tests, contracts and task validation (including the requested read-only updater investigation).

- `.trellis/spec/frontend/agent-bridge-desktop.md`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/commit-plan.md`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/implement.md`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/prd.md`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/research/updater-validation.md`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/task.json`
- `.trellis/tasks/11-05-desktop-settings-diagnostics/validation.md`
- `agent-bridge/Cargo.lock`
- `agent-bridge/desktop/src-tauri/Cargo.toml`
- `agent-bridge/desktop/src-tauri/src/diagnostics.rs`
- `agent-bridge/desktop/src-tauri/src/keep_awake.rs`
- `agent-bridge/desktop/src-tauri/src/lib.rs`
- `agent-bridge/desktop/src-tauri/src/runtime.rs`
- `agent-bridge/desktop/src/App.tsx`
- `agent-bridge/desktop/src/bridge.test.ts`
- `agent-bridge/desktop/src/bridge.ts`
- `agent-bridge/desktop/src/components/Diagnostics.test.tsx`
- `agent-bridge/desktop/src/components/LogsPanel.tsx`
- `agent-bridge/desktop/src/components/SettingsPanel.tsx`
- `agent-bridge/desktop/src/preview.ts`
- `agent-bridge/desktop/src/styles/panel.css`
- `agent-bridge/desktop/src/test/snapshot-contract.json`
- `agent-bridge/desktop/src/types.ts`
- `agent-bridge/desktop/src/update.test.tsx`

## Excluded work

All iOS framework binaries, Xcode user state and iOS-redesign research/logs remain outside this commit. No remote releases, installed applications, signing private keys or generated bundles are included.

## Validation

32 frontend tests, 11 Rust tests, frontend build/typecheck, changed-file formatting, final macOS debug bundle and codesign integrity checks passed. Baseline-wide lint failures and native GUI limits are recorded in validation.md. Live production updater returns HTTP 404; no installation/restart or release publication was performed.
