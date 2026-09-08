import SwiftUI

struct CantripQueueButton: View {
    let session: CantripRemoteSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Queued messages (\(session.queuedCount))", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                if let next = session.queued?.first {
                    Text(next.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("View messages waiting to run on your Mac")
    }
}

struct CantripQueueView: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss

    private var session: CantripRemoteSession? {
        guard remote.selectedSession?.id == sessionID else { return nil }
        return remote.selectedSession
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session, session.queuedCount > 0 {
                    queueContents(session)
                } else {
                    ContentUnavailableView(
                        "No queued messages",
                        systemImage: "text.badge.checkmark",
                        description: Text("Accepted prompts appear here while waiting to run.")
                    )
                }
            }
            .navigationTitle("Queued messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                if !remote.isConnected {
                    Label(
                        "Disconnected. Showing the last known queue.",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func queueContents(_ session: CantripRemoteSession) -> some View {
        if let queued = session.queued {
            List {
                Section {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { index, prompt in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(index == 0 ? "Next in queue" : "Queue position \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(prompt.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("These prompts are accepted by your Mac and run in order. They move into the conversation when they start.")
                }
            }
        } else {
            ContentUnavailableView(
                "\(session.queuedCount) queued on your Mac",
                systemImage: "clock",
                description: Text("Update and relaunch Cantrip on your Mac to see the queued message contents.")
            )
        }
    }
}
