# Direct-first private relay design

## Architecture

Retain the existing embedded Rust `agentd` host, ABP v1 protocol, Tauri/React desktop and SwiftUI/UniFFI iOS client. Add relay configuration at the network boundary, never a parallel application protocol.

The version-pinned iroh default selector already ranks IPv4/IPv6 as primary and relay as backup. Keep it. Do not call `clear_ip_transports` outside forced-relay tests, and keep HTTPS probes enabled. Establishing initially over a relay is allowed; a viable direct path then wins without replacing the application session.

### Configuration ownership

Create a small shared Rust configuration owner usable by host/client (a focused workspace `bridge-network` crate with no GUI/platform storage dependency). It owns:

- `AddressHints`: optional canonical HTTPS relay origin (`relay_url`) and bounded `direct_addresses`; serializable without credentials.
- `PeerNetwork`: input-only hints plus optional `relay_access_key`, with redacted Debug and no generic Serialize/logging path.
- URL/input limits and `RelayConfig::new(url, None)` conversion, using per-entry bearer authentication.

Do not place bearer credentials in normal `AppSettings`, `Snapshot`, `PairedMac`, errors or event DTOs. The default private URL is a non-secret suggestion, not a mandate to use this server without authorization. With private configuration absent, keep `presets::N0` behavior.

### Storage

Desktop: use the existing Security.framework pattern with separate relay-specific Keychain service/account identifiers. Keep `{enabled, relay_url, access_key}` together in the protected Keychain item (`dev.agent-bridge.desktop.relay` / `private-relay-v1`), exposing only public metadata through commands. This makes native settings/credential rollback atomic. Commands return a public descriptor and `has_access_key`; a dedicated mutation accepts a write-only secret update. Blank/missing key has explicit keep/clear semantics rather than accidental deletion.

iOS: use Security.framework generic-password items with a canonical-origin credential reference; no secret in `devices-v2.json`, UserDefaults or generated fixtures. Extend existing records with optional hints/configuration references so older JSON still decodes. Keychain operations and device-record persistence have compensating rollback; never discard the previous secret before the new record and intended operation can commit. Report storage/Keychain failures without silently replacing identities.

The initial desktop can be provisioned from the already authorized VPS into its own native credential store during rollout, without emitting the server key to tool output. General distribution requires managed provisioning, not a compiled shared secret or an ordinary-user credential form.

## Desktop host behavior

Keep `NetworkServer::start(..., relay_enabled)` as a compatibility wrapper for harnesses. Add a typed config entry point for the desktop. Explicit private mode uses the selected private relay as its home relay while retaining IP/direct transports and ordinary address lookup. Default mode retains default relays. A relay outage must not stop endpoint creation or block direct address discovery.

Settings edits validate and persist atomically. Update the running endpoint relay map when safe using `insert_relay`/`remove_relay`; otherwise perform a bounded transport-only restart using the same host identity and daemon. Do not shut down Agent processes or revoke grants as part of a network change. Respect the existing lifecycle lock and stopping generation; display the potential reconnect before explicit apply.

The transient invitation builder obtains current endpoint address hints and privately reads the relay credential, adds them to the invitation response, and never publishes the secret in daemon events/snapshots. Cancellation/expiry clears any invitation cache. The local pairing view is the only UI allowed to receive that transient credential.

## QR and discovery contract

Keep base QR `version: 1` fields. Add optional data, decoded once into typed records:

- `network`: optional `relay_url`, optional transient `relay_access_key`, and `direct_addresses: string[]`. This additive record carries explicit scan import credentials separately from the authenticated endpoint identity. Persist its non-secret hints only.

Preserve the existing invitation one-use token independently from the relay access key. The UI explicitly says that the scan imports private relay access. The relay key grants transport usage only; the existing Mac approval and peer-key authorization still protect Agent access.

Bound URL/key/candidate lengths and total payload; require HTTPS origin URLs without embedded username/password, query or fragment. Permit valid LAN/public unicast socket candidates with nonzero ports, rejecting unspecified/multicast addresses. Never disable TLS verification. Device identity remains the authentication authority even for untrusted/stale hints.

New optional UniFFI entry points accept the typed peer hints/configuration. Retain old `pair_over_iroh` and `BridgeConnection` constructors as wrappers. Dial an `EndpointAddr` that includes the authenticated endpoint ID and validated relay/direct hints, retaining normal lookup as additional discovery. Persist usable metadata after successful pairing for future reconnects; direct socket hints are advisory and can become stale.

