import CryptoKit
import Foundation

/// The wire API a Private Local server speaks. Ollama stays the default for saved settings.
enum PrivateLocalAPI: String, Codable, CaseIterable {
    case ollama
    /// `GET {base}/models` and streamed `POST {base}/chat/completions` (oMLX, LM Studio, mlx-serve…).
    case openAI = "openai"

    /// How errors name the server: Ollama keeps its name, anything else is the user's own server.
    var serverName: String { self == .ollama ? "self-hosted Ollama server" : "self-hosted server" }
    var modelsPath: String { self == .ollama ? "/api/tags" : "/models" }
    var chatPath: String { self == .ollama ? "/api/chat" : "/chat/completions" }
}

struct PrivateLocalConfiguration: Codable, Equatable {
    var baseURL = "http://127.0.0.1:11434"
    var model = ""
    var contextWindow = 8192
    var systemPrompt = "You are a helpful private assistant. Answer using only this conversation. You have no tools or internet access."
    var api = PrivateLocalAPI.ollama

    private enum CodingKeys: String, CodingKey { case baseURL, model, contextWindow, systemPrompt, api }

    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw SessionModelSettingsError(400, api == .ollama
                ? "Enter your self-hosted Ollama server's base URL without credentials, query parameters, fragments or dot-path segments."
                : "Enter your self-hosted server's OpenAI-compatible base URL, ending in its API version path such as /v1, without credentials, query parameters, fragments or dot-path segments.")
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]"].contains(host)
        guard components.scheme?.lowercased() == "https" || loopback else {
            throw SessionModelSettingsError(400, "Use HTTPS for a self-hosted server on another machine, such as its Tailscale Serve URL. Unencrypted HTTP is allowed only on loopback.")
        }
        if host == "localhost" { components.host = "127.0.0.1" }
        // Preserve a reverse proxy's base path and encoding without changing the configured origin.
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + path
        guard let url = components.url else {
            throw SessionModelSettingsError(400, "Invalid \(api.serverName) address.")
        }
        return url
    }

    func validate(requireModel: Bool = true) throws {
        _ = try endpoint(api.chatPath)
        guard (512...131072).contains(contextWindow), systemPrompt.count <= 8000 else {
            throw SessionModelSettingsError(400, "Choose 512-131072 context tokens and a system prompt of at most 8000 characters.")
        }
        guard (!requireModel || !model.isEmpty), model.count <= 200,
              model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !model.contains("://"), !Self.isCloudModel(model) else {
            throw SessionModelSettingsError(400, "Choose a model installed on your \(api.serverName), not a cloud model.")
        }
    }

    static func isCloudModel(_ name: String) -> Bool {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("cloud")
    }
}

extension PrivateLocalConfiguration {
    /// Settings saved before the API choice existed have no `api` key: they stay on Ollama.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        contextWindow = try container.decode(Int.self, forKey: .contextWindow)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        api = try container.decodeIfPresent(PrivateLocalAPI.self, forKey: .api) ?? .ollama
    }

    static let remoteFields: Set<String> = ["baseURL", "model", "contextWindow", "systemPrompt"]

    /// A remote client's complete configuration. Clients that predate the API choice omit `api`;
    /// they keep the saved one rather than silently switching the server back to Ollama.
    static func remote(_ fields: [String: Any], savedAPI: PrivateLocalAPI) throws -> PrivateLocalConfiguration {
        let keys = Set(fields.keys)
        guard keys == remoteFields || keys == remoteFields.union(["api"]),
              fields["baseURL"] is String, fields["model"] is String, fields["systemPrompt"] is String,
              let tokens = fields["contextWindow"] as? NSNumber,
              CFGetTypeID(tokens) != CFBooleanGetTypeID(),
              tokens.doubleValue == Double(tokens.intValue) else {
            throw SessionModelSettingsError(400, "Provide revision and the complete Private Local configuration.")
        }
        if let api = fields["api"], (api as? String).flatMap(PrivateLocalAPI.init(rawValue:)) == nil {
            throw SessionModelSettingsError(400, "Choose Ollama or an OpenAI-compatible server API.")
        }
        var configuration = try JSONDecoder().decode(PrivateLocalConfiguration.self,
                                                     from: JSONSerialization.data(withJSONObject: fields))
        if fields["api"] == nil { configuration.api = savedAPI }
        return configuration
    }
}

struct PrivateLocalSnapshot: Encodable {
    let configuration: PrivateLocalConfiguration
    let revision: String
    let unavailableReason: String?
}

extension ChatSession {
    // The reserved identity, not an editable setting, enforces the route across restarts.
    nonisolated static let privateLocalID = UUID(uuidString: "91A48C51-6D58-4B56-972C-F81A93701E73")!
    var isLocalPrivate: Bool { id == Self.privateLocalID }

    var privateLocalRevision: String {
        let data = UserDefaults.standard.data(forKey: "privateLocalConfiguration") ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func privateLocalConfiguration() throws -> PrivateLocalConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "privateLocalConfiguration") else {
            return PrivateLocalConfiguration()
        }
        do { return try JSONDecoder().decode(PrivateLocalConfiguration.self, from: data) }
        catch { throw SessionModelSettingsError(500, "Private Local settings could not be read. Repair the saved settings on this Mac; no request was sent.") }
    }

    func privateLocalSnapshot() throws -> PrivateLocalSnapshot {
        guard isLocalPrivate else { throw SessionModelSettingsError(404, "This is not the Private Local tab.") }
        return try PrivateLocalSnapshot(configuration: privateLocalConfiguration(), revision: privateLocalRevision,
                                        unavailableReason: isStreaming || !queued.isEmpty || shell.isRunning
                                            ? "Wait for the Private Local tab and its queue to finish before saving." : nil)
    }

    func updatePrivateLocalSettings(_ configuration: PrivateLocalConfiguration, revision: String) throws {
        let snapshot = try privateLocalSnapshot()
        guard revision == snapshot.revision else {
            throw SessionModelSettingsError(409, "Private Local settings changed on another device. Reload before saving.")
        }
        if let reason = snapshot.unavailableReason { throw SessionModelSettingsError(409, reason) }
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        UserDefaults.standard.set(data, forKey: "privateLocalConfiguration")
        objectWillChange.send()
    }
}
