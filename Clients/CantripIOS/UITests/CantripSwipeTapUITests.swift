import XCTest

/// A swipe that starts on a link or a card opens the menu, never the link or card; a plain tap
/// still opens it. Against a fixture host whose Home and "Cards check" tab carry an inline link,
/// link previews, a map card, a weather card, a flight card, a tool card with a source link and a
/// handoff card. Run with `TEST_RUNNER_CANTRIP_UITEST_SWIPE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_SWIPE_TOKEN=<token>`.
final class CantripSwipeTapUITests: XCTestCase {
    private var app: XCUIApplication!
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    /// In Home, the handoff card opening its tab also counts as opening something.
    private var inHome = true

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_SWIPE_URL"], let token = environment["CANTRIP_UITEST_SWIPE_TOKEN"] else {
            throw XCTSkip("Start the swipe fixture host and set CANTRIP_UITEST_SWIPE_URL and CANTRIP_UITEST_SWIPE_TOKEN")
        }
        continueAfterFailure = true
        safari.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        launch()
    }

    private func launch() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        XCTAssertTrue(handoffButton.waitForExistence(timeout: 30), "Home loads from the fixture host")
        sleep(2)
    }

    private var drawer: XCUIElement { app.descendants(matching: .any)["cantrip-tab-drawer"].firstMatch }
    private var backPill: XCUIElement { app.buttons["Home"].firstMatch }
    private var handoffButton: XCUIElement { app.buttons["Open Cards check tab"].firstMatch }
    private var isDuo: Bool {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo")
    }

    /// Everything that opens something on tap, bottom of the conversation first.
    private func targets(inHome: Bool) -> [(name: String, element: XCUIElement)] {
        var list: [(String, XCUIElement)] = []
        if inHome { list.append(("handoff card", handoffButton)) }
        list += [
            ("tool card source link", app.buttons["Tracking by UPS"].firstMatch),
            ("flight card action", app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Book'")).firstMatch),
            ("weather card attribution", app.buttons["Weather data by Open-Meteo.com"].firstMatch),
            ("link preview", app.descendants(matching: .any)["chat.linkPreview.apple.com"].firstMatch),
            ("inline link", app.links["Apple Mac Studio page"].firstMatch),
        ]
        return list
    }

    func testSwipeFromLinksAndCardsInHomeOpensTheDrawerOnly() {
        for (name, element) in targets(inHome: true) {
            guard reveal(element, name) else { continue }
            swipeRight(from: element)
            XCTAssertFalse(openedSomething(), "Swiping right from the \(name) must not open it")
            attach("home swipe from \(name)")
            if safari.state != .runningForeground {
                XCTAssertTrue(drawer.waitForExistence(timeout: 3), "Swiping right from the \(name) opens the tab drawer")
            }
            returnToHome()
        }
    }

    func testTapOnLinksAndCardsInHomeStillOpensThem() {
        for (name, element) in targets(inHome: true) {
            guard reveal(element, name) else { continue }
            element.tap()
            XCTAssertTrue(openedSomething(timeout: 6), "A tap on the \(name) opens it")
            returnToHome()
        }
    }

    func testSwipeFromLinksAndCardsInATabOpensTheMenuOnly() {
        for (name, element) in targets(inHome: false) {
            openCardsTab()
            inHome = false
            defer { inHome = true }
            guard reveal(element, name) else { continue }
            swipeRight(from: element)
            XCTAssertFalse(safari.wait(for: .runningForeground, timeout: 2), "Swiping right from the \(name) in a tab must not open it")
            if safari.state == .runningForeground {
                attach("tab swipe from \(name)")
            } else if isDuo {
                XCTAssertTrue(drawer.waitForExistence(timeout: 3), "Swiping right from the \(name) opens the tab picker")
                attach("tab swipe from \(name)")
                closeDrawer()
            } else {
                XCTAssertTrue(waitForAbsence(backPill, timeout: 5), "Swiping right from the \(name) goes back to Home")
                attach("tab swipe from \(name)")
            }
            returnToHome()
        }
    }

    // MARK: - Helpers

    private func openCardsTab() {
        guard !backPill.exists || isDuo else { return }
        let handoff = handoffButton
        _ = reveal(handoff, "handoff card")
        handoff.tap()
        XCTAssertTrue(app.buttons["Tracking by UPS"].firstMatch.waitForExistence(timeout: 10), "The Cards check tab opened")
        sleep(1)
    }

    /// Scrolls the conversation until `element` sits well inside the screen, dragging from a strip
    /// of the screen's right edge so the drag itself starts on no card.
    @discardableResult
    private func reveal(_ element: XCUIElement, _ name: String) -> Bool {
        let window = app.windows.firstMatch
        for attempt in 0..<12 {
            if element.exists, element.isHittable {
                let frame = element.frame, screen = window.frame
                // Swipes and taps land on its middle row; tall cards needn't fit whole on the Duo's cover screen.
                if frame.midY > screen.minY + 120, frame.midY < screen.maxY - 140 { return true }
                let up = frame.midY > screen.midY
                drag(window, up: up)
            } else {
                drag(window, up: attempt >= 6)
            }
            XCTAssertFalse(openedSomething(timeout: 0.5), "Scrolling must not open anything (\(name))")
        }
        XCTFail("Couldn't find the \(name) on screen. Links: \(app.links.debugDescription)\n\(app.debugDescription)")
        return false
    }

    private func drag(_ window: XCUIElement, up: Bool) {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.6 : 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.55))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.2)
        sleep(1)
    }

    /// A quick 100 pt swipe right, enough to open the drawer, starting just inside the element.
    private func swipeRight(from element: XCUIElement) {
        let window = app.windows.firstMatch
        let frame = element.frame
        let startX = min(frame.minX + min(16, frame.width / 3), window.frame.width * 0.6)
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startX, dy: frame.midY))
        let end = start.withOffset(CGVector(dx: 100, dy: 3))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 2000, thenHoldForDuration: 0)
    }

    /// Safari came up, or (in Home) the handoff card opened its tab.
    private func openedSomething(timeout: TimeInterval = 2) -> Bool {
        if safari.wait(for: .runningForeground, timeout: timeout) { return true }
        // The Duo has no ‹ Home: there, leaving Home shows as its handoff card going away.
        return inHome && !drawer.exists && (isDuo ? !handoffButton.exists : backPill.exists)
    }

    private func returnToHome() {
        // Something opened in Safari: start over from Home.
        if safari.state == .runningForeground || app.state != .runningForeground {
            safari.terminate()
            launch()
            return
        }
        if drawer.exists { closeDrawer() }
        if isDuo {
            let tabs = app.buttons["Tabs"].firstMatch
            if !handoffButton.exists, tabs.exists {
                tabs.tap()
                let homeRow = app.descendants(matching: .any)["drawer.home"].firstMatch
                if homeRow.waitForExistence(timeout: 3) { homeRow.tap() }
            }
        } else if backPill.exists {
            backPill.tap()
        }
        XCTAssertTrue(app.buttons["Tabs"].firstMatch.waitForExistence(timeout: 8), "Back in Home")
        sleep(1)
    }

    /// Taps the dimmed chat just past the drawer (the folded Duo's right edge is its vertical bar).
    private func closeDrawer() {
        let window = app.windows.firstMatch
        let x = min(drawer.frame.maxX + 20, window.frame.maxX - 8)
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: window.frame.midY)).tap()
        XCTAssertTrue(waitForAbsence(drawer, timeout: 3), "The drawer closes")
        sleep(1)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] {
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
