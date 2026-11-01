import Foundation

extension SessionTabTests {
    @MainActor
    static func testMCPSharing() async throws {
        requireTemporaryHome()
        try testMCPImport()
        testMCPBackendConfigs()
        try await testMCPOAuth()
        try await testMCPRelay()
        try testMCPMigration()
        try await testMCPRemoteList()
        print("MCP sharing: import, backend configs, OAuth with single-flight refresh, the relay and the remote list passed")
    }

    /// What Remote clients get: whether a server has a credential in the keychain, never its name or value.
    @MainActor
    static func testMCPRemoteList() async throws {
        let secrets = MCPSecrets.Store.memory()
        try secrets.set("secret-flows-value", for: MCPSecrets.headerAccount("flows", "X-Api-Key"))
        let hub = MCPServerHub(signIns: MCPSignIns(secrets: secrets), snapshot: MCPRegistry.Snapshot(servers: [
            MCPServer(name: "notes", command: "/usr/bin/python3"),
            MCPServer(name: "flows", url: "https://flows.example.com/mcp", secretHeaders: ["X-Api-Key"]),
            MCPServer(name: "vault", command: "/usr/bin/python3", secretEnv: ["VAULT_SESSION"]),
        ], importedAt: Date()))
        await hub.refreshStates()
        let payload = hub.remotePayload()
        guard let servers = payload["servers"] as? [[String: Any]] else { preconditionFailure("The list has servers") }
        let credentials = Dictionary(uniqueKeysWithValues: servers.map { ($0["name"] as? String ?? "", $0["credentials"] as? Bool) })
        precondition(credentials == ["notes": false, "flows": true, "vault": true], "credentials flags: \(credentials)")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        precondition(!text.contains("X-Api-Key") && !text.contains("VAULT_SESSION") && !text.contains("secret-flows-value"),
                     "A Remote client never sees a credential's name or value")
    }

    static let mcpCopilotFixture: [String: Any] = ["mcpServers": [
        "mobbin": ["type": "http", "url": "https://mcp.example.com/mcp", "headers": [String: String](), "tools": ["*"]],
        "vault": ["type": "local", "command": "/usr/bin/python3", "args": ["vault.py"],
                  "env": ["PATH": "/usr/bin", "VAULT_CLI_PATH": "/opt/vault"], "tools": ["status", "get"]],
        "notes": ["type": "local", "command": "/usr/bin/python3", "args": ["notes.py"], "tools": ["*"]],
    ]]
    static let mcpClaudeFixture: [String: Any] = ["mcpServers": [
        "notes": ["command": "npx", "args": ["-y", "notes-server"], "env": ["NOTES_TOKEN": "secret-notes"]],
        "flows": ["type": "http", "url": "https://flows.example.com/mcp", "headers": ["Authorization": "Bearer secret-flows"]],
        "errors": ["type": "http", "url": "https://errors.example.com/mcp"],
    ]]

