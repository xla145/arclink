# Validation evidence

## Visual acceptance

Used agent-browser against the local Vite development server at 320×480. The explicit browser preview is labelled as sample data and is not evidence of native command execution.

- Inspected settings and recent-log views in light and dark appearances.
- General preferences appear first, with autostart and keep-awake visible in the initial settings viewport. The existing updater is in Application.
- Recent logs, refresh, copy, export and open-folder actions fit within the panel.
- Document width/height remained 320×480 with no document overflow. Scrolling is bounded inside the panel.
- Keyboard Tab reached the host-name input with a visible solid focus outline.
- Preview screenshots are saved under `/Users/mac/.codex/visualizations/2026/11/05/01a1a940-da6f-7c42-875a-7e798efe15bf/desktop-settings/`.

## Implementation validation

Final checker verified frontend production build/typecheck and 32 frontend tests; 11 desktop Rust tests passed, including real named IOKit assertion acquisition/release checked through `pmset` scoped to the test PID, duplicate-enable stability, temporary saved-true restoration, disable/stop cleanup and failed persistence rollback. Changed-file Prettier, desktop rustfmt and `git diff --check` passed.

Final native debug application rebuilt after checker fixes at `agent-bridge/target/debug/bundle/macos/ArcLink.app` (76.28 MiB); existing packaging uses an ad-hoc signature, whose integrity passed `codesign --verify --deep --strict` again. This is a development bundle, not notarized release evidence.

## Known limits

- The existing installed production app is running. It was not stopped or replaced for validation; actual tray/save-dialog interaction in the new bundle has not been manually exercised.
- Workspace-wide formatting has pre-existing failures in unrelated Rust files.
- Full dependency Clippy has a pre-existing `if_same_then_else` failure in `crates/agentd/src/agent_projects.rs:117`; the desktop crate also has an existing `single_match` warning in its window-close handler. Task-crate Clippy passed with `--no-deps` and the specific existing `single_match` exemption.

## Final review

Trellis checker completed full-scope review and fixed initial keep-awake loading/failure recovery, actual status refresh on panel focus, scoped helper-text contrast, log-rotation metadata disappearance and process-scoped assertion testing. Added regressions for these behaviors, single-instance updater placement and long-lived export-dialog timeout handling. Final bundle rebuild is complete.

## Updater availability

The production updater is currently unavailable: configured latest manifest redirects to the empty public `v1.0.0` release and returns HTTP 404. Explicit `arclink-v0.1.1` manifest and both architecture archives also return 404. A successful branch CI build skipped the tag-conditioned publish job. Update UI tests 5/5, Rust updater tests 2/2 and release-assembly tests 8/8 passed; passing tests do not establish live distribution availability. Authenticated CI artifact download timed out, leaving those signatures unverified; a stale local archive has a mismatched payload signature and cannot be used for release. Installation/restart was not exercised.

Detailed evidence and repair recommendation: `research/updater-validation.md`. This verification did not mutate any remote release or replace the running application. Publishing a complete version-matched signed release is outside the user's read-only verification request.
