# Implementation

1. Protocol worker owns new CodexChatSession.swift and CodexChatSessionTests.swift; defines typed event and injectible I/O seam.
2. UI/state worker owns AppModel.swift, ChatView.swift, optional DeviceStorage.swift and store integration tests; coordinate protocol API before writes.
3. Root validates native Codex 0.165.0 protocol, Orca references, iOS build/test and docs/spec boundaries.
4. Independent check agent reviews and self-fixes only remote chat changes; preserve unrelated dirty work.
