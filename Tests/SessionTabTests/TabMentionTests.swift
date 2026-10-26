import Foundation

private final class MentionFixtureBackend: Backend {
    var prompts: [String] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}

    func finish(_ text: String) {
        sink?(.textDelta(text))
        sink?(.done)
    }
}

extension SessionTabTests {
    /// @-mentions: the token, the composer's "@" query, matching and encoding, what the model
    /// hears in a tab and in Home, private tabs never named, the Remote fields, plain text for
    /// display, and handoffs refused for child tabs that aren't running.
    @MainActor
    static func testTabMentions() async throws {
        testMentionTokens()
        testMentionComposer()
        try await testMentionRouting()
        print("Tab mentions: tokens, composer, routing, privacy, Remote fields and handoff guard passed")
    }

    static func testMentionTokens() {
        let tv = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let remote = UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!
        precondition(TabMentions.label(for: "  Fix [the]\n TV  ") == "Fix the TV")
        precondition(TabMentions.label(for: " [] ") == "tab")
        precondition(TabMentions.label(for: String(repeating: "x", count: 90)).count == TabMentions.labelLimit)
        precondition(TabMentions.token(label: "Sony TV", id: tv) == "@[Sony TV](cantrip-tab:\(tv.uuidString))")

        let picks = [TabMentions.Pick(label: "TV", id: tv), TabMentions.Pick(label: "TV Remote", id: remote)]
        let encoded = TabMentions.encode("ask @TV and @TV Remote, mail a@TV (@TV) @TVs", mentions: picks)
        precondition(encoded == "ask @[TV](cantrip-tab:\(tv.uuidString)) and @[TV Remote](cantrip-tab:\(remote.uuidString)), "
                     + "mail a@TV (@[TV](cantrip-tab:\(tv.uuidString))) @TVs", encoded)
        let parsed = TabMentions.parse(encoded)
        precondition(parsed.map(\.id) == [tv, remote, tv] && parsed.map(\.label) == ["TV", "TV Remote", "TV"])
        precondition(TabMentions.plain(encoded) == "ask @TV and @TV Remote, mail a@TV (@TV) @TVs")
        precondition(TabMentions.parse("@[TV](cantrip-tab:not-a-uuid) [x](cantrip-tab:\(tv.uuidString))").isEmpty)
        precondition(TabMentions.parse("@[TV](cantrip-tab:\(tv.uuidString.lowercased()))").first?.id == tv)
        precondition(TabMentions.markdown("Ask @[A*b_](cantrip-tab:\(tv.uuidString)) now") == #"Ask **@A\*b\_** now"#)
        precondition(TabMentions.plain("no mentions [here](https://x.y)") == "no mentions [here](https://x.y)")
        precondition(TabMentions.remaining(picks, in: "only @TV Remote here") == [picks[1]])
        precondition(TabMentions.removing(picks[0], from: "ask @TV now, @TV Remote stays", among: picks) == "ask now, @TV Remote stays")
        precondition(TabMentions.remaining(picks, in: "@TV and @TV Remote") == picks)
        precondition(ThreadTags.promptText("Ask @[TV](cantrip-tab:\(tv.uuidString))", sessionID: UUID()) == "Ask @TV")
        precondition(RemoteCompletion.preview("Asked @[TV](cantrip-tab:\(tv.uuidString)).") == "Asked @TV.")
    }

    static func testMentionComposer() {
        func query(_ text: String, caret: Int? = nil) -> String? {
            let index = caret.map { text.index(text.startIndex, offsetBy: $0) }
            return TabMentions.query(in: text, caret: index)?.query
        }
        // Emails and handles inside words never start one; a word start, or one after a bracket, does.
        precondition(query("mail a@b.com") == nil && query("x@handle") == nil)
        precondition(query("@") == "" && query("hi @ba") == "ba" && query("(@tv") == "tv" && query("“@tv") == "tv")
        precondition(query("hi @ ") == nil && query("@a\nb") == nil && query("@[TV](x") == nil && query("", caret: 0) == nil)
        precondition(query("@bass co") == "bass co" && query("@ab cd", caret: 3) == "ab")
        precondition(query("@" + String(repeating: "a", count: 49)) == nil, "too far back")

        let tabs = [
            TabMentions.Candidate(id: UUID(), title: "Sony TV"),
            TabMentions.Candidate(id: UUID(), title: "Bass Compass", workdir: "/tmp/bass-compass"),
            TabMentions.Candidate(id: UUID(), title: "Café Ops"),
            TabMentions.Candidate(id: UUID(), title: "Cantrip", workdir: "/tmp/Cantrip", isStreaming: true),
            TabMentions.Candidate(id: UUID(), title: "Notes file", parentTitle: "Cantrip", needsAnswer: true),
        ]
        func titles(_ query: String) -> [String] { TabMentions.matches(query, in: tabs).map(\.title) }
        precondition(titles("") == tabs.map(\.title))
        precondition(titles("ba") == ["Bass Compass"] && titles("comp") == ["Bass Compass"] && titles("bass c") == ["Bass Compass"])
        precondition(titles("cafe") == ["Café Ops"] && titles("CA") == ["Café Ops", "Cantrip"] && titles("tv") == ["Sony TV"])
        precondition(titles("ass") == ["Bass Compass"] && titles("bass x").isEmpty && titles("bass-c") == ["Bass Compass"])
        precondition(TabMentions.matches("", in: tabs + tabs, limit: 8).count == 8)
        precondition(tabs[1].detail == "bass-compass" && tabs[3].detail == "Working" && tabs[3].project == "Cantrip")
        precondition(tabs[4].detail == "Child of Cantrip · Needs your answer", tabs[4].detail)
        precondition(tabs[4].accessibilityLabel == "Notes file, child of Cantrip, needs your answer")
        precondition(TabMentions.Candidate(id: UUID(), title: "Home", workdir: NSHomeDirectory()).project == nil)

        let text = "Hey @so later"
        let at = text.firstIndex(of: "@")!
        let caret = text.index(at, offsetBy: 3)
        let picked = TabMentions.insert(tabs[0], at: at, caret: caret, in: text)
        precondition(picked.text == "Hey @Sony TV later" && picked.label == "Sony TV", picked.text)
        precondition(picked.text[picked.caret...] == "later", "the caret skips the space that was already there")
        let atEnd = TabMentions.insert(tabs[1], at: "@ba".startIndex, in: "@ba")
        precondition(atEnd.text == "@Bass Compass " && atEnd.caret == atEnd.text.endIndex)

        // After a pick the list stays closed at that "@", so Return sends and typing isn't replaced.
        let sonyPick = [TabMentions.Pick(label: "Sony TV", id: tabs[0].id)]
        for text in ["@Sony TV ", "Ask @Sony TV so", "@Sony TV"] {
            let found = TabMentions.query(in: text)
            precondition(found != nil && TabMentions.isPicked(at: found!.at, in: text, picks: sonyPick), text)
        }
        precondition(!TabMentions.isPicked(at: "@Sony TVs".startIndex, in: "@Sony TVs", picks: sonyPick))
        precondition(!TabMentions.isPicked(at: "@So".startIndex, in: "@So", picks: sonyPick))

        // Same-titled tabs get distinct labels, since a label stands for one ID.
        let twin = TabMentions.Candidate(id: UUID(), title: "Sony TV", workdir: "/tmp/tv-two")
        precondition(TabMentions.uniqueLabel(for: tabs[0], among: sonyPick) == "Sony TV", "re-picking the same tab keeps it")
        precondition(TabMentions.uniqueLabel(for: twin, among: sonyPick) == "Sony TV (tv-two)")
        let bare = TabMentions.Candidate(id: UUID(), title: "Sony TV")
        precondition(TabMentions.uniqueLabel(for: bare, among: sonyPick) == "Sony TV 2")
        let both = sonyPick + [TabMentions.Pick(label: "Sony TV (tv-two)", id: twin.id)]
        let sent = TabMentions.encode("compare @Sony TV with @Sony TV (tv-two)", mentions: both)
        precondition(TabMentions.parse(sent).map(\.id) == [tabs[0].id, twin.id], sent)
        precondition(ChildTabCoordinator.title(from: "Ask \(TabMentions.token(label: "Sony TV", id: tabs[0].id)) what port")
                     == "Ask @Sony TV what port")
    }

    @MainActor
    static func testMentionRouting() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.childTabsAutoFork = false
        defer { (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork) = saved }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-tab-mentions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let manager = SessionManager()
        func addTab(_ name: String) throws -> (ChatSession, MentionFixtureBackend) {
            let backend = MentionFixtureBackend()
            let session = ChatSession(copilotBackend: backend)
            session.workdir = scratch.path
            try session.updateTab(name: name)
            manager.sessions.append(session)
            return (session, backend)
        }
        defer { for session in manager.sessions { session.cancel() } }
        let (planner, plannerBackend) = try addTab("Planner")
        let (tv, _) = try addTab("Sony TV")
        let (secret, _) = try addTab("Secret plans")
        secret.isPrivate = true
        let (child, _) = try addTab("Notes child")
        let (stopped, _) = try addTab("Stopped child")
        var running = ChildTab(id: child.id, parentID: planner.id, queueItemID: UUID(), title: "Notes child",
                               prompt: "Write notes", parentTitle: "Planner", createdAt: Date(), updatedAt: Date())
        running.state = .working
        var finished = ChildTab(id: stopped.id, parentID: tv.id, queueItemID: UUID(), title: "Stopped child",
                                prompt: "Tidy up", parentTitle: "Sony TV", createdAt: Date(), updatedAt: Date())
        finished.state = .stopped
        ChildTabStore.shared.upsert(running)
        ChildTabStore.shared.upsert(finished)
        defer {
            ChildTabStore.shared.remove(child.id)
            ChildTabStore.shared.remove(stopped.id)
        }
        let localPrivate = try requireMention(manager.sessions.first { $0.isLocalPrivate })

        // Who may mention, and who may be suggested: never private tabs, Home or the tab itself.
        precondition(TabMentions.supportsMentions(planner) && TabMentions.supportsMentions(manager.homeSession))
        precondition(!TabMentions.supportsMentions(secret) && !TabMentions.supportsMentions(localPrivate))
        let suggested = TabMentions.candidates(for: planner, in: manager)
        let ids = Set(suggested.map(\.id))
        precondition(ids.isSuperset(of: [tv.id, child.id]) && !ids.contains(planner.id) && !ids.contains(secret.id)
                     && !ids.contains(localPrivate.id) && !ids.contains(ChatSession.cantripHomeID), "\(suggested)")
        precondition(suggested.first { $0.id == child.id }?.parentTitle == "Planner")
        precondition(TabMentions.candidates(for: secret, in: manager).isEmpty)
        precondition(TabMentions.candidates(for: manager.homeSession, in: manager).contains { $0.id == planner.id })

        // A tab hears which tab each mention means, by ID, and how to look into it.
        let unknown = UUID()
        let message = "Ask \(TabMentions.token(label: "Sony TV", id: tv.id)) and \(TabMentions.token(label: "Notes", id: child.id)) "
            + "what port; \(TabMentions.token(label: "Psst", id: secret.id)) \(TabMentions.token(label: "Gone", id: unknown)) "
            + TabMentions.token(label: "Psst", id: localPrivate.id)
        planner.submitRemote(message, mode: .queue)
        try await waitForJournalTest { plannerBackend.prompts.count == 1 }
        let prompt = plannerBackend.prompts[0]
        precondition(prompt.contains("(Tabs the user @mentioned in this message")
                     && prompt.contains("- @Sony TV = “Sony TV” · \(tv.id.uuidString) · open, idle")
                     && prompt.contains("- @Notes = “Notes child” · \(child.id.uuidString) · your own child tab · open, idle")
                     && prompt.contains("tab read <ID>") && prompt.contains("tab ask <ID>") && prompt.contains("tab ask --steer <ID>")
                     && prompt.contains("Don't edit another tab's files") && !prompt.contains("cantrip-delegate"), prompt)
        precondition(prompt.contains("- @Psst: unavailable") && prompt.contains("- @Gone: unavailable")
                     && !prompt.contains(secret.title) && !prompt.contains("“Secret plans”"), prompt)
        precondition(prompt.components(separatedBy: ": unavailable").count == 4, "secret, unknown and Private Local")
        precondition(planner.messages.first { $0.role == .user }?.text == message, "the stored message keeps the IDs")
        precondition(planner.title == "Planner")
        plannerBackend.finish("Asked it.")
        try await waitForJournalTest { !planner.isStreaming }

        // No mention: no note. A mention of a tab that isn't running says it can only be read.
        precondition(TabMentions.notes(for: planner, prompt: "Ask @Sony TV by name", manager: manager) == nil)
        let stoppedNote = try requireMention(TabMentions.notes(
            for: planner, prompt: TabMentions.token(label: "Stopped", id: stopped.id), manager: manager))
        precondition(stoppedNote.contains("child tab of “Sony TV”") && stoppedNote.contains("not running (")
                     && stoppedNote.contains("can't take questions or handoffs") && !stoppedNote.contains("tab ask <ID>"), stoppedNote)
        precondition(TabMentions.notes(for: secret, prompt: message, manager: manager) == nil, "private tabs don't mention")
        let selfNote = try requireMention(TabMentions.notes(for: tv, prompt: TabMentions.token(label: "Me", id: tv.id), manager: manager))
        precondition(selfNote.contains("this tab itself"), selfNote)

        // Home: questions read or ask exactly that tab; change work is a handoff to that ID.
        let homeNote = try requireMention(TabMentions.notes(
            for: manager.homeSession, prompt: "Fix \(TabMentions.token(label: "Sony TV", id: tv.id))", manager: manager))
        precondition(homeNote.contains(tv.id.uuidString) && homeNote.contains("tab ask <ID>")
                     && homeNote.contains("`cantrip-delegate` block whose tabID is that ID") && !homeNote.contains("--steer"), homeNote)
        let many = (0..<7).map { _ in TabMentions.token(label: "X", id: UUID()) }.joined(separator: " ")
        precondition(TabMentions.notes(for: planner, prompt: many, manager: manager)?.contains("2 more mentions ignored") == true)

        // Handoffs never restart a child tab that isn't running (child-tab caps, merges).
        CantripHomeDelegations.shared.attach(manager: manager)
        do {
            _ = try CantripHomeDelegations.shared.dispatch(.init(tabID: stopped.id, summary: "Tidy", prompt: "Tidy the notes file."))
            preconditionFailure("handed work to a stopped child tab")
        } catch let error as CantripHomeError {
            precondition(error.status == 409 && error.message.contains("isn't running"), error.message)
        }

        // Remote: which tabs a composer may suggest, and plain text where people read it.
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func get(_ path: String) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var lastError: Error?
            for _ in 0..<3 {
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            throw lastError!
        }
        let listing = try await get("/api/v1/sessions")
        let sessions = try requireMention(listing["sessions"] as? [[String: Any]])
        func summary(_ id: UUID) -> [String: Any]? { sessions.first { $0["id"] as? String == id.uuidString } }
        precondition(summary(tv.id)?["mentionable"] as? Bool == true && summary(tv.id)?["supportsTabMentions"] as? Bool == true)
        precondition(summary(localPrivate.id)?["mentionable"] as? Bool == false
                     && summary(localPrivate.id)?["supportsTabMentions"] as? Bool == false)
        precondition(summary(secret.id) == nil)
        if let home = listing["home"] as? [String: Any] {
            precondition(home["supportsTabMentions"] as? Bool == true && home["mentionable"] as? Bool == false, "\(home)")
        }
        tv.isStreaming = true
        tv.submitRemote("Then \(TabMentions.token(label: "Planner", id: planner.id)) again", mode: .queue)
        let detail = try requireMention(try await get("/api/v1/sessions/\(tv.id.uuidString)")["session"] as? [String: Any])
        let queued = try requireMention((detail["queued"] as? [[String: Any]])?.last)
        precondition(queued["displayText"] as? String == "Then @Planner again"
                     && (queued["text"] as? String)?.contains("cantrip-tab:\(planner.id.uuidString)") == true, "\(queued)")
        let paged = try requireMention(try await get("/api/v1/sessions/\(tv.id.uuidString)?history=recent")["session"] as? [String: Any])
        precondition((paged["queued"] as? [[String: Any]])?.last?["displayText"] as? String == "Then @Planner again", "\(paged)")
        tv.isStreaming = false
        tv.removeQueued(at: 0)
    }

    private static func requireMention<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
