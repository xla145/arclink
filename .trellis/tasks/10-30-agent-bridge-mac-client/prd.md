# Simple Agent Bridge Mac menu-bar client

## Goal
Deliver a small, launchable macOS menu-bar application managing the local Agent Bridge service. The user explicitly requested Mac rather than iOS, then supplied image.png (Remmo menu-bar popover) and requested a simple client. This resolves the earlier local-vs-remote product question in favor of local host management.

## Background and evidence
- `agent-bridge/` has no desktop UI; its daemon and development CLI are implemented Rust programs.
- `crates/agentd/src/main.rs` supports serve, devices, pairs, approve and revoke, but has no structured persistent local UI channel. Pair windows can currently be opened only at daemon startup via --pair.
- `crates/agentd/src/endpoint.rs` owns pairing, local endpoint identity and lifecycle. `crates/agentd/src/identity.rs` uses macOS Keychain.
- Existing backend support is verified Codex 0.165.0; unverified versions must not be presented as supported. There is no mobile application yet.
- Xcode/macOS SDK and Swift6.3.3 are available; native Rust target is aarch64-apple-darwin.

## Requirements
R1 Menu-bar UI: compact native popover resembling the reference hierarchy: app name/Mac name and status; optional actionable error card; devices; Agents; footer controls. Chinese labels, light/dark appearance and bounded height. No full session workspace.
R2 Service ownership: launch bundled agentd, show starting/running/stopped/failed and Endpoint ID, start/stop/restart controls, open local logs. Only manage the app-owned child; never kill an independently running daemon. Collapsing popover does not stop service. Quit/stop/restart must disclose interruption when active work exists.
R3 Pairing/devices: create a short-lived pairing invitation without restarting daemon, show/copy endpoint/token with countdown, show pending requests and require explicit local confirmation of displayed permissions, list authorized devices and revoke them. Do not imply an unimplemented phone app can scan/connect. Do not invent last-seen or connected state when unavailable.
R4 Agents: refresh installed Codex version and supported/unverified/unavailable status; show concrete diagnostic for missing CLI or version mismatch. Other agents are not advertised as controllable.
R5 Local settings: login-item toggle backed by SMAppService, off until user enables; visible error/pending system approval state. Open logs/data location; version and quit. Persist data in the user Application Support directory and logs in Library/Logs, with private file permissions.
R6 Build and tests: runnable .app bundle including the Rust daemon, repeatable local packaging script, Rust local-control contract tests, Swift model/state tests and visual smoke check. Preserve the backend37-test suite.

## Acceptance criteria
- Build and launch app on this Mac; menu icon opens correctly sized popover and controls reflect real state.
- Start/stop/restart affect one owned process; independent daemon conflict and native startup errors are visible.
- Pairing invitation expires, pending requests can be explicitly authorized, revoke takes effect, and no invitation token enters ordinary logs.
- Missing/unverified Codex is visibly distinguished from supported Codex; process running does not falsely imply Relay connectivity.
- Closing popover keeps service running. Application exit cleans owned process and has clear active-task interruption behavior.
- Login toggle changes only after deliberate user action and reports OS errors.
- Automated tests and native build pass; visual verification artifacts recorded.

## Out of scope
Full session/task/approval workbench, remote Mac controller views, iOS/Android, terminal emulator, new adapters, APNs, auto-update, App Store distribution/notarization and standalone LaunchAgent installation. Existing remote-control backend remains available.
