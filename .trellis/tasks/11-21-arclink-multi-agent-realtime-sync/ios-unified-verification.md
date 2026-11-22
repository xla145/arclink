# iOS unified projects and model selection — verification

Date: 2026-11-21

Implemented unified project navigation, explicit new-task client/project selection, dynamic Agent/model menus, durable pending-task retries and actual managed runtime model changes. Existing conversations remain device-bound; provider switching is new-conversation-only.

- Backend: agentd 123 and client 21 tests passed (model worker).
- Desktop: 45 tests, TypeScript and production build passed.
- Deterministic iroh integration: managed_catalog 1 and managed_execution 2 passed.
- iOS: 138 tests executed with signing disabled; 137 passed, native isolated Keychain test failed. Same Keychain test passed with app signing enabled. No credential implementation change made.
- Final signed iPhone build succeeded; devicectl installed com.xula.ArcLink successfully on connected iPhone (installation ABCF0C1E-3CFB-4F0C-9FD0-2DA03280F7B6).
- git diff --check passed.

Limits: no final visual or real multi-Mac/phone end-to-end acceptance; Mac must run the updated managed_models_v1 host. Task remains in progress, without commit/push/archive.

Logs: /tmp/arclink-model-integration.log, /tmp/arclink-unified-all-ios-tests.log, /tmp/arclink-keychain-signed-test.log, /tmp/arclink-unified-final-device-build.log.

Housekeeping error: Xcode UserInterfaceState.xcuserstate was inadvertently restored to HEAD during final cleanup; no source/history/credential files were reverted.
