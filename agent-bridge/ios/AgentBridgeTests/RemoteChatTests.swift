import XCTest
import UIKit
@testable import AgentBridge

@MainActor
final class RemoteChatTests: XCTestCase {
    func testPublicProcessTimelineKeepsSourceOrderAndFinalOnlyAcrossReplay() async throws {
        let driver = RemoteChatFake()
        let (store, storage) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "request", images: [])
        driver.emit(.turnObserved(id: "t", completed: false))
        driver.emit(.assistantPhase(itemId: "comment", phase: "commentary"))
        driver.emit(.assistantCompleted(itemId: "comment", text: "checking"))
        let started = ChatExecutionStep(id: "tool", failed: nil, completed: false, title: "执行命令", input: "pwd")
        driver.emit(.executionStep(turnID: "t", step: started))
        driver.emit(.publicSummary(itemId: "summary", text: "public reasoning summary"))
        var completed = started
        completed.completed = true
        completed.failed = false
        completed.output = "/repo"
        driver.emit(.executionStep(turnID: "t", step: completed))
        driver.emit(.assistantPhase(itemId: "final", phase: "final_answer"))
        driver.emit(.assistantCompleted(itemId: "final", text: "result"))
        driver.emit(.executionStep(turnID: "t", step: started))
        driver.emit(.executionStep(turnID: "t", step: completed))
        driver.emit(.turnObserved(id: "t", completed: true))
        driver.emit(.turnCompleted(status: "completed", error: nil))
        let turn = ConversationTurn.live(store.messages)[1]
        XCTAssertEqual(turn.text, "result")
        XCTAssertEqual(turn.steps.map(\.title), ["过程说明", "执行命令", "思考摘要"])
        XCTAssertEqual(turn.steps.map(\.output), ["checking", "/repo", "public reasoning summary"])
        XCTAssertEqual(turn.steps[1].input, "pwd")
        XCTAssertEqual(store.messages.filter { $0.executionStep != nil }.count, 1)
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(ConversationTurn.live(restored.messages)[1].text, "result")
        XCTAssertEqual(ConversationTurn.live(restored.messages)[1].steps.map(\.output), turn.steps.map(\.output))
    }

    func testUnknownOldExecutionCannotBindPendingUserAndFailureEndsObservation() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "new", images: [])
        driver.emit(.executionStep(turnID: "old", step: ChatExecutionStep(id: "old-step", failed: true, completed: true)))
        XCTAssertNil(store.messages.first?.turnMetrics)
        driver.emit(.executionStep(turnID: "new", step: ChatExecutionStep(id: "actual", failed: false, completed: true)))
        driver.emit(.turnObserved(id: "new", completed: false))
        XCTAssertEqual(store.messages.first?.turnMetrics?.turnID, "new")
        XCTAssertEqual(store.messages.first?.turnMetrics?.steps.map(\.id), ["actual"])
        driver.emit(.assistantCompleted(itemId: "reply", text: "partial"))
        driver.emit(.failure(.unavailable("stopped")))
        XCTAssertTrue(store.messages.first?.turnMetrics?.finished == true)
        XCTAssertNil(store.messages.first?.turnMetrics?.completedAt)
        XCTAssertTrue(ConversationTurn.live(store.messages)[1].metricsText.hasPrefix("耗时 —"))
    }

    func testTurnMetricsPersistAndDoNotLeakAcrossUsers() async throws {
        let driver = RemoteChatFake()
        let (store, storage) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "First", images: [])
        driver.emit(.turnObserved(id: "one", completed: false))
        driver.emit(.executionStep(turnID: "one", step: ChatExecutionStep(id: "a", failed: true, completed: true)))
        driver.emit(.executionStep(turnID: "one", step: ChatExecutionStep(id: "a", failed: nil, completed: false)))
        driver.emit(.turnObserved(id: "one", completed: true))
        driver.emit(.assistantCompleted(itemId: "reply", text: "done"))
        driver.emit(.turnCompleted(status: "completed", error: nil))
        _ = await store.sendMessage(sessionId: "session", text: "Second", images: [])
        driver.emit(.turnObserved(id: "two", completed: false))
        driver.emit(.executionStep(turnID: "one", step: ChatExecutionStep(id: "a", failed: true, completed: true)))
        let users = store.messages.filter(\.isUser)
        XCTAssertEqual(users[0].turnMetrics?.steps.count, 1)
        XCTAssertEqual(users[1].turnMetrics?.steps.count, 0)
        XCTAssertNotNil(users[0].turnMetrics?.completedAt)
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(restored.messages.filter(\.isUser).map(\.turnMetrics), users.map(\.turnMetrics))
    }

    func testRejectedStartupCanChangeSettingsAndRetrySameConversation() async throws {
        let driver = RemoteChatFake()
        driver.startError = CodexChatError.rejected("Invalid model")
        let (store, _) = try fixture(a: driver)
        let first = await store.sendMessage(sessionId: "session", text: "Draft", images: [])
        XCTAssertFalse(first)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.canConfigureUnsentSession("session"))
        let options = ChatSessionOptions(model: "replacement", executionPolicy: .readOnly)
        XCTAssertTrue(store.configureUnsentSession("session", projectID: "project", options: options))
        driver.startError = nil
        let second = await store.sendMessage(sessionId: "session", text: "Draft", images: [])
        XCTAssertTrue(second)
        XCTAssertEqual(driver.configuredOptions, options)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertFalse(store.canConfigureUnsentSession("session"))
    }

    private func fixture(a: RemoteChatFake, b: RemoteChatFake? = nil, catalog: RemoteCatalogFake? = nil, previousProcessState: String = "exited") throws -> (AppStore, DeviceStorage) {
        let second = b ?? RemoteChatFake()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = DeviceStorage(directory: directory)
        func device(_ id: String) -> PairedMac {
            PairedMac(id: id, name: id, endpointID: String(repeating: id, count: 64), workspace: DeviceWorkspace(
                projects: [ProjectItem(id: "project", name: id, path: "/\(id)", agent: .codex)],
                sessions: [SessionItem(id: "session", projectId: "project", title: id, status: .done, detail: "Ready", source: .cli)]))
        }
        try storage.save(DeviceSnapshot(devices: [device("a"), device("b")], selectedDeviceID: "a"))
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in catalog ?? RemoteCatalogFake() }, chatFactory: { id in
            let bridge = RemoteProcessBridge(state: previousProcessState)
            return (id == "a" ? a : second, bridge)
        })
        return (store, storage)
    }

    func testFirstAndFollowingTurnsUseOneNativeThreadAndStreamIntoHistory() async throws {
        let driver = RemoteChatFake()
        let (store, storage) = try fixture(a: driver)
        let accepted = await store.sendMessage(sessionId: "session", text: "First", images: [])
        XCTAssertTrue(accepted)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["First"])
        XCTAssertEqual(store.messages.filter(\.isUser).map(\.text), ["First"])
        XCTAssertTrue(store.approvals.isEmpty)
        driver.emit(.assistantDelta(itemId: "one", text: "Hello "))
        driver.emit(.assistantDelta(itemId: "one", text: "world"))
        driver.emit(.assistantCompleted(itemId: "one", text: "Hello world"))
        driver.emit(.turnCompleted(status: "completed", error: nil))
        XCTAssertEqual(store.messages.filter { !$0.isUser }.map(\.text), ["Hello world"])
        XCTAssertEqual(store.sessions.first?.status, .done)
        let second = await store.sendMessage(sessionId: "session", text: "Second", images: [])
        XCTAssertTrue(second)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["First", "Second"])
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(restored.sessions.first?.codexThreadId, "native-thread")
        XCTAssertEqual(restored.sessions.first?.realProcessId, "process")
    }

    func testDefiniteStartupRejectionDoesNotInventReplyOrApproval() async throws {
        let driver = RemoteChatFake()
        driver.startError = CodexChatError.rejected("Codex 未登录")
        let (store, _) = try fixture(a: driver)
        let accepted = await store.sendMessage(sessionId: "session", text: "Keep draft", images: [])
        XCTAssertFalse(accepted)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.chatError(sessionId: "session"), "Codex 未登录")
    }

    func testDefiniteStartupFailureCanBeRetriedAfterCorrection() async throws {
        let driver = RemoteChatFake()
        driver.startError = CodexChatError.rejected("Codex 未登录")
        let (store, _) = try fixture(a: driver)
        let rejected = await store.sendMessage(sessionId: "session", text: "Keep draft", images: [])
        XCTAssertFalse(rejected)
        XCTAssertTrue(driver.sent.isEmpty)
        driver.startError = nil
        let accepted = await store.sendMessage(sessionId: "session", text: "Keep draft", images: [])
        XCTAssertTrue(accepted)
        XCTAssertEqual(driver.starts, 2)
        XCTAssertEqual(driver.closes, 1)
        XCTAssertEqual(driver.sent, ["Keep draft"])
        XCTAssertEqual(store.messages.filter(\.isUser).map(\.text), ["Keep draft"])
        XCTAssertNil(store.chatError(sessionId: "session"))
    }

    func testUnknownTurnDeliveryIsRetainedAndNeverAutomaticallyReplayed() async throws {
        let driver = RemoteChatFake()
        driver.sendError = CodexChatError.deliveryUnknown("发送结果未知，请检查 Mac")
        let (store, _) = try fixture(a: driver)
        let consumed = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        XCTAssertTrue(consumed)
        XCTAssertEqual(store.messages.filter(\.isUser).map(\.text), ["Once"])
        let retry = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        XCTAssertFalse(retry)
        XCTAssertEqual(driver.sent, ["Once"])
        XCTAssertTrue(store.approvals.isEmpty)
    }

    func testDeviceSwitchDuringStartRoutesAllResultsToOriginatingMac() async throws {
        let a = RemoteChatFake(), b = RemoteChatFake()
        a.delayStart = true
        let (store, _) = try fixture(a: a, b: b)
        let task = Task { await store.sendMessage(sessionId: "session", text: "A only", images: [], deviceID: "a") }
        while a.startContinuation == nil { await Task.yield() }
        store.selectDevice("b")
        a.completeStart()
        let accepted = await task.value
        XCTAssertTrue(accepted)
        a.emit(.assistantCompleted(itemId: "answer", text: "A answer"))
        a.emit(.turnCompleted(status: "completed", error: nil))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.sessions.first?.codexThreadId)
        XCTAssertEqual(b.starts, 0)
        store.selectDevice("a")
        XCTAssertEqual(store.messages.map(\.text), ["A only", "A answer"])
        XCTAssertEqual(store.sessions.first?.codexThreadId, "native-thread")
    }

    func testApprovalAndStopCallNativeDriverWithoutMockDecisions() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Task", images: [])
        driver.emit(.approval(CodexChatApproval(requestId: "wire-id", itemId: "tool", title: "运行命令",
                                              kind: "执行命令", target: "pwd", detail: "cwd: /a")))
        let id = try XCTUnwrap(store.approvals.first?.id)
        store.resolve(id, approved: true)
        while driver.decisions.isEmpty { await Task.yield() }
        await Task.yield()
        XCTAssertEqual(driver.decisions.first?.0, "wire-id")
        XCTAssertEqual(driver.decisions.first?.1, true)
        XCTAssertEqual(store.approvals.first?.approved, true)
        XCTAssertEqual(store.messages.count, 1)
        store.stopSession(id: "session")
        while driver.interrupts == 0 { await Task.yield() }
        driver.emit(.turnCompleted(status: "interrupted", error: nil))
        XCTAssertEqual(store.sessions.first?.status, .cancelled)
        XCTAssertFalse(store.isChatBusy(sessionId: "session"))
    }

    func testInvalidImagesAndRealOfflinePathNeverFallBackToSimulation() async throws {
        let driver = RemoteChatFake()
        let (store, storage) = try fixture(a: driver)
        let image = await store.sendMessage(sessionId: "session", text: "Image", images: [Data([1])])
        XCTAssertFalse(image)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertTrue(store.messages.isEmpty)
        let offline = AppStore(storage: storage, autoConnect: false)
        let accepted = await offline.sendMessage(sessionId: "session", text: "Offline", images: [])
        XCTAssertFalse(accepted)
        XCTAssertTrue(offline.messages.isEmpty)
        XCTAssertTrue(offline.approvals.isEmpty)
    }

    func testCatalogRefreshDoesNotDuplicateWritableNativeThread() async throws {
        let driver = RemoteChatFake(), catalog = RemoteCatalogFake()
        catalog.projects = [MacProject(path: "/a", lastSeen: nil, name: "a", threads: [
            MacThread(id: "native-thread", title: "Native title", updatedAt: nil, source: "cli")
        ])]
        let (store, _) = try fixture(a: driver, catalog: catalog)
        _ = await store.sendMessage(sessionId: "session", text: "Task", images: [])
        await store.refreshMacStatus()
        _ = await store.loadMacProjects(deviceID: "a", agent: .codex, force: true)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.id, "session")
        XCTAssertFalse(try XCTUnwrap(store.sessions.first).isReadOnly)
        XCTAssertEqual(store.sessions.first?.codexThreadId, "native-thread")
    }

    private func imageData(size: CGFloat = 600) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            UIColor.blue.setFill()
            context.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        }.pngData()!
    }

    private func waitUntil(timeout: TimeInterval = 4, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for asynchronous chat state")
                throw NSError(domain: "RemoteChatTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testImageOnlyTurnSendsValidBoundedJPEGAndPersistsExactlyThoseBytes() async throws {
        let driver = RemoteChatFake()
        let (store, storage) = try fixture(a: driver)
        let source = imageData(size: 2400)
        let accepted = await store.sendMessage(sessionId: "session", text: "", images: [source, source])
        XCTAssertTrue(accepted)
        let images = try XCTUnwrap(driver.sentImages.first)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(driver.sent, [""])
        XCTAssertLessThanOrEqual(images.reduce(0) { $0 + $1.count }, RemoteChatImage.maximumTotalBytes)
        for image in images {
            XCTAssertEqual(Array(image.prefix(2)), [0xff, 0xd8])
            XCTAssertLessThanOrEqual(image.count, RemoteChatImage.maximumBytes)
            let decoded = try XCTUnwrap(UIImage(data: image))
            XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 2048)
        }
        XCTAssertEqual(store.messages.first?.images, images)
        let restored = AppStore(storage: storage, autoConnect: false)
        XCTAssertEqual(restored.messages.first?.images, images)
        XCTAssertTrue(store.approvals.isEmpty)
    }

    func testRemoteImageLimitAndDefiniteRejectionPreserveUnsentState() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        let source = imageData()
        let tooMany = await store.sendMessage(sessionId: "session", text: "", images: Array(repeating: source, count: 5))
        XCTAssertFalse(tooMany)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertTrue(store.messages.isEmpty)
        driver.sendError = CodexChatError.rejected("图片被拒绝")
        let rejected = await store.sendMessage(sessionId: "session", text: "", images: [source])
        XCTAssertFalse(rejected)
        XCTAssertEqual(driver.sentImages.first?.count, 1)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.chatError(sessionId: "session"), "图片被拒绝")
    }

    func testForegroundReturnAutomaticallyRecoversSameDriverWithoutReplayingTurn() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        store.suspendHealthChecks()
        driver.emit(.recoveryNeeded(message: "连接中断"))
        await Task.yield()
        XCTAssertEqual(driver.recoveries, 0)
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        try await waitUntil { driver.recoveries == 1 && store.chatRecoveryLabel(sessionId: "session") == nil }
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["Once"])
        XCTAssertTrue(store.isChatBusy(sessionId: "session"))
        driver.emit(.assistantCompleted(itemId: "reply", text: "Recovered reply"))
        driver.emit(.turnCompleted(status: "completed", error: nil))
        XCTAssertFalse(store.isChatBusy(sessionId: "session"))
        XCTAssertEqual(store.messages.map(\.text), ["Once", "Recovered reply"])
    }

    func testHandshakeRecoveryDoesNotAllowSecondSendWhileOriginalStartupWaits() async throws {
        let driver = RemoteChatFake()
        driver.delayStart = true
        let (store, _) = try fixture(a: driver)
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        let first = Task { await store.sendMessage(sessionId: "session", text: "Original", images: []) }
        try await waitUntil { driver.startContinuation != nil }
        driver.emit(.recoveryNeeded(message: "初始化连接中断"))
        try await waitUntil { driver.recoveries == 1 && store.chatRecoveryLabel(sessionId: "session") == nil }
        XCTAssertTrue(store.isChatBusy(sessionId: "session"))
        let second = await store.sendMessage(sessionId: "session", text: "Must wait", images: [])
        XCTAssertFalse(second)
        driver.completeStart()
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["Original"])
    }

    func testRecoveryPreservesUnknownDeliveryFenceUntilNativeOutcomeSettles() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        driver.isDeliveryUncertain = true
        driver.emit(.recoveryNeeded(message: "发送结果待确认"))
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        try await waitUntil { driver.recoveries == 1 && store.chatRecoveryLabel(sessionId: "session") == nil }
        let retry = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        XCTAssertFalse(retry)
        XCTAssertEqual(driver.sent, ["Once"])
        XCTAssertNotNil(store.chatError(sessionId: "session"))
        driver.emit(.turnCompleted(status: "completed", error: nil))
        let next = await store.sendMessage(sessionId: "session", text: "Next", images: [])
        XCTAssertTrue(next)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["Once", "Next"])
    }

    func testRecoveryIsSingleFlightAndDeviceSwitchKeepsRepliesOnOriginatingMac() async throws {
        let a = RemoteChatFake(), b = RemoteChatFake()
        a.delayRecover = true
        let (store, _) = try fixture(a: a, b: b)
        _ = await store.sendMessage(sessionId: "session", text: "A only", images: [])
        a.emit(.recoveryNeeded(message: "连接中断"))
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        try await waitUntil { a.recoverContinuation != nil }
        store.retryChatConnection(sessionId: "session")
        store.selectDevice("b")
        a.completeRecover()
        try await waitUntil { a.recoveryState == .connected }
        a.emit(.assistantCompleted(itemId: "reply", text: "A recovered"))
        a.emit(.turnCompleted(status: "completed", error: nil))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(b.recoveries, 0)
        XCTAssertEqual(a.recoveries, 1)
        store.selectDevice("a")
        XCTAssertEqual(store.messages.map(\.text), ["A only", "A recovered"])
        XCTAssertEqual(a.starts, 1)
        XCTAssertEqual(a.sent, ["A only"])
    }

    func testBackgroundCancelsRecoveryGenerationAndLateResultCannotMarkItRestored() async throws {
        let driver = RemoteChatFake()
        driver.delayRecover = true
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        driver.emit(.recoveryNeeded(message: "连接中断"))
        store.reconnectIfNeeded()
        try await waitUntil { driver.recoverContinuation != nil }
        store.suspendHealthChecks()
        driver.completeRecover()
        try await waitUntil { driver.recoveryState == .connected }
        XCTAssertNotNil(store.chatRecoveryLabel(sessionId: "session"))
        XCTAssertFalse(store.isChatRecovering(sessionId: "session"))
        driver.delayRecover = false
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        try await waitUntil { driver.recoveries == 1 && store.chatRecoveryLabel(sessionId: "session") == nil }
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["Once"])
    }

    func testRecoveryRetryBudgetResetsOnForegroundEntryWithoutMutatingReplay() async throws {
        let driver = RemoteChatFake()
        driver.recoverError = CodexChatError.unavailable("网络不可达")
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Once", images: [])
        // Establish host health before the interrupted chat starts retrying, so
        // periodic healthy polls cannot reset the bounded retry budget.
        await store.refreshMacStatus()
        driver.emit(.recoveryNeeded(message: "连接中断"))
        store.reconnectIfNeeded()
        defer { store.suspendHealthChecks() }
        try await waitUntil(timeout: 12) { store.chatRecoveryLabel(sessionId: "session")?.contains("暂停") == true }
        XCTAssertEqual(driver.recoveries, 4)
        await store.refreshMacStatus()
        await Task.yield()
        XCTAssertEqual(driver.recoveries, 4)
        store.suspendHealthChecks()
        driver.recoverError = nil
        store.reconnectIfNeeded()
        try await waitUntil { driver.recoveries == 5 && store.chatRecoveryLabel(sessionId: "session") == nil }
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.sent, ["Once"])
        XCTAssertTrue(driver.decisions.isEmpty)
    }

    func testStoppingIdleChatDoesNotFenceFollowingMessages() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "First", images: [])
        driver.emit(.turnCompleted(status: "completed", error: nil))
        store.stopSession(id: "session")
        await Task.yield()
        XCTAssertEqual(driver.interrupts, 0)
        let next = await store.sendMessage(sessionId: "session", text: "Next", images: [])
        XCTAssertTrue(next)
        XCTAssertEqual(driver.sent, ["First", "Next"])
    }

    func testColdRestartChecksOldProcessBeforeResumingNativeThread() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver, previousProcessState: "running")
        store.sessions[0].realProcessId = "old-process"
        store.sessions[0].realGeneration = "old-generation"
        store.sessions[0].codexThreadId = "old-thread"
        let accepted = await store.sendMessage(sessionId: "session", text: "Do not duplicate", images: [])
        XCTAssertFalse(accepted)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertTrue(driver.sent.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.chatError(sessionId: "session")?.contains("仍在运行") == true)
    }

    func testColdRestartResumesEndedThreadAndRefusesSendIfNativeTurnAlreadyBusy() async throws {
        let driver = RemoteChatFake()
        driver.busyOnStart = true
        let (store, _) = try fixture(a: driver, previousProcessState: "lost")
        store.sessions[0].realProcessId = "old-process"
        store.sessions[0].realGeneration = "old-generation"
        store.sessions[0].codexThreadId = "old-thread"
        let accepted = await store.sendMessage(sessionId: "session", text: "Keep draft", images: [])
        XCTAssertFalse(accepted)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.resumedThreadIds.first!, "old-thread")
        XCTAssertTrue(driver.sent.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.isChatBusy(sessionId: "session"))
    }

    func testRemovingDeviceClosesDriverAndIgnoresLateEvents() async throws {
        let driver = RemoteChatFake()
        let (store, _) = try fixture(a: driver)
        _ = await store.sendMessage(sessionId: "session", text: "Task", images: [])
        store.removeDevice("a")
        driver.emit(.assistantCompleted(itemId: "late", text: "Late"))
        XCTAssertEqual(driver.closes, 1)
        XCTAssertEqual(store.selectedDeviceID, "b")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.devices.count, 1)
    }
}

