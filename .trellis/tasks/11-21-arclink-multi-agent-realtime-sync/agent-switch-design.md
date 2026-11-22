# Same-conversation Agent switching (approved user extension, 2026-11-22)

## Requirement and boundary
A managed conversation keeps its Thread ID, project, owning Mac and full public timeline while the user switches between Codex and Claude. The Agent/model pick applies to the next idle turn. This supersedes the earlier restriction that an existing Thread cannot change provider. Imported/legacy native histories remain readable and are not silently taken over. No device migration, private reasoning transfer, parallel runs, automatic model calls or git merges.

## Upstream reference
Read t3code main `apps/server/src/orchestration-v2/ProviderSessionTransitionPolicy.ts` and `apps/web/src/components/chat/useApplyThreadModelPick.ts` on 2026-11-22. Upstream distinguishes reuse, in-session model change, restart/resume and create_with_handoff. Incompatible continuation driver/identity creates a fresh session with handoff. Persist selection separately from native session identity, and only release composer pick after authoritative success. Adapt this pattern to the existing ArcLink Thread/RPC architecture; do not copy provider-private context or upstream model names.

## Contract
Add capability `managed_provider_switch_v1` and idempotent RPC `threads.provider.set` with `{command_id,thread_id,provider_id,model?,expected_revision?}` returning the existing Thread shape. Optional model is validated against the target's dynamic catalog. Require view/session/task and project ACL; serialize with sends using mutation_gate; reject non-idle, active, approval-pending and outcome_unknown runs, unavailable targets and stale revisions. Matching retries return receipt without reapplying; payload changes conflict.

Keep Thread.id, project_id, cwd and messages unchanged. Retire/reap the old live runtime, fence late events and clear the provider-native binding when provider changes. Each cross-provider transition uses a fresh native session, including A→B→A, with bounded public user/final-assistant history handed off on its first next send. Store a durable switch marker and provider attribution in message content; old unattributed messages remain legacy/unknown and use a generic historical-assistant label instead of relabeling as the newly selected Agent. Handoff excludes private thinking/raw approval metadata and is clearly quoted historical context; retain all UI history, explicitly mark bounded transfer when necessary. Do not record the handoff as a duplicate user message or replay past instructions as tool calls.

## Ownership
Backend worker: agentd domain/store/thread service/network/runtime/session fencing and deterministic backend tests. UI worker: ManagedThreadView/ManagedThreadState and Swift tests only. Root: agent-bridge-client RPC wrapper, generated ABI and device/simulator libraries, desktop compatibility/attribution, integration validation, docs and installation. No concurrent edits to another owner's files.

## Validation and rollout
Rust unit/integration tests: stable timeline across Codex→Claude→Codex, correct fresh native IDs, context arrival, model selection, restart continuity, permissions, busy/uncertain rejection, idempotent retry and late-event fencing. Swift: switch-event projection, historical attribution, capability/error/loading/unknown delivery fences and retry identity. Existing host/client/desktop regressions and signed iOS build/install. Old host shows explicit upgrade requirement. Record actual evidence and remaining physical multi-device limitations. No commit/push/archive; preserve credentials and Xcode UI state.
