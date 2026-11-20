import XCTest

/// iPhone Duo unfolded in a window too narrow for the sidebar and the chat side by side (split
/// screen, or the Duo held upright): the sidebar slides over the chat instead of narrowing it, and
/// tapping outside it or picking a tab puts it away; with it put away, a swipe brings out the tab
/// drawer with Home's sections. Run on an unfolded iPhone Duo simulator held
/// upright with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>` (and
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if the host's token isn't `duo-qa-token`).
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` asks a watcher for inner-display screenshots.
final class CantripDuoSidebarOverlayUITests: XCTestCase {
    private var shots: String?

    func testANarrowWindowSlidesTheSidebarOverTheChat() throws {
        let (app, toggle, window) = try launchNarrow(lane: "cantrip")
        // Over the chat the sidebar is modal, which VoiceOver (and XCUITest) treat like an alert.
        let sidebar = app.descendants(matching: .any)["duo.sidebar"].firstMatch
        XCTAssertFalse(sidebar.exists, "A narrow window starts with the sidebar put away")
        let field = app.textFields["chat.composer"].firstMatch
        let composer = field.waitForExistence(timeout: 10) ? field : app.textViews["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "The message field")
        let chatWidth = composer.frame.width
        save(app, "narrow-closed")

        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The toggle opens the sidebar")
        sleep(1)
        XCTAssertEqual(toggle.label, "Hide Sidebar")
        XCTAssertEqual(composer.frame.width, chatWidth, accuracy: 1, "The sidebar slides over the chat; the chat keeps its width")
        XCTAssertLessThan(sidebar.frame.minX, 1, "It slides in from the left edge")
        save(app, "narrow-open")

        // A tap beside the sidebar puts it away.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        XCTAssertTrue(waitForAbsence(sidebar), "Tapping outside closes it")
        XCTAssertEqual(toggle.label, "Show Sidebar")

        // So does picking a tab.
        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let rows = sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'duo.sidebar.tab.'"))
        let row = rows.allElementsBoundByIndex.dropFirst().first { $0.isHittable } ?? rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The sidebar lists the tabs")
        row.tap()
        XCTAssertTrue(waitForAbsence(sidebar), "Picking a tab closes it")
        save(app, "narrow-picked")

        // The toggle closes it too.
        toggle.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(waitForAbsence(sidebar), "The toggle closes it again")
    }

    /// With the sidebar put away (as it starts upright), a swipe right brings out the tab drawer, which
    /// lists Home's sections under Cantrip Home as it does folded; a row opens Home on that section.
    func testASwipeOpensTheDrawerWithHomesSections() throws {
        let (app, _, window) = try launchNarrow(lane: "home")
        XCTAssertFalse(app.descendants(matching: .any)["duo.sidebar"].exists, "The sidebar starts put away")
        let drawer = app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch
        func openDrawer() {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
            XCTAssertTrue(drawer.waitForExistence(timeout: 5), "A swipe right brings out the drawer")
        }
        openDrawer()
        XCTAssertTrue(app.descendants(matching: .any)["drawer.homeHeader"].firstMatch.waitForExistence(timeout: 5),
                      "Cantrip Home heads the sections")
        for id in ["chat", "tasks", "artifacts", "builds"] {
            let row = app.buttons["drawer.section.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "The drawer lists \(id)")
        }
        XCTAssertTrue(app.buttons["drawer.section.chat"].firstMatch.waitForSelection(), "Chat is the one on screen")
        sleep(1)
        save(app, "upright-drawer")
        for id in ["tasks", "artifacts", "builds", "chat"] {
            if !drawer.exists { openDrawer() }
            app.buttons["drawer.section.\(id)"].firstMatch.tap()
            XCTAssertTrue(waitForAbsence(drawer), "Choosing \(id) puts the drawer away")
            sleep(1)
            save(app, "upright-\(id)")
            openDrawer()
            XCTAssertTrue(app.buttons["drawer.section.\(id)"].firstMatch.waitForSelection(), "\(id) is on screen")
        }
    }

    /// Launches on an unfolded Duo whose window can't fit the sidebar beside the chat (upright).
    private func launchNarrow(lane: String) throws -> (XCUIApplication, XCUIElement, XCUIElement) {
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
                               "-CantripUITestLane", lane]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let toggle = app.buttons["duo.rail.sidebar"].firstMatch
        guard toggle.waitForExistence(timeout: 15) else {
            throw XCTSkip("Unfold the Duo: the rail's sidebar toggle shows only unfolded")
        }
        let window = app.windows.firstMatch
        guard window.frame.width - 288 < 400 else {
            throw XCTSkip("Needs a narrow unfolded window (upright or split screen), got \(window.frame.size)")
        }
        return (app, toggle, window)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// Asks a watcher on the Mac for the unfolded display (`simctl io <udid> screenshot --display=3`):
    /// writes `<name>.request` into the shots folder and waits for `<name>.png`.
    private func save(_ app: XCUIApplication, _ name: String) {
        guard let shots else { return }
        let folder = URL(fileURLWithPath: shots)
        try? Data().write(to: folder.appendingPathComponent("\(name).request"))
        let picture = folder.appendingPathComponent("\(name).png").path
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: picture) { usleep(250_000) }
    }
}
