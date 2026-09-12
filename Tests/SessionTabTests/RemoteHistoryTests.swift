import Foundation

extension SessionTabTests {
    @MainActor
    static func testRemoteHistory() async throws {
        let manager = SessionManager()
        let chat = manager.active
        chat.messages = (0..<100).map { ChatMessage(role: .assistant, text: "Reply \($0)") }
        let largeText = String(repeating: "Large output \u{1F680}\n", count: 100_000)
        chat.messages[99].text = largeText
        chat.messages[99].thinking = largeText
        chat.messages[99].activities = (0..<100).map {
            ToolActivity(id: "tool-\($0)", title: "Tool \($0)", toolName: "bash",
                         state: .succeeded, input: largeText, output: largeText,
                         fileChanges: [], terminalCommand: nil)
        }
        let original = chat.messages
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 10
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func request(_ suffix: String, auth: Bool = true) async throws -> (Int, [String: Any], Int) {
            let url = URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)\(suffix)")!
            var request = URLRequest(url: url)
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any], data.count)
        }
        let (status, response, bytes) = try await request("?history=recent")
        let recent = response["session"] as! [String: Any]
        let messages = recent["messages"] as! [[String: Any]]
        precondition(status == 200 && messages.count == 30)
        precondition(bytes < 192 * 1024, "A huge live turn must not dominate automatic history loads")
        precondition(recent["hasOlderMessages"] as? Bool == true)
        precondition(messages.last?["isPreview"] as? Bool == true)
        precondition((messages.last?["text"] as! String).utf8.count <= 16 * 1024)
        precondition((messages.last?["thinking"] as! String).utf8.count <= 4 * 1024)
        let activities = messages.last?["activities"] as! [[String: Any]]
        precondition(activities.count == 40 && activities.allSatisfy { $0["output"] == nil && $0["input"] == nil })
        precondition(chat.messages == original, "Remote paging must never prune host history")
        let revision = recent["historyRevision"] as! String
        let (_, unchanged, unchangedBytes) = try await request("?history=recent&revision=\(revision)")
        precondition(unchanged["unchanged"] as? Bool == true && unchangedBytes < 100)

        var ids = messages.map { $0["id"] as! String }
        var hasOlder = true
        while hasOlder {
            let (_, response, _) = try await request("?history=recent&before=\(ids.first!)")
            let page = response["session"] as! [String: Any]
            let older = page["messages"] as! [[String: Any]]
            precondition(older.count <= 30 && !older.isEmpty)
            ids = older.map { $0["id"] as! String } + ids
            hasOlder = page["hasOlderMessages"] as! Bool
        }
        precondition(ids == original.map { $0.id.uuidString }, "Paging must restore all messages once, in order")

        // Keep the explicit-detail fixture small enough for the transport's existing 32 MiB ceiling.
        chat.messages[99].activities = Array(chat.messages[99].activities.prefix(1))
        let (_, full, _) = try await request("/messages/\(original[99].id)")
        let fullMessage = full["message"] as! [String: Any]
        precondition(fullMessage["text"] as? String == largeText)
        precondition((fullMessage["activities"] as! [[String: Any]])[0]["output"] as? String == largeText)
        let (_, legacy, _) = try await request("")
        precondition((legacy["session"] as! [String: Any])["messages"] is [[String: Any]])
        precondition(((legacy["session"] as! [String: Any])["messages"] as! [[String: Any]]).count == 100)
        chat.messages[99].thinking += "new thinking"
        let (_, changed, _) = try await request("?history=recent&revision=\(revision)")
        precondition(changed["session"] != nil)
        let contentRevision = (changed["session"] as! [String: Any])["historyRevision"] as! String
        try chat.updateTab(name: "Renamed")
        let (_, renamed, _) = try await request("?history=recent&revision=\(contentRevision)")
        precondition((renamed["session"] as! [String: Any])["title"] as? String == "Renamed")
        chat.messages.append(ChatMessage(role: .assistant, text: "Appended"))
        let (cursorStatus, _, _) = try await request("?history=recent&before=\(original[70].id)")
        precondition(cursorStatus == 200, "Appending must not invalidate older-history cursors")
        let (badStatus, _, _) = try await request("?history=recent&before=invalid")
        precondition(badStatus == 409)
        let (unauthorized, _, _) = try await request("?history=recent", auth: false)
        precondition(unauthorized == 401)
        chat.isPrivate = true
        let (hidden, _, _) = try await request("/messages/\(original[99].id)")
        precondition(hidden == 404)
        chat.isPrivate = false
        chat.messages = []
        let (resetStatus, _, _) = try await request("?history=recent&before=\(original[70].id)")
        precondition(resetStatus == 409)
        let (_, emptyResponse, _) = try await request("?history=recent")
        let empty = emptyResponse["session"] as! [String: Any]
        precondition(empty["hasOlderMessages"] as? Bool == false && (empty["messages"] as! [Any]).isEmpty)
        let unicode = String(repeating: "\u{1F680}", count: 10)
        precondition(RemoteHistory.preview(unicode, bytes: 7) == "\u{1F680}")
        print("Remote history: bounded previews, conditional reads, complete paging, legacy and private access passed")
    }
}
