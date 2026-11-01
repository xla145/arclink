# Agent Bridge iOS mock UI

Scope: `agent-bridge/ios/`, SwiftUI on iOS 17+. The 0.1 contract is `doc/I-AB-0.1-UI-mock.md`; use `agent-bridge-mobile.html` and client document §04/§10 as visual references. Unpaired/demo workspaces retain local mock chat; paired Codex projects support real remote text/image chat (see the remote Codex contract below). As of the `10-31-ios-iroh-transport` task, real iroh transport exists: `agent-bridge/crates/agent-bridge-client` (UniFFI) provides persistent pairing, Control RPC (`Ping`/`GetSystemInfo`/`ListAgents`/`ListProcesses`/`Start|StopProcess`/`GetProcessStatus`), and raw `STREAM_AGENT_IO` byte streaming — Swift `TerminalSession` now provides explicit process start/attach/stop, while the separate `CodexChatSession` parses Codex app-server JSON-RPC for remote text chat — see "Real iroh transport" below before extending either direction.

## State contracts

`@MainActor @Observable AppStore` owns projects, sessions, messages and approvals. Views mutate shared state through the store. `ApprovalItem.sessionId` associates decisions with a session; `sessions(for:)` and `pendingCount(projectId:)` derive row counts. Do not store another independent counter on `ProjectItem`.

`resolve(_:approved:)` ignores missing/already resolved IDs, records the decision, updates session state and emits a toast. A rejection keeps the session cancelled even if a later request is approved. Completed decisions remain inspectable in approval history. Decision toasts remain visible for three seconds and expose the `toast` accessibility identifier; test that element rather than mistaking a history badge for transient feedback. `clearHistory()` clears sessions, messages and associated approvals together.

## Presentation

### Display brand and icons

Use `ArcLink` (Chinese brand: `弧连`) for visible product text and
`INFOPLIST_KEY_CFBundleDisplayName` in both Debug and Release. Preserve existing
bundle IDs, the `AgentBridge` target/scheme, protocol identifiers, and persisted
data/key names so branding does not invalidate existing devices or preferences.
Design masters live in `output/arclink-brand/`; ship the full-bleed, opaque
1024 × 1024 image at `AgentBridge/Assets.xcassets/AppIcon.appiconset/ArcLink.png`,
referenced by its `Contents.json`. The onboarding image uses
`AgentBridge/Assets.xcassets/ArcLinkLogo.imageset/` through `Image("ArcLinkLogo")`.
Let iOS apply the app-icon corner mask. Verify asset-catalog compilation and
the built app's display name; do not rename the internal target to change branding.

Use native NavigationStack, semantic grouped backgrounds, safeAreaInset for the chat composer and approval actions, and scroll-to-bottom after new messages or keyboard focus. The approval preview must match the operation: a diff for writing, the actual command/work directory for execution. A mock execution must never run a shell command.

Use an item-bound image sheet so its data and presentation change together:

```swift
@State private var expandedImage: ImagePreview?
// On tap: expandedImage = ImagePreview(image: image)
.sheet(item: $expandedImage) { preview in
    Image(uiImage: preview.image).resizable().scaledToFit()
}
```

Avoid a separate Boolean plus conditionally captured image state: the first sheet presentation can render empty. Use PhotosPicker and the system PasteButton for explicit local image selection.
Do not read the clipboard or photo library automatically. Draft images remain local until Send. For paired Codex chats, Send prepares bounded JPEG payloads and saves exactly the bytes passed to the native image input.

The UserDefaults `appearance` key accepts `自动`, `浅色`, `深色`; apply it at RootView. Retention is a mock preference only. Notification toggles change local UI state and do not register APNs.

## Row hit areas and toast contrast

For a grouped row with `.buttonStyle(.plain)`, apply `.contentShape(Rectangle())` to the padded label. Otherwise a short title may leave the center of the apparent row untappable. Keep body text semantic instead of inheriting the list button tint.

