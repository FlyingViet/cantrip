import XCTest

/// Opens a heavy tab (hundreds of tool steps in its last turns) through a link shaper and times how long
/// its latest reply takes to show (~/.cache/Cantrip/tab-qa: run-host.sh + shape.py). Run with
/// `TEST_RUNNER_CANTRIP_UITEST_HOME_URL`, `_HOME_TOKEN`, `_TAB_ID` (the tab), `_TAB_TEXT` (text from its
/// latest reply), `_TIMING` (a JSON file the result goes to) and optionally `_TAB_WAIT` (seconds, default 150).
final class CantripTabLoadUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        guard env["CANTRIP_UITEST_HOME_URL"] != nil, env["CANTRIP_UITEST_TAB_ID"] != nil,
              env["CANTRIP_UITEST_TIMING"] != nil else {
            throw XCTSkip("Start the tab-qa host and shaper and set CANTRIP_UITEST_HOME_URL, _TAB_ID and _TIMING")
        }
        continueAfterFailure = false
    }

    func testHeavyTabLoadsOnAWeakLink() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRemoteURL", env["CANTRIP_UITEST_HOME_URL"]!,
                               "-CantripUITestRemoteToken", env["CANTRIP_UITEST_HOME_TOKEN"]!, "-CantripUITestLane", "home",
                               // Opens the tab through a tapped completion push once Home is up.
                               "-CantripUITestNotifyTab", env["CANTRIP_UITEST_TAB_ID"]!, "-CantripUITestNotifyAfter", "2"]
        let launched = Date()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let deny = springboard.buttons["Don’t Allow"]
            guard deny.waitForExistence(timeout: 2) else { break }
            deny.tap()
        }
        let text = env["CANTRIP_UITEST_TAB_TEXT"] ?? "Heavy tab 0 reply 4."
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let header = app.descendants(matching: .any)["tab.header.title"]
        let wait = TimeInterval(env["CANTRIP_UITEST_TAB_WAIT"] ?? "150") ?? 150
        let deadline = launched.addingTimeInterval(wait)
        var opened: Date?
        var shown: Date?
        while Date() < deadline {
            if opened == nil, header.exists { opened = Date() }
            if reply.exists { shown = Date(); break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let headerValue = header.exists ? (header.value as? String ?? "") : "no header"
        var result: [String: Any] = ["launch": launched.timeIntervalSince1970, "header": headerValue]
        result["tabOpened"] = opened?.timeIntervalSince1970
        result["replyShown"] = shown?.timeIntervalSince1970
        if let shot = env["CANTRIP_UITEST_SHOT"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: shot))
        }
        // Stays open a little so the shaper logs the polls that follow.
        Thread.sleep(forTimeInterval: 10)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: env["CANTRIP_UITEST_TIMING"]!))
        XCTAssertNotNil(shown, "the tab's latest reply never showed within \(Int(wait)) s (header: \(headerValue))")
    }
}
