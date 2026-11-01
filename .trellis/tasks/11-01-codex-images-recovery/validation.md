# Validation

- Rust full deterministic suite: 65 passing tests (abp-protocol6, harness10, client12, agentd37); native model probes remain opt-in. Log /private/tmp/arclink-rust-recovery-tests.log.
- Mac desktop cargo check passed; log /private/tmp/arclink-rust-desktop-recovery-check.log.
- Regenerated Swift/headers/modulemap and both iOS device/simulator XCFramework libraries from final Rust client. Log /private/tmp/arclink-images-ffi.log.
- iOS simulator full AgentBridgeTests suite: 89 passing, zero failures (26 Codex protocol,20 remote chat plus43 existing tests). Log /private/tmp/arclink-images-xcode-signed.log.
- Run full iOS tests with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` for local simulator signing. Initial unsigned run passed all chat tests but existing native Keychain roundtrip failed; local signing resolved it without code changes.
- Native installed verified Codex0.165.0 real iroh image smoke passed: image spans transport frames, native model recognized red/blue; hard-disconnect, same peer/process/thread resume via offsets/lease, full output and following model turn. Exact notLoaded turn page and one-item page shape also passed. Final run47.84s; log /private/tmp/arclink-images-native.log. No transcript logged.
- Independent trellis-check passed host auth/lease/offset/record behavior and bounded native snapshots. It found full-history image hydration overflow; fixed with bounded metadata/turn/item paging and3 large-image-history regression.
- git diff --check and scoped Rust format/Swift parse passed. No unrelated dirty paths reverted or committed.

## Remaining acceptance boundary

Physical iPhone/cellular/WiFi-transition and OS suspension tests have not been run. Foreground and return-to-foreground recovery are implemented. Native output retention is finite4MiB and gaps are explicit. Cold app launch does not have a checkpoint/lease proof: if prior process is live, query+block duplicate process and ask user to check Mac; an ended/lost process can resume native thread. Mac exit/reboot does not restore lost child processes. No APNs/automatic mutating replay. Upgrade Mac before iOS.