For inverse toasts, use explicit `Color.primary` for the background and `Color(.systemBackground)` for the text. A hierarchical `.primary` background combined with `.foregroundStyle(.background)` can resolve to the same foreground/background and produce an accessibility-visible but visually invisible toast. Verify the screenshot as well as the `toast` element's existence and label.

## Real iroh transport

`agent-bridge/crates/agent-bridge-client/src/connection.rs` exposes `BridgeConnection` (UniFFI `Object`: `connect`/`reconnect`/`disconnect`/`state`/`ping`/`getSystemInfo`/`listAgents`/`listProcesses`/`startProcess`/`stopProcess`/`getProcessStatus`/`attachIo`), `ConnectionState` (`Enum`), and `IoHandle`/`AgentIoCallback` for raw `STREAM_AGENT_IO` byte streaming. `AppModel.swift` keeps one runtime per paired endpoint and projects the selected runtime as `connectionState`/`macAgents`; `reconnectIfNeeded()` refreshes all devices on `ScenePhase == .active`.

## Scenario: simultaneous paired devices

### 1. Scope / Trigger

`AppModel.swift`, `DeviceStorage.swift`, `HomeView.swift`, `SettingsViews.swift`,
and `RootView` support multiple paired Macs. The current selection controls the
displayed workspace; it must not control which other Macs remain connected.
Projects/chat/approval semantics retain their existing real/mock boundary.

### 2. Signatures

- `PairedMac(id, name, endpointID, workspace)` owns one `DeviceWorkspace`.
- `DeviceSnapshot(version: 2, devices, selectedDeviceID, orphanedWorkspace, ...)`
  stores device workspaces and application-wide notification preferences.
- `DeviceStorage.load()` / `save(_:)` own migration and atomic file writes.
- `AppStore.selectDevice(_:)`, `removeDevice(_:)`, and
  `pair(from:repairingDeviceID:)` are the device mutations.
- `refreshMacStatus()` refreshes all eligible devices concurrently;
  `suspendHealthChecks()` invalidates stale foreground work.
- `setRealProcess(deviceID:sessionId:processId:generation:)` records a result
  against its original device, even if the visible selection changed.

### 3. Contracts

Store `devices-v2.json` under the existing Application Support/AgentBridge
directory. Migration reads `state.json`, preserves `state-v1-backup.json`, and
never overwrites the original single-device file. A paired legacy snapshot
becomes one device; an unpaired snapshot's workspace is preserved separately,
not assigned to an unrelated new Mac. Do not persist online state, runtimes,
one-time pairing tokens, or async tasks. Preserve the existing identity key.

Workspaces isolate projects, sessions, messages, approvals, selected Agent and
permission. Notifications remain application-wide. `AppStore` exposes the selected
workspace through its existing computed properties. Runtime dictionaries are
keyed by device ID, with independent refresh/generation guards. Switching selection
persists the ID and clears `RootView`'s navigation path, without disconnecting
other transports. Foreground health checks are periodic; iOS background suspension
does not guarantee live sockets or APNs delivery.

Pairing keeps candidate name/endpoint local until success. Duplicate endpoints
update the existing record, retaining its workspace. A legacy record without an
endpoint has an explicit re-scan action targeting that record; do not silently
attach its history to an already stored different endpoint. Pair cancellation
invalidates the operation generation. Removing a device closes only its runtime
after persistence succeeds. It does not claim to revoke authorization on the Mac.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Unsupported/corrupt snapshot, duplicate IDs/endpoints, invalid selection | Preserve files; show storage error; block overwrite |
| New pairing fails/cancels | Keep prior selection, records and connections |
| Pair/select/remove write fails | Restore previous records/selection |
| LAN-only legacy record | Keep history and show re-scan requirement |
| Response after removal/background generation change | Ignore stale result |
| One host fails | Clear only that runtime's live state; other hosts stay usable |
| Process start completes after UI switch | Write result to captured device ID |

### 5. Good / Base / Bad Cases

