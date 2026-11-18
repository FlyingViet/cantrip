import Foundation

/// The policy one backend applies to its own tool calls, for the calls its programs make.
struct CodeModePolicy {
    var guardrail: CantripHomeGuardrail?
    var approval: CantripHomeApproval = .ask
    var label = ""
    var workdir = ""
    var privacy: PrivacyCloudRestriction?

    func decide(_ request: CantripHomeActionRequest) -> AgentPolicyOutcome {
        AgentPolicyGate.decide(request, guardrail: guardrail, approval: approval, label: label, workdir: workdir, privacy: privacy)
    }
}

/// A backend whose tool calls Cantrip checks: a program's calls get the same check.
protocol CodeModePolicySource: AnyObject {
    var codeModePolicy: CodeModePolicy { get }
}

/// Serves `cantrip_code` inside the MCP relay: the typed API for this caller's read-only tools,
/// and programs whose every call gets the caller's own checks (see docs/code-mode.md).
final class CodeModeHost: @unchecked Sendable {
    static let shared = CodeModeHost()

    /// Who is calling: resolved again for every program, since a backend's runtime outlives a turn
    /// and the Privacy Gate's restriction is per run.
    struct Caller {
        var hello: MCPRelay.Hello
        /// Servers this run may not reach (the Privacy Gate's cloud exclusions).
        var excludedServers: Set<String> = []
        var policy = CodeModePolicy()
        /// nil when the relay would let this caller use the server, else why not.
        var serverRefusal: (String) -> String? = { _ in nil }
        /// Tool-result size for this caller.
        var outputCharacters = CodeMode.Limits().outputCharacters
    }

    /// The app's sessions, to find a caller's tab and backend.
    @MainActor static weak var manager: SessionManager?

    var resolveCaller: (MCPRelay.Hello) -> Caller = { CodeModeHost.defaultCaller($0) }
    var catalog: () async -> [PrivateLocalTools.Server] = { await PrivateLocalTools.shared.catalog() }
    var socketPath: () -> String = { MCPRelay.socketPath }
    var recipes: () -> [CodeModeRecipe] = { CodeModeRecipes.all() }
    var shapes: CodeModeShapes = .shared
    var limits = CodeMode.Limits()

    /// Backends that run on this Mac's own models: no cloud exclusions apply.
    static let localBackends: Set<String> = ["Private Local", BackendKind.localModel.rawValue]

