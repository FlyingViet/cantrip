import XCTest

/// Tasks → Views against a Home host that serves views (docs/views.md): the list shows them, a view
/// opens its own screen with its tabs, and a button asks first (Cancel sends nothing; Refresh, once
/// confirmed, comes back refreshed). Run with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// and `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN`, on a host whose views include a "Homelab" view with a
/// Refresh button and a view with tabs. On an unfolded iPhone Duo it opens the sidebar first.
/// `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` asks a watcher for screenshots (it answers
/// `<name>.request` with `<name>.png`, so an unfolded Duo's inner display can be captured).
final class CantripViewsUITests: XCTestCase {
    private var shots: String?
    private var app: XCUIApplication!

    func testViewsOpenFromTasksAndButtonsAskFirst() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a Home host that serves views and set CANTRIP_UITEST_HOME_URL")
        }
        shots = environment["CANTRIP_UITEST_SHOTS"]
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }

        openTasks()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.view.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "Tasks lists the Mac's views")
        sleep(1)
        save("views-list")

        // A view with tabs: its first tab, then each other tab's blocks.
        let tabbed = rows.allElementsBoundByIndex.first { !$0.label.hasPrefix("Homelab") } ?? rows.firstMatch
        press(tabbed)
        let screen = app.descendants(matching: .any)["home.viewScreen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "The view opens on its own screen")
        let tabs = app.segmentedControls["card.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "Its card draws its tabs")
        sleep(1)
        save("view-tabs-0")
        let segments = tabs.buttons.allElementsBoundByIndex
        for (index, segment) in segments.enumerated().dropFirst() {
            press(segment)
            XCTAssertTrue(segment.isSelected, "\(segment.label) shows its blocks")
            sleep(1)
            save("view-tabs-\(index)")
        }
        if let first = segments.first { press(first) }

        // Its buttons ask first; Cancel sends nothing.
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card.action.'")).firstMatch
        for _ in 0..<6 where !(action.exists && action.isHittable) { scrollUp() }
        XCTAssertTrue(action.isHittable, "The view's buttons are on its screen")
        press(action)
        let question = app.alerts.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), "A button asks before it runs")
        XCTAssertTrue(question.buttons[action.label].exists, "The question goes ahead with the button's own label")
        save("view-confirm")
        press(question.buttons["Cancel"])
        XCTAssertFalse(app.descendants(matching: .any)["home.view.status"].waitForExistence(timeout: 2), "Cancel runs nothing")
        // Back to Tasks (on a Duo the back button is in the vertical bar, not a navigation bar).
        let back = app.buttons["BackButton"].firstMatch
        press(back.exists ? back : app.navigationBars.buttons.firstMatch)

        // Homelab: Refresh, once confirmed, refreshes the view on the Mac.
        let homelab = rows.matching(NSPredicate(format: "label BEGINSWITH 'Homelab'")).firstMatch
        XCTAssertTrue(homelab.waitForExistence(timeout: 10))
        press(homelab)
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        let refresh = app.buttons["card.action.a1"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 20), "Homelab's Refresh button")
        sleep(1)
        save("view-homelab")
        press(refresh)
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Refresh asks first")
        press(question.buttons[refresh.label])
        XCTAssertTrue(refresh.waitForExistence(timeout: 30))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: refresh)
        wait(for: [enabled], timeout: 30)
        save("view-homelab-refreshed")
    }

    private var isDuo: Bool {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo")
    }

    /// Home's Tasks section: the bottom bar's on an iPhone, the Duo bar's on a Duo (with the sidebar
    /// open beside it when unfolded).
    private func openTasks() {
        guard isDuo else {
            let tasks = app.buttons.matching(NSPredicate(format: "label == 'Tasks'"))
            XCTAssertTrue(tasks.firstMatch.waitForExistence(timeout: 20), "Home's Tasks section")
            press(tasks.allElementsBoundByIndex.first { $0.isHittable } ?? tasks.firstMatch)
            return
        }
        XCTAssertTrue(app.expandDuoBar(timeout: 20, press: press), "The Duo bar's pill")
        let toggle = app.buttons["duo.rail.sidebar"].firstMatch
        if toggle.waitForExistence(timeout: 3), toggle.label == "Show Sidebar" {
            press(toggle)
            sleep(1)
        }
        if !app.buttons["duo.bar.section.tasks"].firstMatch.exists { app.expandDuoBar(press: press) }
        let section = app.buttons["duo.bar.section.tasks"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        press(section)
    }

    /// A tap at the element's place in the window (taps by element land off on the Duo's inner display).
    private func press(_ element: XCUIElement) {
        let window = app.windows.firstMatch
        let frame = element.frame, origin = window.frame.origin
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y)).tap()
    }

    private func scrollUp() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.3)))
    }

    private func save(_ name: String) {
        guard let shots else { return }
        let folder = URL(fileURLWithPath: shots)
        try? Data().write(to: folder.appendingPathComponent("\(name).request"))
        let picture = folder.appendingPathComponent("\(name).png").path
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: picture) { usleep(250_000) }
    }
}
