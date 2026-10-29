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
        print("Antigravity models: agy models discovery, display names, Claude Opus 5.5 and --model passed")
    }
}
