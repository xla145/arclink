import XCTest
@testable import AgentBridge

@MainActor
final class MultiDeviceTests: XCTestCase {
    private func storage() throws -> DeviceStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeviceStorage(directory: directory)
    }

    private func snapshot() -> DeviceSnapshot {
        let a = PairedMac(id: "a", name: "Mac A", endpointID: "endpoint-a", workspace: DeviceWorkspace(
            projects: [ProjectItem(id: "same", name: "A project", path: "/a", agent: .claude)],
            sessions: [SessionItem(id: "same-session", projectId: "same", title: "A session", status: .running, detail: "")]))
        let b = PairedMac(id: "b", name: "Mac B", endpointID: "endpoint-b", workspace: DeviceWorkspace(
            projects: [ProjectItem(id: "same", name: "B project", path: "/b", agent: .claude)],
            sessions: [SessionItem(id: "same-session", projectId: "same", title: "B session", status: .running, detail: "")]))
        return DeviceSnapshot(devices: [a, b], selectedDeviceID: "a")
    }

    func testSwitchPersistsSelectionAndIsolatesIdenticalIDs() throws {
        let storage = try storage()
        try storage.save(snapshot())
        let store = AppStore(storage: storage, autoConnect: false)
        store.selectDevice("b")
        XCTAssertEqual(store.projects.first?.name, "B project")
        store.clearHistory()
        store.setRealProcess(deviceID: "a", sessionId: "same-session", processId: "a-process", generation: "g")
        store.selectDevice("a")
        XCTAssertEqual(store.sessions.first?.realProcessId, "a-process")
        XCTAssertEqual(store.sessions.first?.title, "A session")
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(restored.selectedDeviceID, "a")
        XCTAssertFalse(restored.online)
        restored.selectDevice("b")
        XCTAssertTrue(restored.sessions.isEmpty)
    }

    func testLegacyMigrationPreservesHistoryAndBackup() throws {
        let storage = try storage()
        let legacy = LegacyDeviceSnapshot(paired: true, hostName: "旧 Mac", online: true, selectedAgent: .claude,
            projects: snapshot().devices[0].workspace.projects, sessions: [], messages: [], approvals: [], permission: "仅查看",
            notifyApproval: true, notifyDone: true, notifyOnMac: false, notifyFailed: true, macEndpointId: nil)
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: storage.legacyURL)
        let store = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.projects.first?.name, "A project")
        XCTAssertEqual(store.permission, "仅查看")
        XCTAssertFalse(store.online)
        XCTAssertEqual(store.connectionStateLabel, "请重新扫码连接")
        XCTAssertEqual(try Data(contentsOf: storage.legacyURL), original)
        XCTAssertEqual(try Data(contentsOf: storage.directory.appendingPathComponent("state-v1-backup.json")), original)
        XCTAssertEqual(try storage.load().devices.count, 1)
    }

    func testCorruptNewFormatNeverOverwrittenOrFallbackToLegacy() throws {
        let storage = try storage()
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: storage.currentURL)
        let store = AppStore(storage: storage, autoConnect: false)
        XCTAssertNotNil(store.storageError)
        store.save()
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), corrupt)
    }

    func testConcurrentConnectionsSwitchDoesNotDisconnectAndRemovalIsScoped() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        let a = FakeTransport(), b = FakeTransport()
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { $0 == "endpoint-a" ? a : b })
        await store.refreshMacStatus()
        XCTAssertTrue(store.isOnline("a")); XCTAssertTrue(store.isOnline("b"))
        store.selectDevice("b")
        XCTAssertEqual(a.disconnects, 0); XCTAssertEqual(b.disconnects, 0)
        store.removeDevice("a")
        await Task.yield()
        XCTAssertEqual(a.disconnects, 1)
        XCTAssertTrue(store.isOnline("b")); XCTAssertEqual(b.disconnects, 0)
    }

    func testDelayedOldDeviceResultDoesNotReplaceSelectedStatusOrResurrectRemovedDevice() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        let a = FakeTransport(), b = FakeTransport()
        a.delayConnect = true
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { $0 == "endpoint-a" ? a : b })
        let refresh = Task { await store.refreshMacStatus() }
        while a.pendingConnect == nil { await Task.yield() }
        store.selectDevice("b")
        store.removeDevice("a")
        a.completeConnect()
        await refresh.value
        XCTAssertEqual(store.selectedDeviceID, "b")
        XCTAssertFalse(store.isOnline("a"))
        XCTAssertTrue(store.online)
    }

    func testBackgroundInvalidatesInFlightRefresh() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        let a = FakeTransport(), b = FakeTransport()
        a.delayConnect = true
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { $0 == "endpoint-a" ? a : b })
        let refresh = Task { await store.refreshMacStatus() }
        while a.pendingConnect == nil { await Task.yield() }
        store.suspendHealthChecks()
        a.completeConnect()
        await refresh.value
        XCTAssertFalse(store.isOnline("a"))
        a.delayConnect = false
        await store.refreshMacStatus()
        XCTAssertTrue(store.isOnline("a"))
    }

    func testCancelledPairingCannotCommitLateSuccess() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        var continuation: CheckedContinuation<PairOutcome, Never>?
        let store = AppStore(storage: storage, autoConnect: false, pairingOperation: { _, _, _, _, _ in
            await withCheckedContinuation { continuation = $0 }
        })
        let pair = Task { await store.pair(from: "{\"token\":\"token\",\"endpoint_id\":\"new\",\"device_name\":\"New Mac\"}") }
        while continuation == nil { await Task.yield() }
        store.cancelPairing()
        continuation?.resume(returning: PairOutcome(ok: true, deviceId: "phone", pending: false, errorCode: "", errorMessage: ""))
        let result = await pair.value
        XCTAssertFalse(result)
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertEqual(store.hostName, "Mac A")
    }

    func testFailedPairDoesNotChangeCurrentDevice() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        let store = AppStore(storage: storage, autoConnect: false, pairingOperation: { _, _, _, _, _ in
            PairOutcome(ok: false, deviceId: "phone", pending: false, errorCode: "unauthorized", errorMessage: "")
        })
        let result = await store.pair(from: "{\"token\":\"token\",\"endpoint_id\":\"new\",\"device_name\":\"Other\"}")
        XCTAssertFalse(result)
        XCTAssertEqual(store.hostName, "Mac A")
        XCTAssertEqual(store.projects.first?.name, "A project")
        XCTAssertEqual(try storage.load().selectedDeviceID, "a")
    }

    func testStorageFailureRollsBackSelectionRemovalAndPair() async throws {
        let storage = try storage()
        try storage.save(snapshot())
        let a = FakeTransport(), b = FakeTransport()
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { $0 == "endpoint-a" ? a : b },
            pairingOperation: { _, _, _, _, _ in PairOutcome(ok: true, deviceId: "phone", pending: false, errorCode: "", errorMessage: "") })
        await store.refreshMacStatus()
        try FileManager.default.removeItem(at: storage.currentURL)
        try FileManager.default.createDirectory(at: storage.currentURL, withIntermediateDirectories: false)
        store.selectDevice("b")
        XCTAssertEqual(store.selectedDeviceID, "a")
        store.removeDevice("a")
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertEqual(a.disconnects, 0)
        let result = await store.pair(from: "{\"token\":\"token\",\"endpoint_id\":\"new\"}")
        XCTAssertFalse(result)
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertEqual(store.selectedDeviceID, "a")
    }

    func testRepairLANRecordAndDuplicatePairKeepWorkspace() async throws {
        let storage = try storage()
        var saved = snapshot()
        saved.devices[0].endpointID = nil
        try storage.save(saved)
        let store = AppStore(storage: storage, autoConnect: false, pairingOperation: { _, _, _, _, _ in
            PairOutcome(ok: true, deviceId: "phone", pending: false, errorCode: "", errorMessage: "")
        })
        let payload = "{\"token\":\"token\",\"endpoint_id\":\"repaired\",\"device_name\":\"Mac A new name\"}"
        let repaired = await store.pair(from: payload, repairingDeviceID: "a")
        XCTAssertTrue(repaired)
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertEqual(store.projects.first?.name, "A project")
        let repeated = await store.pair(from: payload)
        XCTAssertTrue(repeated)
        XCTAssertEqual(store.devices.count, 2)
        XCTAssertEqual(store.selectedDeviceID, "a")
    }
}

@MainActor
private final class FakeTransport: DeviceTransport {
    var disconnects = 0
    var delayConnect = false
    var pendingConnect: CheckedContinuation<ConnectionState, Never>?
    var projectsByAgent: [String: [MacProject]] = [:]
    func connect() async -> ConnectionState {
        if delayConnect { return await withCheckedContinuation { pendingConnect = $0 } }
        return .connected
    }
    func reconnect() async -> ConnectionState { await connect() }
    func completeConnect() { pendingConnect?.resume(returning: .connected); pendingConnect = nil }
    func disconnect() async { disconnects += 1 }
    func ping() async throws {}
    func listAgents() async throws -> [AgentInfo] { [] }
    func listAgentProjects(agentId: String) async throws -> [MacProject] { projectsByAgent[agentId] ?? [] }
}
