import SwiftUI

@main
struct CantripGatewayMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var env = HermesEnv()
    @StateObject private var voice = VoiceController()
    @StateObject private var navigation = MacHomeNavigation()
    @StateObject private var directLocal = DirectLocalChat()
    // Held, not observed (as on iOS): re-rendering the whole scene on every Cantrip poll
    // would rebuild open menus. Views observe the model themselves. No live-status
    // controller: widgets and Live Activities don't exist on the Mac.
    #if DEBUG
    @State private var remote = CantripRemoteModel(
        authorizeSensitiveAction: CantripUITestFixtures.authorizeSensitiveAction
    )
    #else
    @State private var remote = CantripRemoteModel()
    #endif

    init() {
        // `--direct-local-check` runs from Terminal and exits before any window opens.
        if let status = DirectLocalCheck.runIfRequested(CommandLine.arguments) { exit(status) }
    }

    var body: some Scene {
        Window("Cantrip Home", id: MacHomeNavigation.windowID) {
            MacHomeWindow(env: env, remote: remote, voice: voice, navigation: navigation, directLocal: directLocal)
                // Cantrip's look is dark on every client (the iOS app sets the same).
                .preferredColorScheme(.dark)
                #if DEBUG
                // Same launch arguments as the iOS UI tests: pair with a local fixture host.
                .task { await CantripUITestFixtures.pairRemoteIfRequested(remote, env: env) }
                .task { await DirectLocalQA.run(chat: directLocal, navigation: navigation) }
                #endif
        }
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            MacHomeCommands(remote: remote, navigation: navigation)
        }

        Settings {
            MacSettingsView(env: env, remote: remote, voice: voice)
                .preferredColorScheme(.dark)
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Home is one conversation in one window; quitting stops polling the Mac host.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// MCP servers started for the local model end with the app.
    func applicationWillTerminate(_ notification: Notification) {
        DirectLocalMCPConnection.terminateAll()
    }
}
