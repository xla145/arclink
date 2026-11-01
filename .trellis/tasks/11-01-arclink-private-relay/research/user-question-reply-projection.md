# User question reply presentation boundary

The user supplied a real `role=user` message whose text wraps an array of
`{questionItemId, question, answer}` in `send_user_message_question_reply` tags.
Both imported and live user messages currently render through the same plain
Text branch in ChatView. Keep that role, its turn boundary, raw text, timestamps
and images intact. No host, wire, FFI, persistence or approval behavior changes.

Add a pure Swift presentation parser and a shared user-body view. Only known,
well-formed tagged arrays containing string questions and answers are converted.
The optional string questionItemId is metadata, never visible. Reject unknown
keys/types, malformed JSON, empty arrays and oversized payloads back to exact
original text. Keep ordinary prefix/suffix text and multiple known blocks in
source order. Quoted/fenced/code examples are literal, not structured responses.

Render a completed, noninteractive “补充信息” section inside the existing user
bubble. Question is secondary text, answer uses normal body emphasis; both wrap
and remain selectable. Never move these replies into AI tool steps or invent an
unanswered form/submission action. Unknown protocol types remain ordinary text.

Existing public-type audit: live command/file approvals have ApprovalItem and
resolved events; tool records use typed executionStep/role=tool; host excludes
known context injection prefixes. Do not add heuristic protocol stripping.

Verification: parser valid/mixed/multiple blocks, array order, duplicate replies,
malformed/unknown/oversize fallback, quoted and fenced examples; history/live
user boundaries remain intact; light/dark UI fixture checks readable questions
and answers and absence of IDs/wrapper. Build/sign/install without resetting data.
