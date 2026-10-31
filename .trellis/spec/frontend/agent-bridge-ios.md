# Agent Bridge iOS mock UI

Scope: `agent-bridge/ios/`, SwiftUI on iOS 17+, no external dependencies. The 0.1 contract is `doc/I-AB-0.1-UI-mock.md`; use `agent-bridge-mobile.html` and client document §04/§10 as visual references. Do not add transport, Rust/UniFFI, real pairing, APNs, multiple hosts or distribution work to this mock slice.

## State contracts

`@MainActor @Observable AppStore` owns projects, sessions, messages and approvals. Views mutate shared state through the store. `ApprovalItem.sessionId` associates decisions with a session; `sessions(for:)` and `pendingCount(projectId:)` derive row counts. Do not store another independent counter on `ProjectItem`.

`resolve(_:approved:)` ignores missing/already resolved IDs, records the decision, updates session state and emits a toast. A rejection keeps the session cancelled even if a later request is approved. Completed decisions remain inspectable in approval history. Decision toasts remain visible for three seconds and expose the `toast` accessibility identifier; test that element rather than mistaking a history badge for transient feedback. `clearHistory()` clears sessions, messages and associated approvals together.

## Presentation

Use native NavigationStack, semantic grouped backgrounds, safeAreaInset for the chat composer and approval actions, and scroll-to-bottom after new messages or keyboard focus. The approval preview must match the operation: a diff for writing, the actual command/work directory for execution. A mock execution must never run a shell command.

Use an item-bound image sheet so its data and presentation change together:

```swift
@State private var expandedImage: ImagePreview?
// On tap: expandedImage = ImagePreview(image: image)
.sheet(item: $expandedImage) { preview in
    Image(uiImage: preview.image).resizable().scaledToFit()
}
```

Avoid a separate Boolean plus conditionally captured image state: the first sheet presentation can render empty. Keep mock attachments generated locally; image permission and network access are unnecessary for 0.1.

The UserDefaults `appearance` key accepts `自动`, `浅色`, `深色`; apply it at RootView. Retention is a mock preference only. Notification toggles change local UI state and do not register APNs.

## Row hit areas and toast contrast

For a grouped row with `.buttonStyle(.plain)`, apply `.contentShape(Rectangle())` to the padded label. Otherwise a short title may leave the center of the apparent row untappable. Keep body text semantic instead of inheriting the list button tint.

For inverse toasts, use explicit `Color.primary` for the background and `Color(.systemBackground)` for the text. A hierarchical `.primary` background combined with `.foregroundStyle(.background)` can resolve to the same foreground/background and produce an accessibility-visible but visually invisible toast. Verify the screenshot as well as the `toast` element's existence and label.

## Verification

Build `AgentBridge` simulator Debug with signing disabled. Run the shared scheme's `AgentBridgeUITests/MockPathTests`: both themes must verify search/agent filters, new session/send/reply, keyboard hittability, attachment zoom, event details, approval decisions/history, paired Mac and preference controls. Tap the right-side native switch control in automation; its row text does not toggle it. LabeledContent may expose its label/value as one accessibility element.

Export original XCTest screenshots via `work/codex-runs/export-screenshots.py`. Require at least home/project/chat-with-reply/approval/settings in both themes; retain full build and test logs and inspect the PNGs visually before marking acceptance-ready.
