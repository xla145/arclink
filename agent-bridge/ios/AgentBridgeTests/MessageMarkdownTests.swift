import XCTest
@testable import AgentBridge

final class MessageMarkdownTests: XCTestCase {
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
