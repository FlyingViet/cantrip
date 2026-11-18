import XCTest

/// The iPhone Duo's one navigation bar in UI tests: always open, so its items are there from launch.
extension XCUIApplication {
    /// The app runs on the unfolded Duo's inner display: `XCUIScreen.main` is the outer one there,
    /// so its picture and the app's window differ in size.
    var isOnDuoInnerDisplay: Bool {
        let window = windows.firstMatch.frame.size
        let screen = XCUIScreen.main.screenshot().image.size
        return abs(window.width * window.height - screen.width * screen.height) > 1_000
    }
}

extension XCUIElement {
    /// Waits for a bar or sidebar item to report itself selected.
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isSelected { return true }
            usleep(200_000)
        } while Date() < deadline
        return isSelected
    }
}
