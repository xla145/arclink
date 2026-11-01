# Agent Bridge iOS mock UI

Scope: `agent-bridge/ios/`, SwiftUI on iOS 17+. The 0.1 contract is `doc/I-AB-0.1-UI-mock.md`; use `agent-bridge-mobile.html` and client document §04/§10 as visual references. Project/session/approval/chat state is still local mock (see `agent-bridge/ios/README.md` for the current real/mock boundary). As of the `10-31-ios-iroh-transport` task, real iroh transport exists: `agent-bridge/crates/agent-bridge-client` (UniFFI) provides persistent pairing, Control RPC (`Ping`/`GetSystemInfo`/`ListAgents`/`ListProcesses`/`Start|StopProcess`/`GetProcessStatus`), and raw `STREAM_AGENT_IO` byte streaming — Swift `TerminalSession` now provides explicit process start/attach/stop, while nothing parses a given Agent's own protocol (Claude Code/Codex semantics, e.g. a "project list") — see "Real iroh transport" below before extending either direction.

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
Do not read the clipboard or photo library automatically. Draft images are
saved locally with the message; selection is not a remote upload.

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

A system-wide proxy/VPN in Fake-IP+TUN mode (common on macOS via Clash/Surge/V2Ray-style tools, common in China) can break both iroh connection paths (direct NAT traversal and relay), since both ultimately depend on UDP/QUIC that such tools often don't forward correctly — even though a plain `curl https://<relay-host>/` through it can still return `200 OK`. Diagnostic signature: `dig` any domain (including unrelated ones like `google.com`) and see it resolve into the `198.18.0.0/15` IANA benchmark-test range — that's the proxy's Fake-IP pool, not a real public IP. If iOS↔Mac pairing fails with `unreachable`/`timeout` and this network has that symptom, disable the Mac's proxy/VPN and retry before assuming a code bug.

## Verification

Build `AgentBridge` simulator Debug with signing disabled. Run the shared scheme's `AgentBridgeUITests/MockPathTests`: both themes must verify search/agent filters, new session/send/reply, keyboard hittability, attachment zoom, event details, approval decisions/history, paired Mac and preference controls. Tap the right-side native switch control in automation; its row text does not toggle it. LabeledContent may expose its label/value as one accessibility element.

Export original XCTest screenshots via `work/codex-runs/export-screenshots.py`. Require at least home/project/chat-with-reply/approval/settings in both themes; retain full build and test logs and inspect the PNGs visually before marking acceptance-ready.


## Compact project conversations and rich message presentation

The native UI follows `doc/arclink-home-chat.html`. Home uses fixed Agent tabs,
a per-Agent current project, bell-to-approvals, gear-to-settings and a scoped
conversation chooser. `DeviceWorkspace.selectedProjectIDs` is optional for old
snapshots. Validate a saved selection against both project existence and Agent;
fall back to a matching project. Choosing a project never creates a session.

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
