import XCTest

/// View Mac from the header: the header button opens it, Full Screen fills the screen with a toolbar
/// that drops down from the top, and its keyboard types straight onto the Mac. Against a fixture host
/// with a stand-in Mac screen. Run with `TEST_RUNNER_CANTRIP_UITEST_VIEWMAC_URL=http://127.0.0.1:<port>`
/// and `TEST_RUNNER_CANTRIP_UITEST_VIEWMAC_TOKEN=<token>`; `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>`
/// saves screenshots (`TEST_RUNNER_CANTRIP_UITEST_SHOT_REQUESTS=1` asks a watcher on the Mac to take
/// them instead, for the unfolded iPhone Duo's inner screen).
final class CantripViewMacUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_VIEWMAC_URL"], let token = environment["CANTRIP_UITEST_VIEWMAC_TOKEN"] else {
            throw XCTSkip("Start the View Mac fixture host and set CANTRIP_UITEST_VIEWMAC_URL and CANTRIP_UITEST_VIEWMAC_TOKEN")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home", "-cantrip.desktop.control", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 30), "Home's header has View Mac")
        sleep(2)
    }

    private var viewMacButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'chat.viewMac' OR label == 'View Mac'")).firstMatch
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testHeaderOpensViewMacAndFullScreenTypesOnTheMac() {
        save("1 home header")
        viewMacButton.tap()
        let start = app.buttons["Authenticate & Control Mac"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "View Mac opens, set to control")
        start.tap()
        let open = element("desktop.fullScreen.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15), "The session starts")
        XCTAssertTrue(app.images["Live Mac screen. Use zoom and tap to control when enabled."].waitForExistence(timeout: 10)
                      || app.otherElements["Live Mac screen. Use zoom and tap to control when enabled."].exists,
                      "The Mac's screen shows on the page")
        save("2 view mac page")

        open.tap()
        let toolbar = element("desktop.fullScreen.toolbar")
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "Full screen drops its toolbar down")
        let screen = element("desktop.fullScreen.screen")
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "The Mac fills the screen")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(screen.frame.width, window.width - 2, "Edge to edge, or as wide as fits")
        save("3 full screen")

        // Click into the fake Mac's window, then type with the keyboard.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap()
        sleep(2)
        let keyboardButton = element("desktop.fullScreen.keyboard")
        XCTAssertEqual(keyboardButton.label, "Show Keyboard")
        keyboardButton.tap()
        XCTAssertTrue(keyboardButton.waitForLabel("Hide Keyboard"), "The keyboard button turns into Hide Keyboard")
        if ProcessInfo.processInfo.environment["CANTRIP_UITEST_SOFT_KEYBOARD"] == "1" {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The on-screen keyboard comes up")
        }
        app.typeText("hello mac")
        app.typeText("\n")
        app.typeText("Cantrip")
        sleep(4)
        save("4 typing")
        keyboardButton.tap()
        XCTAssertTrue(keyboardButton.waitForLabel("Show Keyboard"), "Hide Keyboard puts it away")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "No keyboard once hidden")
        sleep(1)
        save("5 keyboard hidden")

        // The toolbar folds up into a small tab and drops back down.
        element("desktop.fullScreen.collapse").tap()
        let expand = element("desktop.fullScreen.expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Folded into a tab at the top")
        XCTAssertFalse(toolbar.exists)
        sleep(1)
        save("6 toolbar folded")
        expand.tap()
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3), "The toolbar drops back down")

        element("desktop.fullScreen.exit").tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Exit returns to View Mac with the session still on")
        XCTAssertTrue(app.buttons["End View Mac"].exists)
        app.buttons["End View Mac"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Ended")
        save("7 ended")
    }

    func testTabHeaderHasViewMac() {
        // The unfolded iPhone Duo lists tabs in its sidebar; elsewhere they're in the Tabs drawer.
        let row = app.staticTexts["Remote desk"].firstMatch
        if !row.exists {
            let tabs = app.buttons.matching(NSPredicate(format: "identifier == 'home.tabs' OR label == 'Tabs'")).firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 10))
            tabs.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        sleep(2)
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 5), "A tab's header has View Mac too")
        XCTAssertTrue(viewMacButton.isHittable)
        save("8 tab header")
        viewMacButton.tap()
        XCTAssertTrue(app.buttons["Authenticate & Control Mac"].firstMatch.waitForExistence(timeout: 10))
    }

    private func save(_ name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["CANTRIP_UITEST_SHOTS"] else { return }
        let url = URL(fileURLWithPath: folder)
        if environment["CANTRIP_UITEST_SHOT_REQUESTS"] == "1" {
            // A watcher on the Mac takes the inner screen's picture and removes the request.
            let request = url.appendingPathComponent("\(name).request")
            try? Data().write(to: request)
            for _ in 0..<40 where FileManager.default.fileExists(atPath: request.path) { usleep(100_000) }
        } else {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}

private extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
