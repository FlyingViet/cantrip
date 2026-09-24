import CryptoKit
import Foundation

private actor NotificationRequests {
    var requests: [URLRequest] = []
    var status = 200
    func count() -> Int { requests.count }
    func first() -> URLRequest? { requests.first }
    func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(#"{"reason":"Unregistered"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func setStatus(_ status: Int) { self.status = status }
}

extension SessionTabTests {
    @MainActor
    static func testRemoteNotifications() async throws {
        precondition(RemoteCompletion.preview("## Completed\n\n**Fixed** the [login](https://example.com).") == "Completed Fixed the login.")
        precondition(RemoteCompletion.preview("```swift\nsecret()\n```") == "The response is ready. Open the tab for details.")
        precondition(RemoteCompletion.preview(String(repeating: "a", count: 500)).count == 220)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("push-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let jwt = try configuration.authorization(now: Date(timeIntervalSince1970: 1234567890))
        let parts = jwt.split(separator: ".")
        precondition(parts.count == 3)
        func decoded(_ value: Substring) -> Data {
            let value = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))!
        }
        let claims = try JSONSerialization.jsonObject(with: decoded(parts[1])) as! [String: Any]
        precondition(claims["iat"] as? Int == 1234567890 && claims["iss"] as? String == "TESTTEAM12")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded(parts[2]))
        precondition(configuration.key.publicKey.isValidSignature(
            signature,
            for: Data("\(parts[0]).\(parts[1])".utf8)))

        let recorder = NotificationRequests()
        let service = RemoteNotifications(file: file, configuration: { configuration }, send: { await recorder.respond($0) })
        let registration = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
                                                 deviceToken: String(repeating: "a", count: 64), environment: "production")
        precondition(registration.isValid)
        precondition(!RemotePushRegistration(installationID: UUID(), serverID: UUID(), deviceToken: "../bad", environment: "production").isValid)
        await service.activate(fingerprint: "paired")
        try await service.register(registration, fingerprint: "paired")
        let event = RemoteCompletion(id: UUID(), sessionID: UUID(), title: "Release", summary: "Published the changes.", completedAt: Date())
        await service.enqueue(event)
        for _ in 0..<100 {
            if await recorder.count() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await recorder.first()!
        precondition(sent.url?.host == "api.push.apple.com")
        precondition(sent.value(forHTTPHeaderField: "apns-topic") == "com.itzhoang.hermbot")
        precondition(sent.value(forHTTPHeaderField: "apns-collapse-id") == event.id.uuidString)
        precondition(sent.value(forHTTPHeaderField: "apns-push-type") == "alert")
        let payload = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: Any]
        let aps = payload["aps"] as! [String: Any]
        let alert = aps["alert"] as! [String: String]
        precondition(alert["body"] == event.summary && alert["subtitle"] == event.title)
        let route = payload["cantrip"] as! [String: String]
        precondition(route["sessionID"] == event.sessionID.uuidString && route["serverID"] == registration.serverID.uuidString)
        await service.enqueue(event)
        try await Task.sleep(for: .milliseconds(100))
        let count = await recorder.count()
        precondition(count == 1, "The same completion is not sent twice")
        await service.activate(fingerprint: nil)
        let restored = RemoteNotifications(file: file, configuration: { configuration }, send: { await recorder.respond($0) })
        await restored.activate(fingerprint: "paired")
        await restored.enqueue(event)
        try await Task.sleep(for: .milliseconds(100))
        let restoredCount = await recorder.count()
        precondition(restoredCount == 1, "Dedup survives host restart")
        try await restored.unregister(installationID: registration.installationID, serverID: registration.serverID, fingerprint: "paired")
        await restored.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "No subscribers", summary: "Done", completedAt: Date()))
        try await Task.sleep(for: .milliseconds(100))
        let removedCount = await recorder.count()
        precondition(removedCount == 1)
        await restored.activate(fingerprint: nil)

        let missing = RemoteNotifications(file: directory.appendingPathComponent("missing.json"), configuration: {
            throw RemotePushError(status: 503, message: "Configure Apple push first.")
        })
        let unavailable = await missing.status()
        precondition(!unavailable.configured)
        do {
            try await missing.register(registration, fingerprint: "paired")
            preconditionFailure("Missing provider credentials cannot claim registration succeeded")
        } catch let error as RemotePushError { precondition(error.status == 503) }

        let invalidRecorder = NotificationRequests()
        await invalidRecorder.setStatus(410)
        let invalid = RemoteNotifications(file: directory.appendingPathComponent("invalid.json"),
                                          configuration: { configuration }, send: { await invalidRecorder.respond($0) })
        try await invalid.register(registration, fingerprint: "paired")
        await invalid.activate(fingerprint: "paired")
        await invalid.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "Invalid token", summary: "Done", completedAt: Date()))
        try await Task.sleep(for: .milliseconds(150))
        await invalid.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "Do not retry", summary: "Done", completedAt: Date()))
        try await Task.sleep(for: .milliseconds(150))
        let invalidCount = await invalidRecorder.count()
        precondition(invalidCount == 1, "APNs invalidation removes the token")
        let invalidStatus = await invalid.status()
        precondition(invalidStatus.lastDeliveryError != nil)
        await invalid.activate(fingerprint: nil)

        let retryRecorder = NotificationRequests()
        await retryRecorder.setStatus(500)
        let retry = RemoteNotifications(file: directory.appendingPathComponent("retry/state.json"),
                                        configuration: { configuration }, send: { await retryRecorder.respond($0) })
        try await retry.register(registration, fingerprint: "paired")
        await retry.activate(fingerprint: "paired")
        await retry.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "Retry later", summary: "Done", completedAt: Date()))
        try await Task.sleep(for: .milliseconds(150))
        await retryRecorder.setStatus(200)
        await retry.enqueue(RemoteCompletion(id: UUID(), sessionID: UUID(), title: "New work", summary: "Done", completedAt: Date()))
        try await Task.sleep(for: .milliseconds(150))
        let retryCount = await retryRecorder.count()
        precondition(retryCount == 2, "New completions must wake a sleeping retry worker")
        try await retry.unregister(installationID: registration.installationID, serverID: registration.serverID, fingerprint: "paired")
        await retry.activate(fingerprint: nil)

        AppSettings.shared.memoryEnabled = false
        AppSettings.shared.voiceMode = false
        let chat = ChatSession()
        var completed: [RemoteCompletion] = []
        chat.onRunFinished = {
            if let completion = chat.remoteCompletion { completed.append(completion) }
        }
        chat.submitRemote("! /bin/sleep 0.1; /usr/bin/printf first")
        chat.submitRemote("! /usr/bin/printf 'Finished queued work'", mode: .queue)
        try await waitForJournalTest { !chat.isStreaming && chat.queued.isEmpty && !completed.isEmpty }
        precondition(completed.count == 1)
        let results = RunJournal.loadEvents(from: RunJournal.defaultDirectory.appendingPathComponent("\(chat.id).jsonl"))
            .filter { $0.kind == .result }
        precondition(results.count == 2 && completed[0].id == results.last?.runID,
                     "Only the final queued run is announced")
        chat.submitRemote("! /usr/bin/false")
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.remoteCompletion == nil && completed.count == 1, "Failure cannot reuse a previous successful reply")
        chat.submitRemote("! /bin/sleep 1")
        chat.cancel()
        precondition(chat.remoteCompletion == nil && completed.count == 1)
        chat.isPrivate = true
        chat.submitRemote("! /usr/bin/printf secret")
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.remoteCompletion == nil && completed.count == 1, "Private work never produces a push preview")
        try await testRemoteNotificationEndpoint(directory: directory, configuration: configuration)
        print("Remote notifications: final summaries, JWT, APNs payload, durable dedup, opt-out, invalidation, queue, failure, stop and privacy passed")
    }

    @MainActor
    static func testRemoteNotificationEndpoint(directory: URL, configuration: RemotePushConfiguration) async throws {
        let recorder = NotificationRequests()
        let push = RemoteNotifications(file: directory.appendingPathComponent("endpoint/state.json"),
                                       configuration: { configuration }, send: { await recorder.respond($0) })
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager, notifications: push)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ method: String, auth: Bool = true, body: Data? = nil) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/notifications")!)
            request.httpMethod = method
            request.httpBody = body
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await client.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        let unauthorized = try await request("GET", auth: false)
        let unsupported = try await request("PATCH")
        let malformed = try await request("POST", body: Data("{}".utf8))
        let oversized = try await request("POST", body: Data(repeating: 32, count: 4097))
        precondition(unauthorized == 401 && unsupported == 405 && malformed == 400 && oversized == 413)
        let registration = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
                                                  deviceToken: String(repeating: "b", count: 64), environment: "development")
        let registered = try await request("POST", body: JSONEncoder().encode(registration))
        precondition(registered == 200)
        let chat = manager.active
        chat.onRunFinished = { server.notifyCompletion(for: chat) }
        chat.submitRemote("! /usr/bin/printf completed")
        try await waitForJournalTest { !chat.isStreaming }
        for _ in 0..<100 {
            if await recorder.count() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await recorder.first()
        precondition(sent?.url?.host == "api.sandbox.push.apple.com")
        server.notifyCompletion(for: chat)
        try await Task.sleep(for: .milliseconds(50))
        let sentCount = await recorder.count()
        precondition(sentCount == 1)
        let removal = try JSONSerialization.data(withJSONObject: [
            "installationID": registration.installationID.uuidString, "serverID": registration.serverID.uuidString
        ])
        let removed = try await request("DELETE", body: removal)
        precondition(removed == 200)
        chat.submitRemote("! /usr/bin/true")
        try await waitForJournalTest { !chat.isStreaming }
        try await Task.sleep(for: .milliseconds(50))
        let finalCount = await recorder.count()
        precondition(finalCount == 1, "Opt-out stops subsequent completions")
        chat.onRunFinished = nil
    }
}
