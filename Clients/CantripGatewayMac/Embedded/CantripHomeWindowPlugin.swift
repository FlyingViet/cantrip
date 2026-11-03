import AppKit
import SwiftUI

/// Cantrip's Home window inside the Cantrip menu bar app: the same window as Cantrip Gateway Mac,
/// built as a plug-in bundle (`CantripHomeWindow.bundle`, macOS 26) that Cantrip.app loads when
/// its interface is set to Window. Cantrip passes its own server on this Mac (loopback URL and
/// token) on every open; it shows as "This Mac" in Settings › Macs, where other Macs can be paired
/// too (see `ThisMacServer`). Nothing is shared with Gateway Mac's server list or Keychain items.
///
/// Cantrip calls these class methods by selector after loading the bundle:
/// `showWithURL:token:` opens or focuses the window, `close` closes it, `isOpen` reports it,
/// and `setOnClose:` registers a block run when the user closes the window.
/// `showSettingsWithURL:token:` opens Settings on its own (the panel's gear, ⌘,) and
/// `setOnSettingsClose:` hears it close; `refreshWithURL:token:` follows a new port or token; and
/// `setLocalKey:` hands over the key that tells Cantrip's server these windows are its own.
///
/// The ⌥Space panel (while the background agents run the tabs): `showPanelWithURL:token:` opens
/// it, `closePanel` hides it, `isPanelOpen` reports it and `setOnPanelClose:` hears it hide.
/// `setPanelContext:` gives it the selection and screenshots (`{selection: {text, appName}?,
/// screenshots: [{path, index, isMain}], newOpening}`); as you type it asks `setOnPanelQuery:`'s
/// block for apps and files, which Cantrip answers with `setPanelSuggestions:` (`[{id, kind,
/// title, subtitle?, action?, icon?}]`), and opens one through `setOnPanelOpenSuggestion:`'s block.
@objc(CantripHomeWindowPlugin)
public final class CantripHomeWindowPlugin: NSObject {
    @MainActor private static var controller: EmbeddedHomeWindowController?
    @MainActor private static var closeHandler: (() -> Void)?
    @MainActor private static var settingsCloseHandler: (() -> Void)?
    @MainActor private static var localKey: String?

    @MainActor private static var shared: EmbeddedHomeWindowController {
        if let controller { return controller }
        let created = EmbeddedHomeWindowController(onClose: { closeHandler?() },
                                                   onSettingsClose: { settingsCloseHandler?() })
        controller = created
        return created
    }

    @MainActor @objc public static func show(withURL url: String, token: String) {
        CantripLocalClientKey.register(localKey, for: url)
        shared.show(url: url, token: token)
    }

    @MainActor @objc public static func showSettings(withURL url: String, token: String) {
        CantripLocalClientKey.register(localKey, for: url)
        shared.showSettings(url: url, token: token)
    }

    /// This Mac's server moved (a new port) or its token changed: reconnect without showing anything.
    @MainActor @objc public static func refresh(withURL url: String, token: String) {
        guard let controller else { return }
        CantripLocalClientKey.register(localKey, for: url)
        controller.refresh(url: url, token: token)
    }

    @MainActor @objc public static func setLocalKey(_ key: String) {
        localKey = key
    }

    @MainActor @objc public static func setOnSettingsClose(_ handler: @escaping () -> Void) {
        settingsCloseHandler = handler
    }

    @MainActor @objc public static func close() {
        controller?.close()
    }

    @MainActor @objc public static var isOpen: Bool {
        controller?.isOpen ?? false
    }

    @MainActor @objc public static func setOnClose(_ handler: @escaping () -> Void) {
        closeHandler = handler
    }

    // MARK: The ⌥Space panel

    @MainActor @objc public static func showPanel(withURL url: String, token: String) {
        CantripLocalClientKey.register(localKey, for: url)
        shared.showPanel(url: url, token: token)
    }

    @MainActor @objc public static func closePanel() {
        controller?.closePanel()
    }

    @MainActor @objc public static var isPanelOpen: Bool {
        controller?.isPanelOpen ?? false
    }

    @MainActor @objc public static func setOnPanelClose(_ handler: @escaping () -> Void) {
        shared.onPanelClose = handler
    }

