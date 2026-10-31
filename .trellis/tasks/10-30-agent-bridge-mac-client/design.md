# Greenfield desktop technical design

## Source precedence and historical compatibility
Use the desktop technical document for the embedded-daemon architecture and
tray HTML for appearance. Retain the base plan's ABP framing, trust boundary
and first-verified-adapter rule. Historical specs describe missing Swift and
server-side session/approval implementations: do not recreate those contracts.
Preserve their applicable authorization, bounded-I/O, lifecycle and truthful
status invariants. New host data starts with a versioned schema; there is no
existing database or native package to migrate in this checkout.

## Workspace and responsibility boundaries
Create `agent-bridge/` with one Cargo workspace and Cargo.lock:
- `crates/abp-protocol`: protobuf schema/types, IDs, framing, hello, stream
  kinds, process RPC, I/O channel/gap/exit envelopes and protocol errors.
- `crates/agent-adapters`: executable discovery, compatibility registry,
  version probes, approved spawn configuration and process-group primitives.
- `crates/agentd`: embedded library owning endpoint, auth, SQLite store,
  discovery cache, process registry, serialized writers and event publisher.
- `crates/abp-test-harness`: real transport peer and deterministic fake Agent
  fixtures. This is a test driver, not a mobile business client.
- `desktop/src-tauri`: Tauri setup, commands/DTOs, events, tray, windows,
  settings/autostart and application shutdown; depends on agentd.
- `desktop/src`: React components/hooks, bridge/types, local CSS tokens.
- `fixtures`, `scripts`, README: compatibility evidence and repeatable builds.

No independent daemon sidecar or Node runtime is bundled initially. GUI and
network requests call the same daemon service layer, with local privileged
administration separate from remote peer operations. Choose pinned compatible
crate/plugin versions during the first compile spike; do not invent API
signatures from unverified examples. Use pnpm through Corepack if pnpm is not
installed; keep a single frontend lockfile and packageManager declaration.

## Runtime and native window ownership
Initialize the singleton before opening a database/endpoint; acquire an app
data lock to reject competing writers. Load Keychain identity and settings,
start the embedded daemon once, then publish readiness/errors to the UI.
Keep service startup asynchronous so Keychain/network failures can be shown.
Rust owns all child handles and cancellation tasks. A shutdown state blocks
new starts; graceful stop has a bounded wait followed by owned process-group
cleanup. Repeated quit/close requests join the same shutdown operation.
Window close/blur/Esc only hides main. Pairing-window close cancels its own
session, not the daemon. Events never implicitly terminate other windows.
Use monitor work area and scale factor for tray placement; clamp height on
small displays. Follow the technical document's 320px default width/480px
maximum panel height, preserving the HTML sections/colors/typography.
Use local/system fonts rather than the prototype's external font request.

## UI command/event contract
Keep invoke/listen/window actions behind `bridge.ts`. Generate TS DTOs from
Rust or verify serialization fixtures, including null/error/enum cases.
Return u64 offsets/revisions as strings and timestamps as ISO strings.
Commands include list_agents, refresh_agents, get_agent_detail,
get_daemon_status, get_process_list, list_paired_devices, start_pairing,
cancel_pairing, approve_pairing, reject_pairing, revoke_device, get_settings,
update_settings, set_autostart, open_logs and request_exit. Pair decisions
accept only the active session/request and displayed permission subset.
Commands cannot execute arbitrary shell code or forward arbitrary RPC.

Events carry service_instance, monotonically increasing revision, and
process_id/generation where relevant. Subscribe before the initial snapshot,
then apply only matching/newer revisions; refresh a snapshot on reopen or a
reported gap. Loading/error/stale are separate from data. Unmount tears down
subscriptions even when listen registration is asynchronous. Backend guards
mutations; UI button disablement is supplementary. A timed-out mutation
refreshes authority or uses the original deduplication key, never a fresh
automatic replay. Production without Tauri shows unavailable, not fixtures.

Pair QR data is the deliberate exception to transient secret exposure: only
the pairing window receives the short-lived invitation; it is never placed
in global events, persistence, logs or localStorage and is cleared on close.
Private keys never enter WebView. This resolves the document's broad
'no token in frontend state' wording with its explicit QR requirement.

