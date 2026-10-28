import Foundation

extension SessionTabTests {
    /// The account models these tests pretend the Mac's catalog offers.
    static let taskModelCatalog: [CopilotModelInfo] = [
        .init(id: "claude-opus-5.5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
              contextTiers: ["default", "long_context"]),
        .init(id: "claude-sonnet-5.5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
              contextTiers: ["default", "long_context"]),
        .init(id: "claude-haiku-4.5", reasoningEfforts: [], contextTiers: ["default"]),
    ]

    /// Runs `body` with Home on claude-opus-5.5 (xhigh, long context) and the test catalog.
    @MainActor
    static func withTaskModelSettings<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.copilotModel, settings.copilotEffort,
                     settings.copilotContextTier, settings.copilotModelCatalog, settings.copilotAvailableModels)
        settings.backend = .copilot
        settings.copilotModel = "claude-opus-5.5"
        settings.copilotEffort = "xhigh"
        settings.copilotContextTier = "long_context"
        settings.copilotModelCatalog = taskModelCatalog
        settings.copilotAvailableModels = taskModelCatalog.map(\.id)
        defer {
            settings.backend = saved.0
            settings.copilotModel = saved.1
            settings.copilotEffort = saved.2
            settings.copilotContextTier = saved.3
            settings.copilotModelCatalog = saved.4
            settings.copilotAvailableModels = saved.5
        }
        return try await body()
    }

    /// A task's own model: validation, edits, Home's protocol and the hidden run's backend.
    @MainActor
    static func testCantripHomeTaskModelChoices(homeChat: ChatSession) async throws {
        try await withTaskModelSettings {
            let store = CantripHomeStore.shared
            let settings = AppSettings.shared
            let wasEnabled = AppSettings.shared.cantripHomeEnabled
            AppSettings.shared.cantripHomeEnabled = false
            defer { AppSettings.shared.cantripHomeEnabled = wasEnabled }
            let zone = "America/Los_Angeles"
            let now = Date()
            let daily = CantripHomeSchedule(
                kind: .weekdays, summary: "Every day", timeZone: zone, startAt: nil,
                weekdays: [1, 2, 3, 4, 5, 6, 7], times: [.init(hour: 9, minute: 30)]
            )
            @MainActor func rejects(_ proposal: CantripHomeTaskProposal, _ text: String, line: UInt = #line) {
                do {
                    _ = try store.create(proposal, now: now)
                    preconditionFailure("Expected a rejection at line \(line)")
                } catch let error as CantripHomeError {
                    precondition(error.localizedDescription.contains(text),
                                 "Unexpected error at line \(line): \(error.localizedDescription)")
                } catch {
                    preconditionFailure("Unexpected error at line \(line): \(error)")
                }
            }

            // New tasks may name a model the picker offers, with an effort that model supports.
            let tracker = try store.create(.init(
                id: nil, title: "Model tracker", prompt: "Track things.", schedule: daily,
                model: "claude-sonnet-5.5"
            ), now: now)
            let plain = try store.create(.init(
                id: nil, title: "Model briefing", prompt: "Brief me.", schedule: daily
            ), now: now)
            precondition(tracker.model == "claude-sonnet-5.5" && tracker.effort == nil
                         && plain.model == nil && plain.effort == nil,
                         "Tasks store their own model, or none to follow Home")
            rejects(.init(id: nil, title: "Bad", prompt: "Bad.", schedule: daily, model: "gpt-9-imaginary"),
                    "Unknown model gpt-9-imaginary")
            rejects(.init(id: nil, title: "Bad", prompt: "Bad.", schedule: daily, model: "rm -rf"),
                    "Unknown model")
            rejects(.init(id: nil, title: "Bad", prompt: "Bad.", schedule: daily,
                          model: "claude-haiku-4.5", effort: "high"),
                    "doesn't support effort high")
            rejects(.init(id: tracker.id, title: nil, prompt: nil, schedule: nil, effort: "turbo"),
                    "doesn't support effort turbo")

            // Edits may send only the model or effort; nil keeps, "" returns to Home's model.
            let effortOnly = try store.create(.init(
                id: tracker.id, title: nil, prompt: nil, schedule: nil, effort: "medium"
            ), now: now)
            precondition(effortOnly.model == "claude-sonnet-5.5" && effortOnly.effort == "medium"
                         && effortOnly.prompt == "Track things." && effortOnly.schedule == tracker.schedule,
                         "An effort-only edit keeps the model, prompt and schedule")
            let renamed = try store.create(.init(
                id: tracker.id, title: "Model tracker 2", prompt: nil, schedule: nil, workspace: nil,
                runsAfter: [plain.id]
            ), now: now)
            precondition(renamed.model == "claude-sonnet-5.5" && renamed.effort == "medium",
                         "Edits without model fields keep the saved model")
            let cleared = try store.create(.init(
                id: tracker.id, title: nil, prompt: nil, schedule: nil, model: "", effort: ""
            ), now: now)
            precondition(cleared.model == nil && cleared.effort == nil,
                         "\"\" returns a task to Home's model and default effort")

            // Before the Mac has loaded its catalog, a well-formed ID is accepted; runs check again.
            settings.copilotModelCatalog = []
            settings.copilotAvailableModels = []
            let early = try store.create(.init(
                id: tracker.id, title: nil, prompt: nil, schedule: nil, model: "claude-sonnet-5.5"
            ), now: now)
            precondition(early.model == "claude-sonnet-5.5")
            rejects(.init(id: tracker.id, title: nil, prompt: nil, schedule: nil, model: "bad model"),
                    "Unknown model")
            settings.copilotModelCatalog = taskModelCatalog
            settings.copilotAvailableModels = taskModelCatalog.map(\.id)

            // Local maintenance can set a model through the task-edit inbox.
            let edit = CantripHomeStore.taskEditDirectory.appendingPathComponent("model-edit.json")
            try Data(#"{"version":1,"taskID":"\#(plain.id.uuidString)","model":"claude-sonnet-5.5","effort":"high"}"#.utf8)
                .write(to: edit, options: .atomic)
            store.checkNow()
            let edited = try requireHome(store.tasks.first { $0.id == plain.id })
            precondition(edited.model == "claude-sonnet-5.5" && edited.effort == "high"
                         && edited.prompt == "Brief me." && edited.schedule == plain.schedule
                         && !FileManager.default.fileExists(atPath: edit.path),
                         "A queued edit sets only the task's model and effort")
            try Data(#"{"version":1,"taskID":"\#(plain.id.uuidString)","model":""}"#.utf8)
                .write(to: edit, options: .atomic)
            store.checkNow()
            precondition(store.tasks.first { $0.id == plain.id }?.model == nil
                         && store.tasks.first { $0.id == plain.id }?.effort == "high",
                         "A queued edit can clear the model")

            // Home learns the field, the offered IDs and each task's saved model.
            let instructions = homeChat.cantripHomeInstructions
            let lines = instructions.split(separator: "\n").map(String.init)
            let trackerLine = lines.first { $0.contains("Model tracker 2 — ") } ?? ""
            let briefingLine = lines.first { $0.contains("Model briefing — ") } ?? ""
            precondition(instructions.contains(#""model":"Copilot model ID", "" for Home's model, or null to keep,"#)
                         && instructions.contains("Models: claude-opus-5.5, claude-sonnet-5.5, claude-haiku-4.5.")
                         && trackerLine.contains("; runsAfter \(plain.id.uuidString); model claude-sonnet-5.5")
                         && briefingLine.hasSuffix("; effort high") && !briefingLine.contains("; model "),
                         "Home's protocol documents task models and lists each task's model: \(trackerLine) / \(briefingLine)")
            precondition(CantripHomeProtocol.schema(for: .task).contains(#""model":null or "model ID" or """#),
                         "Block corrections show the model field")

            // Resolution: the task's model with Home's effort and context; Home's model otherwise.
            let sonnet = try requireHome(store.tasks.first { $0.id == tracker.id })
            let resolved = CantripHomeTaskModels.resolve(task: sonnet, settings: settings)
            precondition(resolved == .init(
                selection: .init(model: "claude-sonnet-5.5", effort: "xhigh", contextTier: "long_context"),
                model: "claude-sonnet-5.5", note: nil
            ), "A task model keeps Home's effort and context window: \(resolved)")
            var haiku = sonnet
            haiku.model = "claude-haiku-4.5"
            haiku.effort = "low"
            let unsupported = CantripHomeTaskModels.resolve(task: haiku, settings: settings)
            precondition(unsupported.selection == .init(model: "claude-haiku-4.5", effort: "", contextTier: ""),
                         "Effort and context the task's model lacks fall back to its defaults")
            precondition(CantripHomeTaskModels.resolve(task: nil, settings: settings)
                            == .init(selection: nil, model: "claude-opus-5.5", note: nil)
                         && CantripHomeTaskModels.resolve(task: plain, settings: settings).selection == nil,
                         "Incidents and tasks without a model follow Home")
            var gone = sonnet
            gone.model = "claude-sonnet-4"
            let fallback = CantripHomeTaskModels.resolve(task: gone, settings: settings)
            precondition(fallback.selection == nil && fallback.model == "claude-opus-5.5"
                         && fallback.note == "Ran on Home's model, claude-opus-5.5: claude-sonnet-4 isn't available on this Mac right now.",
                         "An unavailable model falls back to Home's with a note")
            // On Claude Code, tasks pick from its own list; a Copilot-only model falls back to Home's.
            let savedClaude = (settings.claudeModelCatalog, settings.claudeModel, settings.claudeEffort)
            settings.claudeModelCatalog = [CopilotModelInfo(id: "opus", reasoningEfforts: ["low", "high", "max"], contextTiers: []),
                                           CopilotModelInfo(id: "sonnet", reasoningEfforts: ["low", "high"], contextTiers: [])]
            (settings.claudeModel, settings.claudeEffort) = ("opus", "max")
            settings.backend = .claudeCode
            let copilotOnly = CantripHomeTaskModels.resolve(task: sonnet, settings: settings)
            var claudeTask = sonnet
            claudeTask.model = "sonnet"
            claudeTask.effort = nil
            let onClaude = CantripHomeTaskModels.resolve(task: claudeTask, settings: settings)
            let claudeRun = ChatSession(copilotBackend: CopilotBackend(), cantripHomeRun: true, makeJournal: { _ in
                try RunJournal(sessionID: UUID(), directory: CantripHomeStore.runsDirectory)
            })
            claudeRun.cantripHomeModelOverride = onClaude.selection
            let claudeOverride = (claudeRun.claudeCode.modelOverride, claudeRun.claudeCode.effortOverride)
            claudeRun.discardCantripHomeRun()
            settings.backend = .copilot
            (settings.claudeModelCatalog, settings.claudeModel, settings.claudeEffort) = savedClaude
            precondition(copilotOnly.selection == nil && copilotOnly.model == "opus"
                         && copilotOnly.note?.contains("claude-sonnet-5.5 isn't available") == true,
                         "A Copilot model falls back to Home's Claude model: \(copilotOnly)")
            // Home's max effort isn't offered by sonnet, so it falls back to sonnet's default.
            precondition(onClaude.selection == .init(model: "sonnet", effort: "", contextTier: "") && onClaude.note == nil,
                         "A Claude task model resolves against Claude Code's list: \(onClaude)")
            precondition(claudeOverride.0 == "sonnet" && claudeOverride.1 == "",
                         "The task model reaches the hidden run's Claude backend: \(claudeOverride)")

            // A hidden run's Copilot backend gets the override, and loses it when cleared.
            let backend = CopilotBackend()
            let run = ChatSession(copilotBackend: backend, cantripHomeRun: true, makeJournal: { _ in
                try RunJournal(sessionID: UUID(), directory: CantripHomeStore.runsDirectory)
            })
            precondition(backend.modelOverride == nil && backend.effortOverride == nil,
                         "Without a task model a hidden run follows Home's selection")
            run.cantripHomeModelOverride = resolved.selection
            precondition(backend.modelOverride == "claude-sonnet-5.5" && backend.effortOverride == "xhigh"
                         && backend.contextTierOverride == "long_context",
                         "The task model reaches the hidden run's Copilot backend")
            run.cantripHomeModelOverride = nil
            precondition(backend.modelOverride == nil, "Clearing the override returns to Home's model")
            run.discardCantripHomeRun()

            for id in [tracker.id, plain.id] { try? store.delete(id: id) }
            print("Cantrip Home: per-task models validate, edit, document and reach the run's backend")
        }
    }
}
