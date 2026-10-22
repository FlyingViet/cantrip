import XCTest

/// A `cantrip pair` link opened through the system (as the Camera does) while Settings is up: the
/// confirmation appears on top, Cancel saves nothing, and Pair saves and selects the host like Add
/// Server. No fixture host needed; the paired `.invalid` URL can't resolve.
final class CantripPairingUITests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"

    func testPairingLinkConfirmsOverSettingsAndSavesOnlyOnPair() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 3) else { break }
            deny.tap()
        }
        let openSettings = app.buttons["Open Settings"].firstMatch
        XCTAssertTrue(openSettings.waitForExistence(timeout: 10))
        openSettings.tap()
        XCTAssertTrue(app.staticTexts["No saved servers"].firstMatch.waitForExistence(timeout: 5))

        let host = "codespaces-pair-ui-\(Int.random(in: 1000...9999))"
        let link = try XCTUnwrap(URL(string: "cantripagent://pair?v=1&name=\(host)&token=\(token)"
            + "&url=https%3A%2F%2F\(host).invalid"))
        open(link, app, springboard)
        let confirmation = app.navigationBars["Pair with Cantrip"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "The confirmation shows over Settings")
        XCTAssertTrue(app.staticTexts[host].exists)
        XCTAssertTrue(app.staticTexts["Ends in bCdE"].exists)
        XCTAssertFalse(app.staticTexts[token].exists, "The token is never shown in full")
        attach(app, "Confirmation over Settings")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        let cantripServers = app.staticTexts["Add Cantrip Remote"].firstMatch
        for _ in 0..<10 where !cantripServers.isHittable { app.swipeUp() }
        let saved = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssertFalse(saved.exists, "Cancel saves nothing")

        open(link, app, springboard)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Pair"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 10), "Pair closes the confirmation")
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The host is saved like Add Server")
        XCTAssertTrue(saved.isSelected || saved.label.contains("Selected"), "and selected")
        attach(app, "Saved and selected")

        open(try XCTUnwrap(URL(string: "cantripagent://pair?v=2&token=\(token)")), app, springboard)
        let update = app.navigationBars["Can't Pair"]
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Update Cantrip Agent to pair with this Mac."].exists)
        update.buttons["OK"].tap()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
    }

    /// `XCUIApplication.open` relaunches the app; the system route keeps Settings open.
    private func open(_ url: URL, _ app: XCUIApplication, _ springboard: XCUIApplication) {
        XCUIDevice.shared.system.open(url)
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
