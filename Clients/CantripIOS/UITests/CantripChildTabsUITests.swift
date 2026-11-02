import XCTest

/// Child tabs against a local Cantrip host such as the child-tabs QA host (the "Cantrip" tab works
/// with queued messages that carry plans): Run in child tab from the queue, the nested rows, a
/// child's banner, the parent's cards, then the merge question once the parent finishes its turn
/// (the host is told to finish it from outside while this waits). Run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`; `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` also
/// saves the screenshots there.
final class CantripChildTabsUITests: XCTestCase {
    func testRunQueuedMessagesInChildTabsAndAnswerTheMerge() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start the child-tabs QA host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()

        openTab(app, titled: "Cantrip")
        let queue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Queued messages'")).firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 20))
        queue.tap()
        let independent = app.staticTexts["Plan: Independent: can run in a child tab"].firstMatch
        XCTAssertTrue(independent.waitForExistence(timeout: 20), "Queued messages show the Mac's plans")
        attach(app, "ios-1-queue-plans")

        // The two independent messages are 4th and 5th; after the first leaves, the second is 4th.
        for remaining in [4, 3] {
            let fork = app.buttons["cantrip-queue-fork-3"]
            XCTAssertTrue(fork.waitForExistence(timeout: 10))
            fork.tap()
            XCTAssertTrue(waitUntil(timeout: 20) { !app.buttons["cantrip-queue-fork-\(remaining)"].exists },
                          "The message moves into a child tab")
        }
        app.buttons["Done"].firstMatch.tap()

        let card = descendant(app, prefix: "cantrip-child-card-")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The parent shows a card per child")
        Thread.sleep(forTimeInterval: 6)
        attach(app, "ios-2-cards-working")
        let thread = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-child-thread-'")).firstMatch
        thread.tap()
        Thread.sleep(forTimeInterval: 2)
        attach(app, "ios-3-thread-open")
        thread.tap()

        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let tabs = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.tap()
        let child = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label CONTAINS 'child tab of Cantrip'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15), "Child tabs are listed under their parent")
        attach(app, "ios-4-drawer-nested")
        child.tap()
        let banner = descendant(app, prefix: "cantrip-child-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "A child tab says whose child it is")
        Thread.sleep(forTimeInterval: 2)
        // The banner heads the conversation, which opens at its latest message.
        for _ in 0..<8 where !banner.isHittable { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        attach(app, "ios-5-child-banner")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open the parent tab'")).firstMatch.tap()

        // The QA host finishes the parent's turn once both children are done; then they merge.
        let question = descendant(app, prefix: "cantrip-child-question-")
        XCTAssertTrue(question.waitForExistence(timeout: 180), "A conflicting merge asks in the parent")
        let leave = app.buttons["Leave it unmerged; I'll look"].firstMatch
        for _ in 0..<6 where !leave.isHittable { app.swipeDown() }
        Thread.sleep(forTimeInterval: 2)
        attach(app, "ios-6-merge-question")
        leave.tap()
        let retry = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "Left unmerged offers Try Again")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "ios-7-left-unmerged")
    }

    private func openTab(_ app: XCUIApplication, titled title: String) {
        let tabs = app.buttons.matching(NSPredicate(format: "label == 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-tab-' AND label BEGINSWITH %@", title + ",")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
    }

    private func descendant(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
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
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
