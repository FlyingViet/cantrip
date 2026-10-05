import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// The AppKit stand-ins that let the shared iOS sources run on macOS.
@MainActor
final class PlatformCompatTests: XCTestCase {
    private func solidImage(width: Int, height: Int, color: NSColor = .systemTeal) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    func testImageKeepsPixelSizeAndEncodes() throws {
        let image = try solidImage(width: 40, height: 20)
        XCTAssertEqual(image.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(image.cgImage?.width, 40)
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let png = try XCTUnwrap(image.pngData())
        XCTAssertEqual(NSImage(data: jpeg)?.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(NSImage(data: png)?.size, CGSize(width: 40, height: 20))
    }

    /// The shared decoder (used for every chat image) returns a correctly sized Mac image.
    func testSharedDecoderProducesMacImages() throws {
        let png = try XCTUnwrap(try solidImage(width: 300, height: 150).pngData())
        let decoded = try ChatImageDecoder.decode(png, maximumDimension: 100)
        XCTAssertEqual(decoded.size, CGSize(width: 100, height: 50))
    }

    func testTraitsFollowAppearance() {
        let dark = UITraitCollection(appearance: NSAppearance(named: .darkAqua)!, increaseContrast: false)
        XCTAssertEqual(dark.userInterfaceStyle, .dark)
        XCTAssertEqual(dark.accessibilityContrast, .normal)
        XCTAssertEqual(UITraitCollection(appearance: NSAppearance(named: .aqua)!).userInterfaceStyle, .light)
        // System Settings > Accessibility > Increase contrast maps to UIKit's high contrast.
        let increased = UITraitCollection(appearance: NSAppearance(named: .aqua)!, increaseContrast: true)
        XCTAssertEqual(increased.userInterfaceStyle, .light)
        XCTAssertEqual(increased.accessibilityContrast, .high)
    }

    /// Shared dynamic colors (e.g. Home's AA-safe orange) resolve per appearance.
    func testDynamicColorsResolvePerAppearance() throws {
        let color = NSColor { $0.userInterfaceStyle == .dark ? .white : .black }
        func resolved(_ name: NSAppearance.Name) throws -> CGFloat {
            var white: CGFloat = -1
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                white = color.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
            }
            return white
        }
        XCTAssertEqual(try resolved(.darkAqua), 1, accuracy: 0.01)
        XCTAssertEqual(try resolved(.aqua), 0, accuracy: 0.01)
    }

    func testLiveActivitiesAreInertOnMac() async {
        XCTAssertTrue(Activity<CantripTabsAttributes>.activities.isEmpty)
        XCTAssertFalse(ActivityAuthorizationInfo().areActivitiesEnabled)
        var updates = 0
        for await _ in Activity<CantripTabsAttributes>.activityUpdates { updates += 1 }
        XCTAssertEqual(updates, 0)
    }

    func testDeviceReportsMac() {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .mac)
    }
}

/// The magnifiable image stage and window sizing behind the shared image viewer.
@MainActor
final class MacImageViewerTests: XCTestCase {
    private func image(_ width: CGFloat, _ height: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: width, height: height))
    }

    func testStageFitsLargeImagesAndNeverUpscalesSmallOnes() {
        let stage = CantripImageStage()
        stage.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        stage.setImage(image(1600, 600))
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(stage.magnification, 0.25, accuracy: 0.001)
        XCTAssertEqual(stage.minMagnification, 0.25, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(stage.maxMagnification, 1)

        stage.setImage(image(100, 50))
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(stage.magnification, 1, accuracy: 0.001)
    }

    func testStageRefitsWhenTheWindowResizes() {
        let stage = CantripImageStage()
        stage.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        stage.setImage(image(1600, 1200))
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(stage.magnification, 0.25, accuracy: 0.001)
        stage.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(stage.magnification, 0.5, accuracy: 0.001)
    }

    func testViewerWindowKeepsTheImageAspectWithinTheScreen() {
        let screen = CGSize(width: 1512, height: 945)
        let portrait = CantripImageViewerPresenter.initialFrame(for: image(600, 900), screen: screen)
        XCTAssertEqual(portrait.height, 756)
        XCTAssertEqual(portrait.height / portrait.width, 1.5, accuracy: 0.05)
        // Very tall images fit the height; the window keeps its minimum width.
        let tall = CantripImageViewerPresenter.initialFrame(for: image(200, 600), screen: screen)
        XCTAssertEqual(tall.size, CGSize(width: 480, height: 756))
        let wide = CantripImageViewerPresenter.initialFrame(for: image(1000, 500), screen: screen)
        XCTAssertLessThanOrEqual(wide.width, 1100)
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.05)
        let unknown = CantripImageViewerPresenter.initialFrame(for: nil, screen: screen)
        XCTAssertEqual(unknown.size, CGSize(width: 960, height: 720))
    }
}

@MainActor
final class MacHomeNavigationTests: XCTestCase {
    func testOpenChatSwitchesSectionPrefillsAndFocuses() {
        let navigation = MacHomeNavigation()
        navigation.section = .tasks
        navigation.openChat(prefill: "Create a task to ")
        XCTAssertEqual(navigation.section, .chat)
        XCTAssertEqual(navigation.composerPrefill, "Create a task to ")
        XCTAssertEqual(navigation.composerFocusRequest, 1)
        navigation.openChat()
        XCTAssertEqual(navigation.composerPrefill, "Create a task to ", "No prefill keeps a pending one")
        XCTAssertEqual(navigation.composerFocusRequest, 2)
    }

    /// Like iOS, a waiting background run opens Home's Background list focused on that run.
    func testOpenRunFocusesBackgroundList() {
        let navigation = MacHomeNavigation()
        let memory = ServerCredentialStore(read: { _ in nil }, write: { _, _ in }, remove: { _ in })
        let servers = ServerProfiles(kind: .cantrip, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                     credentials: memory)
        let remote = CantripRemoteModel(servers: servers)
        navigation.openRun("run-1", remote: remote)
        XCTAssertEqual(remote.homeBackgroundFocus, "run-1")
        XCTAssertTrue(navigation.showingBackground)
        navigation.sheet = .memory
        navigation.closeAll()
        XCTAssertNil(navigation.sheet)
        XCTAssertFalse(navigation.showingBackground)
    }
}

@MainActor
final class MacHomeWindowSmokeTests: XCTestCase {
    /// The whole Home window (sidebar, chat, composer, toolbar) lays out for an unpaired Mac.
    func testHomeWindowRendersUnpaired() throws {
        let memory = ServerCredentialStore(read: { _ in nil }, write: { _, _ in }, remove: { _ in })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let remote = CantripRemoteModel(servers: ServerProfiles(kind: .cantrip, defaults: defaults, credentials: memory))
        let env = HermesEnv(servers: ServerProfiles(kind: .hermes, defaults: defaults, credentials: memory),
                            defaults: defaults)
        let navigation = MacHomeNavigation()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MacHomeWindow(
            env: env, remote: remote, voice: VoiceController(), navigation: navigation
        ))
        window.layoutIfNeeded()
        XCTAssertEqual(env.executionLane, .home)
        XCTAssertFalse(remote.isConfigured)
        for section in CantripHomeSection.allCases {
            navigation.section = section
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            window.layoutIfNeeded()
        }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThan(content.fittingSize.width, 0)
        window.close()
    }
}
