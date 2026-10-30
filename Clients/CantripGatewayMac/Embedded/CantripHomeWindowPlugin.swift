import AppKit
import SwiftUI

/// Cantrip's Home window inside the Cantrip menu bar app: the same window as Cantrip Gateway Mac,
/// built as a plug-in bundle (`CantripHomeWindow.bundle`, macOS 26) that Cantrip.app loads when
/// its interface is set to Window. Cantrip passes its own server on this Mac (loopback URL and
/// token) on every open; nothing is saved to the Keychain or to Gateway Mac's server list.
///
/// Cantrip calls these class methods by selector after loading the bundle:
/// `showWithURL:token:` opens or focuses the window, `close` closes it, `isOpen` reports it,
/// and `setOnClose:` registers a block run when the user closes the window.
@objc(CantripHomeWindowPlugin)
public final class CantripHomeWindowPlugin: NSObject {
    @MainActor private static var controller: EmbeddedHomeWindowController?
    @MainActor private static var closeHandler: (() -> Void)?

    @MainActor @objc public static func show(withURL url: String, token: String) {
        if controller == nil { controller = EmbeddedHomeWindowController { closeHandler?() } }
        controller?.show(url: url, token: token)
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
}

/// One Home window and the models behind it, kept for the life of Cantrip so reopening keeps the
/// same conversation and drafts. Settings live in their own defaults suite inside Cantrip's
/// preferences, apart from Cantrip's own keys and from Gateway Mac's saved servers.
@MainActor
final class EmbeddedHomeWindowController: NSObject, NSWindowDelegate {
    static let defaultsSuite = "cantrip.home-window"
    static let serverName = "This Mac"

    private let onClose: () -> Void
    private var window: NSWindow?
    private let defaults: UserDefaults
    private let env: HermesEnv
    private let remote: CantripRemoteModel
    private let voice = VoiceController()
    private let navigation = MacHomeNavigation()
    private let directLocal = DirectLocalChat()
    private var connected: (url: String, token: String)?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        defaults = UserDefaults(suiteName: Self.defaultsSuite) ?? .standard
        env = HermesEnv(servers: ServerProfiles(kind: .hermes, defaults: defaults), defaults: defaults)
        remote = CantripRemoteModel(servers: ServerProfiles(kind: .cantrip, defaults: defaults))
        super.init()
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(url: String, token: String) {
        if window == nil { makeWindow() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        remote.setAppActive(true)
        guard connected?.url != url || connected?.token != token else { return }
        connected = (url, token)
        Task { await connect(url: url, token: token) }
    }

    func close() {
        window?.close()
    }

    /// Saves This Mac (replacing an older entry whose port or token changed) and opens Home on it.
    private func connect(url: String, token: String) async {
        let stale = remote.servers.servers.filter {
            $0.name == Self.serverName && ($0.url != url || (try? remote.servers.credential(for: $0)) != token)
        }
        for server in stale { try? remote.removeServer(server) }
        if !remote.servers.servers.contains(where: { $0.name == Self.serverName }) {
            try? remote.addServer(ServerDraft(name: Self.serverName, url: url, credential: token,
                                              tailscaleOnly: true, directAddress: ""))
        }
        guard let server = remote.servers.servers.first(where: { $0.name == Self.serverName }) else { return }
        try? await remote.selectServer(server)
        if env.executionLane != .home && env.executionLane != .cantrip { env.select(.home) }
        if env.executionLane == .home { await remote.selectHome() }
    }

    private func makeWindow() {
        let root = MacHomeWindow(env: env, remote: remote, voice: voice, navigation: navigation,
                                 directLocal: directLocal)
            .preferredColorScheme(.dark)
        let hosting = NSHostingController(rootView: root)
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
        voice.stopListening(finalize: false)
        voice.stopSpeaking()
        remote.setAppActive(false)
        // Back to a menu bar app: no Dock icon while only the panel is around.
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}
