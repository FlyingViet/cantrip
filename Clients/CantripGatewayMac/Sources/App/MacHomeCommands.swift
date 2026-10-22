import SwiftUI

extension FocusedValues {
    /// The Home window's open tab while it can start fresh; nil disables the command.
    @Entry var startFreshTabID: String?
}

/// Menu bar commands for the Home window.
struct MacHomeCommands: Commands {
    let remote: CantripRemoteModel
    let navigation: MacHomeNavigation
    @AppStorage("hermes.paused") private var paused = false
    @FocusedValue(\.startFreshTabID) private var startFreshTabID

    var body: some Commands {
        // Home is a single window.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Home") {
            ForEach(Array(CantripHomeSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigation.showHome(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("Background") { navigation.showBackground() }
                .keyboardShortcut("b", modifiers: .command)
            Divider()
            Button("New Tab") { navigation.createTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Message") { navigation.openChat() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Refresh") { Task { await remote.refreshNow() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Voice Mode") { navigation.sheet = .voiceMode }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(paused)
            Button(paused ? "Resume Agent" : "Pause Agent") { paused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Model Settings…") {
                if let session = remote.selectedSession { remote.modelSettingsSession = session }
            }
            .keyboardShortcut(";", modifiers: .command)
            Button(CantripStartFresh.title) {
                guard let id = startFreshTabID else { return }
                Task { await remote.startFresh(sessionID: id) }
            }
            .disabled(startFreshTabID == nil)
            Button("Copilot Usage") { navigation.sheet = .usage }
            Button("Cantrip Memory") { navigation.sheet = .memory }
            Button("GitHub Builds") { navigation.sheet = .builds }
            Button("Customize Mascot…") { navigation.sheet = .mascot }
        }
    }
}