    @MainActor @objc public static func setPanelContext(_ context: NSDictionary) {
        let values = context as? [String: Any] ?? [:]
        let (selection, screenshots) = MacPanelLauncher.context(from: values)
        shared.launcher.setContext(selection: selection, screenshots: screenshots,
                                   newOpening: (values["newOpening"] as? Bool) ?? false)
    }

    @MainActor @objc public static func setPanelSuggestions(_ suggestions: NSArray) {
        shared.launcher.setSuggestions(MacPanelLauncher.suggestions(from: suggestions as? [[String: Any]] ?? []))
    }

    @MainActor @objc public static func setOnPanelQuery(_ handler: @escaping (String) -> Void) {
        shared.launcher.onQuery = handler
    }

    @MainActor @objc public static func setOnPanelOpenSuggestion(_ handler: @escaping (String) -> Void) {
        shared.launcher.onOpen = handler
    }
}

/// One Home window and the models behind it, kept for the life of Cantrip so reopening keeps the
/// same conversation and drafts. Settings live in their own defaults suite inside Cantrip's
/// preferences, apart from Cantrip's own keys and from Gateway Mac's saved servers.
@MainActor
final class EmbeddedHomeWindowController: NSObject, NSWindowDelegate {
    static let defaultsSuite = "cantrip.home-window"

    private let onClose: () -> Void
    private let onSettingsClose: () -> Void
    private var window: NSWindow?
    private let defaults: UserDefaults
    private let env: HermesEnv
    private let remote: CantripRemoteModel
    private let voice = VoiceController()
    private let navigation = MacHomeNavigation()
    private let directLocal = DirectLocalChat()
    private let thisMacToken: ThisMacToken
    private var settingsWindow: NSWindow?
    private var connected: (url: String, token: String)?
    /// The ⌥Space panel: its own navigation (sheets, composer focus) on the same model and tab.
    private var panel: EmbeddedLauncherPanel?
    private let panelNavigation = MacHomeNavigation()
    let launcher = MacPanelLauncher()
    private let chrome = EmbeddedPanelChrome()
    private let surfaces = EmbeddedSurfaces()
    var onPanelClose: (() -> Void)?

