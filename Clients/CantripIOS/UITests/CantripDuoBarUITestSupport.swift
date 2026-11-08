import XCTest

/// The iPhone Duo's one navigation bar in UI tests: it starts minimized to a pill
/// (`duo.bar.pill`); its items exist only once it's expanded.
extension XCUIApplication {
    var duoBarPill: XCUIElement { buttons["duo.bar.pill"].firstMatch }

    /// Expands the bar when it's minimized; `press` taps (the unfolded inner display needs
    /// window-coordinate taps). False when there is no pill (already expanded, or no Duo bar).
    @discardableResult
    func expandDuoBar(timeout: TimeInterval = 10, press: ((XCUIElement) -> Void)? = nil) -> Bool {
        let pill = duoBarPill
        guard pill.waitForExistence(timeout: timeout) else { return false }
        if let press { press(pill) } else { pill.tap() }
        // The system animates the pill into the bar.
        sleep(1)
        return true
    }

    /// The app runs on the unfolded Duo's inner display: `XCUIScreen.main` is the outer one there,
    /// so its picture and the app's window differ in size.
    var isOnDuoInnerDisplay: Bool {
        let window = windows.firstMatch.frame.size
        let screen = XCUIScreen.main.screenshot().image.size
        return abs(window.width * window.height - screen.width * screen.height) > 1_000
    }
}
