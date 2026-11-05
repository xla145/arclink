# ArcLink R2 distribution contract

## 1. Scope / Trigger

Applies to the signed macOS release mirror, desktop updater endpoint selection,
and generated website downloads. R2 Standard distributes exact signed artifacts
using `https://download.classktv.com`; GitHub remains an independent release
origin. Do not introduce a Worker or a paid CDN for this workflow.

## 2. Signatures

- Publisher: `agent-bridge/scripts/r2-release.py`; consult its `--help` for the
  current CLI. Input is the eight attachments of an already published stable
  GitHub Release, not newly built or re-signed local artifacts.
- Website generator: `agent-bridge/website/prepare.py`; template/configuration
  own all download links. Release-manifest input synchronizes version and URLs.
- Desktop config: `agent-bridge/desktop/src-tauri/tauri.conf.json` endpoint list
  selects R2 first, then GitHub. Preserve `requireSignedVersion: true` and key.

## 3. Contracts

### Environment and ownership

CI Secrets: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`. Repository variables:
`R2_ACCOUNT_ID`, `R2_BUCKET=oss`,
`R2_PUBLIC_BASE_URL=https://download.classktv.com`.
S3 credentials may read/write objects only in the designated bucket. S3 API URLs
are authenticated upload interfaces, not public updater endpoints. Never embed
credentials in clients, URLs, generated website assets, or command output.

Only ArcLink `releases/arclink-vX.Y.Z/` and its latest pointer are managed;
preserve unrelated `oss` objects. No bulk deletion or automatic retention cleanup.
Existing Cloudflare DNS zone and bound custom domain are prerequisites; do not
change nameservers or unrelated records while configuring downloads.

### Artifacts and publication

Each version directory contains eight public files: two DMGs, two archives,
their two `.sig` files, `latest.json`, and `SHA256SUMS.txt`. DMGs retain stable
`ArcLink-macos-{arm64,x64}.dmg` filenames. The two platform keys remain
`darwin-aarch64` and `darwin-x86_64`.

GitHub and R2 DMG/archive/signature bytes must match exactly. R2 manifest URLs
use `https://download.classktv.com/releases/arclink-vX.Y.Z/<archive>`;
GitHub manifest URLs continue to use GitHub. Preserve version, publication date,
Chinese notes and signature metadata. Generate separate checksums for the actual
manifest bytes on each source. Checksums are integrity comparisons, not a
replacement for cryptographic signature verification.

Mirror only published stable main-ancestry tags. Retry identical existing version
objects idempotently; refuse any differing existing bytes. Upload and verify the
complete version directory via public HTTPS before updating root `latest.json`.
Earlier upload/validation failures must not alter latest. Serial CI publication
and version guards prevent an older recovery workflow from moving latest back.
Missing configuration is a visible mirror failure, not an implicit success.

Immutable binaries use long cache lifetimes; latest metadata uses short TTL or
revalidation, with matching Cloudflare rules. Avoid stale 404 caching during
promotion. Content types and HTTP HEAD/GET/Range must work through the custom
domain. R2 free tier is account-shared and not a spend cap; monitoring cannot be
described as a hard automatic billing limit.

### Client compatibility

Previously released clients retain their compiled GitHub endpoint. A regular
update or R2 DMG install migrates them to the new endpoint list; do not edit
historical tags or GitHub manifests to suggest otherwise.

The locked Tauri updater controls metadata fallback. Network/HTTP failures can
advance to the next endpoint; 204 and an accepted manifest end selection. Test
and document malformed JSON behavior rather than assuming fallback on every
error. Metadata fallback does not implement archive failover or cross-source
resume. Failed signature/version validation never stops the user's host.

## 4. Validation & Error Matrix

| Condition | Required result |
| --- | --- |
| Missing Secrets/variables | Visible failure; no mirror/promotion claim |
| Missing architecture or invalid source checksum | No latest promotion |
| Existing version object differs | Refuse overwrite |
| Public mirror differs or is inaccessible | Fail verification; preserve latest |
| Stale candidate version | Refuse latest downgrade |
| Identical incomplete mirror retry | Reuse verified bytes; finish missing objects |
| Different source manifest URLs | Verify each source's own manifest checksum |
| R2 download/signature failure | Retryable error; no simulated install success |

## 5. Good / Base / Bad Cases

Good: GitHub publication succeeds, mirror validates both architectures, then
latest advances and native signed download works. Base: credentials are absent;
local tests pass but the live mirror remains explicitly pending. Bad: publishing
a latest pointer before all version objects are publicly verifiable, or treating
a root 404 in an empty bucket as proof that custom domain activation failed.

## 6. Tests Required

Cover deterministic manifest transformation preserving notes/date/signatures;
independent checksum validation; missing assets; same-version immutable conflicts;
idempotent retries; failed public validation; stale latest rejection. Assert that
failed pre-promotion work leaves the prior latest bytes unchanged.

Test actual updater endpoint behavior using isolated fixtures and unchanged
production TLS settings. Run website generation tests, native updater/lifecycle
tests, frontend test/build, release Python tests and actionlint. Live validation
must compare origin/mirror digests, cryptographic signatures and signed version,
strict codesign/architecture, and installation into a guarded temporary app.
Record throughput/TTFB for identical source bytes and actual network location;
do not extrapolate one host's measurements to all mainland users.

## 7. Wrong vs Correct

Wrong: point the client at the S3 API endpoint, copy a GitHub checksum onto the
modified R2 manifest, or re-sign a mirrored archive.

Correct: use the bound HTTPS custom domain, generate R2's own manifest checksum,
preserve the six signed/binary attachment bytes, verify before promotion.
