import XCTest
@testable import AgentBridge

final class MessageMarkdownTests: XCTestCase {
    func testHistoricalStepsPairParallelCallsByIDAndRetainLegacyOutput() {
        func message(_ text: String, _ id: String? = nil, _ phase: String? = nil) -> MacMessage {
            MacMessage(role: "tool", text: text, timestamp: nil, toolCallId: id, toolName: nil, toolPhase: phase, toolFailed: nil, assistantPhase: nil)
        }
        let steps = MessageStep.history([
            message("A input", "a", "input"), message("B input", "b", "input"),
            message("B output", "b", "output"), message("A output", "a", "output"),
            message("legacy output"), message("orphan output", "missing", "output")
        ])
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps[0]?.input, "A input")
        XCTAssertEqual(steps[0]?.output, "A output")
        XCTAssertEqual(steps[1]?.output, "B output")
        XCTAssertNil(steps[2])
        XCTAssertNil(steps[4]?.input)
        XCTAssertEqual(steps[4]?.output, "legacy output")
        XCTAssertEqual(steps[5]?.output, "orphan output")
    }

    func testHistoricalStepPreviewDoesNotIncludeLongInputOrOutput() {
        let input = "Run checks\n" + String(repeating: "large input\n", count: 1000)
        let steps = MessageStep.history([
            MacMessage(role: "tool", text: input, timestamp: nil, toolCallId: "a", toolName: "exec", toolPhase: "input", toolFailed: nil, assistantPhase: nil)
        ])
        XCTAssertEqual(steps[0]?.summary, "Run checks")
        XCTAssertEqual(steps[0]?.input, input)
        XCTAssertNil(steps[0]?.output)
        XCTAssertLessThanOrEqual(MessageStep.preview(String(repeating: "x", count: 1000)).count, 121)
    }

    func testToolSummaryUsesArgumentExcerptInsteadOfRepeatedToolName() {
        let step = MessageStep.history([
            MacMessage(role: "tool", text: "Read\n\n```text\n{\n  \"path\": \"src/main.swift\"\n}\n```", timestamp: nil, toolCallId: "a", toolName: "Read", toolPhase: "input", toolFailed: nil, assistantPhase: nil)
        ])[0]
        XCTAssertEqual(step?.summary, "  \"path\": \"src/main.swift\"")
    }

    func testCodeFencesPreserveWhitespaceAndLongerInnerFence() {
        let blocks = MessageMarkdown.parse("before\n\n````swift\n  let x = 1\n```\n````\nafter")
        XCTAssertEqual(blocks, [.text("before"), .code(language: "swift", code: "  let x = 1\n```"), .text("after")])
    }

    func testUnclosedFencePreservesPartialStream() {
        XCTAssertEqual(MessageMarkdown.parse("~~~json\n{\"a\": 1"), [.code(language: "json", code: "{\"a\": 1")])
    }

    func testImagesPreserveSurroundingTextAndBalancedDestination() {
        XCTAssertEqual(MessageMarkdown.parse("before ![a screenshot](https://example.com/a(b).png) after"), [
            .text("before "), .image(alt: "a screenshot", source: "https://example.com/a(b).png"), .text(" after")])
        XCTAssertEqual(MessageMarkdown.parse("`![literal](https://example.com/a.png)`"), [.text("`![literal](https://example.com/a.png)`")])
        XCTAssertEqual(MessageMarkdown.parse("![broken](https://example.com/a.png"), [.text("![broken](https://example.com/a.png")])
    }

    func testTasksHeadingsQuotesAndTable() {
        let blocks = MessageMarkdown.parse("## Plan\n- [x] Done\n  - [ ] Next\n> Note\n> More\n\n| Name | Value |\n| :--- | ---: |\n| a | `x|y` |")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Plan"), .list(marker: "-", text: "Done", depth: 0, checked: true),
            .list(marker: "-", text: "Next", depth: 1, checked: false), .quote("Note\nMore"),
            .table(headers: ["Name", "Value"], rows: [["a", "`x|y`"]])])
    }

    func testLiteralHeadingHashesAndEscapedImageDestination() {
        XCTAssertEqual(MessageMarkdown.parse("# C#"), [.heading(level: 1, text: "C#")])
        XCTAssertEqual(MessageMarkdown.parse("## Heading ##"), [.heading(level: 2, text: "Heading")])
        XCTAssertEqual(MessageMarkdown.parse(#"![x](https://example.com/a\(1\).png)"#),
                       [.image(alt: "x", source: "https://example.com/a(1).png")])
    }

    func testConversationSnippetRemovesBlockAndInlineFormatting() {
        XCTAssertEqual(MessageMarkdown.snippet("## Plan\nKeep **retry** and `useQuery`."), "Plan Keep retry and useQuery.")
    }

    func testOnlyExplicitWebImagesAndSafeLinkSchemes() {
        for source in ["file:///private/test.png", "javascript:alert(1)", "data:text/html;base64,AA==", "https://user:pass@example.com/a.png", "/private/test.png"] {
            XCTAssertNil(MessageMarkdown.imageURL(source))
            XCTAssertNil(MessageMarkdown.imageData(source))
        }
        XCTAssertNotNil(MessageMarkdown.imageURL("https://example.com/a.png"))
        XCTAssertTrue(MessageMarkdown.safeLink(URL(string: "mailto:hello@example.com")!))
        XCTAssertFalse(MessageMarkdown.safeLink(URL(string: "agent-bridge://pair?token=123")!))
        XCTAssertEqual(MessageMarkdown.imageData("data:image/png;base64,AQID"), Data([1, 2, 3]))
    }
}
