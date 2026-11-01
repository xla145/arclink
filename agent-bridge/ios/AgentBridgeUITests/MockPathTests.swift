import UIKit
import XCTest

/// UI fixtures use a fresh DEBUG-only storage directory for every run.
/// These exercise local presentation, not a live Mac/Agent connection.
final class MockPathTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.agentbridge.ios")
    }

    func testLightPaths() throws { try runPaths(theme: "浅色") }
    func testDarkPaths() throws { try runPaths(theme: "深色") }

    func testStepsHeaderExpandsAcrossEntireRow() throws {
        try launchFixture(theme: "浅色")
        XCTAssertTrue(app.buttons["project-p1"].waitForExistence(timeout: 10))
        app.buttons["project-p1"].tap()
        app.buttons["session-s-rich"].tap()
        let steps = disclosure("工具步骤 · 2 项")
        reveal(steps, swipeUp: false)
        let summary = app.staticTexts["先检查数据请求，再保留错误重试入口。"]
        XCTAssertFalse(summary.exists)
        // Exercise the title and the empty middle, rather than only the chevron.
        steps.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Read: src/Dashboard.tsx"].exists)
        shot("浅色", "steps-expanded")
        steps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(summary.exists)
        steps.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
    }

    func testReadableUserQuestionReplies() throws { try exerciseUserQuestionReplies(theme: "浅色") }
    func testDarkReadableUserQuestionReplies() throws { try exerciseUserQuestionReplies(theme: "深色") }

    private func exerciseUserQuestionReplies(theme: String) throws {
        let raw = """
        补充一点：
        <send_user_message_question_reply>[{"questionItemId":"internal-question-1","question":"失败发生在哪一步？","answer":"进入某个项目查看对话"},{"questionItemId":"internal-question-2","question":"Codex 还是 Claude？","answer":"Codex"}]</send_user_message_question_reply>
        请继续排查。
        """
        try launchFixture(theme: theme, history: [
            ["role": "user", "text": raw], ["role": "assistant", "text": "收到，我会检查项目对话加载。", "assistantPhase": "final_answer"]
        ])
        XCTAssertTrue(app.buttons["project-p1"].waitForExistence(timeout: 10))
        app.buttons["project-p1"].tap()
        app.buttons["session-s-desktop"].tap()
        let firstQuestion = app.staticTexts["失败发生在哪一步？"]
        XCTAssertTrue(firstQuestion.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["补充信息"].exists)
        let firstAnswer = app.staticTexts["进入某个项目查看对话"]
        let secondQuestion = app.staticTexts["Codex 还是 Claude？"]
        let secondAnswer = app.staticTexts["Codex"]
        XCTAssertTrue(firstAnswer.exists && secondQuestion.exists && secondAnswer.exists)
        XCTAssertLessThan(firstQuestion.frame.minY, firstAnswer.frame.minY)
        XCTAssertLessThan(firstAnswer.frame.minY, secondQuestion.frame.minY)
        XCTAssertLessThan(secondQuestion.frame.minY, secondAnswer.frame.minY)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "补充一点：")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请继续排查。")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "send_user_message_question_reply")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "internal-question")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具步骤")).firstMatch.exists)
        shot(theme, "user-question-replies")
    }

    func testImportedAssistantFragmentsShareOneReplyCard() throws { try exerciseMergedReply(theme: "浅色") }
    func testDarkMergedReplySummary() throws { try exerciseMergedReply(theme: "深色") }
    func testLargeTextMergedReplySummary() throws { try exerciseMergedReply(theme: "浅色", largeText: true) }

    private func exerciseMergedReply(theme: String, largeText: Bool = false) throws {
        try launchFixture(theme: theme, history: [
            ["role": "user", "text": "检查项目", "timestamp": "2026-11-01T12:00:00Z"],
            ["role": "assistant", "text": "开始检查。", "timestamp": "2026-11-01T12:00:01Z"],
            ["role": "tool", "text": "工具结果", "toolFailed": "false", "timestamp": "2026-11-01T12:00:02Z"],
            ["role": "assistant", "text": "检查完成。", "timestamp": "2026-11-01T12:00:03Z"]
        ], largeText: largeText)
        XCTAssertTrue(app.buttons["project-p1"].waitForExistence(timeout: 10))
        app.buttons["project-p1"].tap()
        app.buttons["session-s-desktop"].tap()
        XCTAssertTrue(app.buttons["复制回复的 Markdown"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "复制回复的 Markdown").count, 1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "开始检查。")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检查完成。")).firstMatch.exists)
        let process = disclosure("工具步骤 · 2 项")
        XCTAssertTrue(process.exists)
        if !largeText {
            app.buttons["复制回复的 Markdown"].tap()
            // The host test command checks the simulator pasteboard after this
            // tap; reading it from another iOS app requires a blocking OS prompt.
            XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 3))
            process.tap()
            let commentary = app.buttons["history-commentary-1"]
            let tool = app.buttons["history-step-2"]
            XCTAssertTrue(commentary.exists && tool.exists)
            XCTAssertLessThan(commentary.frame.minY, tool.frame.minY)
            process.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["turn-metrics"].exists)
        if largeText {
            shot(theme, "merged-turn-large-header")
            reveal(app.descendants(matching: .any)["turn-metrics"], swipeUp: true)
            // The combined accessibility element can be hittable while its lower
            // values are below the viewport. Capture the footer at the end too.
            for _ in 0..<2 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.7))
                    .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25)))
            }
        }
        shot(theme, largeText ? "merged-turn-large-text" : "merged-turn-metrics")
    }

    func testImportedStepsShowSummariesThenCorrelatedInputAndOutput() throws {
        try exerciseImportedSteps(theme: "浅色")
    }

    func testDarkImportedStepDetails() throws {
        try exerciseImportedSteps(theme: "深色")
    }

    private func exerciseImportedSteps(theme: String) throws {
        try launchFixture(theme: theme, history: [
            ["role": "user", "text": "检查项目"],
            ["role": "summary", "text": "先检查项目，再读取文件。"],
            ["role": "tool", "text": "检查项目\nINPUT_DETAIL_A", "toolCallId": "a", "toolName": "检查命令", "toolPhase": "input"],
            ["role": "tool", "text": "读取文件\nINPUT_DETAIL_B", "toolCallId": "b", "toolName": "读取文件", "toolPhase": "input"],
            ["role": "tool", "text": "OUTPUT_DETAIL_B", "toolCallId": "b", "toolPhase": "output"],
            ["role": "tool", "text": "OUTPUT_DETAIL_A", "toolCallId": "a", "toolPhase": "output"],
            ["role": "assistant", "text": "检查完成。"]
        ])
        XCTAssertTrue(app.buttons["project-p1"].waitForExistence(timeout: 10))
        app.buttons["project-p1"].tap()
        app.buttons["session-s-desktop"].tap()
        let steps = disclosure("工具步骤 · 3 项")
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        reveal(steps, swipeUp: false)
        steps.tap()
        let first = app.buttons["history-step-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["history-step-3"].exists)
        XCTAssertFalse(app.staticTexts["OUTPUT_DETAIL_A"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "INPUT_DETAIL_A")).firstMatch.exists)
        shot(theme, "imported-step-summaries")
        first.tap()
        XCTAssertTrue(app.navigationBars["检查命令"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["输入"].exists)
        XCTAssertTrue(app.staticTexts["输出"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "INPUT_DETAIL_A")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["OUTPUT_DETAIL_A"].exists)
        XCTAssertFalse(app.staticTexts["OUTPUT_DETAIL_B"].exists)
        shot(theme, "imported-step-details")
        app.buttons["完成"].tap()
        app.buttons["history-step-3"].tap()
        XCTAssertTrue(app.navigationBars["读取文件"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["OUTPUT_DETAIL_B"].exists)
        XCTAssertFalse(app.staticTexts["OUTPUT_DETAIL_A"].exists)
        app.buttons["完成"].tap()
        disclosure("工具步骤 · 3 项").tap()
        XCTAssertFalse(app.buttons["history-step-2"].exists)
    }

    func testNewConversationFormSendsTextAndImage() throws { try exerciseNewConversationForm(theme: "浅色") }
    func testDarkNewConversationForm() throws { try exerciseNewConversationForm(theme: "深色") }

    private func exerciseNewConversationForm(theme: String) throws {
        UIPasteboard.general.image = try XCTUnwrap(UIImage(data: XCTUnwrap(Data(base64Encoded: Self.fixturePNG))))
        defer { UIPasteboard.general.items = [] }
        try launchFixture(theme: theme)
        app.buttons["chat-fab"].tap()
        XCTAssertTrue(app.navigationBars["开启对话"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["start-conversation"].isEnabled)
        app.buttons["current-project-picker"].tap()
        app.buttons["service"].tap()
        app.buttons["new-chat-permission"].tap()
        app.buttons["只读"].tap()
        app.buttons["new-chat-model"].tap()
        XCTAssertFalse(app.buttons["输入模型 ID…"].exists)
        app.buttons["跟随 Mac 设置"].tap()
        XCTAssertFalse(app.textFields["new-chat-custom-model"].exists)
        let messageField = app.textFields["new-chat-message"]
        let input = messageField.exists ? messageField : app.textViews["new-chat-message"]
        reveal(input, swipeUp: true)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        input.typeText("Check service screenshot")
        if app.keyboards.firstMatch.exists { app.buttons["完成"].tap() }
        let paste = app.buttons["粘贴图片"]
        reveal(paste, swipeUp: true)
        paste.tap()
        XCTAssertTrue(app.buttons["移除图片 1"].waitForExistence(timeout: 5))
        if app.keyboards.firstMatch.exists { app.buttons["完成"].tap() }
        reveal(app.buttons["current-project-picker"], swipeUp: false)
        shot(theme, "new-conversation-form")
        app.buttons["start-conversation"].tap()
        XCTAssertTrue(app.navigationBars["Check service screenshot"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Check service screenshot"].firstMatch.exists)
        XCTAssertTrue(app.buttons["查看图片 1"].exists)
        shot(theme, "new-conversation-started")
    }

    /// Uses the system pasteboard and the production PasteButton; there is
    /// no test-only attachment action in the application.
    func testImagePasteAndSend() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixturePNG))
        UIPasteboard.general.image = try XCTUnwrap(UIImage(data: data))
        defer {
            app.terminate()
            UIPasteboard.general.items = []
        }
        try launchFixture(theme: "浅色")
        XCTAssertTrue(app.buttons["project-p2"].waitForExistence(timeout: 10))
        app.buttons["project-p2"].tap()
        app.buttons["新建 CLI 对话"].tap()
        XCTAssertFalse(app.buttons["发送"].isEnabled)
        let paste = app.buttons["粘贴图片"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        XCTAssertTrue(paste.isEnabled, "System image pasteboard should enable PasteButton")
        paste.tap()
        let remove = app.buttons["移除图片"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["预览待发送图片"].exists)
        XCTAssertTrue(app.buttons["发送"].isEnabled)
        shot("浅色", "pasted-image-draft")
        remove.tap()
        XCTAssertFalse(app.buttons["预览待发送图片"].exists)
        XCTAssertFalse(app.buttons["发送"].isEnabled)

        paste.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        app.buttons["发送"].tap() // Empty text with a real pasted image.
        let image = app.buttons["查看图片 1"]
        reveal(image, swipeUp: false)
        image.tap()
        XCTAssertTrue(app.navigationBars["图片预览"].waitForExistence(timeout: 3))
        shot("浅色", "pasted-image-sent")
        app.buttons["完成"].tap()
        back()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 1)
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "图片对话").firstMatch.exists)

        // Relaunch from the same isolated persisted workspace, then reopen.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["project-p2"].waitForExistence(timeout: 10))
        app.buttons["project-p2"].tap()
        app.buttons.containing(.staticText, identifier: "图片对话").firstMatch.tap()
        reveal(image, swipeUp: false)
        image.tap()
        XCTAssertTrue(app.navigationBars["图片预览"].waitForExistence(timeout: 3))
        shot("浅色", "pasted-image-reopened")
    }

    private static let fixturePNG = "iVBORw0KGgoAAAANSUhEUgAAAHgAAABICAIAAACyfKYoAAAAuUlEQVR4nO3QMQ0AIADAMMA0OrCCQlSwqzWwZHOfO/hvBQ2M7hgdMTpidMToiNERoyNGR4yOGB0xOmJ0xOiI0RGjI0ZHjI4YHTE6YnTE6IjREaMjRkeMjhgdMTpidMToiNERoyNGR4yOGB0xOmJ0xOiI0RGjI0ZHjI4YHTE6YnTE6IjREaMjRkeMjhgdMTpidMToiNERoyNGR4yOGB0xOmJ0xOiI0RGjI0ZHjI4YHTE6YnTE6IjRo/EASN0CSpQ8ouwAAAAASUVORK5CYII="

    private func runPaths(theme: String) throws {
        try launchFixture(theme: theme)
        XCTAssertTrue(app.navigationBars["ArcLink"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat-fab"].isHittable)
        XCTAssertTrue(app.buttons["settings-entry"].isHittable)
        XCTAssertTrue(app.buttons["approval-entry"].isHittable)
        shot(theme, "home")

        // Fixed Agent tabs scope the visible projects and the chooser.
        app.buttons["Codex"].tap()
        XCTAssertTrue(app.buttons["project-p3"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["project-p1"].exists)
        app.buttons["Herdr"].tap()
        XCTAssertTrue(app.staticTexts["未安装 Herdr"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat-fab"].exists)
        app.buttons["Claude Code"].tap()
        app.buttons["搜索项目"].tap()
        let projectSearch = app.textFields["搜索项目"]
        XCTAssertTrue(projectSearch.waitForExistence(timeout: 3))
        projectSearch.tap(); projectSearch.typeText("/ui/service")
        XCTAssertTrue(app.buttons["project-p2"].exists)
        XCTAssertFalse(app.buttons["project-p1"].exists)
        projectSearch.typeText("-missing")
        XCTAssertTrue(app.staticTexts["没有匹配的项目"].waitForExistence(timeout: 3))
        app.buttons["清除项目搜索"].tap()
        app.buttons["搜索项目"].tap()

        // Project taps open conversation lists, with explicit source filters.
        app.buttons["project-p1"].tap()
        XCTAssertTrue(app.buttons["session-s-rich"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["session-s-desktop"].exists)
        sourceButton("CLI").tap()
        XCTAssertTrue(app.buttons["session-s-rich"].exists)
        XCTAssertFalse(app.buttons["session-s-desktop"].exists)
        sourceButton("桌面").tap()
        XCTAssertFalse(app.buttons["session-s-rich"].exists)
        XCTAssertTrue(app.buttons["session-s-desktop"].exists)
        sourceButton("全部").tap()
        let search = app.textFields["conversation-search"]
        search.tap(); search.typeText("Images")
        XCTAssertTrue(app.buttons["session-s-image"].exists)
        XCTAssertFalse(app.buttons["session-s-rich"].exists)
        app.buttons["清除对话搜索"].tap()
        dismissKeyboard()
        shot(theme, "project")

        // Desktop imports are read-only even while disconnected; starting a
        // CLI conversation is a separate route and has no editable history.
        app.buttons["session-s-desktop"].tap()
        XCTAssertTrue(app.staticTexts["桌面历史仅供查看"].waitForExistence(timeout: 3))
        XCTAssertFalse(input.exists)
        XCTAssertFalse(app.buttons["发送"].exists)
        XCTAssertFalse(app.buttons["终端"].exists)
        shot(theme, "desktop-readonly")
        app.buttons["新建 CLI 对话"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["发送"].isEnabled)
        back() // Read-only history.
        back() // Project list: entering an empty composer created no session.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 3)

        // Markdown uses native blocks, code copying and a single collapsed
        // "工具步骤 · N 项" group for supplied thinking/tool summaries. It must not
        // hide the original response.
        app.buttons["session-s-rich"].tap()
        reveal(app.staticTexts["Dashboard 调整方案"], swipeUp: false)
        XCTAssertTrue(app.staticTexts["Dashboard 调整方案"].exists)
        let steps = disclosure("工具步骤 · 2 项")
        reveal(steps, swipeUp: false)
        XCTAssertFalse(app.staticTexts["先检查数据请求，再保留错误重试入口。"].exists)
        steps.tap()
        XCTAssertTrue(app.staticTexts["先检查数据请求，再保留错误重试入口。"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Read: src/Dashboard.tsx"].exists)
        shot(theme, "chat-thinking")
        let copyCode = app.buttons["复制代码"]
        reveal(copyCode, swipeUp: true)
        copyCode.tap()
        XCTAssertTrue(app.buttons["已复制代码"].waitForExistence(timeout: 2))
        reveal(app.staticTexts["数据请求"], swipeUp: true)
        XCTAssertTrue(app.staticTexts["数据请求"].exists)
        XCTAssertTrue(app.staticTexts["待写入"].exists)
        shot(theme, "chat-markdown")
        let copyReply = app.buttons["复制回复的 Markdown"]
        reveal(copyReply, swipeUp: true)
        copyReply.tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["toast"].label, "已复制回复的 Markdown")
        back()

        // A persisted real PNG is inspectable without a fake upload button.
        app.buttons["session-s-image"].tap()
        let image = app.buttons["查看图片 1"]
        reveal(image, swipeUp: true)
        image.tap()
        XCTAssertTrue(app.navigationBars["图片预览"].waitForExistence(timeout: 3))
        shot(theme, "attachment-preview")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["从相册添加图片"].isHittable)
        back(); back()

        // The chooser can switch projects within the selected Agent. Merely
        // opening/backing out creates nothing; first send belongs to p2.
        app.buttons["chat-fab"].tap()
        XCTAssertTrue(app.navigationBars["开启对话"].waitForExistence(timeout: 3))
        app.buttons["current-project-picker"].tap()
        app.buttons["service"].tap()
        XCTAssertFalse(app.buttons["start-conversation"].isEnabled)
        app.buttons["取消"].tap()
        app.buttons["project-p2"].tap()
        XCTAssertTrue(app.staticTexts["还没有对话"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 0)
        app.buttons["新建 CLI 对话"].tap()
        input.tap(); input.typeText("Review service")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["发送"].isHittable)
        shot(theme, "keyboard")
        app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["Review service"].firstMatch.waitForExistence(timeout: 3))
        shot(theme, "chat-sent")
        back()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 1)
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Review service").firstMatch.exists)
        back()
        app.buttons["project-p1"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 3)
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: "Review service").firstMatch.exists)
        back()

        // Bell leads to actionable approvals; explicit gear leads to real settings.
        app.buttons["approval-entry"].tap()
        XCTAssertTrue(app.buttons["approval-a1"].waitForExistence(timeout: 3))
        app.buttons["approval-a1"].tap()
        XCTAssertTrue(app.navigationBars["审批详情"].waitForExistence(timeout: 3))
        shot(theme, "approval")
        app.buttons["批准写入"].tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["toast"].label, "已批准")
        back()
        app.buttons["settings-entry"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        let notify = app.switches["需要批准"]
        XCTAssertTrue(notify.waitForExistence(timeout: 3))
        let previous = notify.value as? String
        notify.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(notify.value as? String, previous)
        shot(theme, "settings")
        app.terminate()
    }

    private var input: XCUIElement {
        let field = app.textFields["composer"]
        return field.exists ? field : app.textViews["composer"]
    }

    private func sourceButton(_ title: String) -> XCUIElement {
        app.segmentedControls["conversation-source-filter"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func disclosure(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    private func dismissKeyboard() {
        if app.keyboards.firstMatch.exists {
            app.swipeDown()
        }
    }

    private func reveal(_ element: XCUIElement, swipeUp: Bool) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            // Swipe beside nested code/table scroll areas so the outer
            // conversation scrolls, not a wide code block.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: swipeUp ? 0.74 : 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: swipeUp ? 0.25 : 0.74))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected visible element: \(element)")
    }

    private func shot(_ theme: String, _ screen: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "rich-ui-\(theme)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixture(theme: String, history: [[String: String]]? = nil, largeText: Bool = false) throws {
        let now = Date().timeIntervalSinceReferenceDate
        func project(_ id: String, _ name: String, _ path: String, _ agent: String) -> [String: Any] {
            ["id": id, "name": name, "path": path, "agent": agent, "createdAt": now]
        }
        func session(_ id: String, _ title: String, _ source: String) -> [String: Any] {
            ["id": id, "projectId": "p1", "title": title, "status": "已完成", "detail": source == "桌面" ? "Claude 对话" : "本地记录", "source": source, "createdAt": now]
        }
        let png = Self.fixturePNG
        let markdown = """
        ## Dashboard 调整方案
        保留 **错误重试**，将请求迁移到 `useQuery`。

        - [x] 检查现有组件
        - [ ] 修改数据请求

        ```tsx
        const query = useQuery({ queryKey: ["dashboard"] });
        ```

        | 区域 | 状态 |
        | --- | --- |
        | 数据请求 | 待写入 |
        | 错误处理 | 保留重试 |

        > 修改前先确认影响范围。
        """
        let workspace: [String: Any] = [
            "selectedAgent": "Claude Code", "selectedProjectIDs": ["Claude Code": "p1", "Codex": "p3"],
            "projects": [project("p1", "my-app", "/ui/app", "Claude Code"), project("p2", "service", "/ui/service", "Claude Code"), project("p3", "codex-app", "/ui/codex", "Codex")],
            "sessions": [session("s-rich", "Dashboard rich content", "CLI"), session("s-desktop", "Desktop history", "桌面"), session("s-image", "Images", "CLI")],
            "messages": [
                ["id": "m-rich", "sessionId": "s-rich", "isUser": false, "text": markdown, "time": "10:30", "thinkingSummary": "先检查数据请求，再保留错误重试入口。", "toolOutput": "Read: src/Dashboard.tsx"],
                ["id": "m-image", "sessionId": "s-image", "isUser": true, "text": "请查看这张图片", "time": "10:31", "imageAttachments": [png]]
            ],
            "approvals": [["id": "a1", "sessionId": "s-rich", "title": "更新 Dashboard", "kind": "工具调用 · 写入文件", "target": "/ui/app/src/Dashboard.tsx", "detail": "本地模拟审批，不会写入 Mac 文件。", "pending": true]],
            "permission": "完全访问"
        ]
        let state: [String: Any] = ["version": 2, "selectedDeviceID": "mac", "devices": [["id": "mac", "name": "UI 测试 Mac", "workspace": workspace]], "notifyApproval": true, "notifyDone": true, "notifyOnMac": false, "notifyFailed": true]
        app.launchEnvironment = ["ARCLINK_UI_TEST_ID": UUID().uuidString,
                                 "ARCLINK_UI_TEST_STATE": String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)]
        if let history {
            app.launchEnvironment["ARCLINK_UI_TEST_MAC_MESSAGES"] = String(decoding: try JSONSerialization.data(withJSONObject: history), as: UTF8.self)
        }
        app.launchArguments = ["-appearance", theme]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }
}
