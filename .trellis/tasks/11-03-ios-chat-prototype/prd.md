# iOS conversation detail prototype adoption

## Goal
Apply the user-approved `prototypes/arclink-chat/index.html` design to the native ArcLink iOS conversation detail page. Improve reading, composing and inspecting real execution inputs/outputs.

## Background
- User requested adoption of the prototype, including refined scrolling and tappable step input/output details; task/planning consent received.
- `ChatView.swift` owns message rows, composer and existing recovery/permission boundaries.
- `MacMessageViews.swift:199` already provides AgentStepsDisclosure and an item-bound detail sheet.
- `ConversationTurn.swift:16` maps native execution input/output but does not yet carry per-step completion/failure into MessageStep. Historical pairing uses call IDs within turn boundaries.
- Existing working tree contains unrelated host, transport, desktop and website changes; preserve them.

## Requirements
R1. Native page adopts neutral green adaptive surfaces, right-aligned user bubbles, unboxed assistant prose, compact header and rounded multiline composer. Retain native navigation and semantic type sizing.
R2. Compact process disclosure expands to tappable rows. Detail sheet clearly separates real input/output, supports selection/copy and long content, and shows actual structured status when available. Missing data remains explicit; no invented durations, success, file changes or reasoning.
R3. Preserve final-answer-only projection and source ordering inside process records. Place the process disclosure ahead of the final answer to match the prototype; do not duplicate commentary as assistant prose. Retain real turn statistics in a compact presentation.
R4. Retain text/image send, explicit photo/paste consent, attachment removal/preview, stop, approval allow/deny, recovery, draft preservation and unknown-delivery protections. Read-only history cannot send. Any approval visuals use the existing store and actual operation data.
R5. Reading older messages must not be interrupted by streaming updates; provide return-to-latest when appropriate. Use native subtle scrolling indicators rather than reproducing browser CSS or adding a custom scroll engine.
R6. Support existing app appearance preference, safe areas/keyboard, Dynamic Type, VoiceOver and reduced motion. No prototype control panel or example content ships in production.

## Acceptance
A1. Simulator screenshots of light/dark conversation align with prototype layout, and accessibility text does not clip primary controls (R1,R6).
A2. Live and imported step rows open input/output details; missing/failed/in-progress states are honest; an open live detail reflects subsequent output for the same step (R2).
A3. Projection regression tests retain final paragraphs, images, call-ID pairing, user boundaries, replay semantics and unknown metadata (R2,R3).
A4. Existing mock UI paths plus targeted step-detail and composer cases pass; send/stop/approval/recovery/read-only contracts remain intact (R4).
A5. Scrolling away from bottom remains stable during updates; return-to-latest, keyboard and safe-area behavior work (R5,R6).

## Out of scope
Mac desktop redesign, transport/agent protocol additions, new model selection behavior, invented file-diff feeds, public release, publishing, and automatic commits. No new per-step timing protocol.
