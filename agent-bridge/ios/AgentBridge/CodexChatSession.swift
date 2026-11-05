import Foundation

enum CodexChatError: Error, LocalizedError, Equatable {
    case rejected(String)
    case deliveryUnknown(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message), .deliveryUnknown(let message), .unavailable(let message): message
        }
    }
}

struct CodexChatApproval: Equatable {
    let requestId: String
    let itemId: String
    let title: String
    let kind: String
    let target: String
    let detail: String
}

enum CodexChatEvent: Equatable {
    case thread(id: String)
    case turnStarted(id: String)
    case turnObserved(id: String, completed: Bool)
    case turnReconciled(id: String)
    case turnAssociated(id: String)
    case executionStep(turnID: String, step: ChatExecutionStep)
    case assistantPhase(itemId: String, phase: String)
    case publicSummary(itemId: String, text: String)
    case assistantDelta(itemId: String, text: String)
    case assistantCompleted(itemId: String, text: String)
    case turnCompleted(status: String, error: String?)
    case approval(CodexChatApproval)
    case approvalResolved(requestId: String)
    case failure(CodexChatError)
    case recoveryNeeded(message: String)
    case recovered
}

enum CodexChatRecoveryState: Equatable {
    case connected, recoveryNeeded, recovering, blocked
}

@MainActor
protocol CodexChatDriving: AnyObject {
    var onEvent: ((CodexChatEvent) -> Void)? { get set }
    var threadId: String? { get }
    var recoveryState: CodexChatRecoveryState { get }
    var isTurnBusy: Bool { get }
    var isDeliveryUncertain: Bool { get }
    func configure(options: ChatSessionOptions)
    func start(bridge: BridgeConnection, operationId: String, cwd: String, threadId: String?) async throws -> ProcessInfo
    func send(text: String, images: [Data]) async throws
    func recover(bridge: BridgeConnection) async throws
    func interrupt() async throws
    func resolveApproval(requestId: String, approved: Bool) async throws
    func close()
}

extension CodexChatDriving {
    func configure(options: ChatSessionOptions) {}
    var recoveryState: CodexChatRecoveryState { .connected }
    var isTurnBusy: Bool { false }
    var isDeliveryUncertain: Bool { false }
    func send(text: String) async throws { try await send(text: text, images: []) }
    func recover(bridge: BridgeConnection) async throws { throw CodexChatError.unavailable("这个会话无法恢复连接。") }
}

/// Codex 0.165.0 JSON-RPC over the Mac's existing authenticated, opaque AgentIO.
/// A driver owns one input lease. It never retries a write whose delivery is unknown.
@MainActor
final class CodexChatSession: CodexChatDriving {
    var onEvent: ((CodexChatEvent) -> Void)?
    private(set) var threadId: String?
    private(set) var recoveryState: CodexChatRecoveryState = .connected
    var isTurnBusy: Bool { turnBusy }
    var isDeliveryUncertain: Bool { uncertainTurn || !uncertainApprovals.isEmpty }
    private(set) var stdoutOffset: UInt64 = 0
    private(set) var stderrOffset: UInt64 = 0
    private(set) var attachmentEpoch = UUID()

    private enum State { case idle, initializing, ready, failed, closed }
    private struct Pending {
        var continuation: CheckedContinuation<[String: Any], Error>?
        let timeout: Task<Void, Never>
        let method: String
        let clientMessageId: String?
    }
    private struct Approval {
        let nativeId: Any
        var writing = false
    }

    private var options = ChatSessionOptions()
    func configure(options: ChatSessionOptions) {
        guard state == .idle else { return }
        self.options = options
    }

    private var state: State = .idle
    private var handle: IoHandle?
    private var callback: CodexIOCallback?
    private var reader: Task<Void, Never>?
    private var write: ((Data) async throws -> Void)?
    private var buffer = Data()
    private var nextRequest = 0
    private var pending: [String: Pending] = [:]
    private var approvals: [String: Approval] = [:]
    private var itemPreviews: [String: String] = [:]
    private var publicSummaries: [String: [Int: String]] = [:]
    private var activeTurnId: String?
    private var turnBusy = false
    private var terminalError: CodexChatError?
    private var process: ProcessInfo?
    private var leaseId = ""
    private var uncertainTurn = false
    private var uncertainApprovals: Set<String> = []
    private var submittedMessageId: String?
    private var completedTurnIds: Set<String> = []
    private var turnAckId: String?
    private var deferredRefusals: [[String: Any]] = []
    private let requestTimeout: TimeInterval
    private static let maximumLineBytes = 2 * 1024 * 1024
    private static let maximumInputBytes = 256 * 1024

