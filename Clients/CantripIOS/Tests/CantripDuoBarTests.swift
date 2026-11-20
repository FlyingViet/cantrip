import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// The iPhone Duo's one navigation bar: always open with only actions (Home's sections are in the
/// left menu), and the app-drawn rail (unfolded upright).
@MainActor
final class CantripDuoBarTests: XCTestCase {
    func testEveryDuoPoseHasTheBarAndNoHomeBottomBar() {
        XCTAssertTrue(ChatDisplayTraits(hasVerticalBar: true, isFolded: true).hasDuoBar, "Folded")
        XCTAssertTrue(ChatDisplayTraits(hasVerticalBar: true, isLandscape: true, isFolded: true).hasDuoBar, "Folded on its side")
        XCTAssertTrue(ChatDisplayTraits(hasVerticalBar: true, isHingeOpen: true).hasDuoBar, "Unfolded on its side")
        XCTAssertTrue(ChatDisplayTraits(isHingeOpen: true).hasDuoBar, "Unfolded upright (the app-drawn rail)")
        XCTAssertFalse(ChatDisplayTraits().hasDuoBar, "Other iPhones keep Home's bottom bar and the menu's Settings")
    }

    /// The iPhone Duo open upright (669 x 951 pt, an 81 pt status band): the app-drawn rail, always open
    /// with only its actions, in Home and in a tab (dark, as the app always is), and at a large text size.
    /// Set TEST_RUNNER_HOME_TABS_ARTIFACT_DIR.
    func testUprightRailScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_TABS_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_TABS_ARTIFACT_DIR to render the upright Duo rail.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let band: CGFloat = 81

        func items(home: Bool) -> CantripDuoBarItems {
            CantripDuoBarItems(
                leading: AnyView(CantripDuoSidebarToggle(isOpen: false, workingCount: 2) {}),
                settings: AnyView(ChatSettingsButton {}),
                mac: AnyView(CantripViewMacButton {}),
                menu: AnyView(ChatMenuIcon(systemName: home ? "line.3.horizontal" : "ellipsis"))
            )
        }
        func screen(home: Bool) -> some View {
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 12) {
                    Text("When does the second stage open?")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    Text("Friday at 4 PM, beside the main pier.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Text("Message…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                CantripDuoAppRail(dividerTop: band, items: items(home: home))
            }
        }
        let cases: [(String, Bool, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("home-dark", true, .dark, .large),
            ("tab-dark", false, .dark, .large),
            ("home-dark-ax3", true, .dark, .accessibility3),
        ]
        for (name, home, style, size) in cases {
            let controller = UIHostingController(rootView: screen(home: home).dynamicTypeSize(size))
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 669, height: 951))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let extra = controller.view.safeAreaInsets
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: band - extra.top + controller.additionalSafeAreaInsets.top,
                                                               left: -extra.left, bottom: -extra.bottom, right: -extra.right)
            try await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("duo-bar-upright-\(name).png"))
        }
    }
}
