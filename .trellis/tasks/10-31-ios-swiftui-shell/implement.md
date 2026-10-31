# Execution and acceptance

1. Read mock contract, HTML and client document §04/§10; inspect existing shell and applicable guidelines.
2. Repair source state consistency, chat interactions, approval previews and actionable settings within ios/.
3. Build simulator Debug with signing disabled; retain complete log at work/builds/0.1.0-sim-debug.log.
4. Run native XCUITest through both themes: search/filter, project/history, empty/new session, send/reply, keyboard, attachment/zoom, tool/approval events, approve/reject/history, Mac and preferences.
5. Export native screenshot attachments and visually inspect primary screens. Fix any observed failure and rerun affected verification.
6. Record evidence, critique and mock limitations in work/codex-runs/0.1-report.md. Append READY_FOR_ACCEPTANCE only after build and evidence are complete.

Rollback: changes are isolated to SwiftUI shell, test target/scheme and task documentation; no daemon or desktop edits. No publication or Git commit is part of this request.

## Verification record — 2026-10-31

Simulator Debug build passed (Xcode 26.6, iPhone 17 Pro / iOS 26.4.1). Final native XCUITest suite passed 2/2 with 0 failures, including distinct toast assertions, short-title row hit areas, and theme changes via the settings UI. Exported and visually reviewed 22 native PNGs. Evidence and mock limitations are recorded in `agent-bridge/ios/work/codex-runs/0.1-report.md`; marked READY_FOR_ACCEPTANCE. No Git commit or publication performed; keep task available for acceptance.
