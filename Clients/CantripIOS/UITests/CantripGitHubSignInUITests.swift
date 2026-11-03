import XCTest

/// Settings › Tools & sign-ins shows who the Mac's GitHub CLI is signed in as. Run against a fixture
/// host with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`,
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` and `TEST_RUNNER_CANTRIP_UITEST_GITHUB` set to the text the
/// row should start with ("Signed in as …", "Not signed in"). `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>`
/// saves a screenshot.
final class CantripGitHubSignInUITests: XCTestCase {
    func testToolsPageShowsTheMacsGitHubSignIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"], let expected = environment["CANTRIP_UITEST_GITHUB"] else {
            throw XCTSkip("Start a fixture host and set CANTRIP_UITEST_HOME_URL and CANTRIP_UITEST_GITHUB")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let tabs = app.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "Home loads")
        tabs.tap()
        let settings = app.buttons["drawer.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let tools = app.buttons["settings.page.tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.tap()
        let status = app.descendants(matching: .any).matching(identifier: "settings.github.status").firstMatch
        for _ in 0..<8 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the GitHub row shows")
        let shows = NSPredicate(format: "label CONTAINS %@", expected)
        let answered = XCTNSPredicateExpectation(predicate: shows, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 30), .completed, "row reads: \(status.label)")
        if !status.isHittable { app.swipeUp() }
        save("github-\(expected.hasPrefix("Signed in") ? "signed-in" : "signed-out")")
    }

    private func save(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] else { return }
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
