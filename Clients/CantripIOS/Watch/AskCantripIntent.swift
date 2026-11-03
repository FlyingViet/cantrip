import AppIntents
import Foundation

/// "Ask Cantrip" from Siri or Shortcuts on the watch: sends the request to Cantrip Home and
/// answers with its reply.
struct AskCantripIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Cantrip"
    // App Store validation (ITMS-90626) rejects intent metadata naming Apple products ("Mac", "iPhone", "Watch"...).
    static let description = IntentDescription("Send a request to Cantrip Home and hear its reply.")

    @Parameter(title: "Request", requestValueDialog: "What should I ask Cantrip?")
    var request: String

    /// Siri waits about this long for the answer.
    private static let answerWait: TimeInterval = 25

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .result(dialog: "\(CantripWatchError.noSpeech.errorDescription ?? "")")
        }
        do {
            let deadline = Date().addingTimeInterval(Self.answerWait)
            let client = try CantripWatchClient.current()
            let turn = try await client.follow(try await client.startTurn(text: text), until: deadline)
            guard turn.isFinished else { throw CantripWatchError.stillWorking }
            if turn.status == .failed {
                throw CantripWatchError.failed(turn.error ?? "Cantrip Home couldn't answer that. Try again.")
            }
            let answer = turn.speakableText
            return .result(dialog: "\(answer.isEmpty ? "Done." : answer)")
        } catch let error as CantripWatchError {
            return .result(dialog: "\(error.errorDescription ?? "")")
        }
    }
}

struct CantripWatchShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToCantripIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start talking to \(.applicationName)",
            ],
            shortTitle: "Talk to Cantrip",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AskCantripIntent(),
            phrases: [
                "Ask \(.applicationName)",
            ],
            shortTitle: "Ask Cantrip",
            systemImageName: "waveform"
        )
    }
}
