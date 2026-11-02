# ArcLink updater and release contract

## 1. Scope / Trigger

Applies to native desktop updates, React update presentation and GitHub release
assembly. Repository: `xla145/arclink` (public). Apple Developer ID signing and
notarization are intentionally disabled; Tauri update signatures remain required.

## 2. Signatures

Native commands exposed through `bridge.ts`:

- `get_update_status() -> UpdateStatus`
- `check_for_update(startup: bool) -> Result<UpdateStatus>`
- `download_update(version: String) -> Result<UpdateStatus>`
- `install_update(version: String, confirmed: bool) -> Result<UpdateStatus>`

These enqueue work and return immediately. Long-running operations must not hold
an IPC request beyond the bridge timeout. The frontend polls authoritative state
and ignores older string-encoded revisions.

## 3. Contracts

`UpdateStatus` contains `revision`, `current_version`, `phase`, `version`, `notes`,
`downloaded`, `total`, `error` and `restart_required`. Phases: `idle`, `checking`,
`current`, `available`, `downloading`, `ready`, `installing`, `error`.

Rust owns the selected Update and verified archive bytes. WebView supplies only
version and consent, never a URL, signature, key or filesystem path. HTTPS is
required. `requireSignedVersion: true` binds the manifest version to the signed
archive. Native startup deduplicates the automatic check. In-flight operations
reject duplicates; failed checks never claim the client is current.

Download and signature verification precede shutdown. Final installation consent
warns about interrupting all Agents, even when the observed count is zero, because
a remote start can race the count. `stop_for_update` shares the runtime lifecycle
gate/cleanup with Quit and retains shutdown ownership throughout installation.
After install success, permit exit and restart. After install failure retain
verified bytes, allow explicit retry/exit and show that the host is stopped.

CI requires `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
Secrets. Public key is committed; private key/password stay in ignored
`agent-bridge/.release-keys/` with restrictive permissions and a secure backup.
Never print or commit them. Signatures are generated with the app version by the
locked Tauri CLI. Update keys are unrelated to Apple certificates.

The workflow builds `app,dmg` for both architectures. Stable `arclink-vX.Y.Z` tags
must match package.json, tauri.conf.json and Cargo workspace versions. Branch
pushes/manual runs upload artifacts only. Tag builds publish a draft only after
both architectures succeed and all assets upload. `latest.json` uses versioned
archive URLs and platform keys `darwin-aarch64`, `darwin-x86_64`. Keep stable DMG
filenames `ArcLink-macos-arm64.dmg` / `ArcLink-macos-x64.dmg` for the website.

## 4. Validation & Error Matrix

| Condition                              | Required result                              |
| -------------------------------------- | -------------------------------------------- |
| Offline or manifest unavailable        | Visible retryable error, host unchanged      |
| Same/older version                     | No upgrade offered                           |
| Signature/version mismatch             | Refuse archive; do not stop host or install  |
| Concurrent check/download/install      | `update_busy`                                |
| Candidate version changed              | `update_changed`                             |
| Missing install consent                | `confirmation_required`                      |
| Install fails after cleanup            | Error with `restart_required`, retry or exit |
| Missing architecture or mixed versions | No complete manifest/public release          |
| Missing signing Secrets                | Early build failure                          |
| Published same/newer stable version    | Refuse publication; never overwrite          |

## 5. Good / Base / Bad Cases

Good: download, verify, confirm interruption, stop host, install, restart.
Base: first release missing produces a check error; manual DMG install bootstraps
clients which predate the updater.
Bad: disable signature verification or embed a GitHub token to read private assets.

## 6. Tests Required

Run frontend tests/build, Rust updater/lifecycle checks, and
`python3 agent-bridge/scripts/test-release-assets.py`. Cover stale polling,
confirmation cancellation, download retry, post-cleanup failure recovery, duplicate
operations, missing/empty signatures and mismatched architecture versions. Validate
workflow syntax with actionlint. Native two-version signed installation on both
architectures is a separate smoke test; do not equate build/unit checks with it.

## 7. Wrong vs Correct

Wrong: call generic process relaunch before shutting down owned Agent processes.
Correct: verify bytes, acquire shared lifecycle shutdown ownership, finish cleanup,
install while owning shutdown, then permit exit and restart.
