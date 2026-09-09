import SwiftUI

struct CantripStopButton: View {
    let session: CantripRemoteSession?
    let isConnected: Bool
    let isMutating: Bool
    let isStopping: Bool
    var iconOnly = false
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
                HStack(spacing: 4) {
                    if isStopping {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "stop.fill")
                    }
                    if !iconOnly {
                        Text(isStopping ? "Stopping..." : "Stop")
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                .font(.caption.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: iconOnly ? 24 : nil, height: iconOnly ? 24 : nil)
                .padding(.horizontal, iconOnly ? 6 : 8)
                .padding(.vertical, 6)
                .background(.red.opacity(isEnabled ? 0.12 : 0.06), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEnabled ? Color.red : Color.secondary)
            .tint(.red)
            .disabled(!isEnabled)
            .accessibilityLabel(isStopping ? "Stopping Cantrip prompt" : "Stop current Cantrip prompt")
            .accessibilityHint("Stops work on this tab and clears its queued prompts. Keeps the conversation.")
            .accessibilityIdentifier("cantrip.stop")
        }
    }
}
