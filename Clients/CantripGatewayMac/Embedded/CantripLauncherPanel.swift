import AppKit
import SwiftUI

/// Cantrip's ⌥Space panel while the background agents run the tabs (Cantrip.app as their client):
/// the Home window's chat in a floating panel, on the same Mac and tab as the Home window, with
/// Cantrip.app's apps, files, selection and screenshots (`MacPanelLauncher`). Like Spotlight it
/// opens where the pointer is and hides when you click elsewhere, unless pinned.
final class EmbeddedLauncherPanel: NSPanel {
    static let defaultSize = NSSize(width: 720, height: 560)
    private static let topFractionKey = "cantrip.panel.topFraction"
    private static let sizeKey = "cantrip.panel.size"

    var onEscape: (() -> Void)?
    private let defaults: UserDefaults
    private var positioning = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.sizeKey).map(NSSizeFromString)
        let size = saved.flatMap { $0.width >= 480 && $0.height >= 320 ? $0 : nil } ?? Self.defaultSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   // Non-activating, like Spotlight and Cantrip's own panel: it takes the keyboard
                   // without making Cantrip the active app (macOS may refuse that from a hotkey).
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Cantrip"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 320)
        setAccessibilityIdentifier("cantrip.panel")

        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.defaults.set(NSStringFromSize(self.frame.size), forKey: Self.sizeKey) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.rememberTop() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Where the pointer is: centered, its top edge where you last dragged it (as a share of the
    /// screen's height), else in the upper third, like Cantrip's own panel.
    func placeOnPointerScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let stored = defaults.double(forKey: Self.topFractionKey)
        let top = visible.minY + visible.height * (stored > 0 ? stored : 0.78)
        var size = frame.size
        size.width = min(size.width, visible.width * 0.95)
        size.height = min(size.height, visible.height * 0.9)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: max(top - size.height, visible.minY))
        positioning = true
        setFrame(NSRect(origin: origin, size: size), display: true)
        positioning = false
    }

    private func rememberTop() {
        guard !positioning, !inLiveResize, isVisible, let visible = screen?.visibleFrame, visible.height > 0 else { return }
        defaults.set(min(max((frame.maxY - visible.minY) / visible.height, 0.2), 0.98), forKey: Self.topFractionKey)
    }
}

/// The panel's own state and actions, shared with its header.
@MainActor
final class EmbeddedPanelChrome: ObservableObject {
    /// Pinned: clicking elsewhere leaves the panel up.
    @Published var pinned = false
    var openHomeWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var close: () -> Void = {}
}

/// Which surface presents the sheets the shared model asks for (`macPresentsRemoteSheets`): the
/// panel while it's in front, else the Home window.
@MainActor
final class EmbeddedSurfaces: ObservableObject {
    @Published var panelInFront = false
}

struct EmbeddedSheetGate<Content: View>: View {
    @ObservedObject var surfaces: EmbeddedSurfaces
    let isPanel: Bool
    let content: Content

    var body: some View {
        content.environment(\.macPresentsRemoteSheets, isPanel ? surfaces.panelInFront : !surfaces.panelInFront)
    }
}

