import Foundation

/// One model from Codex's `model/list`: the efforts it accepts and its default.
struct CodexModel: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var efforts: [String]
    var defaultEffort: String?
    var isDefault = false
}

enum CodexModelError: Error, LocalizedError {
    case unavailable, response

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn't start the Codex CLI. Check its path in Settings."
        case .response: return "Codex returned no model list. Run `codex login`, then retry."
        }
    }
}

/// Lists the account's models through a short-lived app server (no model call, no quota).
enum CodexModelFetcher {
    static func parse(_ result: [String: Any]) -> [CodexModel] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { entry in
            guard entry["hidden"] as? Bool != true, let id = (entry["model"] ?? entry["id"]) as? String, !id.isEmpty else {
                return nil
            }
            let efforts = (entry["supportedReasoningEfforts"] as? [Any] ?? []).compactMap { item -> String? in
                (item as? String) ?? ((item as? [String: Any])?["reasoningEffort"] as? String)
            }
            return CodexModel(id: id, displayName: entry["displayName"] as? String ?? id, efforts: efforts,
                              defaultEffort: entry["defaultReasoningEffort"] as? String,
                              isDefault: entry["isDefault"] as? Bool ?? false)
        }
    }

    static func fetch(executable: String, completion: @escaping (Result<[CodexModel], Error>) -> Void) {
        Task.detached(priority: .utility) {
            do {
                var models: [CodexModel] = []
                var cursor: String?
                try await CodexAppServer.withServer(executable: executable) { server in
                    repeat {
                        var params: [String: Any] = [:]
                        if let cursor { params["cursor"] = cursor }
                        let page = try await server.request("model/list", params, timeout: 30)
                        models += parse(page)
                        cursor = page["nextCursor"] as? String
                    } while cursor != nil
                }
                completion(models.isEmpty ? .failure(CodexModelError.response) : .success(models))
            } catch {
                completion(.failure(error is CodexAppServer.Failure ? CodexModelError.response : CodexModelError.unavailable))
            }
        }
    }
}

extension AppSettings {
    /// Codex's models in the shape per-tab settings and Remote use.
    var codexModelCatalog: [CopilotModelInfo] {
        codexAvailableModels.map { CopilotModelInfo(id: $0.id, contextWindow: nil, reasoningEfforts: $0.efforts, contextTiers: []) }
    }

    func codexModelLabel(_ id: String) -> String {
        codexAvailableModels.first { $0.id == id }?.displayName ?? id
    }

    func refreshCodexModels(
        using loader: (String, @escaping (Result<[CodexModel], Error>) -> Void) -> Void = CodexModelFetcher.fetch
    ) {
        guard !codexRefreshInFlight else { return }
        let configured = codexPath.trimmingCharacters(in: .whitespaces)
        guard let executable = ToolLocator.shared.codex(configured: configured) else {
            codexModelRefreshError = CodexModelError.unavailable.localizedDescription
            return
        }
        codexRefreshInFlight = true
        codexModelRefreshError = nil
        loader(executable) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.codexRefreshInFlight = false
                switch result {
                case .success(let models):
                    self.codexAvailableModels = models
                    self.codexCatalogUpdatedAt = Date()
                    Log.write("model discovery: found \(models.count) entries via codex model/list")
                case .failure(let error):
                    self.codexModelRefreshError = (error as? CodexModelError ?? .response).localizedDescription
                    Log.write("model discovery: codex model/list failed (\(error))")
                }
            }
        }
    }

    /// At launch, and when a picker opens with a list over six hours old.
    func refreshCodexModelsIfNeeded() {
        if let date = codexCatalogUpdatedAt, Date().timeIntervalSince(date) < 6 * 3_600, !codexAvailableModels.isEmpty { return }
        refreshCodexModels()
    }
}
