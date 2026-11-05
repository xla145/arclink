Chat is the conversation with one agent in one project: read the reply, approve what it asks, and keep going.

Nav bar: back, the conversation title in 16px semibold with project · agent under it in `caption`, and a more menu. The body is MessageBubble turns on `bg`, with StepsDisclosure and CodeBlock inside agent replies and an ApprovalCard inline when the agent is waiting. The Composer is pinned to the bottom.

What changed from today's Chat:
- One palette with the rest of the app: the green chat scheme (ChatStyle accent `#286347`) is replaced by `primary` / `primary-soft`, so Chat no longer looks like a different app.
- The large in-scroll title is dropped; the nav bar title is enough and gives the first message more room.
- Copy and retry sit under each reply instead of in a long-press menu.
- Errors use a Banner above the composer with 重试, not 12pt red text.
- Approve uses `primary`, deny `secondary` — no more green/red pair.
