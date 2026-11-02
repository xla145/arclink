# Implementation plan

- [x] Obtain user approval of the final planning summary before task.py start.
- [x] Load applicable development guidelines and dispatch the Trellis implementer with curated context.
- [x] Build the independent responsive page, reuse the existing brand asset and add accurate feature copy.
- [x] Add download configuration, package preparation and concise local preview/deployment instructions; ignore prepared binary files.
- [x] Prepare the DMG, run a local server, verify page/assets/download HTTP responses and SHA-256 equality.
- [x] Inspect 390 px and 1440 px browser screenshots, navigation, keyboard focus, unavailable iOS state and console output; resolve any failures.
- [x] Dispatch Trellis check for independent review, resolve findings and record verified outcomes.
- [x] Update relevant frontend website spec.
- [ ] Obtain scoped commit approval, then finish bookkeeping.

## Verification commands
Exact preparation/server commands will be documented alongside the implementation. Use `python3 -m http.server` for preview and browser automation for layout and interactions. Compare prepared and original DMG checksums. No native client rebuild is required.

## Boundaries
Only the new website, task artifacts and relevant specs are owned by this task. Preserve existing workspace changes. No public deployment or client signing. Roll back the website directory if necessary.

## User-authorized deployment extension
- [x] Upload allowlisted release assets and verify checksums.
- [x] Install isolated HTTP vhost, validate Nginx, issue TLS certificate and switch to validated HTTPS vhost.
- [x] Check public HTTPS page, redirect, download checksum, and existing services.
