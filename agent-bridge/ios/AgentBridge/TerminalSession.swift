import Foundation

/// Drives one real Mac process for a session's terminal page: start/attach,
/// live stdout/stderr, stop. Owned by `TerminalView` for that view's
/// lifetime; `detach()` on `.onDisappear` so nothing keeps streaming once
/// the page is gone.
@MainActor
@Observable
final class TerminalSession {
    enum RunState: Equatable {
        case idle
        case starting
        case attaching
        case running
        case stopping
        case stopped(exitCode: Int32?)
        case failed(String)
    }

    var runState: RunState = .idle
    /// Real bytes only — kept separate from `TerminalView`'s mock replay so
    /// the two never interleave.
    var liveLines: [String] = []

    private var attachmentGeneration = UUID()
    private var handle: IoHandle?
    private var callback: TerminalCallback?

    /// `operation_id = session.id`: a repeat call (re-open the page, app
    /// restart) is idempotent on the Mac rather than spawning a second
    /// process. The Mac's own idempotency store may answer with a process
    /// that already exited — callers must not assume success means "freshly
    /// started and still running".
    func start(bridge: BridgeConnection, sessionId: String, agentId: String, cwd: String) async -> ProcessInfo? {
        runState = .starting
        do {
            let info = try await bridge.startProcess(operationId: sessionId, agentId: agentId, cwd: cwd)
            return info
        } catch let error as BridgeError {
            runState = .failed(Self.message(for: error))
            return nil
        } catch {
            runState = .failed("启动失败，请重试。")
            return nil
        }
    }

    func attach(bridge: BridgeConnection, processId: String, generation: String) async {
        detach()
        let generationID = attachmentGeneration
        runState = .attaching
        liveLines.removeAll()
        let callback = TerminalCallback(owner: self)
        self.callback = callback
        do {
            let handle = try await bridge.attachIo(processId: processId, generation: generation, callback: callback)
            guard attachmentGeneration == generationID, !Task.isCancelled else {
                handle.close()
                return
            }
            self.handle = handle
            runState = .running
        } catch let error as BridgeError {
            runState = .failed(Self.message(for: error))
        } catch {
            runState = .failed("无法连接这个进程的输出，请重试。")
        }
    }

    func stop(bridge: BridgeConnection, processId: String, generation: String) async {
        runState = .stopping
        do {
            let info = try await bridge.stopProcess(
                operationId: UUID().uuidString, processId: processId, generation: generation
            )
            runState = .stopped(exitCode: info.exitCode)
        } catch let error as BridgeError {
            runState = .failed(Self.message(for: error))
        } catch {
            runState = .failed("停止失败，请重试。")
        }
    }

    /// Ends the subscription without touching the Mac's process — call from
    /// `.onDisappear` (leaving the page) as well as before re-`attach`ing.
    func detach() {
        attachmentGeneration = UUID()
        handle?.close()
        handle = nil
        callback = nil
    }

    fileprivate func append(_ line: String) {
        liveLines.append(line)
    }

    private static func message(for error: BridgeError) -> String {
        if case .Failed(let code, let message) = error {
            return AppStore.localizedPairError(code: code, message: message)
        }
        return "操作失败，请重试。"
    }
}

/// UniFFI invokes these from a Rust-side background task, never the main
/// actor — every path must hop to `@MainActor` before touching `owner`'s
/// `@Observable` state. `weak` avoids a retain cycle (`IoHandle` holds this
/// callback on the Rust side for the stream's lifetime; `owner` holds the
/// `IoHandle`).
private final class TerminalCallback: AgentIoCallback {
    weak var owner: TerminalSession?

    init(owner: TerminalSession) {
        self.owner = owner
    }

    func onStdout(data: Data, cursor: UInt64, offset: UInt64) {
        let text = String(decoding: data, as: UTF8.self)
        Task { @MainActor [owner] in owner?.append(text) }
    }

    func onStderr(data: Data, cursor: UInt64, offset: UInt64) {
        let text = String(decoding: data, as: UTF8.self)
        Task { @MainActor [owner] in owner?.append("! \(text)") }
    }

    func onGap(affectedChannel: Int32, offset: UInt64, lostBytes: UInt64) {
        Task { @MainActor [owner] in owner?.append("# 丢失了一段输出（\(lostBytes) 字节）") }
    }

    func onExit(exitCode: Int32?) {
        Task { @MainActor [owner] in
            guard let owner else { return }
            owner.append("# 进程已退出" + (exitCode.map { "（exit code \($0)）" } ?? ""))
            owner.runState = .stopped(exitCode: exitCode)
        }
    }

    func onError(code: String, message: String) {
        Task { @MainActor [owner] in
            owner?.runState = .failed(AppStore.localizedPairError(code: code, message: message))
        }
    }
}
