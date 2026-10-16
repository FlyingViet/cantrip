import Foundation

extension SessionTabTests {
    /// Tab lists get each tab's age and latest outcome without changing its history revision.
    @MainActor
    static func testTabListPreviews() async throws {
        let manager = SessionManager()
        let finished = manager.newSession()
        finished.messages = [
            ChatMessage(role: .user, text: "Ship the Builds tab"),
            ChatMessage(role: .assistant, text: "I'll check the OTA page first.\n\nOutcome: Builds tab\nshipped in TF 100135."),
        ]
        finished.persistTranscript()
        let empty = manager.newSession()
        let working = manager.newSession()
        working.messages = [
            ChatMessage(role: .user, text: "Go"),
            ChatMessage(role: .assistant, text: "Outcome: an earlier run's result."),
        ]
        working.isStreaming = true
        defer { working.isStreaming = false }

        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func list() async throws -> [String: [String: Any]] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions")!)
            request.timeoutInterval = 3
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as! HTTPURLResponse).statusCode == 200)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let rows = object["sessions"] as! [[String: Any]]
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as! String, $0) })
        }

        let listed = try await list()
        let row = listed[finished.id.uuidString]!
        precondition(row["preview"] as? String == "Builds tab shipped in TF 100135.",
                     "A tab's preview is its reply's outcome, on one line")
        let age = Date().timeIntervalSince1970 - (row["lastActivityAt"] as? Double ?? 0)
        precondition((-5...60).contains(age), "A tab without a recorded run uses its transcript's time")
        precondition(listed[empty.id.uuidString]?["preview"] == nil, "A tab with no reply has no preview")
        precondition(listed[working.id.uuidString]?["preview"] == nil,
                     "A working tab shows its live status instead of an earlier outcome")
        precondition(row["messages"] == nil)

        let revision = row["historyRevision"] as? String
        let relisted = try await list()
        precondition(relisted[finished.id.uuidString]?["historyRevision"] as? String == revision
                     && relisted[finished.id.uuidString]?["preview"] as? String == "Builds tab shipped in TF 100135.",
                     "Listing again keeps the revision and the cached preview")
        let edited = ChatSession(id: UUID())
        edited.messages = [ChatMessage(role: .assistant, text: "Outcome: first.")]
        precondition(edited.tabPreview() == "First.")
        edited.messages[0].text = "Outcome: second."
        precondition(edited.tabPreview() == "Second.", "A changed reply refreshes the cached preview")
        for chat in [finished, empty, working] { chat.deleteTranscript() }
    }
}
