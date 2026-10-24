import Foundation

/// `Cantrip Gateway Mac --direct-local-check [--url URL] [--model NAME] [--prompt TEXT]`
/// From Terminal: checks direct local mode with this app's own transport and settings (the saved
/// ones unless overridden), lists the server's local models, confirms the model, and with
/// `--prompt` streams one reply (without tools). Saves nothing and doesn't open a window.
///
/// `Cantrip Gateway Mac --mcp-check [--server NAME]` lists the MCP servers set up on this Mac,
/// starts each one that can run here (or just NAME) the way the app does, lists its tools and
/// stops it. It calls no tools. Exit status 0 = OK.
enum DirectLocalCheck {
    static let flag = "--direct-local-check"
    static let mcpFlag = "--mcp-check"

    static func runIfRequested(_ arguments: [String]) -> Int32? {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains(mcpFlag) {
            let server = value("--server")
            return wait { await runMCP(server: server) }
        }
        guard arguments.contains(flag) else { return nil }
        var configuration = DirectLocalStore().loadConfiguration()
        if let url = value("--url") { configuration.baseURL = url }
        if let model = value("--model") { configuration.model = model }
        let prompt = value("--prompt")
        let checked = configuration
        return wait { await run(checked, prompt: prompt) }
    }

    private static func wait(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let status = Status()
        Task.detached {
            status.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return status.value
    }

    static func runMCP(server name: String?) async -> Int32 {
        func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        let servers = DirectLocalMCPConfig.load()
        if servers.isEmpty { out("No MCP servers in ~/.copilot/mcp-config.json or ~/.claude.json.") }
        for server in servers {
            out("\(server.name): \(server.unavailableReason ?? "runs on this Mac") — \(server.detail)")
        }
        let targets = servers.filter { $0.isAvailable && (name == nil || $0.name == name) }
        if let name, targets.isEmpty {
            FileHandle.standardError.write(Data("MCP check failed: no server named \(name) that runs on this Mac.\n".utf8))
            return 1
        }
        let hub = DirectLocalMCPHub(idleTimeout: 600)
        var failed = false
        for server in targets {
            let started = Date()
            do {
                let tools = try await hub.tools(for: server)
                var settings = DirectLocalToolSettings()
                settings.setEnabled(server.name, true)
                let offered = DirectLocalTools.offered(
                    servers: [server],
                    catalog: [server.name: DirectLocalToolCatalogEntry(fingerprint: server.fingerprint, tools: tools, loaded: Date())],
                    settings: settings)
                out(String(format: "\n%@: started and listed %d tools in %.1f s; %d allowed by its config use about %d tokens:",
                           server.name, tools.count, Date().timeIntervalSince(started), offered.count,
                           DirectLocalTools.tokens(characters: DirectLocalTools.characters(offered))))
                for tool in offered {
                    out("  \(tool.functionName)\(tool.tool.readOnly ? " (read-only)" : "")")
                }
            } catch {
                failed = true
                out("\n\(server.name): FAILED: \(error.localizedDescription)")
            }
        }
        await hub.stopAll()
        DirectLocalMCPConnection.terminateAll()
        out(failed ? "FAILED" : "OK")
        return failed ? 1 : 0
    }

    private final class Status: @unchecked Sendable { var value: Int32 = 1 }

    static func run(_ configuration: DirectLocalConfiguration, prompt: String?) async -> Int32 {
        var configuration = configuration
        let client = DirectLocalClient()
        defer { client.close() }
        func out(_ text: String, terminator: String = "\n") {
            FileHandle.standardOutput.write(Data((text + terminator).utf8))
        }
        do {
            out("Server: \(try configuration.endpoint("").absoluteString)")
            let models = try await client.models(configuration)
            out("Models: \(models.isEmpty ? "(none)" : models.joined(separator: ", "))")
            if configuration.model.isEmpty, let first = models.first { configuration.model = first }
            try await client.verify(configuration)
            out("Model: \(configuration.model) (installed on this server)")
            if let prompt {
                let messages = DirectLocalHistory.chatMessages(
                    [DirectLocalMessage(role: .user, content: prompt)], configuration: configuration)
                out("Reply: ", terminator: "")
                let started = Date()
                do {
                    try await client.chat(configuration, messages: messages) { event in
                        if case .content(let text) = event { out(text, terminator: "") }
                    }
                } catch {
                    out("")
                    throw error
                }
                out(String(format: "\n(%.1f s)", Date().timeIntervalSince(started)))
            }
            out("OK")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Direct local check failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
