import XCTest
@testable import AgentBridge

@MainActor
final class CodexChatSessionTests: XCTestCase {
    @MainActor
    private final class NativePeer {
        var driver: CodexChatSession!
        var writes: [[String: Any]] = []
        var turnCount = 0
        var acknowledgeTurns = true
        var rejectNextTurn = false
        var ignoreInitialize = false
        var snapshotTurns: [[String: Any]] = []
        var snapshotStatus = "idle"
        var includeSnapshotItems = false
        var failApprovalWrite = false

        func write(_ data: Data) async throws {
            let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            writes.append(message)
            if message["result"] != nil, failApprovalWrite { throw CodexChatError.unavailable("simulated dropped approval write") }
            guard let method = message["method"] as? String, let id = message["id"] else { return }
            switch method {
            case "initialize":
                if !ignoreInitialize { emit(["id": id, "result": [:]]) }
            case "thread/start", "thread/resume", "thread/read":
                let params = message["params"] as? [String: Any] ?? [:]
                let includeTurns = method == "thread/read" ? params["includeTurns"] as? Bool == true : method == "thread/resume" && params["excludeTurns"] as? Bool != true
                emit(["id": id, "result": ["thread": ["id": "thread-1", "status": ["type": snapshotStatus], "turns": includeTurns ? snapshotTurns : []]]])
            case "thread/turns/list":
                let turns = snapshotTurns.suffix(1).map { turn -> [String: Any] in
                    var turn = turn
                    if !includeSnapshotItems { turn["items"] = [[String: Any]]() }
                    return turn
                }
                emit(["id": id, "result": ["data": turns]])
            case "thread/items/list":
                let params = message["params"] as? [String: Any] ?? [:]
                let turnId = params["turnId"] as? String ?? ""
                let turn = snapshotTurns.last { $0["id"] as? String == turnId }
                let items = turn?["items"] as? [[String: Any]] ?? []
                let index = Int(params["cursor"] as? String ?? "0") ?? 0
                var result: [String: Any] = ["data": index < items.count ? [["turnId": turnId, "item": items[index]]] : []]
                if index + 1 < items.count { result["nextCursor"] = String(index + 1) }
                emit(["id": id, "result": result])
            case "turn/start":
                turnCount += 1
                let params = message["params"] as? [String: Any] ?? [:]
                snapshotStatus = "active"
                snapshotTurns = [["id": "turn-\(turnCount)", "status": "inProgress", "items": [["id": "user-\(turnCount)", "type": "userMessage", "clientId": params["clientUserMessageId"] as? String ?? ""]]]]
                if rejectNextTurn {
                    rejectNextTurn = false
                    emit(["id": id, "error": ["code": -32602, "message": "private diagnostic"]])
                } else if acknowledgeTurns {
                    emit(["id": id, "result": ["turn": ["id": "turn-\(turnCount)", "status": "inProgress"]]])
                }
            case "turn/interrupt": emit(["id": id, "result": [:]])
            default: break
            }
        }

        func emit(_ message: [String: Any], fragmented: Bool = false) {
            var data = try! JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(10)
            if fragmented { for byte in data { driver.receiveStdout(Data([byte])) } }
            else { driver.receiveStdout(data) }
        }

        func notification(_ method: String, _ params: [String: Any] = [:], thread: String = "thread-1") {
            var params = params
            params["threadId"] = thread
            emit(["method": method, "params": params])
        }

        func complete(status: String = "completed", turn: String? = nil) {
            snapshotStatus = "idle"
            if !snapshotTurns.isEmpty { snapshotTurns[snapshotTurns.count - 1]["status"] = status }
            notification("turn/completed", ["turn": ["id": turn ?? "turn-\(turnCount)", "status": status]])
        }
    }

