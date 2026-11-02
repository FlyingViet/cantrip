import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class SplashRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Task { @MainActor in
            let data = Self.handler?(request) ?? Data("{}".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class CantripLaunchSplashTests: XCTestCase {
    private let windowSize = CGSize(width: 402, height: 874)

    func testTimingStaysShortAndNeverWaitsOnTheNetwork() {
        for reduced in [false, true] {
            let timing = CantripLaunchSplashTiming(reducedMotion: reduced)
            XCTAssertEqual(timing.dismissal(readyAt: 0), timing.minimum, "Ready apps still get the short greeting")
            XCTAssertEqual(timing.dismissal(readyAt: timing.minimum + 0.1), timing.minimum + 0.1, accuracy: 0.0001)
            XCTAssertEqual(timing.dismissal(readyAt: nil), timing.maximum, "A slow reconnect never holds the splash")
            XCTAssertEqual(timing.dismissal(readyAt: 30), timing.maximum)
            XCTAssertLessThanOrEqual(timing.maximum + timing.exit, 1.5)
            XCTAssertLessThanOrEqual(timing.maximum + timing.skipExit, 1.5)
        }
        let full = CantripLaunchSplashTiming(reducedMotion: false)
        XCTAssertGreaterThanOrEqual(full.minimum + full.exit, 1.0)
    }

    func testPipHopsOnlyAfterTheHandoffAndRestsForReduceMotion() {
        let full = CantripLaunchSplashTiming(reducedMotion: false)
        XCTAssertNil(full.celebration(at: 0), "The first frame must match the static launch image")
        XCTAssertNil(full.celebration(at: full.hold))
        XCTAssertNotNil(full.celebration(at: full.hold + full.hop / 2))
        XCTAssertNil(full.celebration(at: full.hold + full.hop + 0.01))
        XCTAssertLessThanOrEqual(full.hold + full.hop, full.minimum, "The hop finishes before the earliest exit")
        XCTAssertEqual(full.greeting(at: 0), 0)
        XCTAssertEqual(full.greeting(at: full.minimum), 1)

        let reduced = CantripLaunchSplashTiming(reducedMotion: true)
        for elapsed in stride(from: 0.0, through: 1.5, by: 0.05) {
            XCTAssertNil(reduced.celebration(at: elapsed))
        }
        XCTAssertEqual(reduced.greeting(at: reduced.minimum), 1, "Reduce Motion still crossfades the wordmark in")
    }

    func testControllerSkipsOnlyWhilePresented() {
        let controller = CantripLaunchSplashController()
        XCTAssertTrue(controller.isPresented)
        controller.skip()
        XCTAssertTrue(controller.skipRequested)
        controller.finish()
        XCTAssertFalse(controller.isPresented)

        let resumed = CantripLaunchSplashController(isPresented: false)
        resumed.skip()
        XCTAssertFalse(resumed.skipRequested)
    }

    func testLaunchScreenUsesTheSplashAssetsInEveryAppearance() throws {
        let launch = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        XCTAssertEqual(launch["UIColorName"] as? String, CantripLaunchSplash.backgroundColorName)
        XCTAssertEqual(launch["UIImageName"] as? String, CantripLaunchSplash.imageName)

        let image = try XCTUnwrap(UIImage(named: CantripLaunchSplash.imageName))
        XCTAssertEqual(image.size, CGSize(width: CantripLaunchSplash.badgeSize, height: CantripLaunchSplash.badgeSize))

        let color = try XCTUnwrap(UIColor(named: CantripLaunchSplash.backgroundColorName))
        let light = rgba(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        let dark = rgba(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertEqual(light, dark, "Light mode must not flash a white launch screen before the dark app")
        XCTAssertEqual(dark, [0, 0, 0, 1])
    }

    func testSplashCoversTheFirstFrameWithTheExactLaunchImage() throws {
        let controller = CantripLaunchSplashController()
        let (window, _) = try host(
            Color.red.ignoresSafeArea().cantripLaunchSplash(controller) { false }
        )
        defer { window.isHidden = true }

        let snapshot = render(window)
        let expected = launchScreen(scale: snapshot.scale)
        let difference = try compare(snapshot, expected)
        XCTAssertLessThan(difference.mean, 1.5, "Launch screen -> splash must not visibly change")
        XCTAssertLessThan(difference.largeFraction, 0.002)
        XCTAssertTrue(controller.isPresented)
    }

    func testSplashDismissesWithoutWaitingForASlowConnection() async throws {
        let controller = CantripLaunchSplashController()
        let (window, _) = try host(Color.red.ignoresSafeArea().cantripLaunchSplash(controller) { false })
        defer { window.isHidden = true }
        let timing = CantripLaunchSplashTiming(reducedMotion: UIAccessibility.isReduceMotionEnabled)
        let started = Date()
        while controller.isPresented, Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(controller.isPresented)
        XCTAssertLessThan(Date().timeIntervalSince(started), timing.maximum + timing.exit + 0.35)
    }

    func testSplashLeavesEarlyWhenReadyAndOnSkip() async throws {
        let ready = CantripLaunchSplashController()
        let (readyWindow, _) = try host(Color.red.ignoresSafeArea().cantripLaunchSplash(ready) { true })
        let timing = CantripLaunchSplashTiming(reducedMotion: UIAccessibility.isReduceMotionEnabled)
        var started = Date()
        while ready.isPresented, Date().timeIntervalSince(started) < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        readyWindow.isHidden = true
        XCTAssertFalse(ready.isPresented)
        XCTAssertLessThan(Date().timeIntervalSince(started), timing.minimum + timing.exit + 0.3)

        let skipped = CantripLaunchSplashController()
        let (skipWindow, _) = try host(Color.red.ignoresSafeArea().cantripLaunchSplash(skipped) { false })
        defer { skipWindow.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        started = Date()
        skipped.skip()
        while skipped.isPresented, Date().timeIntervalSince(started) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(skipped.isPresented)
        XCTAssertLessThan(Date().timeIntervalSince(started), timing.skipExit + 0.3, "Links and pushes skip it")
    }

    func testInactiveSceneStillStartsTheSplash() async throws {
        let controller = CantripLaunchSplashController()
        let (window, _) = try host(
            Color.red.ignoresSafeArea().cantripLaunchSplash(controller) { true }
                .environment(\.scenePhase, .inactive)
        )
        defer { window.isHidden = true }
        let timing = CantripLaunchSplashTiming(reducedMotion: UIAccessibility.isReduceMotionEnabled)
        let started = Date()
        while controller.isPresented, Date().timeIntervalSince(started) < 4 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(controller.isPresented, "An alert holding the scene inactive must not strand the splash")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1 + timing.minimum + timing.exit + 0.4)
    }

    func testReadinessWaitsOnlyForTheVisibleRemoteChat() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SplashRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        SplashRequestProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/api/v1/home":
                return Data("""
                {"session":{"id":"7EAE0CE5-8C8B-4652-9FD0-214867A90E5D","title":"Cantrip Home",
                "workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,
                "queuedCount":0,"status":null,"queued":[],"supportsAutoDelivery":true,
                "isLocked":true,"isCantripHome":true,"supportsModelSettings":true,"messages":[]}}
                """.utf8)
            case "/api/v1/home/tasks": return Data(#"{"tasks":[],"revision":"r"}"#.utf8)
            case "/api/v1/home/artifacts": return Data(#"{"artifacts":[],"revision":"r"}"#.utf8)
            default: return Data(#"{"sessions":[]}"#.utf8)
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            SplashRequestProtocol.handler = nil
        }

        XCTAssertTrue(CantripLaunchSplash.isReady(lane: .home, remote: model), "Unpaired: nothing to wait for")
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "splash-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        XCTAssertFalse(CantripLaunchSplash.isReady(lane: .home, remote: model))
        XCTAssertTrue(CantripLaunchSplash.isReady(lane: .copilot, remote: model), "Local lanes restore instantly")
        await model.selectHome()
        XCTAssertTrue(CantripLaunchSplash.isReady(lane: .home, remote: model))
    }

    func testWordmarkAndPipMeetAAContrast() throws {
        let background = UIColor(named: CantripLaunchSplash.backgroundColorName)!
        let glow = UIColor(CantripLaunchSplash.glowColor)
        let worst = blend(glow, CantripLaunchSplash.glowPeakOpacity, over: background)
        XCTAssertGreaterThanOrEqual(contrast(.white, worst), 7, "Wordmark text beats AA (4.5:1), even on the glow")

        let art = try XCTUnwrap(UIImage(named: CantripLaunchSplash.imageName)?.cgImage)
        let pixels = try rgbaPixels(art)
        let radius = Double(art.width) / 2
        var dimmest = Double.infinity
        for step in 0..<72 {
            let angle = Double(step) * .pi / 36
            let x = Int(radius + cos(angle) * (radius - 6))
            let y = Int(radius + sin(angle) * (radius - 6))
            let index = (y * art.width + x) * 4
            let color = UIColor(red: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255,
                                blue: CGFloat(pixels[index + 2]) / 255, alpha: 1)
            dimmest = min(dimmest, contrast(color, background))
        }
        XCTAssertGreaterThanOrEqual(dimmest, 3, "Pip's badge edge must meet the 3:1 non-text contrast")
    }

    /// Regenerates the launch image: TEST_RUNNER_CANTRIP_LAUNCH_ART_DIR=<dir> xcodebuild test ...
    func testRenderLaunchArt() throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_LAUNCH_ART_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set CANTRIP_LAUNCH_ART_DIR to regenerate LaunchPip.")
        }
        for scale in [2, 3] {
            let renderer = ImageRenderer(content: CantripLaunchPipBadge().environment(\.colorScheme, .dark))
            renderer.scale = CGFloat(scale)
            renderer.isOpaque = false
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("LaunchPip@\(scale)x.png"))
        }
    }

    func testSplashFrameArtifacts() throws {
        guard let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_ARTIFACT_DIR to render splash frames.")
        }
        let controller = CantripLaunchSplashController()
        let frames: [(String, TimeInterval, TimeInterval?, Bool)] = [
            ("launch", 0, nil, false), ("hop", 0.43, nil, false), ("greeting", 0.75, nil, false),
            ("rest", 1.0, nil, false), ("exit", 1.15, 1.0, false),
            ("reduced-start", 0.1, nil, true), ("reduced-rest", 0.6, nil, true),
        ]
        for (name, elapsed, leavingAt, reduced) in frames {
            let (window, _) = try host(ZStack {
                Color(white: 0.12).ignoresSafeArea()
                CantripLaunchSplashView(controller: controller, isReady: { false },
                                        frame: (elapsed, leavingAt), reducedMotionOverride: reduced)
            })
            try XCTUnwrap(render(window).pngData()).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("cantrip-splash-\(name).png")
            )
            window.isHidden = true
        }
        try XCTUnwrap(launchScreen(scale: 3).pngData()).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("cantrip-splash-system-launch.png")
        )
    }

    // MARK: - Helpers

    private func host(_ content: some View) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        // Plain hosting controllers report .background; the app's WindowGroup reports the real phase.
        let controller = UIHostingController(
            rootView: content.preferredColorScheme(.dark).environment(\.scenePhase, .active)
        )
        controller.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func render(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// What `UILaunchScreen` draws: the color asset with the image centered at its point size.
    private func launchScreen(scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: windowSize, format: format).image { context in
            UIColor(named: CantripLaunchSplash.backgroundColorName)!.setFill()
            context.fill(CGRect(origin: .zero, size: windowSize))
            let side = CantripLaunchSplash.badgeSize
            UIImage(named: CantripLaunchSplash.imageName)!.draw(in: CGRect(
                x: (windowSize.width - side) / 2, y: (windowSize.height - side) / 2, width: side, height: side
            ))
        }
    }

    private func compare(_ actual: UIImage, _ expected: UIImage) throws -> (mean: Double, largeFraction: Double) {
        let a = try XCTUnwrap(actual.cgImage)
        let b = try XCTUnwrap(expected.cgImage)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let left = try rgbaPixels(a)
        let right = try rgbaPixels(b)
        var total = 0
        var large = 0
        for index in stride(from: 0, to: min(left.count, right.count), by: 4) {
            var worst = 0
            for channel in 0..<3 {
                let delta = abs(Int(left[index + channel]) - Int(right[index + channel]))
                total += delta
                worst = max(worst, delta)
            }
            if worst > 32 { large += 1 }
        }
        let pixels = Double(min(left.count, right.count) / 4)
        return (Double(total) / (pixels * 3), Double(large) / pixels)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return pixels
    }

    private func rgba(_ color: UIColor) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { (Double($0) * 1000).rounded() / 1000 }
    }

    private func blend(_ top: UIColor, _ opacity: Double, over bottom: UIColor) -> UIColor {
        let t = rgba(top), b = rgba(bottom)
        return UIColor(red: t[0] * opacity + b[0] * (1 - opacity), green: t[1] * opacity + b[1] * (1 - opacity),
                       blue: t[2] * opacity + b[2] * (1 - opacity), alpha: 1)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            let channels = rgba(color).prefix(3).map { value in
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }
}
