import Foundation

/// Claude Code's model list, read from the CLI's `initialize` reply (no model call, no tokens).
enum ClaudeModelFetcher {
    static func fetch(command: String, completion: @escaping (Result<[CopilotModelInfo], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Result { try models(command: command) })
        }
    }

    private static func models(command: String) throws -> [CopilotModelInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeModelError.unavailable }
        defer {
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.readabilityHandler = nil
        }

        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var buffer = Data(), reply: [String: Any]?
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.withLock {
                guard reply == nil else { return }
                if data.isEmpty { done.signal(); return }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["type"] as? String == "control_response",
                          let response = object["response"] as? [String: Any],
                          response["request_id"] as? String == "cantrip-models" else { continue }
                    reply = response["response"] as? [String: Any] ?? [:]
                    done.signal()
                    return
                }
            }
        }
        var request = try JSONSerialization.data(withJSONObject: [
            "type": "control_request", "request_id": "cantrip-models", "request": ["subtype": "initialize"],
        ])
        request.append(10)
        try? input.fileHandleForWriting.write(contentsOf: request)
        guard done.wait(timeout: .now() + 25) == .success else { throw ClaudeModelError.timeout }
        guard let models = lock.withLock({ reply })?["models"] as? [[String: Any]] else {
            throw ClaudeModelError.response
        }
        return catalog(models)
    }

    /// `[1m]` aliases are the 1M-token context variants; the others leave the window unknown.
    static func catalog(_ models: [[String: Any]]) -> [CopilotModelInfo] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard let id = model["value"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let efforts = model["supportsEffort"] as? Bool == true
                ? model["supportedEffortLevels"] as? [String] ?? [] : []
            return CopilotModelInfo(id: id, contextWindow: id.hasSuffix("[1m]") ? 1_000_000 : nil,
                                    reasoningEfforts: efforts, contextTiers: [])
        }
    }
}

enum ClaudeModelError: String, Error, LocalizedError {
    case unavailable, response, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Could not start the Claude Code CLI. Check its path in Settings."
        case .response: return "Claude Code returned no model list. Update the CLI and retry."
        case .timeout: return "The Claude Code model lookup timed out. Retry when the Mac is online."
        }
    }
}

/// The model list per-tab settings use for the Mac's backend.
struct TabModelCatalog {
    let backend: BackendKind
    let models: [CopilotModelInfo]
    /// The CLI's own default when a tab picks none.
    let fileDefaultModel: String?
    let fileDefaultContextTier: String?
    let refreshError: String?
    let isRefreshing: Bool

    func info(_ id: String) -> CopilotModelInfo? {
        models.first { $0.id == (id.isEmpty ? fileDefaultModel ?? "" : id) }
    }
}

extension AppSettings {
    /// Backends whose tabs can pick their own model and effort.
    static let tabModelBackends: Set<BackendKind> = [.copilot, .claudeCode]

    func tabModelCatalog(for backend: BackendKind) -> TabModelCatalog {
        backend == .claudeCode
            ? TabModelCatalog(backend: backend, models: claudeModelCatalog, fileDefaultModel: "default",
                              fileDefaultContextTier: nil, refreshError: claudeModelRefreshError,
                              isRefreshing: claudeRefreshInFlight)
            : TabModelCatalog(backend: backend, models: copilotModelCatalog, fileDefaultModel: copilotFileDefaultModel,
                              fileDefaultContextTier: copilotFileContextTier, refreshError: copilotModelRefreshError,
                              isRefreshing: copilotRefreshInFlight)
    }

    /// The Mac-wide model settings a tab without its own uses.
    func tabModelDefaults(for backend: BackendKind) -> SessionModelSelection {
        backend == .claudeCode
            ? SessionModelSelection(model: claudeModel, effort: claudeEffort, contextTier: "")
            : SessionModelSelection(model: copilotModel, effort: copilotEffort, contextTier: copilotContextTier)
    }

    func refreshTabModels(for backend: BackendKind) {
        backend == .claudeCode ? refreshClaudeModels() : refreshCopilotModels()
    }

    func refreshTabModelsIfNeeded(for backend: BackendKind) {
        backend == .claudeCode ? refreshClaudeModelsIfNeeded() : refreshCopilotModelsIfNeeded()
    }

    func refreshClaudeModels(
        using loader: (String, @escaping (Result<[CopilotModelInfo], Error>) -> Void) -> Void = ClaudeModelFetcher.fetch
    ) {
        guard !claudeRefreshInFlight else { return }
        guard let command = ToolLocator.shared.claude(configured: claudePath) else {
            claudeModelRefreshError = ClaudeModelError.unavailable.localizedDescription
            return
        }
        claudeRefreshInFlight = true
        claudeModelRefreshError = nil
        loader(command) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.claudeRefreshInFlight = false
                switch result {
                case .success(let catalog) where !catalog.isEmpty:
                    self.claudeModelCatalog = catalog
                    self.claudeCatalogUpdatedAt = Date()
                    Log.write("model discovery: found \(catalog.count) Claude Code models")
                case .success, .failure:
                    let error: ClaudeModelError
                    if case .failure(let failure) = result { error = failure as? ClaudeModelError ?? .response }
                    else { error = .response }
                    self.claudeModelRefreshError = error.localizedDescription
                    Log.write("claude model discovery failed: \(error.rawValue); keeping cached catalog")
                }
            }
        }
    }

    func refreshClaudeModelsIfNeeded() {
        if claudeCatalogUpdatedAt.map({ Date().timeIntervalSince($0) < 6 * 60 * 60 }) != true {
            refreshClaudeModels()
        }
    }
}
