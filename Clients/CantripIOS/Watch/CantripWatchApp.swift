import SwiftUI

@main
struct CantripWatchApp: App {
    @StateObject private var model = WatchVoiceModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchPhoneLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.scenePhaseChanged(phase)
                }
        }
    }
}

extension Color {
    static let cantripAccent = Color(red: 0.58, green: 0.45, blue: 1.0)
}
