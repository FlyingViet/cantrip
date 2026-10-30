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
/// built from the CantripGatewayMac submodule by `make app` when Xcode is installed. It connects
/// to this host's own server on loopback, so everything Gateway does works on this Mac's tabs.
@MainActor
enum HomeWindow {
    static let bundleName = "CantripHomeWindow.bundle"
    private static var pluginClass: AnyClass?

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
                                          with: "http://127.0.0.1:\(port)" as NSString, with: token as NSString)
        return true
    }

    static func close() {
        guard let plugin = pluginClass else { return }
        _ = (plugin as AnyObject).perform(NSSelectorFromString("close"))
    }

    static var isOpen: Bool {
        guard let plugin = pluginClass else { return false }
        let selector = NSSelectorFromString("isOpen")
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
        Log.write("home-window: loaded \(url.lastPathComponent)")
        return principal
    }
}
