import SwiftUI

struct CantripQueueButton: View {
    let session: CantripRemoteSession
    /// Sends the next queued message now. Nil keeps the plain row.
    var sendNow: (() -> Void)? = nil
    var isSendingNow = false
    var canSendNow = true
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var next: CantripRemoteQueuedPrompt? { session.queued?.first }

    private var showsSendNow: Bool {
        sendNow != nil && session.supportsQueueSendNow == true && next != nil
    }

    var body: some View {
        Group {
            if !showsSendNow {
                openButton
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    openButton
                    sendNowButton
                        .padding([.horizontal, .bottom], 10)
                }
            } else {
                HStack(spacing: 0) {
                    openButton
                    sendNowButton
                        .padding(.trailing, 10)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var openButton: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Queued messages (\(session.queuedCount))", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                if let next {
                    Text(verbatim: PromptText(CantripTabMentions.plain(next.presentedText)).preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("View messages waiting to run on your Mac")
    }

    @ViewBuilder
    private var sendNowButton: some View {
        if let next, let sendNow {
            Button(action: sendNow) {
                // The label keeps its width under the spinner so the row doesn't jump.
                Label("Send now", systemImage: "arrow.up.circle")
                    .font(.caption.weight(.semibold))
                    .opacity(isSendingNow ? 0 : 1)
                    .overlay {
                        if isSendingNow {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(
                        minWidth: 44, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                        minHeight: 44
                    )
            }
            .buttonStyle(.bordered)
            .disabled(!canSendNow || isSendingNow)
            .accessibilityLabel(isSendingNow ? "Sending next queued message now" : "Send next queued message now")
            .accessibilityHint(PromptText(CantripTabMentions.plain(next.presentedText)).preview)
        }
    }
}

struct CantripQueueView: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var removingPromptID: String?
    @State private var sendingPromptID: String?
    @State private var forkingPromptID: String?
    @State private var actionError: ActionError?

    private struct ActionError {
        let title: String
        let message: String
    }

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
            .alert(actionError?.title ?? "", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError?.message ?? "")
            }
        }
    }

    private var canMutate: Bool {
        remote.isConnected && !remote.isMutating && removingPromptID == nil
            && sendingPromptID == nil && remote.sendingQueuedPromptID == nil
            && forkingPromptID == nil && remote.forkingQueuedPromptID == nil
    }

    private var supportsChildTabs: Bool { session?.supportsChildTabs == true }

    /// Child tabs are offered but can't start now (caps full, a child itself, …).
    private var childTabsUnavailableReason: String? {
        guard supportsChildTabs else { return nil }
        return session?.childTabsUnavailableReason.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var canFork: Bool {
        canMutate && supportsChildTabs && childTabsUnavailableReason == nil
    }

    private var canRemove: Bool {
        canMutate && session?.supportsQueueRemoval == true
    }

    private var canSendNow: Bool {
        canMutate && session?.supportsQueueSendNow == true
    }

    private func isSending(_ prompt: CantripRemoteQueuedPrompt) -> Bool {
        sendingPromptID == prompt.id || remote.sendingQueuedPromptID == prompt.id
    }

    private func isForking(_ prompt: CantripRemoteQueuedPrompt) -> Bool {
        forkingPromptID == prompt.id || remote.forkingQueuedPromptID == prompt.id
    }

    /// Starts the message now in a child tab under this one; this tab stays open.
    private func fork(_ prompt: CantripRemoteQueuedPrompt) {
        forkingPromptID = prompt.id
        Task {
            let child = await remote.forkQueuedPrompt(prompt.id, sessionID: sessionID)
            forkingPromptID = nil
            if child == nil {
                actionError = ActionError(
                    title: "Could not start a child tab",
                    message: remote.errorMessage
                        ?? "The child tab could not be confirmed. Check the tab list before trying again."
                )
            } else if session?.queuedCount == 0 {
                dismiss()
            }
        }
    }

    private func remove(_ prompt: CantripRemoteQueuedPrompt) {
        removingPromptID = prompt.id
        Task {
            let removed = await remote.removeQueuedPrompt(prompt.id, sessionID: sessionID)
            if !removed {
                actionError = ActionError(
                    title: "Could not remove message",
                    message: remote.errorMessage
                        ?? "Removal could not be confirmed. Check the queue before trying again."
                )
            }
            removingPromptID = nil
        }
    }

    private func sendNow(_ prompt: CantripRemoteQueuedPrompt) {
        sendingPromptID = prompt.id
        Task {
            let sent = await remote.sendQueuedPromptNow(prompt.id, sessionID: sessionID)
            sendingPromptID = nil
            if !sent {
                actionError = ActionError(
                    title: "Could not send message",
                    message: remote.errorMessage
                        ?? "Sending could not be confirmed. Check the conversation before trying again."
                )
            } else if session?.queuedCount == 0 {
                // Nothing is left to manage; show the conversation the message went into.
                dismiss()
            }
        }
    }

    private func queueRow(_ prompt: CantripRemoteQueuedPrompt, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(index == 0 ? "Next in queue" : "Queue position \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSending(prompt) {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Sending queued message now")
                } else if removingPromptID == prompt.id {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Removing queued message")
                } else if isForking(prompt) {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Starting a child tab")
                } else {
                    if supportsChildTabs {
                        Button { fork(prompt) } label: {
                            Image(systemName: CantripChildTabStyle.glyph)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(CantripChildTabStyle.lane)
                        .disabled(!canFork)
                        .help(childTabsUnavailableReason
                              ?? "Run in a child tab: its own tab and branch, merged back when it's done.")
                        .accessibilityLabel("Run in child tab")
                        .accessibilityHint(childTabsUnavailableReason ?? PromptText(CantripTabMentions.plain(prompt.presentedText)).preview)
                        .accessibilityIdentifier("cantrip-queue-fork-\(index)")
                    }
                    if session?.supportsQueueSendNow == true {
                        Button { sendNow(prompt) } label: {
                            Image(systemName: "arrow.up.circle")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canSendNow)
                        .accessibilityLabel("Send queued message now")
                        .accessibilityHint(PromptText(CantripTabMentions.plain(prompt.presentedText)).preview)
                    }
                    if session?.supportsQueueRemoval == true {
                        Button(role: .destructive) { remove(prompt) } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canRemove)
                        .accessibilityLabel("Remove queued message")
                        .accessibilityHint(PromptText(CantripTabMentions.plain(prompt.presentedText)).preview)
                    }
                }
            }
            PromptTextView(text: prompt.presentedText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let plan = prompt.plan, !plan.reason.isEmpty {
                CantripQueuePlanChip(plan: plan)
            }
            ChatImageGallery(
                images: (prompt.images ?? []).map { $0.inSession(sessionID) }, remote: remote
            )
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if session?.supportsQueueSendNow == true {
                Button("Send now", systemImage: "arrow.up.circle") {
                    sendNow(prompt)
                }
                .tint(.blue)
                .disabled(!canSendNow)
            }
            if supportsChildTabs {
                Button("Child tab", systemImage: CantripChildTabStyle.glyph) {
                    fork(prompt)
                }
                .tint(.teal)
                .disabled(!canFork)
            }
        }
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
                } header: {
                    if let reason = childTabsUnavailableReason {
                        Text(reason)
                            .textCase(nil)
                            .accessibilityIdentifier("cantrip-queue-child-unavailable")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("These prompts are accepted by your Mac and run in order. They move into the conversation when they start.")
                        if supportsChildTabs {
                            Text("Run in child tab starts a message now in its own tab under this one, on its own branch, and merges it back when it's done. Each message shows what your Mac suggests.")
                        }
                        if session.supportsQueueSendNow == true {
                            Text("Send now delivers a message without waiting. Work already running keeps going in the background.")
                        }
                        if session.supportsQueueRemoval == true {
                            Text("Remove a prompt with the trash button or swipe left. Removing a queued message does not stop the current task.")
                        } else {
                            Text("Update and reopen Cantrip on your Mac to remove queued messages here.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
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
