import LocalAuthentication
import UIKit

@MainActor
enum CantripBiometrics {
    static func authorize(_ reason: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        try await authorize(applicationState: { UIApplication.shared.applicationState }, notifications: .default, evaluate: {
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw ServerConfigurationError(message: "Face ID or Touch ID is required for this action. Set up biometrics in device Settings, or perform the action on the Mac. Cancel and Deny remain available.")
            }
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        }, invalidate: { context.invalidate() })
    }

    static func authorize(applicationState: @escaping () -> UIApplication.State,
                          notifications: NotificationCenter, activationTimeout: Duration = .seconds(5),
                          evaluate: () async throws -> Bool, invalidate: @escaping () -> Void) async throws {
        try Task.checkCancellation()
        guard applicationState() == .active else { throw CancellationError() }
        let activity = BiometricActivity(applicationState: applicationState, notifications: notifications, invalidate: invalidate)
        defer { activity.close() }
        try await withTaskCancellationHandler {
            guard try await evaluate() else {
                throw ServerConfigurationError(message: "Biometric authentication did not succeed. Nothing was sent.")
            }
            // Face ID can complete while its system sheet still leaves the app inactive.
            try await activity.waitUntilActive(timeout: activationTimeout)
        } onCancel: {
            Task { @MainActor in activity.cancel() }
        }
    }
}

@MainActor
private final class BiometricActivity {
    private let applicationState: () -> UIApplication.State
    private let notifications: NotificationCenter
    private let invalidate: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(applicationState: @escaping () -> UIApplication.State, notifications: NotificationCenter,
         invalidate: @escaping () -> Void) {
        self.applicationState = applicationState
        self.notifications = notifications
        self.invalidate = invalidate
        observers = [
            notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            },
            notifications.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled, self.applicationState() == .active else { return }
                    self.finish(.success(()))
                }
            }
        ]
    }

    func waitUntilActive(timeout: Duration) async throws {
        try Task.checkCancellation()
        guard !cancelled, applicationState() != .background else { throw CancellationError() }
        if applicationState() == .active { return }
        defer { timeoutTask?.cancel(); timeoutTask = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                finish(.failure(ServerConfigurationError(message: "Authentication finished, but AgentGateway did not become active. Nothing was sent. Try again.")))
            }
        }
        try Task.checkCancellation()
        guard !cancelled, applicationState() == .active else { throw CancellationError() }
    }

    func cancel() {
        cancelled = true
        invalidate()
        finish(.failure(CancellationError()))
    }

    func close() {
        observers.forEach(notifications.removeObserver)
        observers.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
