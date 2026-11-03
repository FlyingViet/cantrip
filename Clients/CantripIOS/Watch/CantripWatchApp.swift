import SwiftUI

@main
struct CantripWatchApp: App {
    @StateObject private var model = WatchVoiceModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchPhoneLink.shared.activate()
        #if DEBUG
        if let qa = WatchQA.current, qa.talkIntent {
            Task { @MainActor in
                if qa.talkIntentAfter > 0 { try? await Task.sleep(for: .seconds(qa.talkIntentAfter)) }
                _ = try? await TalkToCantripIntent().perform()
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.scenePhaseChanged(phase)
                }
                // "Talk to Cantrip" ran while the app was already open. @Published sends before it
                // stores the value, so take the request on the next turn of the main loop.
                .onReceive(WatchListenRequest.shared.$pending) { pending in
                    if pending { DispatchQueue.main.async { model.consumeListenRequest() } }
                }
        }
    }
}

extension Color {
    static let cantripAccent = Color(red: 0.58, green: 0.45, blue: 1.0)
}
