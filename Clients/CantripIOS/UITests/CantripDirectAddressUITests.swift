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
        // Settings is in the tab drawer's footer; the Mac's addresses are on its page under Macs.
        let tabs = app.buttons["home.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.tap()
        let settings = app.buttons["drawer.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let macs = app.buttons["settings.page.macs"].firstMatch
        XCTAssertTrue(macs.waitForExistence(timeout: 5))
        macs.tap()
        let mac = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.mac.'")).firstMatch
        XCTAssertTrue(mac.waitForExistence(timeout: 5), "The paired Mac is listed")
        mac.tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", direct)).firstMatch
        for _ in 0..<8 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The Mac's page shows its direct address under Advanced")
        attach(app, "Saved Mac with direct address")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.pairMac"].firstMatch.tap()
        let advanced = app.buttons["Advanced"].firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let field = app.textFields.containing(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Direct address"))
            .firstMatch
        for _ in 0..<8 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.exists, "Pair a Mac offers a direct address under Advanced")
        attach(app, "Pair a Mac form")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
