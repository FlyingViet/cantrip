import Foundation

/// Antigravity's model list, read from `agy models` (no model call, no tokens).
///
/// The list depends on the signed-in account and changes as Antigravity adds models (for
/// example Claude Opus 5.5 next to Gemini 4 Argon), so Cantrip asks the CLI instead of
/// shipping a fixed list. `AppSettings.agyDefaultModels` only covers the time before the
/// first lookup succeeds.
enum AntigravityModelFetcher {
    struct Model: Equatable {
        let id: String
        let name: String
    }

    static func fetch(command: String, completion: @escaping (Result<[Model], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Result { try models(command: command) })
        }
    }

    private static func models(command: String) throws -> [Model] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        environment["NO_COLOR"] = "1"
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(command, ["models"], environment: environment,
                                           directory: FileManager.default.homeDirectoryForCurrentUser,
                                           errorOutput: .discard, timeout: 30)
        } catch {
            throw AntigravityModelError.unavailable
        }
        if result.timedOut { throw AntigravityModelError.timeout }
        guard result.succeeded else { throw AntigravityModelError.response }
        let models = parse(result.text)
        guard !models.isEmpty else { throw AntigravityModelError.response }
        return models
    }

    /// `agy models` prints one `slug<TAB>Display name` line per model, after a
    /// "Fetching available models..." status line that has no tab.
    static func parse(_ text: String) -> [Model] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(separator: "\t", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  parts[0].range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
                  seen.insert(parts[0]).inserted else { return nil }
            return Model(id: parts[0], name: parts[1].isEmpty ? parts[0] : parts[1])
        }
    }
}

enum AntigravityModelError: String, Error, LocalizedError {
    case unavailable, response, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Could not start the Antigravity CLI. Check its path in Settings."
        case .response: return "Antigravity returned no model list. Run `agy` once to sign in, then retry."
        case .timeout: return "The Antigravity model lookup timed out. Retry when the Mac is online."
        }
    }
}

extension AppSettings {
    /// A readable name for an Antigravity model slug, e.g. "Claude Opus 5.5 (Medium)".
    func agyModelLabel(_ id: String) -> String {
        agyModelNames[id] ?? id
    }

    /// Models the Antigravity pickers offer: the discovered list plus a saved custom choice.
    var agyModelOptions: [String] {
        let model = agyModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !agyAvailableModels.contains(model) else { return agyAvailableModels }
        return agyAvailableModels + [model]
    }

    func refreshAntigravityModels(
        using loader: (String, @escaping (Result<[AntigravityModelFetcher.Model], Error>) -> Void) -> Void
            = AntigravityModelFetcher.fetch
    ) {
        guard !agyRefreshInFlight else { return }
        let configured = agyPath.trimmingCharacters(in: .whitespaces)
        guard let command = AntigravityBackend.resolveExecutable(customPath: configured) else {
            agyModelRefreshError = AntigravityModelError.unavailable.localizedDescription
            return
        }
        agyRefreshInFlight = true
        agyModelRefreshError = nil
        loader(command) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.agyRefreshInFlight = false
                guard self.agyPath.trimmingCharacters(in: .whitespaces) == configured else {
                    self.agyModelRefreshError = "Antigravity path changed during refresh. Refresh again for the new installation."
                    return
                }
                switch result {
                case .success(let models):
                    self.agyAvailableModels = models.map(\.id)
                    self.agyModelNames = Dictionary(models.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                    self.agyCatalogUpdatedAt = Date()
                    Log.write("model discovery: found \(models.count) entries via agy models")
                case .failure(let error):
                    self.agyModelRefreshError = (error as? AntigravityModelError ?? .response).localizedDescription
                    Log.write("model discovery: agy models failed (\(error))")
                }
            }
        }
    }

    /// Refreshes once per launch, and again if the last lookup is over a day old.
    func refreshAntigravityModelsIfNeeded() {
        if let date = agyCatalogUpdatedAt, Date().timeIntervalSince(date) < 86_400 { return }
        refreshAntigravityModels()
    }
}
