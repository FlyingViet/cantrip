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
        XCTAssertEqual(state.detailFrame.width, controller.view.safeAreaLayoutGuide.layoutFrame.width, accuracy: 1)
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

    func testDuoKeepsDrawerAndConversationThroughDisplayTransitions() async throws {
        let state = AdaptiveNavigationState()
        state.displayTraits = ChatDisplayTraits(hasVerticalBar: true)
        let (window, controller) = try host(
            AdaptiveTraitsHarness(state: state),
            size: CGSize(width: 393, height: 852), horizontalSizeClass: .compact
        )
        defer { window.isHidden = true }
        try await settle(controller)

        for (size, traits) in [
            (CGSize(width: 951, height: 710), ChatDisplayTraits(hasVerticalBar: true)),
            (CGSize(width: 710, height: 951), ChatDisplayTraits()),
            (CGSize(width: 393, height: 852), ChatDisplayTraits(hasVerticalBar: true))
        ] {
            state.presented = true
            try await settle(controller)
            window.frame.size = size
            controller.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
            state.displayTraits = traits
            try await settle(controller)
            XCTAssertTrue(state.presented, "An open Duo drawer should stay a drawer after folding")
            state.presented = false
            try await settle(controller)
            XCTAssertEqual(state.currentDraft, "Edited draft")
            XCTAssertEqual(state.detailIdentities.count, 1)
            XCTAssertGreaterThan(state.detailFrame.width, size.width - 180,
                                 "The session list must not become a persistent Duo column")
        }
    }

    func testSystemDuoTraitsDriveNativeToolbarAndDrawer() async throws {
        #if AGENTGATEWAY_DUO_SDK
        guard #available(iOS 27.1, *) else { throw XCTSkip("Requires the Duo runtime") }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let state = AdaptiveNavigationState()
        let (window, controller) = try host(
            AdaptiveNavigationHarness(state: state, allowsSidebar: false).modifier(ChatDisplayObserver()),
            size: scene.effectiveGeometry.coordinateSpace.bounds.size,
            horizontalSizeClass: scene.traitCollection.horizontalSizeClass
        )
        defer { window.isHidden = true }
        try await settle(controller)
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .phone)
        XCTAssertEqual(state.observedTraits.hasVerticalBar,
                       scene.traitCollection.verticalBarEdge != .unspecified)
        XCTAssertGreaterThan(state.detailFrame.width, window.bounds.width - 180)
        XCTAssertEqual(state.detailIdentities.count, 1)
        if state.observedTraits.hasVerticalBar {
            for frame in [state.tabsFrame, state.refreshFrame, state.settingsFrame, state.menuFrame] {
                if scene.traitCollection.verticalBarEdge == .leading {
                    XCTAssertLessThanOrEqual(frame.maxX, state.detailFrame.minX + 1)
                } else {
                    XCTAssertGreaterThanOrEqual(frame.minX, state.detailFrame.maxX - 1,
                                                "Native actions belong beside chat, not above it")
                }
                let target = try XCTUnwrap(nativeActionTarget(around: frame, in: window))
                XCTAssertGreaterThanOrEqual(target.width, 44)
                XCTAssertGreaterThanOrEqual(target.height, 44)
                XCTAssertLessThanOrEqual(target.maxX, window.bounds.maxX)
            }
            XCTAssertGreaterThan(state.tabsFrame.minY, window.bounds.height * 0.7,
                                 "Tabs belongs near the bottom of the native side toolbar")
            for frame in [state.settingsFrame, state.refreshFrame, state.menuFrame] {
                XCTAssertLessThan(frame.maxY, window.bounds.midY,
                                  "Settings, Refresh and the menu stay in the upper toolbar")
                XCTAssertLessThan(frame.maxY, state.tabsFrame.minY)
            }
        } else {
            XCTAssertEqual(state.settingsFrame, .zero,
                           "The standalone Settings button is only shown in the vertical toolbar")
        }
        state.presented = true
        try await settle(controller)
        XCTAssertTrue(state.presented)
        state.presented = false
        try await settle(controller)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "duo-native-chat-navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
        #else
        throw XCTSkip("Requires the Duo SDK")
        #endif
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

    func testPhoneHeaderPlacesTabsLeftAndMenuRight() async throws {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            let state = AdaptiveNavigationState()
            let (window, controller) = try host(
                AdaptiveNavigationHarness(state: state, allowsSidebar: false)
                    .environment(\.dynamicTypeSize, size),
                size: CGSize(width: 393, height: 852), horizontalSizeClass: .compact
            )
            defer { window.isHidden = true }
            try await settle(controller)
            XCTAssertEqual(state.tabsFrame.size, CGSize(width: 44, height: 44))
            XCTAssertEqual(state.menuFrame.size, CGSize(width: 44, height: 44))
            XCTAssertLessThan(state.tabsFrame.maxX, state.menuFrame.minX)
            XCTAssertEqual(state.tabsFrame.minY, state.menuFrame.minY, accuracy: 1)
            XCTAssertTrue(state.headerFrame.contains(state.tabsFrame))
            XCTAssertTrue(state.headerFrame.contains(state.menuFrame))
            state.presented = true
            try await settle(controller)
            XCTAssertTrue(state.presented)
            state.presented = false
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

    private func nativeActionTarget(around label: CGRect, in window: UIWindow) -> CGRect? {
        // Native bars wrap the smaller icon host in a 48pt glass interaction target.
        var target = window.hitTest(CGPoint(x: label.midX, y: label.midY), with: nil)
        while let view = target {
            let frame = view.convert(view.bounds, to: window)
            if (44...64).contains(frame.width), (44...64).contains(frame.height) { return frame }
            target = view.superview
        }
        return nil
    }
}

