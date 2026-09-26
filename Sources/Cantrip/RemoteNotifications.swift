import CryptoKit
import Foundation

struct RemoteCompletion: Codable, Equatable {
    let id: UUID
    let sessionID: UUID
    let title: String
    let summary: String
    let completedAt: Date
    var kind: String? = nil
    var expiresAt: Date? = nil
    var isAttention: Bool { kind == "input" || kind == "macAttention" }

    static func preview(_ text: String) -> String {
        // Use the final answer, not tool output or a second model request.
        var value = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if value.isEmpty { return "The response is ready. Open the tab for details." }
        return value.count > 220 ? String(value.prefix(217)) + "..." : value
    }
}

struct RemotePushStatus: Codable {
    let configured: Bool
    let message: String
    let lastDeliveryError: String?
    var supportsInputAlerts = true
}

struct RemotePushRegistration: Codable, Equatable {
    let installationID: UUID
    let serverID: UUID
    let deviceToken: String
    let environment: String
    var inputNeeded: Bool? = nil

    var isValid: Bool {
        ["development", "production"].contains(environment)
            && (32...200).contains(deviceToken.utf8.count)
            && deviceToken.utf8.count.isMultiple(of: 2)
            && deviceToken.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct RemotePushError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct RemotePushConfiguration {
    let keyID: String
    let teamID: String
    let key: P256.Signing.PrivateKey

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Cantrip/apns.json")

    static func load() throws -> Self {
        struct Settings: Decodable { let keyID: String; let teamID: String; let privateKeyPath: String }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RemotePushError(status: 503, message: "Apple push is not configured on this Mac. Set up ~/.config/Cantrip/apns.json as described in the Cantrip README.")
        }
        do {
            let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
            guard [settings.keyID, settings.teamID].allSatisfy({
                $0.count == 10 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
            }) else { throw RemotePushError(status: 503, message: "Invalid Apple push key ID or team ID.") }
            let path = (settings.privateKeyPath as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw RemotePushError(status: 503, message: "The Apple push private key needs an absolute path.")
            }
            return try Self(keyID: settings.keyID, teamID: settings.teamID,
                            key: P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8)))
        } catch let error as RemotePushError {
            throw error
        } catch {
            throw RemotePushError(status: 503, message: "Could not read the Apple push configuration or its P-256 .p8 key. Check the configuration on the Mac.")
        }
    }

    func authorization(now: Date) throws -> String {
        func base64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(now.timeIntervalSince1970)])
        let message = base64(header) + "." + base64(claims)
        return try message + "." + base64(key.signature(for: Data(message.utf8)).rawRepresentation)
    }
}

