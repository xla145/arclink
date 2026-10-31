# Current implementation context (2026-10-31)

## Evidence and scope resolution
The user explicitly selected a greenfield implementation after source
inspection. The source-gap decision is resolved; historical Swift plans and
claims about existing tests are archived for provenance, not current context.
Current requirements are in this task PRD, design and implementation plan.

## Authoritative documents
- doc/agent-bridge-desktop-client.md: Tauri 2, React/TypeScript/Vite, embedded
  agentd library, SQLite host metadata, iroh and prost; default 320px panel,
  480px maximum height, separate pairing window, 120-second invitation.
- doc/agent-bridge-tray.html: visual hierarchy and states. It has sample data,
  external fonts and decorative QR generation: none become runtime behavior.
- doc/agent-bridge-plan.md: ABP framing/identity/trust/relay rules, one verified
  structured Agent first, Generic PTY only after independent validation.

## Important deviations from historical specs
Do not implement SwiftUI, daemon stdio administration, host session/task/
approval persistence or business event parsing. Those describe missing old
code, conflict with the user's current documents, and are not dependencies.
Retain general invariants: authenticated peers, explicit consent, secret
redaction, bounded I/O, truthful connectivity, stale-generation rejection,
owned-process cleanup and operation-outcome uncertainty.
The new host spec must capture the implemented contract after validation;
existing historical specs must not be treated as proof of current support.

## Cross-layer constraints
- Rust owns authoritative daemon/device/process state. UI uses named commands
  and revisioned events with service/process generation. Initial snapshot and
  subscription ordering must not miss or overwrite updates.
- Opaque AgentIO cannot enforce different semantic task/approval messages;
  require both permissions for bidirectional access and explain the coupling.
- A short-lived pairing QR is an explicit transient WebView use of its token;
  avoid logs, persistent/global frontend state and localStorage. Keychain
  private identity never enters frontend payloads.
- Unknown network status is distinct from Direct/Relay; paired != online.
- Output is bounded by bytes, not only channel message count; gap indication
  precedes retained post-loss output. stdout/stderr remain separate.
- SQLite operation reservation precedes spawn; restart ambiguity stays unknown
  and cannot automatically spawn a second process for the same operation ID.

## Toolchain observed (not a build result)
Rust/cargo 1.93.1, Node 23.11.1, npm 10.9.2, Corepack available; pnpm is not
on PATH. macOS SDK query returned 26.5 with sandbox cache/event-stream warnings.
Use Corepack pnpm and lock the compatible dependency versions during build
foundation; no dependency downloads or product compilation have run yet.

## Working tree boundaries
User changes include doc/agent-bridge-plan.md, doc/agent-bridge-mobile.html
and IMG_9188.PNG / IMG_9189.PNG. Preserve them and do not stage them as task
implementation. No source clone/download or product code has been created.
