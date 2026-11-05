# Agent Bridge private relay contract

## 1. Scope / Trigger

Applies to `bridge-network`, host networking, the Tauri settings boundary and iOS UniFFI/Keychain consumers. Keep the existing ABP authorization, endpoint identities and process ownership. Private relay access grants transport use only; pairing still requires approval on the Mac.

## 2. Signatures

- `NetworkServer::start_with_network(...)` adds optional private configuration; legacy `start(...)` remains a wrapper.
- `get_network_settings()` returns `{enabled, relay_url, has_access_key}`.
- Administrative/native provisioning API `update_network_settings(settings: {enabled, relay_url, access_key?})` returns the same public descriptor. `access_key: null` keeps the existing key; `""` clears it.
- UniFFI `PeerNetworkConfig {relayUrl: String?, relayAccessKey: String?, directAddresses: [String]}` is transient input.
- `BridgeConnection.withNetwork(keyPath:endpointId:network:) throws` and `pairOverIrohWithNetwork(..., network:)` are additive; legacy entry points remain usable.
- `validatePeerNetwork(network:) throws` normalizes boundary input; `BridgeConnection.pathKind()` asynchronously returns `direct`, `relay` or `unknown`.

## 3. Contracts

`AddressHints {relay_url?, direct_addresses}` is public/serializable. `PeerNetwork` carries the optional credential, redacts Debug, and deliberately has no general Serialize implementation. Only `invitation_value()` may export it into a transient QR. Version-1 QR fields remain compatible; optional `network` contains `relay_url`, `relay_access_key`, `direct_addresses`. Pairing imports both paths in a single scan, automatically persists the credential in Keychain and reconnects using saved hints. Product settings contain no manual relay address/key/enable form; existing devices refresh by scanning the Mac QR again. Desktop relay configuration is provisioned natively for this deployment, outside ordinary user flows.

Desktop stores the entire private configuration in macOS Keychain service `dev.agent-bridge.desktop.relay`, account `private-relay-v1`. Public snapshots, events and settings responses never return the key. iOS stores keys in service `com.agentbridge.ios.private-relay` under unique staged references using `AfterFirstUnlockThisDeviceOnly`; `devices-v2.json` stores only `SavedPeerNetwork {relayURL?, credentialReference?, directAddresses}`. Failed/cancelled imports delete only their own staged item. After a durable device-record update/removal succeeds, delete superseded credentials only when no saved device still references them; preserve keys if persistence fails.

Use iroh 1.4.1's default selector: IP paths are primary, relay is backup. Preserve IP transports, NAT traversal and HTTPS probes. Relay may establish first while a direct path is discovered; use the real selected path for UI labels. Never infer the selected path from configuration. The deployed HTTPS relay has no QUIC address discovery: construct `RelayConfig::new(url, None)` and attach bearer authentication. TLS verification stays enabled.

One shared mobile endpoint is keyed by the phone identity path. Each host/pairing operation retains a relay lease. Same-origin same-key leases share a registration; different keys conflict; releasing the final lease restores the prior registration. Disconnecting one host never closes the shared endpoint. Explicit shared-token rotation across saved hosts is deferred; report a conflict rather than replacing credentials silently.

Desktop live updates preserve endpoint identity, paired grants and Agent processes. No compiled-in access key, new environment secret or DB migration is required. Without private configuration retain default relay behavior.

## 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Relay URL | HTTPS canonical origin, <=512 bytes, no userinfo/query/fragment/path beyond `/` |
| Access key | If supplied, nonempty, <=256 bytes, no ASCII controls; requires relay URL |
| Direct hints | <=8 valid socket addresses, nonzero port, no unspecified/multicast IP; deduplicate |
| Network JSON helper / QR | `PeerNetwork::from_json` <=4096 bytes; typed FFI validates fields; Swift whole invitation <=16384 bytes, token <=4096 bytes, <=16 pair URLs; errors never echo raw input |
| Conflicting key for the same relay | `relay_conflict` / localized conflict; preserve existing leases |
| Keychain unavailable/missing credential | Visible actionable error; no plaintext fallback; explicit re-scan may repair only the scanned endpoint's absent item, never bypass Keychain access failure or other hosts' conflicts |
| Scan/persistence failure | Roll back staged credential and preserve workspace/other devices |
| Relay unavailable but direct peer reachable | Direct remains usable |
| No selected route yet | `unknown`, independently of online/offline |

## 5. Good / Base / Bad Cases

Good: scan a private-relay QR, approve locally, persist only a credential reference, reconnect with the same phone identity and use direct when available.
Base: old QR and old saved records omit `network` and retain existing behavior.
Bad: re-scan an existing Mac and replace its workspace, overwrite a shared relay key, or close the identity endpoint while removing one host.

## 6. Tests Required

