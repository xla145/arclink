# Design

Smallest gap: ChatView calls synchronous mock AppStore.send. Implement Codex JSON-RPC in a dedicated Swift CodexChatSession over existing authenticated Mac StartProcess/AttachIO. The Mac Tauri embedded agentd starts its installed Codex; host remains opaque. No FFI/API regeneration required.

Protocol owner: CodexChatSession.swift owns bounded byte NDJSON framing, request correlation with bounded timeout, initialize/initialized/thread/start or thread/resume/turn/start, item deltas/completion, turn completion/errors, approval request and reply and turn/interrupt. Retain driver at AppStore device+session scope rather than view scope. Never blind replay a turn after uncertain delivery. Preserve native thread ID for restart/resume; fresh process for restarted clients must not replay previous initialize against old process. Process identity is stored in existing fields.

AppStore and ChatView own device-captured state reduction, session busy/error handling, composer and pending approvals. Existing mock path may remain only for explicit mock/test workspaces; real paired endpoints must never fall back to mock. Images may be explicitly rejected until bounded real image input is implemented. UI should retain draft on explicit rejection. Protocol callbacks are typed; UI never casts raw JSON. Terminal cannot concurrently take the chat input lease.

Orca references: mobile-native-chat-send.ts models accepted/rejected/unknown with one send budget and no automatic retry; use-mobile-structured-native-chat-send-bridge.ts captures origin and restores rejected drafts. Retain iroh and host authorization. Exact Codex 0.165.0 JSON schemas generated under /private/tmp/arclink-codex-schema.
