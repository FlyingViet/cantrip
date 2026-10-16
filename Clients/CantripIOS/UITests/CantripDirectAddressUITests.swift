import XCTest

/// Cantrip Home through a saved direct address only: no Tailscale URL and no Bonjour, the path
/// the phone uses to reach a Mac without Tailscale through a router's Tailscale subnet route.
/// Start a fixture host whose TLS-PSK listener is pinned with Bonjour off, then run with
/// `TEST_RUNNER_CANTRIP_UITEST_DIRECT=<host:port> TEST_RUNNER_CANTRIP_UITEST_DIRECT_TOKEN=<token>`.
final class CantripDirectAddressUITests: XCTestCase {
    func testHomeLoadsThroughADirectAddressAndSettingsShowsIt() throws {
        let env = ProcessInfo.processInfo.environment
        guard let direct = env["CANTRIP_UITEST_DIRECT"], let token = env["CANTRIP_UITEST_DIRECT_TOKEN"] else {
            throw XCTSkip("Start a pinned-port fixture host and set CANTRIP_UITEST_DIRECT and CANTRIP_UITEST_DIRECT_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", "", "-CantripUITestRemoteToken", token,
                               "-CantripUITestRemoteDirect", direct, "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "109 users")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "Home history must load through the direct address")
        attach(app, "Home via direct address")

        let pip = app.buttons["Pip"].firstMatch
        XCTAssertTrue((pip.value as? String ?? "").contains("Conn"), "Pip reports a live connection")
        let menu = app.buttons["Chat menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Direct \(direct)")).firstMatch
        for _ in 0..<8 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The saved profile shows its direct address")
        attach(app, "Saved server with direct address")
        let field = app.textFields.containing(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Direct address"))
            .firstMatch
        for _ in 0..<8 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.exists, "The add form offers a direct address")
        attach(app, "Add server form")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
