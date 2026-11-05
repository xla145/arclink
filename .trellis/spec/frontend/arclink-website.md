# ArcLink Website

## Scope
Standalone marketing/download site in `agent-bridge/website`, independent of Tauri. Use existing brand SVG and accurate client capabilities. Do not include credentials, backend code or native source in published assets.

## Commands
`python3 agent-bridge/website/prepare.py` generates `index.html` from `index.template.html` and `downloads.json`. Local packages are copied and checked; external R2 packages need no local binary. `--release-manifest <verified-R2-latest.json>` synchronizes the generated version and both DMG links without making network requests; add `--write-config` to persist the derived configuration for publication. This flag requires the manifest flag. Preview with `python3 -m http.server 8767 --bind 127.0.0.1 --directory agent-bridge/website`.

## Contracts
Mac configuration declares one stable version and minimumOS. Legacy single-package local configuration remains supported. Dual-architecture configuration uses `mac.packages.arm64` and `mac.packages.x64`, each with a URL and optional positive `sizeBytes`. Local entries declare a source and same-site URL under downloads/. External entries must match exactly `https://download.classktv.com/releases/arclink-v<version>/ArcLink-macos-<arch>.dmg` and must not declare a local source. Reject query strings, credentials, unsafe paths and architecture/version swaps.

iOS URL remains null and displays a noninteractive unavailable state. Generated HTML preserves architecture-specific downloads without JavaScript. Edit the template/configuration, then regenerate. Cross-origin buttons do not rely on the browser's `download` attribute. Binary downloads are ignored by Git; local mode still requires explicit preparation/deployment.

Release-manifest mode validates both macOS platforms, R2 versioned archive URLs, notes and signature metadata, then derives the matching DMG URLs. It does not verify cryptographic signatures or public availability. Validate the complete mirror according to [the R2 contract](./arclink-r2-distribution.md) before deploying links to it. Do not display cached package sizes from another version. Persist the release-derived version/configuration when updating the checked-in generated page, so regeneration without flags does not revert it.

## Validation and errors
Missing source package, destination outside downloads/, invalid external URL, missing architecture, manifest mismatch, a non-null iOS URL without implementation, checksum mismatch or unresolved template tokens fail preparation. Browser page should have no unresolved assets or horizontal overflow. Decorative rotated orbits must be clipped separately from devices.

## Cases
Base: existing local Apple Silicon test DMG yields working static download. Good: changing release metadata and regenerating updates all links consistently. Bad: deploying only Git-tracked files leaves a broken download.

## Verification
Run `python3 -m unittest discover -s agent-bridge/website -p 'test_*.py'`, plus JS syntax/formatting and template-generation consistency. Check HTTP 200 for assets and both DMGs, and SHA-256 equality between mirror and source. Inspect 390 px and 1440 px layouts, focus visibility, FAQ keyboard activation, unavailable iOS state and console errors.

## Wrong vs correct
Wrong: edit only generated index.html or set a fake iOS download URL. Correct: edit index.template.html/configuration, regenerate and retain unavailable states until real distribution exists.

## Production
Domain arclink.classktv.com uses an isolated Nginx vhost, `/var/www/arclink/current` symlink to a timestamped release, and `/var/www/arclink/acme` for Certbot webroot challenges. Use bootstrap HTTP config before certificate issuance, then validated HTTPS config. Keep other vhosts unchanged. Publish only HTML/CSS/JS/assets/downloads; deploy configs belong outside the web root. Run nginx -t before reload. Keep prior releases for rollback. Verify public HTTPS, HTTP redirect and downloaded checksum after deployment. Certificate renewal uses a successful-renewal Nginx reload hook.
