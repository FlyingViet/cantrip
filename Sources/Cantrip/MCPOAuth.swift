import CryptoKit
import Foundation
import Network

/// OAuth for remote MCP servers, done by Cantrip so every backend shares one sign-in: the MCP
/// authorization flow (protected-resource metadata, authorization-server metadata, dynamic client
/// registration, PKCE with S256, a loopback redirect) and refresh. The sign-in lives in the
/// Keychain only (`MCPSecrets.oauthAccount`).
enum MCPOAuth {
    struct Failure: LocalizedError, Equatable {
        enum Kind: String, Codable { case discovery, registration, denied, provider, exchange, needsSignIn, keychain }
        let kind: Kind
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one HTTP request; tests replace it.
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let defaultTransport: Transport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Where a server signs in, found from the server itself.
    struct Endpoints: Codable, Equatable {
        var resource: String
        var issuer: String
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var scopes: [String] = []
    }

    /// The client Cantrip registered with a sign-in server (dynamic client registration), stored as
    /// JSON in the Keychain from registration on, so a retry or a later sign-in reuses it.
    struct RegisteredClient: Codable, Equatable {
        var issuer: String
        var clientID: String
        var clientSecret: String?
        var redirectURI: String

        var port: UInt16? { URL(string: redirectURI)?.port.flatMap { UInt16(exactly: $0) } }
    }

    /// One server's sign-in, stored as JSON in the Keychain.
    struct Credential: Codable, Equatable {
        var endpoints: Endpoints
        var clientID: String
        var clientSecret: String?
        var redirectURI: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var signedInAt: Date

        func isFresh(at now: Date, margin: TimeInterval = 120) -> Bool {
            expiresAt.map { $0.timeIntervalSince(now) > margin } ?? true
        }
    }

    // MARK: - Discovery

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A sign-in server's reason in an error body, in words: `error_description`, Supabase's `msg`,
    /// or `message`, with its code ("client_id is required (validation_failed)").
    static func refusal(in object: [String: Any]) -> String? {
        let reason = ["error_description", "msg", "message", "error"].lazy
            .compactMap { object[$0] as? String }.first { !$0.isEmpty }
        guard let reason else { return nil }
        let code = [object["error_code"] as? String, object["error"] as? String].compactMap { $0 }.first { !$0.isEmpty && $0 != reason }
        return code.map { "\(reason) (\($0))" } ?? reason
    }

    /// The sign-in server's refusal on the page agent Chrome shows instead of a sign-in: an OAuth
    /// `error` in the address, a JSON error body (Chrome shows it under "Pretty-print"), or Chrome's
    /// own page for an address it couldn't load. Nil for an ordinary page.
    static func providerError(pageURL: String, title: String, text: String) -> String? {
        if pageURL.hasPrefix("chrome-error:") { return "agent Chrome couldn't load the page (\(title.isEmpty ? "no answer" : title))" }
        if let items = URLComponents(string: pageURL)?.queryItems,
           let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            let description = items.first { $0.name == "error_description" }?.value.flatMap { $0.isEmpty ? nil : $0 }
            return description.map { "\($0) (\(error))" } ?? error
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count < 4_000, let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close,
              body.distance(from: body.startIndex, to: open) <= 20,
              let object = json(Data(body[open...close].utf8)) else { return nil }
        return refusal(in: object)
    }

    /// `resource_metadata="…"` from a 401's WWW-Authenticate header.
    static func resourceMetadataURL(fromChallenge header: String?) -> URL? {
        guard let header, let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let value = header[range].dropFirst("resource_metadata=\"".count).dropLast()
        return URL(string: String(value))
    }

    /// RFC 8414 / OIDC well-known addresses for an issuer, path-aware first.
    static func metadataCandidates(issuer: URL) -> [URL] {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path == "/" ? "" : components.path
        var candidates: [URL] = []
        for well in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            components.path = well + path
            if let url = components.url { candidates.append(url) }
            components.path = path + well
            if let url = components.url, !candidates.contains(url) { candidates.append(url) }
        }
        return candidates
    }

