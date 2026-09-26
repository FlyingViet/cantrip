import SwiftUI
import ApplicationServices

struct MacAccessView: View {
    @ObservedObject private var desktop = RemoteDesktop.shared
    @ObservedObject private var attention = MacAttention.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow paired clients to view and control this Mac", isOn: $desktop.enabled)
            Text("View Mac is off by default. Enabling it allows any client with your pairing token to start a five-minute session. Screen Recording and Accessibility must be granted here first. Screen frames and typed text are not saved or sent to AI models.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if desktop.activeUntil != nil {
                Label("Remote viewing is active", systemImage: "display")
                Button("End Remote View Now", role: .destructive) { desktop.stop() }
            }

            HStack {
                Button("Screen Recording Settings") { open(.screenRecording) }
                Button("Accessibility Settings") { open(.accessibility) }
            }
            ForEach(attention.issues) { issue in
                Button(issue.title) { open(issue.permission) }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            Text("Protected dialogs may not accept remote input or appear in captures. Touch ID and macOS authorization are never replaced by phone approval.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func open(_ permission: MacPermission) {
        if permission == .screenRecording { ScreenCapture.shared.requestAccess() }
        if permission == .accessibility, !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        do { try attention.openSettings(permission) }
        catch { self.error = error.localizedDescription }
    }
}

struct MacDesktopStatusView: View {
    @ObservedObject private var desktop = RemoteDesktop.shared

    var body: some View {
        if desktop.activeUntil != nil {
            Button {
                desktop.stop()
            } label: {
                Label("End Remote View", systemImage: "display")
                    .foregroundStyle(.orange)
            }
            .help("A paired client is viewing this Mac. Click to disconnect it immediately.")
        }
    }
}
