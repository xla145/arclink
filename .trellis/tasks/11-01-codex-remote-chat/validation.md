# Validation

- xcodebuild iOS simulator build/test succeeded: 38 tests, zero failures (CodexChatSessionTests 13, RemoteChatTests 9, ConversationTests and ConversationCacheTests 16). Simulator E36F2D5F-020B-47D3-8F33-7E16337F8EF7.
- Real native smoke: `cargo test --manifest-path agent-bridge/Cargo.toml -p abp-test-harness --test transport real_codex_chat_turns_over_iroh -- --ignored --nocapture` passed with installed verified Codex 0.165.0; two actual model turns over authenticated iroh to embedded agentd, same initialization parameters as iOS and read-only turn override, 17.59 seconds. No transcript logged.
- Independent trellis-check found and fixed retry after definite pre-turn startup failure, plus regression.
- git diff --check passed.
- No physical iPhone/cellular validation, remote images, automatic replay or full reconnection recovery.
- Build/test logs: /private/tmp/arclink-chat-xcode.log and /private/tmp/arclink-chat-native.log.

Orca source references inspected: mobile-native-chat-send.ts, use-mobile-structured-native-chat-send-bridge.ts, mobile-structured-agent-session-send.ts. Adopt target capture, bounded send and accepted/rejected/unknown outcome classification; keep existing iroh transport and opaque authenticated Mac host.
