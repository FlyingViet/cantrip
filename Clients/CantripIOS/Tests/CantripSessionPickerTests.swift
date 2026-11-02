import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class CantripSessionPickerTests: XCTestCase {
    private func session(
        id: String = "first",
        title: String = "Project",
        locked: Bool? = nil,
        streaming: Bool = false,
        queued: Int = 0
    ) -> CantripRemoteSession {
        CantripRemoteSession(
            id: id, title: title, workdir: "/tmp", isStreaming: streaming,
            canResume: false, councilMode: false, queuedCount: queued,
            status: nil, messages: nil, supportsImageAttachments: nil, queued: nil,
            isLocked: locked
        )
    }

    func testOpeningDrawerPreservesSelectionWithDuplicateNamesAndLockedTabs() {
        let first = session()
        let second = session(id: "second", locked: true, streaming: true)
        var opened = false
        let picker = CantripSessionPicker(
            sessions: [first, second], selectedSessionID: second.id,
            onOpenTabs: { opened = true }
        )
        XCTAssertEqual(picker.selectedSession, second)
        picker.onOpenTabs()
        XCTAssertTrue(opened)
        XCTAssertEqual(picker.selectedSession?.id, second.id)
    }

    func testEmptyAndRemovedSelectionDoNotSelectAnUnrelatedTab() {
        for sessions in [[], [session()]] {
            let picker = CantripSessionPicker(
                sessions: sessions, selectedSessionID: "removed",
                onOpenTabs: { XCTFail("Rendering must not open the drawer") }
            )
            XCTAssertNil(picker.selectedSession)
        }
    }

    func testMenuPreservesTitlesLocksAndQueuesWithoutWorkingSuffix() {
        let busy = session(title: "Renamed project", locked: true, streaming: true, queued: 3)
        XCTAssertEqual(CantripSessionPicker.statusSummary(for: busy), "Locked, 3 queued")
        XCTAssertEqual(CantripSessionPicker.menuTitle(for: busy),
                       "Renamed project - Locked, 3 queued")
        let legacy = session(title: "Older host")
        XCTAssertEqual(CantripSessionPicker.statusSummary(for: legacy), "")
        XCTAssertEqual(CantripSessionPicker.menuTitle(for: legacy), "Older host")
    }

    func testActivityIsAnnouncedWithoutChangingVisibleTabText() {
        for locked in [false, true] {
            for queued in [0, 3] {
                let idle = session(title: "My tab", locked: locked, queued: queued)
                let busy = session(title: "My tab", locked: locked, streaming: true, queued: queued)
                XCTAssertEqual(CantripSessionPicker.menuTitle(for: busy),
                               CantripSessionPicker.menuTitle(for: idle))
                XCTAssertEqual(CantripSessionPicker.statusSummary(for: busy),
                               CantripSessionPicker.statusSummary(for: idle))
                XCTAssertEqual(CantripSessionPicker.accessibilityTitle(for: busy), "My tab, Working")
                XCTAssertEqual(CantripSessionPicker.accessibilityTitle(for: idle), "My tab")
            }
        }
    }

    func testBusyTabHasAVisibleIndicator() throws {
        func render(streaming: Bool) throws -> Data {
            let tab = session(streaming: streaming)
            let picker = CantripSessionPicker(
                sessions: [tab], selectedSessionID: tab.id, onOpenTabs: {}
            )
            .frame(width: 288)
            return try XCTUnwrap(ImageRenderer(content: picker).uiImage?.pngData())
        }

        let idle = try render(streaming: false)
        let busy = try render(streaming: true)
        XCTAssertNotEqual(idle, busy, "Busy tabs must show an icon, not just an accessibility announcement")
        XCTAssertEqual(idle, try render(streaming: false), "Idle tabs must not retain the activity icon")
    }

    func testUpdatedSnapshotsKeepSelectionAndRefreshNameAndStatus() {
        let renamed = session(title: "New name", locked: true, queued: 2)
        let picker = CantripSessionPicker(
            sessions: [session(id: "other"), renamed], selectedSessionID: renamed.id,
            onOpenTabs: { XCTFail("Snapshot updates must not trigger navigation") }
        )
        XCTAssertEqual(picker.selectedSession?.id, renamed.id)
        XCTAssertEqual(picker.selectedSession?.title, "New name")
        XCTAssertEqual(picker.selectedSession?.queuedCount, 2)
    }

    func testDrawerButtonFillsAvailableWidthAndHasComfortableTapTarget() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let long = session(
            title: String(repeating: "Project ", count: 10), locked: true, streaming: true, queued: 12
        )
        for width: CGFloat in [288, 720] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                let picker = CantripSessionPicker(
                    sessions: [long], selectedSessionID: long.id, onOpenTabs: {}
                )
                .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: picker)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let measured = controller.sizeThatFits(in: CGSize(width: width, height: 2_000))
                XCTAssertEqual(measured.width, width, accuracy: 1)
                XCTAssertGreaterThanOrEqual(measured.height, 52)
                XCTAssertLessThan(measured.height, 400, "Long titles should wrap within bounded space")
            }
        }
    }

    func testDrawerButtonAndDeliveryMenuFitTogetherForEveryMode() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let busy = session(
            title: String(repeating: "Project ", count: 10), locked: true, streaming: true, queued: 12
        )
        for width: CGFloat in [288, 361, 720] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                for mode in CantripDeliveryMode.allCases {
                    let bar = CantripSessionBar(
                        sessions: [busy], selectedSessionID: busy.id,
                        deliveryMode: .constant(mode), isMutating: false, onOpenTabs: {}
                    ) {
                        Button("Rename Tab") {}
                        Button("Unlock Tab") {}
                        Button("Close Session", role: .destructive) {}
                    }
                    .environment(\.dynamicTypeSize, size)
                    let controller = UIHostingController(rootView: bar)
                    let window = UIWindow(windowScene: scene)
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    defer { window.isHidden = true }
                    controller.view.layoutIfNeeded()
                    let measured = controller.sizeThatFits(in: CGSize(width: width, height: 2_000))
                    XCTAssertEqual(measured.width, width, accuracy: 1, "\(mode) at \(size)")
                    XCTAssertGreaterThanOrEqual(measured.height, 52)
                    XCTAssertLessThan(measured.height, 400)
                }
            }
        }
    }

    func testLongPressContextMenuUsesTheFullTabControl() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let tab = session()
        let picker = CantripSessionPicker(
            sessions: [tab], selectedSessionID: tab.id,
            onOpenTabs: { XCTFail("Opening tab actions must not open the drawer") }
        )
        .contextMenu {
            Button("Rename Tab") {}
            Button("Lock Tab") {}
            Button("Close Session", role: .destructive) {}
        }
        let controller = UIHostingController(rootView: picker)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 288, height: 200)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        func contextMenus(in view: UIView) -> [UIContextMenuInteraction] {
            view.interactions.compactMap { $0 as? UIContextMenuInteraction }
                + view.subviews.flatMap { contextMenus(in: $0) }
        }
        let interaction = try XCTUnwrap(contextMenus(in: controller.view).first)
        let target = try XCTUnwrap(interaction.view)
        XCTAssertEqual(target.bounds.width, 288, accuracy: 1)
        XCTAssertGreaterThanOrEqual(target.bounds.height, 52)
        let contentFrame = target.safeAreaLayoutGuide.layoutFrame
        for x in [contentFrame.minX + 8, contentFrame.midX, contentFrame.maxX - 8] {
            let configuration = interaction.delegate?.contextMenuInteraction(
                interaction, configurationForMenuAtLocation: CGPoint(x: x, y: contentFrame.midY)
            )
            XCTAssertNotNil(configuration, "Long press should work across the whole tab, including x=\(x)")
        }
    }
}
