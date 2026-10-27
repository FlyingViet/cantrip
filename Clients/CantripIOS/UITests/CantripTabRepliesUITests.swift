import XCTest

/// What a tab sends back is a reply to the message that asked for it, even when it lands right under
/// that message. Against the tab-replies QA host: Home's chat has two requests that @mention the Home
/// Network tab; Home hands the first off and answers the second with `tab ask`. Each tab card quotes
/// its request, the request says "2 Replies", and the thread shows the request, Home's handoff, the
/// tab's turns and the result, in order. Also runs on iPhone Duo (its default pose; the unfolded
/// sidebar layout shows the same transcript rows). Run with `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL`,
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN` and optionally `TEST_RUNNER_CANTRIP_UITEST_SHOTS`.
final class CantripTabRepliesUITests: XCTestCase {
    func testTabRepliesQuoteTheirRequest() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start the tab-replies QA host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") ? "duo" : "ios"
        XCTAssertTrue(app.staticTexts["Home · Cantrip"].firstMatch.waitForExistence(timeout: 30), "Home's chat loads")

        // Answered with `tab ask`: the tab's answer sits right under the request and quotes it.
        let asked = tag(app, "Reply to: @Home Network which version of jellyfin")
        XCTAssertTrue(asked.waitForExistence(timeout: 30), "The ask's card quotes the request it answers")
        reveal(asked, in: app)
        XCTAssertEqual(repliesButton(above: asked, in: app)?.label, "2 Replies", "The request counts the card and Home's answer")
        attach(app, "\(device)-tab-replies-1-ask")

        // Handed off: the tab's result quotes the request, which says "2 Replies" (Home's handoff and the result).
        let handed = tag(app, "Reply to: @Home Network looks like jellyfin failed")
        for _ in 0..<20 where !(handed.exists && handed.isHittable) { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(handed.exists, "The handoff's result quotes the request")
        reveal(handed, in: app)
        attach(app, "\(device)-tab-replies-2-handoff")
        let replies = try XCTUnwrap(repliesButton(above: handed, in: app), "The request shows its replies")
        XCTAssertEqual(replies.label, "2 Replies")

        // The thread: the request, Home's handoff, the tab's turns (named after the tab), then the result.
        replies.tap()
        let view = app.descendants(matching: .any)["cantrip-thread-view"]
        XCTAssertTrue(view.waitForExistence(timeout: 10), "N Replies opens the thread")
        let request = text(app, "looks like jellyfin failed to update")
        let handoff = text(app, "The Home Network tab is taking the Jellyfin update failure")
        let work = text(app, "Outcome: Jellyfin is healthy on 10.11.2")
        let result = text(app, "Done in Home Network")
        XCTAssertTrue(work.waitForExistence(timeout: 15), "The tab's turns are in the thread")
        XCTAssertTrue(app.staticTexts["Home Network"].firstMatch.exists, "The tab's turns are named after the tab")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "\(device)-tab-replies-3-thread")
        let order = [request, handoff, work, result].map { $0.frame.minY }
        XCTAssertEqual(order, order.sorted(), "In order: request, handoff, the tab's turns, result")
        app.buttons["cantrip-thread-close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !view.exists }, "Close returns to the chat")
    }

    private func tag(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-thread-tag-' AND label BEGINSWITH %@", label)).firstMatch
    }

    private func text(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// The "N Replies" button closest above `element`: its request's.
    private func repliesButton(above element: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        let top = element.frame.minY
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cantrip-thread-replies-'"))
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.maxY <= top }
            .max { $0.frame.maxY < $1.frame.maxY }
    }

    /// Drags the transcript until the element sits mid-screen, clear of the floating header.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            let frame = element.frame, screen = app.frame
            let offset = frame.midY - screen.height * 0.55
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