    static func onMain<T>(_ body: @MainActor () -> T) -> T {
        Thread.isMainThread ? MainActor.assumeIsolated(body) : DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    static func defaultCaller(_ hello: MCPRelay.Hello) -> Caller {
        var caller = Caller(hello: hello)
        let found: (policy: CodeModePolicy, isLocal: Bool)? = onMain {
            guard let tab = hello.tab.flatMap(UUID.init(uuidString:)),
                  let session = manager?.managedSession(id: tab) else { return nil }
            let backend = session.codeModeBackend
            let policy = (backend as? CodeModePolicySource)?.codeModePolicy
                ?? CodeModePolicy(privacy: PrivacyRunRestrictions.restriction(for: backend))
            return (policy, session.isLocalPrivate)
        }
        if let found {
            caller.policy = found.policy
            caller.excludedServers = found.policy.privacy?.excludedServers ?? []
            if found.isLocal { caller.outputCharacters = PrivateLocalTools.resultCharacters }
        } else if !localBackends.contains(hello.backend ?? "") {
            // No tab to go by: treated as a cloud run without the private servers.
            let restriction = onMain { PrivacyCloudRestriction(PrivacyGate.shared.settings.cloudRuns) }
            caller.excludedServers = restriction.excludedServers
            caller.policy.privacy = restriction
        }
        caller.serverRefusal = { name in
            onMain {
                guard let server = MCPRegistry.load()?.servers.first(where: { $0.name == name }) else {
                    return "Cantrip has no MCP server called \(name)."
                }
                return MCPHost.refusal(MCPRelay.Hello(server: name, tab: hello.tab, backend: hello.backend), server)
            }
        }
        return caller
    }

    /// The read-only tools this caller's programs may call.
    func tools(for caller: Caller) async -> [CodeModeTool] {
        await catalog().filter { server in
            !server.blocked && server.problem == nil && !CodeMode.isBlocked(server: server.name)
                && !caller.excludedServers.contains(server.name.lowercased())
                && caller.serverRefusal(server.name) == nil
        }.flatMap { $0.tools.map(CodeModeTool.init) }
    }

    // MARK: - The relay's side

    /// `tools/list`: the program runner and the API lookup.
    func listTools(_ hello: MCPRelay.Hello) async -> [[String: Any]] {
        let caller = resolveCaller(hello)
        let tools = await tools(for: caller)
        let recipes = recipes().filter { $0.available(with: tools) }
        var limits = limits
        limits.outputCharacters = caller.outputCharacters
        return [
            ["name": CodeMode.runTool,
             "description": CodeModeAPI.runDescription(tools, recipes: recipes, shapes: shapes, limits: limits),
             "inputSchema": CodeModeAPI.runInputSchema,
             "annotations": ["readOnlyHint": true, "openWorldHint": false] as [String: Any]],
            ["name": CodeMode.apiTool,
             "description": "TypeScript declarations of the read-only tools and recipes run_tool_script's programs can use, for the servers named (all when empty).",
             "inputSchema": CodeModeAPI.apiInputSchema,
             "annotations": ["readOnlyHint": true, "openWorldHint": false] as [String: Any]],
        ]
    }

    /// `tools/call`: the reply text and whether it's an error.
    func callTool(_ name: String, arguments: [String: Any], hello: MCPRelay.Hello) async -> (text: String, isError: Bool) {
        let caller = resolveCaller(hello)
        let tools = await tools(for: caller)
        let recipes = recipes().filter { $0.available(with: tools) }
        switch name {
        case CodeMode.apiTool:
            let wanted = Set((arguments["servers"] as? [String] ?? []).map { $0.lowercased() })
            let chosen = wanted.isEmpty ? tools : tools.filter { wanted.contains($0.server.lowercased()) }
            if chosen.isEmpty, !wanted.isEmpty {
                return ("None of those servers has read-only tools this run may use. Available: \(Set(tools.map(\.server)).sorted().joined(separator: ", ")).", true)
            }
            return (CodeModeAPI.declarations(chosen, recipes: recipes, shapes: shapes), false)
        case CodeMode.runTool:
            guard let script = arguments["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("run_tool_script needs a `script`: the body of an async function that returns the result.", true)
            }
            var limits = limits
            limits.outputCharacters = caller.outputCharacters
            let result = await run(script, arguments: arguments["args"] as? [String: Any] ?? [:], tools: tools,
                                   recipes: recipes, caller: caller, limits: limits)
            return (result.reply, result.error != nil)
        default:
            return ("cantrip_code has no tool \(name).", true)
        }
    }

    func run(_ script: String, arguments: [String: Any], tools: [CodeModeTool], recipes: [CodeModeRecipe],
             caller: Caller, limits: CodeMode.Limits) async -> CodeModeRunner.Result {
        let connections = CodeModeConnections(hello: caller.hello, path: socketPath())
        defer { connections.close() }
        let runner = CodeModeRunner(tools: tools, recipes: recipes, limits: limits, shapes: shapes) { tool, arguments in
            await Self.perform(tool, arguments: arguments, caller: caller, connections: connections)
        }
        let result = await runner.run(script, arguments: arguments)
        Log.write("code mode: \(caller.hello.backend ?? "unknown") \(caller.hello.tab.map { String($0.prefix(8)) } ?? "no tab") ran a program: "
                  + "\(result.toolCalls) calls, \(result.refused) refused, \(String(format: "%.1f", result.seconds)) s"
                  + (result.error == nil ? "" : ", ended with an error"))
        return result
    }

    /// One call from a program, with the checks a direct call from this caller gets.
    static func perform(_ tool: CodeModeTool, arguments: [String: Any], caller: Caller,
                        connections: CodeModeConnections) async -> CodeModeCallOutcome {
        if caller.excludedServers.contains(tool.server.lowercased()) {
            return .refused("The Privacy Gate keeps this cloud run from \(tool.server).")
        }
        let request = CantripHomeActionRequest(kind: .mcp, server: tool.server, tool: tool.name, readOnly: true)
        switch caller.policy.decide(request) {
        case .deny(let reason, let by):
            Log.write("code mode: \(by) denied \(tool.server).\(tool.name) in a program")
            return .refused("\(by) refused \(tool.server).\(tool.name): \(reason)")
        case .ask:
            return .refused("Cantrip's policy asks before \(tool.server).\(tool.name). Call it directly (not from a program) so it can be approved.")
        case .allow, .prompt:
            break
        }
        if let refusal = caller.serverRefusal(tool.server) { return .refused(refusal) }
        do {
            let client = try await connections.client(tool.server)
            let (text, isError) = try await client.callTool(tool.name, arguments: arguments)
            return .output(text.isEmpty ? "(no output)" : text, isError: isError)
        } catch is CancellationError {
            return .refused("Stopped.")
        } catch {
            connections.drop(tool.server)
            return .output("The \(tool.server) server failed: \(error.localizedDescription)", isError: true)
        }
    }
}

/// One program's relay connections, one per server, opened as the caller (its tab and backend),
/// so the relay's per-tab, per-backend and scheduled-task checks apply to every call.
final class CodeModeConnections: @unchecked Sendable {
    private let hello: MCPRelay.Hello
    private let path: String
    private let lock = NSLock()
    private var clients: [String: MCPRelayClient] = [:]

