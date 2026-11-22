# iOS unified projects and multi-device Agent dispatch

Status: implementation extension of the active authorized task.

## Confirmed user requirements

- Remove the Claude / Codex / Herdr project tabs; present projects together.
- Let a project conversation choose different Agents. The user explicitly clarified that “不用 agent” meant “不同 Agent”, not a notes-only mode.
- Keep multiple paired devices and allow work requested in an iOS conversation to be assigned to an available Agent on an idle eligible device.
- Preserve existing device credentials, project records, conversation history and approvals.

## Current implementation evidence

- `HomeView.swift:65` renders AgentSwitcher and filters the project list by selectedAgent.
- `AppModel.swift:56` stores AgentKind on ProjectItem; sessions reference a project rather than independently choosing an Agent.
- `AppModel.swift:412` refreshes paired devices independently. Health checks obtain Agent discovery data; discovery alone is not a reservation or authoritative idle check.
- `Generated/agent_bridge_client.swift:640` creates managed threads with an explicit provider; existing managed threads are owned by one host and provider.
- `ManagedThreadView.swift:253` creates threads on the selected device. Existing event cursors and cached snapshots are scoped to the owning environment/device.
- Current project folders are host-local. Matching project names or equal path strings across hosts does not prove shared file contents or revisions.

## Required implementation boundaries

- Separate logical project identity from Agent identity and host-local project bindings.
- Separate unified conversation presentation from provider-native session identities; never resume a Claude session as Codex or reuse one host's native session ID on another.
- New task creation must check project availability, device permissions and provider capability; the host remains authoritative for concurrent execution limits. Device load is advisory for the explicit client picker.
- Record the selected device, provider, command and run identities before treating a dispatch as accepted. Unknown delivery must not trigger execution on another device.
- Surface actual execution ownership and status in the conversation. Preserve approval ownership and reconnect routing.

## Resolved task routing decision

The user specified that only NEW tasks select a client and create the corresponding project on that client. Prompt for the target client and project location; show available/busy information as a selection aid, not autonomous migration. Existing conversations remain attached to their original client/project. No cross-device file copy or distributed scheduler is required by this clarified scope.

The user also requested an in-conversation Agent/model dropdown inspired by t3code. Models must come from the selected client's provider catalog and the selected model must reach the actual execution runtime. Use an explicit default-model choice when no model is selected. Provider changes are available before first send; an existing provider-native conversation keeps its provider identity. Model changes within that provider may apply to subsequent turns when idle and must be persisted by the host, not only by a local UI label.

## Implementation boundary

1. Unified iOS project presentation, without Agent tabs or separate shared-project entry. Group same-device projects by actual path while preserving original IDs and read-only imported provider history.
2. New task sheet: target device -> existing or newly created project folder -> provider/model dropdown -> prompt. Bind command IDs/device/project/provider before mutation; uncertain creation/sends must be reconciled on the same host, never moved to another.
3. Host model configuration: additive persisted selection with default for old data; capability-negotiated model-setting command, idle validation, provider launch/turn mapping, event projection and generated UniFFI bindings. Existing clients retain default behavior.
4. Managed conversation rendering uses the selected provider and stored model; dynamic dropdown lists actual supported models and reports loading/errors accurately.
5. Verify host persistence/provider mapping, generated bindings, iOS project aggregation/device ownership, unknown outcomes, simulator and signed device builds. No commits/pushes or task archival.

## Reference evidence

Read upstream `apps/web/src/components/ChatView.modelPick.browser.test.tsx` via GitHub raw content on 2026-11-21. The test checks that selecting a model for an existing thread dispatches `thread.model-selection.set` before a message is sent and preserves model options for alias-equivalent choices. Reuse the interaction concept; do not copy upstream code or static model names.

## Proposed acceptance scenarios

- No Agent tabs on the unified project list; project conversations can select an Agent.
- Provider-specific historical conversations remain readable and correctly attributed.
- With two paired devices, the new-task picker shows their actual availability and lets the user select one; creation and execution use that selected client, even if the previously viewed client differs.
- Missing project, unsupported Agent, stale load and insufficient permissions do not produce fake successful dispatches.
- An uncertain create/send remains attached to the selected client and cannot execute twice through a new command ID or another device.
- Restart/reconnect retains the selected execution owner and restores conversation events without crossing device boundaries.

Busy state is advisory; host execution limits remain authoritative. Existing tasks do not change devices.
