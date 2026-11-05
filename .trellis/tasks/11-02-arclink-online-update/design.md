# Technical design

Use Tauri 2 updater on the native side with a bundled public key and HTTPS GitHub Releases latest.json endpoint. Publish per-architecture app.tar.gz archives and signatures alongside DMGs only after all builds succeed. Apple Developer ID signing/notarization remain disabled. Update signatures are mandatory and independent.

Native commands own checks, selected update, download/verification, and installation; expose serializable state/progress to React through bridge.ts. Serialize update operations and reject duplicates. Network failures remain visible/retryable. Only newer versions qualify. Backend uses lifecycle gate and daemon shutdown before installing/restarting; no bypass of host cleanup. Downloads/signature verification complete before shutting down. Recover safely on installation/cleanup failure and allow explicit retry/exit. Always require explicit install consent; when activity changes, request renewed consent for task interruption. Preserve all IDs and storage.

React checks once on native startup, surfaces available updates, allows manual checks in settings, and shows progress/errors/confirmation. Browser preview never simulates successful native updates. No forced upgrade, iOS update, new platform, or automatic background install.

Key bootstrap: generate a persistent private/public updater keypair outside tracked files, store the private key only in GitHub Actions Secrets, and commit the public key. Never expose private material in logs. Release builds fail early if keys are absent. Document initial setup and retain keys for future versions.

Validation includes version handling, failed checks, invalid signatures, repeated actions, lifecycle races, frontend production build, Rust checks/tests, and manifest URLs/architecture/signature completeness. Real GitHub build and signed two-version installation remain explicit external validation if unavailable. Rollback by withdrawing a faulty release; clients must never downgrade silently.

User-approved distribution: make the original repository public and rename it to `xla145/arclink`; update origin and all current release endpoints. GitHub Actions Secrets remain attached to the same repository. Gitleaks scanned all 14 fetched commits and current source without findings before the visibility change.
