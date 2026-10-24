import Foundation

extension SessionTabTests {
    /// `GET /api/v1/voice/vocabulary`: authenticated, read-only, version 1, private tabs excluded.
    @MainActor
    static func testRemoteVoiceVocabulary() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voice-vocabulary-api-\(UUID())")
        let vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "# Plexo rollout\n".write(to: vault.appendingPathComponent("plexo.md"), atomically: true, encoding: .utf8)
        let settings = AppSettings.shared
        let oldPath = settings.memoryPath
        settings.memoryPath = vault.path
        defer { settings.memoryPath = oldPath }

        let manager = SessionManager()
        let named = manager.newSession()
        try named.updateTab(name: "Orbitly launch")
        let secret = manager.newSession()
        try secret.updateTab(name: "Kestrel secret")
        secret.isPrivate = true
        let vocabulary = VoiceVocabularyService(configuration: .init(
            messagesDatabase: root.appendingPathComponent("chat.db"),
            callHistoryDatabase: root.appendingPathComponent("CallHistory.storedata"),
            readsCalendar: false, readsContacts: false))
        let server = RemoteControlServer(manager: manager, voiceVocabulary: vocabulary)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))
        func request(method: String = "GET", auth: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/voice/vocabulary")!)
            request.httpMethod = method
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }

        let (unauthorized, _) = try await request(auth: false)
        precondition(unauthorized == 401, "The vocabulary requires the pairing token")
        for method in ["POST", "PUT", "DELETE"] {
            let (status, _) = try await request(method: method)
            precondition(status == 405, "The vocabulary is read-only")
        }
        let (status, body) = try await request()
        precondition(status == 200 && body["version"] as? Int == 1 && body["generatedAt"] is Double)
        let terms = body["terms"] as! [[String: Any]]
        let texts = terms.map { $0["text"] as! String }
        precondition(terms.contains { $0["text"] as? String == "Orbitly launch" && $0["kind"] as? String == "project" },
                     "Named tabs are project terms: \(texts)")
        precondition(terms.contains { $0["text"] as? String == "Plexo" && $0["kind"] as? String == "note" },
                     "Memory note headings are note terms: \(texts)")
        precondition(!texts.contains { $0.contains("Kestrel") }, "Private tabs never reach the vocabulary")
        precondition(body["people"] as? [[String: Any]] != nil)
        let unavailable = body["unavailable"] as! [String]
        precondition(unavailable.contains("messages: there's no Messages history on this Mac")
                     && unavailable.contains("calls: there's no call history on this Mac"), "\(unavailable)")

        let (_, again) = try await request()
        precondition(again["generatedAt"] as? Double == body["generatedAt"] as? Double, "The vocabulary is cached")
    }
}
