import XCTest
@testable import AgentBridge

@MainActor
final class ManagedThreadStateTests: XCTestCase {
    private func thread(revision: String = "1") -> ManagedThread { ManagedThread(id: "t", projectId: "p", providerId: "codex", model: nil, title: "Test", cwd: "/tmp", status: "active", revision: revision, createdAt: "now", updatedAt: "now") }
    private func snapshot(sequence: String = "9007199254740993") -> ManagedThreadSnapshot {
        ManagedThreadSnapshot(environmentId: "e", sequence: sequence, thread: thread(), messages: [], runs: [], approvals: [], hasOlderMessages: false)
    }
    private func replay(sequence: String = "9007199254740994", environment: String = "e", eventSequence: String = "9007199254740994") -> ManagedThreadReplay {
        let payload = try! JSONSerialization.data(withJSONObject: ["id": "t", "project_id": "p", "provider_id": "codex", "title": "Next", "cwd": "/tmp", "status": "idle", "revision": "2", "created_at": "now", "updated_at": "now"])
        let event = ManagedThreadEvent(sequence: eventSequence, aggregateId: "t", eventType: "thread.updated", schemaVersion: 1, payloadJson: String(decoding: payload, as: UTF8.self))
        return ManagedThreadReplay(environmentId: environment, threadId: "t", sequence: sequence, events: [event], hasMore: false)
    }
    func testWideDecimalCursorAndThreadRevision() throws {
        let value = try ManagedThreadState.apply(replay(), to: snapshot())
        XCTAssertEqual(value.sequence, "9007199254740994")
        XCTAssertEqual(value.thread.status, "idle")
        XCTAssertEqual(value.thread.revision, "2")
    }
    func testModelSelectionUpdatesWithThreadEvent() throws {
        var event = replay()
        var payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(event.events[0].payloadJson.utf8)) as? [String: Any])
        payload["model"] = "fixture-model"
        event.events[0].payloadJson = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let value = try ManagedThreadState.apply(event, to: snapshot())
        XCTAssertEqual(value.thread.model, "fixture-model")
        XCTAssertNil(try ManagedThreadState.apply(replay(), to: snapshot()).thread.model)
    }
    func testRejectsForeignAndRegressiveReplay() {
        XCTAssertThrowsError(try ManagedThreadState.apply(replay(environment: "other"), to: snapshot()))
        XCTAssertThrowsError(try ManagedThreadState.apply(replay(sequence: "1", eventSequence: "1"), to: snapshot()))
        XCTAssertThrowsError(try ManagedThreadState.apply(replay(eventSequence: "9007199254740995"), to: snapshot()))
    }
    func testCacheRoundTripUsesDeviceAndThreadIsolation() throws {
        let device = "managed-test-\(UUID().uuidString)"
        let value = snapshot()
        try ManagedThreadState.save(value, device: device)
        XCTAssertEqual(ManagedThreadState.load(device: device, thread: "t"), value)
        XCTAssertNil(ManagedThreadState.load(device: device, thread: "other"))
    }
}

extension ManagedThreadStateTests {
    func testProviderAttributionAndSwitchMarker() throws {
        let user = ManagedMessage(id: "m1", threadId: "t", runId: nil, clientMessageId: nil, role: "assistant", contentJson: "{\"text\":\"old\",\"provider_id\":\"claude\"}", revision: "1")
        XCTAssertEqual(ManagedThreadState.provider(user), "claude")
        let marker = ManagedMessage(id: "m2", threadId: "t", runId: nil, clientMessageId: nil, role: "system", contentJson: "{\"type\":\"provider_switch\",\"from_provider_id\":\"claude\",\"to_provider_id\":\"codex\",\"model\":\"gpt\"}", revision: "2")
        XCTAssertEqual(ManagedThreadState.switchMarker(marker)?.from, "claude")
        XCTAssertEqual(ManagedThreadState.switchMarker(marker)?.to, "codex")
        XCTAssertEqual(ManagedThreadState.switchMarker(marker)?.model, "gpt")
    }

