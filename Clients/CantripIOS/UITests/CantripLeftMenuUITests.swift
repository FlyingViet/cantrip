import XCTest

/// The app's one left menu: its search, and pictures of it in whatever pose the simulator is in, for
/// before/after comparisons: the
/// tab drawer (iPhone, folded iPhone Duo, unfolded Duo with its sidebar put away), the unfolded Duo's
/// sidebar, and iPad's sidebar column. Set `TEST_RUNNER_CANTRIP_UITEST_HOME_URL` (and `_HOME_TOKEN`),
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` and `TEST_RUNNER_CANTRIP_UITEST_SHOT_PREFIX=<pose>`
/// (`TEST_RUNNER_CANTRIP_UITEST_LANDSCAPE=1` turns the app on its side, for the folded Duo); a
/// watcher on the Mac answers `<name>.request`, whose text names the display (inner, outer or main).
final class CantripLeftMenuUITests: XCTestCase {
    private var shots = ""
    private var display = "main"

    func testLeftMenuShots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"], let folder = environment["CANTRIP_UITEST_SHOTS"] else {
            throw XCTSkip("Set CANTRIP_UITEST_HOME_URL and CANTRIP_UITEST_SHOTS")
        }
        shots = folder
        let prefix = environment["CANTRIP_UITEST_SHOT_PREFIX"] ?? "menu"
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "home"]
            + (environment["CANTRIP_UITEST_LANDSCAPE"] == "1" ? ["-CantripUITestLandscape"] : [])
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        // Turned on its side, the window settles after launch.
        sleep(environment["CANTRIP_UITEST_LANDSCAPE"] == "1" ? 6 : 3)
        let isDuo = (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo")
        display = !isDuo ? "main" : (app.isOnDuoInnerDisplay ? "inner" : "outer")
        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch

        if UIDevice.current.userInterfaceIdiom == .pad {
            save("\(prefix)-column")
            return
        }
        let toggle = app.buttons["duo.rail.sidebar"].firstMatch
        if toggle.waitForExistence(timeout: 5) {
            // Unfolded: the sidebar, then the drawer a swipe brings out while the sidebar is put away.
            let sidebar = app.descendants(matching: .any)["duo.sidebar"].firstMatch
            if !sidebar.exists { toggle.tap() }
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The sidebar")
            sleep(1)
            save("\(prefix)-sidebar")
            toggle.tap()
            XCTAssertTrue(waitForAbsence(sidebar), "The toggle puts the sidebar away")
            sleep(1)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        } else {
            let tabs = app.buttons["home.tabs"].firstMatch.exists ? app.buttons["home.tabs"].firstMatch : app.buttons["Tabs"].firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 10), "The Tabs button")
            tabs.tap()
        }
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "The drawer")
        sleep(1)
        save("\(prefix)-drawer")
    }

    /// The magnifying glass beside Pip searches the tabs: typing a tab's name lists just the matches
    /// under Results, and closing the search brings Home's sections back.
    func testSearchFindsTabsFromTheMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else { throw XCTSkip("Set CANTRIP_UITEST_HOME_URL") }
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
        // The drawer on an iPhone or a folded Duo; iPad's column is always there.
        let prefix: String
        if UIDevice.current.userInterfaceIdiom == .pad {
            prefix = "drawer"
        } else if app.buttons["duo.rail.sidebar"].waitForExistence(timeout: 5) {
            let sidebar = app.descendants(matching: .any)["duo.sidebar"].firstMatch
            if !sidebar.exists { app.buttons["duo.rail.sidebar"].firstMatch.tap() }
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            prefix = "duo.sidebar"
        } else {
            let tabs = app.buttons["home.tabs"].firstMatch.exists ? app.buttons["home.tabs"].firstMatch : app.buttons["Tabs"].firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            tabs.tap()
            prefix = "drawer"
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(prefix).tab."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "The menu lists tabs")
        let all = rows.allElementsBoundByIndex.map(\.label)
        let wanted = try XCTUnwrap(all.first { title in all.filter { $0.localizedStandardContains(title) }.count == 1 },
                                   "A tab whose name no other tab contains: \(all)")
        let section = app.buttons["\(prefix).section.tasks"].firstMatch
        XCTAssertTrue(section.exists, "Home's sections show")

        app.buttons["\(prefix).searchButton"].firstMatch.tap()
        let field = app.textFields["\(prefix).search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The magnifying glass opens the search field")
        field.typeText(wanted)
        // The header draws in capitals; match its text either way.
        let results = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Results · 1")).firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5), "One match")
        XCTAssertEqual(rows.count, 1, "Only the match is listed")
        XCTAssertEqual(rows.firstMatch.label, wanted)
        XCTAssertFalse(section.exists, "Home's sections step aside while searching")

        app.buttons["\(prefix).searchButton"].firstMatch.tap()
        XCTAssertTrue(section.waitForExistence(timeout: 5), "Closing the search brings the menu back")
        XCTAssertEqual(rows.count, all.count, "Every tab again")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func save(_ name: String) {
        let folder = URL(fileURLWithPath: shots)
        try? Data(display.utf8).write(to: folder.appendingPathComponent("\(name).request"))
        let picture = folder.appendingPathComponent("\(name).png").path
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: picture) { usleep(250_000) }
    }
}
