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

    func testSelectionUsesIDsEvenWithDuplicateNamesAndLockedTabs() {
        let first = session()
        let second = session(id: "second", locked: true, streaming: true)
        var selectedIDs: [String] = []
        let picker = CantripSessionPicker(
            sessions: [first, second], selectedSessionID: second.id,
            onSelect: { selectedIDs.append($0) }
        )
        XCTAssertEqual(picker.selectedSession, second)
        XCTAssertEqual(picker.selection.wrappedValue, second.id)
        picker.selection.wrappedValue = first.id
        picker.selection.wrappedValue = second.id
        XCTAssertEqual(selectedIDs, [first.id, second.id])
    }

    func testEmptyAndRemovedSelectionDoNotSelectAnUnrelatedTab() {
        for sessions in [[], [session()]] {
            let picker = CantripSessionPicker(
                sessions: sessions, selectedSessionID: "removed",
                onSelect: { _ in XCTFail("Rendering must not change the session") }
            )
            XCTAssertNil(picker.selectedSession)
            XCTAssertNil(picker.selection.wrappedValue)
            picker.selection.wrappedValue = nil
        }
    }

    func testMenuPreservesTitlesAndShowsLockWorkAndQueueState() {
        let busy = session(title: "Renamed project", locked: true, streaming: true, queued: 3)
        XCTAssertEqual(CantripSessionPicker.statusSummary(for: busy), "Locked, Working, 3 queued")
        XCTAssertEqual(CantripSessionPicker.menuTitle(for: busy),
                       "Renamed project - Locked, Working, 3 queued")
        let legacy = session(title: "Older host")
        XCTAssertEqual(CantripSessionPicker.statusSummary(for: legacy), "")
        XCTAssertEqual(CantripSessionPicker.menuTitle(for: legacy), "Older host")
    }

    func testUpdatedSnapshotsKeepSelectionAndRefreshNameAndStatus() {
        let renamed = session(title: "New name", locked: true, queued: 2)
        let picker = CantripSessionPicker(
            sessions: [session(id: "other"), renamed], selectedSessionID: renamed.id,
            onSelect: { _ in XCTFail("Snapshot updates must not trigger navigation") }
        )
        XCTAssertEqual(picker.selection.wrappedValue, renamed.id)
        XCTAssertEqual(picker.selectedSession?.title, "New name")
        XCTAssertEqual(picker.selectedSession?.queuedCount, 2)
    }

    func testDropdownFillsAvailableWidthAndHasComfortableTapTarget() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let long = session(
            title: String(repeating: "Project ", count: 10), locked: true, streaming: true, queued: 12
        )
        for width: CGFloat in [288, 720] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let picker = CantripSessionPicker(
                    sessions: [long], selectedSessionID: long.id, onSelect: { _ in }
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
}
