import Foundation
import SwiftUI

/// App-wide configuration + connection to the Hermes gateway's OpenAI-compatible
/// API server (`/v1/responses`). The endpoint defaults to the Mac's LAN address;
/// point it at the Cloudflare tunnel hostname to use Hermes away from home.
@MainActor
final class HermesEnv: ObservableObject {
    // Each user points this at THEIR OWN Hermes gateway api_server (LAN address
    // or a Cloudflare tunnel). No default server — set it in Settings on first run.
    @AppStorage("hermes.baseURL") var baseURL: String = ""
    @AppStorage("hermes.model") var model: String = "hermes-agent"
    /// Selected TTS voice identifier (empty = system default). `VoiceController`
    /// reads this key directly from UserDefaults at speak time.
    @AppStorage("hermes.voiceId") var voiceId: String = ""
    /// Stable per-install id so the gateway can scope long-term memory to this app
    /// (the `X-Hermes-Session-Key` header). Generated once, kept in UserDefaults.
    @AppStorage("hermes.sessionKey") private var storedSessionKey: String = ""

    @Published var apiKey: String = Keychain.get("hermes.apiKey") ?? ""

    var sessionKey: String {
        if storedSessionKey.isEmpty { storedSessionKey = "ios-" + UUID().uuidString }
        return storedSessionKey
    }

    var isConfigured: Bool { !trimmed(baseURL).isEmpty && URL(string: trimmed(baseURL)) != nil }

    var client: HermesClient? {
        guard let url = URL(string: trimmed(baseURL)) else { return nil }
        return HermesClient(baseURL: url, apiKey: apiKey, sessionKey: sessionKey, model: model)
    }

    func setAPIKey(_ value: String) {
        apiKey = value
        if value.isEmpty { Keychain.remove("hermes.apiKey") } else { Keychain.set(value, for: "hermes.apiKey") }
    }

    private func trimmed(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}
