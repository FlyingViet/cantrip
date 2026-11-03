import AppIntents
import Foundation

/// "Talk to Cantrip": opens the app already listening, like tapping the mic. The app sends what
/// you say to Cantrip Home and speaks the reply when it's ready, however long Home takes
/// (`WatchVoiceModel.answerLimit`), instead of Siri's short wait (`AskCantripIntent`). On Apple
/// Watch Ultra the Action button runs it through a shortcut (Action Button › Shortcut).
struct TalkToCantripIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Cantrip"
    // App Store validation (ITMS-90626) rejects intent metadata naming Apple products ("Mac", "iPhone", "Watch"...).
    static let description = IntentDescription("Open Cantrip and start listening. Cantrip Home's reply is spoken when it's ready.")
    /// The app has to be in front to record and speak.
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchListenRequest.shared.request()
        return .result()
    }
}

/// A "Talk to Cantrip" run waiting for the app to start listening: the intent can run before the
/// app is active, so the model takes it once it is (`WatchVoiceModel.consumeListenRequest`).
@MainActor
final class WatchListenRequest: ObservableObject {
    static let shared = WatchListenRequest()

    @Published private(set) var pending = false

    func request() {
        WatchVoiceModel.log.info("Talk to Cantrip requested")
        pending = true
    }

    /// True once per request.
    func take() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}
