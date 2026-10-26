import XCTest

/// "@" in the message box suggests open tabs: in Cantrip Home and in a tab, filtered as you type,
/// a picked tab shows as "@Label" with a chip, and the sent message shows the mention (the Mac gets
/// the tab's ID). Private tabs are never suggested. Needs a local host with tab mentions, such as
/// the Hermes mentions QA host (tabs Sony TV, TV Remote, Bass Compass, Cantrip + child "Notes file",
/// private "Secret plans"); run with `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>`
/// and `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`; `TEST_RUNNER_CANTRIP_UITEST_SHOTS=<folder>`
/// also saves screenshots there.
final class CantripTabMentionsUITests: XCTestCase {
    func testMentioningATabFromHome() throws {
        let app = try launch(lane: "home")
        let message = messageBox(in: app)
        message.tap()
        message.typeText("@")
        let list = app.descendants(matching: .any)["chat.mentionSuggestions"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "\"@\" opens the tab suggestions")
        XCTAssertTrue(row(app, "Sony TV").exists)
        XCTAssertTrue(row(app, "Notes file").exists, "child tabs are suggested")
        XCTAssertTrue(row(app, "Notes file").label.contains("child of Cantrip"), row(app, "Notes file").label)
        XCTAssertFalse(row(app, "Secret plans").exists, "private tabs are never suggested")
        shot(app, "1-home-at-list")

        message.typeText("ba")
        XCTAssertTrue(waitUntil(timeout: 5) { !self.row(app, "Sony TV").exists }, "the list filters as you type")
        XCTAssertTrue(row(app, "Bass Compass").exists)
        shot(app, "2-home-filtered-ba")

        row(app, "Bass Compass").tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (self.messageBox(in: app).value as? String) == "@Bass Compass " },
                      "picking inserts the mention: \(String(describing: messageBox(in: app).value))")
        XCTAssertTrue(app.buttons["Remove mention Bass Compass"].waitForExistence(timeout: 5), "a chip shows the mention")
        XCTAssertFalse(list.exists, "the list closes after a pick")
        shot(app, "3-home-chip")

        messageBox(in: app).typeText("is the release ready?")
        app.buttons["Send prompt"].tap()
        let sent = app.staticTexts["@Bass Compass is the release ready?"]
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the sent message shows \"@Label\", not the token")
        XCTAssertFalse(app.buttons["Remove mention Bass Compass"].exists, "chips clear after sending")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "I'll read @Bass Compass")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "replies show mentions as \"@Label\" too")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "cantrip-tab:")).firstMatch.exists)
        shot(app, "4-home-sent")
    }

    func testMentioningATabFromATab() throws {
        let app = try launch(lane: "cantrip")
        let message = messageBox(in: app)
        message.tap()
        message.typeText("Ask @")
        XCTAssertTrue(app.descendants(matching: .any)["chat.mentionSuggestions"].waitForExistence(timeout: 10))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.mentionSuggestion.'"))
        // Five tabs can be mentioned (the private one never); the tab you're writing in isn't offered.
        XCTAssertTrue(waitUntil(timeout: 5) { rows.count == 4 }, "\(rows.count) rows")
        XCTAssertFalse(row(app, "Secret plans").exists)

        message.typeText("tv")
        let label = row(app, "TV Remote").exists ? "TV Remote" : "Sony TV"
        XCTAssertTrue(row(app, label).waitForExistence(timeout: 5))
        shot(app, "5-tab-at-list")

        row(app, label).tap()
        XCTAssertTrue(app.buttons["Remove mention \(label)"].waitForExistence(timeout: 5))
        // An email address never opens the list.
        messageBox(in: app).typeText("mail a@b")
        XCTAssertFalse(app.descendants(matching: .any)["chat.mentionSuggestions"].exists)
        shot(app, "6-tab-chip-email")

        // Removing the chip removes its text too.
        app.buttons["Remove mention \(label)"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (self.messageBox(in: app).value as? String) == "Ask mail a@b" },
                      "\(String(describing: messageBox(in: app).value))")

        // The caret the field reports is never pushed back stale: after leaving and coming back,
        // typing continues at the end.
        messageBox(in: app).typeText(" hello")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        Thread.sleep(forTimeInterval: 1.5)
        if app.keyboards.count > 0 {
            messageBox(in: app).typeText("X")
            XCTAssertTrue(waitUntil(timeout: 5) { (self.messageBox(in: app).value as? String) == "Ask mail a@b helloX" },
                          "\(String(describing: messageBox(in: app).value))")
        }
    }

    // MARK: Helpers

    private func launch(lane: String) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", lane]
        app.launch()
        dismissSystemAlerts()
        // iPhone Duo unfolded on its side: the sidebar layout, with the list above the chat's composer.
        if isDuo { XCUIDevice.shared.orientation = .landscapeLeft }
        let message = messageBox(in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30) { message.isEnabled }, "The composer is ready")
        // The tab list arrives with the first poll.
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    private var isDuo: Bool {
        (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name).contains("Duo")
    }

    /// A suggestion row by its tab's title (rows read "title, child of …, project …").
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.mentionSuggestion.' AND (label == %@ OR label BEGINSWITH %@)",
                                         title, title + ",")).firstMatch
    }

    /// The composer's text field, which takes the composer's identifier.
    private func messageBox(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["chat.composer"]
        return field.exists ? field : app.textViews["chat.composer"]
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CANTRIP_UITEST_SHOTS"] {
            let file = "\(isDuo ? "duo" : "ios")-\(name).png"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(file))
        }
    }
}
