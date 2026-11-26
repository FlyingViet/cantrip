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
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 10
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func request(_ suffix: String, auth: Bool = true, method: String = "GET",
                     body: [String: Any]? = nil) async throws -> (Int, [String: Any], Int) {
            let url = URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)\(suffix)")!
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
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
        let sizable = String(repeating: "Sizable output\n", count: 4_000)
        let exchanges = (0..<5).map { index in
            [ChatMessage(role: .user, text: "Exchange \(index)"),
             ChatMessage(role: .assistant, text: index == 2 ? sizable : "Answer \(index)")]
                + (index == 3 ? (0..<40).map {
                    ChatMessage(role: .assistant, text: "Continuation \($0)", author: "Council")
                } : [])
        }
        chat.messages = exchanges.flatMap { $0 }
        let completeHistory = chat.messages
        let (_, threeResponse, threeBytes) = try await request("?history=recent&recentExchanges=3")
        let three = threeResponse["session"] as! [String: Any]
        let threeMessages = three["messages"] as! [[String: Any]]
        let expectedThree = exchanges.suffix(3).flatMap { $0 }
        precondition(threeMessages.map { $0["id"] as! String } == expectedThree.map { $0.id.uuidString })
        precondition(threeMessages.filter { $0["role"] as? String == "user" }.count == 3)
        precondition(threeMessages.count > RemoteHistory.pageSize && threeBytes < RemoteHistory.recentPageBytes,
                     "Three complete exchanges that fit the newest page's budget survive the count budget")
        for (payload, original) in zip(threeMessages, expectedThree) { expectFull(payload, original: original) }
        precondition(three["hasOlderMessages"] as? Bool == true && chat.messages == completeHistory)
        let (_, previousResponse, _) = try await request(
            "?history=recent&recentExchanges=3&before=\(expectedThree[0].id)"
        )
        let previous = previousResponse["session"] as! [String: Any]
        let previousMessages = previous["messages"] as! [[String: Any]]
        precondition(previousMessages.map { $0["id"] as! String }
                     == exchanges.prefix(2).flatMap { $0 }.map { $0.id.uuidString })
        precondition(previous["hasOlderMessages"] as? Bool == false)
        let (_, normalResponse, _) = try await request("?history=recent")
        let normal = (normalResponse["session"] as! [String: Any])["messages"] as! [[String: Any]]
        precondition(normal.first?["id"] as? String == exchanges[3][0].id.uuidString,
                     "Other clients keep the usual budgeted recent page")

        chat.isStreaming = true
        let (queuedStatus, queuedResponse, _) = try await request(
            "/messages?history=recent&recentExchanges=3", method: "POST",
            body: ["text": "Queued follow-up", "mode": "queue"]
        )
        let queuedSession = queuedResponse["session"] as! [String: Any]
        precondition(queuedStatus == 202 && chat.queued.count == 1)
        precondition((queuedSession["messages"] as! [[String: Any]]).map { $0["id"] as! String }
                     == expectedThree.map { $0.id.uuidString },
                     "Send acknowledgements retain three full exchanges beyond the usual page count")
        let queuedID = chat.queued[0].id
        let unknownID = UUID()
        let (unknownStatus, _, _) = try await request("/queue/\(unknownID)/send", method: "POST", body: [:])
        let (invalidIDStatus, _, _) = try await request("/queue/not-a-uuid/send", method: "POST", body: [:])
        let (getSendStatus, _, _) = try await request("/queue/\(queuedID)/send")
        precondition(unknownStatus == 409 && invalidIDStatus == 400 && getSendStatus == 405
                     && chat.queued.count == 1,
                     "Send now refuses unknown, malformed and non-POST requests without touching the queue")
        precondition(queuedSession["supportsQueueSendNow"] as? Bool == true)
        let (removedStatus, removedResponse, _) = try await request(
            "/queue/\(queuedID)?history=recent&recentExchanges=3", method: "DELETE"
        )
        precondition(removedStatus == 200 && chat.queued.isEmpty)
        precondition(((removedResponse["session"] as! [String: Any])["messages"] as! [[String: Any]])
            .map { $0["id"] as! String } == expectedThree.map { $0.id.uuidString })
        for invalid in ["0", "4", "-1", "invalid"] {
            let (invalidStatus, _, _) = try await request(
                "/messages?history=recent&recentExchanges=\(invalid)", method: "POST",
                body: ["text": "Must not be queued", "mode": "queue"]
            )
            precondition(invalidStatus == 400 && chat.queued.isEmpty && chat.messages == completeHistory,
                         "Reject invalid history options before accepting any mutation")
        }
        chat.isStreaming = false

        chat.messages.append(ChatMessage(role: .user, text: "Waiting for the next reply"))
        let (_, waitingResponse, _) = try await request("?history=recent&recentExchanges=3")
        let waiting = (waitingResponse["session"] as! [String: Any])["messages"] as! [[String: Any]]
        precondition(waiting.first?["id"] as? String == exchanges[3][0].id.uuidString)
        precondition(waiting.last?["role"] as? String == "user", "The active prompt is the newest exchange")
        let (renamedStatus, renamedResponse, _) = try await request(
            "/metadata?history=recent&recentExchanges=3", method: "POST", body: ["customTitle": "Three exchanges"]
        )
        let renamedMessages = (renamedResponse["session"] as! [String: Any])["messages"] as! [[String: Any]]
        precondition(renamedStatus == 200 && renamedMessages.map { $0["id"] as! String }
                     == waiting.map { $0["id"] as! String },
                     "An active prompt counts toward three exchanges in mutation replies too")
        for invalid in ["0", "4", "-1", "invalid"] {
            let (invalidStatus, _, _) = try await request("?history=recent&recentExchanges=\(invalid)")
            precondition(invalidStatus == 400, "The exchange-count opt-in is bounded")
        }
        chat.messages = exchanges.prefix(2).flatMap { $0 }
        let (_, shortResponse, _) = try await request("?history=recent&recentExchanges=3")
        let short = shortResponse["session"] as! [String: Any]
        precondition((short["messages"] as! [[String: Any]]).count == chat.messages.count)
        precondition(short["hasOlderMessages"] as? Bool == false)
        chat.messages = (0..<100).map { ChatMessage(role: .assistant, text: "Legacy \($0)") }
        let (_, ungroupedResponse, _) = try await request("?history=recent&recentExchanges=3")
        precondition(((ungroupedResponse["session"] as! [String: Any])["messages"] as! [[String: Any]]).count
                     == RemoteHistory.pageSize, "Ungrouped legacy messages retain normal bounded paging")
        chat.messages = []
        let (resetStatus, _, _) = try await request("?history=recent&before=\(original[70].id)")
        precondition(resetStatus == 409)
        let (_, emptyResponse, _) = try await request("?history=recent")
        let empty = emptyResponse["session"] as! [String: Any]
        precondition(empty["hasOlderMessages"] as? Bool == false && (empty["messages"] as! [Any]).isEmpty)
        let (_, emptyThreeResponse, _) = try await request("?history=recent&recentExchanges=3")
        let emptyThree = emptyThreeResponse["session"] as! [String: Any]
        precondition(emptyThree["hasOlderMessages"] as? Bool == false && (emptyThree["messages"] as! [Any]).isEmpty)
        try await testRemoteNewestPageBudget(chat: chat, request: request)
        try await testRemoteReasoningSummaries(chat: chat, request: request)
        print("Remote history: three-exchange opt-in, newest-page budget, reasoning summaries, complete prompt-aligned pages, soft budgets, conditional reads, complete paging with new turns arriving, legacy and private access passed")
    }

    typealias HistoryRequest = (_ suffix: String, _ auth: Bool, _ method: String, _ body: [String: Any]?) async throws
        -> (Int, [String: Any], Int)

    /// The newest page holds up to three whole exchanges within `recentPageBytes`, dropping the oldest
    /// first and always keeping the newest whole; `before` cursors then page back to the first message
    /// with no gap or repeat, while new turns arrive between pages.
    @MainActor
    private static func testRemoteNewestPageBudget(chat: ChatSession, request: HistoryRequest) async throws {
        func read(_ suffix: String) async throws -> [String: Any] {
            let (status, response, _) = try await request(suffix, true, "GET", nil)
            precondition(status == 200, "\(suffix) -> \(status)")
            return response["session"] as! [String: Any]
        }
        func ids(_ page: [String: Any]) -> [String] { (page["messages"] as! [[String: Any]]).map { $0["id"] as! String } }
        let big = String(repeating: "Big reply line\n", count: 10_000)
        func exchange(_ index: Int, reply: String? = nil) -> [ChatMessage] {
            [ChatMessage(role: .user, text: "Turn \(index)"), ChatMessage(role: .assistant, text: reply ?? "Answer \(index)")]
        }
        // A large reply two exchanges back: the newest page keeps the two newer exchanges.
        chat.messages = (0..<8).flatMap { exchange($0, reply: $0 == 5 ? big : nil) }
        let original = chat.messages
        var page = try await read("?history=recent&recentExchanges=3")
        precondition(ids(page) == original.suffix(4).map(\.id.uuidString) && page["hasOlderMessages"] as? Bool == true,
                     "A third exchange that doesn't fit stays for the next page")
        // New turns arrive while the reader pages back: cursors don't move, and nothing repeats or goes missing.
        var loaded = ids(page)
        var added: [ChatMessage] = []
        while page["hasOlderMessages"] as? Bool == true {
            let turn = exchange(100 + added.count / 2)
            chat.messages += turn
            added += turn
            page = try await read("?history=recent&recentExchanges=3&before=\(loaded.first!)")
            precondition(!ids(page).isEmpty && Set(ids(page)).isDisjoint(with: loaded))
            loaded = ids(page) + loaded
        }
        precondition(loaded == original.map(\.id.uuidString), "Paging back reaches the first message once, in order")
        // The client's merge: the newest page overlaps what it holds, and the new turns follow.
        let newest = ids(try await read("?history=recent&recentExchanges=3"))
        let overlap = try requireHistory(loaded.firstIndex(of: newest.first!))
        precondition(Array(loaded.prefix(overlap)) + newest == chat.messages.map(\.id.uuidString)
                     && newest.suffix(added.count) == added.map(\.id.uuidString)[...])
        // A newest exchange larger than the budget comes whole, alone.
        chat.messages = (0..<4).flatMap { exchange($0, reply: $0 == 3 ? big + big : nil) }
        page = try await read("?history=recent&recentExchanges=3")
        precondition(ids(page) == chat.messages.suffix(2).map(\.id.uuidString)
                     && (page["messages"] as! [[String: Any]])[1]["text"] as? String == big + big
                     && page["hasOlderMessages"] as? Bool == true)
        // Mutation replies (here: renaming the tab) send the same budgeted page.
        let (renamed, response, _) = try await request("/metadata?history=recent&recentExchanges=3", true, "POST",
                                                       ["customTitle": "Budgeted"])
        precondition(renamed == 200 && ids(response["session"] as! [String: Any]) == ids(page))
    }

    /// `reasoning=summary`: long reasoning comes as step titles with `reasoningBytes` (no `thinking`),
    /// and `…/messages/<id>/reasoning` has the steps in full. Short reasoning and other clients are unchanged.
    @MainActor
    private static func testRemoteReasoningSummaries(chat: ChatSession, request: HistoryRequest) async throws {
        let sections = (1...40).map { "**Checking part \($0)**\n\n" + String(repeating: "Reasoning about part \($0). ", count: 60) }
        var long = ChatMessage(role: .assistant, text: "Long reasoning reply")
        long.thinking = sections.joined(separator: "\n\n")
        long.reasoningStarts = [0]
        var short = ChatMessage(role: .assistant, text: "Short reasoning reply")
        short.thinking = "**Quick check**\n\nOne line."
        short.reasoningStarts = [0]
        chat.messages = [ChatMessage(role: .user, text: "First"), short, ChatMessage(role: .user, text: "Second"), long]
        func message(_ suffix: String, _ index: Int) async throws -> [String: Any] {
            let (status, response, _) = try await request(suffix, true, "GET", nil)
            precondition(status == 200)
            return ((response["session"] as! [String: Any])["messages"] as! [[String: Any]])[index]
        }
        let (_, plainResponse, plainBytes) = try await request("?history=recent&recentExchanges=3&steps=summary", true, "GET", nil)
        let (_, _, summaryBytes) = try await request("?history=recent&recentExchanges=3&steps=summary&reasoning=summary",
                                                     true, "GET", nil)
        let full = ((plainResponse["session"] as! [String: Any])["messages"] as! [[String: Any]])[3]
        precondition(full["thinking"] as? String == long.thinking && full["reasoningBytes"] == nil,
                     "Clients that don't ask keep the reasoning inline")
        let summarized = try await message("?history=recent&recentExchanges=3&reasoning=summary", 3)
        let titles = summarized["reasoning"] as! [[String: Any]]
        let fullSteps = full["reasoning"] as! [[String: Any]]
        precondition(summarized["thinking"] as? String == "" && summarized["reasoningBytes"] as? Int == long.thinking.utf8.count
                     && titles.count == 40 && titles.allSatisfy { ($0["text"] as? String) == "" }
                     && titles.map { $0["title"] as! String } == fullSteps.map { $0["title"] as! String }
                     && titles.map { $0["number"] as! Int } == Array(1...40))
        precondition(summaryBytes * 4 < plainBytes, "Titles instead of text: \(summaryBytes) vs \(plainBytes) bytes")
        let inline = try await message("?history=recent&recentExchanges=3&reasoning=summary", 1)
        precondition(inline["thinking"] as? String == short.thinking && inline["reasoningBytes"] == nil,
                     "Short reasoning stays inline")
        let (status, loaded, _) = try await request("/messages/\(long.id)/reasoning", true, "GET", nil)
        let steps = loaded["reasoning"] as! [[String: Any]]
        precondition(status == 200 && loaded["reasoningBytes"] as? Int == long.thinking.utf8.count && steps.count == 40
                     && zip(steps, fullSteps).allSatisfy {
                         $0["title"] as? String == $1["title"] as? String && $0["text"] as? String == $1["text"] as? String
                             && $0["number"] as? Int == $1["number"] as? Int
                     }, "The full steps match what other clients get inline")
        let (missing, _, _) = try await request("/messages/\(UUID())/reasoning", true, "GET", nil)
        let (post, _, _) = try await request("/messages/\(long.id)/reasoning", true, "POST", [:])
        chat.isPrivate = true
        let (hidden, _, _) = try await request("/messages/\(long.id)/reasoning", true, "GET", nil)
        chat.isPrivate = false
        precondition(missing == 404 && post != 200 && hidden == 404)
        // A streaming reply's reasoning grows: titles keep up, the text stays on the Mac.
        chat.isStreaming = true
        chat.messages[3].thinking += "\n\n**Writing the answer**\n\n" + String(repeating: "More. ", count: 50)
        let live = try await message("?history=recent&recentExchanges=3&reasoning=summary", 3)
        precondition((live["reasoning"] as! [[String: Any]]).last?["title"] as? String == "Writing the answer"
                     && live["reasoningBytes"] as? Int == chat.messages[3].thinking.utf8.count)
        chat.isStreaming = false
    }

    private static func requireHistory<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "RemoteHistoryTests", code: 1) }
        return value
    }
}
