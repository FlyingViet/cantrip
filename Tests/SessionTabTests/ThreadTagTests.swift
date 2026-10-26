import Foundation

extension SessionTabTests {
    /// Thread tags: every message records the prompt that started its thread; Home tags a reply
    /// that belongs to a different thread from the message above it, and serves the thread.
    @MainActor
    static func testThreadTags() async throws {
        let home = ChatSession.cantripHomeID
        func message(_ role: ChatMessage.Role, _ text: String, thread: UUID?) -> ChatMessage {
            var message = ChatMessage(role: role, text: text)
            message.threadID = thread
            return message
        }
        func prompt(_ text: String) -> ChatMessage {
            var message = ChatMessage(role: .user, text: text)
            message.threadID = message.id
            return message
        }
        // The rule: a tag when the thread differs from the message just above.
        let legacy = message(.assistant, "Before threads existed.", thread: nil)
        let book = prompt("we have a book called Designing Data Intensive Applications on our network storage.\nCan you process it?")
        let bookReply = message(.assistant, "I'll find the book on the NAS first.", thread: book.id)
        let tags = prompt("also on the cantrip home, it would be nice if we can show a minimal tag")
        let tagsReply = message(.assistant, "I'm handing this Home feature to the Cantrip tab.", thread: tags.id)
        let empty = message(.assistant, "", thread: tags.id)
        let late = message(.assistant, "Chapters 9 and 12 are done.", thread: book.id)
        let lateMore = message(.assistant, "Chapters 3 and 4 are done too.", thread: book.id)
        let card = message(.handoff, "Cantrip · Done", thread: tags.id)
        let orphan = message(.assistant, "Its prompt is gone.", thread: UUID())
        let unthreadedCard = message(.handoff, "Bass Compass · Done", thread: nil)
        let messages = [legacy, book, bookReply, tags, tagsReply, empty, late, lateMore, card, orphan, unthreadedCard]
        let found = ThreadTags.tags(in: messages, range: messages.indices, sessionID: home)
        precondition(Set(found.keys) == [late.id, card.id],
                     "\(found.keys.map { id in messages.firstIndex { $0.id == id } ?? -1 })")
        precondition(found[late.id]?["id"] as? String == book.id.uuidString
                     && found[late.id]?["prompt"] as? String
                        == "we have a book called Designing Data Intensive Applications on our network storage. Can you process it?",
                     "the tag names the start of the prompt on one line: \(found[late.id] ?? [:])")
        precondition(found[card.id]?["id"] as? String == tags.id.uuidString, "a handoff card is tagged with its thread")
        precondition(ThreadTags.tags(in: messages, range: 6..<7, sessionID: home).keys.first == late.id,
                     "a page computes tags from the message above it, even outside the page")
        precondition(ThreadTags.tags(in: messages, range: messages.indices, sessionID: UUID()).isEmpty,
                     "other tabs record links without tags")
        precondition(ThreadTags.withoutQuestionTitle("Copilot needs your answer\n\nShip it?") == "Ship it?"
                     && ThreadTags.withoutQuestionTitle("Ship it?") == "Ship it?", "a question shows without its title")
        let long = ThreadTags.excerpt(of: String(repeating: "word ", count: 60))
        precondition(long.count <= ThreadTags.excerptLimit + 1 && long.hasSuffix("word…"), long)
        // "N Replies" under a prompt once other messages split its thread: every later shown message counts.
        precondition(ThreadTags.replyCounts(in: messages, sessionID: home) == [book.id: 3, tags.id: 2],
                     "\(ThreadTags.replyCounts(in: messages, sessionID: home))")
        let together = [book, bookReply, late, tags, tagsReply]
        precondition(ThreadTags.replyCounts(in: together, sessionID: home).isEmpty,
                     "a thread whose replies sit right under its prompt shows no count")
        precondition(ThreadTags.replyCounts(in: messages, sessionID: UUID()).isEmpty
                     && ThreadTags.replyCountsObject(in: messages, sessionID: UUID()) == nil, "only Home counts")

        // The thread a tag opens: its prompt and the earlier messages in it, unrelated ones skipped.
        let thread = try requireThread(ThreadTags.thread(book.id, in: messages, before: lateMore.id, sessionID: home,
                                                         visibleText: { $0.text.uppercased() }))
        let items = try requireThread(thread["messages"] as? [[String: Any]])
        precondition((thread["prompt"] as? [String: Any])?["id"] as? String == book.id.uuidString
                     && items.map { $0["id"] as? String } == [bookReply.id.uuidString, late.id.uuidString]
                     && items.first?["text"] as? String == "I'LL FIND THE BOOK ON THE NAS FIRST."
                     && thread["hasEarlier"] as? Bool == false, "\(thread)")
        precondition(ThreadTags.thread(orphan.threadID!, in: messages, before: nil, sessionID: home,
                                       visibleText: \.text) == nil, "a thread whose prompt is gone isn't served")

        // Assignment: prompts start threads; replies, and answers to questions, join theirs.
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen, settings.cantripHomeEnabled)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.cantripHomeEnabled = true
        defer { (settings.backend, settings.memoryEnabled, settings.attachScreen, settings.cantripHomeEnabled) = saved }
        let fixture = CantripHomeBackendFixture()
        let homeChat = ChatSession(id: home, copilotBackend: fixture,
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        defer { homeChat.cancel() }
        homeChat.submitRemote("Start the release watcher")
        try await waitForJournalTest { fixture.sink != nil }
        var watcher = ToolActivityFactory.start(id: "task-release", toolName: "task", arguments: [
            "name": "watch-testflight", "mode": "background", "agent_type": "task",
        ])
        watcher.subagent = SubagentInfo(agentID: "agent-release", name: "watch-testflight", agentType: "task",
                                        summary: "", background: true, startedAt: Date())
        let shell = ToolActivityFactory.start(id: "bash-build", toolName: "bash", arguments: [
            "command": "make app", "mode": "async", "shellId": "build-1",
        ])
        fixture.sink?(.activity(watcher))
        fixture.sink?(.activity(shell))
        // A Home block in the reply that a late result splits off is still saved (here: refused).
        fixture.sink?(.textDelta("The watcher is running.\n\n```cantrip-task\n{\"not\": \"a task\"}\n```"))
        try await waitForJournalTest { homeChat.messages.last?.text.hasPrefix("The watcher is running.") == true }
        let start = try requireThread(homeChat.messages.first { $0.role == .user })
        let first = try requireThread(homeChat.messages.last)
        precondition(start.threadID == start.id && first.threadID == start.id)
        // A later reply's shell 10 must not claim shell 1's result.
        var later = message(.assistant, "Ran the tests.", thread: UUID())
        later.activities = [ToolActivityFactory.complete(nil, id: "bash-tests", toolName: "bash", success: true,
                                                         output: "ok\n<shellId: 10 completed with exit code 0>")]
        var shellOne = ToolActivityFactory.start(id: "bash-one", toolName: "bash", arguments: [
            "command": "make release", "mode": "async",
        ])
        shellOne.output = "<shellId: 1 running>"
        homeChat.messages[homeChat.messages.count - 1].activities.append(shellOne)
        let before = homeChat.messages
        homeChat.messages.append(later)
        precondition(homeChat.backgroundThreadID(for: ["1"]) == start.id
                     && homeChat.backgroundThreadID(for: ["10"]) == later.threadID, "shell IDs match whole values")
        homeChat.messages = before
        precondition(homeChat.backgroundThreadID(for: ["agent-release"]) == start.id
                     && homeChat.backgroundThreadID(for: ["task-release"]) == start.id
                     && homeChat.backgroundThreadID(for: ["build-1"]) == start.id
                     && homeChat.backgroundThreadID(for: ["nothing"]) == nil, "background work is traced to its thread")
        // Home: a late result always opens its own bubble in that thread.
        fixture.sink?(.backgroundWake(["agent-release"]))
        fixture.sink?(.textDelta("The upload finished."))
        try await waitForJournalTest { homeChat.messages.last?.text == "The upload finished." }
        let result = try requireThread(homeChat.messages.last)
        precondition(result.id != first.id && result.threadID == start.id && result.role == .assistant
                     && homeChat.messages.first { $0.id == first.id }?.text == "The watcher is running.",
                     "a late result gets its own bubble, and the closed reply's block was settled: "
                        + (homeChat.messages.first { $0.id == first.id }?.text ?? ""))
        precondition(homeChat.cantripHomeNotices.contains { $0.hasPrefix("Could not save task") },
                     "the closed reply's refused block is reported: \(homeChat.cantripHomeNotices)")
        // A wake while the last reply is still empty (a message on its way to the root) doesn't split.
        let bubbles = homeChat.messages.count
        homeChat.messages.append(message(.assistant, "", thread: UUID()))
        fixture.sink?(.backgroundWake(["agent-release"]))
        try await Task.sleep(for: .milliseconds(200))
        precondition(homeChat.messages.count == bubbles + 1, "an empty reply isn't split from its answer")
        homeChat.messages.removeLast()
        // An answer to a question joins the thread that asked.
        homeChat.recordInputConversation(
            InputRequestSnapshot(id: UUID(), kind: .question, source: "copilot", title: "Ship it?", detail: "",
                                 choices: ["Yes"], expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970),
            answer: "Yes"
        )
        let answer = try requireThread(homeChat.messages.last { $0.role == .user })
        precondition(answer.text == "Yes" && answer.threadID == start.id
                     && homeChat.messages.last?.threadID == start.id, "an answer joins the asking thread")
        fixture.sink?(.done)
        try await waitForJournalTest { !homeChat.isStreaming }

        // Links persist in the transcript and the run journal.
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(result))
        precondition(decoded.threadID == start.id)
        let legacyDecoded = try JSONDecoder().decode(
            ChatMessage.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","text":"Old"}"#.utf8)
        )
        precondition(legacyDecoded.threadID == nil, "older transcripts load without links")
        let runID = UUID()
        var started = RunJournal.Event(sessionID: home, runID: runID, kind: .turnStarted)
        started.prompt = "Start"
        started.mode = .single
        var reply = RunJournal.Event(sessionID: home, runID: runID, kind: .messageStarted)
        reply.messageID = UUID()
        reply.role = "assistant"
        reply.threadID = start.id
        let recovered = RunJournal.recoveryState(from: [started, reply])?.activeRun?.messages.first
        precondition(recovered?.threadID == start.id, "a crash-recovered message keeps its thread")

