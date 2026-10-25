import SwiftUI

/// Thread tags (Cantrip Home). A reply from a different thread than the message above it carries
/// `thread` from the Mac: the prompt that started its thread. The tag sits beside the lane badge;
/// tapping it opens that thread inline (the prompt, then the earlier messages in it), fetched from
/// the Mac so it works before older messages have loaded. Shared by iPhone, Duo and Gateway Mac.
struct CantripRemoteThreadTag: Decodable, Equatable {
    let id: String
    /// The start of the prompt, on one line.
    let prompt: String
}

struct CantripRemoteThread: Decodable, Equatable {
    struct Prompt: Decodable, Equatable {
        let id: String
        let text: String
    }

    struct Message: Decodable, Equatable, Identifiable {
        let id: String
        let role: String
        let text: String
        var author: String? = nil
    }

    let id: String
    let prompt: Prompt
    let messages: [Message]
    var hasEarlier: Bool = false
}

/// Which tags are open and the threads already fetched, by tagged message ID. Kept outside the
/// views so a lazily recycled row reopens as it was without fetching again.
@MainActor
final class CantripThreadTagStore: ObservableObject {
    static let shared = CantripThreadTagStore()
    @Published private(set) var open: Set<String> = []
    @Published private(set) var threads: [String: CantripRemoteThread] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var loading: Set<String> = []

    func toggle(_ messageID: String, tag: CantripRemoteThreadTag, sessionID: String?, remote: CantripRemoteModel) {
        if open.remove(messageID) == nil {
            open.insert(messageID)
            errors[messageID] = nil
            load(messageID, tag: tag, sessionID: sessionID, remote: remote)
        }
    }

    func retry(_ messageID: String, tag: CantripRemoteThreadTag, sessionID: String?, remote: CantripRemoteModel) {
        errors[messageID] = nil
        load(messageID, tag: tag, sessionID: sessionID, remote: remote)
    }

    func load(_ messageID: String, tag: CantripRemoteThreadTag, sessionID: String?, remote: CantripRemoteModel) {
        guard threads[messageID] == nil, errors[messageID] == nil, !loading.contains(messageID) else { return }
        guard let sessionID else {
            errors[messageID] = "This thread isn't available."
            return
        }
        loading.insert(messageID)
        Task {
            do {
                threads[messageID] = try await remote.thread(sessionID: sessionID, threadID: tag.id, before: messageID)
            } catch {
                errors[messageID] = "Couldn't load this thread: \(error.localizedDescription)"
            }
            loading.remove(messageID)
        }
    }
}

/// The lane badge and, for a reply from another thread, its tag; the opened thread below them.
struct CantripThreadHeader: View {
    var lane: ExecutionLane?
    let tag: CantripRemoteThreadTag?
    let messageID: String
    let sessionID: String?
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var store = CantripThreadTagStore.shared
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""

    private var expanded: Bool { store.open.contains(messageID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tag {
                CantripChildFlowLayout(spacing: 6, lineSpacing: 4, shrinksToFit: 140) {
                    if let lane { ExecutionLaneBadge(lane: lane) }
                    toggle(tag)
                }
                if expanded { thread(tag) }
            } else if let lane {
                ExecutionLaneBadge(lane: lane)
            }
        }
    }

    private func toggle(_ tag: CantripRemoteThreadTag) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                store.toggle(messageID, tag: tag, sessionID: sessionID, remote: remote)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.left")
                Text(verbatim: tag.prompt).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(CantripChildTabStyle.neutralFill, in: Capsule())
            #if os(iOS)
            // A 44 pt tap target without making the row taller.
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
            #else
            .contentShape(Capsule())
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to: \(tag.prompt)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the earlier messages in this thread")
        .accessibilityIdentifier("cantrip-thread-tag-\(messageID)")
    }

    @ViewBuilder
    private func thread(_ tag: CantripRemoteThreadTag) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thread = store.threads[messageID] {
                bubble(thread.prompt.text)
                if thread.hasEarlier {
                    Text("Earlier messages in this thread aren't shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(thread.messages) { message in
                    if message.role == "user" {
                        bubble(message.text)
                    } else {
                        reply(message)
                    }
                }
            } else if let error = store.errors[messageID] {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { store.retry(messageID, tag: tag, sessionID: sessionID, remote: remote) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading the thread…").font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { store.load(messageID, tag: tag, sessionID: sessionID, remote: remote) }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cantrip-thread-\(messageID)")
    }

    /// Pip's side of the thread: a gray bubble on the left, named above it.
    private func reply(_ message: CantripRemoteThread.Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name(of: message))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
            // Paragraphs run together in the 3-line preview.
            Text(TurnView.markdown(message.text.replacingOccurrences(
                of: #"\s*\n\s*"#, with: " ", options: .regularExpression)))
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(CantripChildTabStyle.neutralFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)
    }

    private func bubble(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(CantripChildTabStyle.bubble, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 32)
    }

    private func name(of message: CantripRemoteThread.Message) -> String {
        switch message.role {
        case "handoff": "Handoff"
        case "error": "Error"
        default: CantripMascotName.display(mascotName)
        }
    }
}
