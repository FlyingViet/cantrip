import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// The iPhone "/" suggestion list grows with Dynamic Type, never clips rows to a fixed height, and
/// scrolls inside its cap.
@MainActor
final class BackendSlashSuggestionListLayoutTests: XCTestCase {
    private func height(of list: BackendSlashSuggestionList, width: CGFloat, size: DynamicTypeSize) throws -> CGFloat {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var measured: CGFloat = 0
        let content = VStack {
            Spacer(minLength: 0)
            list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
        }
        .padding(.horizontal, 16)
        .environment(\.dynamicTypeSize, size)
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 2400)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<5 {
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return measured
    }

    private func list(maxHeight: CGFloat, style: BackendSlashRowStyle? = nil,
                      maxVisibleRows: Double? = nil) throws -> BackendSlashSuggestionList {
        let response = try BackendSlashCommandsTests.fixture()
        let matches = BackendSlashCommands.matches(token: "", commands: response.commands)
        return BackendSlashSuggestionList(
            presentation: .rows(matches, status: "Claude Code isn't signed in, so its skills can't run until you sign in."),
            maxHeight: maxHeight, style: style, maxVisibleRows: maxVisibleRows, onChoose: { _ in }
        )
    }

    private struct TraitsProbe: View {
        @Environment(\.chatDisplayTraits) private var traits
        let report: (ChatDisplayTraits) -> Void

        var body: some View {
            Color.clear.onChange(of: traits, initial: true) { _, value in report(value) }
        }
    }

    /// The chat's display picks the rows: compact (Gateway Mac style) only beside the system's
    /// vertical bar in a landscape window, as on iPhone Duo unfolded on its side.
    func testDisplayShapeAndVerticalBarPickTheRowStyle() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 900, height: 560), CGSize(width: 560, height: 900)] {
            var observed = ChatDisplayTraits()
            let controller = UIHostingController(rootView: TraitsProbe { observed = $0 }.modifier(ChatDisplayObserver()))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<6 {
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            XCTAssertEqual(observed.isLandscape, size.width > size.height)
            #if AGENTGATEWAY_DUO_SDK
            if #available(iOS 27.1, *) {
                XCTAssertEqual(observed.hasVerticalBar, scene.traitCollection.verticalBarEdge != .unspecified)
            }
            #endif
            let expected: BackendSlashRowStyle = observed.hasVerticalBar && size.width > size.height ? .compact : .touch
            XCTAssertEqual(BackendSlashRowStyle.resolve(observed), expected)
            if !observed.hasVerticalBar {
                XCTAssertEqual(BackendSlashRowStyle.resolve(observed), .touch, "Phones keep the iPhone rows")
            }
        }
    }

    func testPopUpShowsAboutTwoAndAHalfRowsAndScrolls() throws {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            let full = try height(of: list(maxHeight: 5000), width: 393, size: size)
            let capped = try height(of: list(maxHeight: 5000, maxVisibleRows: 2.5), width: 393, size: size)
            XCTAssertLessThan(capped, full * 0.6, "Six rows and a status line are cut to about 2.5 rows")
            XCTAssertGreaterThan(capped, full * 0.25)
            let fortyPercent = try height(of: list(maxHeight: 120, maxVisibleRows: 2.5), width: 393, size: size)
            XCTAssertEqual(fortyPercent, 120, accuracy: 1, "The available-height cap still applies")
        }
        let large = try height(of: list(maxHeight: 5000, maxVisibleRows: 2.5), width: 393, size: .large)
        let huge = try height(of: list(maxHeight: 5000, maxVisibleRows: 2.5), width: 393, size: .accessibility5)
        XCTAssertGreaterThan(huge, large * 1.5, "The cap follows Dynamic Type")
        let two = BackendSlashSuggestionList(
            presentation: .rows(Array(BackendSlashCommands.matches(token: "re", commands: try BackendSlashCommandsTests
                .fixture().commands)), status: nil),
            maxHeight: 5000, maxVisibleRows: 2.5, onChoose: { _ in }
        )
        let twoHeight = try height(of: two, width: 393, size: .large)
        XCTAssertGreaterThan(twoHeight, 60, "Two rows show whole")
    }

    private struct FrameProbe: View {
        let report: (CGRect) -> Void
        var body: some View {
            Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
        }
    }

    /// iPhone Duo unfolded on its side puts the sidebar beside the chat; other layouts don't.
    func testPersistentSidebarSitsBesideTheChat() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for shows in [true, false] {
            var sidebar = CGRect.zero
            var chat = CGRect.zero
            let view = ChatNavigationView(
                isTabListPresented: .constant(false), hasTabs: true, canSelectTabs: true,
                allowsSidebar: false, showsPersistentSidebar: shows
            ) { _, _ in
                Color.red
            } content: {
                FrameProbe { chat = $0 }
            } persistentSidebar: {
                FrameProbe { sidebar = $0 }.frame(width: CantripDuoSidebar.width)
            }
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 950, height: 620)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<6 {
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if shows {
                XCTAssertEqual(sidebar.minX, 0, accuracy: 1, "The sidebar is on the left")
                XCTAssertEqual(sidebar.width, CantripDuoSidebar.width, accuracy: 1)
                XCTAssertGreaterThanOrEqual(chat.minX, sidebar.maxX, "The chat sits beside, not under, the sidebar")
                XCTAssertGreaterThan(chat.width, 500)
            } else {
                XCTAssertEqual(sidebar, .zero)
                XCTAssertEqual(chat.minX, controller.view.safeAreaInsets.left, accuracy: 1)
                XCTAssertEqual(chat.width, 950 - controller.view.safeAreaInsets.left - controller.view.safeAreaInsets.right,
                               accuracy: 1, "Without the sidebar the chat keeps the whole width")
            }
        }
    }

    func testCompactRowsKeepDescriptionsToOneLine() throws {
        let touch = try height(of: list(maxHeight: 5000, style: .touch), width: 360, size: .large)
        let compact = try height(of: list(maxHeight: 5000, style: .compact), width: 360, size: .large)
        XCTAssertLessThan(compact, touch, "Compact rows are shorter")
        let largeCompact = try height(of: list(maxHeight: 5000, style: .compact), width: 360, size: .accessibility5)
        XCTAssertGreaterThan(largeCompact, compact * 1.5, "Compact rows still grow with Dynamic Type")
    }

    func testRowsGrowWithDynamicTypeAndTheListScrollsWithinItsCap() throws {
        for width: CGFloat in [320, 393] {
            let regular = try height(of: list(maxHeight: 5000), width: width, size: .large)
            let large = try height(of: list(maxHeight: 5000), width: width, size: .accessibility5)
            XCTAssertGreaterThan(regular, 6 * 44, "Six rows and a status line at their natural height")
            XCTAssertGreaterThan(large, regular * 1.8, "Accessibility sizes grow the rows instead of clipping them")
            for size: DynamicTypeSize in [.large, .accessibility5] {
                let capped = try height(of: list(maxHeight: 240), width: width, size: size)
                XCTAssertEqual(capped, 240, accuracy: 1, "The list scrolls within its cap")
            }
        }
        let loading = BackendSlashSuggestionList(presentation: .loading, maxHeight: 240, onChoose: { _ in })
        let loadingHeight = try height(of: loading, width: 393, size: .large)
        XCTAssertGreaterThan(loadingHeight, 20)
        XCTAssertLessThan(loadingHeight, 80)
    }
}