@MainActor
private final class AdaptiveNavigationState: ObservableObject {
    @Published var presented = false
    @Published var hasTabs = true
    @Published var canSelectTabs = true
    @Published var displayTraits = ChatDisplayTraits()
    var observedTraits = ChatDisplayTraits()
    var sidebarFrame = CGRect.zero
    var detailFrame = CGRect.zero
    var headerFrame = CGRect.zero
    var composerFrame = CGRect.zero
    var menuFrame = CGRect.zero
    var refreshFrame = CGRect.zero
    var settingsFrame = CGRect.zero
    var tabsFrame = CGRect.zero
    var sidebarEnabled = true
    var detailIdentities: Set<UUID> = []
    var currentDraft = ""
    var dismissSidebar: (() -> Void)?
}

private struct AdaptiveTraitsHarness: View {
    @ObservedObject var state: AdaptiveNavigationState

    var body: some View {
        AdaptiveNavigationHarness(state: state, allowsSidebar: false)
            .environment(\.chatDisplayTraits, state.displayTraits)
    }
}

private struct AdaptiveNavigationHarness: View {
    @ObservedObject var state: AdaptiveNavigationState
    var allowsSidebar = true

    var body: some View {
        ChatNavigationView(
            isTabListPresented: $state.presented,
            hasTabs: state.hasTabs, canSelectTabs: state.canSelectTabs,
            allowsSidebar: allowsSidebar
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
    @Environment(\.chatDisplayTraits) private var displayTraits
    let state: AdaptiveNavigationState
    @State private var identity = UUID()
    @State private var draft = "Unsent draft"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Can we start modernizing AgentGateway for iPhone Duo?")
                        .font(.headline)
                    Text("Chat stays front and center. Your session drawer, draft, and streaming reply stay with you as the display changes.")
                    Text("Duo workspace").font(.title2.bold())
                    Text("Navigation actions use the system toolbar. The composer stays with the conversation.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
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
            } usage: {} delivery: {} refresh: {
                Button {} label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Refresh")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    state.refreshFrame = $0
                }
            } settings: {
                ChatSettingsButton {}
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        state.settingsFrame = $0
                    }
            } leading: {
                ChatTabsButton(isEnabled: true) { state.presented = true }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        state.tabsFrame = $0
                    }
            } trailing: {
                Menu {
                    Button("Settings", systemImage: "gearshape") {}
                } label: {
                    ChatMenuIcon()
                }
                .accessibilityLabel("Chat menu")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    state.menuFrame = $0
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                state.headerFrame = $0
            }
        }
        .onChange(of: displayTraits, initial: true) { _, value in state.observedTraits = value }
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
