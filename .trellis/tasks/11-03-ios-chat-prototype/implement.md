# Implementation plan

1. After approval of this planning summary, activate task and load Phase 2 context; dispatch trellis-implement with curated manifests. Re-check current git diff and nested instructions before edits.
2. Inspect chat, shared markdown/steps, conversation projection/summary, approvals and UI fixtures; record exact source/tests affected. Use CodeGraph first where indexed.
3. Add scoped chat theme and adapt ChatView header, messages, compact statistics and composer. Preserve existing actions, attachment limits and uncertain delivery behavior.
4. Adapt step list and detail sheet, project real completion/failure metadata and keep open details live. Missing input/output remains explicit; no inferred success.
5. Implement stable following-latest scrolling and accessible return action; adapt actual approval rendering and history state to the new styling.
6. Add targeted regression coverage for step metadata/update/missing values and UI details; reuse existing projection and mock-path suites. No tests that merely assert color constants.
7. Run simulator build and appropriate unit/UI tests. Initial command: `xcodebuild -project agent-bridge/ios/AgentBridge.xcodeproj -scheme AgentBridge -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build`; use `xcrun simctl list devices available` to select an available simulator if needed. Run `test` with targeted ConversationTurnTests and MockPathTests plus relevant existing renderer/chat tests discovered during implementation. Capture light/dark, expanded details and large-text screenshots. Do not claim live-device acceptance from fixtures.
8. Dispatch trellis-check, fix findings, update only affected presentation contracts in `.trellis/spec/frontend/agent-bridge-ios.md`, and report checks and remaining limitations. No commit or release without request.

## Gate
Planning artifacts complete. Await a subsequent user approval of the final summary before `task.py start` or product edits.
