# Execution plan

Status: in progress. User approved the final simple-menu-bar summary with “可以”. Task activated; Rust and Swift implementation delegated with explicit ownership.

1. Implement/document bounded opt-in daemon stdio administration; add tests for request correlation, malformed/oversize input, pairing expiry, explicit permissions, EOF and graceful shutdown. Preserve ordinary CLI and ABP.
2. Create native Swift package with Codable control models, owned-process transport and MainActor state model. Add mock-transport tests for failure, stale generation, refresh, pending permission and restart/quit behavior.
3. Build compact Chinese MenuBarExtra UI matching screenshot hierarchy: service, errors, devices/pairing, Codex, login/log/version/quit. Connect every available action to real methods; no live mock data.
4. Create packaging script bundling daemon and macOS executable/Info.plist, ad-hoc sign, and build local .app. Add developer guide and implementation-status update.
5. Run Rust fmt/test/clippy, Swift tests/build, protocol integration; inspect rendered app/screenshot on this Mac if GUI execution is permitted. Do not register login item or modify external daemon state during smoke test.
6. Independent Trellis check and fixes; capture cross-language stdio and ownership contracts in specs; record exact validation and deployment limitations. No Git repository exists; do not invent commits.

## Ownership
Use Trellis implement workers for Rust local-control and Swift application work with explicit files; main coordinates contract and packaging boundaries, check worker reviews whole flow. Native context injection preferred with manifests as fallback.

## Commands / gates
- cargo test --workspace --locked (existing37 plus new tests)
- cargo clippy --workspace --all-targets --locked -- -D warnings
- cargo fmt --all -- --check
- swift test --package-path macos
- swift build --package-path macos -c release
- scripts/build-macos-app.sh (to be added)
- Bundle inspection and visual smoke test; report Keychain/system approval requirements honestly.

## Risks
GUI PATH may not include installed Codex; resolve explicitly without shell sourcing. Keychain prompts and SMAppService approval depend on OS state. Full relay reachability is not derivable from daemon process liveness. Keep UI labels honest and do not expand scope into mobile or session workspace.
