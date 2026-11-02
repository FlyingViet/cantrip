import XCTest

/// Opening the app clears its icon badge, whichever tab has the alerts. A watcher on the Mac sends
/// the pushes: the test writes `<name>.request` into `TEST_RUNNER_CANTRIP_UITEST_PUSH_DIR` and the
/// watcher runs `simctl push` with `<name>.apns` there, then writes `<name>.done`.
final class CantripBadgeResetUITests: XCTestCase {
    func testOpeningTheAppClearsTheBadge() throws {
        guard let pushes = ProcessInfo.processInfo.environment["CANTRIP_UITEST_PUSH_DIR"] else {
            throw XCTSkip("Run with a push watcher and TEST_RUNNER_CANTRIP_UITEST_PUSH_DIR")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-CantripUITestRequestBadges"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(2)
        save("after-home", folder: pushes)

        let icon = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cantrip Agent")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        push("three", folder: pushes)
        XCTAssertTrue(waitForBadge(icon) { $0.contains("3") }, "The alert's badge shows: \(icon.value ?? "")")
        save("badge-three", folder: pushes)

        app.activate()
        sleep(2)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBadge(icon) { !$0.contains("3") && !$0.contains("1") }, "Opening the app clears it: \(icon.value ?? "")")
        save("badge-cleared", folder: pushes)

        push("one", folder: pushes)
        XCTAssertTrue(waitForBadge(icon) { $0.contains("1") }, "The next alert shows its own count: \(icon.value ?? "")")
        save("badge-one", folder: pushes)
    }

    private func push(_ name: String, folder: String) {
        let base = URL(fileURLWithPath: folder)
        try? Data().write(to: base.appendingPathComponent("\(name).request"))
        let done = base.appendingPathComponent("\(name).done").path
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: done) { usleep(250_000) }
    }

    private func waitForBadge(_ icon: XCUIElement, _ matches: @escaping (String) -> Bool) -> Bool {
        let check = expectation(for: NSPredicate { _, _ in matches("\(icon.value ?? "")") }, evaluatedWith: nil)
        return XCTWaiter.wait(for: [check], timeout: 10) == .completed
    }

    private func save(_ name: String, folder: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
