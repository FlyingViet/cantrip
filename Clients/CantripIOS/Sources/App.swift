import SwiftUI

@main
struct HermesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = HermesEnv()
    @StateObject private var remoteModel = CantripRemoteModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                CantripRemoteView()
                    .tabItem {
                        Label {
                            Text("Remote")
                        } icon: {
                            Image(uiImage: CantripRemoteTabIcon.image(
                                connected: remoteModel.isConnected
                            ))
                            .renderingMode(.original)
                        }
                        .accessibilityLabel(
                            remoteModel.isConnected
                                ? "Remote, Connected"
                                : "Remote, Disconnected"
                        )
                    }

                ChatView(env: env)
                    .tabItem {
                        Label("Hermes", systemImage: "brain")
                    }
            }
            .environmentObject(remoteModel)
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
