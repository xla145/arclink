# Agent Bridge embedded host contract

## 1. Scope / Trigger

Applies to `agent-bridge/crates/{abp-protocol,agent-adapters,agentd,abp-test-harness}`.
This greenfield host supersedes the historical server-side session/approval
architecture in `agent-bridge-control.md`. The host relays opaque bytes;
native chat semantics remain in the mobile client.

## 2. Signatures

- `Daemon::open(data_dir) -> Result<Arc<Daemon>>` acquires exclusive data ownership.
- `NetworkServer::start(daemon, secret: [u8; 32], relay_enabled: bool)` starts iroh;
  `shutdown()` closes its endpoint and owned tasks.
- `Daemon::{start_pairing,cancel_pairing,approve_pairing,reject_pairing,revoke_device}`
  are local administration; remote pairing can submit a request, never approve it.
- Remote `ListAgents`, `ListProcesses`, `StartProcess`, `StopProcess`,
  `GetProcessStatus`, `Ping`, `GetSystemInfo` use the versioned ABP contract.
- SQLite schema 1: `metadata`, `devices`, `operations`, `processes`, `discovery`.
  Operations have primary key `(peer,id)` plus request fingerprint/state/result.

## 3. Contracts

ALPN is `agent-bridge/1`. A frame is big-endian u32 length followed by one type
byte and protobuf payload; the length includes the type byte. The maximum is
1 MiB, negotiated by Hello. Validate before allocating, preserve partial reads,
and reject unknown tags. `schema/abp-v1.proto` and Rust prost tags must agree.

The authenticated iroh peer, not a payload ID, owns authorization. `view` is
baseline, `session` controls process mutation, and opaque bidirectional I/O
requires **both** `task` and `approval`. Byte forwarding cannot inspect whether
an Agent message is a task or an approval. Unsupported PTY/file capabilities
must not be advertised.

Pair invitations expire after 120 seconds. Tokens are one-use, bound to the
actual peer, held only transiently, and excluded from logs/events/snapshots.
Persist a grant only after local approval. Revocation invalidates existing
connections and leases even if the same identity is quickly regranted.

Reserve process operations transactionally before OS effects. Matching retries
return the prior result; altered payloads conflict. Reserved/ambiguous operations
become unknown on restart and are never automatically replayed. Historical
processes become lost; stored PIDs are not authority to signal a process.
Snapshots include live processes and bounded recent terminal history, not all
durable rows. Historical idempotent lookup uses the process key directly.
Check completed start/stop operation fingerprints and results before requiring
an in-memory process, while always enforcing the current peer grant and owner.

Each owned process has an opaque process ID and generation, a single input
lease, serialized bounded stdin, independent stdout/stderr drains and a total
4 MiB output ring. Overflow reports a gap before retained output. Detach
preserves the process. Normal app shutdown cleans owned process groups.
Wait for authoritative process exit before emitting a final exit frame.

UI snapshot revisions and corresponding state mutation share a publication
gate. Do not stamp a partially old snapshot with a newly incremented revision.
Native protocol/business capabilities require separate evidence; the checked-in
Codex 0.165.0 fixture proves only stdio initialization/read-only RPC. The separate opt-in `real_codex_chat_turns_over_iroh` test additionally verifies two read-only model turns through the embedded host; mobile `CodexChatSession` owns chat semantics and native approvals.

## 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Unpaired/revoked/wrong owner or missing grant | `unauthorized`, no operation |
| Reused operation ID with different request | `conflict`, no second spawn |
| Prior reservation or uncertain side effect | `outcome_unknown`, query state |
| Wrong process generation | `process_gone`, no native write |
| Invalid/oversize/unknown frame | Stream error before execution |
| Slow output consumer | Bounded retention plus explicit gap |
| Incompatible Agent version | Unverified/unavailable, no guessed capabilities |
| Credential failure | Visible startup error, no plaintext identity fallback |

## 5. Good / Base / Bad Cases

Good: authenticated peer requests pairing; local user approves; peer starts
one process; identical retry returns the same identity; revoke closes old I/O.
Base: disconnect retains the process; a new connection must reacquire its lease.
Bad: an old connection survives revoke/regrant, or old input is written using
the new grant without checking its original lease.

## 6. Tests Required

