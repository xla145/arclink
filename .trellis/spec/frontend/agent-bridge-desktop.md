# Agent Bridge Tauri desktop contract

## 1. Scope / Trigger

Applies to `agent-bridge/desktop`. Replaces the historical Swift menu-bar
implementation assumptions. Tauri 2 embeds `agentd`; React owns presentation.

## 2. Signatures

- Application ID: `dev.agent-bridge.desktop`; binary: `agent-bridge-desktop`.
- `src/bridge.ts` owns all command invocations and event subscriptions.
- Commands: `get_snapshot`, `refresh_agents`, `open_pairing`, `start_pairing`,
  `cancel_pairing`, `approve_pairing`, `reject_pairing`, `close_pairing`,
  `revoke_device`, `update_settings`, `get_autostart`, `set_autostart`,
  `open_logs`, `retry_daemon`, `hide_panel`, `request_exit`.
- Events: `bridge-snapshot`, `bridge-changed`, `show-settings`, `confirm-exit`.
- DTO owner is `agentd::types`; serialized fields/enums are snake_case.
  Service revisions/process generations are strings; absent values remain null.

## 3. Contracts

### Display brand and icons

Use `ArcLink` (Chinese brand: `弧连`) for `productName`, window/tray labels,
and visible product text. Preserve `dev.agent-bridge.desktop`, the binary/crate
names, protocol identifiers, and existing app-scoped data/log paths so branding
does not reset pairing or storage. Design masters live in `output/arclink-brand/`;
production assets must live in the project: `src/assets/arclink-icon.svg` for
React and `src-tauri/icons/` for the PNG/ICNS/ICO files listed in
`src-tauri/tauri.conf.json`. Keep `tray.png` monochrome with transparent pixels
and `icon_as_template(true)` in `src-tauri/src/tray.rs`. Verify bundled icon
references and transparency as well as the visible name after an icon update.

Subscribe before requesting the initial snapshot. Preserve the service instance
and revision; old responses cannot replace newer data or resurrect an old
instance. Clean up listeners even if registration finishes after unmount.
Keep existing data visibly stale on refresh failure. Thirty-second frontend
timeouts do not cancel backend side effects or authorize automatic replay.

The production browser path reports native bridge unavailable. Explicit
`?preview=` fixtures are development-only, visibly labeled and excluded from
production assets. UI mutations in preview must not report simulated success.
Pair tokens are confined to the transient invitation view/cache, not global
snapshot state, logs, localStorage or serialized fixtures with live credentials.

Native setup establishes singleton ownership before starting the host. Startup
and shutdown use a lifecycle gate so delayed Keychain/network work cannot publish
a new host after exit begins. Main blur/Esc/close hides the panel. Pairing is a
view within main; its explicit cancel/back action cancels only the invitation
before returning to devices. Never create a second pairing window.
Native quit asks for confirmation,
then blocks new mutations and cleans the owned daemon/network before exit.

Use macOS accessory policy, template tray icon and work-area/scale-aware
positioning. Main panel is 320 by at most 480, including its inline pairing view.
Use a 14px rounded outer shell and transparent corner areas in the native window,
so the operating-system window does not fill CSS corners with an opaque square.
Follow the supplied HTML's compact sections and segmented navigation, local
fonts, light/dark colors, bounded scrolling and readable long-label behavior.

Autostart changes only through a deliberate user operation and is queried back
from the OS. Data/log locations use Tauri app-scoped path APIs. `open_logs` opens
the fixed log directory; WebView has no arbitrary shell or filesystem access.
Logs rotate and exclude identity, invitation payloads and raw Agent output.

## 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| No Tauri bridge | Explicit unavailable state, no mock fallback |
| Read timeout | Error/stale state; preserve last known data |
| Mutation timeout | `outcome_unknown`; refresh, never blindly replay |
| Expired/rejected/cancelled invitation | Invalidate QR/approval actions |
| Cancel command fails | Preserve invitation ownership for retry |
| Keychain/network start fails | Actionable error plus retry |
| Autostart operation fails | Show error and actual registered state |
| Old service/revision snapshot | Ignore it |

## 5. Good / Base / Bad Cases

Good: subscribe, fetch snapshot, apply newer revision, show the inline pairing view,
confirm actual requested grants, and render resulting authoritative devices.
Base: the browser can verify layout but cannot prove native tray behavior.
Bad: label an authorized offline device online, or append a fabricated version
prefix to an Agent's already formatted raw version string.

## 6. Tests Required

Run `corepack pnpm test --run` and `corepack pnpm build` **from desktop/**.
Corepack chooses packageManager from cwd before pnpm processes `--dir`.
Include shared Rust/TS DTO fixtures, listener cleanup, stale snapshot races,
mutation timeout/no replay, revoke confirmation and QR expiry/close behavior.
Inspect light/dark/empty/error states; separately validate the built macOS app,
single instance, tray positioning, hide/reopen and confirmed shutdown.

## 7. Wrong vs Correct

Wrong: a side effect completes after timeout and the UI retries with a fresh ID.
Correct: preserve unknown outcome and consult authoritative state first.

Wrong: reset invitation cache before cancellation has succeeded.
Correct: keep the cache until daemon cancellation succeeds, preserving retry.


## Private relay integration

See [the private relay contract](../backend/agent-bridge-private-relay.md) for additive APIs, QR metadata, Keychain namespaces, validation, shared endpoint leases and actual path reporting. Keep existing device identity, history and Agent lifecycle contracts.

## Development credential storage

macOS Debug and Release share the existing private relay Keychain item
`dev.agent-bridge.desktop.relay` / `private-relay-v1`, as explicitly requested by
the user. A missing development file must not silently disable the user's saved
private relay. Read/write the same item in both builds; never copy its key into
source, logs or a development JSON file. Keychain access failures remain errors.

Debug network identity remains separate in `development-identity-v1.key` (0600),
so changing relay storage does not change the existing debug endpoint or grants.
Non-macOS debug relay settings retain atomic 0600 development-file storage.
Release retains Keychain exclusively. Legacy macOS development relay files are
left untouched and no longer selected by the macOS runtime.
