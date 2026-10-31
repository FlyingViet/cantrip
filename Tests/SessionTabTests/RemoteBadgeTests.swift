import CryptoKit
import Foundation

private actor BadgeRequests {
    var requests: [URLRequest] = []
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
    func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension SessionTabTests {
    /// The app icon's badge counts tabs with an alert nobody has looked at: each push carries the
    /// count, opening a tab (or answering its question) lowers it with a silent badge-only push,
    /// and a tab that finished on screen at the Mac never counts.
    static func testRemoteBadges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("badge-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let recorder = BadgeRequests()
        let service = RemoteNotifications(file: directory.appendingPathComponent("state.json"),
                                          configuration: { configuration }, send: { await recorder.respond($0) })
        let registration = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
                                                  deviceToken: String(repeating: "c", count: 64),
                                                  environment: "production", inputNeeded: true)
        await service.activate(fingerprint: "paired")
        defer { Task { await service.activate(fingerprint: nil) } }
        try await service.register(registration, fingerprint: "paired")

        func waitForRequests(_ count: Int) async throws -> URLRequest {
            for _ in 0..<200 {
                if await recorder.count() >= count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sent = await recorder.count()
            precondition(sent == count, "Expected \(count) pushes, sent \(sent)")
            return await recorder.last()!
        }
        func aps(_ request: URLRequest) -> [String: Any] {
            (try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["aps"] as! [String: Any]
        }
        func expectBadge(_ badge: Int, after count: Int, _ message: String = "") async throws {
            let sent = aps(try await waitForRequests(count))["badge"] as? Int
            precondition(sent == badge, "Badge \(sent.map(String.init) ?? "missing"), expected \(badge). \(message)")
        }

        let first = UUID(), second = UUID()
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: first, title: "One", summary: "Done", completedAt: Date()))
        try await expectBadge(1, after: 1, "The first unseen tab shows 1")
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: first, title: "One again", summary: "Done", completedAt: Date()))
        try await expectBadge(1, after: 2, "A tab counts once however many alerts it sends")
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: second, title: "Two", summary: "Done", completedAt: Date()))
        try await expectBadge(2, after: 3)

        let remaining = await service.markSeen(first)
        precondition(remaining == 1)
        let update = try await waitForRequests(4)
        precondition(aps(update).count == 1 && aps(update)["badge"] as? Int == 1,
                     "Opening a tab sends only the new count: no alert or sound")
        precondition(update.value(forHTTPHeaderField: "apns-priority") == "5"
                     && update.value(forHTTPHeaderField: "apns-collapse-id") == "cantrip-badge")
        let unchanged = await service.markSeen(first)
        precondition(unchanged == 1)
        try await Task.sleep(for: .milliseconds(100))
        let afterRepeat = await recorder.count()
        precondition(afterRepeat == 4, "Seeing an already-seen tab sends nothing")

        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "On screen", summary: "Done",
                                               completedAt: Date()), seen: true)
        try await expectBadge(1, after: 5, "A tab finished on screen at the Mac doesn't count")

        let question = UUID(), asking = UUID()
        await service.enqueueInput(id: question, sessionID: asking, expiresAt: Date().addingTimeInterval(600))
        try await expectBadge(2, after: 6, "A tab waiting on a question counts")
        await service.resolveInput(question)
        try await expectBadge(1, after: 7, "Answering it lowers the badge")

        await service.enqueueInput(id: UUID(), sessionID: UUID(), expiresAt: Date().addingTimeInterval(600), kind: "macAttention")
        try await expectBadge(1, after: 8, "Mac-attention notices aren't a tab's")

        let status = await service.status()
        precondition(status.badge == 1)
        let restored = RemoteNotifications(file: directory.appendingPathComponent("state.json"),
                                           configuration: { configuration }, send: { await recorder.respond($0) })
        let restoredBadge = await restored.badge()
        precondition(restoredBadge == 1, "Unseen tabs survive a Mac restart")
        _ = await service.markSeen(second)
        try await expectBadge(0, after: 9, "Seeing the last tab clears the badge")
        // Opening the app clears that device's badge; its next alert counts only tabs alerted since.
        let phone = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
                                           deviceToken: String(repeating: "d", count: 64),
                                           environment: "production", inputNeeded: true)
        try await service.register(phone, fingerprint: "paired")
        let sentBefore = await recorder.count()
        func expectFor(_ token: String, after count: Int, badge: Int, _ message: String) async throws {
            _ = try await waitForRequests(count)
            let requests = await recorder.requests.suffix(count - sentBefore)
            let sent = requests.last { $0.url?.lastPathComponent == token }
            precondition(sent.map { aps($0)["badge"] as? Int } == badge,
                         "\(message): \(sent.map { aps($0)["badge"] as? Int ?? -1 } ?? -1)")
        }
        let old = UUID(), new = UUID()
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: old, title: "Old", summary: "Done", completedAt: Date()))
        try await expectFor(phone.deviceToken, after: sentBefore + 2, badge: 1, "Before an open, every unseen tab counts")
        let opened = try await service.appOpened(installationID: phone.installationID, serverID: phone.serverID,
                                                 fingerprint: "paired")
        precondition(opened == 0, "Opening the app reports a cleared badge")
        try await service.register(phone, fingerprint: "paired")
        try await Task.sleep(for: .milliseconds(20))
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: new, title: "New", summary: "Done", completedAt: Date()))
        try await expectFor(phone.deviceToken, after: sentBefore + 4, badge: 1,
                            "After an open only the new tab counts, even after re-registering")
        try await expectFor(registration.deviceToken, after: sentBefore + 4, badge: 2,
                            "A device that never reports opening keeps counting every unseen tab")
        await service.enqueue(RemoteCompletion(id: UUID(), sessionID: old, title: "Old again", summary: "Done", completedAt: Date()))
        try await expectFor(phone.deviceToken, after: sentBefore + 6, badge: 2, "A tab alerted again after the open counts again")
        let unknown = try await service.appOpened(installationID: UUID(), serverID: UUID(), fingerprint: "paired")
        precondition(unknown == 0, "An unregistered device just gets 0")

        // State saved by Macs from before alert times still counts its unseen tabs.
        let legacyFile = directory.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: ["subscribers": [], "deliveries": [], "completedIDs": [],
                                                    "unseenSessions": [UUID().uuidString, UUID().uuidString]])
            .write(to: legacyFile)
        let legacy = RemoteNotifications(file: legacyFile, configuration: { configuration }, send: { await recorder.respond($0) })
        let legacyBadge = await legacy.badge()
        precondition(legacyBadge == 2, "Older saved state keeps its unseen tabs")

        print("Remote badges: opening the app resets that device's badge to new activity only; unseen tabs, per-tab dedup, seen updates, on-screen, questions, Mac attention and restart passed")
    }
}