    init(onClose: @escaping () -> Void, onSettingsClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onSettingsClose = onSettingsClose
        defaults = UserDefaults(suiteName: Self.defaultsSuite) ?? .standard
        env = HermesEnv(servers: ServerProfiles(kind: .hermes, defaults: defaults), defaults: defaults)
        let token = ThisMacToken()
        thisMacToken = token
        let credentials = token.store(persistent: .keychain(service: ThisMacServer.keychainService))
        remote = CantripRemoteModel(servers: ServerProfiles(kind: .cantrip, defaults: defaults, credentials: credentials))
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(url: String, token: String) {
        if window == nil { makeWindow() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        remote.setAppActive(true)
        refresh(url: url, token: token)
    }

    /// Settings without the Home window: the panel's gear and ⌘, open it on its own.
    func showSettings(url: String, token: String) {
        NSApp.setActivationPolicy(.regular)
        remote.setAppActive(true)
        refresh(url: url, token: token)
        showSettings()
    }

    func refresh(url: String, token: String) {
        guard connected?.url != url || connected?.token != token else { return }
        connected = (url, token)
        Task { await connect(url: url, token: token) }
    }

    private var isSettingsOpen: Bool { settingsWindow?.isVisible == true }

    func close() {
        window?.close()
    }

    /// Refreshes This Mac and opens Home on the Mac in use: This Mac, unless another Mac was picked
    /// in Settings › Macs (then it stays on that one, also after Cantrip relaunches).
    private func connect(url: String, token: String) async {
        if let registration = try? ThisMacServer.register(url: url, token: token, remote: remote,
                                                          local: thisMacToken, defaults: defaults) {
            let server = registration.server
            if remote.selectedServerID == server.id {
                try? await remote.reconnectSelectedServer()
            } else if remote.servers.selectedID == nil || remote.servers.selectedID == server.id
                        || registration.replacedSelection {
                try? await remote.selectServer(server)
            }
        }
        if env.executionLane != .home && env.executionLane != .cantrip { env.select(.home) }
        if env.executionLane == .home { await remote.selectHome() }
    }

    /// Settings (the same pages as Gateway Mac's), in a window of its own: Cantrip.app has no
    /// SwiftUI Settings scene for `SettingsLink` to open.
    func showSettings() {
        if settingsWindow == nil {
            let root = MacSettingsView(env: env, remote: remote, voice: voice, directLocal: directLocal)
                .preferredColorScheme(.dark)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Cantrip Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("CantripHomeSettingsWindow")
            if !window.setFrameUsingName("CantripHomeSettingsWindow") { window.center() }
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() {
        let root = MacHomeWindow(env: env, remote: remote, voice: voice, navigation: navigation,
                                 directLocal: directLocal)
            .environment(\.macOpenSettings, { [weak self] in self?.showSettings() })
            .preferredColorScheme(.dark)
        let hosting = NSHostingController(rootView: EmbeddedSheetGate(surfaces: surfaces, isPanel: false, content: root))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cantrip Home"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("CantripHomeWindow")
        if !window.setFrameUsingName("CantripHomeWindow") { window.center() }
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === panel { return }
        if closing === settingsWindow {
            if window?.isVisible != true { putAway() }
            onSettingsClose()
            return
        }
        voice.stopListening(finalize: false)
        voice.stopSpeaking()
        // Settings stays open on its own (Cantrip's Settings window, also used from the panel).
        if !isSettingsOpen { putAway() }
        onClose()
    }

    /// Back to a menu bar app: no Dock icon, and no polling unless the panel is up.
    private func putAway() {
        if panel?.isVisible != true { remote.setAppActive(false) }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: The ⌥Space panel

    var isPanelOpen: Bool { panel?.isVisible == true }

    func showPanel(url: String, token: String) {
        if panel == nil { makePanel() }
        guard let panel else { return }
        refresh(url: url, token: token)
        remote.setAppActive(true)
        remote.setFrontmost(true)
        if !panel.isVisible { panel.placeOnPointerScreen() }
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        surfaces.panelInFront = true
        panelNavigation.composerFocusRequest += 1
        launcher.beginOpening()
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panelDidHide()
    }

    private func panelDidHide() {
        surfaces.panelInFront = false
        launcher.reset()
        if window?.isVisible != true, !isSettingsOpen {
            voice.stopListening(finalize: false)
            remote.setAppActive(false)
        }
        onPanelClose?()
    }

    private func makePanel() {
        chrome.openHomeWindow = { [weak self] in
            guard let self, let connected = self.connected else { return }
            self.closePanel()
            self.show(url: connected.url, token: connected.token)
        }
        chrome.openSettings = { [weak self] in self?.showSettings() }
        chrome.close = { [weak self] in self?.closePanel() }
        let root = MacLauncherPanelView(env: env, remote: remote, voice: voice, navigation: panelNavigation,
                                        launcher: launcher, chrome: chrome, directLocal: directLocal)
            .environment(\.macOpenSettings, { [weak self] in self?.showSettings() })
            .preferredColorScheme(.dark)
        let panel = EmbeddedLauncherPanel(defaults: defaults)
        let hosting = NSHostingController(rootView: EmbeddedSheetGate(surfaces: surfaces, isPanel: true, content: root))
        hosting.sizingOptions = []
        // Keeps the panel's own title ("Cantrip") instead of the chat's.
        hosting.sceneBridgingOptions = []
        let size = panel.frame.size
        panel.contentViewController = hosting
        panel.setContentSize(size)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.closePanel() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            // After the switch, to see where focus went: its own sheet or a file picker keeps it up.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.panelLostFocus() } }
        }
        self.panel = panel
    }

    /// Like Spotlight: clicking another app or window puts the panel away, unless it's pinned or
    /// showing a sheet, alert or file picker of its own.
    private func panelLostFocus() {
        guard let panel, panel.isVisible, !panel.isKeyWindow, !chrome.pinned,
              panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if let key = NSApp.keyWindow, key.sheetParent === panel || key.parent === panel || key is NSOpenPanel {
            return
        }
        closePanel()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === panel { surfaces.panelInFront = true }
        else if window === self.window { surfaces.panelInFront = false }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        closePanel()
        return false
    }
}
