import XCTest

/// iPhone Duo folded (the simulator's default pose): Cantrip Home keeps the iPhone layout while
/// typing, and its actions don't cover the tab bar in the system's vertical bar.
/// Run on an iPhone Duo simulator with `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>`
/// (any fixture host that serves Cantrip Home, e.g. `fake_home_host.py`).
final class CantripDuoFoldedUITests: XCTestCase {
    func testFoldedHomeKeepsThePhoneLayoutAndItsBarButtonsApart() throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo") else {
            throw XCTSkip("Needs an iPhone Duo simulator")
        }
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a fixture Home host and set CANTRIP_UITEST_HOME_URL")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host, "-CantripUITestRemoteToken", "duo-qa-token",
                               "-CantripUITestLane", "home"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        let window = app.windows.firstMatch
        guard window.frame.width < window.frame.height else {
            throw XCTSkip("Fold the Duo and hold it upright (window \(window.frame.size))")
        }

        let tabs = app.buttons["home.tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "The tabs button")
        let sections = ["Chat", "Tasks", "Artifacts", "Builds"].map { app.toolbars.buttons[$0].firstMatch }
        for section in sections {
            XCTAssertTrue(section.waitForExistence(timeout: 5), section.debugDescription)
            XCTAssertFalse(section.frame.intersects(tabs.frame), "The tabs button covers \(section.label)")
        }
        XCTAssertTrue(sections[3].isHittable, "Builds is reachable")
        XCTAssertFalse(app.otherElements["duo.sidebar"].exists)

        let field = app.textFields["chat.composer"].firstMatch
        let message = field.waitForExistence(timeout: 10) ? field : app.textViews["chat.composer"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "The message field")
        message.tap()
        // A simulated hardware keyboard hides the software one; the layout must hold either way.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        XCTAssertFalse(app.otherElements["duo.sidebar"].exists, "Typing on a folded Duo must not show the sidebar")
        XCTAssertTrue(tabs.exists, "The iPhone layout's tabs button stays")
    }
}