    init(requestTimeout: TimeInterval = 60) { self.requestTimeout = requestTimeout }

    /// An injected byte writer exercises the same framing/RPC path as the live bridge.
    init(requestTimeout: TimeInterval = 60, write: @escaping (Data) async throws -> Void) {
        self.requestTimeout = requestTimeout
        self.write = write
    }

    func start(bridge: BridgeConnection, operationId: String, cwd: String, threadId: String?) async throws -> ProcessInfo {
        guard state == .idle else { throw CodexChatError.rejected("这个连接已经启动。") }
        let info = try await bridge.startProcess(operationId: operationId, agentId: "codex", cwd: cwd)
        guard state == .idle else { throw CodexChatError.unavailable("会话连接已关闭。") }
        process = info
        let epoch = beginAttachment()
        do {
            let callback = makeCallback(epoch: epoch)
            let handle = try await bridge.attachChatIo(processId: info.processId, generation: info.generation, callback: callback)
            guard attachmentEpoch == epoch, state == .idle else {
                handle.close()
                throw terminalError ?? CodexChatError.unavailable("会话连接已关闭。")
            }
            install(handle)
            try await initialize(cwd: cwd, threadId: threadId)
            return info
        } catch {
            if recoveryState == .recoveryNeeded || recoveryState == .recovering {
                // Keep the original process/lease. A lost startup reply is never reissued.
                throw error
            }
            close()
            _ = try? await bridge.stopProcess(operationId: UUID().uuidString, processId: info.processId, generation: info.generation)
            throw error
        }
    }

    func recover(bridge: BridgeConnection) async throws {
        if recoveryState == .connected, isDeliveryUncertain, write != nil {
            recoveryState = .recovering
            try await finishRecovery()
            return
        }
        guard recoveryState == .recoveryNeeded, state != .closed, state != .failed,
              let process, !leaseId.isEmpty else {
            throw terminalError ?? CodexChatError.unavailable("这个会话无法恢复，请检查 Mac 上的任务状态。")
        }
        recoveryState = .recovering
        let epoch = beginAttachment()
        do {
            let callback = makeCallback(epoch: epoch)
            let handle = try await bridge.resumeChatIo(processId: process.processId, generation: process.generation,
                stdoutOffset: stdoutOffset, stderrOffset: stderrOffset, previousLeaseId: leaseId, callback: callback)
            guard attachmentEpoch == epoch, state != .closed, state != .failed else {
                handle.close()
                throw terminalError ?? CodexChatError.unavailable("会话连接已关闭。")
            }
            install(handle)
            try await finishRecovery()
        } catch {
            if state == .failed || state == .closed { throw terminalError ?? error }
            if recoveryState == .recoveryNeeded || Self.isRecoverable(error) {
                suspendTransport("连接暂未恢复，正在等待 Mac。")
            } else {
                fail(transportFailure("无法恢复原来的进程或输出记录，请检查 Mac 上的任务状态。"))
            }
            throw error
        }
    }

    /// Test seam: replace only the physical byte writer; all RPC/turn state is retained.
    func recover(write: @escaping (Data) async throws -> Void) async throws {
        guard recoveryState == .recoveryNeeded, state != .closed, state != .failed else {
            throw terminalError ?? CodexChatError.unavailable("这个会话无法恢复。")
        }
        recoveryState = .recovering
        _ = beginAttachment()
        self.write = write
        try await finishRecovery()
    }

    private func finishRecovery() async throws {
        // Replayed acknowledgments can settle pending requests while this read is in flight.
        if let threadId, state == .ready {
            let thread = try await boundedSnapshot(threadId: threadId)
            reconcile(thread)
        }
        guard state != .closed, state != .failed, recoveryState == .recovering else {
            throw terminalError ?? CodexChatError.unavailable("恢复连接时再次断开。")
        }
        recoveryState = .connected
        if !isDeliveryUncertain { terminalError = nil }
        onEvent?(.recovered)
    }

    private func beginAttachment() -> UUID {
        attachmentEpoch = UUID()
        handle?.close()
        handle = nil
        callback?.finish()
        callback = nil
        reader?.cancel()
        reader = nil
        write = nil
        return attachmentEpoch
    }

