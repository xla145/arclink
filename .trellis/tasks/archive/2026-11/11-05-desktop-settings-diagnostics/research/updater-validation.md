# Updater validation — 2026-11-05 (Asia/Shanghai)

## Result

The deployed online update path is currently unavailable. The configured production manifest endpoint returns HTTP 404, so the current client cannot discover a release, download it or reach verified-ready state through production configuration. Unit tests passing does not establish production availability.

The installed `/Applications/ArcLink.app` is version **0.1.1** (Info.plist). Its executable contains both the endpoint and public key in the current `agent-bridge/desktop/src-tauri/tauri.conf.json`. The installed running application was not stopped, replaced, or installed over. No remote release was modified or published.

## Production HTTP evidence

- Configured endpoint: https://github.com/xla145/arclink/releases/latest/download/latest.json
- Redirect target: https://github.com/xla145/arclink/releases/download/v1.0.0/latest.json
- Final status: **404 Not Found**, response body `Not Found`.
- Explicit expected version manifest: https://github.com/xla145/arclink/releases/download/arclink-v0.1.1/latest.json — **404**.
- arm64 archive: https://github.com/xla145/arclink/releases/download/arclink-v0.1.1/ArcLink-macos-arm64.app.tar.gz — **404**.
- x64 archive: https://github.com/xla145/arclink/releases/download/arclink-v0.1.1/ArcLink-macos-x64.app.tar.gz — **404**.

Requests used `curl -L --max-time 30` for the manifest and `curl -I -L --max-time 20` for archive availability. Headers/body are in `/tmp/arclink-updater-manifest.headers` and `/tmp/arclink-updater-manifest.json`.

GitHub's public API and authenticated `gh release list` agree: the only release is `v1.0.0` / `第一版本`, published 2026-11-02T13:00:41Z, with **zero assets**. There is no alternative published architecture manifest to fall back to.

## Release workflow cause

Run: https://github.com/xla145/arclink/actions/runs/41443649793

This successful run was a **branch push** on `feature/agent-bridge-desktop` at commit `754e55a66f6099d0129467cdc7be48fa531005a6`. Both architecture builds succeeded, but **Publish complete release was skipped**. `.github/workflows/arclink-release.yml` restricts publication to tags starting `arclink-v`; branch pushes produce Actions artifacts only.

Authenticated Actions metadata lists:

- `arclink-macos-arm64`, artifact ID 13141925824, 19,656,633 bytes.
- `arclink-macos-x64`, artifact ID 13141557409, 20,384,445 bytes.
- Both unexpired, expiring 2026-11-16 UTC.

CI artifact metadata/access is not equivalent to public release availability. Archive payload download stalled during this investigation; a bounded retry was attempted. CI payload signatures are **unverified**, and no claim is made that they match or fail the app key.

## Automated checks

- `corepack pnpm test --run src/update.test.tsx` from `agent-bridge/desktop`: **5/5 passed**. Covers startup check without automatic install, deliberate download, installation consent/cancellation, error versus current state, stale polling, stopped-host recovery/no automatic retry.
- `cargo test -p agent-bridge-desktop updater::tests --lib` from `agent-bridge`: **2/2 passed**. Covers operation deduplication and serialized revision/error state. Existing vendored netwatch deprecation warnings remain.
- `python3 agent-bridge/scripts/test-release-assets.py`: **8/8 passed**. Covers release manifest/artifact assembly boundaries. This is not cryptographic verification of published artifacts.

Native code in `desktop/src-tauri/src/updater.rs` uses a 20s check timeout; fetch/parse failure maps to `update_check_failed`, rather than reporting current. Download calls the plugin's authenticated `Update::download`; install verifies again before `stop_for_update`, and requires consent. These install paths were inspected, **not executed**.

## Local pre-existing archive signature check

A separate old local release archive exists. It must not be substituted for production or CI evidence:

- `/Users/mac/mac-dev/agent-bridge/target/release/bundle/macos/ArcLink.app.tar.gz`
- 10,227,361 bytes, modified 2026-11-05T01:35:29Z.
- SHA256 `6feaeb93aaf2a7c2c5dedc6c92932295354be6836dada0d8951824ab4566902d`.
- Adjacent `.sig`: 424 bytes, modified 2026-11-04T08:41:07Z.
- Signature SHA256 `6a6ec9f55fbf977a8a5f402215ec7cdbf4bf12fe69d05fa88f4eb58a2937e488`.

An isolated `/tmp/arclink-updater-verify` Rust harness linked the same compiled `minisign_verify` library used by updater 2.14.1. It decoded the configured public key and adjacent public signature and called `PublicKey::verify(bytes, signature, true)`, matching the plugin's cryptographic call. Result: **InvalidSignature**.

Independent Python cryptography checks established:

- Public key ID matches signature key ID.
- Global signature authenticating the trusted comment: **passes**.
- Trusted comment includes `version:0.1.1`.
- BLAKE2b-prehashed archive payload signature: **fails**.

Thus these particular local archive bytes do not match their existing signature. The archive is newer than its signature. This finding does not establish any failure in CI output. Rebuild archive and signature together; do not reuse this local pair for an update.

Only public key/signature data were inspected; no private signing keys were read or printed.

## Required recovery and remaining limits

1. Choose a next application version greater than installed 0.1.1; align desktop package.json, tauri.conf.json, and Cargo workspace version.
2. Build/sign both architecture archives together using the existing release workflow and matching `arclink-vX.Y.Z` tag. Verify archive bytes and signed-version metadata with the app's public key; do not reuse stale local `.sig` files.
3. Publish the complete release with `latest.json`, arm64/x64 signed archives and installer assets; point GitHub latest to that complete release. No product endpoint change is needed solely to repair the currently empty release.
4. Recheck public HTTP availability, actual newer-version discovery, download and signature-ready state.
5. Test final installation/restart against an isolated older app copy, with disposable state and no user Agent processes. Both architectures need native installation smoke evidence before claiming full upgrade coverage.

No installation/restart test was performed against the user's running application. Current evidence establishes application state-machine tests and a concrete production distribution blocker; it does not establish a successful end-to-end installed upgrade.
