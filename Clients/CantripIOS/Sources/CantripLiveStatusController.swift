import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct CantripLiveStatusSubscriptionStatus: Decodable {
    let configured: Bool
    let message: String
    var supportsWidgetPush: Bool? = nil
    var supportsLiveActivities: Bool? = nil
}

/// Keeps the Home Screen widget and the tabs Live Activity in step with the Mac:
/// shares the pairing with the widget, caches the latest tab status, and hands
/// the Mac the push tokens it uses to refresh both.
@MainActor
final class CantripLiveStatusController: ObservableObject {
    static let shared = CantripLiveStatusController()
    static let enabledKey = "cantrip.live-activities.enabled"

    @Published var liveActivitiesEnabled: Bool {
        didSet {
            guard liveActivitiesEnabled != oldValue else { return }
            defaults.set(liveActivitiesEnabled, forKey: Self.enabledKey)
            if !liveActivitiesEnabled { endAll(immediately: true) }
            scheduleUpload(force: true)
        }
    }
    @Published private(set) var status: String?

    /// POSTs a merge body to /api/v1/live-status/subscription over the paired route.
    var uploader: ((Data) async throws -> CantripLiveStatusSubscriptionStatus)?
    /// GET /api/v1/live-status over the paired route.
    var fetcher: (() async throws -> CantripLiveStatusSnapshot)?

