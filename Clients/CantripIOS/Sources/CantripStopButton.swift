import SwiftUI

struct CantripStopButton: View {
    let session: CantripRemoteSession?
    let isConnected: Bool
    let isMutating: Bool
    let isStopping: Bool
    let onStop: (String) -> Void

    var isVisible: Bool {
        session != nil && (session?.isStreaming == true || isStopping)
    }

    var isEnabled: Bool {
        session?.isStreaming == true && isConnected && !isMutating && !isStopping
    }

    var body: some View {
        if let session, isVisible {
            Button(role: .destructive) {
                onStop(session.id)
            } label: {
                HStack(spacing: 6) {
                    if isStopping {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                    }
                    Text(isStopping ? "Stopping..." : "Stop")
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .font(.callout.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!isEnabled)
            .accessibilityLabel(isStopping ? "Stopping Cantrip prompt" : "Stop current Cantrip prompt")
            .accessibilityHint("Stops work on this tab and clears its queued prompts. Keeps the conversation.")
            .accessibilityIdentifier("cantrip.stop")
        }
    }
}
