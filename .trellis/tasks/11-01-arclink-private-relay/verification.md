# Verification evidence — 2026-11-01

## Completed

- Core Rust suite plus bridge-network: 57 passed; one existing installed-Codex test ignored. Authenticated local HTTPS relay fixture proves forced-relay ABP exchange, explicit wrong-key rejection, both usable paths selecting direct and usable direct hints despite unavailable relay.
- Relay lease tests cover reference counts, conflict/isolation and baseline restoration. Host live-update regression preserves endpoint ID, the same peer connection and running Agent process.
- Desktop native unit tests: 3 passed. Native cargo check passed; only existing vendored netwatch deprecation warnings.
- Desktop frontend: 20 passed; TypeScript and production Vite build passed.
- Independent Trellis review fixed baseline restoration, durable-save credential cleanup and nullable path DTO. Prettier, cargo fmt and git diff --check passed.
- UniFFI Swift/header and both iOS XCFramework slices regenerated; whitespace normalization is reproducible in ios-build-client.sh.
- Physical iPhone16Pro (xu): Debug signing/build passed; app installed with unchanged dev.agentbridge.ios bundle identity. No uninstall/data reset. Launch denied because phone was locked.
- Desktop current machine configuration provisioned directly to macOS Keychain. No local plaintext secret file; credential audit passed.
- Desktop light/dark scan-only automatic-network UI inspected in explicit browser preview; screenshots in output/iroh-relay/screenshots. This is visual evidence, not native networking evidence.

- Final physical source was rebuilt successfully and installed again after review fixes. Secret audit was repeated against changed/untracked artifacts and desktop/iOS build logs; no production access key found.

- Same-stream upgrade fixture passed 5/5 repeats; full Rust suite with the new test passed (57 tests, one preexisting ignored).

## Pending / limitations

- Updated iOS unit/UI execution is blocked by CoreSimulator startup/IPC failure (Invalid device state, server died). Final arm64 simulator build-for-testing passed (application + all test targets). The final test-without-building retry timed out after 120 seconds; XCTest did not execute, and no iOS UI screenshots were produced. Do not count tests as passed merely because they compiled.
- Real iPhone LAN and cellular/different-Wi-Fi application acceptance remains pending; user was asked asynchronously to unlock/open installed app.
- Fresh public health probes from this Mac hit DNS resolution timeout and direct-connect timeout. Prior server deployment and authenticated 64KiB echo via temporary SSH tunnel are documented in output/iroh-relay/deployment.md; these prove that stated server path only.
- Shared-origin credential rotation across saved devices is deferred. Conflicting credentials are rejected explicitly.

Task remains in_progress pending real-network acceptance. Unrelated parallel UI work and credentials are preserved; no commits made.

Build warnings retained: existing TerminalCallback mutable Sendable owner; vendored netwatch deprecated send; toolchain AWS-LC assembly deployment-target warnings. Builds pass; these warnings are not new transport acceptance evidence.

## Acceptance mapping

| Criterion | Evidence / status |
| --- | --- |
| AC1 | Local authenticated relay, both-path direct preference and original-stream upgrade passed |
| AC2 | Unreachable relay + usable direct hint passed |
| AC3 | Desktop secure provisioning + secret audit passed; real phone scan/approval/restart pending |
| AC4 | Compatibility/refresh implemented and Swift tests compile; XCTest execution pending |
| AC5 | Credential staging/rollback implemented and tests compile; XCTest execution pending |
| AC6 | Rust shared endpoint/lease multi-host isolation passed; real multi-Mac phone run pending |
| AC7 | Rust, desktop tests/build and regenerated FFI/build passed; iOS XCTest/UI execution pending |
| AC8 | Physical signed build/install passed; locked phone blocks launch, LAN/cellular unverified |

## Scan-only refinement

User requested combined automatic direct/relay setup without address/key entry. Desktop credential form and iOS network-edit page removed; device rows retain actual selected path and re-scan action. QR-to-Keychain flow and existing workspace retention are unchanged. Native administration APIs remain for provisioning; current Mac protected configuration re-audited successfully. Updated frontend checks and iOS builds are recorded below. No compiled/shared plaintext credential introduced.

Refinement validation: desktop20/20 tests and production build passed. New desktop assertion confirms no relay credential controls or mutation and QR pairing remains reachable. Independent review/Prettier/TypeScript/diff checks passed. Final iOS arm64 simulator build-for-testing passed after the missing-item recovery fix; XCTest runtime remains unexecuted. Compiled Swift test cases assert automatic QR key/hint import and secret-free persistence, target missing-key repair/history preservation and other-host conflict rejection; runtime execution remains blocked by the previously documented CoreSimulator failure.

