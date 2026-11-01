import Foundation

private final class TierBackend: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// Tiers map to each backend's own models; a tier skips a model its backend doesn't offer or
    /// whose own quota is used up, and leaves a limit on the whole backend to the backup chain.
    @MainActor
    static func testModelTiers() async throws {
        let settings = AppSettings.shared
        let saved = (settings.modelTiers, settings.copilotModelCatalog, settings.claudeModelCatalog,
                     settings.agyAvailableModels, settings.codexAvailableModels, settings.localModel)
        defer {
            settings.modelTiers = saved.0
            settings.copilotModelCatalog = saved.1
            settings.claudeModelCatalog = saved.2
            settings.agyAvailableModels = saved.3
            settings.codexAvailableModels = saved.4
            settings.localModel = saved.5
            BackendLimitTracker.shared.clear()
        }
        precondition(ModelTier(model: " Deep ") == .deep && ModelTier(model: "claude-opus-5.5") == nil && ModelTier(model: "") == nil)

        // The defaults name only models each backend offers: Copilot's catalog, Claude Code's
        // aliases, `agy models` and Codex's model/list.
        let copilotIDs = ["auto", "claude-sonnet-5.5", "claude-sonnet-5", "claude-opus-5.5", "claude-haiku-5.5",
                          "claude-haiku-4.5", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-6-astra", "gpt-5.6-sol",
                          "gpt-5.6-sol-fast", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.3-codex", "mai-code-1.1-flash",
                          "grok-4.7", "grok-4.6", "gpt-6.1-terra", "mai-code-2-flash"]
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        settings.copilotModelCatalog = copilotIDs.map { CopilotModelInfo(id: $0, reasoningEfforts: efforts) }
        settings.claudeModelCatalog = ["default", "opus", "sonnet", "haiku"].map { CopilotModelInfo(id: $0, reasoningEfforts: efforts) }
        settings.agyAvailableModels = AppSettings.agyDefaultModels
        settings.codexAvailableModels = [
            CodexModel(id: "gpt-6-luna", displayName: "GPT-6-Luna", efforts: efforts, defaultEffort: "medium", isDefault: true),
            CodexModel(id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", efforts: efforts + ["ultra"], defaultEffort: "medium"),
            CodexModel(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", efforts: efforts, defaultEffort: "medium"),
        ]
        settings.modelTiers = ModelTierMap()
        for kind in ModelTierMap.backends {
            let offered = settings.tabModelCatalog(for: kind).models.map(\.id)
            for tier in ModelTier.allCases {
                let choices = settings.tierChoices(tier, on: kind)
                precondition(!choices.isEmpty && choices.allSatisfy { offered.contains($0.model) }, "\(kind) \(tier)")
                let resolved = settings.resolveTier(tier, on: kind)
                precondition(resolved.model == choices[0].model && resolved.note == nil, "\(resolved)")
            }
        }
        precondition(settings.resolveTier(.deep, on: .copilot).selection
            == SessionModelSelection(model: "claude-opus-5.5", effort: "xhigh", contextTier: ""))
        precondition(settings.resolveTier(.standard, on: .codex).model == "gpt-6-luna", "Codex's default model is its standard")
        precondition(settings.resolveTier(.deep, on: .codex).model == "gpt-5.6-terra", "...and its strongest is deep")
        precondition(settings.resolveTier(.fast, on: .claudeCode).selection
            == SessionModelSelection(model: "haiku", effort: "low", contextTier: ""))
        settings.localModel = "gemma"
        precondition(settings.resolveTier(.deep, on: .localModel).model == "gemma", "Local Model runs its one model for every tier")
        precondition(settings.resolveTier(.deep, on: .copilotRemote).model == "", "Copilot Remote runs its server's model")

        // The tab's own effort wins where the model takes it.
        precondition(settings.resolveTier(.deep, on: .copilot, effort: "high").effort == "high")
        precondition(settings.resolveTier(.deep, on: .copilot, effort: "ultra").effort == "xhigh")

        // A model the backend no longer offers: the next one in the tier, and the note says so.
        settings.copilotModelCatalog.removeAll { $0.id == "claude-opus-5.5" }
        let missing = settings.resolveTier(.deep, on: .copilot)
        precondition(missing.model == "gpt-6.1-sol" && missing.note == "claude-opus-5.5 isn't offered, so gpt-6.1-sol", "\(missing)")
        settings.copilotModelCatalog = copilotIDs.map { CopilotModelInfo(id: $0, reasoningEfforts: efforts) }

        // Antigravity's Argon group at its limit: deep moves to Opus on Antigravity.
        let tracker = BackendLimitTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.markLimited(.antigravity, model: "gemini-4-argon-high", message: "quota",
                            report: UsageLimitReport(code: "quota", resetsAt: now.addingTimeInterval(3_600), scope: "argon"), now: now)
        let argon = settings.resolveTier(.deep, on: .antigravity, tracker: tracker, now: now)
        precondition(argon.model == "claude-opus-5-5-high" && argon.note?.hasPrefix("Gemini 4 Argon (High) is at its usage limit until") == true
                     && argon.note?.hasSuffix(", so Claude Opus 5.5 (High)") == true, "\(argon)")
        precondition(settings.resolveTier(.fast, on: .antigravity, tracker: tracker, now: now).note == nil,
                     "Flash has its own quota")
        // Both of deep's groups used up: the first runs, so the backup chain moves on from it.
        tracker.markLimited(.antigravity, model: "claude-opus-5-5-high", message: "quota",
                            report: UsageLimitReport(code: "quota", resetsAt: now.addingTimeInterval(3_600), scope: "claude-gpt"), now: now)
        let both = settings.resolveTier(.deep, on: .antigravity, tracker: tracker, now: now)
        precondition(both.model == "gemini-4-argon-high" && both.note == nil, "\(both)")
        // Copilot's shared quota covers every model: no point trying the next one.
        tracker.markLimited(.copilot, message: "quota", now: now)
        precondition(settings.resolveTier(.deep, on: .copilot, tracker: tracker, now: now).model == "claude-opus-5.5")

        // Nothing in the tier offered: the backend's default model, with a note.
        settings.modelTiers.set([ModelTierChoice(model: "claude-gone-1", effort: "high")], for: .standard, on: .claudeCode)
        let gone = settings.resolveTier(.standard, on: .claudeCode)
        precondition(gone.model == "" && gone.note == "claude-gone-1 isn't offered, so Claude Code's default model", "\(gone)")

        // Editing a cell keeps only that cell; setting it back to the default clears it.
        var map = ModelTierMap()
        map.set([ModelTierChoice(model: "gpt-6-sol", effort: "high")], for: .deep, on: .copilot)
        precondition(!map.isDefault(.deep, on: .copilot) && map.isDefault(.fast, on: .copilot))
        precondition(map.choices(.fast, on: .copilot) == ModelTierMap.defaultChoices(.fast, on: .copilot))
        map.set(ModelTierMap.defaultChoices(.deep, on: .copilot), for: .deep, on: .copilot)
        precondition(map.overrides.isEmpty)
        let cleaned = ModelTierMap.cleaned([
            "Copilot": ["deep": [.init(model: " gpt-6-sol ", effort: "HIGH"), .init(model: "deep"), .init(model: "gpt-6-sol")],
                        "huge": [.init(model: "gpt-6-sol")]],
            "Local Model": ["fast": [.init(model: "gemma")]],
            "Nope": ["fast": [.init(model: "x")]],
        ])
        precondition(cleaned.overrides == ["Copilot": ["deep": [.init(model: "gpt-6-sol", effort: "high")]]], "\(cleaned)")

        // Saved with the other settings, and through ~/.cantriprc.
        settings.modelTiers = cleaned
        let file = settings.dotfileValues["modelTiers"] as? [String: [String: [[String: String]]]]
        precondition(file?["Copilot"]?["deep"]?.first == ["model": "gpt-6-sol", "effort": "high"])
        settings.modelTiers = ModelTierMap()
        precondition(settings.applySettings(["modelTiers": file as Any]).contains("modelTiers"))
        precondition(settings.modelTiers == cleaned)
        try await testTierFallbackRun()
        print("Model tiers: defaults, resolution, limits, editing and runs passed")
    }

    /// A tab set to deep runs the deep model, moves to the tier's next model on the same backend
    /// when its model's own quota runs out, keeps the tier on the backup after that, and follows
    /// an edit to the map on its next run.
    @MainActor
    private static func testTierFallbackRun() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.limitFallbackEntries, settings.modelTiers, settings.agyAvailableModels,
                     settings.claudeModelCatalog, settings.memoryEnabled, settings.voiceMode)
        defer {
            settings.backend = saved.0
            settings.limitFallbackEntries = saved.1
            settings.modelTiers = saved.2
            settings.agyAvailableModels = saved.3
            settings.claudeModelCatalog = saved.4
            settings.memoryEnabled = saved.5
            settings.voiceMode = saved.6
            BackendLimitTracker.shared.clear()
        }
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.backend = .antigravity
        settings.modelTiers = ModelTierMap()
        settings.agyAvailableModels = AppSettings.agyDefaultModels
        settings.claudeModelCatalog = ["default", "opus", "sonnet", "haiku"].map {
            CopilotModelInfo(id: $0, reasoningEfforts: ["low", "medium", "high", "xhigh", "max"])
        }
        settings.limitFallbackEntries = [FallbackEntry(backend: "Claude Code")]
        BackendLimitTracker.shared.clear()
        let agy = TierBackend(), claude = TierBackend()
        let chat = ChatSession(copilotBackend: TierBackend(), backendOverrides: [.antigravity: agy, .claudeCode: claude])
        defer { chat.cancel() }
        try chat.saveModelSelection(SessionModelSelection(model: "deep", effort: "", contextTier: ""))
        precondition(chat.runTier == .deep && chat.runSelection(for: .antigravity)?.model == "gemini-4-argon-high")

        chat.submitRemote("deep task", mode: .queue)
        try await waitForJournalTest { agy.requests.count == 1 }
        agy.sink?(.textDelta("partial work"))
        let reset = Date().addingTimeInterval(3_600)
        agy.sink?(.usageLimit(UsageLimitReport(code: "usage/argon", resetsAt: reset, scope: "argon")))
        agy.sink?(.failure("You've hit your usage limit for Gemini 4 Argon."))
        try await waitForJournalTest { agy.requests.count == 2 }
        precondition(claude.requests.isEmpty, "the tier's next model on Antigravity comes before the backup")
        precondition(agy.requests[1].prompt.contains("deep task"))
        precondition(chat.runSelection(for: .antigravity)?.model == "claude-opus-5-5-high" && chat.fallbackModel?.tier == .deep)
        precondition(chat.messages.contains { $0.role == .error
            && $0.text.contains("Continuing this task on the next Deep model: Antigravity · Deep · Claude Opus 5.5 (High) (Gemini 4 Argon (High) is at its usage limit until") },
                     "the run note says why: \(chat.messages.map(\.text))")

        // Deep's other group on Antigravity runs out too: the backup keeps the tier.
        agy.sink?(.usageLimit(UsageLimitReport(code: "usage/claude-gpt", resetsAt: reset, scope: "claude-gpt")))
        agy.sink?(.failure("You've hit your usage limit."))
        try await waitForJournalTest { claude.requests.count == 1 }
        precondition(chat.fallbackModel?.backend == .claudeCode && chat.fallbackModel?.tier == .deep
                     && chat.runSelection(for: .claudeCode) == SessionModelSelection(model: "opus", effort: "xhigh", contextTier: ""))
        precondition(chat.claudeCode.modelOverride == "opus" && chat.claudeCode.effortOverride == "xhigh")
        precondition(chat.messages.contains { $0.role == .error && $0.text.contains("Continuing this task with Claude Code · Deep · opus · xhigh") })
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // While both groups are used up, new messages start on the backup, still deep.
        chat.submitRemote("second deep task", mode: .queue)
        try await waitForJournalTest { claude.requests.count == 2 }
        precondition(agy.requests.count == 2 && chat.deliveryStatus?.contains("Using Claude Code · Deep · opus · xhigh") == true,
                     chat.deliveryStatus ?? "")
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Only Argon used up: the run starts on Opus on Antigravity and says so.
        BackendLimitTracker.shared.clear()
        BackendLimitTracker.shared.markLimited(.antigravity, model: "gemini-4-argon-high", message: "Argon",
                                               report: UsageLimitReport(code: "usage/argon", resetsAt: reset, scope: "argon"))
        chat.submitRemote("third deep task", mode: .queue)
        try await waitForJournalTest { agy.requests.count == 3 }
        precondition(chat.fallbackModel == nil && chat.runSelection(for: .antigravity)?.model == "claude-opus-5-5-high")
        precondition(chat.deliveryStatus?.hasPrefix("Deep on Antigravity: Gemini 4 Argon (High) is at its usage limit until") == true
                     && chat.deliveryStatus?.hasSuffix(", so Claude Opus 5.5 (High).") == true, chat.deliveryStatus ?? "")
        agy.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // One edit to the deep cell reaches the next run.
        BackendLimitTracker.shared.clear()
        settings.modelTiers.set([ModelTierChoice(model: "gemini-3.8-flash-high")], for: .deep, on: .antigravity)
        chat.submitRemote("fourth deep task", mode: .queue)
        try await waitForJournalTest { agy.requests.count == 4 }
        precondition(chat.runSelection(for: .antigravity)?.model == "gemini-3.8-flash-high")
        agy.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
    }
}