Run core/protocol/harness tests, including fragmented frames interleaved with
output, small negotiated frame limits, duplicate start, SQLite connection
races, pairing replay/expiry, unauthorized streams, revoke/regrant, leases,
overflow, EOF and shutdown. Real iroh loopback tests use deterministic Agents.
The ignored `real_codex_initialization_and_read_only_rpc_over_iroh` test uses
an actual native process without a model request; keep that evidence distinct.

## 7. Wrong vs Correct

Wrong: `select!` between `read_exact` framing and output; output wins and drops
the partial input read, losing bytes already consumed.
Correct: a dedicated bounded reader owns partial framing across output events,
and its task is cancelled when the owning stream ends.

Wrong: version/help output proves task, approval or resume support.
Correct: Codex must pass a bounded live `app-server --stdio` initialize handshake during discovery and again before launch; version strings alone do not gate it. This proves only stdio initialization, not account login, model access, approval or resume support. Kill and reap probe processes, cap output and time, and never log protocol payloads. Other production adapters remain installed/unverified until their transport is implemented and validated. Desktop diagnostics show the selected executable path.

## Client scenario: simultaneous Mac connections

### 1. Scope / Trigger

Applies to `crates/agent-bridge-client/{src/endpoint.rs,src/connection.rs,src/lib.rs}`
when one phone identity pairs with or connects to multiple hosts. This does not
change host authorization or the wire protocol. Private relay support adds UniFFI entry points while retaining the legacy signatures; see `agent-bridge-private-relay.md`.

### 2. Signatures

- `SharedEndpoint::for_key(path: &str) -> Arc<SharedEndpoint>` selects the owner.
- `SharedEndpoint::get()` initializes and returns a clone of the same endpoint.
- `BridgeConnection::new(key_path, endpoint_id)` owns one remote connection.
- `pair_over_iroh(..., key_path)` uses the same endpoint owner while pairing.

### 3. Contracts

A weak registry keyed by the normalized identity path shares an `Arc` owner;
its async `OnceCell` serializes endpoint initialization. Do not hold the registry
mutex across a network await. Each `BridgeConnection` retains its owner; pairing
retains an owner for the call. `disconnect()` closes only that host's connection,
never the shared endpoint. Host connection operations use a per-host mutex.
Disconnect increments a generation before waiting for that mutex; queued or
late dials from the previous generation must not publish a connected state.
Identity initialization is serialized and creates files exclusively with Unix
mode `0600`. A malformed/unreadable existing key is an error, not permission to
generate a replacement identity that invalidates previous pairings.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Corrupt or unreadable existing identity | `identity_error`; preserve file |
| Invalid target endpoint | `invalid_params`; other hosts remain connected |
| Endpoint bind failure | `network_error`; no partially initialized owner |
| Disconnect during queued/in-flight dial | Old generation returns disconnected |
| One host closes or pairing fails | Other host RPCs remain usable |

### 5. Good / Base / Bad Cases

Good: A and B return independent `ListAgents` results while C pairs using the
same phone ID. Base: disconnect A and continue pinging B. Bad: pairing cleanup
calls `Endpoint::close()`, tearing down every host owned by that phone.

### 6. Tests Required

`cargo test -p agent-bridge-client` covers concurrent identity creation, corrupt
key preservation, two-host RPC isolation, concurrent third-host pairing,
independent disconnect/remote-close, failed pairing, and a queued dial invalidated
by disconnect. Local fake hosts prove transport behavior, not real multi-Mac
internet reachability or Agent semantic capabilities.

### 7. Wrong vs Correct

Wrong: create a new bound endpoint with the same phone key for every host, then
close it at the end of pairing. Correct: share the identity's endpoint owner and
close only the remote connection being removed.


## Rich historical message projection

`agent_projects::list_thread_messages` keeps the existing `role/text/timestamp`
shape consumed by the UniFFI client. Ordinary turns retain user/assistant roles;
explicit public Codex reasoning summaries use `summary`, and recorded tool
calls/results use `tool`. Never expose private thinking or encrypted reasoning.
Both plain Codex `.jsonl` and `.jsonl.zst` are accepted. Image parts become
Markdown image references; unsupported/local/over-700-KB embedded references
become a readable placeholder without source/path disclosure. Bound the complete
serialized message array below 900,000 bytes, leaving response/frame metadata
margin under the 1 MiB transport maximum. For oversized histories, strip embedded
image data, bound individual escaped text on UTF-8 boundaries and retain recent
turns with an explicit shortened-history notice; never imply the result is full.
Swift renders
remote images only after explicit user action. This endpoint remains historical
read-only access; it does not imply structured live Agent chat or image upload.