A fresh read-only CoreSimulator probe also hung; only the probe process was stopped. Global simulator services were left untouched. The final Swift missing-key recovery code and regression cases compiled successfully.

Final scan-only signed physical build passed and installed over the existing app on xu (unchanged bundle identity/data, no uninstall). Logs: /private/tmp/scan-only-ios-device-build-final.log and /private/tmp/scan-only-ios-device-install.log. No new physical network acceptance claimed.

## Conversation-list cache follow-up

Implemented a durable optional per-device/per-Agent project/thread catalog with five-minute freshness. Existing local list rows display immediately; stale catalogs refresh in background, forced pull-to-refresh bypasses freshness, and simultaneous loads coalesce. Successful empty catalogs cache normally; offline/RPC/save failure retains prior successful data/time. Project import now uses the same store loader. No Rust/FFI/desktop/relay transport changes.

Nine focused cache test cases were added to cover fresh relaunch/no RPC, expiry/force, empty success/retry, failure/save rollback, concurrent stale loads, device/Agent isolation/removal, foreground generation invalidation, old snapshots/future clocks and health completion while a catalog request is suspended. Final build and review results follow.

Cache follow-up final verification: independent Swift syntax parse and git diff --check passed; final arm64 simulator build-for-testing and signed physical build passed. Nine cache regression cases compile; XCTest runtime was not executed because CoreSimulator remains unavailable. Initial and final build logs: /private/tmp/conversation-cache-ios-build.log, /private/tmp/conversation-cache-ios-build-final.log, /private/tmp/conversation-cache-ios-device-build.log. Reviewer found and fixed only stale explicit-error feedback guards (selected device/runtime/generation/cancellation). No remaining source findings. Prior Rust/desktop evidence unchanged.

Cache-enabled final app installed successfully over the existing dev.agentbridge.ios app on xu; no uninstall/data reset. Install log: /private/tmp/conversation-cache-ios-device-install.log.

## Cellular pairing / Home navigation follow-up (2026-11-01)

- Removed iOS HTTP fallback that treated submission as completion and used an unrelated UUID identity. Only a successful, nonpending authenticated pairing result may persist a device. Endpoint-less legacy scans now explain that a new Mac QR is required.
- Added a durable-completion event for Home navigation, including re-scanning the current Mac. Scanner dismissal invokes device chooser completion, and approval-wait progress is visible.
- `cargo test -p agent-bridge-client --locked`: 15 passed. New test invokes exported `pair_over_iroh_with_network` over an authenticated local HTTPS relay, with IP transports disabled on both fixture endpoints; it waits for a controlled ABP approval and verifies selected relay route. Fixture TLS relaxation is test-only. This is client protocol evidence, not physical cellular acceptance or a real desktop approval UI test.
- iOS simulator `build-for-testing` succeeded for application/unit/UI targets. New Swift tests cover relay-only invitation, pending/rejected outcomes, repeated same-device success events, legacy rejection and no event on storage failure.
- Existing default-home-relay QR export in commands.rs was present before this follow-up and retained. No production relay policy or TLS weakening added.

- Bounded simulator runtime executed 25 tests: 24 passed, including all new scan/completion regressions. Existing `testNativeKeychainRoundTripUsesIsolatedReference` failed with `keychain` in the unsigned (`CODE_SIGNING_ALLOWED=NO`) simulator runner. xcodebuild was interrupted at the 100-second bound after case output; this is not an overall green XCTest run. Full log: `/tmp/arclink-pairing-tests.log`.
- Root completed signed physical build, installation and launch of the existing `dev.agentbridge.ios` app without uninstalling or clearing data; build log `/tmp/arclink-pairing-device-build.log`. Physical cellular scan/approval still requires actual two-device/network interaction.

- Follow-up focused run excluding only the separately reported native Keychain case completed successfully: 24 functional tests passed, `TEST EXECUTE SUCCEEDED`; `/tmp/arclink-pairing-functional-tests.log`. Native Keychain failure above remains unresolved/environment-limited and is not counted as passing.

## No Mac reaction: protocol stages and Apple DNS diagnosis (2026-11-01)

User's real scan showed the phone's initial text incorrectly suggesting Mac
approval while the desktop had received no request. Client startup and relay
registration previously ran outside its dial timeout. Added actual protocol
callbacks, a whole-pre-ACK 40-second deadline and a fixed 130-second approval
deadline. Initial UI now says connecting; only a validated Mac pending ACK asks
for Mac confirmation.

