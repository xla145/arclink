# Download distribution research

Date: 2026-11-05. Read-only investigation; no production changes.

## Repository and public endpoint findings

- Tauri updater endpoint is compiled as `https://github.com/xla145/arclink/releases/latest/download/latest.json` (`agent-bridge/desktop/src-tauri/tauri.conf.json:59`).
- Manifest assembly generates versioned GitHub archive URLs (`agent-bridge/scripts/release-assets.py:79`). Both metadata and payload downloads therefore depend on GitHub.
- Production website is `https://arclink.classktv.com`; isolated static Nginx deployment is documented in `.trellis/spec/frontend/arclink-website.md`. Configuration and live page still link `downloads/ArcLink_0.1.1_aarch64.dmg`. Latest published desktop release is 0.1.3. Website version synchronization is an adjacent issue to include in distribution planning.
- Website generator enforces same-site local downloads (`agent-bridge/website/prepare.py:17`); external URLs need deliberate generator/config changes rather than editing generated HTML alone.
- No reusable R2/Workers deployment was located in inspected release and website configuration. CodeGraph was attempted first but reported no usable index in this worktree; ordinary searches were then used.

## Measurements

Single local execution context, not a regional benchmark:

| Request | Result | First byte | Total | Speed |
| --- | --- | --- | --- | --- |
| Website HTML | 200 | 5.614 s | 5.615 s | Not measured |
| GitHub latest manifest | 200 | 1.421 s | 1.423 s | Not meaningful for small file |
| GitHub arm64 0.1.3 archive first 1 MiB | 206 | 0.944 s | 1.232 s | 850,773 B/s |
| Website arm64 0.1.1 DMG first 1 MiB | 206 | 1.056 s | 3.174 s | 330,351 B/s |

Samples use different artifacts and one request each; they cannot establish a definitive bottleneck or prove candidate acceleration. Future comparisons need identical bytes, repeat cold/warm samples, and target-user networks.

## Official Cloudflare evidence

Retrieved Markdown documentation successfully after HTML requests returned HTTP 403:

- [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/): production should use a custom domain; r2.dev is rate-limited and intended for development. Caching requires custom domain integration and appropriate cache rules; not all extensions cache by default. Domain zone must be present in the same Cloudflare account, so DNS setup must be checked before committing to a hostname.
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/): Standard has monthly free tiers including 10 GB-month storage; direct R2 egress is free, but storage/operation overages and other metered services may incur cost. Do not present this as unlimited free hosting.
- [Cloudflare China Network](https://developers.cloudflare.com/china-network/): mainland network is a separate Enterprise subscription and requires applicable ICP filing/license. Standard global Cloudflare is not equivalent to mainland CDN and cannot promise stable mainland acceleration.

## Candidate architecture and migration considerations

1. Prefer object storage plus custom CDN hostname over a live GitHub proxy. Copy exact CI-produced signed bytes into immutable versioned paths; avoid GitHub dependency on every cache miss and open proxy behavior.
2. Upload/verify both architectures and all signatures/checksums before promoting a latest manifest. Immutable objects can use long cache lifetimes; latest metadata needs short TTL/revalidation. Avoid stale negative caching and mixed-version promotion.
3. Keep GitHub Releases and tag provenance. A CDN manifest may use CDN archive URLs while retaining original signatures. If manifest content differs, publish a checksum for that exact manifest without falsely claiming equality to GitHub's manifest bytes.
4. Retain existing signature verification and signed-version binding. Mirror bytes require checksum, crypto signature, architecture and strict codesign verification.
5. Existing clients still query GitHub. A future binary can ship the stable custom endpoint; migration of old clients needs a reviewed bridge (such as metadata-only URL changes with separate authorization) or one manual accelerated DMG upgrade. Do not silently assume new config changes old installations.
6. Measure mainland/global routes according to target users before selecting R2, domestic object storage/CDN, or regional hosting. Rollback must keep immutable versions available and must not introduce downgrade promotion.

## Pending user-owned decision

Primary target network: mainland China, overseas, or both. This materially determines infrastructure and cost; obtain this before final architecture and implementation approval.
