# Agent Bridge embedded host contract

## 1. Scope / Trigger

Applies to `agent-bridge/crates/{abp-protocol,agent-adapters,agentd,abp-test-harness}`.
This greenfield host supersedes the historical server-side session/approval
architecture in `agent-bridge-control.md`. The host relays opaque bytes;
mobile business state is outside this workspace.

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
64 KiB output ring. Overflow reports a gap before retained output. Detach
preserves the process. Normal app shutdown cleans owned process groups.
Wait for authoritative process exit before emitting a final exit frame.

UI snapshot revisions and corresponding state mutation share a publication
gate. Do not stamp a partially old snapshot with a newly incremented revision.
Native protocol/business capabilities require separate evidence; the checked-in
Codex 0.165.0 fixture proves only stdio initialization/read-only RPC.

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
Correct: register only capabilities demonstrated by exact-version evidence.

## Client scenario: simultaneous Mac connections

### 1. Scope / Trigger

Applies to `crates/agent-bridge-client/{src/endpoint.rs,src/connection.rs,src/lib.rs}`
when one phone identity pairs with or connects to multiple hosts. This does not
change host authorization, the wire protocol, or the public UniFFI signatures.

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
