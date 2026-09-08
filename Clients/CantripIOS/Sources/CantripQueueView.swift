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
    @State private var removingPromptID: String?
    @State private var removalError: String?

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
            .alert("Could not remove message", isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )) {
                Button("OK", role: .cancel) { removalError = nil }
            } message: {
                Text(removalError ?? "")
            }
        }
    }

    private var canRemove: Bool {
        remote.isConnected && !remote.isMutating && removingPromptID == nil
            && session?.supportsQueueRemoval == true
    }

    private func remove(_ prompt: CantripRemoteQueuedPrompt) {
        removingPromptID = prompt.id
        Task {
            let removed = await remote.removeQueuedPrompt(prompt.id, sessionID: sessionID)
            if !removed {
                removalError = remote.errorMessage
                    ?? "Removal could not be confirmed. Check the queue before trying again."
            }
            removingPromptID = nil
        }
    }

    private func queueRow(_ prompt: CantripRemoteQueuedPrompt, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(index == 0 ? "Next in queue" : "Queue position \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if removingPromptID == prompt.id {
                    ProgressView()
                        .accessibilityLabel("Removing queued message")
                } else if session?.supportsQueueRemoval == true {
                    Button(role: .destructive) { remove(prompt) } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRemove)
                    .accessibilityLabel("Remove queued message")
                    .accessibilityHint(prompt.text)
                }
            }
            Text(prompt.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if session?.supportsQueueRemoval == true {
                // A destructive swipe role hides the row before the Mac confirms removal.
                Button("Remove", systemImage: "trash") {
                    remove(prompt)
                }
                .tint(.red)
                .disabled(!canRemove)
            }
        }
    }

    @ViewBuilder
    private func queueContents(_ session: CantripRemoteSession) -> some View {
        if let queued = session.queued {
            List {
                Section {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { index, prompt in
                        queueRow(prompt, index: index)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("These prompts are accepted by your Mac and run in order. They move into the conversation when they start.")
                        if session.supportsQueueRemoval == true {
                            Text("Remove a prompt with the trash button or swipe left. Removing a queued message does not stop the current task.")
                        } else {
                            Text("Update and reopen Cantrip on your Mac to remove queued messages here.")
                        }
                    }
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
