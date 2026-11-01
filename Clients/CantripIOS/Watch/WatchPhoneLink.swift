import Foundation
import WatchConnectivity

/// Asks Cantrip on the paired iPhone to register this watch with its Mac.
final class WatchPhoneLink: NSObject, WCSessionDelegate {
    static let shared = WatchPhoneLink()

    private static let openPhoneMessage = "Open Cantrip on your iPhone, then try again."

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated { session.activate() }
    }

    func register(publicKey: String, name: String) async throws -> CantripWatchConfiguration {
        guard WCSession.isSupported() else { throw CantripWatchError.failed(Self.openPhoneMessage) }
        activate()
        await waitForActivation(timeout: 5)
        let session = WCSession.default
        guard session.activationState == .activated else { throw CantripWatchError.failed(Self.openPhoneMessage) }
        guard session.isCompanionAppInstalled else {
            throw CantripWatchError.failed("Install Cantrip Agent on your iPhone, then try again.")
        }
        guard session.isReachable else { throw CantripWatchError.failed(Self.openPhoneMessage) }

        let message: [String: Any] = ["type": "register", "publicKey": publicKey, "name": name]
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message, replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                continuation.resume(throwing: Self.plainError(error))
            })
        }
        return try Self.configuration(from: reply)
    }

    static func configuration(from reply: [String: Any]) throws -> CantripWatchConfiguration {
        if let error = reply["error"] as? String, !error.isEmpty {
            throw CantripWatchError.failed(error)
        }
        guard let deviceID = reply["deviceID"] as? String, !deviceID.isEmpty,
              let tailnet = CantripWatchURL.origin(reply["tailnet"] as? String)
        else {
            throw CantripWatchError.failed("Your iPhone sent an unexpected answer. Update Cantrip on the iPhone.")
        }
        return CantripWatchConfiguration(
            deviceID: deviceID,
            tailnet: tailnet,
            internet: CantripWatchURL.origin(reply["internet"] as? String),
            serverName: (reply["server"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func plainError(_ error: Error) -> Error {
        if let error = error as? WCError {
            switch error.code {
            case .companionAppNotInstalled, .watchAppNotInstalled:
                return CantripWatchError.failed("Install Cantrip Agent on your iPhone, then try again.")
            default:
                return CantripWatchError.failed(openPhoneMessage)
            }
        }
        return CantripWatchError.failed(openPhoneMessage)
    }

    private func waitForActivation(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while WCSession.default.activationState != .activated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}
