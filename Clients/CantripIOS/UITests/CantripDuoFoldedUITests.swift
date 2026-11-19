import XCTest

/// iPhone Duo folded (the simulator's default pose): Cantrip Home keeps the iPhone layout while
/// typing, and its navigation is one bar on the vertical bar's edge that is always open with only
/// actions (none covering another) and stays open after a choice, a tap outside or a scroll. Home's
/// sections (Chat, Tasks, Artifacts, Builds) are rows in the tab drawer the bar's Tabs button opens.
/// Run on an iPhone Duo simulator with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// (any fixture host that serves Cantrip Home, e.g. `fake_home_host.py`; set
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if its token isn't `duo-qa-token`).
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` saves screenshots.
final class CantripDuoFoldedUITests: XCTestCase {
    private let sections = ["chat", "tasks", "artifacts", "builds"]

    func testFoldedHomeHasOneBarThatStaysOpen() throws {
        let app = try launchFoldedHome()
        let window = app.windows.firstMatch
        guard window.frame.width < window.frame.height else {
            throw XCTSkip("Fold the Duo and hold it upright (window \(window.frame.size))")
        }

        let tabs = app.buttons["home.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "Home's bar is open from the start")
        XCTAssertFalse(app.buttons["duo.bar.pill"].exists, "No pill: the bar never minimizes")
        let actions = [tabs, app.buttons["chat.settings"].firstMatch]
        for item in actions {
            XCTAssertTrue(item.waitForExistence(timeout: 5), item.debugDescription)
            XCTAssertTrue(item.isHittable, "\(item.label) is reachable")
            XCTAssertGreaterThan(item.frame.midX, window.frame.width * 0.75, "\(item.label) is on the right edge")
        }
        XCTAssertLessThan(actions[0].frame.maxY, actions[1].frame.minY, "Tabs first, then Settings")
        // Only actions on the bar: Home's sections are in the tab drawer, as they are in the sidebar unfolded.
        XCTAssertEqual(barSectionButtons(app, window: window), [], "No Home sections on the bar")
        XCTAssertFalse(app.descendants(matching: .any)["duo.sidebar"].exists)
        save("folded-home")

        // The drawer lists every section; a row opens it and puts the drawer away, the bar staying open.
        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch
        tabs.tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "Tabs brings out the drawer")
        for id in sections {
            let row = app.buttons["drawer.section.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "The drawer lists \(id)")
        }
        XCTAssertTrue(app.buttons["drawer.section.chat"].firstMatch.waitForSelection(), "Chat is the one on screen")
        sleep(1)
        save("folded-drawer")
        for id in ["tasks", "artifacts", "builds", "chat"] {
            if !drawer.exists { tabs.tap() }
            let row = app.buttons["drawer.section.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), id)
            row.tap()
            XCTAssertTrue(waitForAbsence(drawer), "Choosing \(id) puts the drawer away")
            XCTAssertTrue(tabs.exists && tabs.isHittable, "The bar stays open after a choice")
            XCTAssertEqual(barSectionButtons(app, window: window), [], "\(id): still no sections on the bar")
            sleep(1)
            save("folded-\(id)")
            tabs.tap()
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["drawer.section.\(id)"].firstMatch.waitForSelection(), "\(id) is on screen")
            tabs.tap()
            XCTAssertTrue(waitForAbsence(drawer), "Tabs puts the drawer away again")
        }

        // Back in Chat: a tap outside and a scroll leave the bar open (nothing to open where it taps).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        XCTAssertTrue(tabs.exists && tabs.isHittable, "A tap outside leaves the bar open")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)))
        XCTAssertTrue(tabs.exists && tabs.isHittable, "A scroll leaves the bar open")

        let field = app.textFields["chat.composer"].firstMatch
        let message = field.waitForExistence(timeout: 10) ? field : app.textViews["chat.composer"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "The message field")
        message.tap()
        // A simulated hardware keyboard hides the software one; the layout must hold either way.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["duo.sidebar"].exists, "Typing on a folded Duo must not show the sidebar")
        XCTAssertTrue(tabs.exists, "The bar stays")
    }

    /// Folded and turned on its side the vertical bar is short and on the left: it still holds only
    /// actions, and Home's sections are reached through the drawer.
    func testFoldedLandscapeReachesHomeSectionsFromTheDrawer() throws {
        let app = try launchFoldedHome(landscape: true)
        let window = app.windows.firstMatch
        for _ in 0..<20 where window.frame.width < window.frame.height { usleep(250_000) }
        guard window.frame.width > window.frame.height else {
            throw XCTSkip("The app didn't turn to landscape (window \(window.frame.size))")
        }
        sleep(1)
        let tabs = app.buttons["home.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15) && tabs.isHittable, "Tabs stays in the short bar")
        XCTAssertEqual(barSectionButtons(app, window: window), [], "No Home sections on the bar")
        save("folded-landscape")
        tabs.tap()
        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "Tabs brings out the drawer")
        let artifacts = app.buttons["drawer.section.artifacts"].firstMatch
        XCTAssertTrue(artifacts.waitForExistence(timeout: 5), "The drawer lists Artifacts")
        if !artifacts.isHittable { drawer.swipeUp() }
        sleep(1)
        save("folded-landscape-drawer")
        artifacts.tap()
        XCTAssertTrue(waitForAbsence(drawer), "Choosing Artifacts puts the drawer away")
        tabs.tap()
        XCTAssertTrue(app.buttons["drawer.section.artifacts"].firstMatch.waitForSelection(), "Artifacts is on screen")
    }

    /// Buttons on the bar's edge named like Home's sections (the bar's own items are actions).
    private func barSectionButtons(_ app: XCUIApplication, window: XCUIElement) -> [String] {
        let titles = ["Chat", "Tasks", "Artifacts", "Builds"]
        let edge = window.frame.width > window.frame.height ? window.frame.width * 0.2 : window.frame.width * 0.75
        let landscape = window.frame.width > window.frame.height
        return app.buttons.allElementsBoundByIndex.filter { button in
            guard titles.contains(button.label), button.exists, !button.frame.isEmpty else { return false }
            return landscape ? button.frame.midX < edge : button.frame.midX > edge
        }.map(\.label)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func launchFoldedHome(landscape: Bool = false) throws -> XCUIApplication {
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
                               "-CantripUITestLane", "home"] + (landscape ? ["-CantripUITestLandscape"] : [])
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        if app.isOnDuoInnerDisplay { throw XCTSkip("Fold the Duo") }
        return app
    }

    /// The folded Duo's outer display, saved to `CANTRIP_UITEST_SHOTS` when set.
    private func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
