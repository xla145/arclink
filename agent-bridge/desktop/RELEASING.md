# ArcLink macOS releases and online updates

`.github/workflows/arclink-release.yml` builds Apple Silicon and Intel DMGs for
macOS 13+, plus signed Tauri updater archives. Both builds must succeed before a
release becomes visible. pnpm/Cargo lockfiles, frontend tests, TypeScript and the
production build are enforced. Apple Developer ID signing and notarization are
disabled; no Apple account or certificates are required. macOS Gatekeeper may
block downloaded apps without Developer ID signing/notarization. The complete
app bundle is ad-hoc signed (`bundle.macOS.signingIdentity: "-"`) before Tauri
creates the DMG and updater archive. CI rejects bundles that fail
`codesign --verify --deep --strict`; the linker's executable-only signature is
not sufficient. Do not change app contents or re-sign after packaging.

## First launch on macOS

1. Drag ArcLink from the DMG into Applications, then open it once.
2. If macOS blocks it because the developer cannot be verified, open **System
   Settings → Privacy & Security**, scroll to Security and choose **Open Anyway**
   for ArcLink.
3. Authenticate with the Mac login password or Touch ID when macOS asks, then
   confirm **Open**. ArcLink must never collect this password itself.

The Chinese system labels are **系统设置 → 隐私与安全性 → 仍要打开**.
The option is normally available for about an hour after the blocked launch.
Ad-hoc signing provides bundle integrity, not verified developer identity or
Apple notarization; availability of this override depends on macOS and device
management policy. If macOS still reports that the app is damaged, use a newly
rebuilt installer and investigate signature integrity rather than promising
that a password will fix it. Existing installers are not repaired by this
configuration change. Developer ID signing and notarization are the supported
path for reliable public distribution. Do not ask users to disable Gatekeeper.

## One-time updater signing setup

Update signatures are independent of Apple code signing. The public key is
committed in `src-tauri/tauri.conf.json`; `requireSignedVersion` also binds the
archive's signature to its version. Never disable verification to work around a
configuration problem.

The initial keypair and password are stored locally in the Git-ignored directory
`agent-bridge/.release-keys/` (directory 0700, private files 0600). Back these up in
a password manager or secure offline storage. Do not commit, publish, log or
upload the private key/password as a build artifact. Do not regenerate them for
each release: existing clients trust this public key.

Set these repository **Actions secrets**, passing file contents via stdin:

```sh
gh secret set TAURI_SIGNING_PRIVATE_KEY --repo xla145/arclink < agent-bridge/.release-keys/updater.key
gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD --repo xla145/arclink < agent-bridge/.release-keys/updater.password
```

For a new installation without this keypair, generate a password-protected key
using `corepack pnpm tauri signer generate --write-keys ../.release-keys/updater.key`
from `desktop/`, then configure the matching public key and Secrets before the
first release. Key rotation after release needs an explicit migration; simply
replacing the key breaks updates for existing installations.

## Try a build

Push changes to the workflow or desktop/build sources to any branch to run an
artifact-only build. Once the workflow exists on the default branch, select
**Actions → ArcLink macOS release → Run workflow** and choose the desired branch.
Branch pushes and manual branch runs upload both architectures as Actions
artifacts for 14 days; they do not publish releases. Signing Secrets are required
for these builds too. Tag pushes publish releases regardless of changed paths.
Install each build on a matching Mac before distribution.

## Publish a version

Keep these versions equal before committing:

- `agent-bridge/desktop/package.json`: `version`
- `agent-bridge/desktop/src-tauri/tauri.conf.json`: `version`
- `agent-bridge/Cargo.toml`: `workspace.package.version`

Refresh and commit `agent-bridge/Cargo.lock` when changing the workspace version.
After committing and pushing the intended release commit:

```sh
git tag arclink-v0.1.0
git push origin arclink-v0.1.0
```

Only stable `arclink-vMAJOR.MINOR.PATCH` tags matching the app version are accepted.
CI rejects an already-published version or an older version than an existing
stable release. It creates a draft, uploads both DMGs, `.app.tar.gz` archives,
`.sig` files, `latest.json` and `SHA256SUMS.txt`, then publishes it as latest.
Failed uploads leave a draft that can be retried. Repository-wide release
concurrency prevents two pipelines from publishing simultaneously.

GitHub's built-in `GITHUB_TOKEN` publishes releases; no personal access token is
needed. The repository must be public for unauthenticated downloads. Do not embed
a GitHub credential in the app or website.

## Website and client endpoints

- Apple Silicon: https://github.com/xla145/arclink/releases/latest/download/ArcLink-macos-arm64.dmg
- Intel: https://github.com/xla145/arclink/releases/latest/download/ArcLink-macos-x64.dmg
- Checksums: https://github.com/xla145/arclink/releases/latest/download/SHA256SUMS.txt
- Client manifest: https://github.com/xla145/arclink/releases/latest/download/latest.json
- Release details: https://github.com/xla145/arclink/releases/latest

These links are available after the first successful release. Reserve this
repository's latest release for ArcLink. The manifest uses immutable versioned
archive URLs and platform keys `darwin-aarch64` / `darwin-x86_64`. DMGs are for
manual installation, not updater input.

## Client behavior and validation

The native client checks on startup; Settings provides manual checks, release
notes and progress. Download and signature/version verification happen before
host shutdown. After download the user explicitly confirms installation/restart
and Agent interruption. Failed downloads leave the host running; failed installs
after shutdown report that service is stopped and allow retry or quit/reopen.
Existing identifiers, pairings and application data are preserved.

A missing first release, offline network or invalid signature is an update error,
not “already latest.” Browsers cannot run native updates. Existing installations
without the updater need one manual installation of an updater-enabled build.

Before claiming a working public update, publish two increasing versions, install
the first outside its DMG (for example `/Applications`), upgrade to the second,
and verify the displayed version, pairing/settings preservation and Agent cleanup
on both CPU architectures. Local unit/build tests do not replace this smoke test.
To withdraw a faulty release, remove it from distribution and publish a corrected
higher version; clients never silently downgrade.
