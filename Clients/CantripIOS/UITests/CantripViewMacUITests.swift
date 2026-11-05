import XCTest

/// View Mac from the header: it opens straight into full screen and starts, touch works on the Mac
/// (tap, double-tap, two-finger tap, drag a window, pinch to zoom), its keyboard types on the Mac,
/// and Settings keeps the Mac's permissions. Against a fixture host with a stand-in Mac screen.
/// Run with `TEST_RUNNER_CANTRIP_UITEST_VIEWMAC_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_VIEWMAC_TOKEN=<token>`; `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>`
/// saves screenshots (`TEST_RUNNER_CANTRIP_UITEST_SHOT_REQUESTS=1` asks a watcher on the Mac to take
/// them instead, for the unfolded iPhone Duo's inner screen).
final class CantripViewMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var host = "", token = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_VIEWMAC_URL"], let token = environment["CANTRIP_UITEST_VIEWMAC_TOKEN"] else {
            throw XCTSkip("Start the View Mac fixture host and set CANTRIP_UITEST_VIEWMAC_URL and CANTRIP_UITEST_VIEWMAC_TOKEN")
        }
        self.host = host
        self.token = token
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-CantripUITestRemoteURL", host, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home", "-cantrip.desktop.control", "YES"] + extra
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }
    }

    private var viewMacButton: XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "identifier == 'chat.viewMac' OR label == 'View Mac'"))
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }
    /// The unfolded iPhone Duo's inner screen, where XCUITest can't aim element-centered
    /// multi-finger gestures (it computes them on the outer screen).
    private var innerScreen: Bool { ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOT_REQUESTS"] == "1" }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testHeaderOpensViewMacFullScreenAndTouchWorksOnTheMac() {
        launch()
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 30), "Home's header has View Mac")
        sleep(2)
        save("1 home header")

        // Straight into full screen: no menu or page first.
        viewMacButton.tap()
        let screen = element("desktop.fullScreen.screen")
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "The Mac fills the screen")
        let toolbar = element("desktop.fullScreen.toolbar")
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "The toolbar drops down")
        XCTAssertFalse(app.navigationBars["Mac Permissions"].exists, "No permissions page on the way")
        sleep(2)
        let window = app.windows.firstMatch.frame
        let fitted = screen.frame
        XCTAssertEqual(fitted.width, window.width, accuracy: 2, "Fitted edge to edge")
        save("2 full screen")

        // Tap, double-tap and two-finger tap.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap()
        sleep(2)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).doubleTap()
        sleep(2)
        if !innerScreen {
            screen.twoFingerTap()
            sleep(2)
        }

        // Drag the fake Mac window by its title bar.
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.32))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 300, thenHoldForDuration: 0.2)
        sleep(3)
        save("3 window dragged")

        // Pinch to zoom in, then Fit to Screen. Fingers pinch where the screen shows (zoomed in, its
        // middle can be off the display).
        if !innerScreen {
        let visible = app.windows.firstMatch
        XCTAssertEqual(screen.value as? String, "Zoom 100%")
        visible.pinch(withScale: 3, velocity: 0.8)
        sleep(1)
        XCTAssertGreaterThan(screen.frame.width, fitted.width * 1.1, "Pinching zooms in")
        XCTAssertNotEqual(screen.value as? String, "Zoom 100%")
        save("4 pinched in")
        for _ in 0..<3 where screen.value as? String != "Zoom 100%" {
            visible.pinch(withScale: 0.3, velocity: -2)
            sleep(1)
        }
        XCTAssertEqual(screen.frame.width, fitted.width, accuracy: 3, "Pinching out returns to fit")
        XCTAssertEqual(screen.value as? String, "Zoom 100%")
        visible.pinch(withScale: 3, velocity: 0.8)
        sleep(1)
        element("desktop.fullScreen.view").tap()
        let fit = app.buttons["Fit to Screen"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 3))
        fit.tap()
        sleep(1)
        XCTAssertEqual(screen.frame.width, fitted.width, accuracy: 3, "Fit to Screen")
        XCTAssertEqual(screen.value as? String, "Zoom 100%")
        }

        // Type on the Mac.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        sleep(2)
        let keyboardButton = element("desktop.fullScreen.keyboard")
        keyboardButton.tap()
        XCTAssertTrue(keyboardButton.waitForLabel("Hide Keyboard"), "The keyboard button turns into Hide Keyboard")
        if ProcessInfo.processInfo.environment["CANTRIP_UITEST_SOFT_KEYBOARD"] == "1" {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The on-screen keyboard comes up")
        }
        app.typeText("touch ok")
        sleep(3)
        save("5 typing")
        keyboardButton.tap()
        XCTAssertTrue(keyboardButton.waitForLabel("Show Keyboard"))

        // The toolbar folds into a tab and drops back down.
        element("desktop.fullScreen.collapse").tap()
        let expand = element("desktop.fullScreen.expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        XCTAssertFalse(toolbar.exists)
        sleep(1)
        save("6 toolbar folded")
        expand.tap()
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))

        // Closing ends the session and returns to the chat.
        element("desktop.fullScreen.close").tap()
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 5), "Back in the chat")
        XCTAssertFalse(screen.exists)
    }

    func testTabHeaderOpensViewMacToo() {
        launch()
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 30))
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
        print("VIEWMAC matches", app.buttons.matching(NSPredicate(format: "identifier == 'chat.viewMac' OR label == 'View Mac'")).count,
              "hittable", viewMacButton.isHittable, viewMacButton.frame)
        save("7 tab header")
        viewMacButton.tap()
        XCTAssertTrue(element("desktop.fullScreen.screen").waitForExistence(timeout: 15), "It opens full screen from a tab")
        element("desktop.fullScreen.close").tap()
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 5))
    }

    func testSettingsKeepsTheMacsPermissions() {
        launch(["-CantripUITestSettings", "about"])
        let row = element("settings.macAccess")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "About & Updates lists the Mac's permissions")
        XCTAssertEqual(row.label, "Mac permissions")
        row.tap()
        XCTAssertTrue(element("cantrip.macAccess.viewMac").waitForExistence(timeout: 10), "It says where View Mac is")
        XCTAssertTrue(app.staticTexts["Mac Permissions & Attention"].exists)
        XCTAssertFalse(app.buttons["Authenticate & Control Mac"].exists, "View Mac itself isn't on this page")
        sleep(1)
        save("8 settings permissions")
    }

    /// With View Mac off on the Mac (fixture host started with VIEWMAC_OFF=1 and
    /// `TEST_RUNNER_CANTRIP_UITEST_VIEWMAC_OFF=1`): the start card says so and leads to the permissions.
    func testStartCardWhenViewMacIsOffLeadsToPermissions() throws {
        guard ProcessInfo.processInfo.environment["CANTRIP_UITEST_VIEWMAC_OFF"] == "1" else {
            throw XCTSkip("Needs the fixture host with View Mac off")
        }
        launch()
        XCTAssertTrue(viewMacButton.waitForExistence(timeout: 30))
        sleep(2)
        viewMacButton.tap()
        let error = element("desktop.start.error")
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Starting fails and says why")
        XCTAssertTrue(error.label.contains("Enable View Mac"), error.label)
        XCTAssertTrue(app.switches["cantrip.desktop.control"].exists, "Control can be chosen before trying again")
        XCTAssertTrue(app.buttons["Authenticate & Control Mac"].exists)
        sleep(1)
        save("9 start card off")
        element("desktop.start.permissions").tap()
        let note = element("cantrip.macAccess.viewMac")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "Mac Permissions opens")
        XCTAssertTrue(note.label.contains("View Mac is off"), note.label)
        XCTAssertFalse(element("desktop.start").exists, "Full screen closed on the way")
        sleep(1)
        save("10 permissions from start card")
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
