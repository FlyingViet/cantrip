import XCTest

/// Real swipes up a long tab served by the Mac's own host code (~/.cache/Cantrip/paging-qa: run-host.sh with a
/// 40-exchange tab whose newest replies carry ~250 KB of reasoning): it opens at the newest page, older pages
/// load while scrolling until the first message, every prompt shows once, the text being read stays put,
/// and the newest reply keeps streaming and a new turn arrives while older pages load.
/// Env: `TEST_RUNNER_CANTRIP_UITEST_HOME_URL`, `_HOME_TOKEN`, `_TAB_ID`, `_PAGING_PROMPTS` (exchanges in the
/// tab) and `_PAGING_SIGNALS` (the host's fixture folder: the test creates `working` and `newturn` there).
final class CantripTabPagingUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testScrollingUpPagesALongTabBackToItsFirstMessage() throws {
        guard let url = env["CANTRIP_UITEST_HOME_URL"], let tab = env["CANTRIP_UITEST_TAB_ID"],
              let count = env["CANTRIP_UITEST_PAGING_PROMPTS"].flatMap(Int.init) else {
            throw XCTSkip("Start the paging-qa host and set CANTRIP_UITEST_HOME_URL, _TAB_ID and _PAGING_PROMPTS")
        }
        continueAfterFailure = false
        let signals = env["CANTRIP_UITEST_PAGING_SIGNALS"].map { URL(fileURLWithPath: $0) }
        func signal(_ name: String) {
            guard let signals else { return }
            FileManager.default.createFile(atPath: signals.appendingPathComponent(name).path, contents: Data())
        }
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", env["CANTRIP_UITEST_HOME_TOKEN"] ?? "",
                               "-CantripUITestLane", "home", "-CantripUITestNotifyTab", tab, "-CantripUITestNotifyAfter", "2"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 3) else { break }
            deny.tap()
        }
        func prompt(_ index: Int) -> XCUIElement { app.staticTexts["Prompt \(index): what happened in step \(index)?"] }

        let newest = prompt(count)
        XCTAssertTrue(newest.waitForExistence(timeout: 90), "The tab opens at its newest exchange")
        XCTAssertFalse(prompt(count - 3).exists, "Opening loads only the newest page, not the whole history")
        attach(app, "1-opened-at-newest")

        // The page carries reasoning step titles only; opening Reasoning loads the text from the Mac.
        let reasoning = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reasoning'")).allElementsBoundByIndex.last
        XCTAssertNotNil(reasoning, "The newest reply shows its reasoning")
        reasoning?.tap()
        let detailedStep = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Step 1,'")).firstMatch
        XCTAssertTrue(detailedStep.waitForExistence(timeout: 60), "Opening Reasoning loads each step's text")
        detailedStep.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { detailedStep.label.count > 200 }, "A loaded step shows its text")
        attach(app, "1b-reasoning-loaded")
        reasoning?.tap()

        // The newest reply keeps streaming while older pages load.
        signal("working")
        let transcript = app.scrollViews.containing(NSPredicate(format: "label BEGINSWITH 'Prompt '")).firstMatch
        let status = app.descendants(matching: .any)["cantrip.olderMessagesStatus"]
        let first = prompt(1)
        var sawLoading = false
        var checkedAnchor = false
        var addedTurn = false
        let loadingOlder = { status.exists && status.label == "Loading older messages" }
        for swipe in 0..<160 where !first.exists {
            XCTAssertFalse(app.buttons["cantrip.retryOlderMessages"].exists, "Swipe \(swipe): no page fails")
            transcript.swipeDown(velocity: .fast)
            if swipe == 6, !addedTurn {
                // A new exchange arrives while the reader is paging back.
                signal("newturn")
                addedTurn = true
            }
            if loadingOlder() { sawLoading = true }
            // Older pages are inserted above what's being read: every loaded prompt has to stay put.
            if !checkedAnchor, waitUntil(timeout: 2, loadingOlder), let label = anchorPrompt(in: app) {
                sawLoading = true
                let reading = app.staticTexts[label]
                Thread.sleep(forTimeInterval: 0.3)
                let before = reading.frame.minY
                if loadingOlder() {
                    _ = waitUntil(timeout: 20) { !loadingOlder() }
                    Thread.sleep(forTimeInterval: 0.3)
                    XCTAssertEqual(reading.frame.minY, before, accuracy: 2,
                                   "Swipe \(swipe): inserting older messages keeps \(label) in place")
                    checkedAnchor = true
                }
            }
        }
        XCTAssertTrue(first.exists, "Scrolling up reaches the first message")
        XCTAssertTrue(sawLoading && checkedAnchor, "Older pages loaded while scrolling, with the reading position checked")
        attach(app, "2-first-message")
        for index in 1...count {
            let matches = app.staticTexts.matching(NSPredicate(format: "label == %@",
                                                               "Prompt \(index): what happened in step \(index)?")).count
            XCTAssertEqual(matches, 1, "Prompt \(index) shows exactly once")
        }

        // Back at the newest: the new exchange arrived and the streaming reply kept growing.
        let latestButton = app.buttons["Scroll to latest message"]
        if latestButton.waitForExistence(timeout: 5) { latestButton.tap() }
        XCTAssertTrue(prompt(count + 1).waitForExistence(timeout: 30), "The exchange that arrived mid-paging shows")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@",
                                                            "Prompt \(count + 1): what happened in step \(count + 1)?")).count, 1)
        let streamed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@",
                                                                             "Long tab reply \(count + 1). ")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 30) { streamed.exists && streamed.label.contains("More.") },
                      "The newest reply keeps streaming in")
        attach(app, "3-back-at-newest")
    }

    /// A prompt on screen if there is one, else any loaded prompt (they all move if older messages push them).
    private func anchorPrompt(in app: XCUIApplication) -> String? {
        let screen = app.windows.firstMatch.frame
        let prompts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Prompt '")).allElementsBoundByIndex
        return (prompts.first { $0.frame.minY > screen.minY + 140 && $0.frame.minY < screen.maxY - 200 }
            ?? prompts.last { !$0.frame.isEmpty })?.label
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
