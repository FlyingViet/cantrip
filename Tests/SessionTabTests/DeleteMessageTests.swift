import Foundation

extension SessionTabTests {
    @MainActor
    static func testDeleteMessage() async throws {
        try testDeleteMessageExchanges()
        try await testDeleteMessageSession()
        try await testDeleteMessageAPI()
        print("Delete message: exchanges, transcript, journal, busy refusal, API and web passed")
    }

    @MainActor
    private static func testDeleteMessageExchanges() throws {
        let chat = ChatSession()
        var first = ChatMessage(role: .user, text: "Plan the weekend")
        first.threadID = first.id
        var firstReply = ChatMessage(role: .assistant, text: "Here's a plan.")
        firstReply.threadID = first.id
        var second = ChatMessage(role: .user, text: "Look up the order code")
        second.threadID = second.id
        var secondReply = ChatMessage(role: .assistant, text: "It's in the receipt email.")
        secondReply.threadID = second.id
        var lateResult = ChatMessage(role: .assistant, text: "The background search finished.")
        lateResult.threadID = first.id
        let untaggedPrompt = ChatMessage(role: .user, text: "Older question")
        let untaggedReply = ChatMessage(role: .assistant, text: "Older answer")
        let untaggedError = ChatMessage(role: .error, text: "Older failure")
        let divider = ChatMessage(role: .freshStart, text: ChatSession.freshStartCaption)
        chat.messages = [untaggedPrompt, untaggedReply, untaggedError, divider,
                         first, firstReply, second, secondReply, lateResult]
        precondition(chat.exchangeIndexes(containing: first.id) == [4, 5, 8],
                     "A prompt goes with its thread, including a late background result")
        precondition(chat.exchangeIndexes(containing: secondReply.id) == [6, 7], "A reply takes its prompt along")
        precondition(chat.exchangeIndexes(containing: untaggedReply.id) == [0, 1, 2],
                     "Untagged history goes up to the next prompt")
        precondition(chat.exchangeIndexes(containing: divider.id) == nil, "Dividers aren't deletable")
        precondition(chat.exchangeIndexes(containing: UUID()) == nil)
    }

    @MainActor
    private static func testDeleteMessageSession() async throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delete-message-\(id)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keptRun = UUID(), deletedRun = UUID()
        var prompt = ChatMessage(role: .user, text: "Find the club order code", runID: deletedRun)
        prompt.threadID = prompt.id
        var reply = ChatMessage(role: .assistant, text: "The club order code is QX-1234.", runID: deletedRun)
        reply.threadID = prompt.id
        var kept = ChatMessage(role: .user, text: "Plan the weekend", runID: keptRun)
        kept.threadID = kept.id
        var keptReply = ChatMessage(role: .assistant, text: "Here's a plan.", runID: keptRun)
        keptReply.threadID = kept.id

        // The journal as Cantrip left it: both runs finished.
        let seed = try RunJournal(sessionID: id, directory: directory)
        for (run, messages) in [(keptRun, [kept, keptReply]), (deletedRun, [prompt, reply])] {
            var start = RunJournal.Event(sessionID: id, runID: run, kind: .turnStarted)
            start.prompt = messages[0].text
            try seed.append(start)
            for message in messages {
                var event = RunJournal.Event(sessionID: id, runID: run, kind: .messageStarted)
                event.messageID = message.id
                event.role = message.role.rawValue
                event.text = message.text
                try seed.append(event)
            }
            var tool = RunJournal.Event(sessionID: id, runID: run, kind: .toolActivity)
            tool.messageID = messages[1].id
            let found = run == deletedRun ? "QX-1234" : "weekend.md"
            tool.activity = RunJournal.Activity(id: "t", title: "grep", toolName: "bash", state: "done",
                                                input: "grep \(found)", output: found, fileChanges: [],
                                                terminalCommand: nil, children: [])
            try seed.append(tool)
            var result = RunJournal.Event(sessionID: id, runID: run, kind: .result)
            result.status = "succeeded"
            try seed.append(result)
        }
        let journalURL = seed.fileURL

        let chat = ChatSession(id: id, makeJournal: { try RunJournal(sessionID: $0, directory: directory) })
        defer { chat.deleteTranscript() }
        chat.messages = [kept, keptReply, prompt, reply]
        chat.persistTranscript()
        precondition(chat.deleteMessageUnavailableReason == nil)

