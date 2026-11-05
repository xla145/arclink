# Agent Bridge desktop host - greenfield implementation

## Goal
Deliver a working desktop host based on `doc/agent-bridge-desktop-client.md`
and `doc/agent-bridge-tray.html`: discover local Agents, pair and revoke
trusted devices, relay Agent process I/O, and show authoritative status in
a compact tray panel. Build the required Rust daemon from scratch alongside
the Tauri 2 / React / TypeScript application.

## Confirmed background and decisions
- The user approved task planning, then explicitly chose a greenfield build
  on 2026-10-31 after the missing source was reported.
- No product workspace or Rust/Swift source exists in this checkout. Previous
  implementation claims and validation counts are historical, not evidence.
- The desktop specification owns host behavior; the HTML owns visual
  hierarchy. The broader plan supplies transport and pairing details.
- macOS on this machine is the first native delivery target. Keep portable
  boundaries; report Windows/Linux validation separately when available.
- The HTML devices, versions, statuses and decorative QR are sample data.
- Latest explicit user direction: match prototype rounding and display the
  pairing QR inside the current panel, without creating another window. This
  supersedes the source technical document's separate-pairing-window strategy.
- No phone application is part of this task. A test peer verifies the host
  network contract; phone scanning/interoperability remains a later check.

## Requirements
R1. Compact UI: implement the prototype header/status, device/Agent/process
    tabs, footer, settings, initial empty state, network errors, pairing and
    revoke confirmation. Match the prototype's rounded outer shell and cards.
    Follow system theme, bound list height, truncate
    long labels and expose keyboard/accessibility labels.
R2. Native lifecycle: tray click opens a screen-clamped panel; blur/Esc hides
    it without stopping the daemon. Use an accessory app/template icon on
    macOS and a single instance. Pairing replaces content in the current panel;
    successful pairing or cancellation returns to devices. Exit with active
    processes requires disclosure/confirmation and cleans owned processes.
R3. Discovery: detect Claude Code, Codex and Herdr using bounded version
    probes, known paths and PATH. Distinguish missing, installed, verified,
    unverified, probe failure and running. Persist a five-minute cache.
    Enable launch capabilities only with actual compatibility evidence;
    begin with one verified structured adapter as required by the base plan.
R4. Pairing: generate a real locally rendered QR with endpoint identity,
    protocol version, one-use high-entropy token and 120-second validity.
    Bind requests to the authenticated peer and require local approval of
    identity and permissions. Support reject, cancel, timeout and completion.
R5. Devices: persist authorized identities/permissions; display actual online
    status and last-seen when known. Revocation closes the device connections
    and input leases and rejects future operations without stopping already
    running Agents. Do not claim already submitted input can be withdrawn.
R6. Process relay: authenticated peers can discover, start, query and stop
    approved adapters and attach I/O. The daemon owns process identities,
    generations, pipes and cleanup. Serialize stdin; keep stdout/stderr
    separate; bound output at 64 KiB and explicitly report loss. Disconnect
    preserves the process. Do not parse/store Agent business state on desktop.
R7. Transport/persistence: implement versioned ABP over iroh with bounded
    Protobuf frames, per-operation/per-stream authorization and durable
    operation deduplication. Crash-ambiguous starts are reported unknown,
    never replayed automatically. Keep identity in OS secure storage and
    host metadata in SQLite, without storing sessions/tasks/approvals.
R8. Settings/diagnostics: manual autostart toggle with actual system result,
    supported network/settings controls, actionable startup/network errors,
    bounded redacted logs and a real log-view action. No simulated success.
R9. Reproducible delivery: lock Rust and frontend dependencies, document
    development/build commands, run meaningful behavior and integration
    tests, inspect UI states, and build a launchable local macOS app/package.

## Acceptance criteria
- AC1 (R1,R2): the built app renders the prototype hierarchy in light/dark,
  with empty/error/loading states; tray positioning, hide, reopen, second
  launch and exit are checked natively, not inferred from a browser.
- AC1a (R1,R2,R4): outer corners and cards are rounded; starting pairing shows
  the QR in the same panel and creates no additional native window. Cancel,
  timeout and completion clear invitation state and return appropriately.
- AC2 (R3): actual installed/missing/timeout/version-mismatch results are
  visible; an adapter is never labeled verified from help/version alone.
- AC3 (R4,R5,R7): a real iroh test peer pairs only after local confirmation;
  expired/reused/cancelled tokens and unauthorized requests fail; revocation
  immediately ends streams and future access while owned processes survive.
- AC4 (R6,R7): peer start/query/stop and raw bidirectional I/O work; repeated
  operation IDs do not spawn twice; altered duplicate payloads conflict;
  disconnect, overflow, EOF, stale generations and crash ambiguity have tests.
- AC5 (R1,R8): UI actions reach Rust, errors remain visible, old responses
  cannot replace newer state, subscriptions are cleaned up, unknown network
  state is not shown as direct/relay, and toggles reflect actual OS state.
- AC6 (R9): frontend type-check/build and Rust fmt/clippy/tests pass; the app
  contains local assets/icons and has native launch evidence. Report exact
  artifacts and any unavailable native/network/real-Agent checks honestly.

## Out of scope / deferred verification
Mobile apps and their business state machines; desktop task/session/approval
workbench; file preview and notifications; unattended service installation;
public distribution/notarization; arbitrary existing terminal takeover;
process survival across daemon/host restart. Generic PTY is capability-gated
and deferred until its adapter/lease/resize contract is verified, consistent
with the base plan. Do not advertise terminal support before that gate.
Windows/Linux native packages and phone-camera scanning are not claimed
validated by a macOS build or test peer.

## Planning status
Greenfield plan approved and implementation underway. Latest rounded-panel /
inline-pairing change was explicitly requested by the user and is authorized.
