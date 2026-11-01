import AppKit
import SwiftUI

extension FocusedValues {
    /// The Home window's open tab while it can start fresh; nil disables the command.
    @Entry var startFreshTabID: String?
}

/// The menu bar: the standard File, View, Tab, Window and Help menus. Memory, Usage Limits and
/// the mascot are in Settings (⌘,), like on the iPhone.
struct MacHomeCommands: Commands {
    let remote: CantripRemoteModel
    let navigation: MacHomeNavigation
    @AppStorage("hermes.paused") private var paused = false
    @FocusedValue(\.startFreshTabID) private var startFreshTabID

    var body: some Commands {
        // File: Home is a single window, so New makes a tab or a message, not a window.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { navigation.createTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Message") { navigation.openChat() }
                .keyboardShortcut("n", modifiers: .command)
        }

        // View: Home's sections and panes, above the system's sidebar and toolbar items.
        CommandGroup(before: .sidebar) {
            ForEach(Array(CantripHomeSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigation.showHome(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("Local Model on This Mac") { navigation.showDirectLocal() }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Background") { navigation.showBackground() }
                .keyboardShortcut("b", modifiers: .command)
            Button("GitHub Builds") { navigation.sheet = .builds }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Toggle Terminal") { navigation.showingTerminal.toggle() }
                .keyboardShortcut("`", modifiers: .control)
            Divider()
        }

        // Tab: the open tab's (or Home's) model and conversation, and the agent.
        CommandMenu("Tab") {
            Button("Model Settings…") {
                if let session = remote.selectedSession { remote.modelSettingsSession = session }
            }
            .keyboardShortcut(";", modifiers: .command)
            Button(CantripStartFresh.title) {
                guard let id = startFreshTabID else { return }
                Task { await remote.startFresh(sessionID: id) }
            }
            .disabled(startFreshTabID == nil)
            Divider()
            Button(paused ? "Resume Agent" : "Pause Agent") { paused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Voice Mode") { navigation.sheet = .voiceMode }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(paused)
        }

        CommandGroup(replacing: .help) {
            Link("Cantrip Gateway Help", destination: MacHomeLinks.help)
            Link("Cantrip Documentation", destination: MacHomeLinks.docs)
        }
    }
}

enum MacHomeLinks {
    static let help = URL(string: "https://github.com/FlyingViet/CantripGatewayMac#readme")!
    static let docs = URL(string: "https://github.com/FlyingViet/cantrip/tree/main/docs")!
}

/// The Dock icon's menu: a new message or tab, Background, pausing the agent and Settings.
@MainActor
final class MacDockMenu: NSObject {
    private weak var remote: CantripRemoteModel?
    private weak var navigation: MacHomeNavigation?

    func attach(remote: CantripRemoteModel, navigation: MacHomeNavigation) {
        self.remote = remote
        self.navigation = navigation
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        let paused = UserDefaults.standard.bool(forKey: "hermes.paused")
        for (title, action, enabled) in [
            ("New Message", #selector(newMessage), navigation != nil),
            ("New Tab", #selector(newTab), remote?.isConfigured == true),
            ("Background", #selector(background), navigation != nil),
        ] as [(String, Selector, Bool)] {
            menu.addItem(item(title, action, enabled: enabled))
        }
        menu.addItem(.separator())
        menu.addItem(item(paused ? "Resume Agent" : "Pause Agent", #selector(togglePause), enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(settings), enabled: true))
        return menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func newMessage() {
        showHome()
        navigation?.openChat()
    }

    @objc private func newTab() {
        showHome()
        navigation?.createTab()
    }

    @objc private func background() {
        showHome()
        navigation?.showBackground()
    }

    @objc private func togglePause() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "hermes.paused"), forKey: "hermes.paused")
    }

    @objc private func settings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Brings Home's window forward (the Dock opens it if it was closed).
    private func showHome() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(MacHomeNavigation.windowID) == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
