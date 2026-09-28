import SwiftUI

@main
struct HermesApp: App {
    @UIApplicationDelegateAdaptor(AgentGatewayAppDelegate.self) private var appDelegate
    @ObservedObject private var notifications = CantripNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = HermesEnv()
    // Held, not observed: re-rendering the whole scene on every Cantrip poll
    // snaps open menus back to the top. ChatView observes the model itself.
    @State private var remoteModel = CantripRemoteModel(liveStatus: .shared)

    var body: some Scene {
        WindowGroup {
            ChatView(env: env, remote: remoteModel)
            .preferredColorScheme(.dark)
            .onAppear {
                remoteModel.setAppActive(scenePhase == .active)
                openNotification()
            }
            .onChange(of: scenePhase) { _, phase in
                remoteModel.setAppActive(phase == .active)
                if phase == .active { openNotification() }
            }
            .onChange(of: notifications.pendingTarget) { _, _ in openNotification() }
            .onChange(of: notifications.deviceToken) { _, _ in remoteModel.refreshCompletionNotificationRegistration(force: true) }
            .onOpenURL { url in
                guard let target = CantripDeepLink.parse(url) else { return }
                env.select(.cantrip)
                Task { await remoteModel.openLiveStatusLink(target) }
            }
        }
    }

    private func openNotification() {
        guard scenePhase == .active, let target = notifications.pendingTarget else { return }
        notifications.consumeTarget()
        Task {
            env.select(.cantrip)
            await remoteModel.openCompletionNotification(target)
        }
    }
}
