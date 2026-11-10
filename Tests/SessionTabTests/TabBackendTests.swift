import Foundation

extension SessionTabTests {
    final class TabBackendFixture: Backend {
        var requests: [BackendRequest] = []
        var sink: ((BackendEvent) -> Void)?
        func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
            requests.append(request)
            sink = onEvent
        }
        func cancel() {}
        func reset() {}
    }

    /// A tab can run on a backend of its own: saved with the tab, used for its runs, its model list
    /// and its usage-limit backups, and set from every client through the model settings API.
    @MainActor
    static func testTabBackend() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.claudeModelCatalog, settings.claudeCatalogUpdatedAt,
                     settings.limitFallbackBackends, settings.memoryEnabled, settings.attachScreen,
                     settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.claudeModelCatalog, settings.claudeCatalogUpdatedAt,
             settings.limitFallbackBackends, settings.memoryEnabled, settings.attachScreen,
             settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        settings.backend = .copilot
        settings.limitFallbackBackends = []
        // A fresh catalog, so nothing starts the real Claude Code CLI to refresh it.
        settings.claudeModelCatalog = [
            CopilotModelInfo(id: "claude-example-2", reasoningEfforts: ["low", "high"], contextTiers: []),
            CopilotModelInfo(id: "claude-example-1", reasoningEfforts: [], contextTiers: []),
        ]
        settings.claudeCatalogUpdatedAt = Date()

        let copilot = TabBackendFixture(), claude = TabBackendFixture()
        let manager = SessionManager()
        let chat = ChatSession(copilotBackend: copilot, backendOverrides: [.claudeCode: claude])
        manager.sessions.append(chat)
        defer { chat.cancel() }

        // A tab follows the Mac's backend until it picks one.
        precondition(chat.tabMetadata.backend == nil && chat.effectiveBackendKind == .copilot && chat.modelSettingsBackend == .copilot)
        let initial = chat.modelSettingsSnapshot
        precondition(initial.backend == "Copilot" && initial.ownBackend == nil && initial.macBackend == "Copilot"
                     && initial.backends.map(\.id) == ["Copilot", "Claude Code", "Codex", "Antigravity"], "\(initial.backends)")

        // Another backend's settings can be shown without saving anything.
        let preview = chat.modelSettingsSnapshot(on: .claudeCode)
        precondition(preview.backend == "Claude Code" && preview.models.contains { $0.id == "claude-example-2" }
                     && preview.usesDefaults && preview.revision == chat.modelSettingsRevision && chat.tabMetadata.backend == nil)

        // The backend and its model save together, and the model is checked against that backend's list.
        let pick = SessionModelSelection(model: "claude-example-2", effort: "high", contextTier: "")
        let firstRevision = chat.modelSettingsRevision
        do {
            try chat.updateModelSettings(SessionModelSelection(model: "model-not-offered", effort: "", contextTier: ""),
                                         revision: firstRevision, backend: .backend(.claudeCode))
            preconditionFailure("a model the backend doesn't offer")
        } catch let error as SessionModelSettingsError { precondition(error.status == 400 && chat.tabMetadata.backend == nil) }
        try chat.updateModelSettings(pick, revision: firstRevision, backend: .backend(.claudeCode))
        precondition(chat.effectiveBackendKind == .claudeCode && chat.modelSettingsBackend == .claudeCode
                     && chat.modelSelection == pick && chat.modelSettingsRevision != firstRevision)
        let stored = SessionTabMetadata.load(id: chat.id)
        precondition(stored.backend == .claudeCode && stored.claudeModelSettings == pick && stored.modelSettings == nil, "saved with the tab")
        do {
            try chat.updateModelSettings(nil, revision: firstRevision, backend: .mac)
            preconditionFailure("a stale revision")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }

        // Its runs go to its backend; other tabs keep the Mac's.
        chat.submitRemote("Example task on the tab's backend")
        try await waitForJournalTest { claude.requests.count == 1 }
        precondition(copilot.requests.isEmpty && claude.requests[0].prompt.contains("Example task on the tab's backend"))
        claude.sink?(.textDelta("Done."))
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        let other = ChatSession(copilotBackend: TabBackendFixture())
        defer { other.cancel() }
        precondition(other.effectiveBackendKind == .copilot && other.modelSettingsBackend == .copilot)

        // At a usage limit it moves to the Mac's backend first, then the Mac's backups.
        settings.limitFallbackBackends = [BackendKind.codex.rawValue]
        precondition(chat.fallbackChain.map(\.backend) == ["Copilot", "Codex"] && other.fallbackChain.map(\.backend) == ["Codex"],
                     "\(chat.fallbackChain)")
        settings.limitFallbackBackends = [BackendKind.copilot.rawValue, BackendKind.codex.rawValue]
        precondition(chat.fallbackChain.map(\.backend) == ["Copilot", "Codex"], "the Mac's backend isn't listed twice")
        settings.limitFallbackBackends = []

        // Changing only the backend keeps the model the tab picked there.
        try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision, backend: .mac, keepsSelection: true)
        precondition(chat.effectiveBackendKind == .copilot && chat.tabMetadata.claudeModelSettings == pick)
        try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision, backend: .backend(.claudeCode), keepsSelection: true)
        precondition(chat.modelSelection == pick, "back on Claude Code, the tab's own model there")

        // Not while the tab works, and never for Cantrip Home or a backend tabs can't pick.
        chat.isStreaming = true
        precondition(chat.modelSettingsSnapshot.backendUnavailableReason != nil && initial.backendUnavailableReason == nil)
        do {
            try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision, backend: .mac, keepsSelection: true)
            preconditionFailure("busy")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409 && chat.effectiveBackendKind == .claudeCode) }
        chat.isStreaming = false
        do {
            try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision, backend: .backend(.localModel), keepsSelection: true)
            preconditionFailure("not a tab backend")
        } catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        let home = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: TabBackendFixture())
        defer { home.cancel() }
        precondition(!home.supportsTabBackend && home.tabBackendChoices.isEmpty && home.modelSettingsSnapshot.backends.isEmpty)
        do {
            try home.updateModelSettings(nil, revision: home.modelSettingsRevision, backend: .backend(.claudeCode), keepsSelection: true)
            preconditionFailure("Home keeps the Mac's backend")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409 && home.effectiveBackendKind == .copilot) }
        let odd = UUID()
        UserDefaults.standard.set(["isLocked": false, "backend": BackendKind.localModel.rawValue], forKey: "sessionTab-\(odd.uuidString)")
        precondition(SessionTabMetadata.load(id: odd).backend == nil, "a saved backend tabs can't pick is ignored")
        SessionTabMetadata.remove(id: odd)

        // Every client: `?backend=` shows a backend's settings unsaved; `backend` saves (null = the Mac's).
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ method: String = "GET", path: String = "/model-settings", body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let current = try await request()
        precondition(current.0 == 200 && current.1["backend"] as? String == "Claude Code" && current.1["ownBackend"] as? String == "Claude Code"
                     && current.1["macBackend"] as? String == "Copilot" && (current.1["backends"] as? [[String: Any]])?.count == 4, "\(current)")
        let toMac = try await request("POST", body: ["revision": current.1["revision"]!, "backend": NSNull()])
        precondition(toMac.0 == 200 && toMac.1["backend"] as? String == "Copilot" && toMac.1["ownBackend"] == nil
                     && chat.effectiveBackendKind == .copilot, "\(toMac)")
        let previewed = try await request(path: "/model-settings?backend=Claude%20Code")
        precondition(previewed.0 == 200 && previewed.1["backend"] as? String == "Claude Code" && previewed.1["usesDefaults"] as? Bool == false
                     && (previewed.1["selection"] as? [String: String])?["model"] == "claude-example-2"
                     && chat.effectiveBackendKind == .copilot, "a preview saves nothing: \(previewed)")
        let mac = try await request(path: "/model-settings?backend=mac")
        precondition(mac.0 == 200 && mac.1["backend"] as? String == "Copilot")
        for bad in ["/model-settings?backend=Local%20Model", "/model-settings?backend=nope"] {
            let rejected = try await request(path: bad)
            precondition(rejected.0 == 400, bad)
        }
        let revision = chat.modelSettingsRevision
        for invalid in [["revision": revision, "backend": 5], ["revision": revision, "backend": "Local Model"],
                        ["revision": revision, "backend": "Claude Code", "model": "claude-example-1"]] as [[String: Any]] {
            let rejected = try await request("POST", body: invalid)
            precondition(rejected.0 == 400 && chat.effectiveBackendKind == .copilot, "\(invalid): \(rejected)")
        }
        let both = try await request("POST", body: ["revision": revision, "backend": "Claude Code", "usesDefaults": false,
                                                    "model": "claude-example-1", "effort": "", "contextTier": ""])
        precondition(both.0 == 200 && chat.effectiveBackendKind == .claudeCode && chat.modelSelection.model == "claude-example-1", "\(both)")
        let tab = (try await request(path: "")).1["session"] as? [String: Any]
        precondition(tab?["backend"] as? String == "Claude Code" && tab?["hasOwnBackend"] as? Bool == true, "the tab says where it runs")
        print("Tab backend: per-tab backend saved with the tab, runs, previews, backups, API and Cantrip Home passed")
    }
}
