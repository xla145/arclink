# Implementation plan

1. Verify Claude control protocol with bounded read-only initialization. Record sanitized protocol fixtures and exact runtime version; resolve resume launch requirements and permission-policy behavior.
2. Update host adapter and transport probe; if necessary add typed resume context through ABP/UniFFI and idempotency validation. Cover errors, oversized output, timeout and cleanup.
3. Extract provider-neutral chat interfaces preserving Codex behavior. Implement Claude driver for startup, text/images, streaming, completion, interruption, tool approvals and safe recovery.
4. Integrate provider selection, compatible options and persisted session migration in iOS. Retain imported-history read-only behavior and multi-device isolation.
5. Tests: adapter/agentd/ABP tests, Swift protocol fixtures for split lines, duplicate events, allow/deny, interruption, reconnect and uncertain writes; existing Codex/iOS regressions; frontend tests/build if DTO changes affect desktop.
6. Run opt-in real Claude handshake and controlled two-turn/approval/interrupt smoke through the actual host transport. Record actual coverage and any login/model limitation.
7. Build iOS simulator target and macOS app/DMG; validate bundle signatures. Update applicable specs and provide artifact paths. Do not publish automatically.

## Review gate
Task remains planning until the user approves this concrete scope. Then run task.py start and dispatch implement/check agents with curated context. Any material contract/scope change discovered in the protocol spike must be surfaced before broad implementation.
