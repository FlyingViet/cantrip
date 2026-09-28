import CryptoKit
import Foundation

struct LiveStatusInput: Equatable {
    let title: String
    /// `InputRequestSnapshot.Kind` raw value: approval, question, secret, login or localAction.
    var kind: String? = nil
}

enum LiveStatusTabState: String, Codable, Equatable {
    case input, running, done, failed, stopped, idle
}

struct LiveStatusRunOutcome: Codable, Equatable {
    let status: LiveStatusTabState
    let finishedAt: Date
}

struct LiveStatusSession: Equatable {
    let id: UUID
    let title: String
    var customTitle: String? = nil
    var isPrivate = false
    var isLocalPrivate = false
    var isStreaming = false
    var statusText: String? = nil
    var currentActivityTitle: String? = nil
    var queued = 0
    var pendingInputs: [LiveStatusInput] = []
    var currentRunStartedAt: Date? = nil
    var lastRunOutcome: LiveStatusRunOutcome? = nil
    var activeSubagents = 0

    init(id: UUID, title: String, customTitle: String? = nil, isPrivate: Bool = false,
         isLocalPrivate: Bool = false, isStreaming: Bool = false, statusText: String? = nil,
         currentActivityTitle: String? = nil, queued: Int = 0, pendingInputs: [LiveStatusInput] = [],
         currentRunStartedAt: Date? = nil, lastRunOutcome: LiveStatusRunOutcome? = nil,
         activeSubagents: Int = 0) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.isPrivate = isPrivate
        self.isLocalPrivate = isLocalPrivate
        self.isStreaming = isStreaming
        self.statusText = statusText
        self.currentActivityTitle = currentActivityTitle
        self.queued = queued
        self.pendingInputs = pendingInputs
        self.currentRunStartedAt = currentRunStartedAt
        self.lastRunOutcome = lastRunOutcome
        self.activeSubagents = activeSubagents
    }
}

struct LiveStatusTab: Codable, Equatable {
    let id: String
    let title: String
    let state: LiveStatusTabState
    let startedAt: Double?
    let finishedAt: Double?
    let detail: String?
    let queued: Int
    let subagents: Int
    /// What the first pending request asks for (input tabs only); older apps ignore it.
    let inputKind: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, state, startedAt, finishedAt, detail, queued, subagents, inputKind
    }

    init(id: String, title: String, state: LiveStatusTabState, startedAt: Double?,
         finishedAt: Double?, detail: String?, queued: Int, subagents: Int, inputKind: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detail = detail
        self.queued = queued
        self.subagents = subagents
        self.inputKind = inputKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        state = try container.decode(LiveStatusTabState.self, forKey: .state)
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Double.self, forKey: .finishedAt)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        queued = try container.decode(Int.self, forKey: .queued)
        subagents = try container.decode(Int.self, forKey: .subagents)
        inputKind = try container.decodeIfPresent(String.self, forKey: .inputKind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(state, forKey: .state)
        if let startedAt { try container.encode(startedAt, forKey: .startedAt) }
        else { try container.encodeNil(forKey: .startedAt) }
        if let finishedAt { try container.encode(finishedAt, forKey: .finishedAt) }
        else { try container.encodeNil(forKey: .finishedAt) }
        if let detail { try container.encode(detail, forKey: .detail) }
        else { try container.encodeNil(forKey: .detail) }
        try container.encode(queued, forKey: .queued)
        try container.encode(subagents, forKey: .subagents)
        try container.encodeIfPresent(inputKind, forKey: .inputKind)
    }
}

struct LiveStatusSnapshot: Codable, Equatable {
    let version: Int
    let generatedAt: Double
    let hostName: String
    let running: Int
    let needsInput: Int
    let total: Int
    let tabs: [LiveStatusTab]

    init(version: Int = 1, generatedAt: Double, hostName: String, running: Int,
         needsInput: Int, total: Int, tabs: [LiveStatusTab]) {
        self.version = version
        self.generatedAt = generatedAt
        self.hostName = hostName
        self.running = running
        self.needsInput = needsInput
        self.total = total
        self.tabs = tabs
    }

