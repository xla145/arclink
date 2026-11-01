import XCTest

final class MultiDeviceUITests: XCTestCase {
    func testLightDeviceSwitching() throws { try exercise(theme: "浅色") }
    func testDarkDeviceSwitching() throws { try exercise(theme: "深色") }

    func testSwitchAfterRelaunchWithoutScanner() throws { try exercise(theme: "浅色", includeScanner: false) }

    private func exercise(theme: String, includeScanner: Bool = true) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.agentbridge.ios")
        let id = UUID().uuidString
        func workspace(_ name: String) -> [String: Any] {
            ["selectedAgent": "Claude Code", "projects": [["id": "shared-project", "name": name, "path": "/test", "agent": "Claude Code"]],
             "sessions": [], "messages": [], "approvals": [], "permission": "完全访问"]
        }
        let state: [String: Any] = ["version": 2, "selectedDeviceID": "a", "devices": [
            ["id": "a", "name": "测试 Mac A", "workspace": workspace("A 的测试项目")],
            ["id": "b", "name": "测试 Mac B", "workspace": workspace("B 的测试项目")]],
            "notifyApproval": true, "notifyDone": true, "notifyOnMac": false, "notifyFailed": true]
        app.launchEnvironment = ["ARCLINK_UI_TEST_ID": id,
                                 "ARCLINK_UI_TEST_STATE": String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)]
        app.launchArguments = ["-appearance", theme]
        app.launch()
        XCTAssertTrue(app.navigationBars["ArcLink"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["A 的测试项目"].exists)
        XCTAssertTrue(app.buttons["device-switcher"].label.contains("测试 Mac A"))
        XCTAssertTrue(app.buttons["device-switcher"].label.contains("重新扫码"))
        shot("\(theme)-home", app)
        app.buttons["device-switcher"].tap()
        XCTAssertTrue(app.navigationBars["我的设备"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["device-a"].exists)
        XCTAssertTrue(app.buttons["device-b"].exists)
        XCTAssertTrue(app.buttons["add-device"].exists)
        shot("\(theme)-devices", app)
        app.buttons["device-b"].tap()
        XCTAssertTrue(app.navigationBars["ArcLink"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["B 的测试项目"].exists)
        XCTAssertTrue(app.buttons["device-switcher"].label.contains("测试 Mac B"))
        XCTAssertFalse(app.staticTexts["A 的测试项目"].exists)
        shot("\(theme)-selected-b", app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["B 的测试项目"].waitForExistence(timeout: 10))
        app.buttons["device-switcher"].tap()
        if includeScanner {
            app.buttons["add-device"].tap()
            let close = app.buttons["关闭扫描"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.tap()
            // First launch can present the system camera alert. XCTest's default
            // interruption handler consumes that tap while granting permission.
            if !close.waitForNonExistence(timeout: 2) { close.tap() }
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["device-b"].waitForExistence(timeout: 3))
        }
        app.buttons["device-a"].tap()
        let project = app.buttons["project-shared-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        let selectedProject = NSPredicate(format: "label CONTAINS %@", "A 的测试项目")
        expectation(for: selectedProject, evaluatedWith: project)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(project.isHittable)
        project.tap()
        XCTAssertTrue(app.navigationBars["A 的测试项目"].waitForExistence(timeout: 3))
        app.terminate()
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "multi-device-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
