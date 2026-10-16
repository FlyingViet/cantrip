import XCTest

/// Real touch-and-hold drags in Cantrip Home's tab drawer, against the tabs fixture host
/// (TabsQAHost on :58736), checking the order the host saved.
/// Run with `TEST_RUNNER_CANTRIP_UITEST_TABS_URL=http://127.0.0.1:58736`
/// and `TEST_RUNNER_CANTRIP_UITEST_TABS_TOKEN=tabs-qa-token`.
final class CantripTabReorderUITests: XCTestCase {
    private var app: XCUIApplication!
    private var host: URL!
    private var token = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CANTRIP_UITEST_TABS_URL"], let url = URL(string: raw),
              let token = env["CANTRIP_UITEST_TABS_TOKEN"] else {
            throw XCTSkip("Start the tabs fixture host and set CANTRIP_UITEST_TABS_URL and CANTRIP_UITEST_TABS_TOKEN")
        }
        continueAfterFailure = false
        host = url
        self.token = token
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", raw, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let tabs = app.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.tap()
    }

    /// The tab titles in the order the host has saved.
    private func hostOrder() throws -> [String] {
        var request = URLRequest(url: host.appendingPathComponent("api/v1/sessions"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: Result<Data, Error>?
        let done = expectation(description: "host order")
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(result).get()) as? [String: Any]
        return (object?["sessions"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
    }

    private func row(_ title: String) -> XCUIElement {
        // Exactly the tab's title (", Working" while it runs), never the pinned "Cantrip Home" row.
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", title, "\(title), Working")).firstMatch
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForOrder(_ expected: [String]) throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try hostOrder() == expected { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Dragging a tab's ≡ handle moves it; touch and hold on the row still opens its actions.
    func testDraggingTheHandleMovesATabAndHoldingOpensItsActions() throws {
        var order = try hostOrder()
        XCTAssertGreaterThanOrEqual(order.count, 4)
        let moving = order[3], target = order[0]
        let source = row(moving), destination = row(target)
        XCTAssertTrue(source.waitForExistence(timeout: 5) && destination.exists)
        attach("Drawer before")

        // The ≡ handle sits at the trailing edge of the drawer panel (min(380, width - 44) wide),
        // outside the row's button.
        let handleX = min(380, app.frame.width - 44) - 30
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: handleX, dy: source.frame.midY))
            .press(forDuration: 0.5,
                   thenDragTo: origin.withOffset(CGVector(dx: handleX, dy: destination.frame.minY + 4)),
                   withVelocity: 300, thenHoldForDuration: 0.6)
        order.remove(at: 3)
        order.insert(moving, at: 0)
        let moved = try waitForOrder(order)
        attach("Drawer after drag")
        let saved = try hostOrder()
        XCTAssertTrue(moved, "Host order after the drag: \(saved)")
        XCTAssertTrue(app.staticTexts["Cantrip"].exists || app.buttons["New Tab"].exists,
                      "The drawer stays open after reordering")
        let menuItem = app.buttons["Close Tab"].firstMatch
        XCTAssertFalse(menuItem.exists, "Dragging dismisses the tab actions menu")

        // A plain touch and hold still shows the tab's actions.
        row(order[1]).press(forDuration: 1.0)
        XCTAssertTrue(app.collectionViews.buttons.firstMatch.waitForExistence(timeout: 3)
                      || app.buttons["Rename Tab"].waitForExistence(timeout: 1),
                      "Touch and hold without moving opens the tab's actions")
        attach("Actions menu")
    }
}