    static func testMCPImport() throws {
        let imported = MCPRegistry.importConfigs(copilot: mcpCopilotFixture, claude: mcpClaudeFixture)
        let byName = Dictionary(uniqueKeysWithValues: imported.servers.map { ($0.name, $0) })
        precondition(byName.keys.sorted() == ["errors", "flows", "mobbin", "notes", "vault"])
        precondition(byName["mobbin"]?.oauth == true && byName["mobbin"]?.isRelayed == true, "A remote server signs in through Cantrip")
        precondition(byName["vault"]?.tools == ["status", "get"] && byName["vault"]?.isRelayed == true
                     && byName["vault"]?.env["VAULT_CLI_PATH"] == "/opt/vault" && byName["vault"]?.secretEnv.isEmpty == true,
                     "A tool limit is kept and enforced by the relay; paths aren't secrets")
        precondition(byName["notes"]?.command == "/usr/bin/python3" && byName["notes"]?.isRelayed == false,
                     "On a clash, the definition without credentials wins")
        precondition(imported.secrets[MCPSecrets.envAccount("notes", "NOTES_TOKEN")] == "secret-notes",
                     "The other definition's credential is still kept, in the keychain")
        precondition(byName["flows"]?.secretHeaders == ["Authorization"] && byName["flows"]?.oauth == false
                     && byName["flows"]?.headers.isEmpty == true
                     && imported.secrets[MCPSecrets.headerAccount("flows", "Authorization")] == "Bearer secret-flows",
                     "A credential header moves to the keychain")
        precondition(byName["errors"]?.oauth == true, "A remote server without credentials uses OAuth")
        precondition(!imported.notes.isEmpty, "Clashes are reported")
        precondition(MCPRegistry.isSecretEnv("GITHUB_TOKEN") && MCPRegistry.isSecretEnv("api_key")
                     && !MCPRegistry.isSecretEnv("PATH") && !MCPRegistry.isSecretEnv("BW_CLI_PATH"), "Secret detection")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID())/servers.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try MCPRegistry.save(MCPRegistry.Snapshot(servers: imported.servers, importedAt: Date()), to: file)
        let saved = try String(contentsOf: file, encoding: .utf8)
        precondition(!saved.contains("secret-"), "The server list never holds a credential")
        precondition(MCPRegistry.load(from: file)?.servers == imported.servers, "The list round-trips")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600, "The list is private to the user")
    }

    static func testMCPBackendConfigs() {
        var snapshot = MCPRegistry.Snapshot(servers: MCPRegistry.importConfigs(copilot: mcpCopilotFixture, claude: mcpClaudeFixture).servers)
        if let index = snapshot.servers.firstIndex(where: { $0.name == "errors" }) {
            snapshot.servers[index].disabledBackends = [BackendKind.copilot.rawValue]
        }
        let relay = "/checkout/Scripts/cantrip-mcp"
        let claude = MCPBackendConfig.claude(snapshot, excluded: ["notes"], relay: relay)["mcpServers"] as? [String: [String: Any]] ?? [:]
        precondition(claude.keys.sorted() == ["errors", "flows", "mobbin", "vault"], "A tab's excluded servers are left out")
        precondition(claude["mobbin"]?["command"] as? String == relay
                     && claude["mobbin"]?["args"] as? [String] == ["mobbin", "--backend", "Claude Code"]
                     && claude["mobbin"]?["type"] as? String == "stdio", "Relayed servers run the relay")
        let rendered = String(decoding: (try? JSONSerialization.data(withJSONObject: claude)) ?? Data(), as: UTF8.self)
        precondition(!rendered.contains("secret-"), "No backend config carries a credential")

        let copilot = MCPBackendConfig.copilot(snapshot, relay: relay)["mcpServers"] as? [String: [String: Any]] ?? [:]
        precondition(copilot["errors"] == nil, "A server switched off for a backend isn't in its config")
        precondition(copilot["notes"]?["type"] as? String == "local" && copilot["notes"]?["command"] as? String == "/usr/bin/python3"
                     && copilot["notes"]?["tools"] as? [String] == ["*"], "Plain local servers keep their command")
        precondition(copilot["vault"]?["command"] as? String == relay, "A tool-limited server goes through the relay")

        let codex = MCPBackendConfig.codexArgs(snapshot, relay: relay)
        precondition(codex.contains("mcp_servers.mobbin.command=\"\(relay)\"")
                     && codex.contains("mcp_servers.mobbin.args=[\"mobbin\",\"--backend\",\"Codex\"]"), "Codex gets -c overrides")

        let existing: [String: Any] = ["mcpServers": ["own": ["command": "own-server"], "stale": ["command": "x"]], "other": 1]
        let antigravity = MCPBackendConfig.antigravity(existing: existing, snapshot: snapshot, managed: ["stale"], relay: relay)
        let servers = antigravity.config["mcpServers"] as? [String: Any] ?? [:]
        precondition(servers["own"] != nil && servers["stale"] == nil && servers["mobbin"] != nil && antigravity.config["other"] != nil,
                     "Antigravity keeps its own servers and drops ones Cantrip stopped managing")
        precondition(antigravity.managed.contains("mobbin") && !antigravity.managed.contains("own"))

        // OpenAI models refuse tools in their reserved `browser` namespace, so no backend gets that name.
        let reserved = MCPRegistry.Snapshot(servers: [MCPServer(name: "browser", command: "/usr/bin/true"),
                                                      MCPServer(name: "agent_chrome", command: "/usr/bin/true")])
        let reservedCopilot = MCPBackendConfig.copilot(reserved, relay: relay)["mcpServers"] as? [String: Any] ?? [:]
        let reservedClaude = MCPBackendConfig.claude(reserved, relay: relay)["mcpServers"] as? [String: Any] ?? [:]
        let reservedAgy = MCPBackendConfig.antigravity(existing: nil, snapshot: reserved, managed: [], relay: relay)
        precondition(reservedCopilot.keys.sorted() == ["agent_chrome", "browser_mcp"]
                     && reservedClaude.keys.sorted() == ["agent_chrome", "browser_mcp"]
                     && reservedAgy.managed == ["agent_chrome", "browser_mcp"], "A reserved server name is renamed for every backend")
        let reservedCodex = MCPBackendConfig.codexArgs(reserved, relay: relay)
        precondition(reservedCodex.contains("mcp_servers.browser_mcp.command=\"/usr/bin/true\"")
                     && !reservedCodex.contains { $0.hasPrefix("mcp_servers.browser.") }, "Codex never gets a reserved server name")
        precondition(MCPBackendConfig.exportName("Browser") == "Browser_mcp" && MCPBackendConfig.exportName("mobbin") == "mobbin",
                     "Only reserved names change")
        precondition(MCPBackendConfig.disabledForRun(["browser", "notes"], tab: nil) == ["browser_mcp", "notes"],
                     "Switching off a renamed server still reaches Copilot")
        let reimported = MCPBackendConfig.droppingExportAliases(reserved.servers + [MCPServer(name: "browser_mcp", command: "/usr/bin/true")])
        precondition(reimported.map(\.name) == ["browser", "agent_chrome"], "Re-importing Cantrip's renamed entry doesn't add a second server")
    }

    /// A fake MCP server and sign-in server, counting token requests.
    final class FakeAuthServer: @unchecked Sendable {
        let lock = NSLock()
        var refreshes = 0
        var accessToken = "access-1"
        var refreshToken = "refresh-1"
        var registeredRedirect: String?
        var mcpRequests: [String] = []

        func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!
            func reply(_ status: Int, _ body: Any? = nil, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
                var fields = headers
                if fields["Content-Type"] == nil { fields["Content-Type"] = "application/json" }
                let data = body.map { ($0 as? Data) ?? ((try? JSONSerialization.data(withJSONObject: $0)) ?? Data()) } ?? Data()
                return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
            }
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            switch (request.httpMethod ?? "GET", url.path) {
            case ("POST", "/mcp"):
                let authorization = request.value(forHTTPHeaderField: "Authorization")
                guard authorization == "Bearer \(lock.withLock { accessToken })" else {
                    return reply(401, headers: ["WWW-Authenticate": "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource/mcp\""])
                }
                let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let method = object["method"] as? String ?? ""
                lock.withLock { mcpRequests.append(method) }
                guard let id = object["id"] else { return reply(202) }
                if method == "initialize" {
                    return reply(200, ["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                              "serverInfo": ["name": "fake"]]],
                                 headers: ["Mcp-Session-Id": "session-1"])
                }
                precondition(request.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1", "The session ID is sent back")
                let event = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                                                                       "result": ["tools": [["name": "search"]]]])
                return reply(200, Data(("event: message\ndata: " + String(decoding: event, as: UTF8.self) + "\n\n").utf8),
                             headers: ["Content-Type": "text/event-stream"])
            case ("GET", "/.well-known/oauth-protected-resource/mcp"):
                return reply(200, ["resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com/auth/v1"],
                                   "scopes_supported": ["openid"]])
            case ("GET", "/.well-known/oauth-authorization-server/auth/v1"):
                return reply(200, ["issuer": "https://auth.example.com/auth/v1",
                                   "authorization_endpoint": "https://auth.example.com/auth/v1/oauth/authorize",
                                   "token_endpoint": "https://auth.example.com/auth/v1/oauth/token",
                                   "registration_endpoint": "https://auth.example.com/auth/v1/oauth/clients/register",
                                   "code_challenge_methods_supported": ["S256"]])
            case ("POST", "/auth/v1/oauth/clients/register"):
                let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                lock.withLock { registeredRedirect = (object?["redirect_uris"] as? [String])?.first }
                return reply(201, ["client_id": "client-1"])
            case ("POST", "/auth/v1/oauth/token"):
                if form.contains("grant_type=authorization_code") {
                    precondition(form.contains("code=the-code") && form.contains("code_verifier=") && form.contains("client_id=client-1"))
                    return reply(200, ["access_token": lock.withLock { accessToken }, "refresh_token": lock.withLock { refreshToken },
                                       "expires_in": 3600])
                }
                let (current, presented) = lock.withLock { (refreshToken, form) }
                guard presented.contains("refresh_token=\(current)") else { return reply(400, ["error": "invalid_grant"]) }
                try await Task.sleep(for: .milliseconds(150))
                let next = lock.withLock { () -> (String, String) in
                    refreshes += 1
                    accessToken = "access-\(refreshes + 1)"
                    refreshToken = "refresh-\(refreshes + 1)"
                    return (accessToken, refreshToken)
                }
                return reply(200, ["access_token": next.0, "refresh_token": next.1, "expires_in": 3600])
            default:
                return reply(404, ["error": "not found"])
            }
        }
    }

    static func testMCPOAuth() async throws {
        let fake = FakeAuthServer()
        let transport: MCPOAuth.Transport = { try await fake.respond($0) }
        let endpoints = try await MCPOAuth.discover(server: URL(string: "https://mcp.example.com/mcp")!, transport: transport)
        precondition(endpoints.tokenEndpoint == "https://auth.example.com/auth/v1/oauth/token" && endpoints.scopes == ["openid"]
                     && endpoints.resource == "https://mcp.example.com/mcp", "Discovery follows the 401 challenge to both metadata documents")
        let client = try await MCPOAuth.register(endpoints, redirectURI: "http://127.0.0.1:5555/oauth/callback", transport: transport)
        precondition(client.id == "client-1" && fake.registeredRedirect == "http://127.0.0.1:5555/oauth/callback")
        let verifier = MCPOAuth.randomURLSafe(48)
        let url = MCPOAuth.authorizeURL(endpoints, clientID: client.id, redirectURI: "http://127.0.0.1:5555/oauth/callback",
                                        state: "s1", verifier: verifier)!
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(items["code_challenge"] == MCPOAuth.challenge(for: verifier) && items["code_challenge_method"] == "S256"
                     && items["resource"] == "https://mcp.example.com/mcp" && items["state"] == "s1", "PKCE S256 and the resource")
        precondition(MCPOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                     "S256 matches RFC 7636's example")

        var clock = Date()
        let secrets = MCPSecrets.Store.memory()
        let signIns = MCPSignIns(secrets: secrets, transport: transport, now: { clock })
        let signedIn = try await signIns.complete(server: "mobbin", endpoints: endpoints, clientID: client.id, clientSecret: nil,
                                                  redirectURI: "http://127.0.0.1:5555/oauth/callback", code: "the-code", verifier: verifier)
        precondition(signedIn.accessToken == "access-1" && signedIn.refreshToken == "refresh-1")
        let stored = try secrets.string(MCPSecrets.oauthAccount("mobbin")) ?? ""
        precondition(stored.contains("refresh-1"), "The sign-in is saved in the (keychain) store")
        let fresh = try await signIns.accessToken(for: "mobbin")
        precondition(fresh == "access-1" && fake.refreshes == 0, "A fresh token is used as is")

        clock = clock.addingTimeInterval(3_590)
        async let a = signIns.accessToken(for: "mobbin")
        async let b = signIns.accessToken(for: "mobbin")
        async let c = signIns.accessToken(for: "mobbin")
        let tokens = try await [a, b, c]
        precondition(Set(tokens) == ["access-2"] && fake.refreshes == 1, "Concurrent callers share one refresh: \(tokens), \(fake.refreshes)")
        let rotated = try await signIns.credential("mobbin")?.refreshToken
        precondition(rotated == "refresh-2", "A rotated refresh token is saved")

        fake.lock.withLock { fake.refreshToken = "revoked" }
        do {
            _ = try await signIns.accessToken(for: "mobbin", force: true)
            preconditionFailure("A revoked sign-in must fail")
        } catch let failure as MCPOAuth.Failure {
            precondition(failure.kind == .needsSignIn, "invalid_grant asks to sign in again")
        }
        fake.lock.withLock { fake.refreshToken = "refresh-2" }

        // The loopback redirect.
        let callback = try MCPOAuth.Callback()
        let browser = URLSession(configuration: .ephemeral)
        defer { browser.invalidateAndCancel(); callback.cancel() }
        let (page, _) = try await browser.data(from: URL(string: callback.redirectURI + "?code=c1&state=s1")!)
        precondition(String(decoding: page, as: UTF8.self).contains("Signed in"))
        let fields = try await callback.wait(timeout: 5)
        precondition(fields["code"] == "c1" && fields["state"] == "s1" && callback.result?["code"] == "c1", "The redirect's code arrives")

        // Relay test reuses this sign-in.
        mcpRelayFixture = (signIns, transport, secrets, fake)
    }

    nonisolated(unsafe) static var mcpRelayFixture: (MCPSignIns, MCPOAuth.Transport, MCPSecrets.Store, FakeAuthServer)?

    static func testMCPRelay() async throws {
        guard let (signIns, transport, secrets, fake) = mcpRelayFixture else { preconditionFailure("OAuth test runs first") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let echo = folder.appendingPathComponent("echo.py")
        try """
        import json, os, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "echo"}}
            elif m["method"] == "tools/list": r = {"tools": [{"name": "a"}, {"name": "b"}]}
            else: r = {"content": [{"type": "text", "text": m["params"]["name"] + ":" + os.environ.get("ECHO_TOKEN", "")}]}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """.write(to: echo, atomically: true, encoding: .utf8)
        try secrets.set("from-keychain", for: MCPSecrets.envAccount("echo", "ECHO_TOKEN"))
        let servers = [
            MCPServer(name: "echo", command: "/usr/bin/python3", args: [echo.path], secretEnv: ["ECHO_TOKEN"], tools: ["a"]),
            MCPServer(name: "mobbin", url: "https://mcp.example.com/mcp", oauth: true),
        ]
        var problems: [String] = []
        let environment = MCPRelay.Environment(
            server: { name in servers.first { $0.name == name } },
            refusal: { hello, _ in hello.tab == "blocked-tab" ? "Switched off for this tab." : nil },
            secrets: secrets, signIns: signIns, transport: transport,
            onSignInProblem: { name, _ in problems.append(name) })
        let socketPath = "/tmp/cantrip-relay-test-\(getpid()).sock"
        let relay = MCPRelay(environment: environment, path: socketPath)
        relay.start()
        defer { relay.stop(); try? FileManager.default.removeItem(atPath: socketPath) }
        try await Task.sleep(for: .milliseconds(300))

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/cantrip-mcp").path
        func session(_ name: String, tab: String? = nil, _ requests: [[String: Any]]) throws -> [[String: Any]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, name, "--backend", "Claude Code"] + (tab.map { ["--tab", $0] } ?? [])
            var env = ProcessInfo.processInfo.environment
            env["CANTRIP_MCP_SOCKET"] = socketPath
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            for request in requests {
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data([0x0A]))
            }
            var replies: [[String: Any]] = []
            var buffer = Data()
            let expected = requests.filter { $0["id"] != nil }.count
            let deadline = Date().addingTimeInterval(10)
            while replies.count < expected, Date() < deadline {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] { replies.append(object) }
                }
            }
            try input.fileHandleForWriting.close()
            process.terminate()
            return replies.sorted { "\($0["id"] ?? "")" < "\($1["id"] ?? "")" }
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        }

        let local = try session("echo", [request(1, "initialize"), request(2, "tools/list"),
                                         request(3, "tools/call", ["name": "a"]), request(4, "tools/call", ["name": "b"])])
        precondition(local.count == 4, "Every request is answered: \(local)")
        let listed = ((local[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        precondition(listed == ["a"], "tools/list keeps only allowed tools: \(String(describing: listed))")
        let called = (((local[2]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        precondition(called == "a:from-keychain", "The relay runs local servers with their keychain secrets: \(String(describing: called))")
        precondition((local[3]["error"] as? [String: Any])?["message"] as? String == "Cantrip doesn't allow the tool b on this server.",
                     "A tool outside the limit is refused")

        let remote = try session("mobbin", [request(1, "initialize"),
                                            ["jsonrpc": "2.0", "method": "notifications/initialized"], request(2, "tools/list")])
        precondition((remote.first?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "Remote initialize: \(remote)")
        let remoteTools = ((remote.last?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String
        precondition(remoteTools == "search", "Server-sent events are unpacked")
        precondition(fake.mcpRequests.contains("notifications/initialized"), "Notifications reach the server")

        // The server rejects the token: one refresh, then the call goes through.
        fake.lock.withLock { fake.accessToken = "rotated-elsewhere" }
        let before = fake.refreshes
        let retried = try session("mobbin", [request(1, "initialize")])
        precondition(retried.first?["result"] != nil && fake.refreshes == before + 1, "A 401 refreshes once and retries")

        let refused = try session("echo", tab: "blocked-tab", [request(1, "initialize")])
        precondition((refused.first?["error"] as? [String: Any])?["message"] as? String == "Switched off for this tab.",
                     "Tab switches are enforced by the relay")
        let unknown = try session("nope", [request(1, "initialize")])
        precondition(((unknown.first?["error"] as? [String: Any])?["message"] as? String)?.contains("no MCP server called nope") == true)

        relay.stop()
        let offline = try session("echo", [request(1, "initialize")])
        precondition(((offline.first?["error"] as? [String: Any])?["message"] as? String)?.contains("Cantrip isn't running") == true,
                     "Without the host, the relay answers with a visible error")
        _ = problems
    }

    /// These tests write and delete the backends' configs at their real paths, so a run outside the
    /// suite's temporary home (a hand-built focused binary, say) must stop before touching anything.
    static func requireTemporaryHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let real = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)).standardizedFileURL.path }
        guard let testHome = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"],
              URL(fileURLWithPath: testHome).standardizedFileURL.path == home, home != real else {
            fatalError("MCP tests rewrite and delete config files in the home folder; run them in the suite's temporary home")
        }
    }

    /// Runs in the suite's temporary home: real config paths, a fake `claude` and an in-memory keychain.
    static func testMCPMigration() throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        try fm.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".gemini/config"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: mcpCopilotFixture).write(to: MCPMigration.copilotConfig)
        try JSONSerialization.data(withJSONObject: ["numStartups": 3, "mcpServers": (mcpClaudeFixture["mcpServers"] as! [String: Any])])
            .write(to: MCPMigration.claudeConfig)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["agy-own": ["command": "own"]]]).write(to: MCPBackendConfig.antigravityFile)
        let log = home.appendingPathComponent("claude-calls.txt")
        let fakeClaude = home.appendingPathComponent("fake-claude.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
        defer {
            // Later tests share this home.
            for url in [MCPMigration.copilotConfig, MCPMigration.claudeConfig, MCPBackendConfig.antigravityFile,
                        MCPRegistry.file, MCPMigration.managedFile, log, fakeClaude, CantripPaths.cache("mcp")] {
                try? fm.removeItem(at: url)
            }
            for name in (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".copilot").path)) ?? []
            where name.contains("pre-cantrip") {
                try? fm.removeItem(at: home.appendingPathComponent(".copilot/\(name)"))
            }
        }
        let secrets = MCPSecrets.Store.memory()
        let originalCopilot = try Data(contentsOf: MCPMigration.copilotConfig)

        let preview = try MCPMigration.run(dryRun: true, secrets: secrets, claudePath: fakeClaude.path)
        let afterPreview = try Data(contentsOf: MCPMigration.copilotConfig)
        precondition(preview.dryRun && MCPRegistry.load() == nil && afterPreview == originalCopilot, "A preview changes nothing")
        let report = try MCPMigration.run(dryRun: false, secrets: secrets, claudePath: fakeClaude.path)
        precondition(report.servers == ["errors", "flows", "mobbin", "notes", "vault"] && report.secretsMoved == 2)
        precondition(MCPRegistry.load()?.importedAt != nil, "The list is saved")
        let moved = try secrets.string(MCPSecrets.headerAccount("flows", "Authorization"))
        precondition(moved == "Bearer secret-flows")

        let copilot = String(decoding: try Data(contentsOf: MCPMigration.copilotConfig), as: UTF8.self)
        precondition(!copilot.contains("secret-") && copilot.contains("cantrip-mcp") && copilot.contains("\"flows\""),
                     "Copilot gets every server, relayed ones as the relay, with no credentials")
        let backups = try fm.contentsOfDirectory(atPath: home.appendingPathComponent(".copilot").path).filter { $0.contains("pre-cantrip") }
        precondition(backups.count == 1, "Copilot's original is backed up")
        let claudeBackup = try fm.contentsOfDirectory(atPath: CantripPaths.cache("mcp").path).filter { $0.hasPrefix("claude-mcpServers.pre-cantrip") }
        let redacted = try String(contentsOf: CantripPaths.cache("mcp/\(claudeBackup.first ?? "")"), encoding: .utf8)
        precondition(!redacted.contains("secret-") && redacted.contains("cantrip mcp restore"), "File backups are redacted")
        let antigravity = String(decoding: try Data(contentsOf: MCPBackendConfig.antigravityFile), as: UTF8.self)
        precondition(antigravity.contains("agy-own") && antigravity.contains("mobbin") && !antigravity.contains("secret-"),
                     "Antigravity keeps its own servers and gets Cantrip's")
        let calls = try String(contentsOf: log, encoding: .utf8)
        precondition(calls.contains("mcp add-json -s user flows") && calls.contains("cantrip-mcp") && !calls.contains("secret-"),
                     "Claude Code's own servers become relay entries through its CLI")

        // A second run (configs now hold relay entries) keeps the list as it is.
        let again = try MCPMigration.run(dryRun: false, secrets: secrets, claudePath: fakeClaude.path)
        precondition(again.servers == report.servers && MCPRegistry.load()?.servers.first { $0.name == "vault" }?.tools == ["status", "get"],
                     "Re-running doesn't lose a server's settings")

        let restored = try MCPMigration.restore(secrets: secrets, claudePath: fakeClaude.path)
        let restoredCopilot = try Data(contentsOf: MCPMigration.copilotConfig)
        precondition(restored.count == 2 && restoredCopilot == originalCopilot, "Restore puts Copilot's original back")
        let finalCalls = try String(contentsOf: log, encoding: .utf8)
        precondition(finalCalls.contains("secret-flows"), "and Claude Code's, credentials included")
        precondition(MCPRegistry.load()?.importedAt == nil, "Restoring stops sharing")
    }
}