    static func build(from sessions: [LiveStatusSession], now: Date = Date(),
                      hostName: String = Host.current().localizedName ?? "Cantrip") -> LiveStatusSnapshot {
        struct RankedTab {
            let tab: LiveStatusTab
            let order: Int
        }

        let eligible = sessions.enumerated().compactMap { offset, session -> RankedTab? in
            guard !session.isPrivate, !session.isLocalPrivate else { return nil }
            let state: LiveStatusTabState
            let startedAt: Double?
            let finishedAt: Double?
            let detail: String?
            var inputKind: String?
            if let input = session.pendingInputs.first {
                state = .input
                startedAt = session.currentRunStartedAt?.timeIntervalSince1970
                finishedAt = nil
                detail = Self.clipped(input.title, limit: 72)
                inputKind = input.kind
            } else if session.isStreaming {
                state = .running
                startedAt = session.currentRunStartedAt?.timeIntervalSince1970
                finishedAt = nil
                detail = Self.clipped(Self.firstNonEmpty(session.statusText, session.currentActivityTitle), limit: 72)
            } else if let outcome = session.lastRunOutcome {
                state = outcome.status
                startedAt = nil
                finishedAt = outcome.finishedAt.timeIntervalSince1970
                detail = nil
            } else {
                state = .idle
                startedAt = nil
                finishedAt = nil
                detail = nil
            }
            let rawTitle = Self.firstNonEmpty(session.customTitle, session.title) ?? "Cantrip"
            return RankedTab(tab: LiveStatusTab(
                id: session.id.uuidString,
                title: Self.clipped(rawTitle, limit: 48) ?? "Cantrip",
                state: state,
                startedAt: startedAt,
                finishedAt: finishedAt,
                detail: detail,
                queued: session.queued,
                subagents: session.activeSubagents,
                inputKind: inputKind
            ), order: offset)
        }

        let sorted = eligible.sorted { left, right in
            let leftRank = Self.rank(left.tab.state)
            let rightRank = Self.rank(right.tab.state)
            if leftRank != rightRank { return leftRank < rightRank }
            switch left.tab.state {
            case .running:
                let leftStart = left.tab.startedAt ?? Double.greatestFiniteMagnitude
                let rightStart = right.tab.startedAt ?? Double.greatestFiniteMagnitude
                if leftStart != rightStart { return leftStart < rightStart }
            case .done, .failed, .stopped, .idle:
                let leftFinished = left.tab.finishedAt ?? -Double.greatestFiniteMagnitude
                let rightFinished = right.tab.finishedAt ?? -Double.greatestFiniteMagnitude
                if leftFinished != rightFinished { return leftFinished > rightFinished }
            case .input:
                break
            }
            return left.order < right.order
        }
        return LiveStatusSnapshot(
            generatedAt: now.timeIntervalSince1970,
            hostName: hostName,
            running: eligible.filter { $0.tab.state == .running }.count,
            needsInput: eligible.filter { $0.tab.state == .input }.count,
            total: eligible.count,
            tabs: Array(sorted.map(\.tab).prefix(8))
        )
    }

    static func clipped(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(0, limit - 1))) + "…"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { clipped($0, limit: Int.max) }.first
    }

    private static func rank(_ state: LiveStatusTabState) -> Int {
        switch state {
        case .input: return 0
        case .running: return 1
        case .done, .failed, .stopped, .idle: return 2
        }
    }
}

struct RemoteLiveStatusPushStatus: Codable, Equatable {
    let configured: Bool
    let message: String
    var supportsWidgetPush = true
    var supportsLiveActivities = true
}

struct RemoteLiveStatusSubscriptionUpdate: Equatable {
    enum TokenValue: Equatable { case keep, clear, set(String) }

    let installationID: UUID
    let serverID: UUID
    let environment: String
    let widgetToken: TokenValue
    let startToken: TokenValue
    let activityToken: TokenValue
    let activityID: TokenValue
    let liveActivities: Bool?

    init(json: [String: Any]) throws {
        guard let installationRaw = json["installationID"] as? String,
              let installationID = UUID(uuidString: installationRaw),
              let serverRaw = json["serverID"] as? String,
              let serverID = UUID(uuidString: serverRaw),
              let environment = json["environment"] as? String,
              ["development", "production"].contains(environment) else {
            throw RemotePushError(status: 400, message: "Invalid live status subscription.")
        }
        self.installationID = installationID
        self.serverID = serverID
        self.environment = environment
        widgetToken = try Self.tokenValue(json, key: "widgetToken", validateHex: true)
        startToken = try Self.tokenValue(json, key: "startToken", validateHex: true)
        activityToken = try Self.tokenValue(json, key: "activityToken", validateHex: true)
        activityID = try Self.tokenValue(json, key: "activityID", validateHex: false)
        if let value = json["liveActivities"] {
            guard let bool = value as? Bool else {
                throw RemotePushError(status: 400, message: "Invalid live status subscription.")
            }
            liveActivities = bool
        } else {
            liveActivities = nil
        }
    }

