import XCTest
@testable import AgentBridge

@MainActor
final class UnifiedProjectsTests: XCTestCase {
    func testRemovedAgentIsNotSelectableButOldRecordsStillDecode() throws {
        XCTAssertEqual(AgentKind.allCases.map(\.agentId), ["claude", "codex"])
        let oldAgent = try JSONDecoder().decode(AgentKind.self, from: Data("\"Herdr\"".utf8))
        XCTAssertFalse(oldAgent.installed)
        XCTAssertEqual(try JSONEncoder().encode(oldAgent), Data("\"Herdr\"".utf8))
    }

    func testSamePathGroupsProvidersWithoutChangingHistoryIDs() {
        let legacy = [
            ProjectItem(id: "codex", name: "Repo", path: "/repo", agent: .codex),
            ProjectItem(id: "claude", name: "Repo", path: "/repo", agent: .claude),
            ProjectItem(id: "other", name: "Repo", path: "/other", agent: .codex)
        ]
        let rows = AppStore.groupProjects(legacy: legacy, managed: [ManagedProject(id: "managed", canonicalRoot: "/repo", name: "Repo", createdAt: "now", updatedAt: "now")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.path == "/repo" }?.legacyIDs, ["codex", "claude"])
        XCTAssertEqual(rows.first { $0.path == "/repo" }?.managedID, "managed")
        XCTAssertEqual(rows.first { $0.path == "/other" }?.legacyIDs, ["other"])
    }

    func testUnifiedProjectOrderingIncludesManagedThreadActivity() {
        let legacy = [ProjectItem(id: "old", name: "Old", path: "/old", agent: .codex, createdAt: Date(timeIntervalSince1970: 100))]
        let managed = [ManagedProject(id: "managed", canonicalRoot: "/managed", name: "Managed", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-02-01T00:00:00Z")]
        let rows = AppStore.groupProjects(legacy: legacy, managed: managed)
        XCTAssertEqual(rows.map(\.path), ["/managed", "/old"])
    }

    private func managedThread(_ id: String, project: String = "managed", updatedAt: String, status: String = "idle") -> ManagedThread {
        ManagedThread(id: id, projectId: project, providerId: "claude", model: nil, title: id, cwd: "/repo", status: status, revision: "1", createdAt: "1970-01-01T00:00:01Z", updatedAt: updatedAt)
    }

    func testMixedConversationsShareOrderingSearchCountsAndStableIdentity() {
        let project = UnifiedProjectItem(name: "Repo", path: "/repo", legacyIDs: ["legacy"], managedID: "managed")
        let sessions = [SessionItem(id: "same", projectId: "legacy", title: "Legacy middle", status: .done, detail: "Codex 对话", createdAt: Date(timeIntervalSince1970: 20)),
                        SessionItem(id: "hidden", projectId: "other", title: "Other", status: .done, detail: "", createdAt: Date())]
        let threads = [managedThread("same", updatedAt: "1970-01-01T00:00:30Z", status: "active"),
                       managedThread("old", updatedAt: "1970-01-01T00:00:10Z"),
                       managedThread("other", project: "elsewhere", updatedAt: "2026-01-01T00:00:00Z")]
        let rows = AppStore.groupConversations(project: project, sessions: sessions, threads: threads)
        XCTAssertEqual(rows.map(\.title), ["same", "Legacy middle", "old"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertTrue(rows[0].isRunning)
        XCTAssertFalse(rows[1].isRunning)
        XCTAssertEqual(AppStore.groupConversations(project: project, sessions: sessions, threads: threads, query: "legacy").map(\.title), ["Legacy middle"])
        XCTAssertEqual(AppStore.groupConversations(project: project, sessions: sessions, threads: threads, query: "same").count, 1)
    }

    func testManagedThreadAndLegacyActivityBothInfluenceProjectOrder() {
        let legacy = [ProjectItem(id: "legacy", name: "Legacy", path: "/legacy", agent: .codex, createdAt: Date(timeIntervalSince1970: 1))]
        let managed = [ManagedProject(id: "managed", canonicalRoot: "/managed", name: "Managed", createdAt: "1970-01-01T00:00:01Z", updatedAt: "1970-01-01T00:00:01Z")]
        let session = SessionItem(id: "s", projectId: "legacy", title: "Recent", status: .done, detail: "Codex 对话", createdAt: Date(timeIntervalSince1970: 20))
        let threads = ["managed": [managedThread("t", updatedAt: "1970-01-01T00:00:30Z")]]
        XCTAssertEqual(AppStore.groupProjects(legacy: legacy, managed: managed, sessions: [session], threads: threads).first?.path, "/managed")
        var later = session; later.createdAt = Date(timeIntervalSince1970: 40)
        XCTAssertEqual(AppStore.groupProjects(legacy: legacy, managed: managed, sessions: [later], threads: threads).first?.path, "/legacy")
    }

    func testOldSessionRecordsDecodeWithoutAvailabilityFlag() throws {
        let row = SessionItem(id: "old", projectId: "p", title: "Old", status: .done, detail: "Claude 对话")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json.removeValue(forKey: "sourceUnavailable")
        let decoded = try JSONDecoder().decode(SessionItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.sourceUnavailable)
        XCTAssertTrue(decoded.isReadOnly)
    }

    func testUnifiedProjectsRemainDeviceScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = DeviceStorage(directory: directory)
        let a = DeviceWorkspace(projects: [ProjectItem(id: "a", name: "A", path: "/same", agent: .codex)])
        let b = DeviceWorkspace(projects: [ProjectItem(id: "b", name: "B", path: "/same", agent: .claude)])
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "a", name: "A", endpointID: nil, workspace: a), PairedMac(id: "b", name: "B", endpointID: nil, workspace: b)], selectedDeviceID: "a"))
        let store = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(store.unifiedProjects().first?.legacyIDs, ["a"])
        store.selectDevice("b")
        XCTAssertEqual(store.unifiedProjects().first?.legacyIDs, ["b"])
    }

    func testPendingTaskRoundTripRetainsDeviceAndAllMutationIDs() throws {
        let intent = PendingManagedTask(deviceID: "chosen-b", projectPath: "/repo", projectName: "Repo", provider: "claude", model: "fixture", text: "work")
        let restored = try JSONDecoder().decode(PendingManagedTask.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.deviceID, "chosen-b")
        XCTAssertEqual(restored.provider, "claude")
        XCTAssertEqual(restored.model, "fixture")
        XCTAssertEqual(restored.projectCommand, intent.projectCommand)
        XCTAssertEqual(restored.threadCommand, intent.threadCommand)
        XCTAssertEqual(restored.modelCommand, intent.modelCommand)
        XCTAssertEqual(restored.sendCommand, intent.sendCommand)
        XCTAssertEqual(restored.clientMessage, intent.clientMessage)
    }
}