Root reproduced default iroh DNS timing out after 25s although protected-key
WebSocket authentication returned 101 and a test-only origin-pinned iroh exchange
succeeded. The shared Apple resolver follows OS A/AAAA behavior without a static
origin override, preserving TXT discovery/TLS. With the production helper, normal
DNS/Fake-IP actual 64 KiB forced-relay data exchange succeeded twice consecutively
after one earlier transient helper timeout. Default iroh DNS failed again with
HTTPS-probe TCP `Network unreachable`. Logs: `/tmp/arclink-relay-default-debug.log`
and `/tmp/arclink-relay-system-repeat-debug.log`. Updated desktop PID 25228 had an
ESTABLISHED relay TCP connection to 198.18.0.57:443 at startup 14:18:58 UTC. This
is public relay/desktop evidence, not a physical iPhone scan acceptance.

Pre-integration client tests 16/16 passed, including setup-lock timeout and actual
relay stage order; shared resolver tests 4/4 passed per worker. Final generated
artifacts and phone verification follow below.

Final follow-up verification:
- Both iOS Rust release targets and generated UniFFI bindings rebuilt after the final timeout-code review fix; `/tmp/arclink-pairing-stages-ios-rust-final.log`.
- `cargo test -p agent-bridge-client --locked`: 16 passed after DNS integration; `/tmp/arclink-pairing-stages-rust-final.log`.
- Simulator test build succeeded; focused RelayNetworkTests/MultiDeviceTests executed 25 tests with zero failures, excluding only the separately recorded unsigned native Keychain test; `/tmp/arclink-pairing-stages-swift-build.log`, `/tmp/arclink-pairing-stages-swift-tests.log`.
- Signed physical build succeeded after retrying a transient concurrent-Xcode build database lock; `/tmp/arclink-pairing-stages-device-build.log`. Installed the updated `dev.agentbridge.ios` on iPhone UDID 00008140-000C711434C2801C without uninstall/data reset, then launched successfully; `/tmp/arclink-pairing-stages-device-install.log` and `/tmp/arclink-pairing-stages-device-launch.log`.
- `git diff --check` passed after generated whitespace normalization. No commit or task archive; actual user phone rescan/approval is still distinct from transport/build evidence.

## Slow successful catalog loading follow-up (2026-11-01)

The user clarified that loading succeeds but is slow; no new error UI or timeout
increase was introduced. Exact local source produced six projects,140 threads
and27,256 JSON bytes in18ms. Isolated local authenticated ABP took49ms; exported
client catalog calls took35/20/15ms. These rule out a large response/disk bottleneck
for this case. Temporary probes live under `/tmp/arclink-catalog-client-probe`;
no probe source or production-data test dependency was added to the repository.

A controlled public authenticated relay probe uses actual exported client calls,
normal TLS, the production DNS helper, and a server with IP transports disabled.
It supplies the same catalog payload and prints aggregates only; the private
credential arrives through stdin, never logs/arguments/environment. Baseline
catalog calls:3658/3205/2817ms; after bounded read-only pipelining:2830/2075/1427ms.
Median fell from3.205s to2.075s (about35%). Ping changed from2584/2273/2316ms to
2070/2105/1738ms; ListAgents from2446/2330/2289ms to2099/1746/1556ms. All calls
reported relay and returned140 threads. Logs `/tmp/arclink-catalog-relay-baseline.log`
and `/tmp/arclink-catalog-relay-after.log`. Network variance affects these samples;
this is not a physical cellular benchmark. No further probe repetitions needed.

Client suite18/18 passed. Reviewer strengthened the no-duplicate regression to
observe stream EOF before closing the QUIC connection; that focused regression
passed after correction. Both iOS Rust slices and unchanged-shape UniFFI bindings
rebuilt successfully (`/tmp/arclink-catalog-pipeline-ios-build.log`). Formatting
and `git diff --check` pass. Swift/cache/navigation source was unchanged this round.

Signed physical build and data-preserving installation of the optimized
`dev.agentbridge.ios` succeeded. The single bounded launch attempt was denied
by iOS because the phone was locked (CoreDevice10002 / FBSOpenApplicationError7).
No repeated launch attempts were made; the user can unlock and open the installed app. Logs: `/tmp/arclink-catalog-pipeline-device-build.log`,
`/tmp/arclink-catalog-pipeline-device-install.log`, `/tmp/arclink-catalog-pipeline-device-launch.log`.
Existing pairing/history remain intact; no Mac update or new pairing is required
for this mobile transport optimization. No commit or task archive performed.


## Combined replies, execution summary and visual refinement

Imported and live messages now project one assistant card per user turn. Original paragraphs, images, native item identities and tool details remain intact. Historical structured outcomes use optional tool_failed; missing outcomes stay unknown. Live optional metrics use authoritative native turn/item identity and observed lifecycle dates, with replay deduplication and explicit uncertain termination. Reviewer findings on late-turn binding, indefinite in-progress failure and duplicate call outcomes were fixed and tested.

