import XCTest
@testable import AgentBridge

final class UserMessageContentTests: XCTestCase {
    private let payload = #"[{"questionItemId":"private-id","question":"失败发生在哪一步？","answer":"进入某个项目查看对话"},{"question":"Codex 还是 Claude？","answer":"Codex"}]"#
    private func envelope(_ body: String) -> String {
        "<send_user_message_question_reply>\(body)</send_user_message_question_reply>"
    }

    func testKnownReplyBecomesOrderedQuestionsAndAnswersWithoutIDs() {
        XCTAssertEqual(UserMessageContent.parse(envelope(payload)), [.answers([
            UserQuestionAnswer(question: "失败发生在哪一步？", answer: "进入某个项目查看对话"),
            UserQuestionAnswer(question: "Codex 还是 Claude？", answer: "Codex")
        ])])
    }

    func testMixedTextMultipleBlocksAndDuplicateAnswersKeepSourceOrder() {
        let raw = "之前的正文\n" + envelope(payload) + "\n中间正文\n" + envelope(payload) + "\n最后正文"
        let result = UserMessageContent.parse(raw)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0], .text("之前的正文\n"))
        XCTAssertEqual(result[2], .text("\n中间正文\n"))
        XCTAssertEqual(result[4], .text("\n最后正文"))
        XCTAssertEqual(result[1], result[3])
        XCTAssertTrue(raw.contains("private-id")) // Presentation never rewrites source.
    }

    func testInlineAdjacentEnvelopeRemainsLiteralAfterRecognizedBlock() {
        let block = envelope(payload)
        let parsed = UserMessageContent.parse(block + block)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1], .text(block))
    }

    func testMalformedUnknownAndWrongTypedPayloadsStayExactText() {
        for body in ["broken", "[]", "{}", #"[{"question":"q","answer":7}]"#,
                     #"[{"question":"q","answer":"a","futureField":true}]"#,
                     #"[{"question":"q","answer":"a","questionItemId":1}]"#,
                     #"[{"question":"q"}]"#] {
            let raw = envelope(body)
            XCTAssertEqual(UserMessageContent.parse(raw), [.text(raw)])
        }
        let unknown = "<other_reply>\(payload)</other_reply>"
        XCTAssertEqual(UserMessageContent.parse(unknown), [.text(unknown)])
        let missingEnd = "<send_user_message_question_reply>" + payload
        XCTAssertEqual(UserMessageContent.parse(missingEnd), [.text(missingEnd)])
        let oversized = envelope(String(repeating: "x", count: 256 * 1024))
        XCTAssertEqual(UserMessageContent.parse(oversized), [.text(oversized)])
    }

    func testQuotedCodeAndIndentedExamplesRemainLiteral() {
        let block = envelope(payload)
        for raw in ["```json\n\(block)\n```", "~~~~\n\(block)\n~~~~", "`\(block)`",
                    "``\n\(block)\n``", "> \(block)", "    \(block)", "\t\(block)",
                    "```\n\(block)", "```\n    ```\n\(block)", "示例：\(block)"] {
            XCTAssertEqual(UserMessageContent.parse(raw), [.text(raw)])
        }
        let raw = "```text\n\(block)\n```\n" + block
        XCTAssertEqual(UserMessageContent.parse(raw).count, 2)
        XCTAssertEqual(UserMessageContent.parse(raw)[0], .text("```text\n\(block)\n```\n"))
    }

    func testEscapedMultilineAnswerPreservesContent() {
        let raw = envelope(#"[{"question":"q","answer":"第一行\n第二行 \"引用\""}]"#)
        XCTAssertEqual(UserMessageContent.parse(raw), [.answers([UserQuestionAnswer(question: "q", answer: "第一行\n第二行 \"引用\"")])])
    }

    @MainActor func testBothHistoryAndLiveKeepReplyAsUserBoundary() {
        let raw = envelope(payload)
        let live = [ChatMessage(id: "u", sessionId: "s", isUser: true, text: raw, imageData: nil, time: ""),
                    ChatMessage(id: "a", sessionId: "s", isUser: false, text: "final", imageData: nil, time: "")]
        let projected = ConversationTurn.live(live)
        XCTAssertTrue(projected[0].isUser)
        XCTAssertEqual(projected[0].text, raw)
        XCTAssertTrue(projected[0].steps.isEmpty)
        XCTAssertEqual(projected[1].text, "final")
        let history = [MacMessage(role: "user", text: raw, timestamp: nil, toolCallId: nil, toolName: nil, toolPhase: nil, toolFailed: nil, assistantPhase: nil)]
        XCTAssertEqual(ConversationTurn.history(history) { _ in "" }[0].text, raw)
        XCTAssertEqual(live[0].text, raw)
    }
}
