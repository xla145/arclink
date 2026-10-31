# ABP host transport v1

ALPN is `agent-bridge/1`. A frame is a four-byte big-endian length followed by
one type byte and a Protobuf message. Length includes type and payload and
must be between 1 and the negotiated maximum (at most 1 MiB). The schema is
in `schema/abp-v1.proto`; the Rust prost declarations preserve its field tags.
Unknown frame types and truncated/oversize frames fail the stream.

Every bidirectional stream negotiates Hello first, then sends StreamOpen.
Hello identifies protocol major/minor, endpoint/service instance and frame
limit. A successful stream open is an empty-rpc-id Response with JSON `null`.

- `kind=1`: Control; only granted peers. Methods: `Ping`, `GetSystemInfo`,
  `ListAgents`, `ListProcesses`, `StartProcess`, `StopProcess`, `GetProcessStatus`.
  Process listing is restricted to the authenticated owner.
- `kind=2`: Pair; token/session/name only. The peer identity is obtained from
  the encrypted connection, never from a request field. The first response
  is pending; the final response is sent only after desktop consent.
- `kind=3`: AgentIO; exact process ID/generation, one writer and task+approval
  grant. Cursor 0 attaches retained output; replay cursors are not supported.

Control request `body_json` contains a daemon DTO, not an Agent protocol:

```json
{"operation_id":"unique-start-id","agent_id":"codex","cwd":"/absolute/path"}
```

Stop uses `operation_id`, `process_id` and `generation`; status uses
`process_id` and `generation`. The same operation ID with changed arguments
is rejected. Timeouts do not prove a mutation did not happen: query status or
retry the original ID. Process IDs/generations are opaque and are not OS PIDs.
Success contains JSON, including present `null`; failure carries a code and
message. Unknown fields in mutation bodies are rejected.

AgentIO channels are stdin=0, stdout=1, stderr=2, gap=3, exit=4. Input chunks
are at most 16 KiB. Output chunks respect negotiated frame size; offset is
per output channel, cursor is stream-local ordering. Gap frames identify the
affected stdout/stderr channel when known (0 means cross-channel loss), and
precede retained post-loss output. A zero lost_bytes on a gap means the exact
byte count is unknown, not that output is complete. The
client must not silently splice data across a gap into a complete native
message. No business-state replay is promised. Exit carries an optional code;
absence does not imply success. Input is opaque, so separate task and approval
semantics cannot be policed in this transport; both grants are required.

Revoking a device closes existing connections and future access. Detach or
revocation does not kill its Agent; application shutdown does. A connection
has at most eight active streams; the service has at most 32 connections.
Control/stream opens are rate-limited. Each inbound frame and outbound write
has a deadline. Slow peers cannot create unbounded queues.
