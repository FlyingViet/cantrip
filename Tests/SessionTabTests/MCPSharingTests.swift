import Foundation
import JavaScriptCore

extension SessionTabTests {
    @MainActor
    static func testMCPSharing() async throws {
        requireTemporaryHome()
        try testMCPImport()
        testMCPBackendConfigs()
        try await testMCPOAuth()
        try await testMCPRelay()
        try testMCPMigration()
        try testMCPMigrationClaudeCLI()
        try testMCPConsentStep()
        try await testMCPRemoteList()
        try await testMCPClientReuse()
        try await testMCPSignInSettingChange()
        try await testMCPAccessProbe()
        print("MCP sharing: import, backend configs, OAuth with single-flight refresh, the relay and the remote list passed")
    }

    /// Whether a remote server needs a sign-in, asked without one: one that answers and names no
    /// sign-in server needs none (kiwi); one that answers anonymously but names a sign-in server
    /// (seats.aero) or answers 401 (supabase) signs in with OAuth; anything else is unknown.
    @MainActor
    static func testMCPAccessProbe() async throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var list: [String] = []
            var credentials = 0
        }
        let calls = Calls()
        // Sendable, so not tied to the main actor, which the batch below blocks while it waits.
        let transport: MCPOAuth.Transport = { @Sendable request in
            let url = request.url!, method = request.httpMethod ?? "GET"
            calls.lock.withLock {
                calls.list.append("\(method) \(url.host ?? "")\(url.path)")
                if request.value(forHTTPHeaderField: "Authorization") != nil { calls.credentials += 1 }
            }
            func reply(_ status: Int, _ body: String = "", _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }
            switch (method, url.host ?? "", url.path) {
            case ("POST", "open.example.com", ""):
                return reply(200, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}\n\n",
                             ["Content-Type": "text/event-stream", "Mcp-Session-Id": "probe-1"])
            case ("POST", "anonymous.example.com", "/mcp"):
                return reply(200, #"{"jsonrpc":"2.0","id":0,"result":{}}"#, ["Content-Type": "application/json"])
            case ("GET", "anonymous.example.com", "/.well-known/oauth-protected-resource/mcp"):
                return reply(200, #"{"resource":"https://anonymous.example.com/mcp","authorization_servers":["https://anonymous.example.com"]}"#)
            case ("POST", "private.example.com", "/mcp"):
                return reply(401, #"{"message":"No access token provided"}"#,
                             ["WWW-Authenticate": #"Bearer resource_metadata="https://private.example.com/.well-known/oauth-protected-resource/mcp""#])
            case ("POST", "refusing.example.com", "/mcp"):
                return reply(403)
            case (_, "offline.example.com", _):
                throw URLError(.cannotFindHost)
            default:
                return reply(404)
            }
        }
        func access(_ address: String) async -> MCPOAuth.Access {
            await MCPOAuth.detectAccess(server: URL(string: address)!, headers: ["X-Client": "cantrip"], transport: transport)
        }
        let open = await access("https://open.example.com")
        precondition(open == .open, "Answers and names no sign-in server: \(open)")
        precondition(calls.list.contains("DELETE open.example.com"), "The session the probe opened is closed: \(calls.list)")
        let anonymous = await access("https://anonymous.example.com/mcp")
        precondition(anonymous == .oauth, "Answers anonymously but names a sign-in server: \(anonymous)")
        let privateServer = await access("https://private.example.com/mcp")
        precondition(privateServer == .oauth)
        let refusing = await access("https://refusing.example.com/mcp")
        precondition(refusing == .unknown("it answered HTTP 403"), "\(refusing)")
        guard case .unknown(let why) = await access("https://offline.example.com/mcp"), why.hasPrefix("couldn't reach offline.example.com") else {
            preconditionFailure("An unreachable server is unknown, with why")
        }
        precondition(calls.credentials == 0, "The probe never sends a credential")

        let batch = MCPOAuth.detectAccessWaiting([
            MCPServer(name: "flights", url: "https://open.example.com"),
            MCPServer(name: "awards", url: "https://anonymous.example.com/mcp"),
        ], transport: transport)
        precondition(batch == ["flights": .open, "awards": .oauth], "Several at once, for `cantrip mcp migrate`: \(batch)")
    }

    /// A server whose sign-in setting changes drops the state shown for the old one at once: one
    /// switched to no sign-in kept "Not signed in" (and Connect) until Cantrip restarted.
    @MainActor
    static func testMCPSignInSettingChange() async throws {
        requireTemporaryHome()
        defer { removeMCPMigrationFixture() }
        let snapshot = MCPRegistry.Snapshot(servers: [
            MCPServer(name: "flights", url: "https://flights.example.com/mcp", oauth: true),
            MCPServer(name: "flows", url: "https://flows.example.com/mcp", secretHeaders: ["X-Api-Key"]),
        ])
        try MCPRegistry.save(snapshot)
        let hub = MCPServerHub(signIns: MCPSignIns(secrets: .memory()), snapshot: snapshot)
        await hub.refreshStates()
        precondition(hub.states["flights"]?.phase == .needsSignIn && hub.states["flows"]?.phase == .ready)

        // Switched off in the list on disk, which `cantrip mcp migrate --apply` reloads.
        var edited = snapshot
        edited.servers[0].oauth = false
        try MCPRegistry.save(edited)
        hub.reload()
        precondition(hub.states["flights"]?.phase == .ready, "Ready without a restart: \(String(describing: hub.states["flights"]))")
        let listed = HostControl.describe(hub)
        precondition(listed.contains("flights: remote, via relay, ready") && !listed.contains("Not signed in"), listed)
        let payload = hub.remotePayload()["servers"] as? [[String: Any]] ?? []
        let shown = payload.first { $0["name"] as? String == "flights" }
        precondition(shown?["oauth"] as? Bool == false && (shown?["state"] as? [String: Any])?["phase"] as? String == "ready",
                     "Remote clients get it too: \(String(describing: shown))")
        await hub.refreshStates()
        precondition(hub.states["flights"]?.phase == .ready, "and it stays ready")

        // A server without sign-in never shows one as missing; a keychain problem still shows.
        hub.reportProblem("flights", "flights isn't signed in. Connect it in Cantrip's MCP Servers settings.")
        precondition(hub.states["flights"]?.phase == .ready, "No sign-in problem for a server without sign-in")
        hub.reportProblem("flows", MCPSecrets.Failure.locked.localizedDescription)
        await hub.refreshStates()
        precondition(hub.states["flows"]?.phase == .locked, "A keychain problem the relay reported stays")

        // Back to OAuth through the hub: the sign-in is read from the keychain again.
        try hub.update { $0.servers[0].oauth = true }
        precondition(hub.states["flights"] == nil, "The old Ready is dropped at once")
        await hub.refreshStates()
        precondition(hub.states["flights"]?.phase == .needsSignIn && MCPRegistry.load()?.servers[0].oauth == true)

        // Connect asks first: a server that answers without signing in needs no sign-in, and shows Ready.
        hub.accessProbe = { _, _ in .open }
        hub.connect("flights")
        for _ in 0..<200 where hub.states["flights"]?.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        precondition(hub.states["flights"]?.phase == .ready && hub.server("flights")?.oauth == false
                     && MCPRegistry.load()?.servers[0].oauth == false,
                     "Connect switches it to no sign-in: \(String(describing: hub.states["flights"]))")
        precondition(HostControl.describe(hub).contains("flights: remote, via relay, ready"))
    }

    /// The authorize address carries everything the sign-in server needs, and reaches agent Chrome
    /// whole: Chrome 156 ends a raw `/json/new?` address at its first `&`, which dropped `client_id`.
    static func testMCPSignInAddress(_ discovered: MCPOAuth.Endpoints, verifier: String) {
        var endpoints = discovered
        endpoints.authorizationEndpoint += "?prompt=consent"
        endpoints.scopes = ["org:read", "project:write"]
        let redirect = "http://127.0.0.1:5555/oauth/callback"
        let url = MCPOAuth.authorizeURL(endpoints, clientID: "client-1", redirectURI: redirect, state: "s1", verifier: verifier)!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        precondition(fields == ["prompt": "consent", "response_type": "code", "client_id": "client-1", "redirect_uri": redirect,
                                "state": "s1", "code_challenge": MCPOAuth.challenge(for: verifier), "code_challenge_method": "S256",
                                "resource": "https://mcp.example.com/mcp", "scope": "org:read project:write"],
                     "client_id, PKCE, redirect_uri, resource and scope, keeping the endpoint's own parameters: \(fields)")
        precondition(items.count == fields.count, "No parameter twice")

        let path = AgentChrome.newTabPath(for: url)
        precondition(path.hasPrefix("/json/new?"))
        let target = String(path.dropFirst("/json/new?".count))
        precondition(!target.contains("&") && !target.contains("?") && !target.contains("#") && !target.contains(" "),
                     "Nothing in the address can end it early: \(target)")
        precondition(target.removingPercentEncoding == url.absoluteString, "Chrome's one unescape gives back the whole address")
    }

    /// A sign-in server's refusal reads as words with Retry, never as its raw JSON; an unreachable
    /// server says so instead of claiming it has no sign-in settings.
    static func testMCPSignInErrors(_ endpoints: MCPOAuth.Endpoints) async throws {
        let supabase = "Pretty-print \n{\"code\":400,\"error_code\":\"validation_failed\",\"msg\":\"client_id is required\"}"
        precondition(MCPOAuth.providerError(pageURL: "https://auth.example.com/auth/v1/oauth/authorize?response_type=code",
                                            title: "", text: supabase) == "client_id is required (validation_failed)")
        precondition(MCPOAuth.providerError(pageURL: "https://auth.example.com/oauth/error?error=invalid_request&error_description=Unknown%20client",
                                            title: "Error", text: "Something went wrong") == "Unknown client (invalid_request)")
        precondition(MCPOAuth.providerError(pageURL: "chrome-error://chromewebdata/", title: "auth.example.com", text: "")?
            .contains("couldn't load") == true)
        precondition(MCPOAuth.providerError(pageURL: "https://example.com/login?redirect_to=/oauth/consent", title: "Login",
                                            text: "Welcome back Continue with Google or Continue {terms}") == nil,
                     "An ordinary sign-in page isn't an error")

        let refusing: MCPOAuth.Transport = { request in
            let body = #"{"error":"invalid_request","error_description":"redirect_uri doesn't match"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let pending = MCPOAuth.Credential(endpoints: endpoints, clientID: "client-1", clientSecret: nil,
                                          redirectURI: "http://127.0.0.1:5555/oauth/callback", accessToken: "",
                                          refreshToken: nil, expiresAt: nil, signedInAt: Date())
        do {
            _ = try await MCPOAuth.requestTokens([("grant_type", "authorization_code"), ("code", "c")], credential: pending,
                                                 now: Date(), transport: refusing)
            preconditionFailure("A 400 from the token endpoint fails")
        } catch let failure as MCPOAuth.Failure {
            precondition(failure.message == "The sign-in server refused the token request: redirect_uri doesn't match (invalid_request).",
                         failure.message)
        }
        do {
            _ = try await MCPOAuth.register(endpoints, redirectURI: "http://127.0.0.1:5555/oauth/callback", transport: refusing)
            preconditionFailure("A 400 from registration fails")
        } catch let failure as MCPOAuth.Failure {
            precondition(failure.kind == .registration && failure.message.contains("redirect_uri doesn't match"), failure.message)
        }
        let offline: MCPOAuth.Transport = { _ in throw URLError(.timedOut) }
        do {
            _ = try await MCPOAuth.discover(server: URL(string: "https://mcp.example.com/mcp")!, transport: offline)
            preconditionFailure("An unreachable server fails")
        } catch let failure as MCPOAuth.Failure {
            precondition(failure.message.hasPrefix("Couldn't reach mcp.example.com"), failure.message)
        }
    }

    /// The client Cantrip registers is saved in the keychain store at once and reused by the next
    /// sign-in (a retry included), until the sign-in server or redirect changes or it's refused.
    static func testMCPClientReuse() async throws {
        final class Registrations: @unchecked Sendable { var count = 0 }
        let registrations = Registrations()
        let transport: MCPOAuth.Transport = { request in
            registrations.count += 1
            let body = #"{"client_id":"client-\#(registrations.count)","client_secret":"secret-\#(registrations.count)"}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let secrets = MCPSecrets.Store.memory()
        let signIns = MCPSignIns(secrets: secrets, transport: transport)
        let endpoints = MCPOAuth.Endpoints(resource: "https://mcp.example.com/mcp", issuer: "https://auth.example.com",
                                           authorizationEndpoint: "https://auth.example.com/authorize",
                                           tokenEndpoint: "https://auth.example.com/token",
                                           registrationEndpoint: "https://auth.example.com/register")
        let redirect = "http://127.0.0.1:5555/oauth/callback"
        let first = try await signIns.client(for: "design", endpoints: endpoints, redirectURI: redirect)
        precondition(first.clientID == "client-1" && registrations.count == 1)
        let saved = try secrets.string(MCPSecrets.clientAccount("design"))
        precondition(saved?.contains("secret-1") == true, "Saved in the keychain store as soon as it's registered")
        let retry = try await signIns.client(for: "design", endpoints: endpoints, redirectURI: redirect)
        precondition(retry == first && registrations.count == 1, "A retry reuses it instead of registering again")
        let port = try await signIns.registeredClient("design")?.port
        precondition(port == 5555, "The next sign-in listens on its redirect port")

        let moved = try await signIns.client(for: "design", endpoints: endpoints, redirectURI: "http://127.0.0.1:6666/oauth/callback")
        precondition(moved.clientID == "client-2", "Another redirect (the port was taken) needs a new registration")
        var other = endpoints
        other.issuer = "https://login.example.com"
        let otherServer = try await signIns.client(for: "design", endpoints: other, redirectURI: moved.redirectURI)
        precondition(otherServer.clientID == "client-3", "Another sign-in server needs its own")
        try await signIns.forgetClient("design")
        let fresh = try await signIns.client(for: "design", endpoints: other, redirectURI: moved.redirectURI)
        precondition(fresh.clientID == "client-4", "A refused client is forgotten, and the next try registers again")

        // A sign-in saved before registrations were kept still lends its client.
        let signedIn = MCPOAuth.Credential(endpoints: endpoints, clientID: "legacy", clientSecret: nil, redirectURI: redirect,
                                           accessToken: "a", refreshToken: nil, expiresAt: nil, signedInAt: Date())
        try await signIns.store(signedIn, for: "errors")
        let legacy = try await signIns.client(for: "errors", endpoints: endpoints, redirectURI: redirect)
        precondition(legacy.clientID == "legacy" && registrations.count == 4)
        try await signIns.signOut("design")
        let kept = try await signIns.registeredClient("design")
        precondition(kept != nil, "Signing out keeps the registration")
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
        testMCPSignInAddress(endpoints, verifier: verifier)
        try await testMCPSignInErrors(endpoints)

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

    /// The backends' configs at their real paths in the suite's temporary home.
    static func writeMCPMigrationFixture() throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        try fm.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".gemini/config"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: mcpCopilotFixture).write(to: MCPMigration.copilotConfig)
        try JSONSerialization.data(withJSONObject: ["numStartups": 3, "mcpServers": (mcpClaudeFixture["mcpServers"] as! [String: Any])])
            .write(to: MCPMigration.claudeConfig)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["agy-own": ["command": "own"]]]).write(to: MCPBackendConfig.antigravityFile)
    }

    /// Later tests share this home.
    static func removeMCPMigrationFixture(_ extra: [URL] = []) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for url in [MCPMigration.copilotConfig, MCPMigration.claudeConfig, MCPBackendConfig.antigravityFile,
                    MCPRegistry.file, MCPMigration.managedFile, CantripPaths.cache("mcp")] + extra {
            try? fm.removeItem(at: url)
        }
        for name in (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".copilot").path)) ?? []
        where name.contains("pre-cantrip") {
            try? fm.removeItem(at: home.appendingPathComponent(".copilot/\(name)"))
        }
    }

    /// Runs in the suite's temporary home: real config paths, a fake `claude` and an in-memory keychain.
    static func testMCPMigration() throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        try writeMCPMigrationFixture()
        let log = home.appendingPathComponent("claude-calls.txt")
        let fakeClaude = home.appendingPathComponent("fake-claude.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
        defer { removeMCPMigrationFixture([log, fakeClaude]) }
        let secrets = MCPSecrets.Store.memory()
        let originalCopilot = try Data(contentsOf: MCPMigration.copilotConfig)

        // Remote servers without a credential are asked whether they need a sign-in (never the network here).
        var asked: [String] = []
        let access: ([MCPServer]) -> [String: MCPOAuth.Access] = { servers in
            asked += servers.map(\.name)
            return Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0.name == "errors" ? .open : .oauth) })
        }
        let preview = try MCPMigration.run(dryRun: true, secrets: secrets, claudePath: fakeClaude.path, access: access)
        let afterPreview = try Data(contentsOf: MCPMigration.copilotConfig)
        precondition(preview.dryRun && MCPRegistry.load() == nil && afterPreview == originalCopilot, "A preview changes nothing")
        precondition(preview.notes.contains("errors answers without signing in, so it needs no sign-in."), "\(preview.notes)")
        let report = try MCPMigration.run(dryRun: false, secrets: secrets, claudePath: fakeClaude.path, access: access)
        precondition(report.servers == ["errors", "flows", "mobbin", "notes", "vault"] && report.secretsMoved == 2)
        precondition(MCPRegistry.load()?.importedAt != nil, "The list is saved")
        precondition(asked.sorted() == ["errors", "errors", "mobbin", "mobbin"], "Only remote servers without a credential are asked: \(asked)")
        let signIns = Dictionary(uniqueKeysWithValues: (MCPRegistry.load()?.servers ?? []).map { ($0.name, $0.oauth) })
        precondition(signIns["errors"] == false && signIns["mobbin"] == true && signIns["flows"] == false,
                     "One that answers without signing in needs none; one that asks for it signs in with OAuth: \(signIns)")
        precondition(report.notes.contains("mobbin signs in with OAuth: `cantrip mcp connect mobbin` (or Connect in Settings)."), "\(report.notes)")
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
        asked = []
        let again = try MCPMigration.run(dryRun: false, secrets: secrets, claudePath: fakeClaude.path, access: access)
        precondition(again.servers == report.servers && MCPRegistry.load()?.servers.first { $0.name == "vault" }?.tools == ["status", "get"],
                     "Re-running doesn't lose a server's settings")
        precondition(asked.isEmpty && MCPRegistry.load()?.servers.first { $0.name == "errors" }?.oauth == false,
                     "Servers already in the list aren't asked again and keep their sign-in setting")

        let restored = try MCPMigration.restore(secrets: secrets, claudePath: fakeClaude.path)
        let restoredCopilot = try Data(contentsOf: MCPMigration.copilotConfig)
        precondition(restored.count == 2 && restoredCopilot == originalCopilot, "Restore puts Copilot's original back")
        let finalCalls = try String(contentsOf: log, encoding: .utf8)
        precondition(finalCalls.contains("secret-flows"), "and Claude Code's, credentials included")
        precondition(MCPRegistry.load()?.importedAt == nil, "Restoring stops sharing")
    }

    /// With Claude Code's path left blank in Settings, `migrate --apply` runs the `claude` it finds
    /// (it used to start "", which fails with "Permission denied" after the other configs were
    /// written). A run that stops partway says what it wrote and still reloads the list.
    @MainActor
    static func testMCPMigrationClaudeCLI() throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bin = home.appendingPathComponent("claude-bin")
        let claude = bin.appendingPathComponent("claude")
        let log = home.appendingPathComponent("claude-cli-calls.txt")
        try writeMCPMigrationFixture()
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { removeMCPMigrationFixture([bin, log]) }
        // Only the fake `claude` can be found: never the real CLI, nor a login shell's PATH.
        let locator = ToolLocator(home: home.path, inheritedPATH: bin.path, loginShell: { _ in nil })
        let secrets = MCPSecrets.Store.memory()
        let hub = MCPServerHub(signIns: MCPSignIns(secrets: secrets), snapshot: MCPRegistry.Snapshot())
        func migrate() -> [String: Any] {
            HostControl.migrate(dryRun: false, hub: hub) {
                try MCPMigration.run(dryRun: $0, secrets: secrets, claudePath: "", locator: locator, access: { _ in [:] })
            }
        }
        let originalCopilot = try Data(contentsOf: MCPMigration.copilotConfig)
        let originalClaude = try Data(contentsOf: MCPMigration.claudeConfig)

        // No `claude` to run: stops before changing anything, and says so.
        let missing = migrate()
        let missingText = missing["error"] as? String ?? ""
        precondition(missingText.hasPrefix("Nothing changed:") && missingText.contains("Claude Code's CLI (claude)"), missingText)
        let copilotAfterMissing = try Data(contentsOf: MCPMigration.copilotConfig)
        precondition(MCPRegistry.load() == nil && copilotAfterMissing == originalCopilot, "Nothing is written when Claude Code's CLI can't run")
        let preview = try MCPMigration.run(dryRun: true, secrets: secrets, claudePath: "", locator: locator, access: { _ in [:] })
        precondition(preview.notes.contains { $0.contains("Claude Code's CLI (claude)") }, "The preview warns too")

        // `claude` is found but won't start: the other configs are already written by then.
        try "#!/nonexistent/interpreter\n".write(to: claude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let partial = migrate()
        let partialText = partial["error"] as? String ?? ""
        precondition(partialText.hasPrefix("Stopped partway: couldn't run Claude Code's CLI (\(claude.path))")
                     && partialText.contains("Already updated: Cantrip's MCP list; ~/.copilot/mcp-config.json; ~/.gemini/config/mcp_config.json.")
                     && partialText.contains("~/.claude.json still has its own errors, flows, notes")
                     && !partialText.contains("Nothing changed") && !partialText.contains("secret-"), partialText)
        precondition(hub.snapshot.servers.map(\.name) == ["errors", "flows", "mobbin", "notes", "vault"] && hub.snapshot.importedAt != nil,
                     "The list is reloaded after a partial run: \(hub.snapshot.servers.map(\.name))")
        let claudeAfterPartial = try Data(contentsOf: MCPMigration.claudeConfig)
        precondition(claudeAfterPartial == originalClaude, "Claude Code's config is untouched")

        // With a working `claude`, running it again finishes: Claude Code's servers become relay entries.
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: claude, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let done = migrate()
        let doneText = done["text"] as? String ?? ""
        precondition(done["error"] == nil && doneText.contains("~/.claude.json: errors; ~/.claude.json: flows; ~/.claude.json: notes"),
                     "\(done)")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let added = Dictionary(calls.compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count == 5, parts[0...2] == ["mcp", "add-json", "-s"], parts[3] == "user" else { return nil }
            let rest = parts[4].split(separator: " ", maxSplits: 1).map(String.init)
            return rest.count == 2 ? (rest[0], rest[1]) : nil
        }, uniquingKeysWith: { $1 })
        precondition(Set(added.keys) == ["errors", "flows", "notes"], "`claude mcp add-json` for each of Claude Code's servers: \(calls)")
        for name in ["errors", "flows"] {
            let entry = (try? JSONSerialization.jsonObject(with: Data(added[name]!.utf8))) as? [String: Any]
            precondition((entry?["command"] as? String)?.hasSuffix("cantrip-mcp") == true && entry?["type"] as? String == "stdio",
                         "\(name) goes through Cantrip's relay: \(added[name]!)")
        }
        precondition(!calls.joined().contains("secret-"), "No credential reaches Claude Code's config")
        precondition(MCPMigration.claudeExecutable("", locator: locator) == claude.path, "Blank means `claude`, found on the PATH")
    }

    /// A consent page that offers a sign-in next to free, guest or anonymous access never gets a
    /// free option approved: you're asked to log in in agent Chrome instead, and Cantrip presses
    /// only the exact button you approved.
    static func testMCPConsentStep() throws {
        func page(_ buttons: [String], login: Bool = false) -> AgentChrome.Page {
            AgentChrome.Page(title: "Authorize", host: "seats.aero", url: "https://seats.aero/mcp/oauth/authorize?client_id=c",
                             text: "", buttons: buttons, login: login, approve: nil)
        }
        let cases: [([String], Bool, AgentChrome.Step)] = [
            // seats.aero with agent Chrome logged out, then logged in.
            (["Sign in with seats.aero Pro", "Continue as a free user"], false, .logIn(declined: "Continue as a free user")),
            (["Allow access", "Cancel"], false, .approve("Allow access")),
            (["Continue as a free user"], false, .logIn(declined: "Continue as a free user")),
            (["Continue as guest", "Log in"], false, .logIn(declined: "Continue as guest")),
            (["Continue anonymously", "Login"], false, .logIn(declined: "Continue anonymously")),
            (["Continue with Google", "Continue without an account"], false, .logIn(declined: "Continue without an account")),
            (["Use the free plan", "Allow"], false, .approve("Allow")),
            (["Approve", "Deny"], false, .approve("Approve")),
            (["Continue with Google", "Continue"], true, .logIn(declined: nil)),
            ([], false, .wait),
        ]
        for (buttons, login, expected) in cases {
            let step = AgentChrome.step(for: page(buttons, login: login))
            precondition(step == expected, "\(buttons) login=\(login): \(step), expected \(expected)")
            if case .approve(let label) = step {
                precondition(label.range(of: AgentChrome.limitedPattern, options: [.regularExpression, .caseInsensitive]) == nil,
                             "Never approves a free or guest option: \(label)")
            }
        }

        // The page's own scripts, on a stand-in page.
        let context = JSContext()!
        context.exceptionHandler = { _, error in preconditionFailure("JavaScript error: \(error?.toString() ?? "")") }
        context.evaluateScript("""
        var clicked = [], location = { host: 'seats.aero', href: 'https://seats.aero/mcp/oauth/authorize?client_id=c' };
        function show(labels) {
          clicked = [];
          document = { title: 'Authorize', body: { innerText: 'Connect your account' }, querySelector: () => null,
            querySelectorAll: () => labels.map(l => ({ innerText: l, offsetParent: {}, click() { clicked.push(l) } })) };
        }
        var document;
        """)
        func show(_ labels: [String]) {
            let literal = String(decoding: try! JSONEncoder().encode(labels), as: UTF8.self)
            context.evaluateScript("show(\(literal))")
        }
        show(["Sign in with seats.aero Pro", "Continue as a free user"])
        let inspected = context.evaluateScript(AgentChrome.inspectScript)?.toString() ?? ""
        let decoded = try JSONDecoder().decode(AgentChrome.Page.self, from: Data(inspected.utf8))
        precondition(decoded.buttons == ["Sign in with seats.aero Pro", "Continue as a free user"] && decoded.approve == nil
                     && AgentChrome.step(for: decoded) == .logIn(declined: "Continue as a free user"), inspected)
        let refused = context.evaluateScript(AgentChrome.approveScript(label: "Allow access"))?.toString()
        precondition(refused == "none" && context.evaluateScript("clicked.length")?.toInt32() == 0,
                     "An approval for another page presses nothing here, the free option included")

        show(["Continue as a free user", "Allow \"access\" \\ now"])
        let pressed = context.evaluateScript(AgentChrome.approveScript(label: "Allow \"access\" \\ now"))?.toString()
        precondition(pressed == "clicked" && context.evaluateScript("clicked.join('|')")?.toString() == "Allow \"access\" \\ now",
                     "Only the approved button is pressed, its label taken literally")
    }
}
