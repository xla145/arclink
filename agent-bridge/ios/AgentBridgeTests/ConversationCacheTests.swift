import XCTest
@testable import AgentBridge

@MainActor
final class ConversationCacheTests: XCTestCase {
    private func storage(devices: [PairedMac]? = nil) throws -> DeviceStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = DeviceStorage(directory: directory)
        let records = devices ?? [PairedMac(id: "a", name: "Mac A", endpointID: "endpoint-a")]
        try storage.save(DeviceSnapshot(devices: records, selectedDeviceID: records.first?.id))
        return storage
    }

    private func project(_ title: String = "History") -> MacProject {
        MacProject(path: "/repo", lastSeen: "2026-11-01T01:00:00Z", name: "Repo", threads: [
            MacThread(id: "thread", title: title, updatedAt: "2026-11-01T01:00:00Z", source: "cli")
        ])
    }

    func testRemovedMacProjectDisappearsAfterRefreshAndRelaunch() async throws {
        let storage = try storage()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(store.projects.count, 1)
        remote.projects["claude"] = []
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertTrue(restored.projects.isEmpty)
        XCTAssertEqual(restored.cachedMacProjects(deviceID: "a", agent: .claude), [])
    }

    func testPreviousProjectCatalogRequiresRefreshAfterCatalogSourceUpgrade() throws {
        var cache = ProjectCatalogCache(fetchedAt: Date(), projects: [project()])
        cache.sourceSchema = 1
        XCTAssertFalse(cache.isFresh(at: Date()))
        XCTAssertEqual(cache.values.count, 1)
    }

    func testSourceOnlyRefreshUpdatesRowAndSurvivesRelaunchAsReadonly() async throws {
        let storage = try storage()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(store.sessions.first?.source, .cli)
        XCTAssertTrue(try XCTUnwrap(store.sessions.first).isReadOnly)
        store.stopSession(id: "thread")
        XCTAssertTrue(try XCTUnwrap(store.sessions.first).isReadOnly)
        store.send(sessionId: "thread", text: "Must not send", images: [])
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.approvals.isEmpty)
        remote.projects["claude"]?[0].threads[0].source = "desktop"
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertEqual(store.sessions.first?.source, .desktop)
        remote.projects["claude"]?[0].threads[0].source = nil
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertEqual(store.sessions.first?.source, .unknown)
        XCTAssertTrue(try XCTUnwrap(store.sessions.first).isReadOnly)
        remote.projects["claude"]?[0].threads[0].source = "cli"
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(restored.sessions.first?.source, .cli)
        XCTAssertTrue(try XCTUnwrap(restored.sessions.first).isReadOnly)
        XCTAssertEqual(restored.cachedMacProjects(deviceID: "a", agent: .claude)?.first?.threads.first?.source, "cli")
    }

    func testLegacyCatalogIsReadableButRequiresSourceRefresh() throws {
        let json = #"{"fetchedAt":0,"projects":[{"path":"/repo","threads":[{"id":"old","title":"Old"}]}]}"#
        let cache = try JSONDecoder().decode(ProjectCatalogCache.self, from: Data(json.utf8))
        XCTAssertFalse(cache.isFresh(at: Date(timeIntervalSinceReferenceDate: 1)))
        XCTAssertNil(cache.values.first?.threads.first?.source)
        XCTAssertEqual(SessionSource(remoteValue: cache.values.first?.threads.first?.source), .unknown)
    }

    func testPersistedFreshCatalogSkipsRPCOnRevisitAndRelaunch() async throws {
        let storage = try storage()
        let clock = CacheClock()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 1)
        XCTAssertEqual(store.sessions.first?.title, "History")

        let relaunchedRemote = CatalogTransport()
        let restored = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in relaunchedRemote }, catalogNow: { clock.now })
        // Persisted list appears before any connection is attempted.
        XCTAssertEqual(restored.sessions.first?.title, "History")
        XCTAssertEqual(restored.cachedMacProjects(deviceID: "a", agent: .claude)?.first?.threads.first?.title, "History")
        await restored.refreshMacStatus()
        let result = await restored.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(result?.count, 1)
        XCTAssertNil(relaunchedRemote.calls["claude"])
        clock.now.addTimeInterval(301)
        let offlineRemote = CatalogTransport()
        let offline = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in offlineRemote }, catalogNow: { clock.now })
        let fetchedAt = offline.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt
        let cachedOffline = await offline.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertEqual(cachedOffline?.first?.threads.first?.title, "History")
        XCTAssertEqual(offline.sessions.first?.title, "History")
        XCTAssertEqual(offline.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt, fetchedAt)
        XCTAssertNil(offlineRemote.calls["claude"])
    }

    func testExpiryAndForceRefreshUpdateWithoutDeletingLocalConversation() async throws {
        let storage = try storage()
        let clock = CacheClock()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        let id = try XCTUnwrap(store.projects.first?.id)
        let local = store.createSession(projectId: id, title: "Phone conversation")
        remote.projects["claude"] = [project("New title")]
        clock.now.addTimeInterval(299)
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(store.sessions.first { $0.id == "thread" }?.title, "History")
        XCTAssertEqual(remote.calls["claude"], 1)
        clock.now.addTimeInterval(1)
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 2)
        XCTAssertEqual(store.sessions.first { $0.id == "thread" }?.title, "New title")
        remote.projects["claude"] = [project("Forced")]
        await store.refreshConversationList(agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 3)
        XCTAssertEqual(store.sessions.first { $0.id == "thread" }?.title, "Forced")
        XCTAssertEqual(store.sessions.first { $0.id == local }?.title, "Phone conversation")
    }

    func testEmptySuccessIsCachedButFailureIsNotFreshAndCanRetry() async throws {
        let storage = try storage()
        let clock = CacheClock()
        let remote = CatalogTransport()
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        let first = await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(first, [])
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 1)
        let successfulDate = try XCTUnwrap(store.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt)
        clock.now.addTimeInterval(301)
        remote.fail = true
        let stale = await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(stale, [])
        XCTAssertEqual(store.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt, successfulDate)
        remote.fail = false
        remote.projects["claude"] = [project()]
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 3)
        XCTAssertEqual(store.sessions.first?.title, "History")
    }

    func testFailureAndSaveFailurePreserveVisibleRowsAndPreviousFreshness() async throws {
        let storage = try storage()
        let clock = CacheClock()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        let successfulDate = try XCTUnwrap(store.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt)
        clock.now.addTimeInterval(301)
        remote.fail = true
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertEqual(store.sessions.first?.title, "History")
        remote.fail = false
        remote.projects["claude"] = [project("Uncommitted")]
        try FileManager.default.removeItem(at: storage.currentURL)
        try FileManager.default.createDirectory(at: storage.currentURL, withIntermediateDirectories: false)
        await store.loadMacProjects(deviceID: "a", agent: .claude, force: true)
        XCTAssertEqual(store.sessions.first?.title, "History")
        XCTAssertEqual(store.cachedMacProjects(deviceID: "a", agent: .claude)?.first?.threads.first?.title, "History")
        XCTAssertEqual(store.devices.first?.workspace.projectCatalogs?["claude"]?.fetchedAt, successfulDate)
    }

    func testConcurrentLoadsShareRPCAndStaleRowsStayVisible() async throws {
        let storage = try storage()
        let clock = CacheClock()
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        clock.now.addTimeInterval(301)
        remote.delayed = true
        remote.projects["claude"] = [project("Updated")]
        let a = Task { await store.loadMacProjects(deviceID: "a", agent: .claude) }
        while remote.pending == nil { await Task.yield() }
        let b = Task { await store.loadMacProjects(deviceID: "a", agent: .claude, force: true) }
        await Task.yield()
        XCTAssertEqual(store.sessions.first?.title, "History")
        XCTAssertEqual(remote.calls["claude"], 2)
        remote.complete()
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(first, second)
        XCTAssertEqual(remote.calls["claude"], 2)
        XCTAssertEqual(store.sessions.first?.title, "Updated")
    }

    func testDeviceAndAgentCachesAreIndependentAndLateRemovalCannotResurrect() async throws {
        let storage = try storage(devices: [PairedMac(id: "a", name: "A", endpointID: "a"), PairedMac(id: "b", name: "B", endpointID: "b")])
        let a = CatalogTransport(), b = CatalogTransport()
        a.delayed = true
        a.projects["claude"] = [project("A")]
        b.projects["claude"] = [project("B")]
        b.projects["codex"] = [project("B Codex")]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { $0 == "a" ? a : b })
        await store.refreshMacStatus()
        let request = Task { await store.loadMacProjects(deviceID: "a", agent: .claude) }
        while a.pending == nil { await Task.yield() }
        store.selectDevice("b")
        await store.loadMacProjects(deviceID: "b", agent: .claude)
        await store.loadMacProjects(deviceID: "b", agent: .codex)
        XCTAssertEqual(store.cachedMacProjects(deviceID: "b", agent: .claude)?.first?.threads.first?.title, "B")
        XCTAssertEqual(store.cachedMacProjects(deviceID: "b", agent: .codex)?.first?.threads.first?.title, "B Codex")
        store.removeDevice("a")
        a.complete()
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.selectedDeviceID, "b")
        XCTAssertEqual(b.calls["claude"], 1)
        XCTAssertEqual(b.calls["codex"], 1)
    }

    func testBackgroundGenerationRejectsLateCatalogAndAllowsRetry() async throws {
        let storage = try storage()
        let remote = CatalogTransport()
        remote.delayed = true
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote })
        await store.refreshMacStatus()
        let request = Task { await store.loadMacProjects(deviceID: "a", agent: .claude) }
        while remote.pending == nil { await Task.yield() }
        store.suspendHealthChecks()
        remote.complete()
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertTrue(store.sessions.isEmpty)
        remote.delayed = false
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 2)
        XCTAssertEqual(store.sessions.first?.title, "History")
    }

    func testHealthPublishesBeforeBackgroundCatalogAndReusesSuccessfulCache() async throws {
        let storage = try storage()
        let remote = CatalogTransport()
        remote.agents = [AgentInfo(id: "claude", name: "Claude", version: nil, status: "ready", validation: "verified")]
        remote.delayed = true
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote })
        // This must return while catalog RPC is still suspended.
        await store.refreshMacStatus()
        XCTAssertTrue(store.online)
        while remote.pending == nil { await Task.yield() }
        let sameLoad = Task { await store.loadMacProjects(deviceID: "a", agent: .claude) }
        await Task.yield()
        XCTAssertEqual(remote.calls["claude"], 1)
        remote.complete()
        await sameLoad.value
        await store.refreshMacStatus()
        await Task.yield()
        XCTAssertEqual(remote.calls["claude"], 1)
        XCTAssertEqual(store.sessions.first?.title, "History")
    }

    func testOlderRecordsDecodeAndFutureTimestampDoesNotSuppressRefresh() async throws {
        let storage = try storage()
        var saved = try storage.load()
        XCTAssertNil(saved.devices.first?.workspace.projectCatalogs)
        let clock = CacheClock()
        saved.devices[0].workspace.projectCatalogs = ["claude": ProjectCatalogCache(fetchedAt: clock.now.addingTimeInterval(3600), projects: [])]
        try storage.save(saved)
        let remote = CatalogTransport()
        remote.projects["claude"] = [project()]
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in remote }, catalogNow: { clock.now })
        await store.refreshMacStatus()
        await store.loadMacProjects(deviceID: "a", agent: .claude)
        XCTAssertEqual(remote.calls["claude"], 1)
        XCTAssertEqual(store.sessions.first?.title, "History")
    }
}

@MainActor
private final class CacheClock {
    var now = Date(timeIntervalSince1970: 1_793_493_600)
}

@MainActor
private final class CatalogTransport: DeviceTransport {
    var calls: [String: Int] = [:]
    var projects: [String: [MacProject]] = [:]
    var agents: [AgentInfo] = []
    var fail = false
    var delayed = false
    var pending: CheckedContinuation<Void, Never>?
    func connect() async -> ConnectionState { .connected }
    func reconnect() async -> ConnectionState { .connected }
    func disconnect() async {}
    func ping() async throws {}
    func listAgents() async throws -> [AgentInfo] { agents }
    func listAgentProjects(agentId: String) async throws -> [MacProject] {
        calls[agentId, default: 0] += 1
        if delayed { await withCheckedContinuation { pending = $0 } }
        if fail { throw CocoaError(.fileReadUnknown) }
        return projects[agentId] ?? []
    }
    func complete() { pending?.resume(); pending = nil }
}
