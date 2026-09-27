import Foundation

private final class MCPAppBackendFixture: Backend {
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
    @MainActor
    static func testMCPAppTranscripts() async throws {
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"hi"}]"#
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: Data(legacy.utf8))
        precondition(decoded.first?.apps.isEmpty == true, "transcripts from before MCP Apps must load")
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        precondition(!encoded.contains("\"apps\""), "messages without views should not grow an apps key")

        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let backend = MCPAppBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Find login screens")
        try await waitForJournalTest { backend.requests.count == 1 }
        let app = MCPAppPayload(
            id: "call-1", serverName: "mobbin", toolName: "search_screens", title: "Search Screens",
            resourceURI: "ui://mobbin/search-screens.html", html: "<p>gallery</p>",
            csp: MCPAppCSP(resourceDomains: ["https://mobbin.com"]), permissions: [], prefersBorder: nil,
            toolInput: #"{"query":"login"}"#, toolResult: #"{"content":[]}"#, tool: #"{"name":"search_screens"}"#)
        var step = ToolActivityFactory.start(id: "call-1", toolName: "mobbin-search_screens", arguments: [:])
        backend.sink?(.activity(step))
        step.state = .succeeded
        step.app = app
        backend.sink?(.activity(step))
        backend.sink?(.activity(step))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.messages.last?.apps == [app], "a completed view should attach once to its reply")

        // A gallery-only reply is not an empty husk: it survives a relaunch.
        let restored = ChatSession(id: chat.id, copilotBackend: MCPAppBackendFixture())
        precondition(restored.messages.contains { $0.role == .assistant && $0.apps == [app] },
                     "views should persist with the transcript")

        // The view's model context rides along with the next prompt only.
        chat.setMCPAppContext(app, text: "User picked Zopa Bank")
        chat.submit("Use that one")
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("Context from the mobbin app view")
                     && backend.requests[1].prompt.contains("User picked Zopa Bank"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        chat.submit("Anything else?")
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(!backend.requests[2].prompt.contains("Zopa Bank"), "view context is consumed once")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Approved view messages are literal prompts, never local commands.
        chat.submitMCPAppMessage("!touch /tmp/cantrip-mcp-app-should-not-exist", from: app)
        try await waitForJournalTest { backend.requests.count == 4 }
        precondition(backend.requests[3].prompt.contains("[From the mobbin view] !touch"),
                     "view messages must reach the model, not the shell")
        precondition(!FileManager.default.fileExists(atPath: "/tmp/cantrip-mcp-app-should-not-exist"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Context from a view never leaks into a new conversation.
        chat.setMCPAppContext(app, text: "STALE_VIEW_CONTEXT")
        chat.newConversation()
        chat.submit("Fresh start")
        try await waitForJournalTest { backend.requests.count == 5 }
        precondition(!backend.requests[4].prompt.contains("STALE_VIEW_CONTEXT"))

        // With views turned off, new ones are not attached.
        settings.copilotMCPApps = false
        defer { settings.copilotMCPApps = true }
        var offStep = ToolActivityFactory.start(id: "call-2", toolName: "mobbin-search_screens", arguments: [:])
        offStep.state = .succeeded
        offStep.app = MCPAppPayload(
            id: "call-2", serverName: "mobbin", toolName: "search_screens", title: nil,
            resourceURI: "ui://mobbin/search-screens.html", html: "<p>off</p>", csp: MCPAppCSP(),
            permissions: [], prefersBorder: nil, toolInput: "{}", toolResult: "{}", tool: "{}")
        backend.sink?(.activity(offStep))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        precondition(!chat.messages.contains { $0.apps.contains { $0.id == "call-2" } },
                     "views must not attach while the setting is off")

        var unavailable: Error?
        chat.mcpAppRequest(app, method: "tools/call", params: [:]) { result in
            if case .failure(let error) = result { unavailable = error }
        }
        precondition(unavailable is MCPAppRequestError, "non-SDK backends cannot proxy view requests")
    }
}