/// The panel's content: a header (Home or tab, the tab's actions, Home window, Settings, pin) over
/// Home's chat, which shows Home's conversation or the open tab like the Home window's detail.
struct MacLauncherPanelView: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var navigation: MacHomeNavigation
    @ObservedObject var launcher: MacPanelLauncher
    @ObservedObject var chrome: EmbeddedPanelChrome
    @ObservedObject var directLocal: DirectLocalChat
    @StateObject private var vm: ChatViewModel
    @StateObject private var usageModel = CopilotUsageModel()
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""

    init(env: HermesEnv, remote: CantripRemoteModel, voice: VoiceController, navigation: MacHomeNavigation,
         launcher: MacPanelLauncher, chrome: EmbeddedPanelChrome, directLocal: DirectLocalChat) {
        navigation.attach(env: env, remote: remote)
        self.env = env
        self.remote = remote
        self.voice = voice
        self.navigation = navigation
        self.launcher = launcher
        self.chrome = chrome
        self.directLocal = directLocal
        _vm = StateObject(wrappedValue: ChatViewModel(env: env, remote: remote, voice: voice))
    }

    private var isTabOpen: Bool { vm.activeLane == .cantrip }

    private var visibleTabID: String? {
        isTabOpen ? remote.selectedSessionID : CantripHomeIdentity.sessionID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MacHomeChatView(remote: remote, vm: vm, voice: voice, navigation: navigation,
                            slashCommands: remote.slashCommands, isTab: isTabOpen,
                            launcher: launcher, showsTerminal: false)
                .id(isTabOpen ? "tab" : "home")
        }
        // The header sits in the hidden title bar's place.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 480, minHeight: 320)
        .modifier(MacHomeSheets(remote: remote, voice: voice, navigation: navigation, vm: vm,
                                usageModel: usageModel, directLocal: directLocal))
        .onAppear {
            vm.setAppActive(true)
            if env.executionLane != vm.activeLane { vm.switchLane(to: env.executionLane) }
            vm.syncRemoteTranscript()
        }
        .onChange(of: env.executionLane) { _, lane in vm.switchLane(to: lane) }
        .onChange(of: vm.sending) { _, sending in
            if !sending, env.executionLane != vm.activeLane { vm.switchLane(to: env.executionLane) }
        }
        .onChange(of: remote.transcriptRevision) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: remote.selectedSessionID) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: visibleTabID, initial: true) { _, id in remote.setVisibleTab(id) }
        .onChange(of: remote.selectedServerID) { _, _ in
            vm.leaveVoiceMode()
            vm.remoteDeliveryMode = .auto
            navigation.closeAll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            tabMenu
            Spacer(minLength: 8)
            if isTabOpen, let session = remote.selectedSession,
               remote.sessions.contains(where: { $0.id == session.id }) {
                Menu {
                    CantripTabActions(
                        model: remote, session: session,
                        onRename: { navigation.renamingTab = session },
                        onClose: { navigation.closeTab(session.id) },
                        onOpenTab: { navigation.openTab($0) }
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("This tab's actions")
                .accessibilityLabel("Tab actions")
                .accessibilityIdentifier("panel.tab.menu")
            } else if remote.selectedSession != nil {
                Button {
                    remote.modelSettingsSession = remote.selectedSession
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(remote.isMutating)
                .help("Home's model settings")
                .accessibilityLabel("Model settings")
            }
            Button(action: chrome.openHomeWindow) {
                Image(systemName: "macwindow")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open in the Home window (⌘O)")
            .accessibilityLabel("Open in the Home window")
            .accessibilityIdentifier("panel.openHome")
            Button(action: chrome.openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            Button { chrome.pinned.toggle() } label: {
                Image(systemName: chrome.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(chrome.pinned ? Color.accentColor : Color.primary)
            }
            .help(chrome.pinned ? "Pinned: stays up when you click elsewhere" : "Pin: keep the panel up when you click elsewhere")
            .accessibilityLabel(chrome.pinned ? "Unpin panel" : "Pin panel")
            .accessibilityIdentifier("panel.pin")
            Button(action: chrome.close) {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")
            .accessibilityLabel("Close panel")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var tabMenu: some View {
        Menu {
            Button {
                navigation.showHome(.chat)
            } label: {
                Label(CantripMascotName.display(mascotName) + " (Home)", systemImage: "house")
            }
            if let groups = CantripTabGrouping.groups(remote.sessions, sections: remote.tabSections) {
                ForEach(groups) { group in
                    Section(group.name) { tabButtons(group.sessions) }
                }
            } else if !remote.sessions.isEmpty {
                Section("Tabs") { tabButtons(remote.sessions) }
            }
            Divider()
            Button("New Tab", systemImage: "plus") { navigation.createTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!remote.isConfigured || remote.isMutating)
        } label: {
            HStack(spacing: 6) {
                if isTabOpen, let session = remote.selectedSession {
                    CantripTabStatusIndicator(session: session).frame(width: 14)
                    Text(session.title).lineLimit(1)
                } else {
                    Image(systemName: "house.fill").foregroundStyle(.tint)
                    Text(CantripMascotName.display(mascotName)).lineLimit(1)
                }
                if !isThisMac, let name = remote.servers.selected?.name {
                    Text("· \(name)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch to Home or another tab")
        .accessibilityLabel("Home and tabs")
        .accessibilityIdentifier("panel.tabs")
    }

    @ViewBuilder private func tabButtons(_ sessions: [CantripRemoteSession]) -> some View {
        ForEach(sessions) { session in
            Button {
                navigation.openTab(session.id)
            } label: {
                Label(session.title, systemImage: session.isStreaming ? "circle.dotted.circle" : "circle")
            }
        }
    }

    /// This Mac's own server (loopback, with Cantrip's local key) rather than a paired Mac.
    private var isThisMac: Bool {
        guard let url = remote.servers.selected.flatMap({ URL(string: $0.url) }) else { return true }
        return CantripLocalClientKey.key(for: url) != nil
    }
}
