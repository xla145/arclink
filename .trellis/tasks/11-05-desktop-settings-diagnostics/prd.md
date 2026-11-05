# Desktop settings and diagnostics

## Goal

Make ArcLink desktop settings easier to scan, make local diagnostic logs easy to retrieve, and let users keep the host awake for remote Agent work.

## Confirmed Background

- Scope is the Tauri 2 + React client in `agent-bridge/desktop`, embedding agentd.
- Preserve its 320px-wide, at-most-480px-high menu-bar panel, bounded scrolling, light/dark themes and hide/reopen behavior (`.trellis/spec/frontend/agent-bridge-desktop.md`).
- Current settings contain host naming, OS autostart, connection information and exit (`agent-bridge/desktop/src/components/SettingsPanel.tsx:69`).
- The footer log action only opens the fixed app log directory (`agent-bridge/desktop/src/App.tsx:423`, `agent-bridge/desktop/src-tauri/src/commands.rs:154`).
- Logs must remain rotated and exclude credentials, invitation payloads and raw Agent output. Browser previews cannot establish native functionality.
- Preserve existing unrelated changes in the workspace.

## Requirements

- R1: Organize settings into compact sections for general preferences, connection, diagnostics and application information/actions. Preserve naming, autostart, update and exit functions.
- R2: Provide recent local-log viewing, refresh, copy and export, while retaining open-folder access. Handle loading, empty logs and failures accurately; retain loaded content if refresh fails.
- R3: Add a deliberate keep-awake switch, default off, with persisted preference and actual OS-state feedback. Prevent idle system sleep only; allow normal display sleep and locking, as explicitly chosen by the user. Continue while the panel is hidden; release the owned prevention mechanism when disabled or the application exits.
- R4: Preserve the existing desktop design language, accessible labels and keyboard focus, and readable long values.

## Acceptance Criteria

- [ ] AC1 / R1, R4: Settings remain usable at 320×480 in light and dark themes; long values and log lines cannot expand the panel.
- [ ] AC2 / R2: Users can retrieve actual recent app logs, refresh, copy, export and open the folder. Reads are bounded; empty and error states give useful feedback.
- [ ] AC3 / R3: Switching on acquires real native sleep prevention; switching off releases it. Reopening the panel reflects actual state; restart restores the preference.
- [ ] AC4 / R3: Initialization, shutdown and failed persistence cannot leak owned sleep prevention or falsely report success.
- [ ] AC5 / R1–R4: Relevant frontend tests/build and Rust checks pass. Check rendered views and native keep-awake behavior separately.

## Out of Scope

- iOS changes, Agent transcript capture, diagnostic uploads, arbitrary filesystem browsing, protocol or pairing redesign.
- Overriding explicit system sleep, lid-close sleep or hardware power management.

## Planning Status

Requirements converged: keep-awake behavior explicitly confirmed by the user. PRD convergence pass completed. Design, implementation plan and context manifests prepared; awaiting approval of the final planning summary before implementation.
