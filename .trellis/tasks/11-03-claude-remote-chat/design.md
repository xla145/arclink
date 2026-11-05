# Design

## Ownership
Keep agentd an opaque transport/process host. Extend host-owned Claude adapter arguments and bounded handshake checks. Preserve Codex detection and process authorization. iOS owns Claude semantic messages, approvals and presentation.

## Driver integration
Extract the existing chat-driving/event contract to provider-neutral names without changing Codex behavior, retaining compatibility aliases only where needed for tests/migration. Add ClaudeChatSession with newline framing, request correlation, turn lifecycle, output offsets, lease recovery and bounded buffers. Select the driver by project agent in AppModel; replace Codex-specific presentation where shared.

## Protocol evidence gate
Before enabling Claude availability, capture sanitized fixture shapes using the installed CLI control initialize exchange and official Agent SDK references. Verify initialize/control_response, user, stream_event, assistant/result, interrupt and can_use_tool control request/response semantics. Do not log raw conversations or credentials. If resume requires launch flags, add typed optional session context to StartProcess/UniFFI with validated provider-owned arguments and include it in idempotency fingerprints; never expose arbitrary argv. Determine this in the initial implementation spike before editing the public contract.

## Sessions and permissions
Migrate durable thread identity to a provider-neutral optional field with fallback for existing codexThreadId; no device/history resets. Imported desktop history remains read-only. Use Claude permission mode compatible with explicit host prompts; do not map Codex sandbox labels onto nonexistent Claude guarantees. Unsupported policy choices must be unavailable or rejected. Approval responses preserve exact request identity and original input; unsupported requests deny explicitly.

## Recovery
Reuse existing AgentIO reattach/replay offsets, generation checks and write lease. Never retry a possibly delivered turn or approval. On an unbridgeable output gap, block sending and show uncertain state; never restart an active turn invisibly.

## Risks and rollout
Claude native protocol varies across releases; availability depends on actual initialization. Real turn/model tests need existing login/network and may consume usage. A protocol feature unsupported by the installed CLI must be reported, not simulated. Keep Codex working throughout. Deliver code/tests and verified local packages first; publish only when requested.
