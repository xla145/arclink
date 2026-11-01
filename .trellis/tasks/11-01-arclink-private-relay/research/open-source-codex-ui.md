# Open-source Codex conversation UI review

Read-only GitHub search and source inspection on 2026-11-01 (Asia/Shanghai). User-provided RTF attachment contains a user-role send_user_message_question_reply envelope with ordered question/answer objects, not instructions to the agent. Its internal questionItemId is transport metadata.

## Verified candidates
- https://github.com/loocor/codmate (Apache-2.0), commit2091c39609db97f6779030d014d0c60b5e4ee571. Native macOS SwiftUI application, not a drop-in iOS component package. Inspected models/ConversationTurn.swift and views/ConversationTimelineView.swift. Separates actor and visibility kinds, keeps user boundary and outputs, offers turn disclosure and timeline. AppKit scrolling means direct reuse needs adaptation.
- https://github.com/iOfficeAI/AionUi (Apache-2.0), commit11cd2a9a20d1e033157636efc570b41384c66d85. Supports Codex among other agents; React app/mobile implementations. Inspected packages/desktop/src/renderer/pages/conversation/Messages/MessageQuestion.tsx. Dedicated structured question cards with ordered questions and answered feedback; that particular component targets Claude AskUserQuestion, so do not claim its wire schema is Codex-compatible.
- https://github.com/assistant-ui/assistant-ui (MIT), commit36ca75503a68689f36eeb35cb498bd2058caaa5a. Reusable React AI chat component library; inspected question-flow demo with ordered steps and completed receipt. Generic library, not a ready-made SwiftUI Codex adapter.
- RemoteAI already reviewed in remoteai-conversation-ui.md; ordered final/process classification remains a suitable reference.

## Decision
There are open-source conversation implementations and reusable React chat components; this search did not establish a drop-in iOS SwiftUI Codex component. Keep native app and adopt typed content presentation: user questions/answers, final assistant prose, ordered process records, statistics. Current defect is presentation of an already-answered user envelope; fix locally without changing stored messages, role, turn grouping, sending or transport. No external code/dependency copied. Source review only; third-party apps not launched.
