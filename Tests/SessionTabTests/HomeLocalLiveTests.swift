import Foundation

extension SessionTabTests {
    /// Opt-in, against a real OpenAI-compatible model server (CANTRIP_LOCAL_PROFILE_LIVE_TEST=1 with
    /// CANTRIP_LIVE_LOCAL_URL, CANTRIP_LIVE_LOCAL_MODEL and optionally CANTRIP_LIVE_LOCAL_WINDOW and
    /// CANTRIP_LIVE_TASK_WINDOW). Home chat and a scheduled task, both routed local by the Privacy
    /// Gate, with synthetic data of realistic size, or copies of this Mac's own Home tasks, memory
    /// and Home transcript (CANTRIP_LIVE_REAL_HOME and CANTRIP_LIVE_REAL_MEMORY; read only, copied
    /// into the test's temporary home). Prints what Cantrip estimated; compare it with the server's
    /// own prompt counts.
    @MainActor
    static func testHomeLocalLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_LIVE_LOCAL_URL"], let model = environment["CANTRIP_LIVE_LOCAL_MODEL"] else {
            print("Set CANTRIP_LIVE_LOCAL_URL and CANTRIP_LIVE_LOCAL_MODEL"); return
        }
        let window = Int(environment["CANTRIP_LIVE_LOCAL_WINDOW"] ?? "") ?? 65_536
        func configure(window: Int) throws {
            var local = PrivateLocalConfiguration()
            local.api = .openAI
            local.baseURL = url
            local.model = model
            local.contextWindow = window
            UserDefaults.standard.set(try JSONEncoder().encode(local), forKey: "privateLocalConfiguration")
        }
        try configure(window: window)
        func wait(_ seconds: TimeInterval, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            precondition(condition(), "timed out after \(Int(seconds)) s")
        }

        // A memory vault, tasks and a conversation the size of a real one (synthetic text).
        let settings = AppSettings.shared
        let vault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Live Memory")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let filler = "Example convention about the synthetic build machine and its folders. "
        let realHome = environment["CANTRIP_LIVE_REAL_HOME"].map { URL(fileURLWithPath: $0) }
        let realMemory = environment["CANTRIP_LIVE_REAL_MEMORY"].map { URL(fileURLWithPath: $0) }
        if let realHome {
            try FileManager.default.createDirectory(at: CantripHomeStore.tasksFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: realHome.appendingPathComponent(".cache/Cantrip/home/tasks.json"),
                                             to: CantripHomeStore.tasksFile)
        }
        if let realMemory {
            for file in try FileManager.default.contentsOfDirectory(atPath: realMemory.path) where file.hasSuffix(".md") {
                try FileManager.default.copyItem(at: realMemory.appendingPathComponent(file), to: vault.appendingPathComponent(file))
            }
        } else {
            try ("# MEMORY — env & conventions\n" + String(repeating: "- " + filler + "\n", count: 30))
                .write(to: vault.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
            try ("# USER\n" + String(repeating: "- Example preference about replies and tools.\n", count: 30))
                .write(to: vault.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
            for note in 0..<50 {
                try ("# Example project \(note) (synthetic procedure)\n" + String(repeating: filler, count: 20))
                    .write(to: vault.appendingPathComponent("example-\(note).md"), atomically: true, encoding: .utf8)
            }
        }
        let saved = (settings.backend, settings.memoryEnabled, settings.memoryPath, settings.attachScreen, settings.allowActions)
        defer {
            (settings.backend, settings.memoryEnabled, settings.memoryPath, settings.attachScreen, settings.allowActions) = saved
        }
        settings.backend = .copilot
        settings.memoryEnabled = true
        settings.memoryPath = vault.path
        settings.attachScreen = false
        settings.allowActions = true
        let store = CantripHomeStore.shared
        let zone = TimeZone.current.identifier
        for index in 0..<(realHome == nil ? 30 : 0) {
            _ = try store.create(.init(id: nil, title: "Example check \(index)", prompt: "Check example item \(index) and report changes.",
                                       schedule: .init(kind: .weekdays, summary: "Weekdays 8:00", timeZone: zone,
                                                       weekdays: [2, 3, 4, 5, 6], times: [.init(hour: 8, minute: 0)])))
        }

        let gate = PrivacyGate.shared
        let savedPolicy = gate.policy
        defer { gate.policy = savedPolicy }
        var section = PrivacyGateSettings()
        section.mode = .enforce
        gate.policy = { var document = AgentPolicyDocument(); document.privacyGate = section; return document }

        // Home chat: a credential sends it local; ten earlier turns come along.
        let home = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                               makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        defer { home.cancel() }
        if let realHome {
            let transcript = realHome.appendingPathComponent(".cache/Cantrip/chats/\(ChatSession.cantripHomeID.uuidString).json")
            home.messages = try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: transcript))
        } else {
            home.messages = (0..<10).flatMap { turn in
                [ChatMessage(role: .user, text: "Example question \(turn) about the packing list. " + String(repeating: filler, count: 15)),
                 ChatMessage(role: .assistant, text: "Example answer \(turn). " + String(repeating: filler, count: 25))]
            }
        }
        print("Home data: \(store.tasks.count) tasks, \(home.messages.count) messages")
        gate.resetConversation(ChatSession.privacyHomeConversationKey)
        home.submit("Remind me tomorrow at 9 to rotate \(syntheticSecret) on the example server.")
        try await wait(240) { !home.isStreaming && home.messages.last?.text.isEmpty == false }
        let reply = home.messages.last?.text ?? ""
        print("Home chat reply (\(reply.count) characters): \(reply.prefix(400))")
        precondition(home.messages.last?.role == .assistant && !reply.isEmpty, "the local model answered")

        // A scheduled task set to local: a run with several tool steps over a smaller window.
        let taskWindow = Int(environment["CANTRIP_LIVE_TASK_WINDOW"] ?? "") ?? window
        try configure(window: taskWindow)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("live-task")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in 1...5 {
            try (0..<400).map { "Example log line \($0) of file \(file): synthetic status ok." }.joined(separator: "\n")
                .write(to: folder.appendingPathComponent("log\(file).txt"), atomically: true, encoding: .utf8)
        }
        let task = try store.create(.init(id: nil, title: "Example log review",
                                          prompt: "Read each of the five files in \(folder.path) with run_shell, one `cat` per step "
                                              + "(log1.txt to log5.txt), then report each file's last line.",
                                          schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: Date().addingTimeInterval(86_400))))
        section.tasks[task.id.uuidString] = .local
        let run = ChatSession(copilotBackend: CantripHomeBackendFixture(), cantripHomeRun: true,
                              makeJournal: { try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory) })
        defer { run.cancel() }
        run.submitCantripHomeTask(id: task.id, title: task.title, scheduleSummary: "Once", prompt: task.prompt)
        try await wait(600) { !run.isStreaming }
        let outcome = run.messages.filter { $0.role == .assistant || $0.role == .error }.map(\.text).joined(separator: "\n")
        print("Task run (\(outcome.count) characters): \(outcome.suffix(600))")
        let log = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
        for line in log.split(separator: "\n") where line.contains("privacy:") || line.contains("local run") {
            print("log: \(line)")
        }
        print("Home local live: window \(window), task window \(taskWindow); compare with the server's prompt counts")
    }
}