@MainActor
private final class RemoteChatFake: CodexChatDriving {
    var onEvent: ((CodexChatEvent) -> Void)?
    var threadId: String?
    var starts = 0
    var sent: [String] = []
    var sentImages: [[Data]] = []
    var recoveryState: CodexChatRecoveryState = .connected
    var isTurnBusy = false
    var isDeliveryUncertain = false
    var recoveries = 0
    var recoverError: Error?
    var delayRecover = false
    var recoverContinuation: CheckedContinuation<Void, Never>?
    var resumedThreadIds: [String?] = []
    var busyOnStart = false
    var decisions: [(String, Bool)] = []
    var interrupts = 0
    var closes = 0
    var startError: Error?
    var sendError: Error?
    var delayStart = false
    var startContinuation: CheckedContinuation<Void, Never>?

    var configuredOptions: ChatSessionOptions?
    func configure(options: ChatSessionOptions) { configuredOptions = options }

    func start(bridge: BridgeConnection, operationId: String, cwd: String, threadId: String?) async throws -> AgentBridge.ProcessInfo {
        starts += 1
        resumedThreadIds.append(threadId)
        if delayStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startError { throw startError }
        self.threadId = threadId ?? "native-thread"
        emit(.thread(id: self.threadId!))
        if busyOnStart { emit(.turnStarted(id: "previous-turn")) }
        return AgentBridge.ProcessInfo(processId: "process", generation: "generation", agentId: "codex", state: "running", pid: nil, exitCode: nil)
    }
    func completeStart() { startContinuation?.resume(); startContinuation = nil }
    func send(text: String, images: [Data]) async throws {
        sent.append(text)
        sentImages.append(images)
        if let sendError { throw sendError }
        emit(.turnStarted(id: "turn-\(sent.count)"))
    }
    func interrupt() async throws { interrupts += 1 }
    func resolveApproval(requestId: String, approved: Bool) async throws { decisions.append((requestId, approved)) }
    func recover(bridge: BridgeConnection) async throws {
        recoveries += 1
        recoveryState = .recovering
        if delayRecover { await withCheckedContinuation { recoverContinuation = $0 } }
        if let recoverError { recoveryState = .recoveryNeeded; throw recoverError }
        recoveryState = .connected
        emit(.recovered)
    }
    func completeRecover() { recoverContinuation?.resume(); recoverContinuation = nil }
    func close() { closes += 1 }
    func emit(_ event: CodexChatEvent) {
        switch event {
        case .turnStarted: isTurnBusy = true
        case .turnCompleted: isTurnBusy = false; isDeliveryUncertain = false
        case .recoveryNeeded: recoveryState = .recoveryNeeded
        default: break
        }
        onEvent?(event)
    }
}

@MainActor
private final class RemoteCatalogFake: DeviceTransport {
    var projects: [MacProject] = []
    func connect() async -> ConnectionState { .connected }
    func reconnect() async -> ConnectionState { .connected }
    func disconnect() async {}
    func ping() async throws {}
    func listAgents() async throws -> [AgentInfo] { [] }
    func listAgentProjects(agentId: String) async throws -> [MacProject] { projects }
}

private final class RemoteProcessBridge: BridgeConnection, @unchecked Sendable {
    let previousState: String
    init(state: String) { previousState = state; super.init(noHandle: NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("Test fake has no native handle") }
    override func getProcessStatus(processId: String, generation: String) async throws -> AgentBridge.ProcessInfo {
        AgentBridge.ProcessInfo(processId: processId, generation: generation, agentId: "codex", state: previousState, pid: nil, exitCode: nil)
    }
}