    func testRecoveryProjectsProvidedPublicItemsInOrderWithoutInventingTiming() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/repo", threadId: nil)
        try await peer.driver.send(text: "request", images: [])
        peer.includeSnapshotItems = true
        peer.snapshotStatus = "idle"
        peer.snapshotTurns = [["id": "turn-1", "status": "completed", "items": [
            ["id": "c", "type": "agentMessage", "phase": "commentary", "text": "checking"],
            ["id": "t", "type": "commandExecution", "status": "completed", "command": "pwd", "aggregatedOutput": "/repo", "exitCode": 0],
            ["id": "s", "type": "reasoning", "summary": ["public"], "content": ["private"]],
            ["id": "f", "type": "agentMessage", "phase": "final_answer", "text": "result"]
        ]]]
        peer.driver.receiveTransportError()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.recover(write: { try await peer.write($0) })
        XCTAssertEqual(events.first, .turnAssociated(id: "turn-1"))
        let order = events.compactMap { event -> String? in
            switch event {
            case .assistantCompleted(let id, _): return id
            case .executionStep(_, let step): return step.id
            case .publicSummary(let id, let text): XCTAssertEqual(text, "public"); return id
            default: return nil
            }
        }
        XCTAssertEqual(order, ["c", "t", "s", "f"])
        XCTAssertFalse(events.contains { if case .turnObserved = $0 { return true }; return false })
        XCTAssertTrue(events.contains(.turnReconciled(id: "turn-1")))
        XCTAssertEqual(events.last, .recovered)
        peer.driver.close()
    }

    func testNativePhaseAndPublicSummaryEventsPreserveOrderWithoutPrivateReasoning() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/repo", threadId: nil)
        try await peer.driver.send(text: "check", images: [])
        events.removeAll()
        peer.notification("item/completed", ["turnId": "turn-1", "item": ["id": "c", "type": "agentMessage", "phase": "commentary", "text": "working"]])
        peer.notification("item/completed", ["turnId": "turn-1", "item": ["id": "s", "type": "reasoning", "summary": ["public"], "content": ["private"], "encryptedContent": "secret"]])
        peer.notification("item/completed", ["turnId": "turn-1", "item": ["id": "f", "type": "agentMessage", "phase": "final_answer", "text": "done"]])
        XCTAssertEqual(events, [.assistantPhase(itemId: "c", phase: "commentary"), .assistantCompleted(itemId: "c", text: "working"),
            .publicSummary(itemId: "s", text: "public"), .assistantPhase(itemId: "f", phase: "final_answer"), .assistantCompleted(itemId: "f", text: "done")])
        peer.driver.close()
    }

    func testExecutionEventsUseStructuredOutcomesAndIgnoreOtherTurns() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/repo", threadId: nil)
        try await peer.driver.send(text: "check", images: [])
        peer.notification("item/started", ["turnId": "turn-1", "item": ["id": "cmd", "type": "commandExecution"]])
        peer.notification("item/completed", ["turnId": "turn-1", "item": ["id": "cmd", "type": "commandExecution", "exitCode": 1, "status": "completed"]])
        peer.notification("item/completed", ["turnId": "other", "item": ["id": "wrong", "type": "commandExecution", "exitCode": 0]])
        let steps = events.compactMap { event -> ChatExecutionStep? in
            if case .executionStep(let turnID, let step) = event { XCTAssertEqual(turnID, "turn-1"); return step }
            return nil
        }
        XCTAssertEqual(steps, [ChatExecutionStep(id: "cmd", failed: nil, completed: false, title: "执行命令"), ChatExecutionStep(id: "cmd", failed: true, completed: true, title: "执行命令")])
        XCTAssertNil(ChatExecutionStep.native(["id": "reasoning", "type": "reasoning"], completed: true))
        XCTAssertNil(ChatExecutionStep.native(["id": "x", "type": "webSearch", "output": "error failed"], completed: true)?.failed)
        XCTAssertEqual(ChatExecutionStep.native(["id": "x", "type": "mcpToolCall", "status": "completed", "result": ["isError": true]], completed: true)?.failed, true)
        peer.driver.close()
    }

    func testSelectedModelAndExecutionPolicyReachNativeThreadStart() async throws {
        let cases: [(SessionExecutionPolicy, String, String)] = [
            (.readOnly, "read-only", "never"), (.workspace, "workspace-write", "on-request"),
            (.fullAccess, "danger-full-access", "never")
        ]
        for (policy, sandbox, approval) in cases {
            let peer = makePeer()
            peer.driver.configure(options: ChatSessionOptions(model: "fixture-model", executionPolicy: policy))
            try await peer.driver.initialize(cwd: "/repo", threadId: nil)
            let start = try XCTUnwrap(peer.writes.first { $0["method"] as? String == "thread/start" })
            let params = try XCTUnwrap(start["params"] as? [String: Any])
            XCTAssertEqual(params["model"] as? String, "fixture-model")
            XCTAssertEqual(params["sandbox"] as? String, sandbox)
            XCTAssertEqual(params["approvalPolicy"] as? String, approval)
            peer.driver.close()
        }
    }

    private func makePeer(timeout: TimeInterval = 1) -> NativePeer {
        let peer = NativePeer()
        peer.driver = CodexChatSession(requestTimeout: timeout, write: { [weak peer] data in
            try await peer?.write(data)
        })
        return peer
    }

    func testHandshakeCreatesThreadBeforeFirstTurnAndSendsRealTextInput() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        XCTAssertEqual(peer.writes.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/start"])
        let startParams = try XCTUnwrap(peer.writes.last?["params"] as? [String: Any])
        XCTAssertEqual(startParams["cwd"] as? String, "/project")
        XCTAssertEqual(startParams["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(startParams["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(startParams["approvalsReviewer"] as? String, "user")
        XCTAssertEqual(events, [.thread(id: "thread-1")])
        try await peer.driver.send(text: "第一条消息")
        let params = try XCTUnwrap(peer.writes.last?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(params["input"] as? [[String: String]])
        XCTAssertEqual(input, [["type": "text", "text": "第一条消息"]])
        XCTAssertEqual(events.last, .turnObserved(id: "turn-1", completed: false))
        peer.driver.close()
    }

    func testResumeDoesNotReplayOldInput() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: "thread-1")
        XCTAssertEqual(peer.writes.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/resume", "thread/read", "thread/turns/list"])
        let params = try XCTUnwrap(peer.writes.first(where: { $0["method"] as? String == "thread/resume" })?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["excludeTurns"] as? Bool, true)
        XCTAssertEqual(peer.turnCount, 0)
        peer.driver.close()
    }

    func testFragmentedUTF8AndFinalMessageStayPublicAndScopedToThread() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "Hello")
        peer.emit(["method": "item/agentMessage/delta", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "answer", "delta": "你好 🌏"]], fragmented: true)
        peer.notification("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "child", "delta": "wrong thread"], thread: "child-thread")
        peer.notification("item/reasoning/textDelta", ["turnId": "turn-1", "itemId": "secret", "delta": "private reasoning"])
        peer.notification("item/completed", ["turnId": "turn-1", "item": ["id": "answer", "type": "agentMessage", "text": "你好 🌏"]])
        peer.complete()
        XCTAssertEqual(events, [.thread(id: "thread-1"), .turnStarted(id: "turn-1"), .turnObserved(id: "turn-1", completed: false), .assistantDelta(itemId: "answer", text: "你好 🌏"), .assistantCompleted(itemId: "answer", text: "你好 🌏"), .turnObserved(id: "turn-1", completed: true), .turnCompleted(status: "completed", error: nil)])
        peer.driver.close()
    }

    func testConcurrentTurnIsRejectedUntilAuthoritativeCompletion() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "one")
        do { try await peer.driver.send(text: "two"); XCTFail("must reject concurrent turn") }
        catch { guard case .rejected = error as? CodexChatError else { return XCTFail("wrong error: \(error)") } }
        XCTAssertEqual(peer.turnCount, 1)
        peer.complete()
        try await peer.driver.send(text: "two")
        XCTAssertEqual(peer.turnCount, 2)
        peer.driver.close()
    }

    func testExplicitNativeRejectionAllowsCorrectedSendWithoutLeakingDiagnostics() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.rejectNextTurn = true
        do { try await peer.driver.send(text: "one"); XCTFail("native rejection expected") }
        catch {
            guard case .rejected(let message) = error as? CodexChatError else { return XCTFail("wrong error") }
            XCTAssertFalse(message.contains("private diagnostic"))
        }
        try await peer.driver.send(text: "corrected")
        XCTAssertEqual(peer.turnCount, 2)
        peer.driver.close()
    }

    func testLostAcknowledgmentIsUnknownAndNeverAutomaticallyRetried() async throws {
        let peer = makePeer(timeout: 0.03)
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.acknowledgeTurns = false
        do { try await peer.driver.send(text: "one"); XCTFail("timeout expected") }
        catch { guard case .deliveryUnknown = error as? CodexChatError else { return XCTFail("wrong error") } }
        do { try await peer.driver.send(text: "one"); XCTFail("unknown delivery must fence writer") }
        catch { guard case .deliveryUnknown = error as? CodexChatError else { return XCTFail("wrong error") } }
        XCTAssertEqual(peer.turnCount, 1)
        peer.driver.close()
    }

    func testGapDuringTaskFencesFutureWrites() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "one")
        peer.driver.receiveGap()
        guard case .failure(.deliveryUnknown) = events.last else { return XCTFail("gap should be visible as unknown") }
        do { try await peer.driver.send(text: "two"); XCTFail("must fence") } catch {}
        XCTAssertEqual(peer.turnCount, 1)
        peer.driver.close()
    }

    func testInitializeTimeoutAndExitReleasePendingRequest() async throws {
        let peer = makePeer(timeout: 0.03)
        peer.ignoreInitialize = true
        do { try await peer.driver.initialize(cwd: "/project", threadId: nil); XCTFail("must timeout") }
        catch { guard case .unavailable = error as? CodexChatError else { return XCTFail("wrong error") } }
        let second = makePeer()
        second.ignoreInitialize = true
        let task = Task { try await second.driver.initialize(cwd: "/project", threadId: nil) }
        await Task.yield()
        second.driver.receiveExit()
        do { try await task.value; XCTFail("must stop waiting on exit") } catch {}
        peer.driver.close()
        second.driver.close()
    }

    func testApprovalKeepsNativeIDAndOnlySendsExplicitOneTimeDecision() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "run a command")
        peer.emit(["id": 42, "method": "item/commandExecution/requestApproval", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "cmd", "command": "pwd", "cwd": "/project", "startedAtMs": 1]])
        guard case .approval(let approval) = events.last else { return XCTFail("approval missing") }
        XCTAssertEqual(approval.target, "pwd")
        XCTAssertTrue(approval.detail.contains("/project"))
        XCTAssertFalse(peer.writes.contains { $0["result"] != nil })
        try await peer.driver.resolveApproval(requestId: approval.requestId, approved: true)
        let response = try XCTUnwrap(peer.writes.last)
        XCTAssertEqual(response["id"] as? Int, 42)
        XCTAssertEqual((response["result"] as? [String: String])?["decision"], "accept")
        do { try await peer.driver.resolveApproval(requestId: approval.requestId, approved: true); XCTFail("duplicate approval") } catch {}
        peer.driver.close()
    }

    func testFileApprovalShowsActualDiffAndRejectsOnce() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "edit")
        peer.notification("item/started", ["turnId": "turn-1", "item": ["id": "file", "type": "fileChange", "changes": [["path": "/project/a", "diff": "-old\n+new"]]]])
        peer.emit(["id": "approval-file", "method": "item/fileChange/requestApproval", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "file", "startedAtMs": 1]])
        guard case .approval(let approval) = events.last else { return XCTFail("approval missing") }
        XCTAssertTrue(approval.detail.contains("-old\n+new"))
        try await peer.driver.resolveApproval(requestId: approval.requestId, approved: false)
        XCTAssertEqual(peer.writes.last?["id"] as? String, "approval-file")
        XCTAssertEqual((peer.writes.last?["result"] as? [String: String])?["decision"], "decline")
        peer.driver.close()
    }

    func testUnsupportedServerRequestFailsClosed() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "ask")
        peer.emit(["id": "unsupported", "method": "item/tool/requestUserInput", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "input"]])
        for _ in 0..<5 { await Task.yield() }
        let response = try XCTUnwrap(peer.writes.last)
        XCTAssertEqual(response["id"] as? String, "unsupported")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertFalse(events.contains { if case .approval = $0 { return true }; return false })
        peer.driver.close()
    }

    func testInterruptUsesActiveTurnAndWaitsForCompletionEvent() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "task")
        try await peer.driver.interrupt()
        XCTAssertEqual(peer.writes.last?["method"] as? String, "turn/interrupt")
        XCTAssertEqual(peer.writes.last?["params"] as? [String: String], ["threadId": "thread-1", "turnId": "turn-1"])
        XCTAssertFalse(events.contains { if case .turnCompleted = $0 { return true }; return false })
        peer.complete(status: "interrupted")
        XCTAssertEqual(events.last, .turnCompleted(status: "interrupted", error: nil))
        peer.driver.close()
    }

    func testMalformedAndOversizeOutputFailVisibly() async throws {
        for data in [Data("{bad json}\n".utf8), Data(repeating: 65, count: 2 * 1024 * 1024 + 1)] {
            let peer = makePeer()
            var events: [CodexChatEvent] = []
            peer.driver.onEvent = { events.append($0) }
            try await peer.driver.initialize(cwd: "/project", threadId: nil)
            peer.driver.receiveStdout(data)
            guard case .failure(.unavailable) = events.last else { return XCTFail("invalid output must fail") }
            peer.driver.close()
        }
    }

    func testImagesAreRealBoundedDataURLInputsAndImageOnlyTurnIsSupported() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        let image = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        try await peer.driver.send(text: "", images: [image])
        let params = try XCTUnwrap(peer.writes.last?["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: String]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"], "image")
        XCTAssertEqual(input[0]["url"], "data:image/jpeg;base64," + image.base64EncodedString())
        XCTAssertFalse((params["clientUserMessageId"] as? String ?? "").isEmpty)
        peer.complete()
        try await peer.driver.send(text: "Look", images: [image, image])
        let mixed = try XCTUnwrap((peer.writes.last?["params"] as? [String: Any])?["input"] as? [[String: String]])
        XCTAssertEqual(mixed.map { $0["type"] }, ["text", "image", "image"])
        peer.driver.close()
    }

    func testInvalidOrOversizeImagesRejectBeforeAnyNativeTurnWrite() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        let small = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let large = Data([0xFF, 0xD8]) + Data(repeating: 0, count: 256 * 1024)
        for images in [[Data()], [Data([1, 2])], [large], Array(repeating: small, count: 5)] {
            do { try await peer.driver.send(text: "image", images: images); XCTFail("invalid attachment must reject") }
            catch { guard case .rejected = error as? CodexChatError else { return XCTFail("wrong rejection") } }
        }
        XCTAssertEqual(peer.turnCount, 0)
        peer.driver.close()
    }

    func testRecoveryPreservesPartialUTF8OffsetsAndIgnoresOldAttachmentCallbacks() async throws {
        let peer = makePeer()
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "hello")
        let line = Data("{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"answer\",\"delta\":\"你好\"}}\n".utf8)
        let split = try XCTUnwrap(line.firstIndex(of: 0xE4)) + 1 // Split the first Chinese scalar.
        let start = peer.driver.stdoutOffset
        peer.driver.receiveStdout(Data(line.prefix(split)), offset: start)
        let checkpoint = peer.driver.stdoutOffset
        let oldEpoch = peer.driver.attachmentEpoch
        peer.driver.receiveTransportError()
        XCTAssertEqual(peer.driver.recoveryState, .recoveryNeeded)
        XCTAssertEqual(peer.driver.stdoutOffset, checkpoint)
        peer.driver.receiveStdout(Data("stale\n".utf8), offset: checkpoint, epoch: oldEpoch)
        XCTAssertEqual(peer.driver.stdoutOffset, checkpoint)
        var replayed = false
        try await peer.driver.recover(write: { data in
            if !replayed {
                replayed = true
                // Include an overlapping prefix to prove byte clipping is exact.
                peer.driver.receiveStdout(Data(line.dropFirst(split - 1)), offset: checkpoint - 1)
            }
            try await peer.write(data)
        })
        XCTAssertEqual(peer.driver.recoveryState, .connected)
        XCTAssertEqual(events.filter { if case .assistantDelta = $0 { return true }; return false }, [.assistantDelta(itemId: "answer", text: "你好")])
        XCTAssertEqual(peer.turnCount, 1)
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        peer.driver.close()
    }

    func testPendingTurnAcknowledgmentSurvivesReattachWithoutResendingTurn() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.acknowledgeTurns = false
        let send = Task { try await peer.driver.send(text: "once") }
        while peer.turnCount == 0 { await Task.yield() }
        let request = try XCTUnwrap(peer.writes.last)
        let requestID = try XCTUnwrap(request["id"])
        peer.driver.receiveTransportError()
        var ackReplayed = false
        try await peer.driver.recover(write: { data in
            if !ackReplayed {
                ackReplayed = true
                peer.emit(["id": requestID, "result": ["turn": ["id": "turn-1", "status": "inProgress"]]])
            }
            try await peer.write(data)
        })
        try await send.value
        XCTAssertEqual(peer.turnCount, 1)
        XCTAssertEqual(peer.writes.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(peer.writes.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertTrue(peer.driver.isTurnBusy)
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        peer.driver.close()
    }

    func testTimedOutTurnIsReconciledByNativeClientMessageIDWithoutReplay() async throws {
        let peer = makePeer(timeout: 0.03)
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.acknowledgeTurns = false
        do { try await peer.driver.send(text: "once"); XCTFail("lost ack expected") }
        catch { guard case .deliveryUnknown = error as? CodexChatError else { return XCTFail("wrong error") } }
        XCTAssertTrue(peer.driver.isDeliveryUncertain)
        peer.snapshotStatus = "idle"
        peer.snapshotTurns[0]["status"] = "completed"
        var items = try XCTUnwrap(peer.snapshotTurns[0]["items"] as? [[String: Any]])
        items.append(["id": "answer", "type": "agentMessage", "text": "done"])
        peer.snapshotTurns[0]["items"] = items
        var events: [CodexChatEvent] = []
        peer.driver.onEvent = { events.append($0) }
        try await peer.driver.recover(write: { try await peer.write($0) })
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        XCTAssertFalse(peer.driver.isTurnBusy)
        XCTAssertEqual(peer.turnCount, 1)
        XCTAssertTrue(events.contains(.turnCompleted(status: "completed", error: nil)))
        XCTAssertEqual(events.last, .recovered)
        peer.driver.close()
    }

    func testReadOnlySnapshotSettlesStillPendingSendWhenNoAcknowledgmentWasReplayed() async throws {
        let peer = makePeer(timeout: 0.2)
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.acknowledgeTurns = false
        let send = Task { try await peer.driver.send(text: "exactly once") }
        while peer.turnCount == 0 { await Task.yield() }
        peer.driver.receiveTransportError()
        peer.snapshotStatus = "idle"
        peer.snapshotTurns[0]["status"] = "completed"
        try await peer.driver.recover(write: { try await peer.write($0) })
        try await send.value
        XCTAssertFalse(peer.driver.isTurnBusy)
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        try await Task.sleep(for: .seconds(0.25))
        XCTAssertEqual(peer.driver.recoveryState, .connected)
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        XCTAssertEqual(peer.turnCount, 1)
        peer.driver.close()
    }

    func testUncorrelatedSnapshotNeverMakesUnknownDeliverySendable() async throws {
        let peer = makePeer(timeout: 0.03)
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        peer.acknowledgeTurns = false
        do { try await peer.driver.send(text: "once"); XCTFail("lost ack expected") } catch {}
        peer.snapshotTurns = [["id": "some-other-turn", "status": "completed", "items": [["type": "userMessage", "clientId": "different-message"]]]]
        peer.snapshotStatus = "idle"
        try await peer.driver.recover(write: { try await peer.write($0) })
        XCTAssertTrue(peer.driver.isDeliveryUncertain)
        do { try await peer.driver.send(text: "duplicate"); XCTFail("unknown delivery must remain fenced") } catch {}
        XCTAssertEqual(peer.turnCount, 1)
        peer.driver.close()
    }

    func testUnknownApprovalIsNeverReplayedAndResolvedEventCanConfirmIt() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "command")
        var approval: CodexChatApproval?
        peer.driver.onEvent = { if case .approval(let item) = $0 { approval = item } }
        peer.emit(["id": 42, "method": "item/commandExecution/requestApproval", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "cmd", "command": "pwd", "cwd": "/project", "startedAtMs": 1]])
        let item = try XCTUnwrap(approval)
        peer.failApprovalWrite = true
        do { try await peer.driver.resolveApproval(requestId: item.requestId, approved: true); XCTFail("write outcome unknown") } catch {}
        XCTAssertTrue(peer.driver.isDeliveryUncertain)
        peer.failApprovalWrite = false
        var replayed = false
        try await peer.driver.recover(write: { data in
            if !replayed {
                replayed = true
                peer.notification("serverRequest/resolved", ["requestId": 42])
            }
            try await peer.write(data)
        })
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        XCTAssertEqual(peer.writes.filter { $0["result"] != nil }.count, 1)
        peer.driver.close()
    }

    func testResumedActiveThreadCannotStartAnotherTurn() async throws {
        let peer = makePeer()
        peer.snapshotStatus = "active"
        peer.snapshotTurns = [["id": "already-running", "status": "inProgress", "items": []]]
        try await peer.driver.initialize(cwd: "/project", threadId: "thread-1")
        XCTAssertTrue(peer.driver.isTurnBusy)
        do { try await peer.driver.send(text: "duplicate task"); XCTFail("active native task must block send") } catch {}
        XCTAssertEqual(peer.turnCount, 0)
        peer.driver.close()
    }

    func testOffsetGapIsPermanentAndDoesNotSkipLostBytes() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        let checkpoint = peer.driver.stdoutOffset
        peer.driver.receiveStdout(Data("{}\n".utf8), offset: checkpoint + 3)
        XCTAssertEqual(peer.driver.recoveryState, .blocked)
        XCTAssertEqual(peer.driver.stdoutOffset, checkpoint)
        peer.driver.close()
    }

    func testFailedInitializedNotificationNeverClaimsStartupRecovered() async throws {
        let peer = makePeer()
        peer.driver = CodexChatSession(requestTimeout: 1, write: { data in
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if message?["method"] as? String == "initialized" {
                peer.driver.receiveTransportError()
                throw CodexChatError.unavailable("simulated notification write failure")
            }
            try await peer.write(data)
        })
        do { try await peer.driver.initialize(cwd: "/project", threadId: nil); XCTFail("startup must fail") } catch {}
        XCTAssertEqual(peer.driver.recoveryState, .blocked)
        do { try await peer.driver.recover(write: { try await peer.write($0) }); XCTFail("initializer cannot be replayed") } catch {}
        XCTAssertFalse(peer.writes.contains { $0["method"] as? String == "thread/start" })
        peer.driver.close()
    }

    func testRecoveryDoesNotHydratePreviousImageHistory() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "latest")
        let latest = peer.snapshotTurns[0]
        let imageURL = "data:image/jpeg;base64," + String(repeating: "A", count: 1_400_000)
        peer.snapshotTurns = (0..<3).map { index in
            ["id": "old-\(index)", "status": "completed", "items": [["type": "userMessage", "clientId": "old-message-\(index)", "content": [["type": "image", "url": imageURL]]]]]
        } + [latest]
        peer.driver.receiveTransportError()
        try await peer.driver.recover(write: { try await peer.write($0) })
        XCTAssertEqual(peer.driver.recoveryState, .connected)
        XCTAssertFalse(peer.driver.isDeliveryUncertain)
        let reads = peer.writes.filter { $0["method"] as? String == "thread/read" }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual((reads[0]["params"] as? [String: Any])?["includeTurns"] as? Bool, false)
        let page = try XCTUnwrap(peer.writes.first { $0["method"] as? String == "thread/turns/list" })
        XCTAssertEqual((page["params"] as? [String: Any])?["itemsView"] as? String, "notLoaded")
        XCTAssertEqual((page["params"] as? [String: Any])?["limit"] as? Int, 1)
        XCTAssertFalse(peer.writes.contains { $0["method"] as? String == "thread/items/list" })
        peer.driver.close()
    }

    func testActiveRuntimeWithUncorrelatedLatestTurnRemainsFenced() async throws {
        let peer = makePeer()
        try await peer.driver.initialize(cwd: "/project", threadId: nil)
        try await peer.driver.send(text: "ours")
        peer.driver.receiveTransportError()
        peer.snapshotStatus = "active"
        peer.snapshotTurns.append(["id": "another-actor-turn", "status": "inProgress", "items": []])
        try await peer.driver.recover(write: { try await peer.write($0) })
        XCTAssertTrue(peer.driver.isTurnBusy)
        do { try await peer.driver.send(text: "duplicate"); XCTFail("active other turn must block send") } catch {}
        XCTAssertEqual(peer.turnCount, 1)
        peer.driver.close()
    }
}
