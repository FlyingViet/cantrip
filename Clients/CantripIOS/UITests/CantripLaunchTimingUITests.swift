import XCTest

/// Times a cold launch into Cantrip Home and opening Tasks, against a host behind a link shaper
/// (~/.cache/Cantrip/launch-qa: run-host.sh + shape.py, ~300 ms round trip and ~1 Mbps). The first
/// launch pairs and leaves the app as a person would; the second, after the app was terminated, is
/// timed. Run with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL`, `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN`,
/// `TEST_RUNNER_CANTRIP_UITEST_TIMING` (a JSON file the timestamps go to, in Mac epoch seconds),
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TEXT` (text from Home's latest reply) and
/// `TEST_RUNNER_CANTRIP_UITEST_TASK_TEXT` (a task's title).
final class CantripLaunchTimingUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["CANTRIP_UITEST_HOME_URL"] != nil, env["CANTRIP_UITEST_HOME_TOKEN"] != nil,
              env["CANTRIP_UITEST_TIMING"] != nil else {
            throw XCTSkip("Start the launch-qa host and shaper and set CANTRIP_UITEST_HOME_URL, _TOKEN and _TIMING")
        }
        continueAfterFailure = false
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", env["CANTRIP_UITEST_HOME_URL"]!,
                               "-CantripUITestRemoteToken", env["CANTRIP_UITEST_HOME_TOKEN"]!, "-CantripUITestLane", "home"]
        return app
    }

    private func dismissAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 3) else { break }
            deny.tap()
        }
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func sectionButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title].firstMatch
    }

    /// Polls without waitForExistence's coarse interval; returns when `element` appeared.
    private func time(until element: XCUIElement, timeout: TimeInterval = 90) -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return Date() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func testColdLaunchAndOpeningTasks() throws {
        let homeText = env["CANTRIP_UITEST_HOME_TEXT"] ?? "Short item and current since"
        let taskText = env["CANTRIP_UITEST_TASK_TEXT"] ?? "Short next current since"
        let app = makeApp()

        // First launch: pairs, loads Home and Tasks, folds Views so Tasks' rows lead the screen, and
        // leaves Home on its chat.
        let primed = Date()
        app.launch()
        dismissAlerts()
        XCTAssertNotNil(time(until: element(app, containing: homeText)), "Home's latest reply")
        let firstContent = Date()
        sectionButton(app, "Tasks").tap()
        // Upcoming lists the same tasks' next runs: folded, only Tasks' own rows carry their titles.
        let views = app.buttons["home.tasks.section.views"].firstMatch
        if views.waitForExistence(timeout: 60), views.value as? String != "Collapsed" { views.tap() }
        let upcoming = app.buttons["home.tasks.section.upcoming"].firstMatch
        if upcoming.waitForExistence(timeout: 30), upcoming.value as? String != "Collapsed" { upcoming.tap() }
        XCTAssertNotNil(time(until: element(app, containing: taskText)), "a task row")
        let tasksShown = Date()
        if let dump = env["CANTRIP_UITEST_DUMP"] {
            try? app.debugDescription.write(toFile: dump, atomically: true, encoding: .utf8)
        }
        Thread.sleep(forTimeInterval: 25)
        sectionButton(app, "Chat").tap()
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
        Thread.sleep(forTimeInterval: 3)

        // Second launch, timed: the app was terminated, as after iOS reclaims it in the background.
        let launched = Date()
        app.launch()
        let homeShown = time(until: element(app, containing: homeText))
        XCTAssertNotNil(homeShown, "Home's latest reply after a cold launch")
        let tapped = Date()
        sectionButton(app, "Tasks").tap()
        let taskShown = time(until: element(app, containing: taskText))
        XCTAssertNotNil(taskShown, "a task row after opening Tasks")
        let saved = app.descendants(matching: .any).matching(identifier: "remote.savedCopy").firstMatch
        let savedSeen = saved.exists
        var current: Date?
        if savedSeen {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, saved.exists { Thread.sleep(forTimeInterval: 0.1) }
            current = Date()
        }
        // Leaves the app open long enough for the shaper's log to hold every launch request.
        Thread.sleep(forTimeInterval: max(0, 30 - Date().timeIntervalSince(launched)))

        var timing: [String: Any] = [
            "primeLaunch": primed.timeIntervalSince1970, "primeFirstContent": firstContent.timeIntervalSince1970,
            "primeTasksShown": tasksShown.timeIntervalSince1970,
            "launch": launched.timeIntervalSince1970, "tasksTapped": tapped.timeIntervalSince1970,
            "savedCopyShown": savedSeen,
        ]
        timing["firstContent"] = homeShown?.timeIntervalSince1970
        timing["tasksShown"] = taskShown?.timeIntervalSince1970
        timing["savedCopyCleared"] = current?.timeIntervalSince1970
        let data = try JSONSerialization.data(withJSONObject: timing, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: env["CANTRIP_UITEST_TIMING"]!))
    }
}
