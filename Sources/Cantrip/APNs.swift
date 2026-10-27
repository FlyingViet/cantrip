import CryptoKit
import Foundation

/// What every Apple push sender shares: the connection and the provider token.
enum APNs {
    /// Sends one request over the shared HTTP/2 connection.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RemotePushError(status: 502, message: "Apple push returned an invalid response.")
        }
        return (data, response)
    }
}

/// The provider token (a signed JWT) for the Mac's push key, shared by every sender.
///
/// APNs expects a token to be reused for 20 to 60 minutes and rejects a connection whose token
/// changes more often (TooManyProviderTokenUpdates). Alerts and live status share one connection,
/// so a cache each would alternate two tokens on it.
final class APNsProviderToken: @unchecked Sendable {
    static let shared = APNsProviderToken()
    /// Under APNs' one-hour limit, with room for clock skew.
    static let lifetime: TimeInterval = 3000

    private let lock = NSLock()
    private var cached: (keyID: String, keyDigest: Data, value: String, date: Date)?

    func value(for configuration: RemotePushConfiguration, now: Date) throws -> String {
        let digest = Data(SHA256.hash(data: configuration.key.rawRepresentation))
        return try lock.withLock {
            if let cached, cached.keyID == configuration.keyID, cached.keyDigest == digest,
               now.timeIntervalSince(cached.date) < Self.lifetime {
                return cached.value
            }
            let value = try configuration.authorization(now: now)
            cached = (configuration.keyID, digest, value, now)
            return value
        }
    }

    /// After APNs answers ExpiredProviderToken for `value`. A newer token stays.
    func expire(_ value: String) {
        lock.withLock {
            if cached?.value == value { cached = nil }
        }
    }
}
