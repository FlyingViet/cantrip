import Foundation

extension SessionTabTests {
    static func projectModels(_ models: [[String: Any]]) throws -> [CopilotModelInfo] {
        let script = CopilotModelFetcher.script.components(separatedBy: "let client;\n")[0]
            + """

            try {
              console.log(JSON.stringify({models: project(JSON.parse(process.env.MODEL_TEST_INPUT))}));
            } catch (error) {
              console.log(JSON.stringify({error: error.message}));
            }
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["MODEL_TEST_INPUT"] = String(decoding: try JSONSerialization.data(withJSONObject: models), as: UTF8.self)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        precondition(!String(decoding: data, as: UTF8.self).contains("must-not-leave-process"))
        struct Projection: Decodable {
            let models: [CopilotModelInfo]?
            let error: CopilotModelError?
        }
        let result = try JSONDecoder().decode(Projection.self, from: data)
        if let error = result.error { throw error }
        return result.models!
    }

    @MainActor
    static func testCopilotModels() async throws {
        let catalog = try projectModels([
            ["id": "auto", "capabilities": [:], "unrelated": "must-not-leave-process"],
            [
                "id": "claude-fixture",
                "capabilities": [
                    "supports": ["reasoningEffort": true],
                    "limits": ["max_context_window_tokens": 1_000_000, "max_prompt_tokens": 936_000, "max_output_tokens": 64_000],
                ],
                "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max", "max"],
                "billing": ["tokenPrices": ["maxPromptTokens": 200_000, "longContext": ["maxPromptTokens": 936_000]]],
            ],
            [
                "id": "haiku-fixture",
                "capabilities": [
                    "supports": ["reasoningEffort": false],
                    "limits": ["max_context_window_tokens": 200_000, "max_prompt_tokens": 136_000, "max_output_tokens": 64_000],
                ],
                "supportedReasoningEfforts": ["high"],
            ],
            [
                "id": "gpt-fixture",
                "capabilities": ["limits": ["max_context_window_tokens": 1_050_000, "max_output_tokens": 128_000]],
                "supportedReasoningEfforts": ["none", "low", "max"],
                "billing": ["tokenPrices": ["maxPromptTokens": 272_000, "longContext": ["maxPromptTokens": 1_050_000]]],
                "policy": ["state": "enabled"],
            ],
            [
                "id": "mini-fixture",
                "capabilities": ["limits": ["max_context_window_tokens": 264_000, "max_prompt_tokens": 128_000, "max_output_tokens": 64_000]],
                "supportedReasoningEfforts": ["low", "medium", "high"],
            ],
            [
                "id": "provider/unknown-fixture",
                "supportedContextTiers": ["default", "long_context"],
                "capabilities": ["limits": ["max_context_window_tokens": 500_000, "max_prompt_tokens": 400_000]],
            ],
            [
                "id": "legacy-fixture",
                "capabilities": ["limits": ["max_context_window_tokens": NSNull(), "max_prompt_tokens": -1]],
                "billing": ["tokenPrices": ["maxPromptTokens": NSNull(), "contextMax": 200_000, "longContext": ["contextMax": 500_000]]],
            ],
            ["id": "disabled-fixture", "policy": ["state": "disabled"]],
            ["id": "gpt-fixture"],
        ])
        precondition(catalog.count == 7)
        precondition(catalog[0].contextWindow == nil && catalog[0].contextTiers == nil)
        precondition(catalog[0].reasoningEfforts == nil, "Unknown is not the same as unsupported")
        let claude = catalog[1]
        precondition(claude.contextLabel == "1M" && claude.defaultContextPromptTokens == 200_000)
        precondition(claude.longContextPromptTokens == 936_000 && claude.maxOutputTokens == 64_000)
        precondition(claude.reasoningEfforts == ["low", "medium", "high", "xhigh", "max"])
        precondition(claude.contextTiers == ["default", "long_context"])
        let haiku = catalog[2]
        precondition(haiku.reasoningEfforts == [] && haiku.contextTiers == ["default"])
        precondition(haiku.defaultContextPromptTokens == 136_000)
        let gpt = catalog[3]
        precondition(gpt.contextLabel == "1.05M", "Do not round 1.05M down to 1.0M")
        precondition(gpt.defaultContextPromptTokens == 272_000 && gpt.longContextPromptTokens == 1_050_000)
        precondition(gpt.contextWindow == 1_050_000, "Do not invent total context by adding output to input")
        precondition(catalog[4].contextWindow == 264_000 && catalog[4].defaultContextPromptTokens == 128_000)
        precondition(catalog[5].contextTiers == ["default", "long_context"])
        precondition(catalog[5].defaultContextPromptTokens == nil && catalog[5].longContextPromptTokens == nil)
        precondition(catalog[6].contextWindow == nil && catalog[6].defaultContextPromptTokens == 200_000)
        precondition(catalog[6].longContextPromptTokens == 500_000)
        precondition(CopilotModelInfo.tokenLabel(264_000) == "264k")
        precondition(CopilotModelInfo.tokenLabel(999) == "999")
        precondition(CopilotModelInfo.tokenLabel(128_001) == "128.001k")
        precondition(claude.promptTokens(for: "long_context") == 936_000)
        precondition(claude.promptTokens(for: "future") == nil)

        let decoded = try JSONDecoder().decode([CopilotModelInfo].self, from: JSONEncoder().encode(catalog))
        precondition(decoded == catalog)
        let oldCache = try JSONDecoder().decode(CopilotModelInfo.self, from: Data(#"{"id":"legacy","contextWindow":400000}"#.utf8))
        precondition(oldCache.contextLabel == "400k" && oldCache.contextTiers == nil)
        precondition(CopilotModelInfo.choices(supported: haiku.reasoningEfforts, fallback: ["high"], selected: "") == [])
        precondition(CopilotModelInfo.choices(supported: ["low", "high"], fallback: ["max"], selected: "max") == ["low", "high", "max"])
        precondition(CopilotModelInfo.choices(supported: nil, fallback: ["low", "low", "max"], selected: "") == ["low", "max"])
        for empty in [[], [["id": "blocked", "policy": ["state": "disabled"]]]] as [[[String: Any]]] {
            do {
                _ = try projectModels(empty)
                preconditionFailure("Unusable catalogs must not be reported as a successful refresh")
            } catch CopilotModelError.response {}
        }

        let settings = AppSettings.shared
        let oldCatalog = settings.copilotModelCatalog
        let oldIDs = settings.copilotAvailableModels
        let oldEfforts = settings.copilotEffortChoices
        let oldTiers = settings.copilotContextTierChoices
        let oldPath = settings.copilotPath
        let oldModel = settings.copilotModel
        let oldEffort = settings.copilotEffort
        let oldTier = settings.copilotContextTier
        defer {
            settings.copilotModelCatalog = oldCatalog
            settings.copilotAvailableModels = oldIDs
            settings.copilotEffortChoices = oldEfforts
            settings.copilotContextTierChoices = oldTiers
            settings.copilotPath = oldPath
            settings.copilotModel = oldModel
            settings.copilotEffort = oldEffort
            settings.copilotContextTier = oldTier
        }
        settings.copilotPath = "/fixture path/copilot"
        settings.copilotModel = "keep-selected-model"
        settings.copilotEffort = "max"
        settings.copilotContextTier = "long_context"
        var completion: ((Result<[CopilotModelInfo], Error>) -> Void)?
        var calls = 0
        let loader: (String, @escaping (Result<[CopilotModelInfo], Error>) -> Void) -> Void = { command, callback in
            precondition(command == "/fixture path/copilot")
            calls += 1
            completion = callback
        }
        settings.refreshCopilotModels(using: loader)
        settings.refreshCopilotModels(using: loader)
        precondition(calls == 1 && settings.copilotRefreshInFlight)
        completion?(.success(catalog))
        try await Task.sleep(for: .milliseconds(20))
        precondition(settings.copilotModelCatalog == catalog && settings.copilotAvailableModels == catalog.map(\.id))
        precondition(settings.copilotCatalogUpdatedAt != nil && settings.copilotModelRefreshError == nil)
        precondition(settings.copilotEffortChoices == ["low", "medium", "high", "xhigh", "max", "none"])
        precondition(settings.copilotContextTierChoices == ["default", "long_context"])
        precondition(settings.copilotModel == "keep-selected-model" && settings.copilotEffort == "max"
                     && settings.copilotContextTier == "long_context")
        let persisted = try JSONDecoder().decode([CopilotModelInfo].self, from: UserDefaults.standard.data(forKey: "copilotModelCatalog")!)
        precondition(persisted == catalog)
        let updatedAt = settings.copilotCatalogUpdatedAt
        settings.refreshCopilotModels(using: loader)
        completion?(.failure(CopilotModelError.timeout))
        try await Task.sleep(for: .milliseconds(20))
        precondition(settings.copilotModelCatalog == catalog && settings.copilotCatalogUpdatedAt == updatedAt)
        precondition(settings.copilotModelRefreshError == CopilotModelError.timeout.localizedDescription)
        precondition(!settings.copilotRefreshInFlight)
        settings.refreshCopilotModels(using: loader)
        completion?(.success([]))
        try await Task.sleep(for: .milliseconds(20))
        precondition(settings.copilotModelCatalog == catalog && settings.copilotModelRefreshError != nil)
        settings.refreshCopilotModels(using: loader)
        settings.copilotPath = "/other/copilot"
        completion?(.success([haiku]))
        try await Task.sleep(for: .milliseconds(20))
        precondition(settings.copilotModelCatalog == catalog && settings.copilotCatalogUpdatedAt == nil)
        precondition(settings.copilotModelRefreshError?.contains("path changed") == true)
        print("Copilot model catalog, tier budgets, effort choices, persistence and failure tests passed")
    }
}
