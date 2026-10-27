import CryptoKit
import Foundation

private actor PushAuthorizations {
    var values: [String] = []
    func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        values.append(request.value(forHTTPHeaderField: "authorization") ?? "")
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension SessionTabTests {
    @MainActor
    static func testSharedAPNsToken() async throws {
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = APNsProviderToken()
        let first = try tokens.value(for: configuration, now: start)
        let reused = try tokens.value(for: configuration, now: start.addingTimeInterval(APNsProviderToken.lifetime - 1))
        precondition(reused == first, "A provider token is reused within its lifetime")
        let renewed = try tokens.value(for: configuration, now: start.addingTimeInterval(APNsProviderToken.lifetime))
        precondition(renewed != first, "A provider token is renewed once its lifetime ends")
        tokens.expire(first)
        let kept = try tokens.value(for: configuration, now: start.addingTimeInterval(APNsProviderToken.lifetime + 1))
        precondition(kept == renewed, "A late rejection of an older token keeps the newer one")
        tokens.expire(renewed)
        let replaced = try tokens.value(for: configuration, now: start.addingTimeInterval(APNsProviderToken.lifetime + 2))
        precondition(replaced != renewed, "A rejected token is replaced")
        let otherKey = RemotePushConfiguration(keyID: "OTHERKEY12", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let other = try tokens.value(for: otherKey, now: start.addingTimeInterval(APNsProviderToken.lifetime + 3))
        precondition(other != replaced, "A different key gets its own token")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-token-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = PushAuthorizations()
        let shared = APNsProviderToken()
        let alerts = RemoteNotifications(file: directory.appendingPathComponent("alerts/state.json"),
                                         configuration: { configuration }, send: { await sent.respond($0) },
                                         tokens: shared)
        let liveStatus = RemoteLiveStatus(file: directory.appendingPathComponent("live/state.json"),
                                          configuration: { configuration }, send: { await sent.respond($0) },
                                          tokens: shared)
        try await alerts.register(RemotePushRegistration(installationID: UUID(), serverID: UUID(),
                                                         deviceToken: String(repeating: "c", count: 64),
                                                         environment: "development"), fingerprint: "paired")
        await alerts.activate(fingerprint: "paired")
        await alerts.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "Build", summary: "Done",
                                              completedAt: Date()))
        await liveStatus.activate(fingerprint: "paired")
        try await liveStatus.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": UUID().uuidString,
            "serverID": UUID().uuidString,
            "environment": "development",
            "startToken": String(repeating: "d", count: 64),
            "liveActivities": true,
        ]), fingerprint: "paired")
        await liveStatus.update(LiveStatusSnapshot.build(from: [
            LiveStatusSession(id: UUID(), title: "Deploy", isStreaming: true,
                              pendingInputs: [LiveStatusInput(title: "Run the deploy script?", kind: "approval")],
                              currentRunStartedAt: Date()),
        ], now: Date(), hostName: "Mac"))
        for _ in 0..<200 {
            if await sent.values.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let authorizations = await sent.values
        await alerts.activate(fingerprint: nil)
        await liveStatus.activate(fingerprint: nil)
        precondition(authorizations.count == 2, "An alert and a live status push were sent: \(authorizations.count)")
        precondition(authorizations[0] == authorizations[1] && authorizations[0].hasPrefix("bearer "),
                     "Alerts and live status sign with the same provider token")
        print("Shared APNs provider token: reuse, renewal, expiry, per-key and cross-sender passed")
    }
}
