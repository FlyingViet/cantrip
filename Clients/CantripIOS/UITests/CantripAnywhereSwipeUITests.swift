import XCTest

/// Swipes that start anywhere, not just at the edge: right opens the tab drawer from Home (and goes
/// back to Home from a tab), left anywhere over the open drawer puts it away. Run with
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>` (and `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN`
/// if the host's token isn't `duo-qa-token`). `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` saves screenshots.
final class CantripAnywhereSwipeUITests: XCTestCase {
    func testSwipesWorkFromTheMiddleOfTheScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a fixture host and set CANTRIP_UITEST_HOME_URL")
        }
        guard !(environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") else {
            throw XCTSkip("On the Duo a tab opens the tab picker instead of going back; see CantripDuoTabPickerUITests")
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
        sleep(2)
        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch

        // Right from the middle of Home's chat opens the drawer.
        swipe(app, from: 0.35, to: 0.9, y: 0.5)
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "A swipe right from mid-screen opens the tab drawer")
        save("drawer-open")

        // Left from the middle of the drawer's tab list puts it away.
        swipe(app, from: 0.55, to: 0.05, y: 0.55)
        XCTAssertTrue(waitForAbsence(drawer), "A swipe left over the tab list closes the drawer")
        save("drawer-closed")

        // Inside a tab, right from mid-screen goes back to Home.
        tabs.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES 'cantrip-tab-[0-9A-Fa-f-]{36}'"))
        let row = rows.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(row, "The drawer lists tabs")
        row?.tap()
        let back = app.buttons["Home"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The tab opened")
        sleep(2)
        save("in-tab")
        swipe(app, from: 0.4, to: 0.95, y: 0.5)
        XCTAssertTrue(waitForAbsence(back, timeout: 8), "A swipe right from mid-screen goes back to Home")
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        save("back-home")
    }

    private func swipe(_ app: XCUIApplication, from: CGFloat, to: CGFloat, y: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: from, dy: y))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: to, dy: y + 0.01))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 900, thenHoldForDuration: 0.05)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] else { return }
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
