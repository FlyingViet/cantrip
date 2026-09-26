import AppKit
import ApplicationServices
import AVFoundation
import Speech
import LocalAuthentication

enum MacPermission: String, Codable, CaseIterable {
    case screenRecording, accessibility, microphone, speechRecognition, fullDiskAccess, keychain, authentication

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .fullDiskAccess: return "Full Disk Access"
        case .keychain: return "Keychain"
        case .authentication: return "Touch ID & Password"
        }
    }
}

struct MacPermissionStatus: Encodable {
    let permission: MacPermission
    let title: String
    let state: String
}

struct MacAttentionIssue: Encodable, Identifiable {
    let id: UUID
    let permission: MacPermission
    let title: String
}

struct MacAccessSnapshot: Encodable {
    let name: String
    let desktopEnabled: Bool
    let permissions: [MacPermissionStatus]
    let issues: [MacAttentionIssue]
    let activeUntil: Double?
}

@MainActor
final class MacAttention: ObservableObject {
    static let shared = MacAttention()
    @Published private(set) var issues: [MacAttentionIssue] = []
    var onAttention: ((MacAttentionIssue) -> Void)?
    var onResolved: ((UUID) -> Void)?

    nonisolated static func report(_ permission: MacPermission) {
        Task { @MainActor in shared.record(permission) }
    }

    func record(_ permission: MacPermission) {
        guard !issues.contains(where: { $0.permission == permission }) else { return }
        let issue = MacAttentionIssue(id: UUID(), permission: permission, title: "\(permission.title) needs attention on the Mac")
        issues.append(issue)
        onAttention?(issue)
    }

    func clear(_ permission: MacPermission) {
        let removed = issues.filter { $0.permission == permission }
        issues.removeAll { $0.permission == permission }
        for issue in removed { onResolved?(issue.id) }
    }

    func permissions() -> [MacPermissionStatus] {
        MacPermission.allCases.map { permission in
            let state: String
            switch permission {
            case .screenRecording: state = CGPreflightScreenCaptureAccess() ? "granted" : "notGranted"
            case .accessibility: state = AXIsProcessTrusted() ? "granted" : "notGranted"
            case .microphone: state = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "granted" : "notGranted"
            case .speechRecognition: state = SFSpeechRecognizer.authorizationStatus() == .authorized ? "granted" : "notGranted"
            case .fullDiskAccess: state = "manualCheck"
            case .keychain: state = issues.contains { $0.permission == .keychain } ? "needsAttention" : "checkedWhenUsed"
            case .authentication:
                let context = LAContext()
                state = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
                    ? "localBiometricsAvailable" : "localPasswordRequired"
                context.invalidate()
            }
            if state == "granted" { clear(permission) }
            return MacPermissionStatus(permission: permission, title: permission.title, state: state)
        }
    }

    func openSettings(_ permission: MacPermission) throws {
        if permission == .authentication {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"),
                  NSWorkspace.shared.open(url) else {
                throw SessionModelSettingsError(503, "Open Touch ID & Password in System Settings on the Mac.")
            }
            return
        }
        if permission == .keychain {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess"),
                  NSWorkspace.shared.open(url) else {
                throw SessionModelSettingsError(503, "Open Keychain Access on the Mac to review the requesting application's access.")
            }
            return
        }
        let pane: String
        switch permission {
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .keychain: pane = ""
        case .authentication: pane = ""
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url) else {
            throw SessionModelSettingsError(503, "Open System Settings > Privacy & Security on the Mac.")
        }
    }
}
