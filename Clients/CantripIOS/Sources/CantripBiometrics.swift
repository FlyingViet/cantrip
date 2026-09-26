import LocalAuthentication
import UIKit

@MainActor
enum CantripBiometrics {
    static func authorize(_ reason: String) async throws {
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw ServerConfigurationError(message: "Face ID or Touch ID is required for this action. Set up biometrics in device Settings, or perform the action on the Mac. Cancel and Deny remain available.")
        }
        defer { context.invalidate() }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw ServerConfigurationError(message: "Biometric authentication did not succeed. Nothing was sent.")
        }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
    }
}
