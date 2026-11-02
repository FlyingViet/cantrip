import AppIntents
import SwiftUI

/// Cross-launch signal from an App Intent (Shortcuts / Action Button) to the UI.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    /// Set by the "Talk to Hermes" intent; the chat view consumes it to open
    /// full-screen voice mode (which listens, sends, and speaks the reply).
    @Published var startVoiceMode = false
    private init() {}
}

/// "Talk to Hermes" — exposed to Shortcuts and assignable to the Action Button.
/// Launches the app straight into voice mode: it listens, sends your turn, and
/// stays active through the spoken reply.
struct TalkToHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Hermes"
    static var description = IntentDescription("Open Hermes in voice mode and start listening.")
    /// Bring the app to the foreground so the mic + voice UI can run.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.startVoiceMode = true
        return .result()
    }
}

/// Auto-registers the intent as an App Shortcut (appears in the Shortcuts app +
/// is selectable for the Action Button; also works with "Hey Siri, Talk to Hermes").
struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToHermesIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName) voice",
                "Ask \(.applicationName)",
            ],
            shortTitle: "Talk to Hermes",
            systemImageName: "waveform"
        )
    }
}
