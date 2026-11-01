import AppKit
import Foundation

/// The agent Chrome (DevTools on 127.0.0.1, `BrowserPreview.port`), used for MCP sign-ins: Cantrip
/// opens the consent page there, shows it in Cantrip, and clicks the page's own approve button
/// only after you approve in Cantrip. Page text is the site's content: shown, never obeyed.
struct AgentChrome {
    var port = BrowserPreview.port
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    struct Tab: Equatable {
        var id: String
        var socket: URL
    }

    struct Page: Codable, Equatable {
        var title: String
        var host: String
        var url: String
        var text: String
        var buttons: [String]
        /// The page asks for an email or password.
        var login: Bool
        /// The label of the button that grants access, if the page has one.
        var approve: String?
    }

    private func endpoint(_ path: String) -> URL? { URL(string: "http://127.0.0.1:\(port)\(path)") }

    func isRunning() async -> Bool {
        guard let url = endpoint("/json/version") else { return false }
        return (try? await session.data(from: url)) != nil
    }

    func open(_ address: URL) async throws -> Tab {
        guard let url = endpoint("/json/new?\(address.absoluteString)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let (data, _) = try await session.data(for: request)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? String, let socket = (object["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)),
              ["127.0.0.1", "localhost"].contains(socket.host ?? "") else {
            throw URLError(.cannotConnectToHost)
        }
        return Tab(id: id, socket: socket)
    }

    func close(_ tab: Tab) async {
        guard let url = endpoint("/json/close/\(tab.id)") else { return }
        _ = try? await session.data(from: url)
    }

    /// Runs one DevTools command on the tab.
    func call(_ tab: Tab, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let socket = session.webSocketTask(with: tab.socket)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let body = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: continue
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["id"] as? Int == 1 else { continue }
            if let error = object["error"] as? [String: Any] {
                throw MCPOAuth.Failure(kind: .denied, message: "Agent Chrome: \(error["message"] as? String ?? "error")")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw URLError(.timedOut)
    }

    static let approvePattern = "^(allow|approve|authorize|authorise|accept|confirm|grant|continue|yes)\\b"

    static let inspectScript = """
    (() => { const re = new RegExp(\(String(reflecting: approvePattern)), 'i');
      const labels = [...document.querySelectorAll('button,a[role=button],input[type=submit],input[type=button]')]
        .filter(e => e.offsetParent !== null).map(e => (e.innerText || e.value || '').trim()).filter(Boolean);
      return JSON.stringify({ title: document.title || '', host: location.host, url: location.href.slice(0, 400),
        text: ((document.body && document.body.innerText) || '').replace(/\\s+\\n/g, '\\n').slice(0, 1200),
        buttons: labels.slice(0, 12), login: !!document.querySelector('input[type=password],input[type=email]'),
        approve: labels.find(l => re.test(l)) || null }); })()
    """

    static let approveScript = """
    (() => { const re = new RegExp(\(String(reflecting: approvePattern)), 'i');
      const b = [...document.querySelectorAll('button,a[role=button],input[type=submit],input[type=button]')]
        .filter(e => e.offsetParent !== null).find(e => re.test((e.innerText || e.value || '').trim()));
      if (!b) return 'none'; b.click(); return 'clicked'; })()
    """

    func inspect(_ tab: Tab) async throws -> Page {
        let result = try await call(tab, "Runtime.evaluate", ["expression": Self.inspectScript, "returnByValue": true])
        guard let value = (result["result"] as? [String: Any])?["value"] as? String,
              let page = try? JSONDecoder().decode(Page.self, from: Data(value.utf8)) else {
            throw URLError(.cannotParseResponse)
        }
        return page
    }

    func screenshot(_ tab: Tab) async -> String? {
        let result = try? await call(tab, "Page.captureScreenshot", ["format": "jpeg", "quality": 55])
        return result?["data"] as? String
    }

    func clickApprove(_ tab: Tab) async throws -> Bool {
        let result = try await call(tab, "Runtime.evaluate", ["expression": Self.approveScript, "returnByValue": true])
        return (result["result"] as? [String: Any])?["value"] as? String == "clicked"
    }
}

/// MCP servers as the host runs them: the shared list, each server's sign-in state, and sign-ins
/// in progress (with the page waiting for your OK). Settings and every Remote client show this.
@MainActor
final class MCPServerHub: ObservableObject {
    static let shared = MCPServerHub()

    enum Phase: String, Codable {
        /// Local, or signed in.
        case ready
        case needsSignIn
        case connecting
        /// The consent page is open in agent Chrome, waiting for Approve in Cantrip.
        case awaitingApproval
        /// The site wants you to log in first; finish that in agent Chrome.
        case needsLogin
        case locked
        case failed
    }

    struct State: Codable, Equatable {
        var phase: Phase
        var message: String?
        var page: AgentChrome.Page?
        /// A JPEG of the page, base64.
        var screenshot: String?
        var expiresAt: Date?
        var updatedAt = Date()
    }

