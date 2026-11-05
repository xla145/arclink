# Technical design

## Presentation and ownership
Keep SwiftUI and existing AppStore actions. ChatView owns compact navigation context, user/assistant layout, attachment composer and scrolling intent. Use scoped adaptive semantic colors (asset variants or a small shared chat style), not app-wide appearance replacement. AgentStepsDisclosure remains the shared live/history entry point; extract its detail view if useful. ConversationSummaryView becomes compact without losing unknown/failure semantics.

## Data flow
Native ChatExecutionStep -> ChatMessage.executionStep -> ConversationTurn.live -> MessageStep -> disclosure/detail. Add optional presentation status fields to MessageStep using native completed/failed values. Historical status derives only from structured result metadata paired by call ID within one turn. Do not alter persisted snapshots or make ChatTurnMetrics carry duplicated payloads: its record method intentionally stores lightweight counts/outcomes. Keep selected step identity and resolve current step content for live sheet updates; close or label unavailable if the source disappears. Inputs/outputs render as selectable text/code with clear missing states; existing safe Markdown policy remains for prose.

## Ordering and native adaptation
Prototype supersedes the old spec's final-answer-first visual placement only: process disclosure precedes final answer, while projection/classification remains unchanged. Public commentary stays in ordered process records. Preserve exact execution counts versus total process records. Use native scroll indicators, not private UIKit hooks; only scroll automatically when following the latest content or after an explicit send/return action. iOS 17-compatible visibility/geometry state must avoid scroll feedback loops. Preserve native back behavior, app theme preference and system image picker.

## Boundaries and compatibility
No backend or wire changes. Preserve canSubmit, session/device guards, approval validation, stop/recovery semantics and read-only detection. Route terminal and destructive session actions through existing menus. No hardcoded Codex branding for other agents. No fabricated file cards or per-step duration. Full accessibility labels and minimum 44pt actions; large text can stack metadata.

## Risks and rollback
Long output and frequent streaming updates require lazy content and stable identities. Keyboard insets, sheet focus and bottom-follow state need simulator checks. Existing uncommitted changes must survive. Keep modifications scoped to chat presentation, necessary projection status fields, tests and relevant presentation spec paragraphs; rollback these independently without touching transport or snapshots.
