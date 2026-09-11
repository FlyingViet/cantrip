import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class ChatAdaptiveLayoutTests: XCTestCase {
    private func host<V: View>(
        _ view: V, size: CGSize, horizontalSizeClass: UIUserInterfaceSizeClass
    ) throws -> (UIWindow, UIHostingController<V>) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let controller = UIHostingController(rootView: view)
        controller.traitOverrides.horizontalSizeClass = horizontalSizeClass
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func settle(_ controller: UIViewController) async throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        controller.view.layoutIfNeeded()
    }

    func testCompactWideCompactResizePreservesDraftAndDetailIdentity() async throws {
        let state = AdaptiveNavigationState()
        let (window, controller) = try host(
            AdaptiveNavigationHarness(state: state),
            size: CGSize(width: 393, height: 852), horizontalSizeClass: .compact
        )
        defer { window.isHidden = true }
        try await settle(controller)
        XCTAssertEqual(state.currentDraft, "Edited draft")
        XCTAssertEqual(state.detailIdentities.count, 1)

        state.presented = true
        try await settle(controller)
        XCTAssertTrue(state.presented)

        window.frame.size = CGSize(width: 1024, height: 768)
        controller.traitOverrides.horizontalSizeClass = .regular
        try await settle(controller)
        XCTAssertFalse(state.presented, "An open drawer must not leave a backdrop over the wide layout")
        XCTAssertGreaterThan(state.sidebarFrame.width, 200)
        XCTAssertGreaterThan(state.detailFrame.width, 400)
        XCTAssertEqual(state.currentDraft, "Edited draft")
        XCTAssertEqual(state.detailIdentities.count, 1)

        state.canSelectTabs = false
        try await settle(controller)
        XCTAssertFalse(state.sidebarEnabled)
        XCTAssertGreaterThan(state.sidebarFrame.width, 200, "Sending must not remove the sidebar")
        state.canSelectTabs = true
        window.frame.size = CGSize(width: 393, height: 852)
        controller.traitOverrides.horizontalSizeClass = .compact
        try await settle(controller)
        XCTAssertFalse(state.presented)
        XCTAssertEqual(state.currentDraft, "Edited draft")
        XCTAssertEqual(state.detailIdentities.count, 1, "Resizing must not recreate the conversation")
        XCTAssertGreaterThan(state.detailFrame.width, 350)
    }

    func testSidebarCanHideAndReopenWithoutChangingTheConversation() async throws {
        let state = AdaptiveNavigationState()
        let (window, controller) = try host(
            AdaptiveNavigationHarness(state: state),
            size: CGSize(width: 1024, height: 768), horizontalSizeClass: .regular
        )
        defer { window.isHidden = true }
        try await settle(controller)
        let splitWidth = state.detailFrame.width
        try XCTUnwrap(state.dismissSidebar)()
        try await settle(controller)
        XCTAssertGreaterThan(state.detailFrame.width, splitWidth)
        state.presented = true
        try await settle(controller)
        XCTAssertFalse(state.presented)
        XCTAssertEqual(state.detailFrame.width, splitWidth, accuracy: 2)
        XCTAssertEqual(state.currentDraft, "Edited draft")
        XCTAssertEqual(state.detailIdentities.count, 1)

        state.hasTabs = false
        try await settle(controller)
        XCTAssertGreaterThan(state.detailFrame.width, splitWidth)
        XCTAssertFalse(state.presented)
        state.hasTabs = true
        try await settle(controller)
        XCTAssertEqual(state.detailFrame.width, splitWidth, accuracy: 2)
        XCTAssertEqual(state.detailIdentities.count, 1, "Changing lanes must not recreate the detail container")
    }

    func testHeaderAndComposerRespectAsymmetricSafeAreasInLandscape() async throws {
        for textSize: DynamicTypeSize in [.large, .accessibility5] {
            let state = AdaptiveNavigationState()
            let (window, controller) = try host(
                AdaptiveNavigationHarness(state: state).environment(\.dynamicTypeSize, textSize),
                size: CGSize(width: 844, height: 393), horizontalSizeClass: .compact
            )
            defer { window.isHidden = true }
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 8, left: 54, bottom: 12, right: 18)
            try await settle(controller)
            let safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame
            for frame in [state.headerFrame, state.composerFrame] {
                XCTAssertGreaterThan(frame.width, 200)
                XCTAssertGreaterThanOrEqual(frame.minX, safeFrame.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, safeFrame.maxX + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, safeFrame.minY - 1)
                XCTAssertLessThanOrEqual(frame.maxY, safeFrame.maxY + 1)
            }
            XCTAssertLessThanOrEqual(state.headerFrame.maxY, state.composerFrame.minY)
        }
    }

    func testVoiceControlsAdaptWithoutRemountingReply() async throws {
        let state = VoiceLayoutState()
        let view = VoiceLayoutHarness(state: state)
        let (window, controller) = try host(
            view, size: CGSize(width: 393, height: 700), horizontalSizeClass: .compact
        )
        defer { window.isHidden = true }
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 28)
        for size in [
            CGSize(width: 393, height: 700),
            CGSize(width: 844, height: 300),
            CGSize(width: 744, height: 500),
            CGSize(width: 320, height: 500)
        ] {
            window.frame.size = size
            try await settle(controller)
            let safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame
            XCTAssertEqual(state.controlsFrame.size, CGSize(width: 76, height: 76))
            XCTAssertGreaterThan(state.replyFrame.height, 100)
            XCTAssertTrue(safeFrame.insetBy(dx: -1, dy: -1).contains(state.controlsFrame))
            XCTAssertFalse(state.replyFrame.intersects(state.controlsFrame))
            if size.width >= 600 {
                XCTAssertLessThan(state.replyFrame.maxX, state.controlsFrame.minX)
            } else {
                XCTAssertLessThan(state.replyFrame.maxY, state.controlsFrame.minY)
            }
            XCTAssertEqual(state.replyAppearances, 1, "Moving voice controls must not restart the reply")
        }
    }

    func testVoiceModeKeepsReplyScrollableAtShortAndWideSizes() async throws {
        let env = HermesEnv()
        let voice = VoiceController()
        let vm = ChatViewModel(env: env, remote: CantripRemoteModel(), voice: voice)
        vm.turns = [
            ChatTurn(role: .user, text: String(repeating: "My question. ", count: 20)),
            ChatTurn(role: .assistant, text: String(repeating: "**A streaming reply.**\n\n", count: 60))
        ]
        vm.sending = true
        defer {
            vm.leaveVoiceMode()
            vm.sending = false
        }
        for textSize: DynamicTypeSize in [.large, .accessibility5] {
            let (window, controller) = try host(
                VoiceModeView(voice: voice, vm: vm, onClose: {})
                    .environment(\.dynamicTypeSize, textSize),
                size: CGSize(width: 393, height: 852), horizontalSizeClass: .compact
            )
            defer { window.isHidden = true }
            for size in [
                CGSize(width: 320, height: 600),
                CGSize(width: 844, height: 393),
                CGSize(width: 1024, height: 768)
            ] {
                window.frame.size = size
                try await settle(controller)
                let scroll = try XCTUnwrap(scrollView(in: controller.view))
                XCTAssertGreaterThan(scroll.bounds.height, 60)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                let frame = scroll.convert(scroll.bounds, to: window)
                XCTAssertLessThan(
                    frame.minY - controller.view.safeAreaInsets.top, size.height / 2,
                    "The voice header must not consume most of a narrow or short window"
                )
                XCTAssertTrue(controller.view.safeAreaLayoutGuide.layoutFrame
                    .insetBy(dx: -1, dy: -1).contains(frame))
                XCTAssertTrue(voice.handsFree)
                XCTAssertTrue(vm.sending)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "adaptive-voice-\(Int(size.width))-\(textSize)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}

@MainActor
private final class AdaptiveNavigationState: ObservableObject {
    @Published var presented = false
    @Published var hasTabs = true
    @Published var canSelectTabs = true
    var sidebarFrame = CGRect.zero
    var detailFrame = CGRect.zero
    var headerFrame = CGRect.zero
    var composerFrame = CGRect.zero
    var sidebarEnabled = true
    var detailIdentities: Set<UUID> = []
    var currentDraft = ""
    var dismissSidebar: (() -> Void)?
}

private struct AdaptiveNavigationHarness: View {
    @ObservedObject var state: AdaptiveNavigationState

    var body: some View {
        ChatNavigationView(
            isTabListPresented: $state.presented,
            hasTabs: state.hasTabs, canSelectTabs: state.canSelectTabs
        ) { isModal, dismiss in
            AdaptiveSidebarProbe(state: state)
                .onAppear { if !isModal { state.dismissSidebar = dismiss } }
        } content: {
            AdaptiveDetailProbe(state: state)
        }
    }
}

private struct AdaptiveSidebarProbe: View {
    @Environment(\.isEnabled) private var isEnabled
    let state: AdaptiveNavigationState

    var body: some View {
        Text("Tabs")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                state.sidebarFrame = $0
            }
            .onChange(of: isEnabled, initial: true) { _, enabled in state.sidebarEnabled = enabled }
    }
}

private struct AdaptiveDetailProbe: View {
    let state: AdaptiveNavigationState
    @State private var identity = UUID()
    @State private var draft = "Unsent draft"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { Text("Existing conversation").frame(maxWidth: .infinity) }
            ChatComposer {
                Image(systemName: "plus.circle").frame(width: 44, height: 44)
            } message: {
                TextField("Message", text: $draft)
            } trailing: {
                Image(systemName: "mic").frame(width: 44, height: 44)
            }
            .padding(8)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                state.composerFrame = $0
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatHeader {
                Text("Current tab").lineLimit(1)
            } connection: {} lane: {
                Image(systemName: "antenna.radiowaves.left.and.right").frame(height: 44)
            } usage: {} delivery: {} refresh: {} leading: {
                Image(systemName: "line.3.horizontal")
            } trailing: {
                Image(systemName: "gearshape")
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                state.headerFrame = $0
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            state.detailFrame = $0
            state.detailIdentities.insert(identity)
        }
        .onAppear { draft = "Edited draft" }
        .onChange(of: draft, initial: true) { _, value in state.currentDraft = value }
    }
}

@MainActor
private final class VoiceLayoutState: ObservableObject {
    var replyFrame = CGRect.zero
    var controlsFrame = CGRect.zero
    var replyAppearances = 0
}

private struct VoiceLayoutHarness: View {
    let state: VoiceLayoutState

    var body: some View {
        VoiceConversationLayout {
            ScrollView {
                Text(String(repeating: "A streaming reply. ", count: 100))
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                state.replyFrame = $0
            }
            .onAppear { state.replyAppearances += 1 }
        } controls: {
            Image(systemName: "mic")
                .frame(width: 76, height: 76)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    state.controlsFrame = $0
                }
        }
    }
}
