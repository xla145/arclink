# Unified iOS projects, new tasks and model selection

## User-confirmed behavior

The home screen lists projects together, without Claude/Codex/Herdr tabs. A new task prompts for its client and creates/registers the corresponding project there. The conversation composer offers provider/model choices. Existing conversations remain on their original client and project. No automatic project copying, cross-device failover or distributed job scheduler is part of this clarified change.

## UI and identity boundaries

- Group legacy provider-specific project rows by same-device project path in presentation while keeping their original IDs for imported history and legacy live sessions. Never merge unrelated devices by path/name.
- Use managed threads for new Claude/Codex work, reusing durable host-owned messages, runs, approvals and replay. Existing legacy Codex image sessions remain accessible.
- New tasks capture the chosen client before any network mutation. Device selection in the sheet must not silently retarget an existing task or discard a draft. A new folder is created through the established folder browser, and its canonical path is registered on that client.
- Load models from the chosen client's provider catalog; show loading, a default-model entry and actionable retrieval errors. Never infer supported models from a static UI list.
- Persist model selection to the host before submitting a turn. The composer shows authoritative selection, with pending/error feedback while setting it. Provider-native context stays with its provider; same-provider model changes take effect on subsequent idle turns.
- Busy and offline states are informational and derived from actual client observations. Missing observations are unknown, not idle.

## Host and transport

- Add an optional model to managed thread persistence/projection. Old rows and older clients continue with the provider default.
- Add a capability-negotiated model-setting operation using the existing command-receipt/idempotency pattern. Check permissions, thread ownership and idle state under the same service serialization boundary as sends.
- Model setting must update the durable projection and its event sequence. Retries retain command identity; late responses cannot overwrite a newer choice.
- Propagate selected models to Codex's native request and Claude's native session startup/turn configuration. Do not treat display-only metadata as implementation.
- Rust client DTOs and generated Swift bindings are generated together; compile both device and simulator xcframework slices to avoid ABI skew.

## Failure and compatibility behavior

An unsupported host keeps existing history usable and explains that model selection requires an update. Unknown delivery retains the pending command and original device; changing clients does not authorize replay. A failed model update retains the prior authoritative selection. Active/uncertain runs reject model mutation so one run cannot change configuration mid-execution.

## Implementation and validation

1. Host persistence/commands and provider mapping, with migration/default compatibility and active-run rejection tests.
2. Generated client ABI and both iOS library slices.
3. Unified home/project histories, new-task target client/project creation and model menus.
4. Swift tests for aggregation, device scoping, model loading and event projection; simulator build/tests.
5. Desktop type/build regression for additive DTOs; Rust host/client/integration tests.
6. Signed iOS device build. Installation uses the existing explicit user authorization if device is available; report physical test limits separately from simulator evidence.

Do not change credentials, bundle IDs, existing device files or the user's Xcode UI state. Do not commit, push or archive this active task.