    /// An unauthenticated MCP `initialize`, as a backend's first request would be.
    static func initializeRequest(_ server: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: server)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Cantrip","version":"1"}}}"#.utf8)
        return request
    }

    /// RFC 9728 protected-resource metadata addresses for a server, path-aware first.
    static func protectedResourceCandidates(_ server: URL) -> [URL] {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path
        components.query = nil
        var candidates: [URL] = []
        components.path = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
        if let url = components.url { candidates.append(url) }
        components.path = "/.well-known/oauth-protected-resource"
        if let url = components.url, !candidates.contains(url) { candidates.append(url) }
        return candidates
    }

    /// Whether a remote server needs a sign-in, found by asking it without one.
    enum Access: Equatable {
        /// It answered `initialize` without credentials and names no sign-in server.
        case open
        /// It asked for a sign-in (401 or a Bearer challenge), or its metadata names a sign-in server.
        case oauth
        /// It couldn't be told; why, in words.
        case unknown(String)
    }

    /// Asks `server` to `initialize` with no credentials (only its non-secret `headers`). An answer
    /// alone isn't enough: some servers serve anonymous callers and sign in for more (seats.aero),
    /// and say so in their protected-resource metadata.
    static func detectAccess(server: URL, headers: [String: String] = [:], timeout: TimeInterval = 8,
                             transport: Transport = defaultTransport) async -> Access {
        var probe = initializeRequest(server, headers: headers)
        probe.timeoutInterval = timeout
        let response: HTTPURLResponse
        do {
            response = try await transport(probe).1
        } catch {
            return .unknown("couldn't reach \(server.host ?? "it"): \(error.localizedDescription)")
        }
        if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            // Ends the session the probe opened (optional for servers; best effort).
            var close = URLRequest(url: server)
            close.httpMethod = "DELETE"
            close.timeoutInterval = timeout
            close.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await transport(close)
        }
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased() ?? ""
        if response.statusCode == 401 || challenge.hasPrefix("bearer") { return .oauth }
        for url in protectedResourceCandidates(server) {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            if let (data, metadata) = try? await transport(request), metadata.statusCode == 200,
               json(data)?["authorization_servers"] != nil {
                return .oauth
            }
        }
        if (200..<300).contains(response.statusCode) { return .open }
        return .unknown("it answered HTTP \(response.statusCode)")
    }

    /// `detectAccess` for several servers at once, for callers that answer synchronously
    /// (`cantrip mcp migrate`). Waits at most `timeout` for each request; a server still
    /// unanswered after `limit` is unknown. It blocks the calling thread, so `transport` must not
    /// need the main actor.
    static func detectAccessWaiting(_ servers: [MCPServer], timeout: TimeInterval = 8, limit: TimeInterval = 20,
                                    transport: @escaping Transport = defaultTransport) -> [String: Access] {
        let targets = servers.compactMap { server in server.url.flatMap(URL.init(string:)).map { (server.name, $0, server.headers) } }
        guard !targets.isEmpty else { return [:] }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var found: [String: Access] = [:]
        }
        let results = Results(), done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for (name, url, headers) in targets {
                    group.addTask {
                        let access = await detectAccess(server: url, headers: headers, timeout: timeout, transport: transport)
                        results.lock.withLock { results.found[name] = access }
                    }
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + limit)
        let found = results.lock.withLock { results.found }
        return Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.0, found[target.0] ?? .unknown("it didn't answer within \(Int(limit)) seconds"))
        })
    }

    static func discover(server: URL, transport: Transport = defaultTransport) async throws -> Endpoints {
        func fail(_ text: String) -> Failure { Failure(kind: .discovery, message: text) }
        // A server that couldn't be reached isn't a server without sign-in settings: say which it was.
        var unreachable: Error?
        func fetch(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
            do { return try await transport(request) } catch { unreachable = error; return nil }
        }
        // An unauthenticated request names its metadata in the challenge.
        var metadataURLs: [URL] = []
        if let (_, response) = await fetch(initializeRequest(server)), response.statusCode == 401,
           let url = resourceMetadataURL(fromChallenge: response.value(forHTTPHeaderField: "WWW-Authenticate")) {
            metadataURLs.append(url)
        }
        for url in protectedResourceCandidates(server) where !metadataURLs.contains(url) { metadataURLs.append(url) }
        var resource: [String: Any]?
        for url in metadataURLs {
            if let (data, response) = await fetch(URLRequest(url: url)), response.statusCode == 200,
               let object = json(data), object["authorization_servers"] != nil {
                resource = object
                break
            }
        }
        guard let resource, let issuerText = (resource["authorization_servers"] as? [String])?.first,
              let issuer = URL(string: issuerText) else {
            if let unreachable {
                throw fail("Couldn't reach \(server.host ?? "the server") to find where it signs in: \(unreachable.localizedDescription)")
            }
            throw fail("\(server.host ?? "The server") doesn't say where to sign in (no OAuth protected-resource metadata).")
        }
        for url in metadataCandidates(issuer: issuer) {
            guard let (data, response) = await fetch(URLRequest(url: url)), response.statusCode == 200,
                  let object = json(data), let authorize = object["authorization_endpoint"] as? String,
                  let token = object["token_endpoint"] as? String else { continue }
            let methods = object["code_challenge_methods_supported"] as? [String] ?? ["S256"]
            guard methods.contains("S256") else { throw fail("\(issuer.host ?? "The sign-in server") doesn't support PKCE (S256).") }
            return Endpoints(resource: resource["resource"] as? String ?? server.absoluteString,
                             issuer: object["issuer"] as? String ?? issuerText,
                             authorizationEndpoint: authorize, tokenEndpoint: token,
                             registrationEndpoint: object["registration_endpoint"] as? String,
                             scopes: resource["scopes_supported"] as? [String] ?? [])
        }
        if let unreachable {
            throw fail("Couldn't reach \(issuer.host ?? issuerText) for its sign-in settings: \(unreachable.localizedDescription)")
        }
        throw fail("Couldn't read the sign-in server's settings at \(issuer.host ?? issuerText).")
    }

    // MARK: - Registration and PKCE

    static func register(_ endpoints: Endpoints, redirectURI: String,
                         transport: Transport = defaultTransport) async throws -> (id: String, secret: String?) {
        guard let address = endpoints.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw Failure(kind: .registration, message: "The server doesn't let apps register, so Cantrip can't sign in to it yet.")
        }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Cantrip", "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode), let object = json(data), let id = object["client_id"] as? String else {
            let body = json(data) ?? [:]
            let reason = refusal(in: body).map { ": \($0)" } ?? ""
            var message = "Registering Cantrip with the sign-in server failed\(reason) (HTTP \(response.statusCode))."
            if onlyKnownClients(error: body["error"] as? String, status: response.statusCode) {
                message += " It only lets apps it already knows sign in. If the service gives out API keys, use one instead: add it as the "
                    + "server's Authorization header (usually `Bearer <key>`) in ~/.copilot/mcp-config.json, then run "
                    + "`cantrip mcp migrate --apply`, which moves it to the keychain."
            }
            throw Failure(kind: .registration, message: message)
        }
        return (id, object["client_secret"] as? String)
    }

    /// A registration refused because the sign-in server accepts only clients it already knows
    /// (RevenueCat's: "The client is not registered" (invalid_client)), not because of what was sent.
    static func onlyKnownClients(error: String?, status: Int) -> Bool {
        status == 401 || status == 403
            || ["invalid_client", "unauthorized_client", "access_denied", "unapproved_software_statement"].contains(error ?? "")
    }

    static func randomURLSafe(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizeURL(_ endpoints: Endpoints, clientID: String, redirectURI: String, state: String,
                             verifier: String) -> URL? {
        guard var components = URLComponents(string: endpoints.authorizationEndpoint) else { return nil }
        var items = components.queryItems ?? []
        items += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
                  URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "state", value: state),
                  URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
                  URLQueryItem(name: "code_challenge_method", value: "S256"),
                  URLQueryItem(name: "resource", value: endpoints.resource)]
        if !endpoints.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: endpoints.scopes.joined(separator: " "))) }
        components.queryItems = items
        return components.url
    }

    // MARK: - Tokens

    static func formBody(_ fields: [(String, String?)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.compactMap { key, value in
            value.map { "\(key)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)" }
        }.joined(separator: "&").utf8)
    }

    /// Posts to the token endpoint and applies the answer to `credential`.
    static func requestTokens(_ fields: [(String, String?)], credential: Credential, now: Date,
                              transport: Transport) async throws -> Credential {
        guard let address = URL(string: credential.endpoints.tokenEndpoint) else {
            throw Failure(kind: .exchange, message: "The token address is invalid.")
        }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(fields + [("client_id", credential.clientID), ("client_secret", credential.clientSecret),
                                              ("resource", credential.endpoints.resource)])
        let (data, response) = try await transport(request)
        let object = json(data) ?? [:]
        guard response.statusCode == 200, let access = object["access_token"] as? String, !access.isEmpty else {
            let code = object["error"] as? String ?? "HTTP \(response.statusCode)"
            let signInAgain = ["invalid_grant", "invalid_client", "unauthorized_client"].contains(code)
            throw Failure(kind: signInAgain ? .needsSignIn : .exchange, message: signInAgain
                ? "The sign-in expired (\(code)). Connect again in Cantrip."
                : "The sign-in server refused the token request: \(refusal(in: object) ?? code).")
        }
        var updated = credential
        updated.accessToken = access
        // Servers that rotate refresh tokens send a new one; others keep the old one valid.
        if let refresh = object["refresh_token"] as? String, !refresh.isEmpty { updated.refreshToken = refresh }
        updated.expiresAt = (object["expires_in"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
        return updated
    }

    // MARK: - Loopback redirect

    /// Answers one `GET /oauth/callback?code=…&state=…` on 127.0.0.1.
    final class Callback: @unchecked Sendable {
        private let listener: NWListener
        let port: UInt16
        private var continuation: CheckedContinuation<[String: String], Error>?
        private var received: [String: String]?
        private let lock = NSLock()

        init(port requested: UInt16 = 0) throws {
            // Loopback only: nothing off this Mac can reach the redirect.
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested) ?? .any)
            let ready = DispatchSemaphore(value: 0)
            var failed: Error?
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error): failed = error; ready.signal()
                default: break
                }
            }
            // NWListener fails (EINVAL) unless it has a connection handler before it starts.
            final class Owner: @unchecked Sendable { weak var callback: Callback? }
            let owner = Owner()
            listener.newConnectionHandler = { connection in
                guard let callback = owner.callback else { return connection.cancel() }
                callback.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            _ = ready.wait(timeout: .now() + 5)
            if let failed { throw failed }
            guard let port = listener.port?.rawValue else { throw URLError(.cannotFindHost) }
            self.port = port
            owner.callback = self
        }

        var redirectURI: String { "http://127.0.0.1:\(port)/oauth/callback" }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let self else { return connection.cancel() }
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = line.split(separator: " ")
                var fields: [String: String] = [:]
                if parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: "http://127.0.0.1" + parts[1]),
                   url.path == "/oauth/callback" {
                    for item in url.queryItems ?? [] { fields[item.name] = item.value ?? "" }
                }
                let ok = fields["code"] != nil
                let message = ok ? "Signed in. Cantrip has the sign-in; you can close this tab."
                    : fields["error"].map { "Sign-in didn't finish: \($0)." } ?? "Not a sign-in callback."
                let body = "<!doctype html><meta charset=utf-8><title>Cantrip</title><body style=\"font:16px -apple-system;margin:3em\">\(message)</body>"
                let response = "HTTP/1.1 \(fields.isEmpty ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard !fields.isEmpty else { return }
                self.finish(.success(fields))
            }
        }

        private func finish(_ result: Result<[String: String], Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            if case .success(let fields) = result, received == nil { received = fields }
            lock.unlock()
            waiting?.resume(with: result)
        }

        /// The callback's query fields once it arrived.
        var result: [String: String]? { lock.withLock { received } }

        /// The callback's query fields, or a timeout.
        func wait(timeout: TimeInterval) async throws -> [String: String] {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    return continuation.resume(returning: received)
                }
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(Failure(kind: .denied, message: "Sign-in timed out before the browser came back to Cantrip.")))
                }
            }
        }

        func cancel() {
            listener.cancel()
            finish(.failure(Failure(kind: .denied, message: "Sign-in was cancelled.")))
        }

        deinit { listener.cancel() }
    }
}

