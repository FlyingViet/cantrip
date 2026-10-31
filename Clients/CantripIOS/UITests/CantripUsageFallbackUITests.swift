import XCTest

/// Model Settings' usage limit fallbacks against a real Mac host: add backups, move one earlier and
/// remove one, each saving right away. Runs on any iPhone, and on an iPhone Duo folded or unfolded.
/// Set `TEST_RUNNER_CANTRIP_UITEST_HOME_URL=http://127.0.0.1:<port>` (and
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_TOKEN` if the host's token isn't `duo-qa-token`) to a host with
/// the backup chain whose fallback starts off. `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>` saves
/// screenshots (on an unfolded Duo, through a watcher answering `<name>.request`).
final class CantripUsageFallbackUITests: XCTestCase {
    private var shots: String?
    private var unfolded = false

    func testBackupsCanBeAddedReorderedAndRemoved() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CANTRIP_UITEST_HOME_URL"] else {
            throw XCTSkip("Start a Mac host with the backup chain and set CANTRIP_UITEST_HOME_URL")
        }
        shots = environment["CANTRIP_UITEST_SHOTS"]
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", host,
                               "-CantripUITestRemoteToken", environment["CANTRIP_UITEST_HOME_TOKEN"] ?? "duo-qa-token",
                               "-CantripUITestLane", "cantrip"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            guard deny.waitForExistence(timeout: 4) else { break }
            deny.tap()
        }

        // The unfolded Duo's rail has its own Model Settings; elsewhere it's in the chat menu.
        let rail = app.buttons["duo.rail.modelSettings"].firstMatch
        let menu = app.buttons["Tab menu"].firstMatch
        let opened = expectation(for: NSPredicate { _, _ in rail.exists || menu.exists }, evaluatedWith: nil)
        if XCTWaiter.wait(for: [opened], timeout: 30) != .completed { save(app, "no-tab") }
        XCTAssertTrue(rail.exists || menu.exists, "A tab is open")
        unfolded = rail.exists
        if unfolded {
            rail.tap()
        } else {
            menu.tap()
            let item = app.buttons["Model Settings"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "The chat menu has Model Settings")
            item.tap()
        }
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForExistence(timeout: 10))

        let add = app.buttons["usageFallback.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "The fallbacks section offers Add a backup")
        reveal(add, app: app)
        XCTAssertTrue(app.staticTexts["Usage limit fallbacks (all tabs)"].firstMatch.exists)
        save(app, "fallback-off")

        for backend in ["Claude Code", "Codex", "Antigravity"] {
            addBackup(backend, app: app)
        }
        XCTAssertEqual(order(app), ["Claude Code", "Codex", "Antigravity"], "Each backup is added at the end")
        save(app, "fallback-three")

        // A backup's model, from the backend's own list, saves right away.
        let modelPicker = app.buttons["usageFallback.model.Claude Code"].firstMatch
        if modelPicker.waitForExistence(timeout: 5) {
            reveal(modelPicker, app: app)
            tap(modelPicker, app: app)
            let opus = app.buttons["opus"].firstMatch
            XCTAssertTrue(opus.waitForExistence(timeout: 5), "The backend's models are offered")
            tap(opus, app: app)
            // The menu shows the pick as its text (the button exposes no value).
            let shown = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'opus' OR value == 'opus'")).firstMatch
            XCTAssertTrue(shown.waitForExistence(timeout: 10), "The chosen model shows")
            save(app, "fallback-model")
        }

        tap(app.buttons["Try Antigravity earlier"].firstMatch, app: app)
        XCTAssertTrue(waitForOrder(app, ["Claude Code", "Antigravity", "Codex"]), "The arrow moves it up one")
        save(app, "fallback-reordered")

        tap(app.buttons["Remove Claude Code"].firstMatch, app: app)
        XCTAssertTrue(waitForOrder(app, ["Antigravity", "Codex"]), "Remove drops it")
        XCTAssertFalse(app.buttons["Try Antigravity earlier"].firstMatch.isEnabled, "The first backup can't move up")
        XCTAssertFalse(app.buttons["Try Codex later"].firstMatch.isEnabled, "The last backup can't move down")
        save(app, "fallback-removed")
    }

    private func addBackup(_ backend: String, app: XCUIApplication) {
        let count = order(app).count
        let add = app.buttons["usageFallback.add"].firstMatch
        reveal(add, app: app)
        tap(add, app: app)
        let choice = app.buttons[backend].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(backend) is offered")
        tap(choice, app: app)
        let added = expectation(for: NSPredicate { _, _ in self.order(app).count == count + 1 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 10), .completed, "\(backend) is added and saved")
    }

    /// On the unfolded Duo's inner display XCUITest's own taps and hit tests land offset; the
    /// window's coordinate space is accurate.
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        guard unfolded else { return element.tap() }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: element.frame.midX - window.frame.minX, dy: element.frame.midY - window.frame.minY))
            .tap()
    }

    /// Scrolls until the element is on screen.
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        guard unfolded else {
            for _ in 0..<6 where !element.isHittable { app.swipeUp() }
            return
        }
        let window = app.windows.firstMatch
        for _ in 0..<6 where element.frame.maxY > window.frame.maxY - 60 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            sleep(1)
        }
    }

    /// The backups as listed, top to bottom.
    private func order(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'usageFallback.backup.'"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("usageFallback.backup.".count)) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private func waitForOrder(_ app: XCUIApplication, _ expected: [String]) -> Bool {
        let done = expectation(for: NSPredicate { _, _ in self.order(app) == expected }, evaluatedWith: nil)
        return XCTWaiter.wait(for: [done], timeout: 10) == .completed
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let shots else { return }
        let folder = URL(fileURLWithPath: shots)
        sleep(1)
        if unfolded {
            // XCUIScreen.main is the outer display; a watcher captures the inner one.
            try? Data().write(to: folder.appendingPathComponent("\(name).request"))
            let picture = folder.appendingPathComponent("\(name).png").path
            for _ in 0..<40 where !FileManager.default.fileExists(atPath: picture) { usleep(250_000) }
        } else {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