Assert URL/key/hint rejection and redaction; authenticated forced-relay data exchange; direct selection with both paths; direct success with unreachable relay; relay-to-direct upgrade preserving an active stream; same-key lease reuse, conflicting-key rejection and final-release restoration. ABP tests must continue proving authorization and independent multi-host RPC ownership.

Desktop checks cover write-only descriptors and administrative null/empty key updates; product settings must expose automatic networking without credential fields. Scan-only UI tests assert no manual address/key controls and an accessible existing-device re-scan action. Swift checks cover old QR/record compatibility, Keychain staging, cancelled/rejected scan, persistence rollback, existing-device refresh/history retention, target-only missing-credential recovery, rejection of other-host missing credentials, path labels and shared-origin conflicts. Regenerate both Swift bindings and device/simulator XCFramework slices together.

Real LAN/cellular acceptance requires actual desktop/iOS evidence. A loopback fixture or production relay echo through SSH proves only its stated transport path; neither proves cellular App behavior.

## 7. Wrong vs Correct

Wrong: disable IP transports to force production through the relay, then display “direct” whenever connected.
Correct: retain default direct-first selection and project `Connection::paths()`' actual selected route.

Wrong: save `relay_access_key` in ordinary device JSON or send it in snapshots.
Correct: keep credentials in Keychain; send them only in the explicit transient invitation/import boundary.


## Cellular connection deadlines and default-relay hints

The phone's 40-second connection budget includes endpoint initialization and
relay registration as well as QUIC dialing. Pre-dial setup must not remain in
Connecting indefinitely. Automatic iOS health retries preserve the last terminal
connection failure until a successful attempt; they must not continually replace
an actionable timeout with Connecting.

Pairing invitations include the endpoint's actual advertised home relay even
when no private relay is configured. Explicit private configuration and its
credential stay authoritative. Keep LAN/direct hints alongside the relay hint;
never promise cellular connectivity merely because default relay mode is enabled.
An old saved invitation may require endpoint-preserving re-scan to gain this hint.


By explicit user request, macOS desktop debug/release use the same existing
private-relay Keychain item. Debug endpoint identity remains file-backed and
unchanged; only relay configuration storage is unified. Startup may log the
validated relay URL, never the credential. No secret is copied to source or JSON.


## Apple system DNS and pairing phase boundary

Both host and shared mobile endpoint builders use `bridge_network::dns_resolver()`.
On Apple platforms its A/AAAA lookup follows OS getaddrinfo so scoped VPN/Fake-IP
DNS and IPv6-only/DNS64 cellular behavior remain consistent with the system.
Run blocking lookups behind eight shared semaphore slots; a timed-out lookup
retains its slot until the worker finishes. Bound OS lookup/queue wait to two
seconds, then use the existing iroh resolver with a five-second bound on failure
or timeout. A successful OS answer with no records for one address family stays
empty rather than mixing in a different resolver's answer. TXT discovery, cache
clearing and reset delegate to the default resolver. Non-Apple platforms keep
the default resolver. Never hardcode a relay IP or disable TLS verification.

`pair_over_iroh_with_progress(..., PeerNetworkConfig, PairingProgressCallback)`
is additive; older pairing exports remain wrappers. Connecting covers endpoint
initialization and relay registration, Handshaking means a QUIC connection exists,
and AwaitingApproval is emitted only after a valid pending response from the Mac.
The entire pre-ACK phase shares a 40-second deadline; after pending ACK, a fixed
130-second deadline applies even if more pending frames arrive. Return
`connect_timeout` and `approval_timeout` distinctly. Deadline cleanup must drop
only that pairing attempt's registration/connection, preserving other hosts.

Verification distinguishes authenticated local fixtures, public relay transport,
and physical phone scanning. The public relay diagnosis must test actual iroh
data exchange: HTTP `/ping` or WebSocket101 alone does not establish reachability.


## Control stream latency on relay paths

The mobile client may buffer a CONTROL Open immediately after Hello only when
the Open fits ABP v1's minimum accepted peer frame size (1024 bytes). It may
also buffer the read-only `ListAgentProjects` request when that complete encoded
frame fits the same minimum. Always validate the returned Hello and Open ACK
before accepting an RPC result. Incompatible Hello and unauthorized/error ACK
remain errors even if a result follows them. All mutations, other RPC requests,
oversized catalog requests, and non-Control stream opens keep their existing
post-negotiation/ACK ordering. Submit each request exactly once, with no pooling
or automatic replay; host authorization remains authoritative.

Regression evidence must withhold all server replies until it receives the
pipelined frames, so the old serial client demonstrably cannot pass. Verify
exactly-once using stream EOF while the QUIC connection remains live; closing
the connection first can hide a queued duplicate. Include minimum-size peers,
incompatible Hello, denied Open, oversized fallback and mutation ordering.
