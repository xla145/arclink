# ArcLink direct-first private relay integration

## Goal
Desktop and iOS maintain encrypted remote access to an authorized Mac: use an available direct path preferentially and fall back to the user's self-hosted relay when required. Existing identities, grants and device workspaces survive the change.

## Background
The user deployed `https://iroh.classktv.com` and explicitly requested both connection paths with direct preference. Deployment and its verification limits are recorded in `output/iroh-relay/deployment.md`. The relay requires a private access key and does not provide QUIC address discovery. Repository findings and source anchors are in `research/connection-contracts.md`.

## Requirements

### R1 — Automatic direct-first connection
Keep IP transports, normal discovery and NAT traversal enabled. Permit immediate relay establishment while direct candidates are negotiated. When a viable direct path becomes available, use it; preserve the session when the path changes. Retain current default behavior when private relay configuration is absent. An unavailable relay must not itself prohibit a reachable direct peer.

### R2 — Private relay provisioning
User refinement: pairing is scan-only. Direct hints and the private relay credential are imported together; neither desktop nor phone asks the ordinary user to enter relay addresses or keys. Remove the manual relay form from product settings. Desktop provisioning remains native/admin-managed for this private deployment. Secrets are stored in OS Keychain under a separate namespace, never in source, public settings snapshots, diagnostics, or ordinary device JSON. For a provisioned Mac, a transient pairing invitation carries the private relay credential alongside direct address hints for automatic scan import; the UI states that this imports private relay access. New phone pairing requires no manual retyping. Existing phone devices can update relay configuration via a refresh scan, retaining their endpoint identities and workspaces. In the first rollout, provision the current Mac from the server's protected access-key file via native Keychain; no shared secret is compiled into release binaries.

### R3 — Pairing, discovery and backward compatibility
Keep version-1 QR compatibility via optional, bounded relay metadata and direct address hints. Validate once at the boundary. Keep older pair and connection APIs as compatibility wrappers. Preserve existing phone identity files, desktop identity Keychain items, one-use approval tokens and Mac-local authorization. Persist only validated non-secret relay references and address hints; Keychain stores the credential. Re-scanning the same Mac refreshes settings and preserves history. Stage candidate credentials until pairing/persistence succeeds; failed/cancelled scans must not replace working credentials or disrupt other devices.

### R4 — Multi-device and live configuration isolation
Continue one endpoint owner per phone identity. Maintain a union of relay configurations needed by the phone's saved devices; a host update, failed scan or removal must not close the entire endpoint or replace another relay's credential. Conflicting credentials for the same canonical relay authority require deliberate credential update, not silent overwrite. Desktop configuration changes preserve running Agent processes and paired grants; notify the user if the host transport must reconnect.

### R5 — Observable status and error behavior
Show actual selected paths as direct/relay/unknown while retaining connected/disconnected state. Never infer direct usage merely because relay is configured or a connection exists. Missing/invalid relay settings show actionable Chinese errors without secret or raw diagnostic leakage. Continue honoring generation checks, unknown operation outcomes and no automatic replay of Agent/process mutations.

## Acceptance criteria
- AC1 (R1/R5): a fixture connection with both paths selects direct; when direct is unavailable it exchanges encrypted data through a private authenticated relay. Observe relay-to-direct upgrade without losing Control RPC/stream ownership.
- AC2 (R1): with an unreachable private relay and a usable direct address hint, pairing/Control RPC remain possible; tests do not globally disable IP transports in production code.
- AC3 (R2/R3): configure the Mac, scan on iOS, approve on the Mac, restart both apps and reconnect with stable device identities. No relay key appears in tracked files, snapshots, logs or device JSON.
- AC4 (R3): old QR payloads and old device records load; relay settings can be refreshed for an already paired endpoint without losing workspace/history or duplicating a device.
- AC5 (R3/R4): malformed QR, rejected/cancelled pairing, Keychain failure and persistence failure preserve previous credentials and other active hosts.
- AC6 (R4): connect to two Macs, update/remove one, and continue RPC/Agent I/O to the other using the same phone identity.
- AC7 (R5): frontend tests/type-check, Rust transport checks and regenerated iOS bindings/build pass. Path status follows actual selection and credentials remain redacted on error.
- AC8: attempt real desktop-to-iOS checks on LAN and cellular/different Wi-Fi. Record exact evidence and any external/device-signing limitation; SSH-tunnel/fixture evidence is not cellular acceptance.

