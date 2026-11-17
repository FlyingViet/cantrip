import Foundation

extension SessionTabTests {
    /// Local-tools shadow runs (CantripHomeShadow): after a covered real run, the task runs again on
    /// the local model with read-only tools against the pre-run snapshot; blocks are captured, never
    /// applied, and the real run's records stay exactly as it left them. Synthetic data only.
    @MainActor
    static func testCantripHomeShadow() async throws {
        // Read-only tools only: no Bitwarden, nothing that can change or send.
        for tool in ["mail_read", "mail_search", "messages_read", "messages_chats", "calendar_events",
                     "contacts_lookup", "personal_status", "firefly_spending", "firefly_transactions",
                     "ha_states", "ha_history", "bass_compass_expenses", "paperless_search"] {
            precondition(CantripHomeShadowTools.isReadOnly(server: "personal", tool: tool), tool)
        }
        for tool in ["mail_send", "create_item", "update-event", "delete_record", "run_script", "turn_on",
                     "set_state", "edit.item", "sync"] {
            precondition(!CantripHomeShadowTools.isReadOnly(server: "homelab", tool: tool), tool)
        }
        precondition(!CantripHomeShadowTools.isReadOnly(server: "bitwarden", tool: "get")
                     && !CantripHomeShadowTools.isReadOnly(server: "Bitwarden", tool: "list"))

        // The configuration: listed tasks, until the end date; defaults for the rest.
        let covered = UUID(), other = UUID(), waiter = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(CantripHomeShadowConfig.self, from: Data("""
            {"tasks":["\(covered.uuidString.lowercased())"],"until":"2030-01-01T00:00:00Z",
             "waitForTasks":["\(waiter.uuidString)"],"temperature":0.2,"reasoningEffort":"low",
             "recordsTool":true,"validateRecords":true,"instructions":"Change a field only with new evidence."}
            """.utf8))
        let end = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        precondition(parsed.covers(covered, at: end) && !parsed.covers(covered, at: end.addingTimeInterval(1))
                     && !parsed.covers(other, at: Date()) && parsed.waits(for: waiter) && !parsed.waits(for: covered)
                     && parsed.servers == ["personal", "homelab"] && parsed.maxSteps == 40 && parsed.afterRun.isEmpty
                     && parsed.priority == "background" && parsed.temperature == 0.2 && parsed.reasoningEffort == "low"
                     && parsed.recordsTool && parsed.validateRecords && parsed.keepTranscript
                     && parsed.instructions == "Change a field only with new evidence."
                     && CantripHomeShadowConfig().temperature == nil && !CantripHomeShadowConfig().recordsTool,
                     "Shadow runs cover only the listed tasks until the end date")
        precondition(CantripHomeShadowConfig.load(from: URL(fileURLWithPath: "/nonexistent/config.json")) == nil,
                     "No configuration file means no shadow runs")

        // Calls: offered read-only tools run; the shell, write tools and Bitwarden are refused.
        let offered = [
            CantripHomeShadowTools.Tool(server: "personal", name: "mail_read", description: "Read a message",
                                        schema: ["type": "object", "properties": [String: Any]()]),
            CantripHomeShadowTools.Tool(server: "personal", name: "mail_send", description: "Send", schema: [:]),
            CantripHomeShadowTools.Tool(server: "bitwarden", name: "get", description: "Get", schema: [:]),
        ]
        var config = CantripHomeShadowConfig()
        config.until = Date().addingTimeInterval(3600)
        config.maxSteps = 5
        let probe = CantripHomeShadowTools(config: config, tools: offered)
        var toolArguments: [[String: Any]] = []
        probe.caller = { server, tool, arguments in
            toolArguments.append(arguments)
            return ("Synthetic: \(server)/\(tool) says Example Co replied.", true)
        }
        let names = probe.openAITools().compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        precondition(names == ["mcp__personal__mail_read"], "Only read-only tools are offered: \(names)")
        precondition(probe.call("run_shell", arguments: ["command": "ls"]).allowed == false
                     && probe.call("mcp__personal__mail_send", arguments: [:]).allowed == false
                     && probe.call("mcp__bitwarden__get", arguments: [:]).allowed == false
                     && toolArguments.isEmpty, "Shell, write and Bitwarden calls never run")
        let read = probe.call("mcp__personal__mail_read", arguments: ["id": "1"])
        precondition(read.allowed && read.success && read.output.contains("Example Co") && toolArguments.count == 1)

        // End to end through the background runner, on a loopback local model.
        let settings = AppSettings.shared
        let memory = settings.memoryEnabled, homeEnabled = settings.cantripHomeEnabled, backend = settings.backend
        let originalConfig = UserDefaults.standard.data(forKey: "privateLocalConfiguration")
        let store = CantripHomeStore.shared
        let previousConfig = store.runner.shadowConfig, previousRoot = store.runner.shadowRoot
        let previousMakeSession = store.runner.makeSession
        let fixture = try PrivateOllamaFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-shadow-\(UUID().uuidString)")
        defer {
            settings.memoryEnabled = memory
            settings.cantripHomeEnabled = homeEnabled
            settings.backend = backend
            UserDefaults.standard.set(originalConfig, forKey: "privateLocalConfiguration")
            store.runner.shadowConfig = previousConfig
            store.runner.shadowRoot = previousRoot
            store.runner.shadowTools = nil
            store.runner.makeSession = previousMakeSession
            fixture.stop()
            try? FileManager.default.removeItem(at: root)
        }
        settings.memoryEnabled = false
        settings.backend = .copilot
        var local = PrivateLocalConfiguration()
        local.api = .openAI
        local.baseURL = try await fixture.start() + "/v1"
        local.model = "Fixture-8B-4bit"
        UserDefaults.standard.set(try JSONEncoder().encode(local), forKey: "privateLocalConfiguration")
        fixture.mode = "openai-shadow"

        let zone = "America/Los_Angeles"
        for task in store.tasks where task.isScheduled && task.enabled {
            _ = try store.update(id: task.id, update: .init(title: nil, prompt: nil, enabled: false))
        }
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture())
        let log = ChatSession(id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture())
        log.messages = []
        let manager = SessionManager(homeSession: homeChat, homeBackgroundSession: log)
        let pool = CantripHomeRunPool()
        store.runner.makeSession = { id in
            let backend = CantripHomeBackendFixture()
            pool.fixtures.append((id, backend))
            return ChatSession(id: id, copilotBackend: backend, cantripHomeRun: true, makeJournal: {
                try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory)
            })
        }
        store.attach(manager: manager)

        let fields = try JSONDecoder().decode(CantripHomeTaskWorkspaceProposal.self, from: Data(#"""
            {"recordLabel":"Thread","recordLabelPlural":"Threads","icon":"envelope",
             "fields":[{"key":"name","label":"Name","kind":"text","required":true,"options":null},
                       {"key":"status","label":"Status","kind":"choice","required":true,"options":["Waiting","Replied","Closed"]}],
             "list":{"titleField":"name","subtitleFields":[],"badgeField":"status","dateField":null},
             "detailSections":[{"title":null,"fields":["name","status"]}]}
            """#.utf8))
        settings.cantripHomeEnabled = false
        func tracker(_ title: String) throws -> CantripHomeTask {
            try store.create(.init(
                id: nil, title: title, prompt: "Check for replies and update the threads.",
                schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: Date().addingTimeInterval(-30)),
                workspace: fields, initialRecords: [["name": "Example Co", "status": "Waiting"]]
            ), now: Date().addingTimeInterval(-60))
        }
        let shadowed = try tracker("Shadow tracker")
        let record = try requireHome(shadowed.workspace?.records.first)

        // The records tool reads the snapshot; the checks catch what saving would refuse or what does nothing.
        let unitRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-shadow-unit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unitRoot) }
        let unit = CantripHomeShadowRun(realRunID: UUID(), task: shadowed, tasks: store.tasks, note: nil,
                                        config: config, root: unitRoot)
        let id = record.id.uuidString
        precondition(unit.recordsTool([:]).contains("1 matching records") && unit.recordsTool([:]).contains(id)
                     && unit.recordsTool(["ids": [String(id.prefix(8)).lowercased()]]).contains(id)
                     && unit.recordsTool(["ids": ["1234"]]).contains("0 matching records")
                     && unit.recordsTool(["query": "example waiting"]).contains(id)
                     && unit.recordsTool(["query": "nomatch"]).contains("0 matching records")
                     && unit.recordsTool(["task": UUID().uuidString]).hasPrefix("No task with records"),
                     "home_records filters by ID prefix and words, with full IDs")
        func block(_ changes: String) -> String {
            "```cantrip-task-records\n{\"taskID\":\"\(shadowed.id.uuidString)\",\"changes\":\(changes)}\n```"
        }
        func problems(_ changes: String) -> String { unit.validate(block(changes)).joined(separator: " | ") }
        precondition(problems(#"[{"operation":"upsert","id":"\#(id)","values":{"status":"Waiting"}}]"#).contains("unchanged values")
                     && problems(#"[{"operation":"upsert","id":"\#(id.prefix(14))","values":{"status":"Closed"}}]"#).contains("isn't a full record ID")
                     && problems("[]").contains("has no changes")
                     && problems(#"[{"operation":"upsert","id":"\#(id)","values":{"color":"Red"}}]"#).contains("isn't in Shadow tracker")
                     && problems(#"[{"operation":"upsert","id":"\#(UUID().uuidString)","values":{"status":"Closed"}}]"#).contains("doesn't exist")
                     && problems(#"[{"operation":"upsert","id":"\#(id)","values":{"status":"Closed"}}]"#).isEmpty
                     && unit.validate("No records changed.").isEmpty,
                     "Record changes are checked against the snapshot")

        config.tasks = [shadowed.id.uuidString]
        config.temperature = 0.2
        config.reasoningEffort = "low"
        config.recordsTool = true
        config.validateRecords = true
        config.instructions = "Change a field only with new evidence."
        store.runner.shadowConfig = { config }
        store.runner.shadowRoot = root
        store.runner.shadowTools = probe
        fixture.shadowReply = """
            Example Co is still waiting.
            ```cantrip-task-records
            {"taskID":"\(shadowed.id.uuidString)","changes":[{"operation":"upsert","id":"\(record.id.uuidString)","values":{"status":"Waiting"}}]}
            ```
            """
        fixture.shadowCorrectedReply = """
            Example Co closed the thread.
            ```cantrip-task-records
            {"taskID":"\(shadowed.id.uuidString)","changes":[{"operation":"upsert","id":"\(record.id.uuidString)","values":{"status":"Closed"}}]}
            ```
            """
        settings.cantripHomeEnabled = true
        store.checkNow()
        let realRun = try requireHome(store.backgroundRuns.first { $0.taskID == shadowed.id && $0.status == "running" }?.id)
        let realSession = try requireHome(store.runner.session(forRun: realRun))
        try await waitForJournalTest { pool.fixture(for: realSession.id)?.sink != nil }
        let realPrompt = pool.fixture(for: realSession.id)?.lastPrompt ?? ""
        let sink = pool.fixture(for: realSession.id)?.sink
        sink?(.textDelta("""
            Example Co replied.
            ```cantrip-task-records
            {"taskID":"\(shadowed.id.uuidString)","changes":[{"operation":"upsert","id":"\(record.id.uuidString)","values":{"status":"Replied"}}]}
            ```
            """))
        sink?(.done)
        let folder = root.appendingPathComponent("private")
        func runFolders() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        try await waitForJournalTest(timeout: 20) {
            runFolders().contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("run.json").path) }
        }
        let run = try requireHome(runFolders().first)
        func json(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent(name))) as! [String: Any]
        }
        let summary = try json("run.json"), checksums = try json("checksums.json")
        let afterShadow = try json("checksums-after-shadow.json")
        let current = try requireHome(store.tasks.first { $0.id == shadowed.id }?.workspace?.records.first)
        precondition(current.values["status"] == "Replied",
                     "The real run's change stands; the shadow run's block is never applied")
        precondition(summary["status"] as? String == "succeeded"
                     && summary["toolCalls"] as? [String: Int] == ["mcp__personal__mail_read": 1]
                     && summary["refusedCalls"] as? [String: Int] == ["run_shell": 1]
                     && summary["blocks"] as? [String: Int] == ["cantrip-task-records": 1]
                     && summary["steps"] as? Int == 1 && summary["promptTokens"] as? Int == 360
                     && summary["corrected"] as? Bool == true && (summary["validationProblems"] as? Int ?? 0) >= 1
                     && (summary["tuning"] as? [String: Any])?["recordsTool"] as? Bool == true
                     && summary["model"] as? String == "Fixture-8B-4bit" && summary["server"] as? String == "127.0.0.1",
                     "The run summary counts tools, refusals, blocks and tokens: \(summary)")
        precondition(checksums["realRunStatus"] as? String == "succeeded"
                     && checksums["before"] as? String != checksums["afterRealRun"] as? String
                     && afterShadow["afterShadowRun"] as? String == checksums["afterRealRun"] as? String,
                     "The real run's records are unchanged by the shadow run")
        let before = try String(contentsOf: run.appendingPathComponent("before.json"), encoding: .utf8)
        let after = try String(contentsOf: run.appendingPathComponent("after.json"), encoding: .utf8)
        let blocks = try String(contentsOf: run.appendingPathComponent("blocks.jsonl"), encoding: .utf8)
        let reply = try String(contentsOf: run.appendingPathComponent("reply.txt"), encoding: .utf8)
        let realReply = try String(contentsOf: run.appendingPathComponent("real-reply.txt"), encoding: .utf8)
        precondition(reply.contains("closed the thread") && reply.contains(CantripHomeShadowRun.correctionMarker)
                     && realReply.contains("Example Co replied"), "Both replies are kept for comparison")
        precondition(before.contains("Waiting") && after.contains("Replied") && blocks.contains("Closed")
                     && !blocks.contains("Waiting") && blocks.split(separator: "\n").count == 1,
                     "Before, after and only the corrected block are kept")
        // The transcript (first request and every tool call with its result) is kept for replay.
        let request = try json("request.json")
        let transcript = try String(contentsOf: run.appendingPathComponent("tools.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition((request["messages"] as? [[String: Any]])?.isEmpty == false && request["temperature"] as? Double == 0.2
                     && transcript.map { $0["name"] as? String ?? "" } == ["run_shell", "mcp__personal__mail_read"]
                     && transcript[0]["allowed"] as? Bool == false
                     && (transcript[1]["output"] as? String)?.contains("Example Co replied") == true,
                     "The request and tool calls are saved: \(transcript.map { $0["name"] ?? "" })")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        precondition(permissions == 0o700, "The shadow folder is private")

        // The local model saw the pre-run snapshot, the same task message, and only the read-only tool.
        let chats = fixture.requests.filter { $0.path == "/v1/chat/completions" }
        precondition(chats.count == 3, "One tool round, the reply, then one correction: \(chats.count)")
        let first = try JSONSerialization.jsonObject(with: chats[0].body) as! [String: Any]
        let firstText = String(decoding: chats[0].body, as: UTF8.self)
        let toolNames = (first["tools"] as? [[String: Any]] ?? []).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        let system = ((first["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "system" }?["content"] as? String) ?? ""
        precondition(first["temperature"] as? Double == 0.2 && first["reasoning_effort"] as? String == "low"
                     && system.contains("Change a field only with new evidence.")
                     && String(decoding: chats[2].body, as: UTF8.self).contains("unchanged values"),
                     "Tuning settings and the correction reach the local model")
        precondition(toolNames == ["mcp__personal__mail_read", CantripHomeShadowRun.recordsToolName]
                     && firstText.contains("Scheduled task · Shadow tracker")
                     && firstText.contains("status=Waiting") && !firstText.contains("status=Replied")
                     && first["priority"] as? String == "background"
                     && realPrompt.contains("status=Waiting"),
                     "The shadow run gets the task as it was before the real run, with read-only tools only")
        precondition(String(decoding: chats[1].body, as: UTF8.self).contains("Example Co replied"),
                     "The read-only tool's result goes back to the local model")

        // Nothing else: the shadow session never used its cloud backend, logged nothing to Home, and is released.
        let shadowSession = try requireHome(pool.fixtures.last?.sessionID)
        precondition(pool.fixtures.count == 2 && pool.fixtures.last?.fixture.lastPrompt == nil,
                     "A shadow run never reaches a cloud backend")
        precondition(store.backgroundRuns.filter { $0.taskID == shadowed.id }.count == 1
                     && !log.messages.contains { $0.text.contains("closed the thread") }
                     && !homeChat.messages.contains { $0.text.contains("closed the thread") },
                     "A shadow run adds no background run or Home message")
        try await waitForJournalTest { !SessionManager.isCantripHomeReserved(shadowSession) }

        // A day after the test ends, saved requests and tool results are removed.
        precondition(CantripHomeShadowRun.purgeTranscripts(root: root) == 2
                     && !FileManager.default.fileExists(atPath: run.appendingPathComponent("tools.jsonl").path)
                     && FileManager.default.fileExists(atPath: run.appendingPathComponent("run.json").path),
                     "Purging removes only the saved requests and tool results")

        // A failed real run gets no shadow run; its folder says why.
        settings.cantripHomeEnabled = false
        let failing = try tracker("Shadow failing tracker")
        config.tasks = [failing.id.uuidString]
        settings.cantripHomeEnabled = true
        store.checkNow()
        let failedRun = try requireHome(store.backgroundRuns.first { $0.taskID == failing.id && $0.status == "running" }?.id)
        let failedSession = try requireHome(store.runner.session(forRun: failedRun))
        try await waitForJournalTest { pool.fixture(for: failedSession.id)?.sink != nil }
        pool.fixture(for: failedSession.id)?.sink?(.failure("Synthetic outage"))
        try await waitForJournalTest(timeout: 20) { runFolders().count == 2 }
        let skipped = try requireHome(runFolders().first { $0 != run })
        try await waitForJournalTest {
            FileManager.default.fileExists(atPath: skipped.appendingPathComponent("run.json").path)
        }
        let skippedSummary = try JSONSerialization.jsonObject(
            with: Data(contentsOf: skipped.appendingPathComponent("run.json"))) as! [String: Any]
        precondition((skippedSummary["status"] as? String)?.hasPrefix("skipped") == true
                     && fixture.requests.filter { $0.path == "/v1/chat/completions" }.count == 3
                     && pool.fixtures.count == 3, "A failed real run is not shadowed")

        for task in [shadowed, failing] { try? store.delete(id: task.id) }
        print("Cantrip Home shadow runs: read-only local tools, captured blocks, unchanged real records passed")
    }
}