Good: A and B stay connected, selection changes to B, then an A refresh updates
only A. Base: re-launch restores both records and selection but verifies online
status afresh. Bad: an async callback writes into the globally selected workspace
after selection changed, or re-pairing overwrites the old device's history.

### 6. Tests Required

Test legacy paired/unpaired/LAN-only migration, corrupt-file preservation,
duplicate endpoint pairing, cancelled late pairing, same local IDs on different
devices, selection persistence, per-device failures/removal, background late
responses, and process-result routing. Verify the home device button, both themes
of the list, add-device scanner, current-selection indicator and navigation reset.
Keep fake transport/simulator fixture evidence distinct from real multi-Mac tests.

### 7. Wrong vs Correct

Wrong: after an await, update `store.sessions` using whichever device is currently
selected. Correct: capture `deviceID` before the await and update that device's
workspace only if it still exists. Wrong: replacing the single `bridge` when a row
is selected. Correct: select a workspace while retaining each device's runtime.

### Don't: raw Rust error text in the UI

`BridgeError`/`PairOutcome.errorMessage` are English diagnostic strings meant for logs (e.g. `"Could not reach the Mac. Check both networks."`), not end-user copy. Map the stable `error_code` (not `error_message`) to a Chinese string in Swift before calling `show(...)` — see `AppStore.localizedPairError(code:message:)` in `AppModel.swift` for the current code→string table (`unreachable`, `timeout`, `network_error`, `identity_error`, `invalid_params`, `incompatible`, `protocol_error`, `pairing_state`/`unauthorized`). Showing the raw message reads to a Chinese-speaking user as "nothing happened."

### Gotcha: `.fullScreenCover` hides the root toast

