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
    /// Tasks header on screen on a phone; both end open.
    private func openBoth(_ app: XCUIApplication) {
        if header(app, "views").value as? String == "Collapsed" { header(app, "views").tap() }
        header(app, "views").tap()
        let tasks = header(app, "tasks")
        if tasks.waitForExistence(timeout: 5), tasks.value as? String == "Collapsed" { tasks.tap() }
        header(app, "views").tap()
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