## iOS multi-device endpoint ownership

Keep `SharedEndpoint` registry keyed only by normalized identity path. Add serialized relay registration and reference/ownership bookkeeping; do not make one endpoint per relay or per Mac. Restore saved configurations before dialing saved devices.

The shared endpoint's relay map can contain default discovery relays and multiple private relays with per-relay authentication. A given Mac's `EndpointAddr` names its private relay explicitly, so it can be reached even when the phone's home relay differs.

A pairing attempt stages new configuration and holds a temporary registration. On failure/cancel, release only that registration; preserve any relay referenced by another saved host or active operation. Do not mutate the credential for an already registered origin during an unapproved scan. Different credentials for that origin are a configuration conflict. Shared-origin credential rotation remains an administrative follow-up; ordinary users refresh from QR. Invalidated operations cannot commit late settings, credentials or online state.

Refreshing settings for an already paired endpoint retains workspace and grants, then reconnects only that host as needed. Removing one device must not close the shared endpoint or delete a relay credential still referenced by another device. A target-only missing Keychain item can be repaired by explicit re-scan without overwriting other devices' credentials; distinguish an absent item from a Keychain access failure.

## Path observability and UI

Use `Connection::paths` / `paths_stream` to derive selected transmission path. Preserve an `unknown` value when no selected path is available; never call a connection direct merely because its relay is absent from metadata. Expose path kind and optional latency through additive FFI/DTO fields, without secrets.

User refinement: remove manual relay address/key controls from desktop and iOS settings. Show automatic direct-first/relay-fallback behavior and actual direct/relay/reconnecting status in existing connection rows. Existing devices refresh via re-scan; desktop configuration is native/admin provisioned. Preserve existing user edits in iOS views/tests. No new navigation redesign, forced reconnect of all devices or background-keepalive claim.

Map stable validation/storage/network error codes to Chinese UI strings. Do not assert that every timeout is an authentication rejection; the iroh API may not expose the underlying failure precisely. Ordinary diagnostics guide a fresh scan or network check; URL/key diagnosis is administrative only and always redacts credentials. Relay failures do not authorize replay of process operations or Agent input.

## Compatibility and rollback

No changes to ABP ALPN, paired public keys, identity namespaces, authorization database, bundle IDs or existing device-workspace format version. New optional metadata has safe defaults. Legacy wrappers continue serving existing tests/callers.

Disabling private settings restores the previous default network mode while retaining grants and private metadata for explicit reuse. Restore prior Keychain/settings values on failed apply. Keep valid existing connection ownership until replacement is ready, or report a bounded reconnect where atomic switching is impossible.

## Validation and deployment risks

- Verify direct-first, forced-relay and relay-to-direct using actual path selection and ABP RPCs, not mock status flags.
- A private in-process relay fixture must enforce the same authentication behavior and reject wrong credentials.
- Test two private relays and one shared-origin relay used by two Macs; failed/cancelled pairing must leave other clients usable.
- Keychain cannot be proven by generic Rust mocks alone: run native storage and simulator checks with isolated accounts/test stores, preserving real device secrets.
- Rebuild both iOS Rust targets and regenerate UniFFI output before Swift validation.
- Production relay QAD is off; HTTPS probes and normal certificate verification stay on.
- The development machine's Fake-IP network is an external acceptance variable. Record a direct/tunnel test distinction; do not rewrite global proxy settings.
- Physical iOS signing/accounts and a second network/device may limit automated acceptance. Keep these open in validation evidence rather than claiming success.

## Follow-up cache boundary

Project and conversation rows already persist in DeviceWorkspace. Runtime importedAgentIDs is insufficient freshness across relaunch and currently marks failure as imported. Add a durable optional cache/freshness owner at the iOS store boundary; choose the smallest representation that also supports the project picker without its direct FFI call. Use one cache-first lookup/refresh path, per-device/per-Agent freshness (five minutes) and in-flight coalescing, explicit force refresh and existing runtime/generation guards. No blocking spinner over existing rows, new database, transport change or message-content cache in this change. Root owns docs; implementation owns AppModel, DeviceStorage, ProjectViews/HomeView refresh entry and focused Swift tests.

## Pairing follow-up boundary

