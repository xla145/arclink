# Desktop settings and diagnostics design

## Boundaries and layout

One integrated desktop task: diagnostics and keep-awake share the settings entry, compact-panel navigation and native lifecycle. Keep a single task rather than splitting shared integration into separate deliverables.

Preserve Tauri 2/React, the 320×480 menu-bar envelope and existing design tokens. Settings use compact titled sections: General (host name, autostart, keep awake), Connection (connection strategy and endpoint), Diagnostics (logs), Application (existing updater and exit). Keep the updater integrated without duplicating its state. Use scrollable content, accessible text/switch controls and visible focus in both appearances.

The footer's log action and settings' Diagnostics entry open the same LogsPanel. Back returns to the originating view; Escape leaves logs before hiding the main panel. Logs show recent text in a bounded monospace area, update time and truncation notice, with refresh, copy, export and open-folder actions. Preserve text on refresh failure. No automatic polling in the first version.

## Native command contracts

All frontend calls remain in `src/bridge.ts`, with matching desktop-only DTOs in `src/types.ts`. Do not expand the shared agentd settings or mobile protocol for a desktop OS preference.

- `get_keep_awake` returns `{ enabled, active, supported, error }`: saved intent, owned assertion state, platform support, and nullable structured error.
- `set_keep_awake(enabled)` serializes native changes and preference persistence, returns authoritative status, and rejects during shutdown/update. UI re-queries status after a failure/uncertain result; no automatic mutation replay.
- `get_recent_logs` returns `{ text, truncated }` from fixed app-scoped log files, with a 256 KiB total read/result budget. Use tail reads, bounded candidate enumeration and explicit file eligibility; do not follow symlinks or accept arbitrary input paths. Handle rotation, UTF-8 boundaries, empty directories and IO errors.
- `export_recent_logs` uses the same bounded diagnostic content and a native save dialog. Cancellation is a neutral outcome; only a completed write reports success. No general filesystem capability exposed to React.
- Existing `open_logs` retains its fixed-directory behavior. Copy uses clipboard support with explicit success/failure feedback, preserving the panel while any native save dialog is active if needed.

## Keep-awake ownership and persistence

Target the existing macOS desktop distribution. Use an owned IOKit `PreventUserIdleSystemSleep` assertion with RAII release; do not request a display assertion or synthesize activity. Other platforms report unsupported explicitly unless a verified native equivalent is implemented; never simulate success.

Store a versioned boolean preference atomically in the Tauri app-data directory, default false for a missing file. Corrupt/unreadable settings surface a recoverable error, not a silently overwritten file. Keep preference/OS ownership independent from daemon network initialization, so a network failure does not disable an already active assertion.

Serialize startup restore, toggles and stop/update cleanup through defined ownership locks. Acquisition and persistence are transactional: on persistence failure release a newly acquired assertion; on disable failure retain truthful active status and saved intent with error. Repeated enable must not acquire duplicates. Setting state is observable from the native owner, never just a React boolean.

Restore saved true once at startup. Hiding/closing the panel leaves the assertion active. Release during confirmed exit and update stop, including fallback drop/process termination. Retain the preference across exit for the next launch. Explicit sleep, lid close and hardware restrictions remain OS behavior.

## Compatibility and rollback

Keep identity, relay credentials, database, pairing, log paths and rotation unchanged. Existing log filter admits desktop targets only: this feature reads those logs rather than broadening collection to raw Agent output. Remove only newly introduced commands/modules/UI to roll back; the optional preference file can remain without affecting old builds.

## Risks and evidence limits

Native save dialogs may blur the accessory panel; coordinate native dialog lifetime with hide behavior. Log rotation can race reads; tolerate files disappearing and preserve meaningful IO failures. Browser screenshots establish layout only. Native assertions require macOS verification with `pmset -g assertions`; no promise of overriding forced sleep.
