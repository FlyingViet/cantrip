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
    /// The project tab being renamed from the sidebar or the tab's More menu.
    @Published var renamingTab: CantripRemoteSession?
    /// A `cantrip pair` link opened on this Mac, waiting for the user to confirm.
    @Published var pairing: CantripPairingPrompt?
    private weak var env: HermesEnv?
    private weak var remote: CantripRemoteModel?

    /// Project tabs open in Home's detail pane; the lane records which one is showing.
    func attach(env: HermesEnv, remote: CantripRemoteModel) {
        self.env = env
        self.remote = remote
    }

    /// A tab is showing, not just requested (a switch waits for an in-flight send).
    var isTabOpen: Bool { env?.executionLane == .cantrip && remote?.isHomeSelected == false }

    /// Opens a project tab in the detail pane: sidebar rows, handoff cards and Background.
    func openTab(_ id: String) {
        guard let env, let remote else { return }
        closeAll()
        if isTabOpen {
            Task { await remote.selectSession(id) }
        } else {
            // Also retargets a tab switch still waiting for Home's send to finish.
            remote.prepareToOpenTab(id)
            env.select(.cantrip)
        }
    }

    /// Leaves an open tab for Home, optionally on one section.
    func showHome(_ section: CantripHomeSection? = nil) {
        if let section { self.section = section }
        if let env, env.executionLane != .home { env.select(.home) }
    }

    func createTab() {
        guard let remote, remote.isConfigured, !remote.isMutating else { return }
        Task {
            if let id = await remote.createTab() { openTab(id) }
        }
    }

    /// Closes a tab; closing the open one returns to Home.
    func closeTab(_ id: String) {
        guard let remote else { return }
        let wasOpen = isTabOpen && remote.selectedSessionID == id
        Task {
            if await remote.closeSession(id), wasOpen, isTabOpen { showHome() }
        }
    }

    /// Background runs load from Home, so the list opens there.
    func showBackground() {
        showHome()
        showingBackground = true
    }

    func openChat(prefill: String? = nil) {
        showHome(.chat)
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
        renamingTab = nil
    }

    /// Shows a pairing link's confirmation in place of any open sheet (a window shows one at a time).
    func showPairing(_ result: Result<CantripPairingLink, CantripPairingLinkError>) {
        closeAll()
        remote?.modelSettingsSession = nil
        remote?.inputRequestsSession = nil
        remote?.showingMacAccess = false
        DispatchQueue.main.async { self.pairing = CantripPairingPrompt(result: result) }
    }
}

enum MacHomeSheet: String, Identifiable {
    case usage, memory, builds, mascot, maintenance, voiceMode, queue, backgroundTasks

    var id: String { rawValue }
}
