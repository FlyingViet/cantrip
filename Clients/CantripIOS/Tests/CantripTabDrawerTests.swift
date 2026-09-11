import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class CantripTabDrawerTests: XCTestCase {
    func testOpeningRequiresDeliberateRightSwipeFromLeftEdge() {
        for x: CGFloat in [0, 12, 24] {
            XCTAssertTrue(CantripDrawerGesture.shouldOpen(
                start: CGPoint(x: x, y: 300), translation: CGSize(width: 80, height: 10)
            ))
        }
        for x: CGFloat in [-1, 25, 160, 350] {
            XCTAssertFalse(CantripDrawerGesture.shouldOpen(
                start: CGPoint(x: x, y: 300), translation: CGSize(width: 150, height: 0)
            ))
        }
        for translation in [
            CGSize(width: 20, height: 0),
            CGSize(width: -100, height: 0),
            CGSize(width: 60, height: 120),
            CGSize(width: 60, height: -120),
            CGSize(width: 60, height: 60)
        ] {
            XCTAssertFalse(CantripDrawerGesture.shouldOpen(start: .zero, translation: translation))
        }
    }

    func testClosingRequiresLeftSwipeNotVerticalTabScrolling() {
        XCTAssertTrue(CantripDrawerGesture.shouldClose(translation: CGSize(width: -80, height: 10)))
        for translation in [
            CGSize(width: 80, height: 0),
            CGSize(width: -20, height: 0),
            CGSize(width: -60, height: 120),
            CGSize(width: -60, height: -120)
        ] {
            XCTAssertFalse(CantripDrawerGesture.shouldClose(translation: translation))
        }
    }

    func testDrawerAlwaysLeavesATappableDismissAreaAndCapsTabletWidth() {
        for width: CGFloat in [288, 320, 393, 720, 1024] {
            let panelWidth = CantripDrawerGesture.panelWidth(available: width)
            XCTAssertLessThanOrEqual(panelWidth, 380)
            XCTAssertGreaterThanOrEqual(width - panelWidth, 44)
            XCTAssertGreaterThan(panelWidth, 200)
        }
    }

    private func sessions() -> [CantripRemoteSession] {
        (0..<40).map { index in
            CantripRemoteSession(
                id: "tab-\(index)", title: String(repeating: "Project ", count: 6),
                workdir: "/tmp", isStreaming: index.isMultiple(of: 2),
                canResume: false, councilMode: false, queuedCount: index,
                status: nil, messages: nil, supportsImageAttachments: nil, queued: nil,
                isLocked: index.isMultiple(of: 3), supportsTabReordering: true
            )
        }
    }

    func testListTracksIDsAcrossDuplicateTitlesReorderingAndRemoval() {
        let tabs = sessions()
        var selectedIDs: [String] = []
        let list = CantripTabList(
            sessions: Array(tabs.reversed()), selectedSessionID: tabs[12].id,
            onSelect: { selectedIDs.append($0) }, actions: { _ in EmptyView() }
        )
        XCTAssertEqual(list.selectedSession, tabs[12])
        list.onSelect(tabs[0].id)
        list.onSelect(tabs[12].id)
        XCTAssertEqual(selectedIDs, [tabs[0].id, tabs[12].id])
        let removed = CantripTabList(
            sessions: Array(tabs.dropFirst()), selectedSessionID: tabs[0].id,
            onSelect: { _ in XCTFail("Removal must not switch tabs") }, actions: { _ in EmptyView() }
        )
        XCTAssertNil(removed.selectedSession)
    }

    func testManyTabsScrollAtNarrowAndTabletWidthsWithLargeText() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for width: CGFloat in [244, 349, 380] {
            for size: DynamicTypeSize in [.large, .accessibility5] {
                let list = CantripTabList(
                    sessions: sessions(), selectedSessionID: "tab-0",
                    onSelect: { _ in }, onMove: { _, _, _ in },
                    actions: { _ in Button("Rename Tab") {} }
                )
                .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: list)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let scroll = try XCTUnwrap(scrollView(in: controller.view))
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, width + 1)
            }
        }
    }

    func testReorderDropUsesStableIDsInBothDirectionsWithoutSelecting() {
        let tabs = sessions()
        var moves: [(String, String, Bool)] = []
        let list = CantripTabList(
            sessions: tabs, selectedSessionID: tabs[12].id,
            onSelect: { _ in XCTFail("Reordering must not select or dismiss the drawer") },
            onMove: { moves.append(($0, $1, $2)) }, actions: { _ in EmptyView() }
        )
        XCTAssertTrue(list.acceptDrop(["cantrip-tab:tab-0"], onto: "tab-39"))
        XCTAssertEqual(moves.last?.0, "tab-0")
        XCTAssertEqual(moves.last?.1, "tab-39")
        XCTAssertEqual(moves.last?.2, true)
        XCTAssertTrue(list.acceptDrop(["cantrip-tab:tab-39"], onto: "tab-0"))
        XCTAssertEqual(moves.last?.2, false)
        for items in [[], ["unrelated"], ["cantrip-tab:closed"], ["cantrip-tab:tab-0"],
                      ["cantrip-tab:tab-1", "cantrip-tab:tab-2"]] {
            XCTAssertFalse(list.acceptDrop(items, onto: "tab-0"))
        }
        XCTAssertFalse(list.acceptDrop(["cantrip-tab:tab-0"], onto: "closed"))
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(list.selectedSession?.id, tabs[12].id)

        var legacy = tabs
        legacy[0].supportsTabReordering = nil
        let oldHost = CantripTabList(
            sessions: legacy, selectedSessionID: nil, onSelect: { _ in },
            onMove: { _, _, _ in XCTFail("Old hosts must not offer reordering") },
            actions: { _ in EmptyView() }
        )
        XCTAssertFalse(oldHost.acceptDrop(["cantrip-tab:tab-0"], onto: "tab-1"))
        XCTAssertFalse(oldHost.acceptDrop(["cantrip-tab:tab-1"], onto: "tab-0"))
    }

    func testOverlayKeepsChatMountedAndClosesWhenSwitchingIsDisabled() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let state = DrawerState()
        let controller = UIHostingController(rootView: DrawerHarness(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(state.contentAppearances, 1)

        state.isPresented = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let frame = try XCTUnwrap(state.panelFrame)
        XCTAssertEqual(frame.minX, 0, accuracy: 1)
        XCTAssertEqual(frame.width, CantripDrawerGesture.panelWidth(available: window.bounds.width), accuracy: 1)
        XCTAssertEqual(state.contentAppearances, 1, "Opening tabs must not rebuild the chat or composer")

        state.isEnabled = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.contentAppearances, 1)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}

@MainActor
private final class DrawerState: ObservableObject {
    @Published var isPresented = false
    @Published var isEnabled = true
    var panelFrame: CGRect?
    var contentAppearances = 0
}

private struct DrawerHarness: View {
    @ObservedObject var state: DrawerState

    var body: some View {
        NavigationStack {
            ScrollView { Text("Existing conversation") }
                .navigationTitle("Chat")
                .onAppear { state.contentAppearances += 1 }
        }
        .cantripTabDrawer(isPresented: $state.isPresented, isEnabled: state.isEnabled) {
            Text("Tabs")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    state.panelFrame = $0
                }
        }
    }
}