    func testProviderSwitchPendingRoundTripUsesDeviceAndThreadIsolation() throws {
        let device = "provider-switch-test-\(UUID().uuidString)"
        let value = ManagedThreadState.ProviderSwitch(command: "cmd", threadId: "t", providerId: "claude", model: nil, revision: "9")
        try ManagedThreadState.saveProviderSwitch(value, device: device)
        XCTAssertEqual(try ManagedThreadState.loadProviderSwitch(device: device, thread: "t"), value)
        XCTAssertNil(try ManagedThreadState.loadProviderSwitch(device: device, thread: "other"))
        try ManagedThreadState.clearProviderSwitch(device: device, thread: "t")
        XCTAssertNil(try ManagedThreadState.loadProviderSwitch(device: device, thread: "t"))
    }
}

extension ManagedThreadStateTests {
    func testColdLaunchPendingSwitchBlocksSendAndKeepsCommandIdentityAndDraft() throws {
        let device = "provider-restore-\(UUID().uuidString)"
        let request = ManagedThreadState.ProviderSwitch(command: "same-command", threadId: "t", providerId: "claude", model: nil, revision: "7")
        try ManagedThreadState.saveProviderSwitch(request, device: device)
        defer { try? ManagedThreadState.clearProviderSwitch(device: device, thread: "t") }
        let model = ManagedThreadModel()
        model.connected = true; model.draft = "Keep this draft"
        XCTAssertTrue(model.canSend)
        model.restoreProviderSwitch(device: device, thread: "t")
        XCTAssertEqual(model.pendingProvider, request)
        XCTAssertTrue(model.providerUncertain)
        XCTAssertFalse(model.canSend)
        model.stop()
        XCTAssertEqual(model.pendingProvider?.command, "same-command")
        XCTAssertTrue(model.providerUncertain)
        XCTAssertEqual(model.draft, "Keep this draft")
    }

    func testInvalidPendingSwitchFailsClosedWithoutOverwritingRecord() throws {
        let device = "provider-invalid-\(UUID().uuidString)"
        let invalid = ManagedThreadState.ProviderSwitch(command: "cmd", threadId: "t", providerId: "unknown", model: nil, revision: "1")
        try ManagedThreadState.saveProviderSwitch(invalid, device: device)
        defer { try? ManagedThreadState.clearProviderSwitch(device: device, thread: "t") }
        XCTAssertThrowsError(try ManagedThreadState.loadProviderSwitch(device: device, thread: "t"))
        let model = ManagedThreadModel()
        model.connected = true; model.draft = "draft"
        model.restoreProviderSwitch(device: device, thread: "t")
        XCTAssertTrue(model.providerStorageBlocked)
        XCTAssertFalse(model.canSend)
        XCTAssertThrowsError(try ManagedThreadState.loadProviderSwitch(device: device, thread: "t"))
    }

    func testSwitchReplayKeepsOriginalAttributionAndUnknownLegacyLabel() throws {
        var original = snapshot(sequence: "1")
        original.messages = [ManagedMessage(id: "old", threadId: "t", runId: nil, clientMessageId: nil, role: "assistant", contentJson: "{\"text\":\"old answer\",\"provider_id\":\"codex\"}", revision: "1")]
        let payload: [String: Any] = ["id": "t", "project_id": "p", "provider_id": "claude", "title": "Next", "cwd": "/tmp", "status": "idle", "revision": "2", "created_at": "now", "updated_at": "now"]
        let event = ManagedThreadEvent(sequence: "2", aggregateId: "t", eventType: "thread.updated", schemaVersion: 1, payloadJson: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        let result = try ManagedThreadState.apply(ManagedThreadReplay(environmentId: "e", threadId: "t", sequence: "2", events: [event], hasMore: false), to: original)
        XCTAssertEqual(result.thread.providerId, "claude")
        XCTAssertEqual(result.messages, original.messages)
        XCTAssertEqual(ManagedThreadState.provider(result.messages[0]), "codex")
        var legacy = result.messages[0]; legacy.contentJson = "{\"text\":\"legacy answer\"}"
        XCTAssertNil(ManagedThreadState.provider(legacy))
        legacy.role = "assistant"; legacy.contentJson = "{\"type\":\"provider_switch\",\"from_provider_id\":\"codex\",\"to_provider_id\":\"claude\"}"
        XCTAssertNil(ManagedThreadState.switchMarker(legacy))
    }
}
