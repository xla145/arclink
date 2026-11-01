# Local conversation-list cache findings

User requested fewer Mac synchronizations when obtaining conversation lists.

- `DeviceWorkspace` already persists projects/sessions/messages to devices-v2.json; list rendering should keep using those rows immediately.
- `AppStore.refreshDevice` calls `autoImportMacProjects` after listAgents. The only fetch suppression was runtime `importedAgentIDs`, lost on relaunch and populated before the RPC succeeds, preventing retries after transient failure.
- `autoImportMacProjects` receives project+thread catalogs through ListAgentProjects, merges thread rows via syncThreads and persists workspace.
- `ProjectEditor.loadMacProjects` bypassed AppStore and called concrete BridgeConnection.listAgentProjects on each Agent task/appearance.
- Existing import code has only a device-exists check after await; cache work must retain/check runtime identity/generation before applying a late catalog.
- New policy: per-device/per-Agent durable successful cache, five-minute freshness, explicit forced refresh, stale data retained on failure/offline, successful empty result fresh, coalesced in-flight work. No transcript/message-body caching changes.