## Conversation catalog metadata

Read Codex's newest numeric `state_N.sqlite` in read-only mode for live thread
metadata. When its `projects`, `project_roots` and `threads.project_id` schema is
available, use those project registrations and explicit thread memberships as
authoritative. An empty native project table is a successful empty catalog.
Never union legacy `local-projects` or synthesize projects from historical cwd
in this mode: removed desktop projects must not reappear. Unassigned threads may
match an existing project's longest root; dangling explicit memberships do not
fall back to cwd. Older schemas keep the legacy registration/cwd fallback. Exclude archived and internal subagent rows. Preserve explicit desktop
project assignments; otherwise match cwd against all named project roots using
the longest ancestor, then create an exact cwd bucket. Merge same-root projects
without losing their threads. CLI and desktop origin must travel separately from
project membership (`AgentThread.source`); legacy assignment-only results have
unknown origin. Legacy metadata remains a best-effort fallback when the database
is unavailable. Claude Code's local project transcripts carry CLI origin.


## Recoverable record-framed AgentIO

`GetCapabilities` (view grant) advertises `io_resume_offsets_v1`,
`io_lease_replace_v1`, and `io_ndjson_records_v1`. The UniFFI client must confirm
all three before `attach_chat_io` or `resume_chat_io`; an old host returns an
explicit upgrade error rather than silently replaying bytes from zero. Legacy
`attach_io` remains raw and compatible.

`StreamOpen.resume` (tag 5) contains next stdout/stderr byte offsets and the
previous lease ID; `record_framed` is tag 6. Open returns the new `lease_id`.
A resume may replace an active lease only with its matching proof, for the same
authenticated owner/generation/current task+approval grants. Old queued writes
and old session drops cannot write through or release the new lease. Reject
future offsets before acquiring a lease. Replay slices a retained block at the
requested offset, emits per-channel gaps for evicted bytes (even an entirely
evicted channel), and allows retained exited processes to drain before exit.

Record-framed mode buffers at most 2 MiB per NDJSON record on the Mac, forwards
only complete newline-terminated records, and discards an interrupted partial
record. This prevents half an uploaded image poisoning subsequent native input.
It does not provide mutating-message replay or an exactly-once stdin protocol.
Image messages still cross bounded 16 KiB transport frames (or smaller negotiated
limits); the native record may exceed a single 1 MiB ABP frame. Retained output
is bounded at 4 MiB to accommodate image echoes. No lease or image bytes in logs.

Validation: protocol legacy encoding, negotiated-frame input, capability fallback,
host offset/lease/eviction/exit/revocation and real iroh record-transfer regressions.
The ignored `real_codex_image_and_connection_recovery` additionally sends a real
image, recognizes its colors, disconnects and resumes the same process/thread,
then completes another model turn. This does not prove cellular/iOS background
execution guarantees.

## Scenario: cold host restart with saved direct addresses

### 1. Scope / Trigger

Applies to `agentd::network::NetworkServer` startup and the host SQLite store.
A paired phone can have only direct IP/port hints, with no usable relay or public
address lookup. Keeping the Ed25519 identity alone does not preserve reachability
if every desktop launch allocates a different UDP port.

### 2. Signatures

- `Store::network_bind_addrs() -> Result<Option<Vec<SocketAddr>>>`.
- `Store::save_network_bind_addrs(&[SocketAddr]) -> Result<()>`.
- Existing `NetworkServer::{start,start_with_network}` signatures are unchanged.
- SQLite schema 1 `metadata`: key `network_bind_addrs_v1`, JSON array of local
  wildcard socket addresses, e.g. `["0.0.0.0:55555","[::]:55556"]`.

### 3. Contracts

Absent metadata permits the first OS-selected ports. Subsequent starts pass the
saved addresses to `Endpoint::builder(...).bind_addr(address)` before binding.
Save `endpoint.bound_sockets()` before publishing `ready` or allowing invitations.
A persistence failure closes the new endpoint and fails startup. Never replace a
saved occupied port with a random one. Store only public bind information; do not
change identity storage, paired grants, relay selection or the wire protocol.

