import XCTest
import UIKit
@testable import AgentBridge

@MainActor
final class ConversationTests: XCTestCase {
    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = DeviceStorage(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let workspace = DeviceWorkspace(projects: [
            ProjectItem(id: "claude-a", name: "A", path: "/a", agent: .claude),
            ProjectItem(id: "claude-b", name: "B", path: "/b", agent: .claude),
            ProjectItem(id: "codex-a", name: "C", path: "/c", agent: .codex)
        ])
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "mac", name: "Mac", endpointID: nil, workspace: workspace)], selectedDeviceID: "mac"))
        return AppStore(storage: storage, autoConnect: false)
    }

    func testNewConversationSettingsPersistAndLockAfterFirstMessage() throws {
        let store = try makeStore()
        let options = ChatSessionOptions(model: "fixture-model", executionPolicy: .readOnly)
        let id = store.createSession(projectId: "codex-a", title: "First", options: options)
        XCTAssertFalse(id.isEmpty)
        XCTAssertTrue(store.canConfigureUnsentSession(id))
        let row = try XCTUnwrap(store.sessions.first { $0.id == id })
        let decoded = try JSONDecoder().decode(SessionItem.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(decoded.chatOptions, options)
        let revised = ChatSessionOptions(model: nil, executionPolicy: .workspace)
        XCTAssertTrue(store.configureUnsentSession(id, projectID: "codex-a", options: revised))
        XCTAssertEqual(store.sessions.first { $0.id == id }?.chatOptions, revised)
        store.send(sessionId: id, text: "Start", image: nil)
        XCTAssertFalse(store.canConfigureUnsentSession(id))
        XCTAssertFalse(store.configureUnsentSession(id, projectID: "claude-a", options: options))
        XCTAssertEqual(store.sessions.first { $0.id == id }?.projectId, "codex-a")
    }

    func testLegacySessionSourceAndSingleImageStillDecode() throws {
        let json = #"{"id":"s","projectId":"p","title":"old","status":"已完成","detail":"Codex 对话"}"#
        let row = try JSONDecoder().decode(SessionItem.self, from: Data(json.utf8))
        XCTAssertEqual(row.source, .desktop)
        XCTAssertTrue(row.isReadOnly)
        let message = ChatMessage(id: "m", sessionId: "s", isUser: true, text: "", imageData: Data([1, 2]), time: "12:00")
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.images, [Data([1, 2])])
    }

    func testProjectSelectionScopedToAgentAndSessionCreation() throws {
        let store = try makeStore()
        store.selectProject("claude-a")
        XCTAssertEqual(store.currentProjectID, "claude-a")
        store.selectProject("codex-a")
        XCTAssertEqual(store.selectedAgent, .codex)
        store.selectedAgent = .claude
        XCTAssertEqual(store.currentProjectID, "claude-a")
        XCTAssertTrue(store.sessions.isEmpty)
        let id = store.createSession(projectId: "claude-b", title: "New")
        XCTAssertEqual(store.currentProjectID, "claude-b")
        XCTAssertEqual(store.sessions.first?.id, id)
        XCTAssertEqual(store.sessions.first?.projectId, "claude-b")
        XCTAssertEqual(store.sessions.first?.source, .cli)
        XCTAssertEqual(store.createSession(projectId: "missing", title: "No"), "")
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testReadonlyAndPermissionCannotReceiveLocalMessages() throws {
        let store = try makeStore()
        store.sessions = [SessionItem(id: "desktop", projectId: "claude-a", title: "Imported", status: .done, detail: "Codex 对话")]
        store.send(sessionId: "desktop", text: "Do not append", images: [])
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.approvals.isEmpty)
        store.permission = "仅查看"
        XCTAssertEqual(store.createSession(projectId: "claude-a", title: "No"), "")
        store.send(sessionId: "missing", text: "Do not append", images: [])
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testImportedCLIHistoryCannotBeMadeWritableByStopOrApproval() throws {
        let store = try makeStore()
        store.sessions = [SessionItem(id: "history", projectId: "claude-a", title: "CLI history",
                                     status: .done, detail: "Claude 对话", source: .cli)]
        store.approvals = [ApprovalItem(id: "stale", sessionId: "history", title: "Old approval",
                                       kind: "工具调用", target: "/a", detail: "Old", pending: true, approved: nil)]
        store.stopSession(id: "history")
        store.resolve("stale", approved: true)
        store.send(sessionId: "history", text: "Must not send", images: [])
        XCTAssertTrue(try XCTUnwrap(store.sessions.first).isReadOnly)
        XCTAssertEqual(store.sessions.first?.detail, "Claude 对话")
        XCTAssertEqual(store.sessions.first?.status, .done)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.approvals.first).pending)
    }

    func testMultiImageOnlySendRoundTripsAndEnforcesLimit() throws {
        let store = try makeStore()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()!
        XCTAssertTrue(ChatAttachment.isValid(image))
        XCTAssertNotNil(ChatAttachment.prepare(image))
        let id = store.createSession(projectId: "claude-a", title: "Images")
        store.send(sessionId: id, text: "", images: Array(repeating: image, count: 5))
        XCTAssertTrue(store.messages.isEmpty)
        store.send(sessionId: id, text: "", images: [image, image])
        let sent = try XCTUnwrap(store.messages.first)
        XCTAssertTrue(sent.isUser)
        XCTAssertEqual(sent.images.count, 2)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(restored.images, [image, image])
        XCTAssertFalse(ChatAttachment.isValid(Data("not an image".utf8)))
        XCTAssertFalse(ChatAttachment.isValid(Data(repeating: 0, count: ChatAttachment.maximumBytes + 1)))
    }
}
