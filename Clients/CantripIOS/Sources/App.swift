import SwiftUI

@main
struct HermesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = HermesEnv()
    @StateObject private var remoteModel = CantripRemoteModel()

    var body: some Scene {
        WindowGroup {
            ChatView(env: env, remote: remoteModel)
            .preferredColorScheme(.dark)
            .onAppear {
                remoteModel.setAppActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                remoteModel.setAppActive(phase == .active)
            }
        }
    }
}
