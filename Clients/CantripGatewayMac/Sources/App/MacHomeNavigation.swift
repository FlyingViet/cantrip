import SwiftUI

/// Window-level state shared by the Home window, its toolbar and the menu bar commands.
@MainActor
final class MacHomeNavigation: ObservableObject {
    static let windowID = "home"

    @Published var section: CantripHomeSection = .chat
    @Published var showingBackground = false
    @Published var sheet: MacHomeSheet?
    /// Text to place in the composer when switching to Chat (from Tasks/Artifacts "+").
    @Published var composerPrefill: String?
    /// Bumped to move keyboard focus into the composer.
    @Published var composerFocusRequest = 0

    func openChat(prefill: String? = nil) {
        section = .chat
        if let prefill { composerPrefill = prefill }
        composerFocusRequest += 1
    }

    /// Shows a waiting background run's request in Home's Background list.
    func openRun(_ sessionID: String, remote: CantripRemoteModel) {
        remote.homeBackgroundFocus = sessionID
        showingBackground = true
    }

    func closeAll() {
        sheet = nil
        showingBackground = false
    }
}

enum MacHomeSheet: String, Identifiable {
    case usage, memory, builds, mascot, maintenance, voiceMode, queue

    var id: String { rawValue }
}