## Pairing, transport and authorization
ALPN `agent-bridge/1`; length prefix is u32 big endian, counting the type
byte plus protobuf payload, default maximum 1 MiB. Validate length before
allocation, then incrementally read. Negotiate Hello limits/versions and
validate StreamOpen before processing business frames. Pair is the only
channel available to unauthenticated/unpaired peers during a local invitation.
Rate-limit and cap connections, streams, pending requests and queue bytes.

Use OS randomness for tokens, store only a token digest in pending session
state, and atomically bind/consume it against the actual iroh peer identity.
Local approval persists the grant; cancelled/rejected/expired requests cannot
be revived by delayed callbacks. Permission checks use authenticated identity
and current expiry/revocation, not a device ID supplied in a request.

Raw AgentIO cannot distinguish a task message from an approval response.
Require the combined task+approval grant to attach a bidirectional opaque
AgentIO stream; session controls process start/stop, view controls discovery
and status, terminal is separate and unavailable until verified. UI must
explain this grant coupling, and may not claim per-message semantic policing.
Any active stream rechecks current grant at input boundaries and is cancelled
on revocation. Own process/lease checks prevent cross-peer control. Device
listing is extensible, but this iteration guarantees the documented single
controller flow; concurrent writers to one process are rejected.

## Storage and recovery
Versioned SQLite holds device grants, discovery TTL records, settings where
appropriate, process metadata and `(peer_id, operation_id)` deduplication.
Use an explicit write transaction/unique constraint to reserve an operation
before spawning. Bind the key to a canonical request digest; mismatched reuse
is Conflict. Store a terminal result or OutcomeUnknown. Crash windows cannot
be made atomic with OS spawn: retain intent/unknown and never repeat it on
reconnect. Preserve rejection tombstones beyond the >=7-day replay period.
Restart marks formerly live processes lost; do not signal reused PIDs or
claim resurrection. SQLite does not contain mobile session/task/approval data.
Store identity in macOS Keychain; keep OS storage behind platform interfaces
for Windows/Linux. Credential failure disables network start visibly; do not
silently fall back to plaintext. Pairing records survive normal restart.

## Agent discovery and I/O
Probe fixed agent identifiers, PATH and known install locations without
sourcing shell startup files. Use explicit paths/args and bounded output,
timeout and cleanup; cache successful/missing results for five minutes.
Refresh bypasses TTL. Baseline targets are Claude Code, Codex and Herdr;
Aider in the visual example is not a claim of implemented support.
Codex app-server is the initial candidate, subject to actual current-version
validation. Record exact native version, schema source and tested capabilities;
keep other adapters discovered/unverified until independently validated.
No model billing or broad native tool execution is part of routine smoke tests.

A process has an opaque ID and generation separate from its PID. Allocate
starting state before await; spawn approved adapter configuration with no shell
concatenation or arbitrary executable/environment injection. Remote cwd must
be validated as an existing directory; it is not represented as a sandbox.
Drain stdout and stderr independently into a total 64 KiB byte-budgeted ring;
maintain per-channel offsets and explicit gap records before retained data.
Slow readers do not block pipe drainage. Never splice post-gap bytes into a
claim of complete native messages; clients must resynchronize or fail clearly.
A bounded single stdin writer preserves frame ordering. Exit terminates stream
writers and pending operations, records exit state and emits an exit event.
Detach retains processes, revocation releases leases, app quit cleans ownership.

## Settings, distribution and rollback
App-scoped support/log paths, private files and bounded redacted logging.
Only expose settings backed by actual behavior. Autostart is off initially
and changes only on user action, followed by querying system state. Capabilities
and CSP restrict local windows; no unrestricted shell/filesystem plugin access.
Build macOS app and DMG with embedded React assets and template/application
icons. Report architecture/signature and local-only distribution status.
Do not install to /Applications, enable login items, publish or notarize as a
side effect. Rollback is stopping the development app and reverting new source;
preserve user data/Keychain and disable login only when explicitly requested.

## Verification boundaries
Use deterministic adapters for fault injection and two actual local iroh
endpoints for transport tests. Test pairing using the same daemon approval
method as UI; a test-only grant bypass cannot establish production pairing.
Native Agent compatibility, real relay reachability, phone scanning and
Windows/Linux behavior have separate evidence; do not substitute mocks for
any of those claims. No new mobile UI is needed for the host test contract.