Host history tests21/21 and client metadata compatibility test passed. Swift focused functional suite68 tests and initial2 UI tests passed; the additional output-only failure aggregation branch passed separately. Visual revision passed7 grouping tests and5 UI checks, followed by final3 light/dark/accessibility-size UI tests after reinstalling only the stale isolated simulator test runner. Final result: /tmp/arclink-style-verified.xcresult. No production data reset. Root inspected final light and maximum-Dynamic-Type render and prior dark render; screenshots preserved at output/arclink-conversation-turns/merged-reply-summary.png and merged-reply-summary-dark.png. These screenshots use explicit test fixtures, not fabricated real history.

Shared historical metadata regenerated with Swift bindings and both device/simulator Rust slices. Existing desktop dev watcher rebuilt the host (startup23:00:54 Asia/Shanghai, after metadata source changes). Final signed iPhone installation is recorded below once complete.

Final signed device build succeeded and dev.agentbridge.ios was installed on the connected iPhone 16 Pro without uninstalling or resetting data. Logs: /tmp/arclink-styled-device-build.log and /tmp/arclink-styled-device-install.log. The single launch attempt was denied because the phone was locked (CoreDevice10002 / FBS7); no retry was made. The user can unlock and open the installed app. Launch log: /tmp/arclink-styled-device-launch.log. Additional maximum-text-size scrolling UI test passed, and the worker inspected all three visible metrics in /tmp/arclink-style-large-footer-screens/C3AE3E7A-72FE-4A82-A31E-B199379836FF.png. No commit or archive: broader relay acceptance remains outstanding.


## Final-answer-only and ordered tool steps
Optional native assistant_phase now survives historical transport; live phase and recorded public summaries use the same presentation contract. Only final content appears in prose/copy; commentary and public summaries retain their source positions among tool records. Legacy messages remain available using the last-complete-message fallback. Recovery projects actual bounded snapshot items in source order after associating the native turn and keeps stable-ID replay deduplication without fabricated timestamps. Independent reviewer found the original recovery projection omission, then verified the fix with no remaining blockers.

Host history22/22 and client old/new metadata1/1 passed; Rust checks/formatting passed. Both iOS Rust slices and FFI rebuilt. Final focused suite passed73 unit and3 UI tests (76 total, zero failures), including direct recover→boundedSnapshot→reconcile coverage. Initial UI attempt was interrupted by cross-app clipboard permission; final verification used the copy action/toast plus host simctl pbpaste, confirming exactly the final fixture answer. Results /tmp/arclink-final-result-verified.log and .xcresult. Root inspected light/dark screenshots; copies at output/arclink-conversation-turns/final-result-only.png and final-result-only-dark.png (fixtures). RemoteAI reference source investigation is recorded in research/remoteai-conversation-ui.md; no external code was copied.

Final signed iPhone build, data-preserving install and single launch all succeeded. Logs: /tmp/arclink-final-result-device-build.log, /tmp/arclink-final-result-device-install.log and /tmp/arclink-final-result-device-launch.log. This supersedes the prior locked-phone launch result for the earlier build. Final git diff --check passed.
Worker confirmed running Mac host PID25890 uses the same executable inode100244009 as the current desktop binary, containing assistant_phase; binary modification23:27:06 follows host source23:26:42 (Asia/Shanghai). No manual restart was needed.


## Structured user question replies
Read user RTF as data; identified the exact send_user_message_question_reply array. Open-source review covers CodMate, AionUi, assistant-ui and prior RemoteAI; source paths and conclusions are in research/open-source-codex-ui.md. Added user-only Swift presentation of validated question/answer arrays, keeping raw storage, original surrounding text, user boundaries and AI metrics. Known cards hide protocol metadata; invalid/unknown/quoted payloads remain verbatim. Same-line subsequent envelopes conservatively remain raw. No Rust/FFI change or third-party code copying.

Independent review found no blocking issues. Seven parser/user-boundary tests, nine conversation grouping tests and two light/dark UI tests passed (18 total, zero failures), /tmp/arclink-question-replies.log and .xcresult. Root inspected both fixture screenshots; output/arclink-conversation-turns/user-question-reply.png and user-question-reply-dark.png. These verify user-side question/answer layout, order and absence of protocol keys, not a claim of live network testing.

Final quoted-code boundary regression passed after a conservative fence-indentation fix (/tmp/arclink-question-literal-test.log). Final signed build, data-preserving install and single launch succeeded; /tmp/arclink-question-reply-device-build.log, -install.log and -launch.log. No uninstall/reset; pairing and history preserved.
