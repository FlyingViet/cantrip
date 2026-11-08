import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// The iPhone Duo's one navigation bar: what its minimized pill shows and says, and the app-drawn
/// rail (unfolded upright) minimized and expanded.
@MainActor
final class CantripDuoBarTests: XCTestCase {
    func testThePillShowsWhereYouAreAndWhatTheBarHides() {
        let chat = CantripDuoBarSummary(section: .chat, runningTasks: 2, workingTabs: 3, tabsNeedingInput: 0)
        XCTAssertEqual(chat.systemImage, CantripHomeSection.chat.systemImage, "Home: the current section")
        XCTAssertEqual(chat.badgeCount, 2, "Home: its running tasks")
        XCTAssertEqual(chat.accessibilityValue, "Chat, 2 tasks running")

        let tasks = CantripDuoBarSummary(section: .tasks, runningTasks: 1, workingTabs: 0, tabsNeedingInput: 1)
        XCTAssertEqual(tasks.accessibilityValue, "Tasks, 1 task running, 1 tab needs your input")

        let tab = CantripDuoBarSummary(section: nil, runningTasks: 0, workingTabs: 3, tabsNeedingInput: 2)
        XCTAssertEqual(tab.systemImage, "chevron.up", "In a tab: not the menu's ellipsis")
        XCTAssertEqual(tab.badgeCount, 3, "In a tab: the working tabs")
        XCTAssertEqual(tab.accessibilityValue, "2 tabs need your input, 3 tabs working")

        let idle = CantripDuoBarSummary(section: nil, runningTasks: 0, workingTabs: 0, tabsNeedingInput: 0)
        XCTAssertEqual(idle.badgeCount, 0)
        XCTAssertEqual(idle.accessibilityValue, "")
        XCTAssertEqual(CantripDuoBarSummary.accessibilityLabel, "Navigation")
    }

    func testTheSummaryFollowsTheChosenSection() {
        var section = CantripHomeSection.chat
        let items = CantripDuoBarItems(
            settings: AnyView(EmptyView()), menu: AnyView(EmptyView()),
            sections: CantripDuoBarSections(selection: Binding(get: { section }, set: { section = $0 }), runningTasks: 2),
            workingTabs: 4, tabsNeedingInput: 0
        )
        XCTAssertEqual(items.summary.section, .chat)
        section = .artifacts
        XCTAssertEqual(items.summary.section, .artifacts)
        XCTAssertEqual(items.summary.badgeCount, 2, "Home's badge is its running tasks, not the working tabs")
        let tab = CantripDuoBarItems(settings: AnyView(EmptyView()), menu: AnyView(EmptyView()), workingTabs: 4)
        XCTAssertNil(tab.summary.section)
        XCTAssertEqual(tab.summary.badgeCount, 4)
    }

    /// The iPhone Duo open upright (669 x 951 pt, an 81 pt status band): the app-drawn rail minimized to
    /// its pill and expanded, in Home and in a tab (dark, as the app always is), and at a large text size.
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
                menu: AnyView(ChatMenuIcon(systemName: home ? "line.3.horizontal" : "ellipsis")),
                sections: home ? CantripDuoBarSections(selection: .constant(.chat), runningTasks: 2) : nil,
                workingTabs: 2
            )
        }
        func screen(home: Bool, expanded: Bool) -> some View {
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
                CantripDuoAppRail(dividerTop: band, items: items(home: home), isExpanded: .constant(expanded))
            }
        }
        let cases: [(String, Bool, Bool, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("home-minimized-dark", true, false, .dark, .large),
            ("home-expanded-dark", true, true, .dark, .large),
            ("tab-minimized-dark", false, false, .dark, .large),
            ("tab-expanded-dark", false, true, .dark, .large),
            ("home-expanded-dark-ax3", true, true, .dark, .accessibility3),
        ]
        for (name, home, expanded, style, size) in cases {
            let controller = UIHostingController(rootView: screen(home: home, expanded: expanded).dynamicTypeSize(size))
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
