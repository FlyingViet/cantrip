import SwiftUI

@main
struct HermesApp: App {
    @StateObject private var env = HermesEnv()

    var body: some Scene {
        WindowGroup {
            ChatView(env: env)
                .preferredColorScheme(.dark)
        }
    }
}
