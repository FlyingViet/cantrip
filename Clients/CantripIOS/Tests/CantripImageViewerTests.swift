import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class CantripImageViewerTests: XCTestCase {
    private func picture(width: CGFloat = 1200, height: CGFloat = 800) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: width * 0.25, y: height * 0.25, width: width * 0.5, height: height * 0.5))
        }
    }

    private func window(size: CGSize = CGSize(width: 393, height: 852)) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        // Something recognizable underneath, so renders show the backdrop fading.
        let title = UILabel(frame: CGRect(x: 20, y: 70, width: 300, height: 44))
        title.text = "Artifacts"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        root.view.addSubview(title)
        for (index, color) in [UIColor.systemTeal, .systemPurple, .systemOrange, .systemGreen].enumerated() {
            let card = UIView(frame: CGRect(x: 20 + CGFloat(index % 2) * 185, y: 140 + CGFloat(index / 2) * 170,
                                            width: 168, height: 150))
            card.backgroundColor = color.withAlphaComponent(0.35)
            card.layer.cornerRadius = 16
            root.view.addSubview(card)
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }

    private func stage(in window: UIWindow, reduceMotion: Bool = false, source: CGRect? = nil)
        -> (CantripImageStageView, () -> [CGFloat], () -> Int) {
        let stage = CantripImageStageView(frame: window.bounds)
        stage.reduceMotion = { reduceMotion }
        stage.sourceFrame = source
        var progress: [CGFloat] = []
        var dismissed = 0
        stage.onProgress = { progress.append($0) }
        stage.onDismiss = { dismissed += 1 }
        stage.setImage(picture())
        window.rootViewController!.view.addSubview(stage)
        stage.layoutIfNeeded()
        return (stage, { progress }, { dismissed })
    }

    private func settle(_ seconds: Double = 0.7) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    func testDismissalRulesMatchPhotos() {
        let vertical = CGPoint(x: 40, y: 600)
        XCTAssertTrue(CantripImageDismissal.canBegin(zoomScale: 0.3, minimumZoomScale: 0.3, velocity: vertical))
        XCTAssertTrue(CantripImageDismissal.canBegin(zoomScale: 0.3, minimumZoomScale: 0.3,
                                                     velocity: CGPoint(x: 10, y: -500)), "Dragging up also dismisses")
        XCTAssertFalse(CantripImageDismissal.canBegin(zoomScale: 0.9, minimumZoomScale: 0.3, velocity: vertical),
                       "A zoomed-in image pans instead of dismissing")
        XCTAssertFalse(CantripImageDismissal.canBegin(zoomScale: 0.3, minimumZoomScale: 0.3,
                                                      velocity: CGPoint(x: 600, y: 100)), "Sideways drags never dismiss")
        XCTAssertEqual(CantripImageDismissal.progress(translationY: 0, height: 800), 0)
        XCTAssertEqual(CantripImageDismissal.progress(translationY: 160, height: 800), 0.5, accuracy: 0.001)
        XCTAssertEqual(CantripImageDismissal.progress(translationY: -160, height: 800), 0.5, accuracy: 0.001)
        XCTAssertEqual(CantripImageDismissal.progress(translationY: 5000, height: 800), 1)
        XCTAssertEqual(CantripImageDismissal.scale(progress: 0), 1)
        XCTAssertEqual(CantripImageDismissal.scale(progress: 1), CantripImageDismissal.minimumScale)
        XCTAssertFalse(CantripImageDismissal.shouldDismiss(translationY: 60, velocityY: 100, height: 800),
                       "A short, slow drag springs back")
        XCTAssertTrue(CantripImageDismissal.shouldDismiss(translationY: 120, velocityY: 0, height: 800))
        XCTAssertTrue(CantripImageDismissal.shouldDismiss(translationY: -120, velocityY: 0, height: 800))
        XCTAssertTrue(CantripImageDismissal.shouldDismiss(translationY: 30, velocityY: 1400, height: 800),
                      "A quick flick dismisses")
        XCTAssertTrue(CantripImageDismissal.shouldDismiss(translationY: -30, velocityY: -1400, height: 800))
        XCTAssertFalse(CantripImageDismissal.shouldDismiss(translationY: 300, velocityY: -1400, height: 800),
                       "Flicking back toward the center cancels")
    }

    func testThumbnailTransformLandsTheImageInsideTheThumbnail() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let fitted = CGRect(x: 0, y: 295, width: 393, height: 262)
        let source = CGRect(x: 30, y: 140, width: 160, height: 120)
        let transform = CantripImageDismissal.transform(from: fitted, to: source, in: bounds)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func mapped(_ point: CGPoint) -> CGPoint {
            let moved = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(transform)
            return CGPoint(x: moved.x + center.x, y: moved.y + center.y)
        }
        let topLeft = mapped(CGPoint(x: fitted.minX, y: fitted.minY))
        let bottomRight = mapped(CGPoint(x: fitted.maxX, y: fitted.maxY))
        let landed = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        XCTAssertEqual(landed.midX, source.midX, accuracy: 0.5)
        XCTAssertEqual(landed.midY, source.midY, accuracy: 0.5)
        XCTAssertEqual(landed.width, source.width, accuracy: 0.5, "Wide images fill the thumbnail's width")
        XCTAssertLessThanOrEqual(landed.height, source.height + 0.5, "and never spill outside it")
    }

    func testDragShrinksAndFadesThenSpringsBackWhenShort() async throws {
        let window = try window()
        let (stage, progress, dismissed) = stage(in: window)
        try await settle(0.5)
        stage.updateDismissal(translation: CGPoint(x: 20, y: 170))
        XCTAssertEqual(stage.progress, 0.5, accuracy: 0.01)
        XCTAssertEqual(stage.backdrop.alpha, 0.5, accuracy: 0.01, "The background fades as the image moves")
        XCTAssertLessThan(stage.scrollView.transform.a, 1, "The image shrinks while dragged")
        XCTAssertEqual(stage.scrollView.transform.ty, 170, accuracy: 0.5)
        XCTAssertEqual(progress().last ?? 0, 0.5, accuracy: 0.01, "Chrome is told to fade too")
        stage.finishDismissal(translation: CGPoint(x: 0, y: 60), velocity: CGPoint(x: 0, y: 50))
        try await settle()
        XCTAssertEqual(stage.scrollView.transform, .identity)
        XCTAssertEqual(stage.backdrop.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(progress().last, 0)
        XCTAssertEqual(dismissed(), 0)
    }

    func testDragDownOrUpPastTheThresholdDismissesOnce() async throws {
        for direction in [CGFloat(1), -1] {
            let window = try window()
            let (stage, _, dismissed) = stage(in: window)
            try await settle(0.5)
            stage.updateDismissal(translation: CGPoint(x: 0, y: 200 * direction))
            stage.finishDismissal(translation: CGPoint(x: 0, y: 200 * direction), velocity: .zero)
            XCTAssertTrue(stage.isDismissing)
            XCTAssertFalse(stage.dismissPan.isEnabled, "No second drag can start while closing")
            XCTAssertFalse(stage.dismiss(), "Closing twice is ignored")
            try await settle()
            XCTAssertEqual(dismissed(), 1)
            XCTAssertEqual(stage.scrollView.transform.ty.sign, direction > 0 ? .plus : .minus,
                           "Without a thumbnail the image leaves in the drag direction")
        }
    }

    func testZoomedInImagesKeepPinchAndPanInsteadOfDismissing() async throws {
        let window = try window()
        let (stage, _, _) = stage(in: window)
        try await settle(0.5)
        let scroll = stage.scrollView
        XCTAssertTrue(CantripImageDismissal.canBegin(zoomScale: scroll.zoomScale, minimumZoomScale: scroll.minimumZoomScale,
                                                     velocity: CGPoint(x: 0, y: 500)))
        scroll.setZoomScale(scroll.maximumZoomScale, animated: false)
        XCTAssertFalse(CantripImageDismissal.canBegin(zoomScale: scroll.zoomScale, minimumZoomScale: scroll.minimumZoomScale,
                                                      velocity: CGPoint(x: 0, y: 500)))
        XCTAssertFalse(stage.canBeginDismissal(movement: CGPoint(x: 0, y: 40)),
                       "The dismissal drag never starts while zoomed in")
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        XCTAssertTrue(stage.canBeginDismissal(movement: CGPoint(x: 2, y: 40)), "At minimum zoom a vertical drag starts it")
        XCTAssertFalse(stage.canBeginDismissal(movement: CGPoint(x: 40, y: 2)), "A sideways drag does not")
        XCTAssertEqual(stage.dismissPan.maximumNumberOfTouches, 1, "Two-finger pinches stay with the scroll view")
        XCTAssertNotNil(scroll.pinchGestureRecognizer)
        XCTAssertTrue(scroll.gestureRecognizers?.contains(stage.dismissPan) == true)
    }

    func testOpensFromAndClosesIntoTheThumbnail() async throws {
        let window = try window()
        let source = CGRect(x: 24, y: 160, width: 170, height: 128)
        let (stage, _, dismissed) = stage(in: window, source: source)
        XCTAssertTrue(stage.scrollView.layer.animationKeys()?.contains("transform") == true,
                      "Opening animates from the thumbnail")
        try await settle(0.6)
        XCTAssertEqual(stage.scrollView.transform, .identity)
        let fitted = stage.fittedImageRect
        XCTAssertTrue(stage.dismiss())
        let expected = CantripImageDismissal.transform(from: fitted, to: source, in: stage.bounds)
        XCTAssertEqual(stage.scrollView.transform.a, expected.a, accuracy: 0.001, "Closing flies back into the thumbnail")
        XCTAssertEqual(stage.scrollView.transform.tx, expected.tx, accuracy: 0.5)
        XCTAssertEqual(stage.scrollView.transform.ty, expected.ty, accuracy: 0.5)
        try await settle()
        XCTAssertEqual(dismissed(), 1)
        XCTAssertEqual(stage.scrollView.alpha, 0, accuracy: 0.01)
    }

    func testReduceMotionFadesWithoutZoomingOrShrinking() async throws {
        let window = try window()
        let (stage, _, dismissed) = stage(in: window, reduceMotion: true, source: CGRect(x: 24, y: 160, width: 170, height: 128))
        XCTAssertEqual(stage.scrollView.transform, .identity, "No zoom from the thumbnail with Reduce Motion")
        XCTAssertTrue(stage.layer.animationKeys()?.contains("opacity") == true, "It fades in instead")
        try await settle(0.4)
        stage.updateDismissal(translation: CGPoint(x: 0, y: 200))
        XCTAssertEqual(stage.scrollView.transform.a, 1, "The image follows the finger without shrinking")
        XCTAssertEqual(stage.scrollView.transform.ty, 200, accuracy: 0.5)
        stage.finishDismissal(translation: CGPoint(x: 0, y: 200), velocity: .zero)
        XCTAssertEqual(stage.scrollView.transform.ty, 200, accuracy: 0.5, "Closing fades in place")
        try await settle(0.5)
        XCTAssertEqual(stage.alpha, 0, accuracy: 0.01)
        XCTAssertEqual(dismissed(), 1)
    }

    func testVoiceOverCanCloseTheViewer() async throws {
        let window = try window()
        let (stage, _, dismissed) = stage(in: window)
        try await settle(0.5)
        XCTAssertEqual(stage.scrollView.accessibilityCustomActions?.map(\.name), ["Close image"])
        XCTAssertTrue(stage.scrollView.accessibilityTraits.contains(.image))
        XCTAssertTrue(stage.scrollView.accessibilityPerformEscape(), "The two-finger scrub closes the image")
        try await settle()
        XCTAssertEqual(dismissed(), 1)
    }

    func testPresenterShowsTheViewerOverTheCurrentScreenAndDoneCloses() async throws {
        let window = try window()
        let image = picture()
        let controller = try XCTUnwrap(CantripImageViewerPresenter.present(
            title: "Flight report", imageLabel: "Flight report", placeholder: image,
            sourceFrame: CGRect(x: 20, y: 200, width: 160, height: 120), loadID: "fixture",
            load: { image }
        ))
        XCTAssertIdentical(window.rootViewController?.presentedViewController, controller)
        XCTAssertEqual(controller.modalPresentationStyle, .overFullScreen, "The screen underneath stays visible")
        XCTAssertFalse(controller.transitionCoordinator?.isAnimated ?? false,
                       "No system slide-up; the viewer animates itself")
        XCTAssertTrue(controller.view.accessibilityViewIsModal)
        try await settle(0.6)
        func find(_ view: UIView) -> CantripImageStageView? {
            if let stage = view as? CantripImageStageView { return stage }
            return view.subviews.lazy.compactMap(find).first
        }
        let stage = try XCTUnwrap(find(controller.view))
        XCTAssertEqual(stage.scrollView.accessibilityLabel, "Flight report")
        stage.updateDismissal(translation: CGPoint(x: 0, y: 220))
        try await Task.sleep(for: .milliseconds(100))
        try render(window, name: "image-viewer-mid-drag")
        stage.finishDismissal(translation: CGPoint(x: 0, y: 220), velocity: CGPoint(x: 0, y: 300))
        try await settle()
        XCTAssertNil(window.rootViewController?.presentedViewController, "A completed drag closes the viewer")
    }

    func testDoneUsesTheSameAnimatedClose() async throws {
        let window = try window()
        let image = picture()
        let controller = try XCTUnwrap(CantripImageViewerPresenter.present(
            title: "Preview", imageLabel: "Preview", placeholder: image, sourceFrame: nil,
            loadID: "done", load: { image }
        ))
        try await settle(0.5)
        try render(window, name: "image-viewer-open")
        func find(_ view: UIView) -> CantripImageStageView? {
            if let stage = view as? CantripImageStageView { return stage }
            return view.subviews.lazy.compactMap(find).first
        }
        let stage = try XCTUnwrap(find(controller.view))
        let control = CantripImageViewerControl()
        control.stage = stage
        XCTAssertTrue(control.dismiss(), "Done runs the stage's dismissal")
        try await settle()
        XCTAssertNil(window.rootViewController?.presentedViewController)
    }

    private func render(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_RENDER_DIR"] else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
