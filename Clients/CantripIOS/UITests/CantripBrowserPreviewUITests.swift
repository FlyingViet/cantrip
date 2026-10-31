import XCTest

/// The live agent browser card: it shows under a reply that used the Mac's browser tools, and a
/// tap opens the larger live view (Done closes it). Needs a local host with a browser activity in
/// its selected tab and the agent Chrome running, such as the browser preview QA host; run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`.
final class CantripBrowserPreviewUITests: XCTestCase {
    func testBrowserCardOpensTheLiveViewer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agent browser'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "A browser card shows under the reply")
        attach(app, "1-card")
        card.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The live viewer opens")
        XCTAssertTrue(app.images["Live view of the agent browser"].waitForExistence(timeout: 15), "A frame loads")
        sleep(2)
        attach(app, "2-viewer")
        done.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Done returns to the chat")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
