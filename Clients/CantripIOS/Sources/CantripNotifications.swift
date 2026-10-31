import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
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
    /// A Cantrip Home background run asked; it is answered in Home, never opened as a tab.
    var isHomeRun = false

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
        isHomeRun = value["home"] == "run"
    }
}

/// Ties the alert installation ID to the device that created it. A device transfer or backup
/// restore copies UserDefaults (the ID, alert subscriptions, saved servers) but not
/// this-device-only Keychain items (the marker, server credentials). Reusing a copied ID would
/// let this device replace or remove the original device's registrations on the Mac.
struct CantripInstallationBinding {
    var readMarker: () throws -> String?
    var writeMarker: (String) throws -> Void
    var credentials: ServerCredentialStore

    static var keychain: Self {
        let account = "cantrip.notifications.installation-marker"
        return Self(readMarker: { try Keychain.loadCredential(account) },
                    writeMarker: { try Keychain.saveCredential($0, for: account) },
                    credentials: .keychain)
    }
}

@MainActor
final class CantripNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    #if os(iOS)
    static let shared = CantripNotifications(installation: .keychain)
    #else
    static let shared = CantripNotifications()
    #endif
    @Published private(set) var deviceToken: String?
    @Published private(set) var registrationError: String?
    @Published private(set) var pendingTarget: CantripNotificationTarget?
    /// The last alert shown while the app was open (the tab on screen then counts it as seen).
    @Published private(set) var presentedTarget: CantripNotificationTarget?
    @Published private(set) var enabledServers: [String: String]
    @Published private(set) var pendingServers: [String: String]
    private let defaults: UserDefaults
    private let enabledKey = "cantrip.notifications.enabled-servers"
    private let pendingKey = "cantrip.notifications.pending-servers"
    private var tokenWaiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private let authorize: () async throws -> Bool
    private let requestRegistration: @MainActor () -> Void
    let installationID: UUID
    private static let installationKey = "cantrip.notifications.installation-id"
    private static let boundKey = "cantrip.notifications.installation-bound"

    init(defaults: UserDefaults = .standard,
         installation: CantripInstallationBinding? = nil,
         authorize: @escaping () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
         },
         requestRegistration: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.defaults = defaults
        self.authorize = authorize
        self.requestRegistration = requestRegistration
        var enabled = defaults.dictionary(forKey: enabledKey) as? [String: String] ?? [:]
        var pending = defaults.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
        let saved = defaults.string(forKey: Self.installationKey).flatMap(UUID.init(uuidString:))
        let resolved = installation.flatMap { Self.resolveInstallation(saved: saved, defaults: defaults, binding: $0) }
        installationID = resolved?.id ?? saved ?? UUID()
        defaults.set(installationID.uuidString, forKey: Self.installationKey)
        if resolved?.copied == true, !enabled.isEmpty {
            // Nothing is registered under the new ID yet: keep each alert as a pending
            // registration, which completes once that server is re-paired on this device.
            pending.merge(enabled) { current, _ in current }
            enabled = [:]
            defaults.set(pending, forKey: pendingKey)
            defaults.set(enabled, forKey: enabledKey)
        }
        enabledServers = enabled
        pendingServers = pending
        super.init()
    }

    /// The installation ID to use, and whether this install's settings were copied from another
    /// device. Nil while the Keychain can't be read (e.g. before first unlock): the saved ID stays
    /// and the check runs again next launch.
    private static func resolveInstallation(
        saved: UUID?, defaults: UserDefaults, binding: CantripInstallationBinding
    ) -> (id: UUID, copied: Bool)? {
        do {
            let marker = try binding.readMarker().flatMap(UUID.init(uuidString:))
            let copied: Bool
            switch (saved, marker) {
            case (nil, _):
                copied = false
            case let (saved?, marker?):
                copied = saved != marker
            case (.some, nil):
                // Saved by a build without the marker: the device that saved the server list holds
                // every server's credential, while a copy arrives without them.
                let profiles = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: binding.credentials)
                copied = try defaults.bool(forKey: boundKey)
                    || profiles.servers.contains { try profiles.storedCredential(for: $0) == nil }
            }
            let id = copied ? UUID() : saved ?? marker ?? UUID()
            if marker != id {
                do { try binding.writeMarker(id.uuidString) } catch {
                    defaults.removeObject(forKey: boundKey)
                    return (id, copied)
                }
            }
            defaults.set(true, forKey: boundKey)
            return (id, copied)
        } catch {
            return nil
        }
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
        guard !enabledServers.isEmpty || !pendingServers.isEmpty else { return }
        UIApplication.shared.registerForRemoteNotifications()
        // Alerts turned on before badges asked only for alerts and sounds. Asking again doesn't
        // prompt once the person has answered; it adds the Badges switch in iOS Settings.
        Task { _ = try? await authorize() }
    }

    /// Opening the app clears its icon badge at once, without waiting for the Mac; pushes after
    /// this count only newer alerts (`CantripRemoteModel.reportAppOpened`).
    func clearBadge() {
        #if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(0)
        #endif
    }

    /// Clears a tab's alerts from Notification Center once it's opened.
    func removeDelivered(sessionID: String, serverID: UUID) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications.filter {
                guard let target = CantripNotificationTarget(userInfo: $0.request.content.userInfo) else { return false }
                return target.serverID == serverID && target.sessionID.uuidString == sessionID.uppercased()
            }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func isEnabled(serverID: UUID?) -> Bool {
        serverID.map { enabledServers[$0.uuidString] != nil } ?? false
    }

    func isPending(serverID: UUID?) -> Bool {
        serverID.map { pendingServers[$0.uuidString] != nil } ?? false
    }

    func hasSubscription(serverID: UUID?) -> Bool { isEnabled(serverID: serverID) || isPending(serverID: serverID) }

    /// Clears a removed server's alert state on this device only; nothing is sent to its Mac.
    func forget(serverID: UUID) { save(serverID: serverID, fingerprint: nil) }

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
            throw ServerConfigurationError(message: "Notifications are disabled for Cantrip Agent. Enable them in iOS Settings.")
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

    #if DEBUG
    /// UI tests open a push exactly as a tap would, without APNs or enabled alerts.
    func simulateTapForUITest(_ userInfo: [AnyHashable: Any]) {
        pendingTarget = CantripNotificationTarget(userInfo: userInfo)
    }
    #endif

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
            presentedTarget = target
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

#if os(iOS)
final class AgentGatewayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CantripNotifications.shared.install()
        CantripLiveStatusController.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CantripNotifications.shared.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CantripNotifications.shared.failed(error)
    }
}
#endif

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
        CantripLiveStatusSettingsSection()
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