        // The server: tags on Home's messages, and the thread endpoint.
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        homeChat.messages = messages.filter { $0.id != orphan.id }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        var ready = false
        for _ in 0..<40 where !ready {
            ready = (try? await call("/api/v1/sessions/\(home.uuidString)")) != nil
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        let session = try await call("/api/v1/sessions/\(home.uuidString)")
        let served = try requireThread((session.1["session"] as? [String: Any])?["messages"] as? [[String: Any]])
        let taggedIDs = served.compactMap { item in item["thread"] == nil ? nil : item["id"] as? String }
        precondition(session.0 == 200 && taggedIDs == [late.id.uuidString, card.id.uuidString]
                     && served.first { $0["id"] as? String == bookReply.id.uuidString }?["threadID"] as? String
                        == book.id.uuidString, "\(session.0) \(taggedIDs)")
        precondition((session.1["session"] as? [String: Any])?["threadReplies"] as? [String: Int]
                     == [book.id.uuidString: 3, tags.id.uuidString: 2], "Home's details carry reply counts")
        let single = try await call("/api/v1/sessions/\(home.uuidString)/messages/\(late.id.uuidString)")
        precondition(((single.1["message"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
                     == book.id.uuidString, "a single message carries its tag")
        let opened = try await call("/api/v1/sessions/\(home.uuidString)/threads/\(book.id.uuidString)?before=\(lateMore.id.uuidString)")
        let openedThread = try requireThread(opened.1["thread"] as? [String: Any])
        precondition(opened.0 == 200
                     && ((openedThread["prompt"] as? [String: Any])?["text"] as? String)?.hasPrefix("we have a book") == true
                     && (openedThread["messages"] as? [[String: Any]])?.count == 2, "\(opened)")
        let missing = try await call("/api/v1/sessions/\(home.uuidString)/threads/\(UUID().uuidString)")
        precondition(missing.0 == 404, "an unknown thread is a 404")
        print("Thread tag checks passed")
    }

    private static func requireThread<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
