import XCTest

/// Real touches on the shared image viewer: swipe up or down to dismiss at minimum zoom,
/// short drags spring back, and a zoomed-in image pans instead of closing.
final class CantripImageViewerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CantripUITestImageViewer"]
        app.launch()
    }

    private func openViewer() -> (done: XCUIElement, image: XCUIElement) {
        let open = app.buttons["fixture.openImage"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let done = app.buttons["imageViewer.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The viewer opens")
        let image = app.descendants(matching: .any)["imageViewer.image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        return (done, image)
    }

    func testSwipeDownAndUpDismissLikePhotos() {
        var viewer = openViewer()
        viewer.image.swipeDown()
        XCTAssertTrue(viewer.done.waitForNonExistence(timeout: 3), "Swiping down closes the image")
        viewer = openViewer()
        viewer.image.swipeUp()
        XCTAssertTrue(viewer.done.waitForNonExistence(timeout: 3), "Swiping up closes it too")
        viewer = openViewer()
        let title = app.staticTexts["Fixture image"].firstMatch
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 320)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(viewer.done.waitForNonExistence(timeout: 3), "A swipe that starts on the title bar closes it as well")
    }

    func testShortDragSpringsBack() {
        let viewer = openViewer()
        let center = viewer.image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 40)),
                     withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(1)
        XCTAssertTrue(viewer.done.exists, "A short, slow drag springs back instead of closing")
        viewer.done.tap()
        XCTAssertTrue(viewer.done.waitForNonExistence(timeout: 3), "Done still closes")
    }

    func testZoomedImagePansInsteadOfDismissing() {
        let viewer = openViewer()
        viewer.image.pinch(withScale: 3, velocity: 2)
        sleep(1)
        viewer.image.swipeDown()
        sleep(1)
        XCTAssertTrue(viewer.done.exists, "While zoomed in, a vertical drag pans the image")
        viewer.image.doubleTap()
        sleep(1)
        viewer.image.swipeDown()
        XCTAssertTrue(viewer.done.waitForNonExistence(timeout: 3), "Back at minimum zoom, swiping dismisses again")
    }
}