/// Signs servers in and keeps their tokens fresh. One refresh at a time per server, so a server
/// that rotates refresh tokens never sees two used at once.
actor MCPSignIns {
    static let shared = MCPSignIns()

    var secrets: MCPSecrets.Store
    var transport: MCPOAuth.Transport
    var now: @Sendable () -> Date
    private var refreshing: [String: Task<MCPOAuth.Credential, Error>] = [:]

    init(secrets: MCPSecrets.Store = .keychain, transport: @escaping MCPOAuth.Transport = MCPOAuth.defaultTransport,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.transport = transport
        self.now = now
    }

    func credential(_ server: String) throws -> MCPOAuth.Credential? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try secrets.read(MCPSecrets.oauthAccount(server)).flatMap { try? decoder.decode(MCPOAuth.Credential.self, from: $0) }
    }

    func store(_ credential: MCPOAuth.Credential, for server: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try secrets.write(MCPSecrets.oauthAccount(server), try encoder.encode(credential))
    }

    /// Signing out removes the tokens; the registered client stays for the next sign-in.
    func signOut(_ server: String) throws {
        try secrets.delete(MCPSecrets.oauthAccount(server))
    }

    /// The saved registration, or the one inside a sign-in saved before registrations were kept.
    func registeredClient(_ server: String) throws -> MCPOAuth.RegisteredClient? {
        if let data = try secrets.read(MCPSecrets.clientAccount(server)),
           let client = try? JSONDecoder().decode(MCPOAuth.RegisteredClient.self, from: data) {
            return client
        }
        return try credential(server).map {
            MCPOAuth.RegisteredClient(issuer: $0.endpoints.issuer, clientID: $0.clientID, clientSecret: $0.clientSecret,
                                      redirectURI: $0.redirectURI)
        }
    }

    /// The client to sign in with: the saved one when it's for this sign-in server and redirect,
    /// else a new registration, saved before the sign-in page opens.
    func client(for server: String, endpoints: MCPOAuth.Endpoints, redirectURI: String) async throws -> MCPOAuth.RegisteredClient {
        if let saved = try registeredClient(server), saved.issuer == endpoints.issuer, saved.redirectURI == redirectURI {
            return saved
        }
        let registered = try await MCPOAuth.register(endpoints, redirectURI: redirectURI, transport: transport)
        let client = MCPOAuth.RegisteredClient(issuer: endpoints.issuer, clientID: registered.id, clientSecret: registered.secret,
                                               redirectURI: redirectURI)
        try secrets.write(MCPSecrets.clientAccount(server), try JSONEncoder().encode(client))
        return client
    }

    /// Drops a registration the sign-in server refused, so the next try registers again.
    func forgetClient(_ server: String) throws {
        try secrets.delete(MCPSecrets.clientAccount(server))
    }

    /// A current access token: the stored one while fresh, else refreshed. `force` refreshes
    /// even a fresh one (the server just rejected it).
    func accessToken(for server: String, force: Bool = false) async throws -> String {
        guard let stored = try credential(server) else {
            throw MCPOAuth.Failure(kind: .needsSignIn, message: "\(server) isn't signed in. Connect it in Cantrip's MCP Servers settings.")
        }
        if !force, stored.isFresh(at: now()) { return stored.accessToken }
        return try await refresh(server, from: stored).accessToken
    }

    private func refresh(_ server: String, from stored: MCPOAuth.Credential) async throws -> MCPOAuth.Credential {
        if let running = refreshing[server] { return try await running.value }
        guard let refreshToken = stored.refreshToken else {
            throw MCPOAuth.Failure(kind: .needsSignIn, message: "\(server)'s sign-in expired. Connect it again in Cantrip.")
        }
        let transport = transport, now = now()
        let task = Task { try await MCPOAuth.requestTokens([("grant_type", "refresh_token"), ("refresh_token", refreshToken)],
                                                          credential: stored, now: now, transport: transport) }
        refreshing[server] = task
        defer { refreshing[server] = nil }
        let fresh = try await task.value
        try store(fresh, for: server)
        return fresh
    }

    /// Exchanges an authorization code (from the loopback redirect) and saves the sign-in.
    func complete(server: String, endpoints: MCPOAuth.Endpoints, clientID: String, clientSecret: String?,
                  redirectURI: String, code: String, verifier: String) async throws -> MCPOAuth.Credential {
        let pending = MCPOAuth.Credential(endpoints: endpoints, clientID: clientID, clientSecret: clientSecret,
                                          redirectURI: redirectURI, accessToken: "", refreshToken: nil,
                                          expiresAt: nil, signedInAt: now())
        let signedIn = try await MCPOAuth.requestTokens(
            [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI), ("code_verifier", verifier)],
            credential: pending, now: now(), transport: transport)
        try store(signedIn, for: server)
        return signedIn
    }

    /// Refreshes every OAuth server whose token ends within `window`, so sign-ins stay alive
    /// even when no tab uses them. Returns the servers that now need signing in again.
    func refreshExpiring(_ servers: [String], window: TimeInterval = 15 * 60) async -> [String: String] {
        var problems: [String: String] = [:]
        for server in servers {
            do {
                guard let stored = try credential(server) else { continue }
                if !stored.isFresh(at: now(), margin: window) { _ = try await refresh(server, from: stored) }
            } catch {
                problems[server] = error.localizedDescription
            }
        }
        return problems
    }
}
