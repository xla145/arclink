# Research: Native interface comparison

- Query: Which locked Agent offers the smallest reliable Rust approval control surface?
- Scope: mixed
- Date: 2026-10-30

## Findings

Legend: ✓ means interface exists in the cited schema or official documentation, NOT an empirical pass. No live Agent task was executed by this researcher.

| Capability | Codex CLI 0.165.0 app-server | Claude Code 2.1.314 via official SDK |
|---|---|---|
| Create session | ✓ `thread/start` | ✓ Python `ClaudeSDKClient.connect()` / context manager |
| Submit / next turn | ✓ `turn/start` with thread ID | ✓ `ClaudeSDKClient.query()` maintains conversation |
| Actual tool approval | ✓ server request `item/commandExecution/requestApproval` | ✓ `can_use_tool` / TypeScript `canUseTool` callback |
| Approve | ✓ `decision: accept` | ✓ `PermissionResultAllow` |
| Deny | ✓ `decline`, agent continues turn | ✓ `PermissionResultDeny` |
| Cancel | ✓ `turn/interrupt`; approval `cancel` also interrupts | ✓ `ClaudeSDKClient.interrupt()`, streaming mode only |
| Resume | ✓ `thread/resume` by persisted thread ID | ✓ `ClaudeAgentOptions(resume=session_id)` |
| Rust direct transport | ✓ generated JSON schema + stdio | Official SDK is Python/TypeScript; recommend sidecar if selected |
| Locked-version empirical closure | Pending root runner results | Not tested; SDK version not installed/pinned by this research |

Choose Codex first: locally generated schema is pinned to the installed binary, JSON-RPC request IDs give explicit approval correlation, Rust can drive stdio without an extra SDK runtime. This is a cost/surface decision, not a claim Claude cannot support approvals.

### Files / code patterns

- `phase0/schema/ServerRequest.json:1846`: native command approval server request used by `turn/start`; method at line 1853.
- `phase0/schema/CommandExecutionRequestApprovalResponse.json:7`: `accept`; line 14: session-scoped acceptance; line 68: `decline` continues turn; line 75: `cancel` interrupts turn. Do not collapse decline and cancel into the same task status.
- `phase0/schema/CommandExecutionRequestApprovalParams.json:535`: optional `approvalId` can be null for ordinary commands; zsh subcommand and stdin callbacks may share `itemId` but have distinct callback IDs. Never key solely by item ID.
- `phase0/schema/CommandExecutionRequestApprovalParams.json:578`: item ID; lines 633–636: thread/turn IDs. Correlate native JSON-RPC request ID plus runtime generation and these IDs.
- `phase0/schema/v2/TurnInterruptParams.json:4`: interrupt requires thread and turn IDs.
- `phase0/schema/v2/ThreadResumeParams.json:1582`: prefer thread ID. Existing running thread is rejoined; non-running thread is reconstructed from disk/history/path. Does not promise resurrection of an OS process or pending approval.
- `phase0/schema/v2/ThreadStartParams.json:351`: ephemeral option; persisted resume test must avoid ephemeral mode.

### External references

- https://platform.claude.com/docs/en/agent-sdk/python — fetched successfully by root to `/tmp/phase0-claude-python.html`, read as HTML text. Official reference explicitly lists multi-exchange `ClaudeSDKClient`, `query`, `receive_response`, `interrupt`, `resume`, `can_use_tool`, `PermissionResultAllow` and `PermissionResultDeny`.
- https://platform.claude.com/docs/en/agent-sdk/permissions — fetched successfully to `/tmp/phase0-claude-doc.html`. Permission evaluation can resolve before callback. Allowlisted tools and bypass modes can skip callback; use default permission mode and avoid pre-allowing test tools. Ask rules / policy have special behavior. Therefore a callback existing is not proof every tool pauses.
- https://developers.openai.com/codex/app-server — fetch returned `Forbidden`; no claim based on unseen page. Local `codex app-server generate-json-schema --out phase0/schema` is authoritative for installed 0.165.0.

### Related specs

`doc/agent-bridge-plan.md` §§07/09 requires real requests, pre-execution evidence, approval/denial/cancel/next turn/resume, bounded framing and no remote-approval product when closure is unverified. Backend specs are still templates, not established implementation conventions.

## Caveats / Not Found

Claude documentation is current and not a version-specific SDK lock. Pin a compatible SDK and executable path and run the same acceptance matrix before advertising Claude support. Native schemas establish shapes, not operational behavior. Official Codex page could not be read. This research does not establish execution, cancellation, or resume pass status for either Agent.
