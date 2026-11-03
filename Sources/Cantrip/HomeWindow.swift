import AppKit

/// Cantrip's interface on this Mac.
enum InterfaceMode: String, CaseIterable, Identifiable {
    /// The floating panel (⌥Space).
    case panel
    /// Cantrip Gateway's Home window: sidebar, tabs, Home, tasks, artifacts and terminal.
    case window

    var id: String { rawValue }
    var label: String { self == .panel ? "Panel" : "Window" }
}

/// Cantrip Gateway's Home window inside Cantrip.app: `Contents/PlugIns/CantripHomeWindow.bundle`,
/// built from Clients/CantripGatewayMac by `make app` when Xcode is installed. It connects
/// to this host's own server on loopback, so everything Gateway does works on this Mac's tabs.
@MainActor
enum HomeWindow {
    static let bundleName = "CantripHomeWindow.bundle"
    private static var pluginClass: AnyClass?

    /// The key the windows send as this Mac's own app: this process's, or the background engine's
    /// when the app is its client (`ClientAppDelegate`).
    static var localKey: String = LocalClientKey.value {
        didSet {
            guard let pluginClass, localKey != oldValue else { return }
            _ = (pluginClass as AnyObject).perform(NSSelectorFromString("setLocalKey:"), with: localKey as NSString)
        }
    }

    static var bundleURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Why the window can't be used on this Mac, or nil when it can.
    static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "The Home window needs macOS 26." }
        guard bundleURL != nil else {
            return "This Cantrip build doesn't include the Home window. Install Xcode and xcodegen, then rebuild (make app)."
        }
        return nil
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// Opens (or brings forward) the window on this host's loopback server. False if it can't.
    @discardableResult
    static func open(port: Int, token: String, onClose: @escaping () -> Void) -> Bool {
        guard let plugin = load() else { return false }
        let setOnClose = NSSelectorFromString("setOnClose:")
        let handler: @convention(block) () -> Void = { onClose() }
        _ = (plugin as AnyObject).perform(setOnClose, with: unsafeBitCast(handler, to: AnyObject.self))
        _ = (plugin as AnyObject).perform(NSSelectorFromString("showWithURL:token:"),
                                          with: url(port) as NSString, with: token as NSString)
        return true
    }

    /// Cantrip's Settings window (the shared Settings pages, this Mac's included), on its own:
    /// the panel's gear, ⌘, and the menu bar open it. False if the plug-in can't load.
    @discardableResult
    static func openSettings(port: Int, token: String, onClose: @escaping () -> Void) -> Bool {
        guard let plugin = load() else { return false }
        let handler: @convention(block) () -> Void = { onClose() }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("setOnSettingsClose:"),
                                          with: unsafeBitCast(handler, to: AnyObject.self))
        _ = (plugin as AnyObject).perform(NSSelectorFromString("showSettingsWithURL:token:"),
                                          with: url(port) as NSString, with: token as NSString)
        return true
    }

    /// This Mac's server moved to another port or has a new token: the open windows reconnect.
    static func refresh(port: Int, token: String) {
        guard let plugin = pluginClass else { return }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("refreshWithURL:token:"),
                                          with: url(port) as NSString, with: token as NSString)
    }

    private static func url(_ port: Int) -> String { "http://127.0.0.1:\(port)" }

    static func close() {
        guard let plugin = pluginClass else { return }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("close"))
    }

    static var isOpen: Bool {
        classBool("isOpen")
    }

    // MARK: The ⌥Space panel

    /// The plug-in can show the ⌥Space panel (`CantripHomeWindowPlugin.showPanel`); older ones can't.
    static var supportsPanel: Bool {
        guard let plugin = load() else { return false }
        return class_getClassMethod(plugin, NSSelectorFromString("showPanelWithURL:token:")) != nil
    }

    static var isPanelOpen: Bool { classBool("isPanelOpen") }

    /// Opens the panel on this Mac's server with what goes along with its messages (`context`:
    /// the selection and screenshots), its searches answered by `PanelSearch`. False if it can't.
    @discardableResult
    static func openPanel(port: Int, token: String, context: [String: Any], onClose: @escaping () -> Void) -> Bool {
        guard supportsPanel, let plugin = pluginClass else { return false }
        installPanelSearch(plugin)
        let handler: @convention(block) () -> Void = { onClose() }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("setOnPanelClose:"),
                                          with: unsafeBitCast(handler, to: AnyObject.self))
        setPanelContext(context)
        _ = (plugin as AnyObject).perform(NSSelectorFromString("showPanelWithURL:token:"),
                                          with: url(port) as NSString, with: token as NSString)
        return true
    }

    /// Screenshots that finished after the panel opened, or a selection grabbed while it's up.
    static func setPanelContext(_ context: [String: Any]) {
        guard let plugin = pluginClass else { return }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("setPanelContext:"), with: context as NSDictionary)
    }

    static func closePanel() {
        guard let plugin = pluginClass, isPanelOpen else { return }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("closePanel"))
    }

    private static var panelSearchInstalled = false

    private static func installPanelSearch(_ plugin: AnyClass) {
        guard !panelSearchInstalled else { return }
        panelSearchInstalled = true
        let search = PanelSearch.shared
        search.publish = { list in
            _ = (plugin as AnyObject).perform(NSSelectorFromString("setPanelSuggestions:"), with: list as NSArray)
        }
        search.onOpened = { closePanel() }
        let query: @convention(block) (NSString) -> Void = { text in
            MainActor.assumeIsolated { PanelSearch.shared.search(text as String) }
        }
        let open: @convention(block) (NSString) -> Void = { id in
            MainActor.assumeIsolated { PanelSearch.shared.open(id as String) }
        }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("setOnPanelQuery:"),
                                          with: unsafeBitCast(query, to: AnyObject.self))
        _ = (plugin as AnyObject).perform(NSSelectorFromString("setOnPanelOpenSuggestion:"),
                                          with: unsafeBitCast(open, to: AnyObject.self))
    }

    private static func classBool(_ name: String) -> Bool {
        guard let plugin = pluginClass else { return false }
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(plugin, selector) else { return false }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(plugin, selector)
    }

    private static func load() -> AnyClass? {
        if let pluginClass { return pluginClass }
        guard isAvailable, let url = bundleURL, let bundle = Bundle(url: url) else { return nil }
        do { try bundle.loadAndReturnError() } catch {
            Log.write("home-window: couldn't load the plug-in: \(error.localizedDescription)")
            return nil
        }
        guard let principal = bundle.principalClass,
              class_getClassMethod(principal, NSSelectorFromString("showWithURL:token:")) != nil else {
            Log.write("home-window: the plug-in has no CantripHomeWindowPlugin")
            return nil
        }
        pluginClass = principal
        // Marks the windows' requests as this Mac's own app (`SettingsManifest`, `LocalClientKey`).
        _ = (principal as AnyObject).perform(NSSelectorFromString("setLocalKey:"), with: localKey as NSString)
        Log.write("home-window: loaded \(url.lastPathComponent)")
        return principal
    }
}
