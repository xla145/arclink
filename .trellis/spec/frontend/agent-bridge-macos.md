# Agent Bridge macOS menu-bar contract

## 1. Scope / Trigger
Applies to `agent-bridge/macos/`, the bundled daemon local administration mode and `scripts/build-macos-app.sh`. This is a native local host panel, not an iOS app or a remote session workspace. Reference screenshot defines hierarchy only; no copied third-party branding or unsupported connectivity claims.

## 2. Signatures
- Swift package executable: `AgentBridgeMac`, macOS13+; app bundle ID `dev.agent-bridge.mac`.
- Bundle helper: `Contents/Helpers/agentd`; launch `agentd DATABASE serve --control-stdio [--codex-bin ABS_PATH]` using Process.arguments, never a shell command string.
- Build: `scripts/build-macos-app.sh [--debug]` → `dist/Agent Bridge.app`; local ad-hoc signature, current-host architecture.
- Snapshot mode: bundled executable `--snapshot OUTPUT.png`; actual popover view with explicitly labeled preview data, no daemon or login registration.

## 3. Contracts
Local JSONL v1 envelope `{version:1,id,method,params}` → exactly one correlated result/error. Request limit64KiB, response limit1MiB. Complete byte lines before UTF8/JSON decode. Control methods and payloads are owned by `fixtures/local-control/README.md`, Rust `local_control.rs` and matching Swift `BridgeCore/Models.swift`.

Only parent-owned pipes expose administrative operations. stdout never carries diagnostics; stderr logging is bounded, private and excludes pairing payloads. EOF ends owned child lifecycle. Retain existing CLI and remote ABP behavior.

@MainActor owns UI state. Set transition state before suspension, use a process generation to reject late callbacks, and serialize stdin writes (JSON messages can exceed PIPE_BUF). Each pending request has a bounded timeout; failure/EOF resumes pending continuations. Timeout does not imply a local mutation was rolled back: refresh before retrying approval/revoke.

Menu collapse does not stop service. Stop/restart/quit only manage the actual owned Process; lock conflict does not authorize killing another process. Guard active work before interruption. Selecting a Codex path is explicit; never source shell startup files. CLI diagnostic and native adapter share one version/capability policy.

Display local service running separately from remote reachability. Authorized device is not an online device; do not invent last seen. Codex untested/unavailable must differ from verified. Pair invitations expire and require separate local permission confirmation; only supplied allowed permission values may be granted.

Data: user Library/Application Support/Agent Bridge; bounded log: Library/Logs/Agent Bridge. Daemon identity stays Keychain-backed. SMAppService login registration occurs only from deliberate toggle action; preview/tests cannot register. Show OS approval/error state without pretending registration succeeded.

## 4. Validation & Error Matrix
- Missing helper, database lock, native start error → Failed plus actionable diagnostic.
- Unsupported protocol, malformed/oversized/truncated JSONL → fail channel and pending requests.
- Old process generation response → ignore, never update current view or busy state.
- Local timeout → error with uncertain effect; refresh authority.
- Expired pairing → disable invitation copy/confirmation appropriately; server is final authority.
- Unverified Codex → diagnostic, no supported badge.
- Login approval pending → system settings action; exception → visible error and actual status refresh.

## 5. Good / Base / Bad Cases
Good: click start once, publish Starting before await, receive matching-generation status, then show Running. Refresh only commits a coherent response set belonging to current generation.
Base: user collapses popover; daemon continues. Reopen refreshes real state. Device grant requires displayed permission confirmation.
Bad: repeated click launches two processes; stale refresh clears newer failure; successful process spawn means Relay reachable; token written into logs.

## 6. Tests Required
Rust local-control: bounded fragmented framing, versions/correlation, malformed input without secret echo, EOF/shutdown, pair/grant/revoke real store, bounded executable probe.
Swift: Codable fixture parity, fragmented UTF8/oversize/truncation, serialized writes, EOF/pending failure, request timeout, process generation, duplicate start/restart and stale mutation results.
Build/visual: bundle contents/signature, launchable local app, screenshot of real popover rendering, readable Chinese labels and bounded height. Keep preview evidence distinct from live service evidence; do not enable login item in automated tests.

## 7. Wrong vs Correct
Wrong: `await transport.stop(); phase = .starting` permits another start while suspended.
Correct: claim transition and generation before the first await; apply results only if still current.

Wrong: one detached task per pipe write allows large JSONL writes to interleave.
Correct: a bounded serialized writer sends complete encoded frames and propagates failure to the matching generation.
