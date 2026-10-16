import XCTest

/// Real edge swipes out of a project tab, against the tabs fixture host (TabsQAHost on :58736).
/// Run with `TEST_RUNNER_CANTRIP_UITEST_TABS_URL=http://127.0.0.1:58736`
/// and `TEST_RUNNER_CANTRIP_UITEST_TABS_TOKEN=tabs-qa-token`.
final class CantripTabBackSwipeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var host: URL!
    private var token = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CANTRIP_UITEST_TABS_URL"], let token = env["CANTRIP_UITEST_TABS_TOKEN"] else {
            throw XCTSkip("Start the tabs fixture host and set CANTRIP_UITEST_TABS_URL and CANTRIP_UITEST_TABS_TOKEN")
        }
        continueAfterFailure = false
        host = URL(string: url)
        self.token = token
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        XCTAssertTrue(homeReply.waitForExistence(timeout: 30), "Home must load from the fixture host")
    }

    /// Home's conversation: its first reply, or the handoff posted later (which may scroll it away).
    private var homeReply: XCUIElement {
        app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "109 users", "taking this"
        )).firstMatch
    }
    private var tabsButton: XCUIElement { app.buttons["Tabs"].firstMatch }
    private var backPill: XCUIElement { app.buttons["Home"].firstMatch }

    /// Sends Home a message as another device would, so Home keeps changing while a tab is open.
    private func postToHome(_ text: String) {
        var request = URLRequest(url: host.appendingPathComponent(
            "api/v1/sessions/7EAE0CE5-8C8B-4652-9FD0-214867A90E5D/messages"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "mode": "queue"])
        let done = expectation(description: "posted to Home")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func openTab(_ title: String) {
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 5))
        tabsButton.tap()
        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) is listed in the drawer")
        row.tap()
        XCTAssertTrue(backPill.waitForExistence(timeout: 5), "\(title) opened full screen")
    }

    /// Drags from the leading edge to `x` points, holding before lifting so the release has no flick.
    private func edgeSwipe(to x: CGFloat, hold: TimeInterval) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.55)).withOffset(CGVector(dx: 6, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.56)).withOffset(CGVector(dx: x, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 300, thenHoldForDuration: hold)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEdgeSwipeDragsTheTabAwayAndAShortSwipeSpringsBack() {
        // Home hands work to a tab and its card keeps changing while NetLib is open.
        postToHome("qa-complete fix the lineup sorting")
        sleep(2)
        openTab("NetLib")
        attach("NetLib tab")

        edgeSwipe(to: 70, hold: 0.4)
        sleep(1)
        XCTAssertTrue(backPill.exists, "Released before a third of the width: still in the tab")
        XCTAssertFalse(tabsButton.exists)
        let pill = backPill.frame
        XCTAssertLessThan(pill.minX, 40, "The tab sprang back to its resting place")

        edgeSwipe(to: app.frame.width * 0.62, hold: 1.2)
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 5), "A long swipe returns to Home")
        XCTAssertFalse(backPill.exists)
        XCTAssertTrue(homeReply.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(tabsButton.frame.minX, 0, "Home is in place, not left mid-slide")
        attach("Home after swipe")

        openTab("Alter")
        backPill.tap()
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 5), "‹ Home slides back to Home")
        XCTAssertTrue(homeReply.waitForExistence(timeout: 5))
        attach("Home after back button")
    }
}
