import XCTest

/// iPhone Duo folded (the simulator's default pose): Cantrip Home keeps the iPhone layout while
/// typing, and its navigation is one bar on the vertical bar's edge that is always open (actions,
/// then Home's sections at the bottom, none covering another) and stays open after a choice, a tap
/// outside or a scroll.
/// Run on an iPhone Duo simulator with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// (any fixture host that serves Cantrip Home, e.g. `fake_home_host.py`; set
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if its token isn't `duo-qa-token`).
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` saves screenshots.
final class CantripDuoFoldedUITests: XCTestCase {
    private let sectionIDs = ["chat", "tasks", "artifacts", "builds"].map { "duo.bar.section.\($0)" }

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
        let sections = sectionIDs.map { app.buttons[$0].firstMatch }
        for item in actions + sections {
            XCTAssertTrue(item.waitForExistence(timeout: 5), item.debugDescription)
            XCTAssertTrue(item.isHittable, "\(item.label) is reachable")
            XCTAssertGreaterThan(item.frame.midX, window.frame.width * 0.75, "\(item.label) is on the right edge")
        }
        // One bar, in order: the actions, then Home's sections at the bottom; nothing covers anything.
        let frames = (actions + sections).map(\.frame)
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.insetBy(dx: 2, dy: 2).intersects(other.insetBy(dx: 2, dy: 2)), "\(frame) covers \(other)")
            }
        }
        XCTAssertLessThan(actions.map(\.frame.maxY).max()!, sections.map(\.frame.minY).min()!, "Sections below the actions")
        XCTAssertLessThan(sections[0].frame.midX - sections[3].frame.midX, 2, "One column")
        XCTAssertFalse(app.descendants(matching: .any)["duo.sidebar"].exists)
        save("folded-home")

        // Choosing a section selects it; the bar stays open.
        sections[1].tap()
        XCTAssertTrue(sections[1].waitForSelection(), "Tasks is selected")
        XCTAssertTrue(tabs.exists && sections[0].exists, "The bar stays open after a choice")
        save("folded-tasks")

        // A tap outside and a scroll leave it open too (in Chat: nothing to open where it taps).
        sections[0].tap()
        XCTAssertTrue(sections[0].waitForSelection(), "Back to Chat")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        XCTAssertTrue(tabs.exists && sections[0].isHittable, "A tap outside leaves the bar open")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)))
        XCTAssertTrue(tabs.exists && sections[0].isHittable, "A scroll leaves the bar open")

        let field = app.textFields["chat.composer"].firstMatch
        let message = field.waitForExistence(timeout: 10) ? field : app.textViews["chat.composer"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "The message field")
        message.tap()
        // A simulated hardware keyboard hides the software one; the layout must hold either way.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["duo.sidebar"].exists, "Typing on a folded Duo must not show the sidebar")
        XCTAssertTrue(sections[0].exists, "The bar stays")
    }

    /// Folded and turned on its side the vertical bar is short: Home's sections stay in the bar and
    /// the actions move into its overflow first.
    func testFoldedLandscapeKeepsHomeSectionsInTheBar() throws {
        let app = try launchFoldedHome(landscape: true)
        let window = app.windows.firstMatch
        for _ in 0..<20 where window.frame.width < window.frame.height { usleep(250_000) }
        guard window.frame.width > window.frame.height else {
            throw XCTSkip("The app didn't turn to landscape (window \(window.frame.size))")
        }
        sleep(1)
        for id in sectionIDs {
            let section = app.buttons[id].firstMatch
            XCTAssertTrue(section.waitForExistence(timeout: 15) && section.isHittable, "\(id) stays in the bar")
        }
        save("folded-landscape")
        app.buttons[sectionIDs[2]].firstMatch.tap()
        XCTAssertTrue(app.buttons[sectionIDs[2]].firstMatch.waitForSelection(), "Artifacts is selected")
        XCTAssertTrue(app.buttons[sectionIDs[0]].firstMatch.exists, "The bar stays open")
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
