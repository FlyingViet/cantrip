import XCTest

/// The tab drawer with sections from a local host such as the Gateway QA host seeded with "Work"
/// and "Personal": headers collapse, and Move to Section files a tab. Run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`.
final class CantripTabSectionsUITests: XCTestCase {
    func testSectionsCollapseAndTabsMoveBetweenThem() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host with sections and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 30))
        tabsButton.tap()
        let personal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Personal,'")).firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 15), "Sections show as headers")
        // The row itself, not its "Reorder Resume" handle.
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label == 'Resume'")).firstMatch
        XCTAssertTrue(resume.exists)
        attach(app, "1-sections")

        personal.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !resume.exists }, "Collapsing hides the section's idle tabs")
        XCTAssertEqual(personal.value as? String, "Collapsed")
        attach(app, "2-collapsed")
        personal.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))

        resume.press(forDuration: 1.2)
        let move = app.buttons["Move to Section"]
        XCTAssertTrue(move.waitForExistence(timeout: 5), "A tab's menu offers Move to Section")
        move.tap()
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        attach(app, "3-move-menu")
        work.tap()
        let workHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Work,'")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { workHeader.label.contains("4 tabs") }, "Resume joins Work: \(workHeader.label)")
        attach(app, "4-moved")
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { return }
            deny.tap()
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
