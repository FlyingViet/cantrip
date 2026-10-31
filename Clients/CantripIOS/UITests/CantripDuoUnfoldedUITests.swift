import XCTest

/// iPhone Duo unfolded (upright or on its side): the system's vertical bar is the app's rail, with a
/// sidebar toggle, Model Settings and Settings. The toggle opens and closes the sidebar, typing never
/// changes it, and Model Settings opens the existing sheet with the Mac's usage limit fallback.
/// Run on an unfolded iPhone Duo simulator with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// (and `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if the host's token isn't `duo-qa-token`). Set
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` (with a watcher that answers its requests) for
/// screenshots of each state.
final class CantripDuoUnfoldedUITests: XCTestCase {
    private var shots: String?

    func testRailTogglesTheSidebarAndOpensModelSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") else {
            throw XCTSkip("Needs an iPhone Duo simulator")
        }
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a fixture Home host and set CANTRIP_UITEST_HOME_URL")
        }
        shots = environment["CANTRIP_UITEST_SHOTS"]
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let toggle = app.buttons["duo.rail.sidebar"].firstMatch
        guard toggle.waitForExistence(timeout: 15) else {
            throw XCTSkip("Unfold the Duo: the rail's sidebar toggle shows only unfolded")
        }
        let modelSettings = app.buttons["duo.rail.modelSettings"].firstMatch
        XCTAssertTrue(modelSettings.exists, "The rail has Model Settings")
        XCTAssertTrue(app.buttons["chat.settings"].firstMatch.exists, "The rail has Settings")
        XCTAssertFalse(app.buttons["home.tabs"].exists, "The toggle takes the tabs button's place")

        let sidebar = app.otherElements["duo.sidebar"]
        if !sidebar.exists { toggle.tap() }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Show Sidebar opens it")
        // Home's sections stay in the right-side rail (the sidebar lists Builds too, on the left).
        let window = app.windows.firstMatch
        let railBuilds = {
            app.buttons.matching(NSPredicate(format: "label == 'Builds'")).allElementsBoundByIndex
                .contains { $0.frame.midX > window.frame.width * 0.85 }
        }
        XCTAssertTrue(app.buttons["Builds"].firstMatch.waitForExistence(timeout: 5) && railBuilds(),
                      "Home's sections stay in the rail with the sidebar open")
        XCTAssertFalse(app.descendants(matching: .any)["home.compactTabBar"].exists, "No bottom bar on the Duo")
        XCTAssertEqual(toggle.label, "Hide Sidebar")
        save(app, "sidebar-open")

        toggle.tap()
        XCTAssertTrue(waitForAbsence(sidebar), "Hide Sidebar closes it")
        XCTAssertEqual(toggle.label, "Show Sidebar")
        XCTAssertTrue(railBuilds(), "Home's sections stay in the rail with the sidebar closed")
        save(app, "sidebar-closed")

        let field = app.textFields["chat.composer"].firstMatch
        let message = field.waitForExistence(timeout: 10) ? field : app.textViews["chat.composer"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "The message field")
        message.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        XCTAssertFalse(sidebar.exists, "Typing must not reopen the sidebar")
        save(app, "sidebar-closed-typing")
        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The toggle works with the keyboard up")
        sleep(1)
        XCTAssertTrue(sidebar.exists, "The sidebar stays open while typing")
        save(app, "sidebar-open-typing")

        modelSettings.tap()
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForExistence(timeout: 10),
                      "Model Settings opens the existing sheet")
        if environment["CANTRIP_UITEST_EXPECTS_FALLBACK"] == "1" {
            let fallback = app.staticTexts["Usage limit fallbacks (all tabs)"].firstMatch
            for _ in 0..<4 where !fallback.exists { app.swipeUp() }
            XCTAssertTrue(fallback.waitForExistence(timeout: 5), "It reaches the Mac's usage limit fallbacks")
            XCTAssertTrue(app.buttons["usageFallback.add"].firstMatch.exists, "Add a backup")
        }
        save(app, "model-settings")
        app.navigationBars["Model Settings"].buttons["Cancel"].tap()

        app.buttons["chat.settings"].firstMatch.tap()
        sleep(2)
        save(app, "settings")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Asks a watcher on the Mac for a picture of the unfolded display (`simctl io <udid> screenshot
    /// --display=3`): writes `<name>.request` into the shots folder and waits for `<name>.png`. The test
    /// runner's own screenshots show only the outer display.
    private func save(_ app: XCUIApplication, _ name: String) {
        guard let shots else { return }
        let folder = URL(fileURLWithPath: shots)
        try? Data().write(to: folder.appendingPathComponent("\(name).request"))
        let picture = folder.appendingPathComponent("\(name).png").path
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: picture) { usleep(250_000) }
    }
}
