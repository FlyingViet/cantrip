import Foundation
import SwiftUI

enum GatewayTransportPolicy {
    static func issue(for url: URL) -> String? {
        guard url.user == nil, url.password == nil else {
            return "Gateway URLs cannot contain embedded credentials."
        }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return "Enter a complete gateway URL."
        }
        if scheme == "https" {
            return nil
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        if scheme == "http", loopbackHosts.contains(host) {
            return nil
        }
        return "Use HTTPS for a Mac or remote gateway. Plain HTTP exposes prompts and the API key."
    }
}

enum GatewayConnectionState: Equatable {
    case notChecked
    case checking
    case connected
    case failed(String)
}

/// App-wide configuration + connection to the Hermes gateway's OpenAI-compatible
/// API server (`/v1/responses`).
@MainActor
final class HermesEnv: ObservableObject {
    // Each user points this at their own HTTPS Hermes gateway. No default server.
    @AppStorage("hermes.baseURL") var baseURL: String = ""
    /// Selected TTS voice identifier (empty = system default). `VoiceController`
    /// reads this key directly from UserDefaults at speak time.
    @AppStorage("hermes.voiceId") var voiceId: String = ""
    /// Stable per-install id so the gateway can scope long-term memory to this app
    /// (the `X-Hermes-Session-Key` header). Generated once, kept in UserDefaults.
    @AppStorage("hermes.sessionKey") private var storedSessionKey: String = ""

    @Published var apiKey: String = Keychain.get("hermes.apiKey") ?? ""
    @Published private(set) var executionLane: ExecutionLane
    @Published private(set) var availableModels: Set<String> = []
    @Published private(set) var connectionState: GatewayConnectionState = .notChecked

    init() {
        let storedLane = UserDefaults.standard.string(forKey: "hermes.executionLane")
        executionLane = ExecutionLane(rawValue: storedLane ?? "") ?? .defaultLane
    }

    var sessionKey: String {
        if storedSessionKey.isEmpty { storedSessionKey = "ios-" + UUID().uuidString }
        return storedSessionKey
    }

    var transportIssue: String? {
        let value = trimmed(baseURL)
        guard !value.isEmpty else { return "Enter your gateway URL." }
        guard let url = URL(string: value) else { return "Enter a valid gateway URL." }
        return GatewayTransportPolicy.issue(for: url)
    }

    var configurationIssue: String? {
        if let transportIssue {
            return transportIssue
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the gateway API key."
        }
        if executionLane == .local, !isAvailable(.local) {
            return "The gateway has not advertised the local-private model route."
        }
        return nil
    }

    var isConfigured: Bool { configurationIssue == nil }

    var gatewayIdentity: String? {
        guard let url = URL(string: trimmed(baseURL)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        var path = url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return "\(scheme)://\(host):\(url.port ?? defaultPort)\(path)"
    }

    var client: HermesClient? {
        client(for: executionLane)
    }

    func client(for lane: ExecutionLane) -> HermesClient? {
        guard let url = URL(string: trimmed(baseURL)),
              GatewayTransportPolicy.issue(for: url) == nil,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let scopedSessionKey = lane == .copilot ? sessionKey : "\(sessionKey)-local"
        return HermesClient(
            baseURL: url,
            apiKey: apiKey,
            sessionKey: scopedSessionKey,
            model: lane.modelAlias
        )
    }

    func isAvailable(_ lane: ExecutionLane) -> Bool {
        switch lane {
        case .copilot:
            true
        case .local:
            availableModels.contains(lane.modelAlias)
        }
    }

    func select(_ lane: ExecutionLane) {
        guard isAvailable(lane) else { return }
        executionLane = lane
        UserDefaults.standard.set(lane.rawValue, forKey: "hermes.executionLane")
    }

    @discardableResult
    func refreshGateway() async -> GatewayConnectionState {
        availableModels.removeAll()
        guard let probeClient = client(for: .copilot) else {
            let state = GatewayConnectionState.failed(
                transportIssue ?? "Enter the gateway URL and API key."
            )
            connectionState = state
            return state
        }
        connectionState = .checking
        do {
            availableModels = try await probeClient.models()
            guard availableModels.contains(ExecutionLane.copilot.modelAlias) else {
                let state = GatewayConnectionState.failed(
                    "Gateway is reachable, but the copilot-coding route is missing."
                )
                connectionState = state
                return state
            }
            if executionLane == .local, !availableModels.contains(ExecutionLane.local.modelAlias) {
                let state = GatewayConnectionState.failed(
                    "Gateway is reachable, but the local-private route is missing."
                )
                connectionState = state
                return state
            }
            connectionState = .connected
        } catch {
            connectionState = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        return connectionState
    }

    func setAPIKey(_ value: String) {
        apiKey = value
        invalidateGateway()
        if value.isEmpty { Keychain.remove("hermes.apiKey") } else { Keychain.set(value, for: "hermes.apiKey") }
    }

    func invalidateGateway() {
        availableModels.removeAll()
        connectionState = .notChecked
    }

    private func trimmed(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}
