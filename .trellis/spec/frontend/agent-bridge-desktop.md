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

## Desktop diagnostics and keep-awake

### 1. Scope / Trigger

Desktop-only settings, bounded local diagnostics and macOS idle-sleep prevention.
Keep these DTOs and preferences out of the shared agentd/mobile wire settings.

### 2. Signatures

- `get_keep_awake() -> { enabled: bool, active: bool, supported: bool, error: BridgeError | null }`
- `set_keep_awake(enabled: bool) -> Result<KeepAwakeStatus>`
- `get_recent_logs() -> Result<{ text: string, truncated: bool }>`
- `copy_recent_logs() -> Result<()>`
- `export_recent_logs() -> Result<bool>` (`false` means native save was cancelled)

### 3. Contracts

The native controller owns one IOKit `PreventUserIdleSystemSleep` assertion named
`ArcLink remote Agent availability`; never acquire a display-sleep assertion or
simulate user input. `enabled` is saved intent; `active` reports the owned native
assertion. Default off; restore from app-data `keep-awake-v1.json`, with payload
`{ "version": 1, "enabled": false }`. Use atomic persistence and serialize native
changes. A failed save must release a newly staged assertion. Preserve unreadable
or corrupt preference files and surface errors. Hide/close retains ownership;
confirmed exit and updater cleanup release it without clearing saved intent.
Unsupported platforms report `supported: false` instead of simulated success.

Settings show General first, then Connection, Diagnostics and Application;
the existing updater belongs to Application. Both footer and Diagnostics open
the same log view, whose Back/Escape return to its origin. Reconcile actual
native state after switch errors and when the panel regains focus; failed initial
reads end loading and offer an explicit read retry. Frontend timeouts never
authorize replay.

Only read app-scoped log files, never caller-provided paths or Agent transcripts.
Bound candidate enumeration and total recent text to 256 KiB, tail-read files,
handle rotation and UTF-8 boundaries, and skip symlinks. Copy/export re-read bounded
recent logs; export selects a destination through a native save dialog. Cancellation
is neutral. The save-dialog command is exempt from the usual 30-second bridge
timeout because user interaction can take longer. Preserve loaded log text on
refresh failure and label truncation.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Missing preference | Off, without creating a preference until explicit mutation |
| Corrupt/unsupported-version preference | Preserve file and report `keep_awake_error` |
| Native acquisition/persistence failure | Report error and actual owned state; no new leaked assertion |
| Shutdown/update starts | Reject new keep-awake mutations and release ownership |
| No logs | Empty state with refresh/folder guidance |
| Logs exceed budget | Recent bounded text and `truncated: true` |
| Refresh fails | Retain prior text and show actionable error |
| Export cancelled | `false`, never success text |
| Export/clipboard IO fails | Structured error, no success notice |

### 5. Good / Base / Bad Cases

Good: saved intent true restores one idle-system-sleep assertion after restart,
while normal screen sleep and locking remain available. Base: browser preview
labels example logs and rejects native mutations. Bad: using system-wide sleep
status as proof, since unrelated applications may already own sleep assertions.

### 6. Tests Required

Cover duplicate-enable ownership stability, saved-true restoration, stop/release,
failed-persistence rollback, corrupt-file preservation, bounded logs, symlink
exclusion, refresh failure, switch-state reconciliation and export cancellation.
On macOS verify the named assertion with `pmset -g assertions`, including release;
use temporary test preferences, not the user's actual file. Check 320×480 settings
and logs in both appearances, keyboard focus, long text and bounded scrolling.

### 7. Wrong vs Correct

Wrong: setting the switch locally and assuming the OS succeeded, or treating
save-dialog cancellation as an exported file.
Correct: use native status, preserve error feedback, and report export success
only after a completed write.
