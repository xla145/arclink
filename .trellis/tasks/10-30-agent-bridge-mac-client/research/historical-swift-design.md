# Mac menu-bar client design

## Architecture
Native SwiftUI MenuBarExtra (macOS13+) with AppKit integrations for clipboard/log folder and ServiceManagement login registration. Use a Swift Package executable and shell packaging script producing `Agent Bridge.app`; bundle the built agentd in Contents/Helpers. No web frontend or UniFFI is needed for this local administrative panel.

Swift owns presentation and process lifecycle; Rust owns authoritative status and mutations. Add `agentd DATABASE serve --control-stdio` as an opt-in, bounded JSONL local administration channel over the child pipes. The parent process owns both pipes; this channel is not a network API. Preserve existing CLI behavior. stdout contains only versioned responses/events; diagnostics go to stderr, saved in a bounded private log. Never print pairing token in normal logging for this mode.

## Local contract
Envelope `{id, method, params}` with correlated `{id, result}` or `{id, error:{code,message}}`. Methods: status (service instance/endpoint/uptime/active counts), agents, devices, pending_pairs, open_pair_window (endpoint,token,expires_at), approve_pair (id,explicit permissions), revoke_device (endpoint), shutdown. Rust returns device types from one serialization owner; Swift Codable models mirror documented payloads and reject unsupported contract versions. Read incrementally with message-size bounds; no one-read-one-message assumption. Periodic refresh is bounded and cannot overlap indefinitely. New requests on stopped generation are rejected, and late old-process responses cannot overwrite current UI state.

No arbitrary process execution, shell strings, filesystem paths or remote RPC passthrough in the administration contract. Native CLI probing uses a known executable path with bounded timeout; the app may offer explicit Codex executable selection if GUI PATH differs from shell, without sourcing user shell startup scripts.

## State and lifecycle
@MainActor view model: Stopped/Starting/Running/Stopping/Failed plus independent agent and pairing states. Child process generation, request IDs and one shutdown path prevent restart races. Pipe EOF/crash fails pending requests and updates state. On app launch start the owned service once; closing popover has no lifecycle effect. On application quit or deliberate stop, gracefully shut down the owned service, with a bounded fallback restricted to that child's PID. Surface active task interruption before stop/restart/quit. Database lock conflict is an error, not permission to seize an existing daemon.

Status language must distinguish local running from remote reachability. Show Relay only if a real endpoint API supplies verified information; otherwise say service running and remote reachability unverified. Paired means authorized, not connected. No invented timestamps or counts.

## Layout
Approximately380–420pt wide, adaptive capped height with scrolling content. Header app symbol/name + Mac name + status pill. Error card orange with clear action; compact device rows with pairing/revoke; Agent row with icon, version and compatibility badge. Footer login toggle, log button, version and overflow/quit. Use system typography, materials, native controls, SF Symbols and restrained accent color. Pair invitation and permission confirmation use small sheets/popovers; no full-screen navigation.

## Packaging/security
Minimum macOS13. arm64 local artifact is the initial supported build on this machine; do not claim universal binary without building both architectures. Set LSUIElement, bundle identifier and version; local ad-hoc signing for runnable package. Login registration requires a bundled app and OS permission; no automatic enablement in tests. Database uses Application Support/Agent Bridge; logs use Library/Logs/Agent Bridge. Persist only settings in UserDefaults; daemon secret remains Keychain-backed. Pair token remains transient UI memory and expires; copy is a deliberate user action. No app installation into /Applications or system/login changes during development smoke tests.

## Compatibility and rollback
Existing CLI/ABP transport and schemas remain unchanged. New stdio flag is optional and versioned. Reuse store pairing APIs rather than duplicating authorization. App shutdown behavior is explicit because a standalone persistent host is outside this small-client scope. Removing the app leaves user data and Keychain intact; disable login item deliberately before removing an enabled installation.
