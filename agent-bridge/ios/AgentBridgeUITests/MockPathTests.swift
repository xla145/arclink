import XCTest

final class MockPathTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.agentbridge.ios")
    }

    func testLightPaths() { runPaths(theme: "light", appearance: "浅色") }
    func testDarkPaths() { runPaths(theme: "dark", appearance: "深色") }

    private func shot(_ theme: String, _ screen: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "0.1-\(theme)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    private func runPaths(theme: String, appearance: String) {
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["project-p1"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap()
        app.descendants(matching: .any).matching(identifier: "appearance-picker").firstMatch.tap()
        app.buttons[appearance].tap()
        back()
        XCTAssertTrue(app.staticTexts["MacBook Pro"].exists)
        shot(theme, "home")

        // Search both project names and paths, including an empty result.
        let search = app.textFields["搜索项目"]
        search.tap()
        search.typeText("~/work")
        XCTAssertTrue(app.buttons["project-p2"].exists)
        XCTAssertFalse(app.buttons["project-p1"].exists)
        search.typeText("-missing")
        XCTAssertTrue(app.staticTexts["没有匹配的项目"].exists)
        app.terminate(); app.launch()
        app.buttons["Codex"].tap()
        XCTAssertTrue(app.buttons["project-p3"].exists)
        XCTAssertFalse(app.buttons["project-p1"].exists)
        app.buttons["Herdr"].tap()
        XCTAssertTrue(app.staticTexts["本机未安装 Herdr"].exists)
        app.buttons["Claude Code"].tap()

        app.buttons["project-p1"].tap()
        XCTAssertTrue(app.buttons["session-s1"].exists)
        shot(theme, "project")
        app.buttons["session-s1"].tap()
        XCTAssertTrue(app.staticTexts["我来帮你重构 Dashboard 组件。先读取当前实现。"].exists)
        app.buttons["tool-event"].tap()
        XCTAssertTrue(app.alerts["工具 · Read"].exists)
        app.alerts.buttons["完成"].tap()
        app.buttons["approval-event-a1"].tap()
        XCTAssertTrue(app.staticTexts["变更预览"].exists)
        back(); back()

        // New session stays empty until the first message, with a real keyboard.
        app.buttons["新建会话"].tap()
        XCTAssertFalse(app.buttons["发送"].isEnabled)
        let composer = app.textFields["composer"]
        // A vertical TextField can be exposed as a text view on newer iOS.
        let input = composer.exists ? composer : app.textViews["composer"]
        input.tap()
        input.typeText("Review project")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["发送"].isHittable)
        shot(theme, "keyboard")
        app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["收到。我先查看相关文件，然后开始处理。"].waitForExistence(timeout: 3))
        shot(theme, "chat")
        app.buttons["添加示例图片"].tap()
        XCTAssertTrue(app.staticTexts["示例截图 · 1 张"].exists)
        app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["收到截图，我来分析一下界面结构。"].waitForExistence(timeout: 3))
        app.buttons["查看图片"].tap()
        XCTAssertTrue(app.navigationBars["图片预览"].exists)
        app.buttons["完成"].tap()
        shot(theme, "attachment")
        back()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Review project").firstMatch.exists)
        back()

        app.buttons.containing(.staticText, identifier: "2 个待审批").firstMatch.tap()
        app.buttons["approval-a1"].tap()
        XCTAssertTrue(app.staticTexts["变更预览"].exists)
        shot(theme, "approval")
        app.buttons["批准写入"].tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["toast"].label, "已批准")
        shot(theme, "approved")
        app.buttons["approval-a1"].tap()
        XCTAssertFalse(app.buttons["批准写入"].exists)
        back()
        app.buttons["approval-a2"].tap()
        XCTAssertTrue(app.staticTexts["命令预览"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["$ npm test --coverage --watchAll=false"].exists)
        shot(theme, "command")
        app.buttons["拒绝"].tap()
        XCTAssertTrue(app.staticTexts["toast"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["toast"].label, "已拒绝")
        XCTAssertTrue(app.staticTexts["没有待处理的审批"].exists)
        shot(theme, "rejected")
        back()
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: "2 个待审批").firstMatch.exists)

        app.buttons["设置"].tap()
        shot(theme, "settings")
        app.buttons.containing(.staticText, identifier: "MacBook Pro").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["我的 Mac"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已配对")).firstMatch.exists)
        shot(theme, "mac")
        back()
        let notify = app.switches["需要批准"]
        let previous = notify.value as? String
        notify.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(notify.value as? String, previous)
        app.swipeUp()
        app.descendants(matching: .any).matching(identifier: "appearance-picker").firstMatch.tap()
        app.buttons[appearance == "浅色" ? "深色" : "浅色"].tap()
        app.descendants(matching: .any).matching(identifier: "appearance-picker").firstMatch.tap()
        app.buttons[appearance].tap()
        XCTAssertTrue(app.navigationBars["设置"].exists)
        app.terminate()
    }
}