    private let defaults: UserDefaults
    private var config: CantripLiveStatusConfig?
    private var startToken: String?
    private var activityToken: String?
    private var activityID: String?
    private var observedActivities: Set<String> = []
    private var observing = false
    private var uploadedSignature: String?
    private var uploadTask: Task<Void, Never>?
    private var lastUploadAttempt: Date?
    private var fetchTask: Task<Void, Never>?
    private var lastFetch: Date?
    private var lastCacheWrite: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveActivitiesEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        config = CantripSharedStore.loadConfig()
    }

    /// Call once at launch; also runs when iOS wakes the app for a pushed Live Activity.
    func start() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            for await data in Activity<CantripTabsAttributes>.pushToStartTokenUpdates {
                self?.startToken = Self.hex(data)
                self?.scheduleUpload(force: true)
            }
        }
        Task { [weak self] in
            for await activity in Activity<CantripTabsAttributes>.activityUpdates {
                self?.observe(activity)
            }
        }
        for activity in Activity<CantripTabsAttributes>.activities { observe(activity) }
    }

    /// Mirrors the selected pairing for the widget; nil clears it.
    func pairingChanged(serverID: UUID?, token: String?, baseURL: URL?, tailscaleOnly: Bool, installationID: UUID) {
        var next: CantripLiveStatusConfig?
        if let serverID, let token {
            next = CantripLiveStatusConfig(
                serverID: serverID.uuidString, token: token, baseURL: baseURL?.absoluteString,
                installationID: installationID.uuidString,
                environment: Bundle.main.object(forInfoDictionaryKey: "CantripPushEnvironment") as? String)
        }
        guard next != config else { return }
        // Only a real switch or unpairing ends activities: an unreadable Keychain
        // before first unlock also reads as "no pairing".
        let switched = config != nil && next?.serverID != config?.serverID
        config = next
        CantripSharedStore.saveConfig(next)
        uploadedSignature = nil
        if switched {
            CantripSharedStore.saveCache(nil)
            lastFetch = nil
            endAll(immediately: true)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "CantripTabs")
        scheduleUpload(force: true)
    }

    /// Called after each successful tab-list poll while the app is open.
    func refreshIfDue(anyStreaming: Bool) {
        scheduleUpload()
        guard fetchTask == nil, let fetcher, config != nil else { return }
        let interval: TimeInterval = anyStreaming ? 10 : 30
        guard lastFetch.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
        lastFetch = Date()
        fetchTask = Task { [weak self] in
            defer { self?.fetchTask = nil }
            do {
                let snapshot = try await fetcher()
                self?.apply(snapshot)
            } catch CantripRemoteError.http(404, _) {
                self?.status = "Update Cantrip on your Mac to use the widget and Live Activity."
            } catch {}
        }
    }

    func apply(_ snapshot: CantripLiveStatusSnapshot, now: Date = Date()) {
        guard let serverID = config?.serverID else { return }
        if status?.hasPrefix("Update Cantrip") == true { status = nil }
        let previous = CantripSharedStore.loadCache()
        let changed = previous?.serverID != serverID || !Self.sameContent(previous?.snapshot, snapshot)
        if changed || lastCacheWrite.map({ now.timeIntervalSince($0) > 300 }) ?? true {
            CantripSharedStore.saveCache(CantripLiveStatusCache(snapshot: snapshot, fetchedAt: now, serverID: serverID))
            lastCacheWrite = now
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: "CantripTabs") }
        }
        reconcileActivities(with: snapshot, now: now)
    }

    /// Ignores `generatedAt`, which changes on every read.
    static func sameContent(_ lhs: CantripLiveStatusSnapshot?, _ rhs: CantripLiveStatusSnapshot) -> Bool {
        guard var lhs else { return false }
        lhs.generatedAt = rhs.generatedAt
        return lhs == rhs
    }

    /// The fields the Mac merges into this installation's subscription.
    func subscriptionFields(activitiesAllowed: Bool) -> [String: Any]? {
        guard let config, let environment = config.environment,
              ["development", "production"].contains(environment) else { return nil }
        let enabled = liveActivitiesEnabled && activitiesAllowed
        return [
            "installationID": config.installationID, "serverID": config.serverID, "environment": environment,
            "liveActivities": enabled,
            "startToken": enabled ? startToken ?? "" : "",
            "activityToken": enabled ? activityToken ?? "" : "",
            "activityID": enabled ? activityID ?? "" : "",
            "widgetToken": CantripSharedStore.loadWidgetToken() ?? "",
        ]
    }

    // MARK: - Private

    private func observe(_ activity: Activity<CantripTabsAttributes>) {
        guard observedActivities.insert(activity.id).inserted else { return }
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self, activity.activityState == .active || activity.activityState == .stale else { continue }
                activityToken = Self.hex(data)
                activityID = activity.id
                scheduleUpload(force: true)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, activityID == activity.id else { continue }
                activityToken = nil
                activityID = nil
                scheduleUpload(force: true)
            }
        }
    }

    private func scheduleUpload(force: Bool = false) {
        guard let fields = subscriptionFields(activitiesAllowed: ActivityAuthorizationInfo().areActivitiesEnabled),
              let uploader else { return }
        let signature = Self.signature(fields)
        guard signature != uploadedSignature, uploadTask == nil else { return }
        if !force, let last = lastUploadAttempt, Date().timeIntervalSince(last) < 20 { return }
        lastUploadAttempt = Date()
        uploadTask = Task { [weak self] in
            var uploaded = false
            do {
                let body = try JSONSerialization.data(withJSONObject: fields)
                let result = try await uploader(body)
                self?.uploadedSignature = signature
                self?.status = result.configured ? nil : result.message
                uploaded = true
            } catch CantripRemoteError.http(404, _) {
                self?.status = "Update Cantrip on your Mac to use the widget and Live Activity."
            } catch {}
            self?.uploadTask = nil
            // A token that changed during the upload goes next; failures wait for the next poll.
            if uploaded { self?.scheduleUpload(force: true) }
        }
    }

    private func reconcileActivities(with snapshot: CantripLiveStatusSnapshot, now: Date) {
        let activities = Activity<CantripTabsAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        guard liveActivitiesEnabled else {
            endAll(immediately: true)
            return
        }
        // One activity for all tabs: keep the one the Mac updates.
        let keep = activities.first { $0.id == activityID } ?? activities.first
        for extra in activities where extra.id != keep?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        let content = ActivityContent(state: CantripTabsAttributes.ContentState(snapshot),
                                      staleDate: now.addingTimeInterval(3_600))
        guard let current = keep else {
            // The Mac starts it with a push; while the app is open, start it here so it
            // doesn't wait for that push. The Mac then updates it with its token.
            guard snapshot.isActive, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            _ = try? Activity.request(attributes: CantripTabsAttributes(hostName: snapshot.hostName),
                                      content: content, pushType: .token)
            return
        }
        let shown = current.content.state
        // Only step in when the Mac hasn't (no Apple push configured, or a missed push).
        let differs = shown.tabs != content.state.tabs || shown.running != content.state.running
            || shown.needsInput != content.state.needsInput || shown.total != content.state.total
        if !snapshot.isActive {
            // The Mac ends it 45 s after the last tab stops.
            if now.timeIntervalSince1970 - shown.updatedAt > 120 {
                Task { await current.end(content, dismissalPolicy: .after(now.addingTimeInterval(900))) }
            }
        } else if differs, snapshot.generatedAt - shown.updatedAt > 30 {
            Task { await current.update(content) }
        }
    }

    private func endAll(immediately: Bool) {
        for activity in Activity<CantripTabsAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: immediately ? .immediate : .default) }
        }
    }

    private static func signature(_ fields: [String: Any]) -> String {
        fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: "&")
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

struct CantripLiveStatusSettingsSection: View {
    @ObservedObject private var controller = CantripLiveStatusController.shared

    var body: some View {
        Section {
            Toggle(isOn: $controller.liveActivitiesEnabled) {
                Label("Live Activity while tabs run", systemImage: "dot.radiowaves.left.and.right")
            }
            if let status = controller.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Widget and Live Activity")
        } footer: {
            Text("Add the Cantrip Tabs widget from your Home Screen in medium or large size to see which tabs are running, need input, or finished. Tap a tab to open it. The Live Activity shows running tabs on the Lock Screen and in the Dynamic Island. The Mac refreshes both with Apple push, set up the same way as alerts. Private tabs are never shown.")
        }
    }
}
