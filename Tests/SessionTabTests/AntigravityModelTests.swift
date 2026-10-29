import Foundation

extension SessionTabTests {
    /// `agy models` output becomes the Antigravity picker list, Claude Opus 5.5 included.
    @MainActor
    static func testAntigravityModels() async throws {
        let output = """
        Fetching available models...
        gemini-4-argon-medium\tGemini 4 Argon (Medium)
        claude-opus-5-5-medium\tClaude Opus 5.5 (Medium)
        claude-opus-5-5-high\tClaude Opus 5.5 (High)
        claude-opus-5-5-high\tDuplicate
        not a model line
        bad slug!\tIgnored
        """
        let parsed = AntigravityModelFetcher.parse(output)
        precondition(parsed.map(\.id) == ["gemini-4-argon-medium", "claude-opus-5-5-medium", "claude-opus-5-5-high"],
                     "agy models lines parse into unique slugs: \(parsed)")
        precondition(parsed[1].name == "Claude Opus 5.5 (Medium)")
        precondition(AppSettings.agyDefaultModels.contains("claude-opus-5-5-medium"),
                     "Claude Opus 5.5 is offered before the first lookup")

        let settings = AppSettings.shared
        let saved = (settings.agyPath, settings.agyModel, settings.agyAvailableModels, settings.agyModelNames,
                     settings.agyCatalogUpdatedAt, settings.agyModelRefreshError)
        defer {
            (settings.agyPath, settings.agyModel, settings.agyAvailableModels, settings.agyModelNames,
             settings.agyCatalogUpdatedAt, settings.agyModelRefreshError) = saved
        }
        settings.agyPath = "/bin/echo"
        settings.agyAvailableModels = ["gemini-3.1-pro-high"]
        settings.refreshAntigravityModels { command, completion in
            precondition(command == "/bin/echo")
            completion(.success(parsed))
        }
        try await waitForJournalTest { !settings.agyRefreshInFlight && settings.agyCatalogUpdatedAt != nil }
        precondition(settings.agyAvailableModels == parsed.map(\.id), "\(settings.agyAvailableModels)")
        precondition(settings.agyModelLabel("claude-opus-5-5-high") == "Claude Opus 5.5 (High)")
        precondition(settings.agyModelLabel("custom-model") == "custom-model")

        settings.agyModel = "claude-opus-5-5-medium"
        precondition(settings.backendLabel(.antigravity) == "Antigravity · Claude Opus 5.5 (Medium)",
                     settings.backendLabel(.antigravity))
        let args = AntigravityBackend().buildArguments(resumingSessionID: nil)
        precondition(args.firstIndex(of: "--model").map { args[$0 + 1] } == "claude-opus-5-5-medium", "\(args)")

        // A saved custom slug stays selectable; a failed lookup keeps the cached list.
        settings.agyModel = "custom-model"
        precondition(settings.agyModelOptions.last == "custom-model")
        settings.refreshAntigravityModels { _, completion in completion(.failure(AntigravityModelError.response)) }
        try await waitForJournalTest { !settings.agyRefreshInFlight && settings.agyModelRefreshError != nil }
        precondition(settings.agyAvailableModels == parsed.map(\.id))
        try await testAntigravityTabModelSettings(models: parsed.map(\.id))
        print("Antigravity models: agy models discovery, display names, Claude Opus 5.5 and --model passed")
    }

    /// Per-tab model settings (what Gateway's Model Settings and Home use) work on Antigravity.
    @MainActor
    static func testAntigravityTabModelSettings(models: [String]) async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.agyModel, settings.agyEffort, settings.agyAvailableModels)
        defer { (settings.backend, settings.agyModel, settings.agyEffort, settings.agyAvailableModels) = saved }
        settings.backend = .antigravity
        settings.agyModel = "gemini-4-argon-medium"
        settings.agyEffort = ""
        settings.agyAvailableModels = models

        precondition(AppSettings.tabModelBackends.contains(.antigravity))
        let catalog = settings.tabModelCatalog(for: .antigravity)
        precondition(catalog.models.map(\.id) == models && catalog.fileDefaultModel == "gemini-4-argon-medium",
                     "Antigravity tabs offer the agy models: \(catalog)")
        precondition(catalog.info("claude-opus-5-5-medium")?.reasoningEfforts == ["low", "medium", "high"])
        precondition(CantripHomeTaskModels.offered(settings) == models, "Home tasks offer the agy models")

        let session = ChatSession(makeJournal: { try RunJournal(sessionID: $0, directory: FileManager.default.temporaryDirectory.appendingPathComponent("agy-tab-\(UUID())")) })
        defer { SessionTabMetadata.remove(id: session.id) }
        precondition(session.modelSettingsBackend == .antigravity)
        precondition(session.modelSettingsUnavailableReason == nil,
                     "Antigravity tabs can change models: \(session.modelSettingsUnavailableReason ?? "")")
        precondition(session.modelSettingsSnapshot.models.contains { $0.id == "claude-opus-5-5-medium" })

        let opus = SessionModelSelection(model: "claude-opus-5-5-medium", effort: "high", contextTier: "")
        try session.updateModelSettings(opus, revision: session.modelSettingsRevision)
        precondition(session.modelSelection == opus && session.ownModelSelection == opus)
        precondition(SessionTabMetadata.load(id: session.id).antigravityModelSettings == opus,
                     "The tab's Antigravity model is saved apart from Copilot's and Claude's")
        precondition(SessionTabMetadata.load(id: session.id).modelSettings == nil)
        do {
            try session.updateModelSettings(.init(model: "not-a-model", effort: "", contextTier: ""),
                                            revision: session.modelSettingsRevision)
            preconditionFailure("Unknown models are rejected")
        } catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        precondition(session.modelCommandReply("").contains("claude-opus-5-5-medium"), "/model lists the agy models")

        // A tab's model reaches agy as --model / --effort; Mac defaults come back when cleared.
        let backend = AntigravityBackend(persistKey: "agy-tab-test-\(UUID())")
        backend.modelOverride = opus.model
        backend.effortOverride = opus.effort
        var args = backend.buildArguments(resumingSessionID: nil)
        precondition(args.firstIndex(of: "--model").map { args[$0 + 1] } == "claude-opus-5-5-medium"
                     && args.firstIndex(of: "--effort").map { args[$0 + 1] } == "high", "\(args)")
        backend.modelOverride = nil
        backend.effortOverride = nil
        args = backend.buildArguments(resumingSessionID: nil)
        precondition(args.firstIndex(of: "--model").map { args[$0 + 1] } == "gemini-4-argon-medium", "\(args)")

        try session.updateModelSettings(nil, revision: session.modelSettingsRevision)
        precondition(session.ownModelSelection == nil && session.modelSelection.model == "gemini-4-argon-medium")
        print("Antigravity tab model settings: catalog, Home tasks, save/validate, /model and agy arguments passed")
    }
}