An old installation's already-stale phone hints cannot be inferred from the Mac
store. Refresh the existing device using a new QR once after upgrading; retain
its workspace and pairing identity. This fixes port drift on host restart with
unchanged LAN addresses, not DHCP changes, subnet migration or relay outages.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| No saved bindings | Bind normally, persist actual sockets before ready |
| Valid saved bindings | Reuse original ports and identity |
| Empty/malformed bindings, zero ports, non-wildcard IPs, duplicate families, >2 sockets | `storage_error`; preserve metadata, no random-port fallback |
| Saved port occupied | `network_error`; retain metadata for a later retry |
| Saving bindings fails | Close endpoint, fail startup, no ready publication |

### 5. Good / Base / Bad Cases

Good: pair, close both endpoints, reopen the host store and both identities, then
Ping through the original saved direct address without another approval.
Base: restarting only the phone retains the host grant.
Bad: a warm endpoint's address cache hides random host port allocation in tests.

### 6. Tests Required

`cargo test -p abp-test-harness --test host_restart --locked` proves cold two-end
recreation, original-grant reuse, and occupied-port failure/retry. Tests disable
relays, use a loopback address and retain no lookup cache between phone instances.
Wait for OS socket release after `Endpoint::close()` before rebind assertions.
`store::network_bind_tests` covers reopen persistence, unchanged settings and
invalid metadata preservation. These tests do not prove cellular recovery.

### 7. Wrong vs Correct

Wrong: keep only the endpoint ID stable and assume public discovery will always
repair the stale port saved in a QR.
Correct: persist actual host socket bindings and reuse them before advertising
readiness; retain existing identity and authorization checks on every reconnect.


Historical `AgentMessage` adds optional tool_call_id, tool_name and tool_phase
(input/output). Codex uses payload.call_id; Claude uses tool_use.id and
tool_result.tool_use_id. Keep role=tool and existing text projection compatible.
Preserve these IDs through bounded-history projection and UniFFI MacMessage;
regenerate Swift bindings and device/simulator libraries together. Missing old
metadata remains nil, not an invented correlation. Public summaries remain the
only reasoning content returned.


`ListDirectory {path?}` (view grant; capability `list_directory_v1`) lists the
visible subfolders of `path` (absolute, `~`, `~/…`; omitted = home) for choosing a
project path: `{path, parent, entries:[{name,path,is_project}], truncated}`, at most
400 entries, sorted case-insensitively, `is_project` = contains `.git`. Folders only;
dot-entries skipped. Both the request and every entry are canonicalized and must
stay inside the home directory: anything resolving outside (`..`, symlinks) is
`forbidden`, missing/unreadable/non-folder is `not_found`, and `parent` is null at
home. Implemented in `agentd/src/directories.rs` with a test-injected home. A host
without it answers `unsupported`, which the phone shows as "update the Mac app".

`ListAgentModels {agent_id}` requires the existing view grant and returns at most
100 `{id,name}` entries, preferring Codex app-server `model/list` through the
configured adapter executable. Initialize first, follow at most 20 pages, bound
total output to 4 MiB and live discovery to 10 seconds, and kill/reap the helper.
Cancellation also terminates its process group. Project native `model` and
`displayName`, exclude hidden models, deduplicate IDs and bound identifiers/labels.
On failure use the bounded (4 MiB) models_cache.json projection, excluding
`visibility=hide`; a successful empty live list must not resurrect stale entries.
Never return instructions or raw protocol/cache payloads. The client allows
15 seconds for this RPC. Missing/unsupported catalogs return empty; model
discovery does not guarantee entitlement or synchronize a thread's model.

## Historical tool outcome metadata

`AgentMessage.tool_failed` and client `MacMessage.tool_failed` are additive optional
booleans, defaulting to unknown for old hosts/records. Only result records carry
outcomes: explicit `is_error`/`isError` booleans or integer `exit_code`/`exitCode`.
Codex execution/MCP envelopes may be exact JSON in output text blocks; decode only
that whole envelope, never JSON buried in its arbitrary program output. Recognized
allSettled wrappers preserve their nested result outcome. Ignore narrative blocks
when result envelopes exist; any explicit failure wins, all known successes yield
false, and mixed success/unfinished execution remains unknown. A running
`chunk_id`/`session_id` result without an exit status is not success. Claude uses
explicit tool_result flags; nonempty stderr and failure words are not evidence.
Retain empty result rows with explicit outcome and their original call ID/phase.
Unknown outcomes must not be converted into successful results in UI summaries.

Discovery cache is valid only after fresh probing in the current host lifetime. Never reuse persisted discovery on first startup: it may contain an earlier binary’s version policy and diagnostic text. Retain the five-minute TTL for subsequent reads and always bypass it on explicit refresh.
