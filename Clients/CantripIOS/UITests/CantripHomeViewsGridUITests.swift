import XCTest

/// Tasks → Views as thumbnails and the Views and Tasks sections that fold, against a local host
/// with synthetic views (~/.cache/Cantrip/views-grid-qa/run-host.sh). Run with
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`, `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN`,
/// optionally `TEST_RUNNER_CANTRIP_UITEST_LATE_TRIGGER` (a file the host watches: touching it saves a
/// "Follow-ups" view) and `TEST_RUNNER_CANTRIP_UITEST_SHOTS` + `TEST_RUNNER_CANTRIP_UITEST_SHOT_PREFIX`.
final class CantripHomeViewsGridUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["CANTRIP_UITEST_HOME_URL"] != nil, env["CANTRIP_UITEST_HOME_TOKEN"] != nil else {
            throw XCTSkip("Start the views-grid QA host and set CANTRIP_UITEST_HOME_URL and CANTRIP_UITEST_HOME_TOKEN")
        }
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", env["CANTRIP_UITEST_HOME_URL"]!,
                               "-CantripUITestRemoteToken", env["CANTRIP_UITEST_HOME_TOKEN"]!, "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 3) else { break }
            deny.tap()
        }
        let tasks = app.tabBars.buttons["Tasks"].exists ? app.tabBars.buttons["Tasks"] : app.buttons["Tasks"].firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 30), "Home's Tasks tab")
        tasks.tap()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let folder = env["CANTRIP_UITEST_SHOTS"] else { return }
        let prefix = env["CANTRIP_UITEST_SHOT_PREFIX"] ?? "ios"
        Thread.sleep(forTimeInterval: 1.5)
        let file = URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name)")
        if env["CANTRIP_UITEST_SHOT_WATCHER"] != nil {
            // On a Duo XCUIScreen.main is the outer display: a Mac watcher shoots the inner one.
            FileManager.default.createFile(atPath: file.path + ".request", contents: Data())
            for _ in 0..<40 where FileManager.default.fileExists(atPath: file.path + ".request") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return
        }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file.appendingPathExtension("png"))
    }

    /// Earlier runs on this simulator may have left a section folded. Folding the views brings the
    /// Tasks header on screen on a phone (Upcoming, on a Mac that lists it, is folded out of the way); both end open.
    private func openBoth(_ app: XCUIApplication) {
        if header(app, "views").value as? String == "Collapsed" { header(app, "views").tap() }
        header(app, "views").tap()
        if header(app, "upcoming").exists, header(app, "upcoming").value as? String == "Expanded" { header(app, "upcoming").tap() }
        let tasks = header(app, "tasks")
        if tasks.waitForExistence(timeout: 5), tasks.value as? String == "Collapsed" { tasks.tap() }
        header(app, "views").tap()
    }

    /// The screen's Back: in the navigation bar, or in the Duo's vertical bar (not the sidebar's Tasks).
    private func goBack(_ app: XCUIApplication) {
        let candidates = [app.buttons["BackButton"], app.navigationBars.buttons.firstMatch,
                          app.buttons.matching(NSPredicate(format: "label == 'Back'")).firstMatch]
        _ = candidates[0].waitForExistence(timeout: 3)
        guard let back = candidates.first(where: { $0.exists && $0.isHittable }) else {
            return XCTFail("No Back button: \(app.buttons.allElementsBoundByIndex.prefix(20).map { "\($0.identifier)|\($0.label)" })")
        }
        back.tap()
    }

    private func taskRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Bills tracker'")).firstMatch
    }

    private func header(_ app: XCUIApplication, _ section: String) -> XCUIElement {
        app.buttons["home.tasks.section.\(section)"].firstMatch
    }

    private func thumbnail(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.view.' AND label BEGINSWITH %@", name)).firstMatch
    }

    func testViewsShowAsThumbnailsAndSectionsFoldAndStayFolded() throws {
        var app = launch()
        XCTAssertTrue(header(app, "views").waitForExistence(timeout: 30), "the Views header")
        openBoth(app)
        XCTAssertTrue(thumbnail(app, named: "Homelab").waitForExistence(timeout: 20), "a thumbnail per view")
        XCTAssertEqual(header(app, "views").value as? String, "Expanded")
        shot(app, "expanded")
        app.swipeUp()
        app.swipeDown()
        XCTAssertFalse(app.descendants(matching: .any)["home.viewScreen"].exists, "a swipe never opens a view")

        header(app, "views").tap()
        XCTAssertEqual(header(app, "views").value as? String, "Collapsed")
        let label = header(app, "views").label
        XCTAssertTrue(label.hasPrefix("Views, ") && label.hasSuffix(" views"), "the count while folded: \(label)")
        XCTAssertFalse(thumbnail(app, named: "Homelab").exists, "folded views hide their thumbnails")
        XCTAssertTrue(taskRow(app).waitForExistence(timeout: 10), "the tasks move up")
        shot(app, "views-collapsed")

        header(app, "tasks").tap()
        XCTAssertEqual(header(app, "tasks").value as? String, "Collapsed")
        XCTAssertEqual(header(app, "tasks").label, "Tasks, 4 tasks")
        XCTAssertFalse(taskRow(app).waitForExistence(timeout: 2), "folded tasks hide their rows")
        header(app, "views").tap()
        XCTAssertTrue(thumbnail(app, named: "Homelab").waitForExistence(timeout: 10))
        shot(app, "tasks-collapsed")

        app.terminate()
        app = launch()
        XCTAssertTrue(thumbnail(app, named: "Homelab").waitForExistence(timeout: 30), "views stayed open")
        header(app, "views").tap()
        XCTAssertTrue(header(app, "tasks").waitForExistence(timeout: 10))
        XCTAssertEqual(header(app, "tasks").value as? String, "Collapsed", "remembered on this device")
        XCTAssertFalse(taskRow(app).exists)
        header(app, "tasks").tap()
        XCTAssertTrue(taskRow(app).waitForExistence(timeout: 10))
        header(app, "views").tap()
        XCTAssertTrue(thumbnail(app, named: "Homelab").waitForExistence(timeout: 10))

        thumbnail(app, named: "Homelab").tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.viewScreen"].waitForExistence(timeout: 15), "a tap opens the view")
    }

    /// Each thumbnail opens its own view, and Back returns to the grid. (The grid is one list row;
    /// with a link per thumbnail, every tap opened the same view.)
    func testEachThumbnailOpensItsOwnViewAndBackReturns() throws {
        let app = launch()
        XCTAssertTrue(header(app, "views").waitForExistence(timeout: 30))
        openBoth(app)
        let names = (env["CANTRIP_UITEST_VIEW_NAMES"] ?? "This week,Homelab,Pipeline").split(separator: ",").map(String.init)
        for name in names {
            let card = thumbnail(app, named: name)
            XCTAssertTrue(card.waitForExistence(timeout: 30), "\(name)'s thumbnail")
            card.tap()
            XCTAssertTrue(app.descendants(matching: .any)["home.viewScreen"].waitForExistence(timeout: 15), "\(name) opens a view")
            let title = app.navigationBars.staticTexts[name].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 10),
                          "tapping \(name) opens \(name), not \(app.navigationBars.staticTexts.allElementsBoundByIndex.map(\.label))")
            shot(app, "open-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            goBack(app)
            XCTAssertTrue(thumbnail(app, named: name).waitForExistence(timeout: 15), "Back returns to the grid")
            XCTAssertFalse(app.descendants(matching: .any)["home.viewScreen"].exists, "the view closed")
        }
    }

    /// Each thumbnail's ⋯ menu is its own: Unpin on a pinned view, Pin on one that isn't. (A long
    /// press in the one list row showed the first view's menu for every card.)
    func testEachThumbnailsMenuIsItsOwn() throws {
        let app = launch()
        XCTAssertTrue(header(app, "views").waitForExistence(timeout: 30))
        openBoth(app)
        for (name, item) in [("This week", "Unpin"), ("Pipeline", "Pin"), ("Homelab", "Unpin")] {
            let menu = app.buttons.matching(NSPredicate(format: "label == %@", "More for \(name)")).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 30), "\(name)'s menu button")
            menu.tap()
            let menuItem = app.buttons[item].firstMatch
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "\(name)'s menu offers \(item)")
            XCTAssertFalse(app.descendants(matching: .any)["home.viewScreen"].exists, "the menu doesn't open the view")
            shot(app, "menu-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            // Close the menu without choosing anything: a tap on the dimmed screen just below it
            // (placed from the item, so it lands right on the Duo's inner display too).
            menuItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 4)).tap()
            XCTAssertTrue(menuItem.waitForNonExistence(timeout: 10),
                          "the menu closed: \(app.buttons.matching(NSPredicate(format: "label == %@", item)).allElementsBoundByIndex.map { "\($0.identifier) \($0.frame) hittable=\($0.isHittable)" })")
        }
    }

    func testAViewSavedWhileTasksIsOpenAppearsWithoutAReload() throws {
        guard let trigger = env["CANTRIP_UITEST_LATE_TRIGGER"] else { throw XCTSkip("Set CANTRIP_UITEST_LATE_TRIGGER") }
        let app = launch()
        XCTAssertTrue(header(app, "views").waitForExistence(timeout: 30))
        openBoth(app)
        XCTAssertTrue(thumbnail(app, named: "Homelab").waitForExistence(timeout: 30))
        XCTAssertFalse(thumbnail(app, named: "Follow-ups").exists)
        shot(app, "live-before")
        FileManager.default.createFile(atPath: trigger, contents: Data())
        XCTAssertTrue(thumbnail(app, named: "Follow-ups").waitForExistence(timeout: 30), "the new view shows on the next poll")
        shot(app, "live-after")
    }
}
