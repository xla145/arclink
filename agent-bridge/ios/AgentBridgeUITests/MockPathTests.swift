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

        // Markdown uses native blocks, code copying and collapsed supplied
        // thinking/tool summaries. It must not hide the original response.
        app.buttons["session-s-rich"].tap()
        reveal(app.staticTexts["Dashboard 调整方案"], swipeUp: false)
        XCTAssertTrue(app.staticTexts["Dashboard 调整方案"].exists)
        let summary = disclosure("思考摘要")
        reveal(summary, swipeUp: false)
        XCTAssertFalse(app.staticTexts["先检查数据请求，再保留错误重试入口。"].exists)
        summary.tap()
        XCTAssertTrue(app.staticTexts["先检查数据请求，再保留错误重试入口。"].waitForExistence(timeout: 3))
        shot(theme, "chat-thinking")
        let copyCode = app.buttons["复制代码"]
        reveal(copyCode, swipeUp: true)
        copyCode.tap()
        XCTAssertTrue(app.buttons["已复制代码"].waitForExistence(timeout: 2))
        reveal(app.staticTexts["数据请求"], swipeUp: true)
        XCTAssertTrue(app.staticTexts["数据请求"].exists)
        XCTAssertTrue(app.staticTexts["待写入"].exists)
        shot(theme, "chat-markdown")
        let tools = disclosure("工具结果")
        reveal(tools, swipeUp: true)
        XCTAssertFalse(app.staticTexts["Read: src/Dashboard.tsx"].exists)
        tools.tap()
        XCTAssertTrue(app.staticTexts["Read: src/Dashboard.tsx"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.navigationBars["选择对话"].waitForExistence(timeout: 3))
        app.buttons["current-project-picker"].tap()
        app.buttons["service"].tap()
        app.buttons["新建 CLI 对话"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["发送"].isEnabled)
        XCTAssertTrue(app.staticTexts["service"].exists)
        back()
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

    private func launchFixture(theme: String) throws {
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
        app.launchArguments = ["-appearance", theme]
        app.launch()
    }
}
