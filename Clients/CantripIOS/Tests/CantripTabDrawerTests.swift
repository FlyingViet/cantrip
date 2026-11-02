import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class CantripTabDrawerTests: XCTestCase {
    func testASidewaysRightSwipeFromAnywhereOpensTheDrawer() {
        CantripSwipeZones.exemptFrames = []
        for x: CGFloat in [0, 24, 160, 350] {
            XCTAssertTrue(CantripDrawerGesture.shouldOpen(
                start: CGPoint(x: x, y: 300), translation: CGSize(width: 80, height: 10)
            ), "A swipe right opens it wherever it starts (x \(x))")
        }
        for translation in [
            CGSize(width: 20, height: 0),
            CGSize(width: -100, height: 0),
            CGSize(width: 60, height: 120),
            CGSize(width: 60, height: -120),
            CGSize(width: 60, height: 40)
        ] {
            XCTAssertFalse(CantripDrawerGesture.shouldOpen(start: .zero, translation: translation),
                           "Short, leftward or not mostly sideways: \(translation)")
        }
        // A map or sideways scroller keeps swipes that start on it.
        CantripSwipeZones.exemptFrames = [CGRect(x: 0, y: 200, width: 390, height: 180)]
        defer { CantripSwipeZones.exemptFrames = [] }
        XCTAssertFalse(CantripDrawerGesture.shouldOpen(start: CGPoint(x: 120, y: 250), translation: CGSize(width: 120, height: 0)))
        XCTAssertTrue(CantripDrawerGesture.shouldOpen(start: CGPoint(x: 120, y: 500), translation: CGSize(width: 120, height: 0)))
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

    func testHoldToDragDropsUseStableIDsInBothDirectionsWithoutSelecting() {
        let tabs = sessions()
        var moves: [(String, String, Bool)] = []
        let list = CantripTabList(
            sessions: tabs, selectedSessionID: tabs[12].id,
            onSelect: { _ in XCTFail("Reordering must not select or dismiss the drawer") },
            onMove: { moves.append(($0, $1, $2)) }, actions: { _ in EmptyView() }
        )
        func drop(_ id: String, on target: Int) -> Bool {
            list.drop(CantripTabDrag.payload(tab: id), onTab: tabs[target])
        }
        XCTAssertTrue(drop("tab-0", on: 39))
        XCTAssertEqual(moves.last?.0, "tab-0")
        XCTAssertEqual(moves.last?.1, "tab-39")
        XCTAssertEqual(moves.last?.2, true, "Moving down lands after the target")
        XCTAssertTrue(drop("tab-39", on: 0))
        XCTAssertEqual(moves.last?.2, false, "Moving up lands before the target")
        XCTAssertTrue(drop("tab-12", on: 13))
        XCTAssertEqual(moves.last?.0, "tab-12")
        XCTAssertEqual(moves.last?.1, "tab-13")
        XCTAssertEqual(moves.last?.2, true)
        XCTAssertTrue(drop("tab-12", on: 11))
        XCTAssertEqual(moves.last?.1, "tab-11")
        XCTAssertEqual(moves.last?.2, false)
        XCTAssertFalse(drop("tab-0", on: 0), "Dropping a tab on itself does nothing")
        XCTAssertFalse(list.drop("not a tab", onTab: tabs[3]))
        XCTAssertEqual(moves.count, 4)
        XCTAssertEqual(list.selectedSession?.id, tabs[12].id)

        var legacy = tabs
        legacy[0].supportsTabReordering = nil
        let oldHost = CantripTabList(
            sessions: legacy, selectedSessionID: nil, onSelect: { _ in },
            onMove: { _, _, _ in XCTFail("Old hosts must not offer reordering") },
            actions: { _ in EmptyView() }
        )
        XCTAssertFalse(oldHost.drop(CantripTabDrag.payload(tab: "tab-0"), onTab: legacy[2]))
        XCTAssertFalse(oldHost.drop(CantripTabDrag.payload(tab: "tab-1"), onTab: legacy[0]))
        let filtered = CantripTabList(
            sessions: tabs, selectedSessionID: nil, onSelect: { _ in }, actions: { _ in EmptyView() }
        )
        XCTAssertFalse(filtered.drop(CantripTabDrag.payload(tab: "tab-0"), onTab: tabs[3]),
                       "Without onMove (a filtered list) drops do nothing")
    }

    func testRowsHaveNoHandlesAndCanBeDraggedAfterAHold() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let state = ReorderingListState(tabs: Array(sessions().prefix(3)))
        let controller = UIHostingController(rootView: ReorderingListHarness(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 349, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        // A scroll view, not an editable List: no ≡ reorder handles. Touch-and-hold drags and the
        // still-hold menu are covered by CantripTabSectionsUITests.
        XCTAssertNotNil(scrollView(in: controller.view))
        let views = allViews(in: controller.view)
        XCTAssertFalse(views.contains { ($0 as? UICollectionView)?.isEditing == true || ($0 as? UITableView)?.isEditing == true },
                       "No list is in edit mode")
        let reorderViews = views.map { String(describing: type(of: $0)) }.filter { $0.contains("ReorderControl") || $0.contains("ReorderAccessory") }
        XCTAssertTrue(reorderViews.isEmpty, "No reorder control is drawn: \(reorderViews)")
        XCTAssertFalse(views.flatMap(\.interactions).filter { $0 is UIDragInteraction }.isEmpty,
                       "Tabs can be dragged after touch and hold")
    }

    private func allViews(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
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
        let safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertEqual(frame.minX, safeFrame.minX, accuracy: 1)
        XCTAssertEqual(frame.width, CantripDrawerGesture.panelWidth(available: safeFrame.width), accuracy: 1)
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
private final class ReorderingListState: ObservableObject {
    @Published var tabs: [CantripRemoteSession]
    var moves = 0

    init(tabs: [CantripRemoteSession]) { self.tabs = tabs }
}

private struct ReorderingListHarness: View {
    @ObservedObject var state: ReorderingListState

    var body: some View {
        CantripTabList(
            sessions: state.tabs, selectedSessionID: "tab-0",
            onSelect: { _ in XCTFail("Dragging must not select or dismiss") },
            onMove: { id, targetID, after in
                var tabs = state.tabs
                let moved = tabs.remove(at: tabs.firstIndex { $0.id == id }!)
                let target = tabs.firstIndex { $0.id == targetID }!
                tabs.insert(moved, at: target + (after ? 1 : 0))
                state.tabs = tabs
                state.moves += 1
            },
            actions: { _ in EmptyView() }
        )
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