`RootView` renders `store.toast` as an overlay, but a `.fullScreenCover` (e.g. `QRScanScreen`) completely occludes the presenting hierarchy — any toast triggered while the cover is up (a failed pair, an invalid QR) never appears, and the screen looks unresponsive even though the Swift-side logic ran correctly. Any view presented via `fullScreenCover`/`sheet` that can trigger `store.show(...)` needs its own toast overlay bound to the same `store.toast`/`.animation(value:)` pair (see `QRScanScreen`'s `.overlay(alignment: .bottom)` in `Components.swift`), not just the presenter's.

### Gotcha: tap-to-focus must stay in continuous AF/AE mode

`AVCaptureQRScanner`'s tap-to-focus (`Components.swift`) sets `focusPointOfInterest`/`exposurePointOfInterest` but must leave `focusMode`/`exposureMode` on `.continuousAutoFocus`/`.continuousAutoExposure`. Switching to the one-shot `.autoFocus`/`.autoExpose` modes locks focus at whatever distance that one tap happened to be — the camera never refocuses again, so scanning a QR code at a different distance/position afterward silently fails with no error. This is easy to introduce when adding "tap to focus" polish and the symptom ("scanning stopped working") looks unrelated to the cause.

### Real-device signing

The project hardcodes `CODE_SIGNING_ALLOWED = NO` / `CODE_SIGNING_REQUIRED = NO` in both Debug and Release (simulator-only by default). To build+install on a physical device: either edit those two keys to `YES` plus `CODE_SIGN_STYLE = Automatic` and `DEVELOPMENT_TEAM = <team>` in the target's build settings, or pass them as `xcodebuild` command-line overrides. Automatic signing additionally needs an Apple ID actually **signed into Xcode's Accounts** — a certificate merely present in the keychain is not enough and produces `error: No Account for Team "<id>"`. Get the real Team ID from Xcode's own Signing & Capabilities resolution (it writes it back into the `.pbxproj`); don't guess it from a keychain certificate's parenthetical suffix, which can be stale or belong to a different team than the one actually logged in.

The crate's iOS static lib pulls in `netdev`/`netwatch`/`system-configuration` (via `iroh`) for network-interface/DNS monitoring; `cargo build`'s own `rustc-link-lib=framework=SystemConfiguration` only applies when cargo performs the final link (a native macOS binary), not when Xcode's `ld` links a prebuilt `.a`. Without an explicit `SystemConfiguration.framework` entry in the Xcode target's Frameworks build phase, the **app** link step (not `cargo build`) fails with `Undefined symbols for architecture arm64: _SCDynamicStoreCopyProxies` etc.

### Gotcha: a system proxy/VPN can silently break iroh pairing

A system-wide proxy/VPN in Fake-IP+TUN mode can interfere with DNS resolution, direct NAT traversal and relay reachability even when `curl https://<relay-host>/` returns `200 OK`. Direct iroh paths use UDP/QUIC; HTTPS relay paths carry encrypted endpoint traffic over TLS/TCP/WebSocket and do **not** require working public UDP. DNS in the `198.18.0.0/15` benchmark-test range indicates a Fake-IP mapping, not the relay's public address. Diagnose the resolver and actual iroh handshake separately from a homepage request. Preserve TLS certificate verification and do not alter system-wide VPN settings automatically. A successful SSH-tunneled relay test proves the server protocol path, not cellular reachability. With HTTPS-only private relays use `RelayConfig::new(url, None)` for the absent QAD endpoint, and keep HTTPS latency probes enabled so a home relay can be selected when UDP is blocked.

## Verification

Build `AgentBridge` simulator Debug with signing disabled. Run the shared scheme's `AgentBridgeUITests/MockPathTests`: both themes must verify search/agent filters, new session/send/reply, keyboard hittability, attachment zoom, event details, approval decisions/history, paired Mac and preference controls. Tap the right-side native switch control in automation; its row text does not toggle it. LabeledContent may expose its label/value as one accessibility element.

Export original XCTest screenshots via `work/codex-runs/export-screenshots.py`. Require at least home/project/chat-with-reply/approval/settings in both themes; retain full build and test logs and inspect the PNGs visually before marking acceptance-ready.


## Compact project conversations and rich message presentation

The native UI follows `doc/arclink-home-chat.html`. Home uses fixed Agent tabs,
a per-Agent current project, bell-to-approvals, gear-to-settings and a scoped
conversation chooser. `DeviceWorkspace.selectedProjectIDs` is optional for old
snapshots. Validate a saved selection against both project existence and Agent;
fall back to a matching project. Choosing a project never creates a session.

Home balances readable content with a modest header: use semantic body text for
project names, caption text for metadata, 12 pt outer card margins and 18 pt
section spacing. Keep Agent tabs at least 44 pt tall; project names may wrap to
two lines, with the current-project label above the name rather than beside it.

`SessionSource` distinguishes `.cli` (phone-created local conversation) from
`.desktop` (Mac-imported read-only history). Decode old Codex/Claude detail
markers as desktop. This is a local presentation distinction: upstream history
does not expose the original program launch source. Enforce read-only and send
permission in the store as well as the composer. Keep real terminal controls
separate from the explicitly labelled simulated chat send/approval flow.

`ChatMessage.imageAttachments` is optional; `images` falls back to legacy
`imageData`. Accept at most four valid images of 10 MiB each. `ChatAttachment`
checks dimensions and downsamples picks to 2048 px JPEG. Async photo/paste
results must match the draft epoch; leaving the conversation invalidates it.

`MacMessageText` / `MessageMarkdown` are shared by local and imported text.
Render native blocks, safely preserve unsupported text, scroll code/tables
internally, and allow only HTTP(S)/mailto links. Markdown images accept bounded
raster data URLs or HTTP(S) requested explicitly by the person; never load local
files. Image sheets are item-bound. `MessageDisclosure` displays only supplied
public summaries/tool content. Host roles `summary` and `tool` need no FFI
shape change; do not infer or expose private reasoning.


Device selection is presented through `DevicePickerSheet` from Home and
Settings, with its own NavigationStack and explicit completion. Preserve the
main device/workspace isolation, including selecting after scanner cancellation
and relaunching. UI tests should target the unique project row identifier and
verify its label plus a real tap; the current-project card duplicates its title.
If an unsigned simulator test run reports steps absent from current source,
reinstall the test runner before treating that output as a new code regression.

The QR representable tears down its capture session and metadata delegate on
view dismantle, using one serial queue for capture configuration/start/stop and
camera control. Scanner sweep animations use finite, cancellable tasks rather
than retaining a forever animation transaction after leaving the screen.


## Private relay integration

See [the private relay contract](../backend/agent-bridge-private-relay.md) for additive APIs, QR metadata, Keychain namespaces, validation, shared endpoint leases and actual path reporting. Keep existing device identity, history and Agent lifecycle contracts.


## Scenario: persistent project and conversation-list cache

### 1. Scope / Trigger

Applies to AppStore, DeviceWorkspace and project/conversation views when loading
ListAgentProjects (which includes conversation summaries). Existing persisted
workspace rows remain the immediate display projection. Message-body loading
is outside this cache contract.

### 2. Signatures

- `DeviceWorkspace.projectCatalogs: [String: ProjectCatalogCache]?` persists
  catalogs keyed by Agent ID; `nil` decodes older v2 records.
- `ProjectCatalogCache(fetchedAt: Date, projects: [MacProject])` stores Codable
  project/thread DTOs and exposes `isFresh(at:)` / `values`.
- `AppStore.cachedMacProjects(deviceID:agent:) -> [MacProject]?` reads locally.
- `AppStore.loadMacProjects(deviceID:agent:force:) async -> [MacProject]?`
  owns freshness, refresh, coalescing and persistence.
- `AppStore.refreshConversationList(agent:force:) async` captures selection;
  views must not call `BridgeConnection.listAgentProjects` directly.
- Existing DeviceStorage.load/save remain the atomic persistence boundary.

### 3. Contracts

Cache catalogs by paired device ID and Agent ID. A successful catalog stores its
fetch time and bounded project/thread DTOs; an empty successful result is valid.
Freshness is five minutes and survives relaunch. Future timestamps are stale.
Views render local rows immediately; stale/absent catalogs refresh in the
background when connected. Explicit pull-to-refresh bypasses freshness.
Concurrent requests for the same device/Agent share one in-flight request.

A response may update only its original device/runtime generation. Device
removal, runtime replacement or foreground invalidation rejects late results.
Save the catalog/freshness and derived rows together; failed persistence restores
the previous workspace. Keep local conversations and their history untouched.
Old device JSON without a catalog decodes and can obtain its first cache.

### 4. Validation & Error Matrix

| Condition | Behavior |
| --- | --- |
| Fresh successful cache | Return local data, no catalog RPC |
| Expired/absent cache, connected | Refresh without clearing displayed rows |
| Explicit refresh | Bypass age; coalesce with existing request |
| Successful empty response | Persist fresh empty catalog |
| Offline or RPC failure | Keep prior catalog/rows/time; explicit refresh gives feedback |
| Persistence failure | Roll back catalog/time and derived rows |
| Removed/replaced/invalidated runtime | Ignore late result |

### 5. Good / Base / Bad Cases

Good: relaunch with fresh cache and open the chooser without a catalog RPC.
Base: offline browsing keeps the last list; pull-to-refresh after reconnect
updates it. Bad: every page open fetches from Mac, or a failed request is marked
fresh and suppresses retry.

### 6. Tests Required

Assert RPC counts for fresh relaunch, expiry, force refresh and coalesced loads;
empty success versus failed request; stale offline preservation; write rollback;
Agent/device isolation; late responses after removal/runtime invalidation; old
record decoding. Build the application and test targets, reporting XCTest
execution separately from compilation.

### 7. Wrong vs Correct

Wrong: view.task calls listAgentProjects on every presentation; a runtime Set
marks an Agent imported before its request succeeds.
Correct: views use AppStore's shared durable cache policy, with success-only
freshness and retained stale data on failure.

## Imported conversation source

`MacThread.source` is optional for old hosts and carries `cli`, `desktop`, or
`unknown`. Preserve it in `CachedMacThread` and map only at `SessionSource`.
A source-only refresh must update existing rows. Catalogs without `sourceSchema`
remain readable offline but are stale for the next connected refresh. Imported
rows (`Codex 对话` / `Claude 对话`) are read-only regardless of origin; never use
CLI source as authority to send or start a process for a historical thread.
`stopSession` and `resolve` must reject imported history before mutating its
status/detail; those markers identify historical rows on old persisted records.
Unknown source remains explicit in lists and filters. Regenerate UniFFI bindings
and both iOS static libraries together when the record changes.


## Remote Codex text chat

`CodexChatSession` owns exact-version app-server JSON-RPC over existing authenticated
`StartProcess` and `STREAM_AGENT_IO`. The embedded Mac host remains an opaque byte
relay and enforces session/task/approval grants. New paired Codex chats initialize,
create or resume a persisted native thread, start turns and project only public
assistant messages. Command/file approval requests use native request IDs; unsupported
interactive requests are explicitly refused. Never synthesize successful assistant
replies or approval requests for a real paired endpoint.

The driver belongs to AppStore's captured `(deviceID, sessionID)`, not a ChatView.
Callbacks may update only that original workspace and current driver instance.
Retain incomplete UTF-8 as bytes until a complete bounded NDJSON record exists;
use a bounded FIFO callback stream rather than independent actor tasks per chunk.
The chat driver exclusively owns the process input lease; TerminalView must not
attach to or stop that same process. Persist optional `codexThreadId` backward
compatibly and avoid catalog duplication of a writable phone-created native thread.

Send acknowledgment and turn completion are separate. Definite rejection preserves
the draft; unknown delivery remains visible in history and blocks blind replay.
A failed pre-turn startup can be retried by an explicit send with a fresh driver.
No automatic mutating-input replay or background-delivery guarantee is implemented. Cross-connection byte resume is provided by the recoverable chat contract below. Unknown delivery must be reconciled before another send; interactive tool/user-input prompts remain unsupported. Stop sends
`turn/interrupt`; only native completion marks the turn stopped.

Validation: `CodexChatSessionTests`, `RemoteChatTests`, existing conversation/cache
regressions, and opt-in `real_codex_chat_turns_over_iroh` (two real read-only model
turns). The latter proves the Mac embedded-host path and installed native protocol,
not a physical iPhone's cellular/background behavior.


## Remote image input and foreground recovery

`RemoteChatImage` uses ImageIO thumbnailing and JPEG encoding. Accept at most four
valid locally selected images (original <=10 MiB), encode each <=256 KiB and all
<=1 MiB. Both image-only and mixed turns use real `image` data URLs. The saved
user message contains the exact prepared payload. Definite failures preserve the
composer; never claim a local-only attachment was uploaded.

`CodexChatSession` uses record-framed `attachChatIo` and retains process identity,
lease proof, per-channel next byte offsets, partial NDJSON bytes, native request
correlation, active turn and approvals in memory. Network failure suspends the
physical writer. A new attachment epoch ignores late callbacks; resumed output
clips overlaps and reports gaps explicitly. Never initialize the existing native
process again or replay turn/start/approval writes. Pending and timed-out ACKs
remain correlated; authoritative native clientUserMessageId/clientId snapshots
can settle them without creating another turn.

Recovery reads metadata and bounded turn/item pages instead of full image-bearing
history. Native turn completion and runtime activity fence the next send.
AppStore coalesces host reconnect by device and reattachment by chat, with four
short exponential attempts and explicit retry. Background/removal invalidates
recovery publication; a foreground/reachability transition can reset retry budget,
ordinary healthy polls cannot. The UI shows restoring/uncertain/lost state.

Checkpoint/partial input state is not persisted by itself. After a cold launch,
query a stored prior process first; if still live, block a duplicate new process
and direct the user to check it on the Mac. Ended/lost processes may resume the
persisted native thread, checking runtime activity before sending. A host restart
does not resurrect a lost process, and an evicted output gap is not full recovery.


Project catalog source schema 2 invalidates older successful caches on the next
connected load while retaining them for offline browsing. A successful empty
native project catalog removes prior imported-only projects and their imported
rows; local phone conversations remain protected. Verify removal survives relaunch.


## Historical step summary and detail interaction

`AgentStepsDisclosure` expands to short public excerpts only; tapping an individual
`MessageStep` opens an item-bound detail sheet with separate input/output sections.
Reasoning-summary steps show only the recorded public summary. Create full Markdown
bodies only in the selected detail sheet, not for every collapsed step. Disclosure
headers and step rows have full-width hit areas at least 44 pt tall.

`MacMessage` optional toolCallId/toolName/toolPhase metadata correlates input/output
by native call ID, including parallel outputs arriving in reverse order or across
assistant prose. Never pair legacy records by adjacency. Retain unmatched results
and explicitly label missing input/output; do not fabricate records. DEBUG UI tests
may inject historical messages only under a valid isolated ARCLINK_UI_TEST_ID using
ARCLINK_UI_TEST_MAC_MESSAGES; Release always uses the real Mac history RPC.


## Start-conversation form

Home's floating chat action presents `NewConversationSheet` at large detent:
project, per-session execution policy, model, first message, and up to four
prepared images. Merely opening or cancelling it creates no session. Starting
sends the first message through the existing real/mock boundary; success or
unknown retained delivery navigates to that same session. Definite failure keeps
the draft/images and reuses the provisional row on retry. Offline preflight
creates no provisional row. Capture device identity; do not navigate a late send
result into a newly selected device. Disable duplicate submission/dismissal
while awaiting send. Epoch-fence photo/paste completion and wait for pending
image loads before enabling start.

`SessionItem.chatOptions` is optional for old snapshots. Codex configures model
and sandbox/approvalPolicy before native thread start/resume; old rows default
to workspace-write/on-request and omit model to retain Mac settings. Read-only
maps to read-only/never, full access to danger-full-access/never. These are
execution settings, never a replacement for paired-device authorization.
Unsent startup failures may revise setup; native thread/process identity,
recorded messages, active/recovering or uncertain delivery freeze setup.

Model choices are automatically fetched bounded display metadata from the Mac
cache via ListAgentModels. Re-fetch when connectivity changes. Offer the Mac
default when metadata is empty/unavailable; never ask users to enter model IDs.
No bundled model catalog or fabricated success. Unavailable selections must remain
a normal failed send with the draft preserved.


## Scan completion and Home navigation

`AppStore.pair(from:repairingDeviceID:)` completes only for an authenticated
iroh result with `ok == true && pending == false`, after durable device/credential
storage succeeds. HTTP invitation submission is not approval and must never
create a paired device: endpoint-less legacy QR codes request a refreshed Mac QR.
Old endpoint-bearing invitations remain supported with optional network hints.

`pairingSuccessID` is an ephemeral completion event, never persisted; change it
after every durable completion, including re-scanning the selected endpoint.
RootView clears its navigation path on this event. DeviceListView invokes its
chooser completion after a successful scanner dismissal so nested sheets close
as well. Pending approval displays `pairingPhase`; rejection, cancellation and
storage failure do not emit success or navigate Home. Test relay-only invitations,
repeated current-device scans and unsuccessful outcomes separately from real
cellular/device acceptance.


Pairing progress must come from authenticated protocol milestones. The additive
`pairOverIrohWithProgress` callback emits connecting, handshaking, and
awaitingApproval; only an actual pending ACK permits the last state. Consume
callbacks in order via one AsyncStream task, checking the pairing generation
and active phase before publication. Cancel the consumer on completion. Display
connection-deadline versus approval-deadline errors distinctly; do not show a
Mac-confirmation instruction merely because a QR decoded successfully.


## Scenario: combined assistant turns and execution summaries

### 1. Scope / Trigger
Conversation detail history and live chat group native assistant items into one visible reply per user turn and display elapsed time, execution count and failures.

### 2. Signatures
`ConversationTurn.live(_:)` and `history(_:formatTime:)` project raw rows for ChatView. `ChatMessage.turnMetrics: ChatTurnMetrics?` is optional Codable data; metrics retain native turnID, observed start/completion dates, completion state and itemID-keyed `ChatExecutionStep` records. Historical `MacMessage.toolFailed: Bool?` is additive from host `tool_failed`.

### 3. Contracts
Actual user rows are hard grouping boundaries, including image-only/consecutive users. Keep explicitly final assistant paragraphs in original order; put public intermediate commentary and recorded summaries into ordered process steps. Retain images and full step details, and never mutate source content or deduplicate identical prose. Historical tool pairing stays within one turn and uses call IDs, including reversed parallel results. Summaries exclude reasoning records from execution counts. Native item replay updates one step; a replayed start cannot erase a terminal result. Keep approximate history timing distinct from precise claims; missing or invalid dates/outcomes remain unknown. No APNs or secret reasoning inference is involved.

### 4. Validation & Error Matrix
- Old messages without metrics/outcome fields: decode normally; show unknown statistics.
- Known nonzero exit/error flag: failed; plain text mentioning failure: unknown.
- Partially unknown results: retain known failures and display unknown count.
- Missing/reversed timestamps: no fabricated duration; an active live turn remains in progress.
- New user/turn or replay: no cross-turn attribution or duplicate execution count.

### 5. Good / Base / Bad Cases
Good: user → commentary → tool → final renders one assistant reply with one execution step. Base: legacy history renders with unknown failure status. Bad: count call and result separately, merge across users, or infer success because output exists.

### 6. Tests Required
Assert paragraph/image preservation, stable group IDs, multiple turns, summary-only steps, parallel output matching and repeated call IDs across users. Assert structured failures, absent metadata, native replay, terminal-state retention, timing boundaries/formatting and old Codable records. UI fixture verifies one assistant bubble per turn and visible summary plus accessible step details.

### 7. Wrong vs Correct
Wrong: render every assistant response item as a separate bubble, or search its prose for “error”. Correct: project by user turn and use native structured outcome metadata, preserving unknown values.


### Conversation card presentation
Keep assistant prose before the compact expandable process-record row. The header contains an Agent badge/name, timestamp and an accessible copy control with a44-point target. Render statistics from typed ConversationSummary fields, not by parsing formatted text: semantic icons/labels above independent values, a subtle separator and explicit unknown-result note. Only real failures receive failure emphasis. Accessibility Dynamic Type uses vertical header/metric/action layout rather than compressing labels. Use semantic light/dark colors. Process disclosure counts all public records; label it “工具步骤” per the product request, but distinguish record count from the execution-step statistic (commentary and public summaries are not executions). Verify light/dark, expanded step details and large-text screenshots.


### Final-answer-only projection
Display final result first, collapsed 工具步骤 second, and execution statistics last. Preserve native assistant phase as optional backward-compatible metadata. Explicit commentary is process content even when no final answer has arrived; multiple explicit final messages remain complete and ordered. For legacy unclassified turns, use the last complete assistant message as answer and retain earlier messages as process records. Commentary, recorded public summaries and tool steps retain original source positions; do not sort by type. Copy acts on final answer content. Do not expose private reasoning or infer classification from prose keywords.


### Structured completed user answers
Treat send_user_message_question_reply as display data, never as application instructions. Only user-role presentation may recognize its validated question/answer array. Render completed answers as a read-only user card with secondary question text, primary answer text and original array order. Omit questionItemId and wrapper syntax from recognized cards, but preserve raw message storage. Preserve surrounding prose in order; unknown schema, malformed payloads and quoted code examples retain raw text rather than silently dropping information. Do not add submit actions to historical answers, alter turn boundaries or count these answers as AI execution steps. Live and imported user rows share the same renderer. Verify multi-question, multiple-block, malformed/unknown fallback and long-text accessibility cases.
