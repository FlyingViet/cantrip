import XCTest

/// Real swipes through a long paged conversation served by a local fixture host
/// (`fake_remote_host.py`): older pages load as the user scrolls up, with no tap, no
/// "Load more messages" control, and no jump in the text being read.
/// Run with `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>`.
final class CantripHistoryUITests: XCTestCase {
    func testScrollingUpLoadsTheWholeHistoryWithoutTapping() throws {
        guard let url = ProcessInfo.processInfo.environment["CANTRIP_UITEST_REMOTE_URL"] else {
            throw XCTSkip("Start the fixture host and set CANTRIP_UITEST_REMOTE_URL")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", "history-qa-token"]
        app.launch()
        dismissSystemAlerts()

        let latest = app.staticTexts["Prompt 60: what happened in step 60?"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30), "The newest exchange opens first")
        XCTAssertTrue(app.staticTexts["Prompt 58: what happened in step 58?"].exists)
        XCTAssertFalse(app.staticTexts["Prompt 57: what happened in step 57?"].exists,
                       "Only the newest three exchanges load before scrolling")
        attach(app, "1-opened-at-latest")

        let transcript = app.scrollViews.firstMatch
        let status = app.descendants(matching: .any)["cantrip.olderMessagesStatus"]
        let first = app.staticTexts["Prompt 1: what happened in step 1?"]
        XCTAssertTrue(status.exists, "The idle history row stays reachable for VoiceOver")
        XCTAssertEqual(status.label, "Earlier messages")
        var sawLoading = false
        var checkedAnchor = false
        for swipe in 0..<80 where !first.exists {
            XCTAssertFalse(app.buttons["Load more messages"].exists, "No tap-to-load control ever appears")
            XCTAssertFalse(app.buttons["cantrip.retryOlderMessages"].exists, "No page fails")
            transcript.swipeDown(velocity: .fast)
            if status.exists, status.label == "Loading older messages" {
                if !sawLoading { attach(app, "2-loading-indicator") }
                sawLoading = true
                Thread.sleep(forTimeInterval: 0.4)
                if !checkedAnchor, status.label == "Loading older messages", let label = visiblePrompt(in: app) {
                    let reading = app.staticTexts[label]
                    let before = reading.frame.minY
                    _ = waitUntil(timeout: 5) { status.label != "Loading older messages" }
                    Thread.sleep(forTimeInterval: 0.3)
                    XCTAssertEqual(reading.frame.minY, before, accuracy: 2,
                                   "Swipe \(swipe): inserting older messages keeps \(label) in place")
                    checkedAnchor = true
                }
            }
        }
        XCTAssertTrue(first.exists, "Scrolling up alone reaches the start of the conversation")
        XCTAssertTrue(sawLoading, "A small inline indicator shows while a page loads")
        XCTAssertTrue(checkedAnchor)
        for i in [1, 15, 30, 45, 57] {
            XCTAssertTrue(app.staticTexts["Prompt \(i): what happened in step \(i)?"].exists, "Prompt \(i) loaded")
        }
        transcript.swipeDown(velocity: .fast)
        attach(app, "3-start-of-history")

        let latestButton = app.buttons["Scroll to latest message"]
        XCTAssertTrue(latestButton.waitForExistence(timeout: 5), "The Latest button is offered while reading history")
        latestButton.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { latest.isHittable }, "Latest returns to the newest message")
        XCTAssertTrue(latestButton.waitForNonExistence(timeout: 5))
        attach(app, "4-back-at-latest")
    }

    /// Fresh simulators ask for speech recognition at launch; answer it so it doesn't cover the chat.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { return }
            deny.tap()
        }
    }

    /// The label of the topmost prompt fully on screen, used to confirm the reading position holds.
    /// Returned by label because index-bound elements shift when older messages are inserted.
    private func visiblePrompt(in app: XCUIApplication) -> String? {
        let screen = app.windows.firstMatch.frame
        let prompts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Prompt '")).allElementsBoundByIndex
        return prompts.first { $0.frame.minY > screen.minY + 140 && $0.frame.maxY < screen.maxY - 200 }?.label
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
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