    @Published private(set) var snapshot: MCPRegistry.Snapshot
    @Published private(set) var states: [String: State] = [:]
    /// Bumps when anything a client shows changes.
    @Published private(set) var revision = UUID()
    /// A sign-in needs your OK (approve or log in), for push alerts.
    var onNeedsAttention: ((String, Phase) -> Void)?

    private var decisions: [String: CheckedContinuation<Bool, Never>] = [:]
    private var flows: [String: Task<Void, Never>] = [:]
    let signIns: MCPSignIns
    var chrome = AgentChrome()
    var openInDefaultBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(signIns: MCPSignIns = .shared, snapshot: MCPRegistry.Snapshot? = nil) {
        self.signIns = signIns
        self.snapshot = snapshot ?? MCPRegistry.load() ?? MCPRegistry.Snapshot()
    }

    func server(_ name: String) -> MCPServer? { snapshot.servers.first { $0.name == name } }

    func reload() {
        snapshot = MCPRegistry.load() ?? snapshot
        revision = UUID()
    }

    func update(_ change: (inout MCPRegistry.Snapshot) -> Void) throws {
        var copy = snapshot
        change(&copy)
        try MCPRegistry.save(copy)
        snapshot = copy
        revision = UUID()
        do { try MCPMigration.sync(copy) } catch { Log.write("mcp: couldn't update backend configs: \(error.localizedDescription)") }
    }

    /// A tab's own switch for one server.
    func setTab(_ tab: UUID, server name: String, enabled: Bool) {
        let key = MCPBackendConfig.tabDisabledKey(tab)
        var off = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if enabled { off.remove(name) } else { off.insert(name) }
        UserDefaults.standard.set(off.isEmpty ? nil : off.sorted(), forKey: key)
        revision = UUID()
    }

    private func set(_ name: String, _ state: State) {
        states[name] = state
        revision = UUID()
        if ![.awaitingApproval, .needsLogin, .needsSignIn, .locked].contains(state.phase) { MCPHost.shared.resolveAlert(name) }
    }

    /// Reads each OAuth server's sign-in from the Keychain.
    func refreshStates() async {
        for server in snapshot.servers {
            guard server.oauth else {
                if states[server.name] == nil { set(server.name, State(phase: .ready)) }
                continue
            }
            if flows[server.name] != nil { continue }
            do {
                if let credential = try await signIns.credential(server.name) {
                    set(server.name, State(phase: .ready, expiresAt: credential.expiresAt))
                } else {
                    set(server.name, State(phase: .needsSignIn, message: "Not signed in."))
                }
            } catch {
                set(server.name, State(phase: .locked, message: error.localizedDescription))
            }
        }
    }

    /// A relayed call found the sign-in expired or the keychain locked.
    func reportProblem(_ name: String, _ message: String) {
        guard flows[name] == nil else { return }
        let locked = message.contains("keychain")
        set(name, State(phase: locked ? .locked : .needsSignIn, message: message))
        onNeedsAttention?(name, locked ? .locked : .needsSignIn)
    }

    // MARK: - Sign-in