    private static func tokenValue(_ json: [String: Any], key: String, validateHex: Bool) throws -> TokenValue {
        guard let raw = json[key] else { return .keep }
        guard let value = raw as? String else {
            throw RemotePushError(status: 400, message: "Invalid live status subscription.")
        }
        guard !value.isEmpty else { return .clear }
        if validateHex, !RemoteLiveStatusSubscription.validToken(value) {
            throw RemotePushError(status: 400, message: "Invalid live status subscription.")
        }
        return .set(value)
    }
}

struct RemoteLiveStatusSubscriptionRemoval: Equatable {
    let installationID: UUID
    let serverID: UUID

    init(json: [String: Any]) throws {
        guard let installationRaw = json["installationID"] as? String,
              let installationID = UUID(uuidString: installationRaw),
              let serverRaw = json["serverID"] as? String,
              let serverID = UUID(uuidString: serverRaw) else {
            throw RemotePushError(status: 400, message: "Invalid live status subscription removal.")
        }
        self.installationID = installationID
        self.serverID = serverID
    }
}

struct RemoteLiveStatusSubscription: Codable, Equatable {
    let installationID: UUID
    let serverID: UUID
    var environment: String
    var widgetToken: String?
    var startToken: String?
    var activityToken: String?
    var activityID: String?
    var liveActivities: Bool

    static func validToken(_ token: String) -> Bool {
        (32...200).contains(token.utf8.count)
            && token.utf8.count.isMultiple(of: 2)
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct RemoteLiveStatusIntervals: Codable, Equatable {
    var widgetThrottle: TimeInterval = 30
    var activityUpdateThrottle: TimeInterval = 3
    var activityEndIdle: TimeInterval = 45
    var activityStartThrottle: TimeInterval = 30 * 60
    var retryBase: TimeInterval = 15
}

actor RemoteLiveStatus {
    private enum DeliveryKind: String, Codable {
        case widget, activityStart, activityUpdate, activityEnd
    }

    private struct Subscriber: Codable {
        var subscription: RemoteLiveStatusSubscription
        let fingerprint: String
        let revision: UUID
        var updatedAt: Date
        var lastWidgetSignature: String?
        var lastWidgetSentAt: Date?
        var lastActivitySignature: String?
        var lastActivityStateSignature: String?
        var lastActivityUpdateAt: Date?
        var lastStartSentAt: Date?
        var idleSince: Date?
    }

    private struct Delivery: Codable {
        var id = UUID()
        let subscriberRevision: UUID
        var kind: DeliveryKind
        var signature: String?
        var stateSignature: String?
        var snapshot: LiveStatusSnapshot?
        var priority: Int
        var attempts = 0
        var nextAttempt: Date
    }

    private struct State: Codable {
        var subscribers: [Subscriber] = []
        var deliveries: [Delivery] = []
    }

    private let file: URL
    private let configuration: () throws -> RemotePushConfiguration
    private let send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let intervals: RemoteLiveStatusIntervals
    private var state: State?
    private var fingerprint: String?
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var generation = 0
    private var lastDeliveryError: String?
    private var cachedAuthorization: (keyID: String, keyDigest: Data, value: String, date: Date)?
    private var currentSnapshot: LiveStatusSnapshot?

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/notifications/live-status.json"),
         intervals: RemoteLiveStatusIntervals = RemoteLiveStatusIntervals(),
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         configuration: @escaping () throws -> RemotePushConfiguration = RemotePushConfiguration.load,
         send: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else {
                 throw RemotePushError(status: 502, message: "Apple push returned an invalid response.")
             }
             return (data, response)
         }) {
        self.file = file
        self.intervals = intervals
        self.now = now
        self.sleep = sleep
        self.configuration = configuration
        self.send = send
    }

    func activate(fingerprint: String?) {
        generation += 1
        worker?.cancel()
        sleeper?.cancel()
        worker = nil
        self.fingerprint = fingerprint
        guard let fingerprint else { return }
        do {
            var next = try load()
            next.subscribers.removeAll { $0.fingerprint != fingerprint }
            let revisions = Set(next.subscribers.map(\.revision))
            next.deliveries.removeAll { !revisions.contains($0.subscriberRevision) }
            try save(next)
            if let currentSnapshot { self.update(currentSnapshot) }
            startWorker()
        } catch { report(error.localizedDescription) }
    }

    func status() -> RemoteLiveStatusPushStatus {
        do {
            _ = try configuration()
            _ = try load()
            return RemoteLiveStatusPushStatus(configured: true,
                message: "Apple push is configured on the Mac.")
        } catch {
            return RemoteLiveStatusPushStatus(configured: false,
                message: error.localizedDescription)
        }
    }

