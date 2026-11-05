# Verification — R2 distribution

Date: 2026-11-05. Branch: codex/arclink-r2-distribution.

## Implemented and independently checked

- Deterministic mirror of the original six GitHub binary/signature files, separate R2 manifest/checksum, immutable version uploads, complete public-GET validation before conditional latest promotion, stale/concurrent publisher guards, and mirror-only workflow recovery.
- R2 primary/GitHub secondary metadata endpoints with actual tauri-plugin-updater fixture coverage. No production insecure-transport configuration; no payload failover claim.
- Dual-architecture static website, safe versioned R2 links, local backwards compatibility, and manifest-derived persistent version configuration through --write-config.
- Updated updater/website/R2 specs and global arclink-release skill plus its read-only audit script.

## Quality results

Independent trellis-check reported no code findings and made no modifications.

- 16 release-asset Python tests.
- 14 R2 uploader Python tests (fake S3/public verifier fixtures).
- 9 website Python tests.
- 16 Rust native library tests including 5 real updater endpoint fixture tests.
- 32 frontend tests.
- 12 global skill audit tests.
- Total: 99 passing tests.
- TypeScript noEmit and Vite production build passed.
- actionlint 1.7.10, changed-file Prettier/Rust formatting, Python compilation and git diff --check passed.
- Targeted Clippy passed with pre-existing single_match exemption and --no-deps; third-party netwatch deprecation warnings are baseline.
- Global skill quick_validate passed.
- Browser checks at 390/1440 px confirmed architecture buttons remain inside the download container. Screenshots: /tmp/arclink-r2-download-mobile.png and /tmp/arclink-r2-download-desktop.png. The unchanged hero phone decoration can extend beyond the 375 px client area when a desktop scrollbar consumes part of a 390 px viewport; this existing decorative layout was not expanded into this distribution task.
- Temporary dependency symlink, browser session and local server were cleaned by the owning implementer.

## Live mirror and public assets

- R2 Secrets were configured successfully. No secret values were read or logged. Mirror-only workflow [41987638772](https://github.com/xla145/arclink/actions/runs/41987638772), attempt 3, succeeded on 2026-11-05 at 15:55 Asia/Shanghai. Earlier attempts stopped before upload because repository Secrets were missing.
- Implementation e3a8639 was merged to remote main via dffbdf901d9541aaf4928d656e03f52be77b1b23. Original arclink-v0.1.3 tag, GitHub Release metadata and all original binary/signature assets were not changed. Redundant main artifact build 41987509593 was cancelled.
- Eight files are publicly available under https://download.classktv.com/releases/arclink-v0.1.3/. All six binary/signature SHA256 digests equal the original GitHub asset digests. The R2 manifest has its own valid checksum, exact release notes, platform URLs and original signatures.
- Root latest.json equals the version-directory manifest. Root SHA256: ffa4011702fc52ab4a3e3f0a2979b69034bc3ec5bd223cc2ed5f173970dda6ee.
- HEAD/GET passed; binary Range requests returned 206 and identical first 1 MiB bytes. Root latest is no-store/max-age=0; versioned objects have public/max-age=31536000/immutable and correct Content-Type/length.
- Local transport intermittently failed TLS handshakes; bounded retries and final integrity checks were used. Do not report universal network reliability from successful checks.
- Public artifact audit: /tmp/arclink-r2-public-validation/audit-report.json. HTTP and speed reports are adjacent files. Initial partial bootstrap GitHub files are not verification inputs.

## Native R2 validation

Independent checker forced a single R2 metadata endpoint and rejected archive URLs outside the versioned R2 hostname, preventing accidental GitHub fallback success.

- Both platforms actual native check() discovered mock 0.1.1 -> 0.1.3.
- arm64 actual native Update::download fetched 10,529,572 R2 bytes; x64 downloaded 11,109,044 R2 bytes and actual native verify passed.
- Both archives passed cryptographic signature, trusted-comment signed-version, embedded-version, expected Mach-O architecture and strict codesign verification. Tampered bytes and wrong announced version were rejected.
- Actual Update::install succeeded only in guarded /private/tmp/arclink-update-smoke-r2-j8q8nqlh/ArcLink.app. Complete before/after snapshots of /Applications/ArcLink.app match. No user app/Agents were stopped, no Keychain access, launch or restart occurred.
- Boundary: real source/copy were already 0.1.3, so installation proves temporary same-version replacement; old-version discovery uses mock package version 0.1.1. Actual old installed app upgrade, x64 runtime launch and normal lifecycle/restart were not exercised.
- Native report: /tmp/arclink-r2-live-validation/validation-report.md, with raw logs and snapshots in that directory.

## Website deployment

- Generated using the verified R2 manifest with --write-config; local website tests (9) passed again after generation.
- Published only index.html/styles.css/main.js/assets, atomically switched current to /var/www/arclink/releases/20261105-160300-r2 after nginx -t succeeded. Prior /var/www/arclink/releases/20261104-v0.1.1 remains available for rollback. No other vhost or certificate configuration changed.
- https://arclink.classktv.com returns the exact generated HTML, SHA256 2f2684687aa9da59fe809641aed905ff72b1dba1427574543fe763fe4c571b72, displays 0.1.3 and both verified architecture-specific R2 URLs. Old 0.1.1 links are gone.
- Deployment evidence: /tmp/arclink-r2-website-deploy/deployment-report.json.

## Observed performance

Single local connection, first 1 MiB of the identical arm64 archive, not a regional guarantee:

| Source/sample | Result | TTFB | Total | Throughput |
| --- | --- | --- | --- | --- |
| GitHub 1 | 206, complete | 2.397 s | 13.686 s | 76,615 B/s |
| R2 1 | 206, complete | 1.005 s | 3.559 s | 294,623 B/s |
| GitHub 2 | Timed out at 25 s | Not a completed sample | Timeout | Not comparable |
| R2 2 | 206, complete | 3.360 s | 5.440 s | 192,761 B/s |

The first paired R2 sample was about 3.8 times the completed GitHub throughput; the sample count and network location do not justify a general acceleration claim.

## Remaining deployment decisions

- Public headers still show CF-Cache-Status DYNAMIC. R2 delivery is live, but Cloudflare edge caching has not been proved enabled. User has been asked to add a free Cache Rule matching only hostname download.classktv.com and path prefix /releases/arclink-v, Eligible for cache, respecting origin Cache-Control. Root /latest.json must remain outside the cache rule. Await configuration or explicit deferral; do not claim edge HIT/MISS until tested.
- Existing 0.1.3 distributed apps retain their original GitHub endpoint. Source code on main includes R2 primary and GitHub fallback; it takes a future client release to deploy that endpoint to users. No new binary/tag was published in this mirror-only validation.
- Free tier assumptions and usage reminder instructions are documented; no dashboard billing controls were changed using object-only credentials.

Task remains in_progress pending edge-cache verification or the user's explicit decision to defer that optional dashboard configuration.