/// The Mac talks directly to APNs. Pairing credentials and agent transcripts
/// never pass through a third-party notification relay.
actor RemoteNotifications {
    private struct Subscriber: Codable {
        let registration: RemotePushRegistration
        let fingerprint: String
        let revision: UUID
        let updatedAt: Date
    }
    private struct Delivery: Codable {
        let id: UUID
        let subscriberRevision: UUID
        let completion: RemoteCompletion
        var attempts = 0
        var nextAttempt = Date()
    }
    private struct State: Codable {
        var subscribers: [Subscriber] = []
        var deliveries: [Delivery] = []
        var completedIDs: [UUID] = []
    }

    private let file: URL
    private let configuration: () throws -> RemotePushConfiguration
    private let send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var state: State?
    private var fingerprint: String?
    private var worker: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var generation = 0
    private var lastDeliveryError: String?
    private var cachedAuthorization: (keyID: String, keyDigest: Data, value: String, date: Date)?
    private var pendingInputs: Set<UUID> = []

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/notifications/state.json"),
         configuration: @escaping () throws -> RemotePushConfiguration = RemotePushConfiguration.load,
         send: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else {
                 throw RemotePushError(status: 502, message: "Apple push returned an invalid response.")
             }
             return (data, response)
         }) {
        self.file = file
        self.configuration = configuration
        self.send = send
    }

    func activate(fingerprint: String?) {
        generation += 1
        worker?.cancel()
        sleeper?.cancel()
        worker = nil
        self.fingerprint = fingerprint
        if fingerprint != nil { startWorker() }
    }

    func status() -> RemotePushStatus {
        do {
            _ = try configuration()
            _ = try load()
            return RemotePushStatus(configured: true, message: "Apple push is configured on the Mac.",
                                    lastDeliveryError: lastDeliveryError)
        } catch {
            return RemotePushStatus(configured: false, message: error.localizedDescription,
                                    lastDeliveryError: lastDeliveryError)
        }
    }

    func register(_ registration: RemotePushRegistration, fingerprint: String) throws {
        guard registration.isValid else {
            throw RemotePushError(status: 400, message: "Invalid notification registration.")
        }
        _ = try configuration()
        var next = try load()
        let existing = next.subscribers.first {
            $0.registration.installationID == registration.installationID
                && $0.registration.serverID == registration.serverID && $0.fingerprint == fingerprint
        }
        let revision = existing?.registration == registration ? existing!.revision : UUID()
        next.subscribers.removeAll {
            ($0.registration.installationID == registration.installationID && $0.registration.serverID == registration.serverID)
                || ($0.registration.deviceToken == registration.deviceToken && $0.registration.environment == registration.environment)
        }
        guard next.subscribers.count < 64 else {
            throw RemotePushError(status: 409, message: "This Mac has reached its notification device limit.")
        }
        next.subscribers.append(Subscriber(registration: registration, fingerprint: fingerprint,
                                          revision: revision, updatedAt: Date()))
        let revisions = Set(next.subscribers.map(\.revision))
        next.deliveries.removeAll { !revisions.contains($0.subscriberRevision) }
        try save(next)
        sleeper?.cancel()
        startWorker()
    }

    func unregister(installationID: UUID, serverID: UUID, fingerprint: String) throws {
        var next = try load()
        next.subscribers.removeAll {
            $0.registration.installationID == installationID && $0.registration.serverID == serverID
                && $0.fingerprint == fingerprint
        }
        let revisions = Set(next.subscribers.map(\.revision))
        next.deliveries.removeAll { !revisions.contains($0.subscriberRevision) }
        try save(next)
        sleeper?.cancel()
    }

    func enqueue(_ completion: RemoteCompletion) {
        guard let fingerprint else { return }
        do {
            var next = try load()
            guard !next.completedIDs.contains(completion.id) else { return }
            next.completedIDs = Array((next.completedIDs + [completion.id]).suffix(512))
            next.subscribers.removeAll { $0.updatedAt < Date().addingTimeInterval(-90 * 86400) || $0.fingerprint != fingerprint }
            for subscriber in next.subscribers {
                if completion.isAttention && subscriber.registration.inputNeeded != true { continue }
                next.deliveries.append(Delivery(id: UUID(), subscriberRevision: subscriber.revision,
                                               completion: completion))
            }

            // Bound stale work without replaying historical tabs to new subscribers.
            next.deliveries.removeAll { $0.completion.completedAt < Date().addingTimeInterval(-3600) }
            guard next.deliveries.count <= 1024 else {
                throw RemotePushError(status: 503, message: "The notification queue is full. Check Apple push delivery on the Mac.")
            }
            try save(next)
            sleeper?.cancel()
            startWorker()
        } catch { report(error.localizedDescription) }
    }

    func enqueueInput(id: UUID, sessionID: UUID, expiresAt: Date, kind: String = "input") {
        guard expiresAt > Date() else { return }
        pendingInputs.insert(id)
        enqueue(RemoteCompletion(id: id, sessionID: sessionID, title: "", summary: "",
                                 completedAt: Date(), kind: kind, expiresAt: expiresAt))
    }

    func resolveInput(_ id: UUID) {
        pendingInputs.remove(id)
        do {
            var next = try load()
            next.deliveries.removeAll { $0.completion.isAttention && $0.completion.id == id }
            try save(next)
            sleeper?.cancel()
        } catch { report(error.localizedDescription) }
    }

    private func load() throws -> State {
        if let state { return state }
        if !FileManager.default.fileExists(atPath: file.path) {
            state = State()
        } else {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { throw RemotePushError(status: 503, message: "Could not read the Mac's saved notification registrations.") }
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
        } catch { throw RemotePushError(status: 503, message: "Could not save notifications on the Mac. Check disk space and permissions.") }
    }

    private func report(_ message: String) {
        lastDeliveryError = message
        Log.write("remote-notifications: \(message)")
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
        while !Task.isCancelled, generation == revision, let fingerprint {
            do {
                var next = try load()
                let now = Date()
                next.deliveries.removeAll { delivery in
                    delivery.completion.completedAt < now.addingTimeInterval(-3600)
                        || (delivery.completion.isAttention
                            && (!pendingInputs.contains(delivery.completion.id)
                                || (delivery.completion.expiresAt ?? .distantPast) <= now))
                        || !next.subscribers.contains {
                            $0.revision == delivery.subscriberRevision && $0.fingerprint == fingerprint
                        }
                }
                guard let delivery = next.deliveries.min(by: { $0.nextAttempt < $1.nextAttempt }) else {
                    try save(next)
                    return
                }
                if delivery.nextAttempt > now {
                    let delay = Task { try await Task.sleep(for: .seconds(delivery.nextAttempt.timeIntervalSince(now))) }
                    sleeper = delay
                    do { try await delay.value }
                    catch is CancellationError {
                        if Task.isCancelled { return }
                    }
                    sleeper = nil
                    continue
                }
                guard let subscriber = next.subscribers.first(where: { $0.revision == delivery.subscriberRevision }) else { continue }
                var retry = false
                var invalidToken = false
                do {
                    let config = try configuration()
                    let digest = Data(SHA256.hash(data: config.key.rawRepresentation))
                    let authorization: String
                    if let cached = cachedAuthorization, cached.keyID == config.keyID, cached.keyDigest == digest,
                       now.timeIntervalSince(cached.date) < 3000 {
                        authorization = cached.value
                    } else {
                        authorization = try config.authorization(now: now)
                        cachedAuthorization = (config.keyID, digest, authorization, now)
                    }
                    let request = try Self.request(deliveryID: delivery.id, completion: delivery.completion,
                                                   registration: subscriber.registration, fingerprint: fingerprint,
                                                   authorization: authorization)
                    let (data, response) = try await send(request)
                    if response.statusCode == 200 {
                        lastDeliveryError = nil
                    } else {
                        struct Failure: Decodable { let reason: String }
                        let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.reason ?? "HTTP \(response.statusCode)"
                        invalidToken = response.statusCode == 410 || ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason)
                        retry = response.statusCode == 429 || response.statusCode >= 500 || reason == "ExpiredProviderToken"
                        if reason == "ExpiredProviderToken" { cachedAuthorization = nil }
                        report("Apple push rejected an alert (\(response.statusCode), \(String(reason.prefix(100)))).")
                    }
                } catch is CancellationError { return }
                catch {
                    retry = true
                    report("Apple push delivery failed: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, generation == revision else { return }
                // Registration/opt-out may have changed while the network request ran.
                next = try load()
                if invalidToken {
                    next.subscribers.removeAll { $0.revision == subscriber.revision }
                    next.deliveries.removeAll { $0.subscriberRevision == subscriber.revision }
                } else if let index = next.deliveries.firstIndex(where: { $0.id == delivery.id }) {
                    if retry && delivery.attempts < 4 {
                        next.deliveries[index].attempts += 1
                        next.deliveries[index].nextAttempt = Date().addingTimeInterval(pow(2, Double(delivery.attempts)) * 15)
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

    static func request(deliveryID: UUID, completion: RemoteCompletion, registration: RemotePushRegistration,
                        fingerprint: String, authorization: String) throws -> URLRequest {
        let host = registration.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        var request = URLRequest(url: URL(string: "https://\(host)/3/device/\(registration.deviceToken)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("bearer \(authorization)", forHTTPHeaderField: "authorization")
        request.setValue("com.itzhoang.hermbot", forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(deliveryID.uuidString, forHTTPHeaderField: "apns-id")
        request.setValue(completion.id.uuidString, forHTTPHeaderField: "apns-collapse-id")
        request.setValue(String(Int((completion.expiresAt ?? completion.completedAt.addingTimeInterval(3600)).timeIntervalSince1970)),
                         forHTTPHeaderField: "apns-expiration")
        let input = completion.isAttention
        let alert = input ? ["title": completion.kind == "macAttention" ? "Cantrip Mac needs attention" : "Cantrip needs your input",
                             "body": "Open AgentGateway to review the request on your Mac."]
            : ["title": "Cantrip finished", "subtitle": String(completion.title.prefix(80)), "body": completion.summary]
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "aps": [
                "alert": alert,
                "sound": "default", "thread-id": "\(registration.serverID)/\(completion.sessionID)",
            ],
            "cantrip": ["eventID": completion.id.uuidString, "sessionID": completion.sessionID.uuidString,
                        "serverID": registration.serverID.uuidString, "fingerprint": fingerprint,
                        "kind": input ? (completion.kind ?? "input") : "completion"],
        ])
        guard request.httpBody!.count <= 4096 else {
            throw RemotePushError(status: 400, message: "The completion alert exceeds Apple's payload limit.")
        }
        return request
    }
}
