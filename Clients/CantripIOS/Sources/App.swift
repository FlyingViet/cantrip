import SwiftUI

@main
struct HermesApp: App {
    @UIApplicationDelegateAdaptor(AgentGatewayAppDelegate.self) private var appDelegate
    @ObservedObject private var notifications = CantripNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var env = HermesEnv()
    @StateObject private var remoteModel = CantripRemoteModel()

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
