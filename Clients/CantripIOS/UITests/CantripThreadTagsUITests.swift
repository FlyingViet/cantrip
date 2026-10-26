import XCTest

/// Thread tags against the thread-tags QA host (Cantrip Home seeded with real messages; a handoff
/// card in the latest page and two DDIA replies in older history carry tags, and their prompts say
/// "N Replies"). Drawn like inline replies in Messages: the reply quotes its prompt, and the quote or
/// "N Replies" opens the whole thread over the blurred chat. Also runs on iPhone Duo (its default
/// pose; the unfolded sidebar layout shows the same transcript rows). Run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL`, `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN` and optionally
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS`.
final class CantripThreadTagsUITests: XCTestCase {
    func testThreadTagsOpenTheirThread() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start the thread-tags QA host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") ? "duo" : "ios"

        let card = tag(app, "Reply to: does it make sense")
        let lane = app.staticTexts["Home · Cantrip"].firstMatch
        XCTAssertTrue(lane.waitForExistence(timeout: 30), "Home's chat loads")
        for _ in 0..<20 where !card.exists { app.swipeDown(velocity: .slow) }
        if !card.exists { attach(app, "\(device)-0-missing") }
        XCTAssertTrue(card.exists, "The handoff card from another thread quotes its prompt")
        reveal(card, in: app)
        attach(app, "\(device)-1-card-quote")
        card.tap()
        let view = app.descendants(matching: .any)["cantrip-thread-view"]
        XCTAssertTrue(view.waitForExistence(timeout: 10), "The quote opens the thread")
        let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'does it make sense to be able to tag a tab'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "The thread opens with its prompt, fetched from the Mac")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '7 Replies'")).firstMatch
            .waitForExistence(timeout: 5), "The header counts the thread's replies")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "\(device)-2-card-thread")
        app.buttons["cantrip-thread-close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !view.exists }, "Close returns to the chat")

        // The DDIA replies are in older history; scrolling up loads them and their prompt's count.
        let ddia = tag(app, "Reply to: we have a book called")
        for _ in 0..<40 where !(ddia.exists && ddia.isHittable) { app.swipeDown() }
        XCTAssertTrue(ddia.exists, "Older replies quote their prompts")
        reveal(ddia, in: app)
        attach(app, "\(device)-3-ddia-quote")
        ddia.tap()
        let book = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'we have a book called Designing Data Intensive Applications on our network storage. Can you'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        attach(app, "\(device)-4-ddia-thread")
        app.buttons["cantrip-thread-close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !view.exists })

        let replies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-thread-replies-' AND label == '4 Replies'")).firstMatch
        for _ in 0..<40 where !(replies.exists && replies.isHittable) { app.swipeDown() }
        XCTAssertTrue(replies.exists, "The book prompt counts the replies that other messages split up")
        reveal(replies, in: app)
        attach(app, "\(device)-5-replies")
        replies.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 15), "N Replies opens the same thread")
        app.buttons["cantrip-thread-close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !view.exists })
    }

    private func tag(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-thread-tag-' AND label BEGINSWITH %@", label)).firstMatch
    }

    /// Drags the transcript until the element sits mid-screen, clear of the floating header.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            let frame = element.frame, screen = app.frame
            let offset = frame.midY - screen.height * 0.45
            if element.isHittable, abs(offset) < screen.height * 0.12 { return }
            let step = max(-screen.height * 0.3, min(screen.height * 0.3, offset))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -step)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.6)
        }
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
