# Claude Code remote conversations

## Goal
Allow the paired iPhone client to create and continue Claude conversations on the Mac, receive streaming replies, interrupt turns, and answer tool approvals.

## Confirmed background
- Claude executable discovery exists, but production status is installed/unverified.
- `agent-bridge/ios/AgentBridge/AppModel.swift:897` rejects non-Codex remote chat; its driver creation uses CodexChatSession.
- `agent-bridge/ios/AgentBridge/CodexChatSession.swift:48` defines the existing driver lifecycle, recovery and approval interface.
- Existing AgentIO provides encrypted byte transport, ownership, generation checks, resumable output and input leases.
- Local Claude reports 2.1.317; CLI supports stream-json input/output, partial messages, resume and host permission prompts. These flags alone do not prove protocol compatibility.

## Requirements
R1. Use actual bounded protocol initialization to determine Claude transport readiness; installation and account/model failures remain distinct.
R2. Support new text/image conversations and continued ArcLink-created Claude sessions; preserve existing Codex behavior and stored identities.
R3. Stream assistant output and tool progress without duplicate final text; show errors and turn completion accurately.
R4. Display actual tool name, inputs and working directory when approval is requested. Send explicit allow/deny; unknown requests fail closed. Do not enable permission bypass.
R5. Interrupt a running turn. Reattach to a live process after transport interruption without replaying user submissions or approval replies whose delivery is unknown.
R6. Preserve desktop-imported history as read-only; continuation applies to ArcLink-owned sessions. Clearly identify unsupported model/options rather than silently using Codex-specific settings.
R7. Preserve device separation, permissions, bounded buffers, startup cleanup and process lifecycle rules.

## Acceptance
- Paired device can submit two Claude turns with incremental output and durable session identity.
- Continuing an ArcLink-created conversation retains context; imported desktop histories remain read-only.
- Approval allow and deny paths are verified with a controlled operation; rejection does not execute it.
- Interrupt, malformed output, process exit, login failure and network interruption show accurate state without automatic resubmission.
- Codex regression suites pass; real Claude handshake and end-to-end evidence are recorded separately from fixtures.
- Rebuilt macOS package passes strict signature verification. iOS build/tests pass on an available simulator; real-device coverage is reported accurately.

## Out of scope
Herdr integration, changing account credentials, automatically installing/upgrading Claude, resuming arbitrary desktop-owned live processes, automatic public publication, and guarantees about iOS background execution.
