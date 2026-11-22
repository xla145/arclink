import XCTest
@testable import AgentBridge

@MainActor
final class ImportedHistoryContinuationTests: XCTestCase {
    private func message(_ role: String, _ text: String, phase: String? = nil) -> MacMessage {
        MacMessage(role: role, text: text, timestamp: nil, toolCallId: nil, toolName: nil, toolPhase: nil, toolFailed: nil, assistantPhase: phase)
    }

    private func continuation(_ messages: [MacMessage], provider: String = "claude") throws -> ImportedHistoryContinuation {
        try XCTUnwrap(ImportedHistoryContinuation(deviceID: "mac-a", projectPath: "/repo", provider: provider, threadID: "native", title: "Original", messages: messages))
    }

    func testCopiesOnlyPublicUserAndFinalAnswerTextForEitherProvider() throws {
        let source = [message("user", "request"), message("assistant", "private reasoning", phase: "analysis"),
                      message("assistant", "progress", phase: "commentary"), message("tool", "tool output"),
                      message("summary", "thinking summary"), message("assistant", "answer", phase: "final_answer")]
        for provider in ["claude", "codex"] {
            let history = try continuation(source, provider: provider)
            XCTAssertEqual(history.records.map(\.text), ["request", "answer"])
            XCTAssertEqual(history.records.map(\.role), ["user", "assistant"])
            XCTAssertEqual(history.provider, provider)
            XCTAssertFalse(history.truncated)
            let body = try history.message(request: "continue with tests")
            XCTAssertTrue(body.hasPrefix("当前请求：\ncontinue with tests"))
            XCTAssertFalse(body.contains("private reasoning"))
            XCTAssertFalse(body.contains("tool output"))
            XCTAssertFalse(body.contains("thinking summary"))
        }
        XCTAssertEqual(source[1].text, "private reasoning", "Original history stays untouched")
    }

    func testLegacyAnswersUseTheSameFinalSelectionAsHistoryRenderingAndDropImages() throws {
        let history = try continuation([message("user", "look ![图片](data:image/png;base64,aGVsbG8=)"),
                                        message("assistant", "earlier commentary"), message("assistant", "last answer")])
        XCTAssertEqual(history.records.map(\.text), ["look [图片未传递]", "last answer"])
        XCTAssertFalse(try history.message(request: "next").contains("base64"))
    }

    func testNewestHistoryIsBoundedByCountAndUTF8Bytes() throws {
        let many = (0..<120).map { message("user", "request-\($0)") }
        let history = try continuation(many)
        XCTAssertEqual(history.records.count, 80)
        XCTAssertEqual(history.records.first?.text, "request-40")
        XCTAssertEqual(history.records.last?.text, "request-119")
        XCTAssertTrue(history.truncated)
        let large = try continuation([message("user", String(repeating: "中文🙂", count: 20000))])
        XCTAssertLessThanOrEqual(large.records.reduce(0) { $0 + $1.text.utf8.count }, 32768)
        XCTAssertTrue(large.truncated)
        XCTAssertFalse(large.records[0].text.contains("�"))
    }

    func testOnlyToolOrPrivateRecordsCannotCreateAContinuation() {
        XCTAssertNil(ImportedHistoryContinuation(deviceID: "a", projectPath: "/repo", provider: "codex", threadID: "n", title: "No text", messages: [message("tool", "command"), message("assistant", "hidden", phase: "analysis")]))
    }

    func testUncertainTaskRoundTripRetainsExactContextPayloadAndIDs() throws {
        let history = try continuation([message("user", "before"), message("assistant", "answer")])
        let wireText = try history.message(request: "new request")
        var intent = PendingManagedTask(deviceID: history.deviceID, projectPath: history.projectPath, projectName: "Repo", provider: "codex", model: "chosen", text: wireText)
        intent.draftText = "new request"
        intent.history = history
        let restored = try JSONDecoder().decode(PendingManagedTask.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.text, wireText)
        XCTAssertEqual(restored.draftText, "new request")
        XCTAssertEqual(restored.history?.records, history.records)
        XCTAssertEqual(restored.history?.deviceID, restored.deviceID)
        XCTAssertEqual(restored.history?.projectPath, restored.projectPath)
        XCTAssertEqual(restored.provider, "codex", "Target Agent can differ from the source")
        XCTAssertEqual(restored.threadCommand, intent.threadCommand)
        XCTAssertEqual(restored.sendCommand, intent.sendCommand)
        XCTAssertEqual(restored.clientMessage, intent.clientMessage)
    }
}