    private func makeCallback(epoch: UUID) -> CodexIOCallback {
        let (stream, continuation) = AsyncStream<CodexIOEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let callback = CodexIOCallback(continuation: continuation)
        self.callback = callback
        reader = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, self.attachmentEpoch == epoch, self.state != .closed, self.state != .failed else { return }
                self.receive(event)
            }
            guard let self, self.attachmentEpoch == epoch, self.state != .closed, self.state != .failed else { return }
            self.suspendTransport("输出流中断，正在重新连接 Mac。")
        }
        return callback
    }

    private func install(_ handle: IoHandle) {
        self.handle = handle
        leaseId = handle.leaseId()
        write = { data in try await handle.writeStdin(data: data) }
        let refusals = deferredRefusals
        deferredRefusals.removeAll()
        for refusal in refusals { sendRefusal(refusal) }
    }

    /// Shared initialization used by the actual transport and protocol tests.
    func initialize(cwd: String, threadId: String?) async throws {
        guard state == .idle, write != nil else { throw CodexChatError.unavailable("未连接 Mac 上的 Codex。") }
        state = .initializing
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "arclink_ios", "title": "ArcLink", "version": "0.1.0"]
            ])
            try await sendObject(["method": "initialized", "params": [:]])
            var params: [String: Any] = ["cwd": cwd, "approvalPolicy": options.executionPolicy.approvalPolicy, "approvalsReviewer": "user", "sandbox": options.executionPolicy.sandbox]
            if let model = options.model, !model.isEmpty { params["model"] = model }
            let method: String
            if let threadId, !threadId.isEmpty {
                method = "thread/resume"
                params["threadId"] = threadId
                params["excludeTurns"] = true
            } else if let source = options.forkFromThreadId, !source.isEmpty {
                // A new thread carrying the source's history; the source is left untouched.
                method = "thread/fork"
                params["threadId"] = source
                params["excludeTurns"] = true
            } else { method = "thread/start" }
            let result = try await request(method, params: params)
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty else {
                throw CodexChatError.unavailable("Codex 没有返回有效的会话标识。")
            }
            guard state == .initializing else { throw terminalError ?? CodexChatError.unavailable("会话连接已关闭。") }
            self.threadId = id
            state = .ready
            onEvent?(.thread(id: id))
            if method == "thread/resume" { reconcile(try await boundedSnapshot(threadId: id)) }
        } catch {
            let failure = error as? CodexChatError ?? .unavailable("无法初始化 Mac 上的 Codex，请检查登录与项目路径。")
            // Once this coroutine unwinds there is no initializer left to continue.
            // In-flight requests may recover while awaited; failed writes are never replayed.
            fail(failure)
            throw failure
        }
    }

    /// Returns on the native turn/start acknowledgment; output continues through onEvent.
    func send(text: String, images: [Data]) async throws {
        guard state == .ready, recoveryState == .connected, !isDeliveryUncertain, let threadId else { throw terminalError ?? CodexChatError.unavailable("尚未恢复到 Codex，请等待连接与任务状态确认。") }
        guard !turnBusy else { throw CodexChatError.rejected("Codex 正在处理上一条消息，请等待完成或停止任务。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { throw CodexChatError.rejected("请输入消息或选择图片。") }
        guard text.utf8.count <= Self.maximumInputBytes else { throw CodexChatError.rejected("消息过长，请缩短后发送。") }
        guard images.count <= 4, images.allSatisfy({ !$0.isEmpty && $0.count <= 256 * 1024 && $0.starts(with: [0xFF, 0xD8]) }),
              images.reduce(0, { $0 + $1.count }) <= 1024 * 1024 else {
            throw CodexChatError.rejected("最多发送 4 张 JPEG 图片，每张需小于 256 KiB。")
        }
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        input += images.map { ["type": "image", "url": "data:image/jpeg;base64," + $0.base64EncodedString()] }
        let clientMessageId = UUID().uuidString
        // The native transcript persists this identifier, allowing read-only reconciliation.
        let params: [String: Any] = ["threadId": threadId, "clientUserMessageId": clientMessageId, "input": input]
        guard try Self.encode(["params": params]).count < Self.maximumLineBytes - 1024 else {
            throw CodexChatError.rejected("这条图文消息过大，请减少图片或文字。")
        }
        turnBusy = true
        uncertainTurn = false
        submittedMessageId = clientMessageId
        turnAckId = nil
        itemPreviews.removeAll()
        publicSummaries.removeAll()
        do {
            let result = try await request("turn/start", params: params)
            guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
                let error = CodexChatError.deliveryUnknown("Codex 已收到请求，但返回状态不完整。请检查 Mac 上的任务，勿重复发送。")
                fail(error)
                throw error
            }
            // A very short turn may complete before its RPC acknowledgment arrives.
            if turnBusy, activeTurnId == nil {
                activeTurnId = id
                onEvent?(.turnStarted(id: id))
                onEvent?(.turnObserved(id: id, completed: false))
            }
        } catch {
            if let failure = error as? CodexChatError, case .rejected = failure {
                turnBusy = false
                submittedMessageId = nil
            }
            throw error
        }
    }

    func interrupt() async throws {
        guard state == .ready, recoveryState == .connected, !isDeliveryUncertain, let threadId, let activeTurnId else {
            throw terminalError ?? CodexChatError.rejected("当前没有可停止的 Codex 任务。")
        }
        _ = try await request("turn/interrupt", params: ["threadId": threadId, "turnId": activeTurnId])
        // Only turn/completed is authoritative; the interrupt response is not completion.
    }

    func resolveApproval(requestId: String, approved: Bool) async throws {
        guard state == .ready, recoveryState == .connected, !isDeliveryUncertain, var approval = approvals[requestId], !approval.writing else {
            throw terminalError ?? CodexChatError.rejected("这条审批已失效或正在发送。")
        }
        approval.writing = true
        approvals[requestId] = approval
        do {
            // One decision only. Never grant session-wide or persistent rules implicitly.
            try await sendObject(["id": approval.nativeId, "result": ["decision": approved ? "accept" : "decline"]])
            // A local stream write is not native settlement. Keep the one-shot fence until
            // serverRequest/resolved or authoritative turn completion confirms the decision.
        } catch {
            let failure = CodexChatError.deliveryUnknown("审批结果是否送达未知，请检查 Mac 上的任务，勿重复批准。")
            uncertainApprovals.insert(requestId)
            terminalError = failure
            suspendTransport(failure.localizedDescription)
            throw failure
        }
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        recoveryState = .blocked
        attachmentEpoch = UUID()
        handle?.close()
        handle = nil
        callback?.finish()
        callback = nil
        reader?.cancel()
        reader = nil
        write = nil
        buffer.removeAll()
        finishPending(with: terminalError ?? .unavailable("会话连接已关闭。"))
    }

    func receiveStdout(_ data: Data, offset: UInt64? = nil, epoch: UUID? = nil) {
        guard epoch == nil || epoch == attachmentEpoch else { return }
        guard state != .closed, state != .failed else { return }
        guard let accepted = accept(data, offset: offset ?? stdoutOffset, channel: 1) else { return }
        buffer.append(accepted)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            guard line.count <= Self.maximumLineBytes else { fail(transportFailure("Codex 输出过大，连接已停止。")); return }
            let bytes = Data(line)
            buffer.removeSubrange(...newline)
            if bytes.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            do {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw CodexChatError.unavailable("Codex 输出格式无效。")
                }
                receiveObject(object)
                if state == .failed || state == .closed { return }
            } catch { fail(transportFailure("Codex 输出格式无效，请重新连接。")); return }
        }
        if buffer.count > Self.maximumLineBytes { fail(transportFailure("Codex 输出过大，连接已停止。")) }
    }

    func receiveGap() { fail(transportFailure("丢失了一段 Codex 输出，任务状态未知。请先检查 Mac，勿重复发送。")) }

    func receiveExit() { fail(transportFailure("Mac 上的 Codex 已退出，请重新连接。")) }

    func receiveTransportError(code: String = "network_error") {
        if ["network_error", "timeout", "disconnected", "unreachable"].contains(code) {
            suspendTransport("与 Mac 的连接中断，正在恢复原会话。")
        } else { fail(transportFailure("无法恢复原会话，请检查 Mac 上的任务状态。")) }
    }

    private func accept(_ data: Data, offset: UInt64, channel: Int) -> Data? {
        let next = channel == 1 ? stdoutOffset : stderrOffset
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow, offset <= next else { receiveGap(); return nil }
        guard end > next else { return Data() }
        let overlap = Int(next - offset)
        let accepted = Data(data.dropFirst(overlap))
        if channel == 1 { stdoutOffset = end } else { stderrOffset = end }
        return accepted
    }

    private func receive(_ event: CodexIOEvent) {
        switch event {
        case .stdout(let data, let offset): receiveStdout(data, offset: offset)
        case .stderr(let data, let offset): _ = accept(data, offset: offset, channel: 2)
        case .gap: receiveGap()
        case .exit: receiveExit()
        case .error(let code): receiveTransportError(code: code)
        }
    }

    private func receiveObject(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"], Self.idKey(id) != nil {
                receiveServerRequest(method, id: id, params: params)
            } else { receiveNotification(method, params: params) }
            return
        }
        guard let id = object["id"], let key = Self.idKey(id), let request = pending.removeValue(forKey: key) else { return }
        request.timeout.cancel()
        if object["error"] != nil {
            // Native RPC errors prove rejection. Do not expose arbitrary diagnostic payloads.
            if request.method == "turn/start", request.clientMessageId == submittedMessageId {
                uncertainTurn = false
                turnBusy = false
                submittedMessageId = nil
                if request.continuation == nil { onEvent?(.turnCompleted(status: "failed", error: "Codex 拒绝了这条消息。")) }
            }
            request.continuation?.resume(throwing: CodexChatError.rejected("Codex 拒绝了这次请求，请检查 Mac 上的登录、模型和项目配置。"))
        } else if let result = object["result"] as? [String: Any] {
            if request.method == "turn/start", request.clientMessageId == submittedMessageId,
               let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String {
                turnAckId = id
                uncertainTurn = false
                if !completedTurnIds.contains(id), activeTurnId == nil {
                    activeTurnId = id
                    turnBusy = true
                    onEvent?(.turnStarted(id: id))
                onEvent?(.turnObserved(id: id, completed: false))
                }
            }
            request.continuation?.resume(returning: result)
            notifySettlement()
        } else {
            let error = request.method == "turn/start"
                ? CodexChatError.deliveryUnknown("Codex 返回状态不完整，请检查 Mac 上的任务，勿重复发送。")
                : .unavailable("Codex 返回了无效响应。")
            request.continuation?.resume(throwing: error)
            fail(error)
        }
    }

    private func receiveNotification(_ method: String, params: [String: Any]) {
        // Child/subagent traffic must never mutate this conversation.
        guard let incomingThread = params["threadId"] as? String, incomingThread == threadId else { return }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            guard !completedTurnIds.contains(id) else { return }
            activeTurnId = id
            turnBusy = true
            onEvent?(.turnStarted(id: id))
            onEvent?(.turnObserved(id: id, completed: false))
        case "item/agentMessage/delta":
            guard belongsToActiveTurn(params), let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            onEvent?(.assistantDelta(itemId: id, text: delta))
        case "item/reasoning/summaryTextDelta":
            guard belongsToActiveTurn(params), let id = params["itemId"] as? String,
                  let index = params["summaryIndex"] as? Int, (0..<128).contains(index),
                  let delta = params["delta"] as? String else { return }
            publicSummaries[id, default: [:]][index, default: ""] += delta
            let parts = publicSummaries[id] ?? [:]
            onEvent?(.publicSummary(itemId: id, text: parts.keys.sorted().compactMap { parts[$0] }.joined(separator: "\n\n")))
        case "item/started", "item/completed":
            guard belongsToActiveTurn(params), let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            guard let turnID = params["turnId"] as? String else { return }
            projectPublicItem(item, id: id, turnID: turnID, completed: method == "item/completed")
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String,
                  activeTurnId == nil || activeTurnId == id else { return }
            let status = turn["status"] as? String ?? "failed"
            let error = status == "failed" ? "Codex 任务失败，请检查 Mac 上的登录、额度和模型配置。" : nil
            activeTurnId = nil
            turnBusy = false
            turnAckId = id
            completedTurnIds.insert(id)
            if completedTurnIds.count > 128 { completedTurnIds = [id] }
            uncertainTurn = false
            uncertainApprovals.removeAll()
            for key in approvals.keys { onEvent?(.approvalResolved(requestId: key)) }
            approvals.removeAll()
            onEvent?(.turnObserved(id: id, completed: true))
            onEvent?(.turnCompleted(status: status, error: error))
            notifySettlement()
        case "serverRequest/resolved":
            guard let nativeId = params["requestId"], let key = Self.idKey(nativeId), approvals.removeValue(forKey: key) != nil else { return }
            uncertainApprovals.remove(key)
            onEvent?(.approvalResolved(requestId: key))
            notifySettlement()
        case "error":
            // The server can recover transient model errors; await turn/completed when retrying.
            if params["willRetry"] as? Bool == false {
                onEvent?(.failure(.unavailable("Codex 返回错误，请检查 Mac 上的登录、网络和模型配置。")))
            }
        default: break // Only public assistant text is projected, never private reasoning.
        }
    }

    private func projectPublicItem(_ item: [String: Any], id: String, turnID: String, completed: Bool) {
            if item["type"] as? String == "agentMessage", let phase = Self.assistantPhase(item) {
                onEvent?(.assistantPhase(itemId: id, phase: phase))
            }
            if item["type"] as? String == "reasoning" {
                // Only the explicit public summary array; never raw/encrypted reasoning.
                if let parts = item["summary"] as? [String] {
                    onEvent?(.publicSummary(itemId: id, text: parts.joined(separator: "\n\n")))
                } else if !completed { onEvent?(.publicSummary(itemId: id, text: "")) }
            }
            if let step = ChatExecutionStep.native(item, completed: completed) {
                onEvent?(.executionStep(turnID: turnID, step: step))
            }
            if item["type"] as? String == "agentMessage", completed, let text = item["text"] as? String {
                onEvent?(.assistantCompleted(itemId: id, text: text))
            } else if item["type"] as? String == "fileChange", let changes = item["changes"] as? [[String: Any]], itemPreviews.count < 128 {
                itemPreviews[id] = String(changes.map { "\($0["path"] as? String ?? "")\n\($0["diff"] as? String ?? "")" }.joined(separator: "\n\n").prefix(16_384))
            }
    }

    private static func assistantPhase(_ item: [String: Any]) -> String? {
        for key in ["phase", "channel"] {
            switch item[key] as? String {
            case "commentary": return "commentary"
            case "final", "final_answer": return "final_answer"
            default: continue
            }
        }
        return nil
    }

    private func belongsToActiveTurn(_ params: [String: Any]) -> Bool {
        guard let id = params["turnId"] as? String else { return false }
        return turnBusy && (activeTurnId == nil || activeTurnId == id)
    }

    private func receiveServerRequest(_ method: String, id: Any, params: [String: Any]) {
        guard let key = Self.idKey(id) else { return }
        guard params["threadId"] as? String == threadId, belongsToActiveTurn(params),
              let itemId = params["itemId"] as? String,
              method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" else {
            // Unsupported requests are explicitly refused rather than hanging or auto-approving.
            let refusal: [String: Any] = ["id": id, "error": ["code": -32601, "message": "Unsupported request on this client"]]
            if write == nil {
                guard deferredRefusals.count < 32 else { fail(transportFailure("不支持的请求过多，请在 Mac 上检查任务。")); return }
                deferredRefusals.append(refusal)
            } else { sendRefusal(refusal) }
            return
        }
        guard approvals[key] == nil else { return }
        let command = method == "item/commandExecution/requestApproval"
        let target = command ? params["command"] as? String ?? "命令详情不可用" : params["grantRoot"] as? String ?? "项目文件"
        var detail = command ? "工作目录：\(params["cwd"] as? String ?? "未知")" : itemPreviews[itemId] ?? "Codex 未提供可显示的文件差异，请在 Mac 上确认。"
        if let reason = params["reason"] as? String { detail += "\n\n" + String(reason.prefix(4096)) }
        approvals[key] = Approval(nativeId: id)
        onEvent?(.approval(CodexChatApproval(requestId: key, itemId: itemId, title: command ? "运行命令" : "修改文件", kind: command ? "工具调用 · 执行命令" : "工具调用 · 写入文件", target: String(target.prefix(16_384)), detail: detail)))
    }

    private func sendRefusal(_ refusal: [String: Any]) {
        Task { @MainActor [weak self] in
            do { try await self?.sendObject(refusal) }
            catch { self?.suspendTransport("无法拒绝不支持的请求，请检查 Mac 上的任务。") }
        }
    }

    private func request(_ method: String, params: [String: Any], timeout overrideTimeout: TimeInterval? = nil) async throws -> [String: Any] {
        guard write != nil, state != .closed, state != .failed else { throw terminalError ?? CodexChatError.unavailable("会话连接已关闭。") }
        guard pending.count < 16 else { throw CodexChatError.unavailable("待确认的请求过多，请在 Mac 上检查任务。") }
        nextRequest += 1
        let id = "arclink-\(nextRequest)"
        let key = Self.idKey(id)!
        let data = try Self.encode(["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutSeconds = overrideTimeout ?? requestTimeout
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                guard let self, var request = self.pending[key], let continuation = request.continuation else { return }
                if self.state == .initializing {
                    self.fail(.unavailable("初始化 Codex 超时，请检查 Mac 上的状态后重新连接。"))
                    return
                }
                request.continuation = nil
                self.pending[key] = request // Retain correlation for a replayed acknowledgment.
                let failure: CodexChatError
                if method == "turn/start" || method == "turn/interrupt" {
                    self.uncertainTurn = true
                    failure = .deliveryUnknown("等待 Codex 响应超时，请检查 Mac 上的任务状态，勿重复发送。")
                } else { failure = .unavailable("核对 Codex 状态超时，请稍后恢复连接。") }
                self.terminalError = failure
                continuation.resume(throwing: failure)
                self.suspendTransport(failure.localizedDescription)
            }
            pending[key] = Pending(continuation: continuation, timeout: timeout, method: method, clientMessageId: params["clientUserMessageId"] as? String)
            let epoch = attachmentEpoch
            Task { @MainActor [weak self] in
                guard let self, self.pending[key] != nil else { return }
                do {
                    guard self.attachmentEpoch == epoch else { return }
                    guard let write = self.write else { throw CodexChatError.unavailable("会话连接已关闭。") }
                    try await write(data)
                } catch {
                    guard self.pending[key] != nil else { return }
                    if method == "turn/start" || method == "turn/interrupt" { self.uncertainTurn = true }
                    self.suspendTransport("发送时连接中断，正在恢复原会话；不会重复发送。")
                }
            }
        }
    }

    private func sendObject(_ object: [String: Any]) async throws {
        guard let write, state != .closed, state != .failed else { throw terminalError ?? CodexChatError.unavailable("会话连接已关闭。") }
        try await write(Self.encode(object))
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }

    private static func idKey(_ id: Any) -> String? {
        if let string = id as? String { return "s:" + string }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return "n:" + number.stringValue }
        return nil
    }

    private func transportFailure(_ message: String) -> CodexChatError {
        turnBusy ? .deliveryUnknown(message) : .unavailable(message)
    }

    private static func isRecoverable(_ error: Error) -> Bool {
        if case BridgeError.Failed(let code, _) = error {
            return ["network_error", "timeout", "disconnected", "unreachable"].contains(code)
        }
        if let error = error as? CodexChatError, case .deliveryUnknown = error { return true }
        return false
    }

    private func suspendTransport(_ message: String) {
        guard state != .closed, state != .failed else { return }
        let alreadyNeeded = recoveryState == .recoveryNeeded
        if turnAckId == nil, pending.values.contains(where: { $0.method == "turn/start" }) { uncertainTurn = true }
        for (key, approval) in approvals where approval.writing { uncertainApprovals.insert(key) }
        recoveryState = .recoveryNeeded
        _ = beginAttachment()
        // Keep partial bytes, offsets, native request IDs, approvals and active turn.
        if !alreadyNeeded { onEvent?(.recoveryNeeded(message: message)) }
    }

    private func notifySettlement() {
        if recoveryState == .connected, !isDeliveryUncertain, terminalError != nil {
            terminalError = nil
            onEvent?(.recovered)
        }
    }

    /// Bound every response to one turn/item instead of echoing all historical image URLs.
    private func boundedSnapshot(threadId: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(requestTimeout)
        func read(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexChatError.unavailable("核对 Codex 状态超时，请稍后重试。") }
            return try await request(method, params: params, timeout: remaining)
        }
        let result = try await read("thread/read", ["threadId": threadId, "includeTurns": false])
        guard var thread = result["thread"] as? [String: Any] else { throw CodexChatError.unavailable("Codex 没有返回可核对的任务状态。") }
        var turns: [[String: Any]]
        do {
            let page = try await read("thread/turns/list", ["threadId": threadId, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"])
            turns = page["data"] as? [[String: Any]] ?? []
        } catch let error as CodexChatError {
            // A new, not-yet-materialized thread has no pageable turns. Empty evidence
            // never confirms a pending send; reconcile keeps that outcome unknown.
            guard case .rejected = error else { throw error }
            turns = []
        }
        if let clientId = submittedMessageId, uncertainTurn, !turns.isEmpty,
           let turnId = turns[0]["id"] as? String {
            var cursor: String?
            var inspected: [[String: Any]] = []
            for _ in 0..<16 {
                var params: [String: Any] = ["threadId": threadId, "turnId": turnId, "limit": 1, "sortDirection": "asc"]
                if let cursor { params["cursor"] = cursor }
                let page = try await read("thread/items/list", params)
                let entries = page["data"] as? [[String: Any]] ?? []
                for entry in entries where entry["turnId"] as? String == turnId {
                    guard let item = entry["item"] as? [String: Any] else { continue }
                    // Only retain the identifier needed to correlate, never historical image bytes.
                    if item["type"] as? String == "userMessage" {
                        inspected.append(["type": "userMessage", "clientId": item["clientId"] as? String ?? ""])
                    }
                }
                if inspected.contains(where: { $0["clientId"] as? String == clientId }) { break }
                guard let next = page["nextCursor"] as? String, !next.isEmpty, next != cursor else { break }
                cursor = next
            }
            turns[0]["items"] = inspected
        }
        thread["turns"] = turns
        return thread
    }

    private func reconcile(_ thread: [String: Any]) {
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let runtimeStatus = (thread["status"] as? [String: Any])?["type"] as? String
        let matchingMessage = submittedMessageId.flatMap { clientId in
            turns.last { turn in
                (turn["items"] as? [[String: Any]] ?? []).contains { item in
                    item["type"] as? String == "userMessage" && item["clientId"] as? String == clientId
                }
            }
        }
        let knownTurn = turns.last { turn in
            guard let id = turn["id"] as? String else { return false }
            return id == activeTurnId || id == turnAckId
        }
        let active = turns.last { $0["status"] as? String == "inProgress" }
        let selected = matchingMessage ?? knownTurn ?? (submittedMessageId == nil ? active : nil)
        if let selected, let id = selected["id"] as? String, let status = selected["status"] as? String {
            uncertainTurn = false
            turnAckId = id
            onEvent?(.turnAssociated(id: id))
            for item in selected["items"] as? [[String: Any]] ?? [] {
                guard let itemID = item["id"] as? String else { continue }
                projectPublicItem(item, id: itemID, turnID: id, completed: item["status"] as? String != "inProgress")
            }
            if status == "inProgress" {
                activeTurnId = id
                turnBusy = true
                onEvent?(.turnStarted(id: id))
            } else if ["completed", "interrupted", "failed"].contains(status) {
                activeTurnId = nil
                turnBusy = false
                completedTurnIds.insert(id)
                uncertainApprovals.removeAll()
                for key in approvals.keys { onEvent?(.approvalResolved(requestId: key)) }
                approvals.removeAll()
                onEvent?(.turnReconciled(id: id))
                onEvent?(.turnCompleted(status: status, error: status == "failed" ? "Codex 任务失败，请在 Mac 上检查。" : nil))
            } else { uncertainTurn = true }
            if matchingMessage != nil {
                for (key, request) in pending where request.method == "turn/start" && request.clientMessageId == submittedMessageId {
                    pending.removeValue(forKey: key)
                    request.timeout.cancel()
                    request.continuation?.resume(returning: ["turn": selected])
                }
            }
            if ["completed", "interrupted", "failed"].contains(status) {
                for (key, request) in pending where request.method == "turn/interrupt" {
                    pending.removeValue(forKey: key)
                    request.timeout.cancel()
                    request.continuation?.resume(returning: [:])
                }
            }
        } else if runtimeStatus == "active" {
            // Runtime activity without a correlated turn is not permission to send again.
            turnBusy = true
            uncertainTurn = true
        } else if !uncertainTurn && activeTurnId == nil {
            turnBusy = false
        } else if turnBusy, selected == nil { uncertainTurn = true }
        // A different actor can start a later turn after our own correlated turn ended.
        // Preserve current runtime activity even when the earlier message is confirmed.
        if runtimeStatus == "active", let active, let id = active["id"] as? String,
           id != activeTurnId {
            activeTurnId = id
            turnBusy = true
            onEvent?(.turnStarted(id: id))
        } else if runtimeStatus == "active", active == nil {
            // Metadata and page reads are not atomic; an active flag with no visible
            // active turn cannot prove that sending another task is safe.
            turnBusy = true
            uncertainTurn = true
        }
        if isDeliveryUncertain {
            terminalError = .deliveryUnknown("连接已恢复，但上次发送或审批结果仍待确认。请在 Mac 上检查，勿重复发送。")
        }
    }

    private func fail(_ error: CodexChatError) {
        guard state != .failed, state != .closed else { return }
        state = .failed
        recoveryState = .blocked
        attachmentEpoch = UUID()
        terminalError = error
        handle?.close()
        handle = nil
        callback?.finish()
        callback = nil
        write = nil
        buffer.removeAll()
        finishPending(with: error)
        onEvent?(.failure(error))
    }

    private func finishPending(with error: CodexChatError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation?.resume(throwing: error)
        }
    }
}

private enum CodexIOEvent: Sendable {
    case stdout(Data, UInt64), stderr(Data, UInt64), gap, exit, error(String)
}

/// The bounded FIFO bridge prevents independent MainActor tasks from reordering bytes.
private final class CodexIOCallback: AgentIoCallback {
    let continuation: AsyncStream<CodexIOEvent>.Continuation
    init(continuation: AsyncStream<CodexIOEvent>.Continuation) { self.continuation = continuation }
    func finish() { continuation.finish() }
    private func emit(_ event: CodexIOEvent) {
        if case .dropped = continuation.yield(event) { continuation.finish() }
    }
    func onStdout(data: Data, cursor: UInt64, offset: UInt64) { emit(.stdout(data, offset)) }
    func onStderr(data: Data, cursor: UInt64, offset: UInt64) { emit(.stderr(data, offset)) }
    func onGap(affectedChannel: Int32, offset: UInt64, lostBytes: UInt64) { emit(.gap) }
    func onExit(exitCode: Int32?) { emit(.exit) }
    func onError(code: String, message: String) { emit(.error(code)) }
}
