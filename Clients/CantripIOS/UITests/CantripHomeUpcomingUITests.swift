import XCTest

/// Tasks → Upcoming against a local host with made-up steps, a wait and paused Home tasks. Run with
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`, `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN`
/// and optionally `TEST_RUNNER_CANTRIP_UITEST_SHOTS` + `TEST_RUNNER_CANTRIP_UITEST_SHOT_PREFIX`. It
/// resumes then pauses again one `task:` item, and cancels one `step:` item only with
/// `TEST_RUNNER_CANTRIP_UITEST_CANCEL_STEP=1`; it never acts on Mac jobs or detached jobs.
final class CantripHomeUpcomingUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["CANTRIP_UITEST_HOME_URL"] != nil, env["CANTRIP_UITEST_HOME_TOKEN"] != nil else {
            throw XCTSkip("Start the Upcoming QA host and set CANTRIP_UITEST_HOME_URL and CANTRIP_UITEST_HOME_TOKEN")
        }
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", env["CANTRIP_UITEST_HOME_URL"]!,
                               "-CantripUITestRemoteToken", env["CANTRIP_UITEST_HOME_TOKEN"]!, "-CantripUITestLane", "home"] + extra
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

    private func shot(_ name: String) {
        guard let folder = env["CANTRIP_UITEST_SHOTS"] else { return }
        let prefix = env["CANTRIP_UITEST_SHOT_PREFIX"] ?? "ios"
        Thread.sleep(forTimeInterval: 1.5)
        let file = URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name)")
        if env["CANTRIP_UITEST_SHOT_WATCHER"] != nil {
            // A watcher on the Mac shoots the simulator (`simctl io … screenshot`) and removes the request.
            FileManager.default.createFile(atPath: file.path + ".request", contents: Data())
            for _ in 0..<40 where FileManager.default.fileExists(atPath: file.path + ".request") {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return
        }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file.appendingPathExtension("png"))
    }

    private func header(_ app: XCUIApplication, _ section: String) -> XCUIElement {
        app.buttons["home.tasks.section.\(section)"].firstMatch
    }

    private func row(_ app: XCUIApplication, _ format: String, _ arguments: Any...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: arguments)).firstMatch
    }

    /// Whether `element` is in the list's visible part (clear of the header and the tab bar).
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame, screen = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 110)
        return !frame.isEmpty && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Scrolls down, then back up, until `element` is on screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<12 where !onScreen(app, element) { app.swipeUp() }
        for _ in 0..<24 where !onScreen(app, element) { app.swipeDown() }
        XCTAssertTrue(onScreen(app, element), "on screen")
    }

    /// Taps a row's button. VoiceOver reads the row as one element; UI tests still see the button.
    private func tapTrailingButton(_ app: XCUIApplication, of element: XCUIElement) {
        reveal(app, element)
        element.buttons.firstMatch.tap()
    }

    /// Pauses a task on the host directly, so one this test resumed ends paused even when a step fails.
    private func pauseOnHost(_ id: String) {
        guard let base = env["CANTRIP_UITEST_HOME_URL"], let token = env["CANTRIP_UITEST_HOME_TOKEN"],
              let url = URL(string: base + "/api/v1/home/upcoming/cancel") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    func testUpcomingGroupsItemsAsksBeforeCancellingAndResumes() throws {
        let app = launch()
        let upcoming = header(app, "upcoming")
        XCTAssertTrue(upcoming.waitForExistence(timeout: 30), "the Upcoming header")
        if header(app, "views").exists, header(app, "views").value as? String == "Expanded" { header(app, "views").tap() }
        if upcoming.value as? String == "Collapsed" { upcoming.tap() }
        XCTAssertTrue(upcoming.label.hasPrefix("Upcoming, "), upcoming.label)
        XCTAssertTrue(app.staticTexts["Next up"].waitForExistence(timeout: 20), "the Next up heading")
        shot("upcoming")

        // Show all stays open, so a resumed task is listed wherever its next run falls.
        let showAll = app.buttons["home.upcoming.showAll"]
        if showAll.exists, showAll.label.hasPrefix("Show all") {
            showAll.tap()
            // Show fewer now sits below the whole group, off screen.
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show all'")).firstMatch.waitForExistence(timeout: 2))
            shot("upcoming-all")
        }

        let step = row(app, "identifier BEGINSWITH 'home.upcoming.step:'")
        XCTAssertTrue(step.waitForExistence(timeout: 10), "a scheduled step")
        XCTAssertTrue(step.label.contains("set up by"), step.label)
        let stepID = step.identifier
        tapTrailingButton(app, of: step)
        let keep = app.alerts.buttons["Keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Cancel asks first")
        XCTAssertTrue(app.alerts.firstMatch.label.hasPrefix("Cancel “"), app.alerts.firstMatch.label)
        shot("upcoming-confirm")
        keep.tap()
        XCTAssertTrue(app.descendants(matching: .any)[stepID].exists, "Keep cancels nothing")
        let status = app.descendants(matching: .any)["home.upcoming.status"]
        XCTAssertFalse(status.exists)

        if env["CANTRIP_UITEST_CANCEL_STEP"] == "1" {
            tapTrailingButton(app, of: app.descendants(matching: .any)[stepID])
            XCTAssertTrue(keep.waitForExistence(timeout: 5))
            app.alerts.buttons["Cancel"].tap()
            XCTAssertTrue(status.waitForExistence(timeout: 10), "what the Mac did shows for a moment")
            XCTAssertTrue(status.label.hasPrefix("Cancelled"), status.label)
            shot("upcoming-cancelled")
            XCTAssertFalse(app.descendants(matching: .any)[stepID].waitForExistence(timeout: 2), "the step is gone")
        }

        let paused = row(app, "identifier BEGINSWITH 'home.upcoming.task:' AND label CONTAINS ', Paused, '")
        reveal(app, paused)
        let taskID = paused.identifier
        addTeardownBlock { self.pauseOnHost(String(taskID.dropFirst("home.upcoming.".count))) }
        tapTrailingButton(app, of: paused)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Resumed"), "Resume acts at once: \(status.label)")
        shot("upcoming-resumed")
        let resumed = row(app, "identifier == %@ AND NOT (label CONTAINS ', Paused, ')", taskID)
        reveal(app, resumed)

        tapTrailingButton(app, of: resumed)
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Pause asks first")
        app.alerts.buttons["Pause"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let pausedAgain = row(app, "identifier == %@ AND label CONTAINS ', Paused, '", taskID)
        reveal(app, pausedAgain)
        XCTAssertTrue(pausedAgain.exists, "paused again")
    }

    /// Rows stack their button under the text at the accessibility text sizes. Shoots only.
    func testUpcomingAtAnAccessibilityTextSize() throws {
        guard env["CANTRIP_UITEST_SHOTS"] != nil else { throw XCTSkip("Set CANTRIP_UITEST_SHOTS") }
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let upcoming = header(app, "upcoming")
        XCTAssertTrue(upcoming.waitForExistence(timeout: 30))
        if upcoming.value as? String == "Collapsed" { upcoming.tap() }
        XCTAssertTrue(row(app, "identifier BEGINSWITH 'home.upcoming.'").waitForExistence(timeout: 20))
        shot("upcoming-ax")
    }
}
