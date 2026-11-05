# ArcLink Website

## Scope
Standalone marketing/download site in `agent-bridge/website`, independent of Tauri. Use existing brand SVG and accurate client capabilities. Do not include credentials, backend code or native source in published assets.

## Commands
`python3 agent-bridge/website/prepare.py` generates `index.html` from `index.template.html` and `downloads.json`, copies the configured Mac DMG, and prints its SHA-256. Preview with `python3 -m http.server 8767 --bind 127.0.0.1 --directory agent-bridge/website`.

## Contracts
Mac configuration contains version, minimumOS, architecture, source and same-site url under downloads/. iOS URL remains null and displays a noninteractive unavailable state. Generated HTML preserves downloads without JavaScript. Edit the template, then regenerate. Binary downloads are ignored by Git and must be prepared and deployed explicitly.

## Validation and errors
Missing source package, destination outside downloads/, a non-null iOS URL without implementation, checksum mismatch or unresolved template tokens fail preparation. Browser page should have no unresolved assets or horizontal overflow. Decorative rotated orbits must be clipped separately from devices.

## Cases
Base: existing local Apple Silicon test DMG yields working static download. Good: changing release metadata and regenerating updates all links consistently. Bad: deploying only Git-tracked files leaves a broken download.

## Verification
Check JS syntax and formatting, template-generation consistency, HTTP 200 for assets and DMG, and SHA-256 equality between downloaded package and source. Inspect 390 px and 1440 px layouts, focus visibility, FAQ keyboard activation, unavailable iOS state and console errors.

## Wrong vs correct
Wrong: edit only generated index.html or set a fake iOS download URL. Correct: edit index.template.html/configuration, regenerate and retain unavailable states until real distribution exists.

## Production
Domain arclink.classktv.com uses an isolated Nginx vhost, `/var/www/arclink/current` symlink to a timestamped release, and `/var/www/arclink/acme` for Certbot webroot challenges. Use bootstrap HTTP config before certificate issuance, then validated HTTPS config. Keep other vhosts unchanged. Publish only HTML/CSS/JS/assets/downloads; deploy configs belong outside the web root. Run nginx -t before reload. Keep prior releases for rollback. Verify public HTTPS, HTTP redirect and downloaded checksum after deployment. Certificate renewal uses a successful-renewal Nginx reload hook.