    init(hello: MCPRelay.Hello, path: String) {
        self.hello = hello
        self.path = path
    }

    func client(_ server: String) async throws -> MCPRelayClient {
        if let client = lock.withLock({ clients[server] }) { return client }
        let client = MCPRelayClient(server: server, tab: hello.tab.flatMap(UUID.init(uuidString:)),
                                    backend: hello.backend ?? "", path: path)
        try await client.open()
        lock.withLock { clients[server] = client }
        return client
    }

    func drop(_ server: String) {
        lock.withLock { clients.removeValue(forKey: server) }?.close()
    }

    func close() {
        let open = lock.withLock { () -> [MCPRelayClient] in defer { clients = [:] }; return Array(clients.values) }
        open.forEach { $0.close() }
    }
}

/// `cantrip_code` as a relay upstream: answers the backend's JSON-RPC in the host.
final class CodeModeUpstream: Upstream, @unchecked Sendable {
    private let hello: MCPRelay.Hello
    private let host: CodeModeHost
    private let deliver: (Data) -> Void
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    init(hello: MCPRelay.Hello, host: CodeModeHost = .shared, deliver: @escaping (Data) -> Void) {
        self.hello = hello
        self.host = host
        self.deliver = deliver
    }

    func send(_ message: Data, id: Any?) {
        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              let method = object["method"] as? String, let id = object["id"] else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": CodeMode.serverName, "version": "1"]])
        case "ping":
            reply(id, [:])
        case "tools/list":
            start(id: id) { [host, hello] in ["tools": await host.listTools(hello)] }
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            start(id: id) { [host, hello] in
                let (text, isError) = await host.callTool(name, arguments: arguments, hello: hello)
                return ["content": [["type": "text", "text": text]], "isError": isError]
            }
        default:
            deliver(MCPRelay.errorReply(id: id, message: "cantrip_code doesn't support \(method).", code: -32601))
        }
    }

    private func start(id: Any, _ work: @escaping @Sendable () async -> [String: Any]) {
        let idBox = IDBox(id)
        let task = Task { [weak self] in
            let result = await work()
            self?.reply(idBox.id, result)
        }
        lock.withLock { tasks.append(task) }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        if let data = try? JSONSerialization.data(withJSONObject: object) { deliver(data) }
    }

    func finishInput() { stop() }

    func stop() {
        let running = lock.withLock { () -> [Task<Void, Never>] in defer { tasks = [] }; return tasks }
        running.forEach { $0.cancel() }
    }

    private final class IDBox: @unchecked Sendable {
        let id: Any
        init(_ id: Any) { self.id = id }
    }
}
