# RemoteAI conversation component reference

User supplied https://github.com/piperhex/remoteai during the final-answer-only change. Read-only source review at commit 71ffa129496b24f988a42d770feee18a8dbfe38e; checkout /tmp/arclink-remoteai-reference. No third-party code copied or executed. Repository root license: Apache-2.0. This is source inspection, not rendered browser verification.

## Relevant components
- shared/chat/turnGroups.ts: explicit final_answer becomes message content; last unclassified assistant message is legacy fallback. Other items become work groups, keeping source order.
- apps/desktop/src/pages/codexGui/TurnProcess.tsx: process disclosure automatically opens while running/failed/interrupted, collapses completed automatic state, and preserves explicit user inspection.
- apps/desktop/src/pages/codexGui/WorkItems.tsx and activityGroups.ts: only consecutive tools group together; commentary and reasoning keep their positions. Running tools remain represented even if later tools complete.
- apps/desktop/src/pages/codexGui/ActivityRow.tsx: compact icon + human-readable preview + disclosure arrow; detailed tool payload is separate.
- shared/chat/DeferredDetails.tsx: constructs heavy content only when expanded; releases it on collapse.
- apps/desktop/src/pages/codexGui/TurnDuration.tsx: updates active running duration only; supports interrupted duration and absent timing.

## ArcLink application
Current SwiftUI implementation can reuse the interaction principles, not React components directly. Preserve the user's explicit final result → 工具步骤 → metrics layout rather than adopting RemoteAI's chronological top-level work-before-answer layout. Preserve 44-point mobile touch targets, semantic colors, Dynamic Type, and only recorded public reasoning summaries. Compact process excerpts and on-demand details already align. Automatic expansion and nested consecutive-tool grouping are optional future refinements, not requirements for this patch. No wholesale UI replacement or additional dependency needed.
