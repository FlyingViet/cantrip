#if os(iOS) && canImport(WatchConnectivity)
import Foundation
import UIKit
import WatchConnectivity

/// Sets up Cantrip on Apple Watch: the watch sends its public key, and this iPhone registers it
/// with the selected Mac (over HTTPS, with its pairing token), then tells the watch how to reach it.
final class CantripWatchLink: NSObject, WCSessionDelegate {
    static let shared = CantripWatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches; listen for the new one.
        session.activate()
    }

    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["type"] as? String == "register" else {
            replyHandler(["error": "Update Cantrip on your iPhone, then try again."])
            return
        }
        let name = message["name"] as? String ?? ""
        let publicKey = message["publicKey"] as? String ?? ""
        Task { @MainActor in
            // The watch may have woken this app in the background; finish the request first.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Cantrip Watch setup")
            let reply = await CantripWatchRegistration.register(name: name, publicKey: publicKey)
            replyHandler(reply)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }
}

enum CantripWatchRegistration {
    private struct Response: Decodable {
        struct Device: Decodable {
            let id: String
        }

        let device: Device
        let internet: String?
    }

    /// The reply for the watch: `deviceID`, `tailnet`, `internet` (when on) and `server`, or `error`.
    @MainActor
    static func register(
        name: String, publicKey: String,
        servers: ServerProfiles? = nil, session: URLSession? = nil
    ) async -> [String: Any] {
        do {
            return try await registerOrThrow(
                name: name, publicKey: publicKey,
                servers: servers ?? ServerProfiles(kind: .cantrip), session: session ?? .shared
            )
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    @MainActor
    private static func registerOrThrow(
        name: String, publicKey: String, servers: ServerProfiles, session: URLSession
    ) async throws -> [String: Any] {
        guard let key = Data(base64Encoded: publicKey), key.count == 65, key.first == 0x04 else {
            throw ServerConfigurationError(message: "Update Cantrip on your watch, then try again.")
        }
        let pairOverTailscale = ServerConfigurationError(
            message: "Pair Cantrip on this iPhone with your Mac over Tailscale first, then set up the watch again."
        )
        guard let server = servers.selected else { throw pairOverTailscale }
        guard let baseURL = try? CantripRemoteModel.normalizedBaseURL(server.url), isAllowed(baseURL) else {
            throw pairOverTailscale
        }
        let token = try servers.credential(for: server)

        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/watch/devices"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": displayName(name), "publicKey": publicKey,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServerConfigurationError(
                message: "Your iPhone can't reach \(server.name). Check that Tailscale is on, then try again."
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServerConfigurationError(message: "\(server.name) sent an unexpected answer. Try again.")
        }
        switch http.statusCode {
        case 200, 201:
            break
        case 401:
            throw ServerConfigurationError(
                message: "\(server.name) didn't accept this iPhone's pairing. Pair Cantrip on the iPhone again, then set up the watch."
            )
        case 404:
            throw ServerConfigurationError(message: "Update Cantrip on \(server.name) to use it from Apple Watch.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ServerConfigurationError(
                message: message ?? "\(server.name) couldn't add the watch (error \(http.statusCode)). Try again."
            )
        }
        guard let registered = try? JSONDecoder().decode(Response.self, from: data),
              !registered.device.id.isEmpty else {
            throw ServerConfigurationError(message: "Update Cantrip on \(server.name) to use it from Apple Watch.")
        }
        var reply: [String: Any] = [
            "deviceID": registered.device.id,
            "tailnet": baseURL.absoluteString,
            "server": server.name,
        ]
        if let internet = registered.internet, !internet.isEmpty { reply["internet"] = internet }
        return reply
    }

    private static func isAllowed(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        #if DEBUG
        return url.host == "127.0.0.1" || url.host == "localhost"
        #else
        return false
        #endif
    }

    private static func displayName(_ raw: String) -> String {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Apple Watch" : String(name.prefix(80))
    }
}
#endif