        chat.isStreaming = true
        do {
            try chat.deleteExchange(containing: reply.id)
            preconditionFailure("A busy tab must not delete messages")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        chat.isStreaming = false
        do {
            try chat.deleteExchange(containing: UUID())
            preconditionFailure("An unknown message can't be deleted")
        } catch let error as SessionModelSettingsError { precondition(error.status == 404) }

        let deleted = try chat.deleteExchange(containing: reply.id)
        precondition(Set(deleted) == [prompt.id, reply.id] && chat.messages == [kept, keptReply],
                     "Deleting the reply removes it and its prompt")
        precondition(chat.deletedMessageIDs == [prompt.id, reply.id], "Clients are told what went")
        try await chat.flushJournal()
        let journal = String(decoding: try Data(contentsOf: journalURL), as: UTF8.self)
        precondition(!journal.contains("QX-1234") && !journal.contains("club order")
                     && journal.contains("Plan the weekend"),
                     "The journal loses the deleted run and keeps the other")

        let restored = ChatSession(id: id, makeJournal: { try RunJournal(sessionID: $0, directory: directory) })
        precondition(restored.messages == [kept, keptReply] && restored.deletedMessageIDs == [prompt.id, reply.id],
                     "The deletion survives a relaunch")
        precondition(!restored.canResume && restored.queued.isEmpty)

        let home = ChatSession(id: ChatSession.cantripHomeID)
        precondition(home.deleteMessageUnavailableReason == nil, "Cantrip Home's chat can delete messages")
    }

    @MainActor
    private static func testDeleteMessageAPI() async throws {
        let manager = SessionManager()
        let chat = manager.newSession()
        var prompt = ChatMessage(role: .user, text: "What's the order code?")
        prompt.threadID = prompt.id
        var reply = ChatMessage(role: .assistant, text: "It's QX-1234.")
        reply.threadID = prompt.id
        let kept = ChatMessage(role: .user, text: "Thanks")
        chat.messages = [prompt, reply, kept]
        defer { manager.close(chat.id) }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ suffix: String, method: String = "GET", body: Data? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)\(suffix)")!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var lastError: Error?
            for _ in 0..<3 {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    return ((response as! HTTPURLResponse).statusCode,
                            try JSONSerialization.jsonObject(with: data) as! [String: Any])
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            throw lastError!
        }
        let loaded = try await request("")
        let session = loaded.1["session"] as! [String: Any]
        precondition(session["supportsDeleteMessage"] as? Bool == true && session["deletedMessageIDs"] == nil)
        let bad = try await request("/delete-message", method: "POST", body: Data(#"{"messageID":"nope"}"#.utf8))
        precondition(bad.0 == 400 && chat.messages.count == 3)
        let extra = try await request("/delete-message", method: "POST",
                                      body: Data(#"{"messageID":"\#(prompt.id)","all":true}"#.utf8))
        precondition(extra.0 == 400)
        let gone = try await request("/delete-message", method: "POST",
                                     body: Data(#"{"messageID":"\#(UUID().uuidString)"}"#.utf8))
        precondition(gone.0 == 404 && (gone.1["error"] as? String)?.contains("no longer") == true)
        chat.isStreaming = true
        let busy = try await request("/delete-message", method: "POST",
                                     body: Data(#"{"messageID":"\#(prompt.id)"}"#.utf8))
        precondition(busy.0 == 409 && chat.messages.count == 3)
        chat.isStreaming = false

        let deleted = try await request("/delete-message", method: "POST",
                                        body: Data(#"{"messageID":"\#(prompt.id)"}"#.utf8))
        precondition(deleted.0 == 200, "\(deleted)")
        let after = deleted.1["session"] as! [String: Any]
        let messages = (after["messages"] as! [[String: Any]]).compactMap { $0["id"] as? String }
        precondition(messages == [kept.id.uuidString], "\(messages)")
        precondition(after["deletedMessageIDs"] as? [String] == [prompt.id.uuidString, reply.id.uuidString])

        let (pageData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let page = String(decoding: pageData, as: UTF8.self)
        precondition(page.contains("function appendDeleteMessage") && page.contains("/delete-message")
                     && page.contains("Delete this message?") && page.contains("deletedMessageIDs"),
                     "The browser and Mac Remote offer Delete and drop deleted messages from cached pages")
    }
}
