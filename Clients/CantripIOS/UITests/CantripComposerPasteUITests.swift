import UIKit
import UniformTypeIdentifiers
import XCTest

/// Real long-press Paste in the message box, with the clipboard filled by this test runner (another
/// app, as when copying from Photos or Files): a photo and a PDF attach, and text still pastes as
/// text. Needs a local host such as the Gateway QA host; run with
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_URL=http://127.0.0.1:<port>` and
/// `TEST_RUNNER_CANTRIP_UITEST_REMOTE_TOKEN=<token>`.
final class CantripComposerPasteUITests: XCTestCase {
    func testPastingPhotosAndFilesAttachesThemAndTextStillPastes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_UITEST_REMOTE_URL"],
              let token = environment["CANTRIP_UITEST_REMOTE_TOKEN"] else {
            throw XCTSkip("Start a local host and set CANTRIP_UITEST_REMOTE_URL and CANTRIP_UITEST_REMOTE_TOKEN")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", url, "-CantripUITestRemoteToken", token,
                               "-CantripUITestLane", "home"]
        app.launch()
        dismissSystemAlerts()
        let message = messageBox(in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30) { message.isEnabled }, "The composer is ready")

        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        UIPasteboard.general.setData(try XCTUnwrap(image.pngData()), forPasteboardType: UTType.png.identifier)
        paste(in: app)
        XCTAssertTrue(app.staticTexts["1/4"].waitForExistence(timeout: 10), "The copied photo attaches")
        attach(app, "1-photo")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("Paste Test.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
        }.write(to: pdf)
        UIPasteboard.general.itemProviders = [try XCTUnwrap(NSItemProvider(contentsOf: pdf))]
        paste(in: app)
        XCTAssertTrue(app.staticTexts["Paste Test.pdf"].waitForExistence(timeout: 10),
                      "A copied file attaches under its own name")
        XCTAssertTrue(app.staticTexts["1/4"].exists, "The photo is still attached")
        attach(app, "2-file")

        UIPasteboard.general.string = "Pasted words"
        paste(in: app)
        XCTAssertTrue(waitUntil(timeout: 5) { (messageBox(in: app).value as? String) == "Pasted words" },
                      "Text pastes into the box: \(String(describing: messageBox(in: app).value))")
        XCTAssertTrue(app.staticTexts["Paste Test.pdf"].exists)
        attach(app, "3-text")
    }

    /// The composer's text field, which takes the composer's identifier.
    private func messageBox(in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["chat.composer"]
        return field.exists ? field : app.textViews["chat.composer"]
    }

    private func paste(in app: XCUIApplication) {
        let message = messageBox(in: app)
        let point = message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.tap()
        Thread.sleep(forTimeInterval: 0.6)
        point.press(forDuration: 1.2)
        let item = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The message box offers Paste")
        item.tap()
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