    func merge(_ update: RemoteLiveStatusSubscriptionUpdate, fingerprint: String) throws {
        var next = try load()
        removeExpiredSubscribers(&next)
        let staleRevisions = next.subscribers.filter {
            $0.subscription.installationID == update.installationID
                && $0.subscription.serverID == update.serverID
                && $0.fingerprint != fingerprint
        }.map(\.revision)
        next.subscribers.removeAll {
            $0.subscription.installationID == update.installationID
                && $0.subscription.serverID == update.serverID
                && $0.fingerprint != fingerprint
        }
        next.deliveries.removeAll { staleRevisions.contains($0.subscriberRevision) }
        let index = next.subscribers.firstIndex {
            $0.subscription.installationID == update.installationID
                && $0.subscription.serverID == update.serverID
                && $0.fingerprint == fingerprint
        }
        var subscription = index.map { next.subscribers[$0].subscription } ?? RemoteLiveStatusSubscription(
            installationID: update.installationID,
            serverID: update.serverID,
            environment: update.environment,
            liveActivities: false
        )
        let previousWidgetToken = subscription.widgetToken
        let previousStartToken = subscription.startToken
        let previousActivityToken = subscription.activityToken
        subscription.environment = update.environment
        apply(update.widgetToken, to: &subscription.widgetToken)
        apply(update.startToken, to: &subscription.startToken)
        apply(update.activityToken, to: &subscription.activityToken)
        apply(update.activityID, to: &subscription.activityID)
        if let liveActivities = update.liveActivities { subscription.liveActivities = liveActivities }

        if let index {
            next.subscribers[index].subscription = subscription
            next.subscribers[index].updatedAt = now()
            next.subscribers[index].idleSince = subscription.activityToken == nil ? nil : next.subscribers[index].idleSince
            if previousWidgetToken != subscription.widgetToken {
                next.subscribers[index].lastWidgetSignature = nil
                next.subscribers[index].lastWidgetSentAt = nil
            }
            if previousStartToken != subscription.startToken {
                next.subscribers[index].lastStartSentAt = nil
            }
            if previousActivityToken != subscription.activityToken {
                next.subscribers[index].lastActivitySignature = nil
                next.subscribers[index].lastActivityStateSignature = nil
                next.subscribers[index].lastActivityUpdateAt = nil
                next.subscribers[index].idleSince = nil
            }
        } else {
            guard next.subscribers.count < 64 else {
                throw RemotePushError(status: 409, message: "This Mac has reached its live status device limit.")
            }
            next.subscribers.append(Subscriber(subscription: subscription, fingerprint: fingerprint,
                                             revision: UUID(), updatedAt: now()))
        }
        try save(next)
        if let currentSnapshot { self.update(currentSnapshot) }
    }

    func unregister(_ removal: RemoteLiveStatusSubscriptionRemoval, fingerprint: String) throws {
        var next = try load()
        let removed = next.subscribers.filter {
            $0.subscription.installationID == removal.installationID
                && $0.subscription.serverID == removal.serverID
                && $0.fingerprint == fingerprint
        }.map(\.revision)
        next.subscribers.removeAll {
            $0.subscription.installationID == removal.installationID
                && $0.subscription.serverID == removal.serverID
                && $0.fingerprint == fingerprint
        }
        next.deliveries.removeAll { removed.contains($0.subscriberRevision) }
        try save(next)
        sleeper?.cancel()
    }

    func update(_ snapshot: LiveStatusSnapshot) {
        currentSnapshot = snapshot
        guard let fingerprint else { return }
        do {
            var next = try load()
            removeExpiredSubscribers(&next)
            next.subscribers.removeAll { $0.fingerprint != fingerprint }
            let revisions = Set(next.subscribers.map(\.revision))
            next.deliveries.removeAll { !revisions.contains($0.subscriberRevision) }
            let current = now()
            for index in next.subscribers.indices {
                var subscriber = next.subscribers[index]
                planWidget(snapshot, now: current, subscriber: &subscriber, state: &next)
                planLiveActivity(snapshot, now: current, subscriber: &subscriber, state: &next)
                next.subscribers[index] = subscriber
            }
            try save(next)
            startWorker()
        } catch { report(error.localizedDescription) }
    }

    private func apply(_ value: RemoteLiveStatusSubscriptionUpdate.TokenValue, to token: inout String?) {
        switch value {
        case .keep: break
        case .clear: token = nil
        case .set(let next): token = next
        }
    }