    func connect(_ name: String) {
        guard let server = server(name), server.oauth, let address = server.url.flatMap(URL.init(string:)),
              flows[name] == nil else { return }
        set(name, State(phase: .connecting, message: "Finding where \(name) signs in…"))
        flows[name] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.signIn(name, address: address)
                let credential = try await self.signIns.credential(name)
                self.set(name, State(phase: .ready, message: "Signed in.", expiresAt: credential?.expiresAt))
                Log.write("mcp: \(name) signed in through Cantrip")
            } catch {
                let failure = error as? MCPOAuth.Failure
                self.set(name, State(phase: failure?.kind == .keychain ? .locked : (failure?.kind == .denied ? .needsSignIn : .failed),
                                     message: error.localizedDescription))
                Log.write("mcp: \(name) sign-in failed: \(error.localizedDescription)")
            }
            self.flows[name] = nil
        }
    }

    /// Approve (or decline) the consent page waiting for `name`.
    func respond(_ name: String, approve: Bool) {
        decisions.removeValue(forKey: name)?.resume(returning: approve)
    }

    func cancel(_ name: String) {
        respond(name, approve: false)
        flows[name]?.cancel()
    }

    func signOut(_ name: String) async {
        try? await signIns.signOut(name)
        set(name, State(phase: .needsSignIn, message: "Signed out."))
    }

    private func signIn(_ name: String, address: URL) async throws {
        let endpoints = try await MCPOAuth.discover(server: address)
        // Reuse the registration and its loopback port when the server knew Cantrip before.
        let previous = try? await signIns.credential(name)
        let reusePort = previous.flatMap { URL(string: $0.redirectURI)?.port }.flatMap { UInt16(exactly: $0) }
        let callback: MCPOAuth.Callback
        if let reused = try? MCPOAuth.Callback(port: reusePort ?? 0) { callback = reused } else { callback = try MCPOAuth.Callback() }
        defer { callback.cancel() }
        let client: (id: String, secret: String?)
        if let previous, previous.redirectURI == callback.redirectURI, previous.endpoints.issuer == endpoints.issuer {
            client = (previous.clientID, previous.clientSecret)
        } else {
            client = try await MCPOAuth.register(endpoints, redirectURI: callback.redirectURI)
        }
        let verifier = MCPOAuth.randomURLSafe(48), state = MCPOAuth.randomURLSafe(16)
        guard let url = MCPOAuth.authorizeURL(endpoints, clientID: client.id, redirectURI: callback.redirectURI,
                                              state: state, verifier: verifier) else {
            throw MCPOAuth.Failure(kind: .discovery, message: "Couldn't build the sign-in address.")
        }
        let fields = try await authorize(name, url: url, callback: callback, redirect: callback.redirectURI)
        guard fields["state"] == state else { throw MCPOAuth.Failure(kind: .denied, message: "The sign-in reply didn't match (state).") }
        guard let code = fields["code"] else {
            throw MCPOAuth.Failure(kind: .denied, message: "Sign-in was declined: \(fields["error_description"] ?? fields["error"] ?? "no code").")
        }
        set(name, State(phase: .connecting, message: "Saving the sign-in…"))
        do {
            _ = try await signIns.complete(server: name, endpoints: endpoints, clientID: client.id, clientSecret: client.secret,
                                           redirectURI: callback.redirectURI, code: code, verifier: verifier)
        } catch let failure as MCPSecrets.Failure {
            throw MCPOAuth.Failure(kind: .keychain, message: failure.localizedDescription)
        }
    }

    /// Opens the consent page in agent Chrome and walks it with you; falls back to the Mac's
    /// default browser when agent Chrome isn't running. Returns the redirect's query fields.
    private func authorize(_ name: String, url: URL, callback: MCPOAuth.Callback, redirect: String) async throws -> [String: String] {
        guard await chrome.isRunning(), let tab = try? await chrome.open(url) else {
            openInDefaultBrowser(url)
            set(name, State(phase: .needsLogin, message: "Agent Chrome isn't running, so the sign-in opened in the Mac's browser. Finish it there."))
            onNeedsAttention?(name, .needsLogin)
            return try await callback.wait(timeout: 15 * 60)
        }
        defer { Task { [chrome] in await chrome.close(tab) } }
        var asked = false, notedLogin = false
        let deadline = Date().addingTimeInterval(15 * 60)
        while !Task.isCancelled, Date() < deadline {
            if let fields = callback.result { return fields }
            try await Task.sleep(for: .milliseconds(1_200))
            if let fields = callback.result { return fields }
            guard let page = try? await chrome.inspect(tab) else { continue }
            if page.url.hasPrefix(redirect) { continue }
            let shot = await chrome.screenshot(tab)
            if let label = page.approve, !page.login, !asked {
                asked = true
                set(name, State(phase: .awaitingApproval,
                                message: "\(page.host) asks to give Cantrip access to \(name). Approve to press “\(label)”.",
                                page: page, screenshot: shot))
                onNeedsAttention?(name, .awaitingApproval)
                let approved = await withCheckedContinuation { decisions[name] = $0 }
                guard approved else { throw MCPOAuth.Failure(kind: .denied, message: "You declined the sign-in.") }
                set(name, State(phase: .connecting, message: "Approved. Finishing the sign-in…", page: page, screenshot: shot))
                if !(try await chrome.clickApprove(tab)) {
                    throw MCPOAuth.Failure(kind: .denied, message: "The approve button disappeared before Cantrip could press it.")
                }
            } else if page.login {
                if !notedLogin { onNeedsAttention?(name, .needsLogin) }
                notedLogin = true
                set(name, State(phase: .needsLogin,
                                message: "\(page.host) wants you to log in first. Log in in agent Chrome (Remote › Browser shows it), then Cantrip continues.",
                                page: page, screenshot: shot))
            } else if !asked {
                set(name, State(phase: .connecting, message: "Opening \(page.host)…", page: page, screenshot: shot))
            }
        }
        throw MCPOAuth.Failure(kind: .denied, message: "Sign-in was cancelled.")
    }

    // MARK: - Remote

    /// What Remote clients show (no secrets: tokens never leave the Keychain).
    func remotePayload(includeScreenshots: Bool = true) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let servers: [[String: Any]] = snapshot.servers.map { server in
            var item: [String: Any] = [
                "name": server.name, "remote": server.isRemote, "oauth": server.oauth, "relayed": server.isRelayed,
                "enabled": server.enabled, "disabledBackends": server.disabledBackends, "source": server.source,
                // Whether a header or environment credential is in the keychain; never its name or value.
                "credentials": !server.secretHeaders.isEmpty || !server.secretEnv.isEmpty,
                "address": server.url ?? ([server.command.map { ($0 as NSString).lastPathComponent }].compactMap { $0 }
                    + server.args.map { ($0 as NSString).lastPathComponent }).joined(separator: " "),
            ]
            if let tools = server.tools { item["tools"] = tools }
            if var state = states[server.name] {
                if !includeScreenshots { state.screenshot = nil }
                if let data = try? encoder.encode(state), let object = try? JSONSerialization.jsonObject(with: data) {
                    item["state"] = object
                }
            }
            return item
        }
        return ["servers": servers, "revision": revision.uuidString, "supportsApproval": true]
    }
}
