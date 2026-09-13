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
            ToolActivity(id: "tool-\($0)", title: "Tool \($0) " + String(repeating: "x", count: 600), toolName: "bash",
                         state: .succeeded, input: "Input \($0)", output: $0 == 0 ? largeText : "Output \($0)",
                         fileChanges: [], terminalCommand: nil)
        }
        chat.messages[50].text = largeText
        chat.messages[50].thinking = largeText
        chat.messages[50].activities = chat.messages[99].activities
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
        precondition(status == 200 && messages.count == 1)
        precondition(bytes > RemoteHistory.pageBytes, "A complete message may exceed the soft page budget")
        precondition(recent["hasOlderMessages"] as? Bool == true)
        func expectFull(_ payload: [String: Any], original: ChatMessage) {
            precondition(payload["isPreview"] as? Bool != true)
            precondition(payload["text"] as? String == original.text)
            precondition(payload["thinking"] as? String == original.thinking)
            let activities = payload["activities"] as! [[String: Any]]
            precondition(activities.count == original.activities.count)
            for (activity, original) in zip(activities, original.activities) {
                precondition(activity["title"] as? String == original.title)
                precondition(activity["input"] as? String == original.input)
                precondition(activity["output"] as? String == original.output)
            }
        }
        expectFull(messages[0], original: original[99])
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
            let encodedBytes = try older.reduce(0) { try $0 + JSONSerialization.data(withJSONObject: $1).count }
            precondition(older.count == 1 || encodedBytes <= RemoteHistory.pageBytes)
            for message in older {
                expectFull(message, original: original.first { $0.id.uuidString == message["id"] as? String }!)
            }
            ids = older.map { $0["id"] as! String } + ids
            hasOlder = page["hasOlderMessages"] as! Bool
        }
        precondition(ids == original.map { $0.id.uuidString }, "Paging must restore all messages once, in order")

        let (_, full, _) = try await request("/messages/\(original[99].id)")
        let fullMessage = full["message"] as! [String: Any]
        expectFull(fullMessage, original: original[99])
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
        let oversized = String(repeating: "Complete output\n", count: 20_000)
        let paired = [
            ChatMessage(role: .user, text: "Earlier prompt"),
            ChatMessage(role: .assistant, text: oversized),
            ChatMessage(role: .user, text: "Current prompt"),
            ChatMessage(role: .assistant, text: oversized),
        ]
        let council = [ChatMessage(role: .user, text: "Compare these answers")]
            + (0..<35).map { ChatMessage(role: .assistant, text: "Council answer \($0)") }
        let countBoundary = (0..<11).flatMap { index in [
            ChatMessage(role: .user, text: "Prompt \(index)"),
            ChatMessage(role: .assistant, text: "First answer \(index)"),
            ChatMessage(role: .assistant, text: "Second answer \(index)"),
        ] } + [ChatMessage(role: .user, text: "Pending prompt")]
        let hugePrompt = [
            ChatMessage(role: .user, text: oversized),
            ChatMessage(role: .assistant, text: "Answer to a large prompt"),
        ]
        for (fixture, expectedRecentCount) in [(paired, 2), (council, 36), (countBoundary, 31),
                                               (hugePrompt, 2)] {
            chat.messages = fixture
            var loadedIDs: [String] = []
            var before = ""
            repeat {
                let (pageStatus, response, _) = try await request("?history=recent\(before)")
                precondition(pageStatus == 200)
                let page = response["session"] as! [String: Any]
                let messages = page["messages"] as! [[String: Any]]
                precondition(messages.first?["role"] as? String == "user",
                             "Every response group must include its prompt, even across size/count limits")
                if before.isEmpty {
                    precondition(messages.count == expectedRecentCount)
                }
                for message in messages {
                    expectFull(message, original: fixture.first { $0.id.uuidString == message["id"] as? String }!)
                }
                let pageIDs = messages.map { $0["id"] as! String }
                loadedIDs = pageIDs + loadedIDs
                precondition(page["hasOlderMessages"] as? Bool == (loadedIDs.count < fixture.count))
                before = "&before=\(pageIDs.first!)"
            } while loadedIDs.count < fixture.count
            precondition(loadedIDs == fixture.map { $0.id.uuidString },
                         "Prompt-aligned cursors must not skip or duplicate messages")
            precondition(chat.messages == fixture)
        }
        chat.messages = []
        let (resetStatus, _, _) = try await request("?history=recent&before=\(original[70].id)")
        precondition(resetStatus == 409)
        let (_, emptyResponse, _) = try await request("?history=recent")
        let empty = emptyResponse["session"] as! [String: Any]
        precondition(empty["hasOlderMessages"] as? Bool == false && (empty["messages"] as! [Any]).isEmpty)
        print("Remote history: complete prompt-aligned pages, soft budgets, conditional reads, complete paging, legacy and private access passed")
    }
}
