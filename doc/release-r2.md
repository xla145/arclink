# ArcLink R2 distribution

R2 Standard mirrors published stable GitHub releases at
`https://download.classktv.com`. It uses the existing `oss` bucket; only
`releases/arclink-vX.Y.Z/` and root `latest.json` are managed. Other bucket
objects must remain untouched. No Worker is required.

## One-time configuration

The R2 custom domain must be bound to this bucket and show **Active**. Do not
point the client at the authenticated `r2.cloudflarestorage.com` S3 endpoint or
the development-only `r2.dev` URL.

Repository Actions variables:

| Variable | Value |
| --- | --- |
| `R2_ACCOUNT_ID` | The account ID shown with the bucket's S3 API endpoint |
| `R2_BUCKET` | `oss` |
| `R2_PUBLIC_BASE_URL` | `https://download.classktv.com` |

Create an R2 S3 API token with Object Read & Write access restricted to `oss`.
Store its two generated values as repository Actions Secrets:
`R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. These are S3 credentials, not a
Cloudflare zone-management token. Do not paste credentials into chat, committed
configuration or command arguments. Missing variables or Secrets visibly fail
the mirror job; GitHub publication may already have succeeded at that point.

R2 Standard's account-wide free allowance includes 10 GB-month storage,
1 million Class A operations and 10 million Class B operations/month; direct
egress is free. Other account usage and overages can incur charges. Configure
available billing/usage notifications in the account dashboard and inspect total
usage periodically. Notifications are not a hard spending cap. This workflow
never bulk-deletes old releases; retain versions consciously within the budget.

## Publication and recovery

Normal tag publication remains: tested feature branch -> main -> annotated
`arclink-vX.Y.Z` -> GitHub Release -> R2 mirror. Both architecture jobs must
succeed first. The mirror downloads the eight actual published attachments,
validates their checksums and signatures' metadata, and preserves the six
binary/signature files exactly. It changes only the staged manifest's archive
URLs, retaining version, date, notes and signature text, then generates a separate
R2 checksum file. It does not cryptographically verify updater signatures;
perform the native updater verification described in the release skill as well.

All eight files go under `releases/arclink-vX.Y.Z/`. Existing identical bytes are
reused; differing bytes are rejected. Full GET verification through the public
domain precedes a conditional update of root `latest.json`. A stale workflow
cannot downgrade the pointer. Upload or public-validation failures before that
point preserve the previous latest. A failure to verify the latest URL after
promotion requires inspection; it does not automatically roll back to an older
version.

Conditional `PutObject` operations use R2's supported `If-Match` and
`If-None-Match` preconditions; see the [R2 S3 compatibility reference](https://developers.cloudflare.com/r2/api/s3/api/).
The pinned S3 client disables optional automatic checksum negotiation using
`when_required`; content integrity is checked against the actual SHA256 bytes.

For a failed R2 job after GitHub succeeded, rerun only the failed job. To bootstrap
or recover an existing stable release without rebuilding or publishing again,
run **ArcLink macOS release** using a workflow ref that contains the R2 publisher
and set its `mirror_tag` input, for example:

```bash
gh workflow run arclink-release.yml --ref main -f mirror_tag=arclink-v0.1.3
```

This mode skips builds and the GitHub publish job. It requires the tag to be in
main history and the source Release to be public, stable and non-draft. Never
move an existing tag to recover a mirror. A same-version metadata difference is
also immutable here; diagnose it rather than overwriting a version directory.

For an authorized local operation, install the same `boto3==1.40.76` dependency,
provide the variables/Secrets through a secure environment, download the eight
published GitHub attachments into a clean directory, then run:

```bash
python3 agent-bridge/scripts/r2-release.py --directory /path/to/published-assets --version X.Y.Z --repository xla145/arclink
```

The local uploader validates source content but does not itself authenticate
Git tag ancestry; perform that provenance check before using it outside CI.

## Cache and download checks

Versioned files are uploaded with `Cache-Control: public, max-age=31536000,
immutable`; root `latest.json` uses `no-store, max-age=0`. If adding Cloudflare
Cache Rules, make only `/releases/arclink-v*/` eligible and preserve these origin
TTLs; explicitly bypass `/latest.json`. Do not use a domain-wide cache rule that
holds old latest metadata or negative 404 responses. Respect the free-plan file
size and rule limits.

Verify public HEAD, full GET and byte Range requests for both architectures,
their SHA256 values, content types, TLS, native signature/version binding and
the two distinct manifest checksums. Compare GitHub and R2 using identical bytes,
recording cold/warm TTFB and throughput for the actual test network. A successful
upload or a single regional probe does not establish mainland performance.

Old clients retain their compiled GitHub endpoint until one regular update or
a new DMG install. New clients use the R2 endpoint first and GitHub metadata as
the tested fallback. That does not imply automatic archive failover or download
resume if R2 becomes unavailable after manifest selection.