AppStore owns authenticated completion and publishes an ephemeral pairingSuccessID only after durable storage. RootView observes it in addition to device selection, covering same-device refresh. DeviceListView closes its parent chooser after scanner dismissal; QRScanScreen renders the existing pairingPhase while waiting. Remove the HTTP fallback: its 200 response meant only submission and used an unrelated UUID instead of the iroh public key. Existing optional relay hints and default-home-relay QR export remain the cellular path; no Wi-Fi-only policy or production TLS relaxation is introduced.

## Authenticated pairing stages and deadlines

Add the backward-compatible `pair_over_iroh_with_progress` API with `PairingProgressCallback` and typed Connecting/Handshaking/AwaitingApproval milestones. All old entry points share one deadline wrapper. The initial 40-second deadline covers endpoint initialization, relay-registration locks, dial, Hello, and invitation ACK; only a validated pending ACK switches to a fixed 130-second approval window. Repeated pending frames cannot extend that deadline. Swift consumes ordered callbacks with one AsyncStream task and rejects stale-generation events. Initial UI says connecting, never awaiting approval. Callback/slice regeneration is atomic across the same source.

## Catalog latency boundary

Each mobile Control RPC previously waited for Hello, then Open acknowledgment,
then the RPC response: three network round trips. Keep dedicated streams and
ABP v1 framing. Pipeline a small CONTROL Open with Hello; additionally pipeline
only `ListAgentProjects` requests whose encoded frame fits the minimum accepted
ABP v1 peer limit (1024 bytes). All other RPC requests, including mutations, and
oversized catalog requests still wait for validated Hello/Open acknowledgment.
The caller validates both responses before accepting any result and submits the
request exactly once. Host authorization and existing read-only catalog ownership
are unchanged. No control pool, replay, new wire message, timeout inflation, Swift
cache change, or new error UI.


## Conversation turn projection and metrics boundary

Use ConversationTurn as a presentation projection for imported MacMessage and local ChatMessage records. Group assistant prose/images/steps until the next user, preserving stable first-source identity and paragraph order. Correlate historical tool input/output only inside the user-bounded turn. Keep raw native and persisted message identities intact.

Add optional tool_failed to host/client historical tool rows (Swift toolFailed), defaulting to unknown for old hosts. Derive only from explicit result flags/integer exit codes or recognized execution-result envelopes, never keywords in arbitrary output prose. Keep empty structured result records when they carry known outcome. Swift ChatMessage gains optional ChatTurnMetrics on its user row, keyed by native turnID and execution itemID, with local observed start/completion times and idempotent terminal step records. Historical elapsed time is an estimate from valid ordered timestamps; new live duration uses observed turn lifecycle, and old missing data remains unknown. Rebuild Swift FFI and both Rust slices for the optional historical field.


## Conversation visual refinement

Use semantic SwiftUI colors and a compact assistant header. Put the answer before the collapsed process disclosure, avoiding a large nested panel above the response. Render a typed three-part summary with time, execution and failure indicators; emphasize actual failure, retain explicit unknown/in-progress states, and keep copying accessible. Adapt long values and larger Dynamic Type rather than truncating meaningful state. Verify rendered light/dark screenshots.


## Final answer and ordered process boundary
Historical transport currently drops assistant phase. Add optional assistant_phase to host/client records and regenerate Swift FFI and both iOS library slices; preserve native commentary/final_answer or normalized final channel only. Live Codex items retain equivalent phase metadata. Presentation separates explicit final content from intermediate public records; unclassified legacy turns retain the last complete assistant message as answer and earlier messages in process details, without truncation or loss. Explicit commentary without final remains process content. Tool records, commentary and public summaries retain source order; only actual executions contribute to step metrics. The existing layout remains final result → collapsed 工具步骤 → statistics. Changes are limited to phase transport, projection, existing UI labels and targeted regression tests; no transport or pairing behavior changes.


## Structured user-answer boundary
Both live and imported user records already use the same ChatView user-row renderer, which currently emits raw Text. Add a pure Swift typed presentation/parser for the known question-reply envelope and a read-only compact user answer card. Strictly validate known keys/types before converting, retain unrecognized input verbatim, preserve surrounding text and array order, and do not reinterpret fenced code examples. Questions are secondary text, answers primary; long text wraps in semantic colors and accessibility sizes. Do not alter raw storage, Rust/FFI, user grouping, tool counts or approval/sending paths. References are documented in research/open-source-codex-ui.md.
