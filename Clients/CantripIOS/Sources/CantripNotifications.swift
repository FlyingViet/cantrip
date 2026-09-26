import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct CantripPushStatus: Codable {
    let configured: Bool
    let message: String
    let lastDeliveryError: String?
    var supportsInputAlerts: Bool? = nil
}

struct CantripNotificationTarget: Equatable {
    let eventID: UUID
    let serverID: UUID
    let sessionID: UUID
    let fingerprint: String
    var kind: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["cantrip"] as? [String: String],
              let eventID = value["eventID"].flatMap(UUID.init(uuidString:)),
              let serverID = value["serverID"].flatMap(UUID.init(uuidString:)),
              let sessionID = value["sessionID"].flatMap(UUID.init(uuidString:)),
              let fingerprint = value["fingerprint"], !fingerprint.isEmpty else { return nil }
        self.eventID = eventID
        self.serverID = serverID
        self.sessionID = sessionID
        self.fingerprint = fingerprint
        kind = value["kind"]
    }
}

@MainActor
final class CantripNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = CantripNotifications()
    @Published private(set) var deviceToken: String?
    @Published private(set) var registrationError: String?
    @Published private(set) var pendingTarget: CantripNotificationTarget?
    @Published private(set) var enabledServers: [String: String]
    @Published private(set) var pendingServers: [String: String]
    private let defaults: UserDefaults
    private let enabledKey = "cantrip.notifications.enabled-servers"
    private let pendingKey = "cantrip.notifications.pending-servers"
    private var tokenWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private let authorize: () async throws -> Bool
    private let requestRegistration: @MainActor () -> Void
    let installationID: UUID

    init(defaults: UserDefaults = .standard,
         authorize: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         },
         requestRegistration: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.defaults = defaults
        self.authorize = authorize
        self.requestRegistration = requestRegistration
        enabledServers = defaults.dictionary(forKey: enabledKey) as? [String: String] ?? [:]
        pendingServers = defaults.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
        let id = defaults.string(forKey: "cantrip.notifications.installation-id").flatMap(UUID.init(uuidString:)) ?? UUID()
        installationID = id
        defaults.set(id.uuidString, forKey: "cantrip.notifications.installation-id")
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
        if !enabledServers.isEmpty || !pendingServers.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
    }

    func isEnabled(serverID: UUID?) -> Bool {
        serverID.map { enabledServers[$0.uuidString] != nil } ?? false
    }

    func isPending(serverID: UUID?) -> Bool {
        serverID.map { pendingServers[$0.uuidString] != nil } ?? false
    }

    func hasSubscription(serverID: UUID?) -> Bool { isEnabled(serverID: serverID) || isPending(serverID: serverID) }

    func prepareRegistration(serverID: UUID, fingerprint: String) {
        pendingServers[serverID.uuidString] = fingerprint
        defaults.set(pendingServers, forKey: pendingKey)
    }

    func save(serverID: UUID, fingerprint: String?) {
        pendingServers.removeValue(forKey: serverID.uuidString)
        defaults.set(pendingServers, forKey: pendingKey)
        enabledServers[serverID.uuidString] = fingerprint
        defaults.set(enabledServers, forKey: enabledKey)
        if fingerprint == nil {
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let ids = notifications.filter {
                    CantripNotificationTarget(userInfo: $0.request.content.userInfo)?.serverID == serverID
                }.map(\.request.identifier)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func register() async throws -> String {
        let granted = try await authorize()
        guard granted else {
            throw ServerConfigurationError(message: "Notifications are disabled for AgentGateway. Enable them in iOS Settings.")
        }
        if let deviceToken { return deviceToken }
        registrationError = nil
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            tokenWaiters[id] = continuation
            requestRegistration()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let waiting = tokenWaiters.removeValue(forKey: id) else { return }
                let message = "Apple push registration timed out. Check internet access and use a signed build with Push Notifications enabled."
                registrationError = message
                waiting.resume(throwing: ServerConfigurationError(message: message))
            }
        }
    }

    func registered(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        registrationError = nil
        let waiters = Array(tokenWaiters.values)
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: token) }
    }

    func failed(_ error: Error) {
        let message = "Apple push registration failed: \(error.localizedDescription)"
        registrationError = message
        let waiters = Array(tokenWaiters.values)
        tokenWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: ServerConfigurationError(message: message)) }
    }

    func accepts(_ target: CantripNotificationTarget) -> Bool {
        enabledServers[target.serverID.uuidString] == target.fingerprint
            || pendingServers[target.serverID.uuidString] == target.fingerprint
    }

    func consumeTarget() { pendingTarget = nil }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let target = CantripNotificationTarget(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            guard let target, accepts(target) else { completionHandler([]); return }
            let key = "cantrip.notifications.presented-events"
            let id = "\(target.serverID)/\(target.eventID)"
            let seen = defaults.stringArray(forKey: key) ?? []
            guard !seen.contains(id) else { completionHandler([]); return }
            defaults.set(Array((seen + [id]).suffix(256)), forKey: key)
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = CantripNotificationTarget(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let target, accepts(target) { pendingTarget = target }
            completionHandler()
        }
    }
}

final class AgentGatewayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CantripNotifications.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CantripNotifications.shared.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CantripNotifications.shared.failed(error)
    }
}

struct CantripNotificationSettingsSection: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var notifications = CantripNotifications.shared
    @State private var busy = false
    @State private var status: String?
    private var visibleStatus: String? { status ?? remote.notificationStatus ?? notifications.registrationError }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { notifications.isEnabled(serverID: remote.selectedServerID) },
                set: update
            )) {
                Label("Completion and input-needed alerts", systemImage: "bell.badge")
            }
            .disabled(busy || remote.isUpdatingNotifications || remote.selectedServerID == nil)
            if busy { ProgressView("Updating notifications...") }
            if notifications.isPending(serverID: remote.selectedServerID), !busy {
                Text("Registration is not confirmed. Alerts may already be active on the Mac. Retry enabling, or cancel the pending registration.")
                    .font(.footnote)
                Button("Cancel pending alert registration") { update(false) }
                    .disabled(remote.isUpdatingNotifications)
            }
            if let message = visibleStatus {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Check notification setup") {
                busy = true
                Task {
                    do {
                        let result = try await remote.completionNotificationStatus()
                        status = result.lastDeliveryError ?? result.message
                    } catch { status = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy || remote.isUpdatingNotifications || remote.selectedServerID == nil)
            Button("iOS notification settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Cantrip alerts")
        } footer: {
            Text("Completion alerts include the tab name and final-answer preview. Input-needed alerts are generic: no command, password, question, login code or tab title goes through Apple push. Open the app to review and respond. Alerts work while the phone is locked; the Mac must stay online. Private tabs are excluded. Input alerts require an updated Mac host. Connect to this Mac to turn alerts off.")
        }
        .onChange(of: remote.selectedServerID) { _, _ in status = nil }
        .onChange(of: visibleStatus) { _, value in
            if let value { UIAccessibility.post(notification: .announcement, argument: value) }
        }
    }

    private func update(_ enable: Bool) {
        busy = true
        Task {
            do {
                try await remote.setCompletionNotifications(enabled: enable)
                status = enable ? "Cantrip alerts are enabled for this Mac." : "Cantrip alerts are off."
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}