    private func planWidget(_ snapshot: LiveStatusSnapshot, now: Date,
                            subscriber: inout Subscriber, state: inout State) {
        guard subscriber.subscription.widgetToken != nil else {
            state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind == .widget }
            return
        }
        let signature = Self.widgetSignature(snapshot)
        if subscriber.lastWidgetSignature == signature {
            state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind == .widget }
            return
        }
        let due: Date
        if let last = subscriber.lastWidgetSentAt,
           now.timeIntervalSince(last) < intervals.widgetThrottle {
            due = last.addingTimeInterval(intervals.widgetThrottle)
        } else {
            due = now
        }
        upsertDelivery(kind: .widget, subscriberRevision: subscriber.revision, signature: signature,
                       stateSignature: nil, snapshot: nil, priority: 5, due: due, state: &state)
    }

    private func planLiveActivity(_ snapshot: LiveStatusSnapshot, now: Date,
                                  subscriber: inout Subscriber, state: inout State) {
        guard subscriber.subscription.liveActivities else {
            state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind != .widget }
            subscriber.idleSince = nil
            return
        }
        let active = snapshot.running + snapshot.needsInput > 0
        let signature = Self.activitySignature(snapshot)
        let stateSignature = Self.activityStateSignature(snapshot)
        if active { subscriber.idleSince = nil }
        if subscriber.subscription.activityToken != nil || !active {
            state.deliveries.removeAll {
                $0.subscriberRevision == subscriber.revision && $0.kind == .activityStart
            }
        }

        if let _ = subscriber.subscription.activityToken {
            if active {
                state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind == .activityEnd }
                guard subscriber.lastActivitySignature != signature else {
                    state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind == .activityUpdate }
                    return
                }
                let due: Date
                if let last = subscriber.lastActivityUpdateAt,
                   now.timeIntervalSince(last) < intervals.activityUpdateThrottle {
                    due = last.addingTimeInterval(intervals.activityUpdateThrottle)
                } else {
                    due = now
                }
                let priority = subscriber.lastActivityStateSignature != stateSignature ? 10 : 5
                upsertDelivery(kind: .activityUpdate, subscriberRevision: subscriber.revision,
                               signature: signature, stateSignature: stateSignature, snapshot: snapshot,
                               priority: priority, due: due, state: &state)
            } else {
                state.deliveries.removeAll { $0.subscriberRevision == subscriber.revision && $0.kind == .activityUpdate }
                let idleSince = subscriber.idleSince ?? now
                subscriber.idleSince = idleSince
                let due = idleSince.addingTimeInterval(intervals.activityEndIdle)
                upsertDelivery(kind: .activityEnd, subscriberRevision: subscriber.revision,
                               signature: signature, stateSignature: stateSignature, snapshot: snapshot,
                               priority: 10, due: maxDate(now, due), state: &state)
            }
            return
        }

        state.deliveries.removeAll {
            $0.subscriberRevision == subscriber.revision
                && ($0.kind == .activityUpdate || $0.kind == .activityEnd)
        }
        guard active, subscriber.subscription.startToken != nil else { return }
        if let last = subscriber.lastStartSentAt,
           now.timeIntervalSince(last) < intervals.activityStartThrottle {
            return
        }
        upsertDelivery(kind: .activityStart, subscriberRevision: subscriber.revision,
                       signature: signature, stateSignature: stateSignature, snapshot: snapshot,
                       priority: 10, due: now, state: &state)
    }

    private func maxDate(_ left: Date, _ right: Date) -> Date {
        left > right ? left : right
    }

    private func upsertDelivery(kind: DeliveryKind, subscriberRevision: UUID,
                                signature: String?, stateSignature: String?, snapshot: LiveStatusSnapshot?,
                                priority: Int, due: Date, state: inout State) {
        if let index = state.deliveries.firstIndex(where: {
            $0.subscriberRevision == subscriberRevision && $0.kind == kind
        }) {
            let samePayload = state.deliveries[index].signature == signature
                && state.deliveries[index].stateSignature == stateSignature
                && state.deliveries[index].snapshot == snapshot
            state.deliveries[index].priority = max(state.deliveries[index].priority, priority)
            if !samePayload {
                state.deliveries[index].signature = signature
                state.deliveries[index].stateSignature = stateSignature
                state.deliveries[index].snapshot = snapshot
                state.deliveries[index].attempts = 0
                state.deliveries[index].nextAttempt = due
            }
        } else {
            state.deliveries.append(Delivery(subscriberRevision: subscriberRevision, kind: kind,
                                             signature: signature, stateSignature: stateSignature,
                                             snapshot: snapshot, priority: priority, nextAttempt: due))
        }
        sleeper?.cancel()
    }

    private func load() throws -> State {
        if let state { return state }
        if !FileManager.default.fileExists(atPath: file.path) {
            state = State()
        } else {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { throw RemotePushError(status: 503, message: "Could not read the Mac's saved live status subscriptions.") }
        }
        return state!
    }

    private func save(_ next: State) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
            try JSONEncoder().encode(next).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = next
        } catch {
            throw RemotePushError(status: 503, message: "Could not save live status subscriptions on the Mac. Check disk space and permissions.")
        }
    }

    private func removeExpiredSubscribers(_ state: inout State) {
        let cutoff = now().addingTimeInterval(-90 * 86400)
        state.subscribers.removeAll { $0.updatedAt < cutoff }
        let revisions = Set(state.subscribers.map(\.revision))
        state.deliveries.removeAll { !revisions.contains($0.subscriberRevision) }
    }

    private func report(_ message: String) {
        lastDeliveryError = message
        Log.write("remote-live-status: \(message)")
    }

    private func startWorker() {
        guard fingerprint != nil, worker == nil else { return }
        let revision = generation
        worker = Task {
            await drain(generation: revision)
            if generation == revision { worker = nil }
        }
    }

    private func drain(generation revision: Int) async {
        while !Task.isCancelled, generation == revision, fingerprint != nil {
            do {
                var next = try load()
                removeUndeliverable(&next)
                guard let delivery = next.deliveries.min(by: { $0.nextAttempt < $1.nextAttempt }) else {
                    try save(next)
                    return
                }
                let current = now()
                if delivery.nextAttempt > current {
                    let delay = Task { try await sleep(delivery.nextAttempt.timeIntervalSince(current)) }
                    sleeper = delay
                    do { try await delay.value }
                    catch is CancellationError {
                        if Task.isCancelled { return }
                    }
                    sleeper = nil
                    continue
                }
                guard let subscriber = next.subscribers.first(where: { $0.revision == delivery.subscriberRevision }) else {
                    next.deliveries.removeAll { $0.id == delivery.id }
                    try save(next)
                    continue
                }
                var delivered = false
                var retry = false
                var invalidToken = false
                do {
                    let config = try configuration()
                    let authorization = try authorization(for: config, now: current)
                    let request = try Self.request(delivery: delivery, subscriber: subscriber,
                                                   authorization: authorization, now: current)
                    let (data, response) = try await send(request)
                    if response.statusCode == 200 {
                        delivered = true
                        lastDeliveryError = nil
                    } else {
                        struct Failure: Decodable { let reason: String }
                        let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.reason ?? "HTTP \(response.statusCode)"
                        invalidToken = response.statusCode == 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].contains(reason)
                        retry = response.statusCode == 429 || response.statusCode >= 500 || reason == "ExpiredProviderToken"
                        if reason == "ExpiredProviderToken" { cachedAuthorization = nil }
                        report("Apple push rejected live status (\(response.statusCode), \(String(reason.prefix(100)))).")
                    }
                } catch is CancellationError { return }
                catch {
                    retry = true
                    report("Apple push live status delivery failed: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, generation == revision else { return }
                next = try load()
                if invalidToken {
                    clearToken(for: delivery.kind, subscriberRevision: delivery.subscriberRevision, state: &next)
                } else if let index = next.deliveries.firstIndex(where: { $0.id == delivery.id }) {
                    if delivered {
                        applySuccess(delivery: delivery, state: &next)
                        next.deliveries.remove(at: index)
                    } else if retry && delivery.attempts < 4 {
                        next.deliveries[index].attempts += 1
                        next.deliveries[index].nextAttempt = now().addingTimeInterval(
                            pow(2, Double(delivery.attempts)) * intervals.retryBase
                        )
                    } else {
                        next.deliveries.remove(at: index)
                    }
                }
                try save(next)
            } catch is CancellationError { return }
            catch {
                report(error.localizedDescription)
                return
            }
        }
    }

    private func authorization(for config: RemotePushConfiguration, now: Date) throws -> String {
        let digest = Data(SHA256.hash(data: config.key.rawRepresentation))
        if let cached = cachedAuthorization, cached.keyID == config.keyID, cached.keyDigest == digest,
           now.timeIntervalSince(cached.date) < 3000 {
            return cached.value
        }
        let value = try config.authorization(now: now)
        cachedAuthorization = (config.keyID, digest, value, now)
        return value
    }

    private func removeUndeliverable(_ state: inout State) {
        let revisions = Set(state.subscribers.map(\.revision))
        state.deliveries.removeAll { delivery in
            guard revisions.contains(delivery.subscriberRevision),
                  let subscriber = state.subscribers.first(where: { $0.revision == delivery.subscriberRevision }) else {
                return true
            }
            switch delivery.kind {
            case .widget: return subscriber.subscription.widgetToken == nil
            case .activityStart: return subscriber.subscription.startToken == nil
            case .activityUpdate, .activityEnd: return subscriber.subscription.activityToken == nil
            }
        }
    }

    private func clearToken(for kind: DeliveryKind, subscriberRevision: UUID, state: inout State) {
        guard let index = state.subscribers.firstIndex(where: { $0.revision == subscriberRevision }) else { return }
        switch kind {
        case .widget:
            state.subscribers[index].subscription.widgetToken = nil
            state.deliveries.removeAll { $0.subscriberRevision == subscriberRevision && $0.kind == .widget }
        case .activityStart:
            state.subscribers[index].subscription.startToken = nil
            state.deliveries.removeAll { $0.subscriberRevision == subscriberRevision && $0.kind == .activityStart }
        case .activityUpdate, .activityEnd:
            state.subscribers[index].subscription.activityToken = nil
            state.subscribers[index].subscription.activityID = nil
            state.subscribers[index].idleSince = nil
            state.subscribers[index].lastActivitySignature = nil
            state.subscribers[index].lastActivityStateSignature = nil
            state.deliveries.removeAll {
                $0.subscriberRevision == subscriberRevision
                    && ($0.kind == .activityUpdate || $0.kind == .activityEnd)
            }
        }
    }

    private func applySuccess(delivery: Delivery, state: inout State) {
        guard let index = state.subscribers.firstIndex(where: { $0.revision == delivery.subscriberRevision }) else { return }
        let current = now()
        switch delivery.kind {
        case .widget:
            state.subscribers[index].lastWidgetSignature = delivery.signature
            state.subscribers[index].lastWidgetSentAt = current
        case .activityStart:
            state.subscribers[index].lastStartSentAt = current
        case .activityUpdate:
            state.subscribers[index].lastActivitySignature = delivery.signature
            state.subscribers[index].lastActivityStateSignature = delivery.stateSignature
            state.subscribers[index].lastActivityUpdateAt = current
        case .activityEnd:
            state.subscribers[index].lastActivitySignature = nil
            state.subscribers[index].lastActivityStateSignature = nil
            state.subscribers[index].lastActivityUpdateAt = nil
            state.subscribers[index].lastStartSentAt = nil
            state.subscribers[index].idleSince = nil
            state.subscribers[index].subscription.activityToken = nil
            state.subscribers[index].subscription.activityID = nil
        }
    }

    private static func request(delivery: Delivery, subscriber: Subscriber,
                                authorization: String, now: Date) throws -> URLRequest {
        let token: String
        switch delivery.kind {
        case .widget:
            guard let value = subscriber.subscription.widgetToken else {
                throw RemotePushError(status: 400, message: "Missing widget push token.")
            }
            token = value
        case .activityStart:
            guard let value = subscriber.subscription.startToken else {
                throw RemotePushError(status: 400, message: "Missing Live Activity start token.")
            }
            token = value
        case .activityUpdate, .activityEnd:
            guard let value = subscriber.subscription.activityToken else {
                throw RemotePushError(status: 400, message: "Missing Live Activity update token.")
            }
            token = value
        }
        let host = subscriber.subscription.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(token)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("bearer \(authorization)", forHTTPHeaderField: "authorization")
        request.setValue(delivery.id.uuidString, forHTTPHeaderField: "apns-id")
        switch delivery.kind {
        case .widget:
            request.setValue("widgets", forHTTPHeaderField: "apns-push-type")
            request.setValue("com.itzhoang.hermbot.push-type.widgets", forHTTPHeaderField: "apns-topic")
            request.setValue("5", forHTTPHeaderField: "apns-priority")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["aps": ["content-changed": true]])
        case .activityStart, .activityUpdate, .activityEnd:
            guard let snapshot = delivery.snapshot else {
                throw RemotePushError(status: 400, message: "Missing Live Activity snapshot.")
            }
            request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
            request.setValue("com.itzhoang.hermbot.push-type.liveactivity", forHTTPHeaderField: "apns-topic")
            request.setValue(String(delivery.priority), forHTTPHeaderField: "apns-priority")
            request.httpBody = try liveActivityPayload(kind: delivery.kind, snapshot: snapshot, now: now)
        }
        guard request.httpBody!.count <= 4096 else {
            throw RemotePushError(status: 400, message: "The live status payload exceeds Apple's payload limit.")
        }
        return request
    }

    private static func liveActivityPayload(kind: DeliveryKind, snapshot: LiveStatusSnapshot,
                                            now: Date) throws -> Data {
        var tabs = Array(snapshot.tabs.prefix(5)).map { tabObject($0, detailLimit: 60) }
        while true {
            var aps: [String: Any] = [
                "timestamp": Int(now.timeIntervalSince1970),
                "event": eventName(kind),
                "content-state": [
                    "tabs": tabs,
                    "running": snapshot.running,
                    "needsInput": snapshot.needsInput,
                    "total": snapshot.total,
                    "updatedAt": now.timeIntervalSince1970,
                ],
            ]
            switch kind {
            case .activityStart:
                aps["attributes-type"] = "CantripTabsAttributes"
                aps["attributes"] = ["hostName": snapshot.hostName]
                aps["alert"] = startAlert(snapshot)
                aps["stale-date"] = now.addingTimeInterval(3600).timeIntervalSince1970
            case .activityUpdate:
                aps["stale-date"] = now.addingTimeInterval(3600).timeIntervalSince1970
            case .activityEnd:
                aps["dismissal-date"] = now.addingTimeInterval(900).timeIntervalSince1970
            case .widget:
                break
            }
            let data = try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
            if data.count <= 4096 { return data }
            guard !tabs.isEmpty else { return data }
            tabs.removeLast()
        }
    }

    /// Generic on purpose: the alert can show on a locked phone or a watch.
    static func startAlert(_ snapshot: LiveStatusSnapshot) -> [String: String] {
        let waiting = snapshot.needsInput
        guard waiting > 0 else {
            let count = snapshot.running
            return ["title": "Cantrip is working", "body": "\(count) tab\(count == 1 ? "" : "s") running"]
        }
        var body = waiting == 1 ? "1 tab needs your response" : "\(waiting) tabs need your response"
        if snapshot.running > 0 { body += " · \(snapshot.running) running" }
        return ["title": "Cantrip needs your response", "body": body]
    }

    private static func eventName(_ kind: DeliveryKind) -> String {
        switch kind {
        case .activityStart: return "start"
        case .activityUpdate: return "update"
        case .activityEnd: return "end"
        case .widget: return "update"
        }
    }

    private static func tabObject(_ tab: LiveStatusTab, detailLimit: Int) -> [String: Any] {
        var object: [String: Any] = [
            "id": tab.id,
            "title": tab.title,
            "state": tab.state.rawValue,
            "queued": tab.queued,
            "subagents": tab.subagents,
        ]
        object["startedAt"] = tab.startedAt ?? NSNull()
        object["finishedAt"] = tab.finishedAt ?? NSNull()
        object["detail"] = LiveStatusSnapshot.clipped(tab.detail, limit: detailLimit) ?? NSNull()
        if let inputKind = tab.inputKind { object["inputKind"] = inputKind }
        return object
    }

    private static func widgetSignature(_ snapshot: LiveStatusSnapshot) -> String {
        snapshot.tabs.map { "\($0.id)|\($0.state.rawValue)|\($0.title)|\(request($0))" }.joined(separator: "\n")
    }

    /// Leaves out a running tab's `detail`: its current step changes every few seconds,
    /// and the Live Activity doesn't show it, so it alone never warrants a push.
    private static func activitySignature(_ snapshot: LiveStatusSnapshot) -> String {
        let tabs = snapshot.tabs.prefix(5).map { tab in
            [tab.id, tab.state.rawValue, tab.title,
             String(tab.queued), String(tab.subagents),
             tab.startedAt.map { String($0) } ?? "", tab.finishedAt.map { String($0) } ?? "",
             request(tab)].joined(separator: "|")
        }.joined(separator: "\n")
        return "\(snapshot.running)|\(snapshot.needsInput)|\(snapshot.total)|\(tabs)"
    }

    /// A new request in a waiting tab is as urgent as the tab starting to wait.
    private static func activityStateSignature(_ snapshot: LiveStatusSnapshot) -> String {
        snapshot.tabs.prefix(5).map { "\($0.id)|\($0.state.rawValue)|\(request($0))" }.joined(separator: "\n")
    }

    /// The pending request a waiting tab shows; empty for every other state.
    private static func request(_ tab: LiveStatusTab) -> String {
        guard tab.state == .input else { return "" }
        return "\(tab.inputKind ?? "")|\(tab.detail ?? "")"
    }
}
