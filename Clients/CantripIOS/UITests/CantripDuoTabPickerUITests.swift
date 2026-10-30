import XCTest

/// iPhone Duo folded (the simulator's default pose), in a project tab: there is no "‹ Home". The Tabs
/// button at the bottom of the vertical bar and a swipe in from the left edge both bring out the tab
/// picker, which switches tabs or goes back to Home.
/// Run on an iPhone Duo simulator with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// (and `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if the host's token isn't `duo-qa-token`) against a
/// fixture host with at least two tabs. `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` saves screenshots.
final class CantripDuoTabPickerUITests: XCTestCase {
    func testATabSwitchesThroughTheTabPickerInsteadOfGoingBack() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") else {
            throw XCTSkip("Needs an iPhone Duo simulator")
        }
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a fixture Home host and set CANTRIP_UITEST_HOME_URL")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "cantrip"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let window = app.windows.firstMatch
        guard window.frame.width < window.frame.height else {
            throw XCTSkip("Fold the Duo and hold it upright (window \(window.frame.size))")
        }

        let tabs = app.buttons["home.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "A tab shows the Tabs button")
        XCTAssertFalse(app.buttons["tab.home"].exists, "No ‹ Home on the Duo")
        XCTAssertGreaterThan(tabs.frame.midX, window.frame.width * 0.75, "It sits in the vertical bar")

        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch
        tabs.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "Tabs brings out the tab picker")
        sleep(1)
        save("picker-from-tabs")
        // Tabs is a toggle: tapping it again puts the picker away.
        tabs.tap()
        XCTAssertTrue(waitForAbsence(drawer), "Tapping Tabs again closes the tab picker")
        tabs.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "And opens it again")
        // Another tab (the fixture opens on its first one).
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES 'cantrip-tab-[0-9A-Fa-f-]{36}'"))
        let other = rows.allElementsBoundByIndex.dropFirst().first { $0.isHittable }
        XCTAssertNotNil(other, "The picker lists other tabs")
        other?.tap()
        XCTAssertTrue(waitForAbsence(drawer), "Picking a tab closes the picker")
        XCTAssertTrue(app.buttons["home.tabs"].firstMatch.waitForExistence(timeout: 5), "Still in a tab")
        save("switched-tab")

        // A swipe in from the left edge brings it out too.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.47)))
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "The left-edge swipe brings out the tab picker")
        sleep(1)
        save("picker-from-swipe")

        // Home is pinned first in the picker.
        let home = app.descendants(matching: .any)["drawer.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Home is in the picker")
        home.tap()
        XCTAssertTrue(waitForAbsence(drawer), "Choosing Home closes the picker")
        XCTAssertTrue(app.toolbars.buttons["Builds"].firstMatch.waitForExistence(timeout: 10),
                      "Back on Home: its sections are in the vertical bar")
    }

    /// The folded Duo's outer display, saved to `CANTRIP_UITEST_SHOTS` when set.
    private func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}
