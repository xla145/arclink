import XCTest

final class RelayNetworkUITests: XCTestCase {
    func testLightAutomaticConnection() throws { try exercise(theme: "浅色") }
    func testDarkAutomaticConnection() throws { try exercise(theme: "深色") }

    private func exercise(theme: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.agentbridge.ios")
        let state: [String: Any] = ["version": 2, "selectedDeviceID": "relay-device", "devices": [
            ["id": "relay-device", "name": "测试 Mac", "endpointID": "invalid-ui-test-endpoint",
             "network": ["relayURL": "https://iroh.classktv.com/", "directAddresses": []],
             "workspace": ["selectedAgent": "Claude Code", "projects": [], "sessions": [], "messages": [], "approvals": [], "permission": "完全访问"]]],
            "notifyApproval": true, "notifyDone": true, "notifyOnMac": false, "notifyFailed": true]
        app.launchEnvironment = ["ARCLINK_UI_TEST_ID": UUID().uuidString,
            "ARCLINK_UI_TEST_STATE": String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)]
        app.launchArguments = ["-appearance", theme]
        app.launch()
        XCTAssertTrue(app.buttons["device-switcher"].waitForExistence(timeout: 10))
        app.buttons["device-switcher"].tap()
        XCTAssertTrue(app.navigationBars["我的设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重新扫码连接 测试 Mac"].exists)
        XCTAssertTrue(app.staticTexts["扫码即可同时设置直连和中继，优先直连，不可用时自动使用中继。重新扫码会更新连接信息，保留项目和会话。"].exists)
        XCTAssertFalse(app.buttons["网络设置 · 测试 Mac"].exists)
        XCTAssertFalse(app.textFields["HTTPS 中继地址"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        app.buttons["重新扫码连接 测试 Mac"].tap()
        XCTAssertTrue(app.buttons["关闭扫描"].waitForExistence(timeout: 5))
        app.buttons["关闭扫描"].tap()
        XCTAssertTrue(app.buttons["device-relay-device"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "relay-network-" + theme
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }
}