## Out of scope
frpc integration; a new cloud account/control plane; multi-tenant relay credential issuance; server protocol replacement; APNs/background socket guarantees; structured Agent chat semantics; automatic replay or lossless terminal-history recovery. No redesign of existing product navigation.

## Planning review
No blocking product question remains beyond approval of this concrete first-release scope. Design, execution plan and curated context accompany this PRD. Implementation starts only after a subsequent approval of the final planning summary.

## Scan-only refinement

User explicitly requested automatic direct/relay pairing without manually entering addresses or keys. Retain automatic selection and secure Keychain storage. Settings show connection behavior/status and guide existing devices to re-scan; do not expose credential forms. Native provisioning APIs may remain for administration, with no compiled shared secret.

## Follow-up: local conversation list cache (user authorized)

Phone conversation/project listings should render persisted local data immediately rather than resync from the Mac on every visit/relaunch. Cache successful per-device/per-Agent project/thread catalog results for five minutes, including successful empty responses; explicit refresh bypasses freshness. Expired data remains visible offline or on refresh failure, while a connected refresh updates in the background. Never mix caches across Macs/Agents or apply stale results after selection/removal/runtime generation changes. Existing locally created conversations and history remain intact. No host/protocol/FFI changes.

Acceptance: fresh persisted cache avoids ListAgentProjects across relaunch/visits; stale cache updates while visible; force refresh reaches Mac; empty success and failure differ; duplicate calls coalesce; two-device isolation, late result rejection and old record compatibility are covered.

## Follow-up: cellular scanning and successful pairing navigation (authorized)

The phone must pair using authenticated iroh direct/relay transport on Wi-Fi or cellular. Submission/pending is not success: only Mac approval followed by durable phone storage completes pairing. Success closes the scanner and device chooser and returns to Home even when refreshing the currently selected Mac. Rejection, cancellation and storage failure retain the current device and do not publish success. Legacy QR codes without an endpoint require a fresh Mac QR; the old HTTP submission cannot establish an authenticated device grant. Physical cellular acceptance remains separate from local relay fixtures.

## Follow-up: no Mac reaction during scan (authorized)

A connecting phone must not claim the Mac is awaiting approval before the Mac acknowledges the invitation. Endpoint setup, relay registration, dialing, handshake and submission must have a bounded overall connection deadline. After actual pending acknowledgment, show the Mac approval instruction with a separate bounded approval window. Preserve cancellation/generation guards and old pairing APIs. Diagnose the actual host relay reachability in parallel; progress changes alone do not fulfill cellular connectivity.

## Follow-up: slow successful project conversation loading (authorized)

The user clarified that Codex project conversation lists do load successfully,
but slowly over the relay. Improve that latency without changing stored history,
five-minute catalog freshness, authorization, or introducing unrelated error UI.
The measured real catalog is six projects/140 threads/27,256 bytes and takes about
18ms to read locally; local authenticated ABP takes49ms. Therefore do not increase
timeouts or redesign pagination based on an unobserved disk/size failure.


## Follow-up: one assistant reply per turn and execution summary (authorized)

The user requests one combined AI reply for each user turn in conversation details, including imported history and live chat. Retain every source text paragraph, image and inspectable tool step without rewriting raw messages. A new actual user message starts a new group. Each assistant group displays elapsed time, execution-step count and failed-step count. Count one native tool call/item once; reasoning summaries are not execution steps. Unknown outcome/timing must remain visibly unknown, and incomplete turns must not claim completion. Preserve old device records and support recovery/replayed events without double counting.


## Visual refinement (authorized)

User additionally requests a more polished conversation detail UI. Prioritize assistant prose, keep execution details compact and expandable, and show elapsed time/steps/failures in a readable compact footer. Preserve factual statistics, images/Markdown, accessibility and light/dark appearance. Scope remains the current conversation detail page.


## Final-answer-only follow-up
User requests that only final results appear in reply prose. Public intermediate assistant commentary and recorded reasoning summaries belong in the collapsed tool-step area, preserving their source order alongside tool activity. Display order: final result, tool-step disclosure, elapsed/steps/failures summary. Preserve all raw content and old persisted-data compatibility.


## Structured user-answer presentation
User supplied an RTF example of send_user_message_question_reply and requested open-source Codex UI investigation followed by appropriate UI improvement. Display recognized completed question/answer records as readable, ordered, read-only user content; hide protocol keys in this recognized presentation. Preserve surrounding prose, user boundaries, original stored text and existing final→tools→metrics layout. Unknown, malformed or quoted payloads must not lose data.
