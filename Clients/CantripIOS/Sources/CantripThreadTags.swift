import SwiftUI

/// Thread tags (Cantrip Home), drawn like inline replies in Messages. A reply from a different
/// thread than the message above it carries `thread` from the Mac: the prompt that started its
/// thread. The reply shows a small copy of that prompt, joined to it by a curved line in the left
/// margin. A prompt whose replies other messages split up says "N Replies" under it (the Mac's
/// `threadReplies`). Either opens the whole thread over the blurred conversation, fetched from the
/// Mac so it works before older messages have loaded. Shared by iPhone, Duo and Gateway Mac; the
/// browser Remote and Windows draw the same.
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

/// The thread on screen.
struct CantripThreadFocus: Identifiable, Equatable {
    let sessionID: String
    let threadID: String
    /// The prompt as the conversation shows it, until the thread loads.
    let prompt: String
    /// The reply it was opened from, scrolled into view; nil from a prompt's "N Replies".
    var messageID: String? = nil

    var id: String { "\(sessionID)/\(threadID)" }
}

enum CantripThreadText {
    static func replies(_ count: Int) -> String { count == 1 ? "1 Reply" : "\(count) Replies" }
}

/// The open thread and the threads already fetched, by thread ID. Kept outside the views so the
/// presenter and every row share them.
@MainActor
final class CantripThreadTagStore: ObservableObject {
    static let shared = CantripThreadTagStore()
    /// Fetched threads kept besides the open one.
    private static let limit = 12
    @Published private(set) var focus: CantripThreadFocus?
    @Published private(set) var threads: [String: CantripRemoteThread] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var loading: Set<String> = []
    private var stale: Set<String> = []
    private var order: [String] = []

    func open(_ focus: CantripThreadFocus, remote: CantripRemoteModel) {
        self.focus = focus
        errors[focus.threadID] = nil
        load(focus, remote: remote)
    }

    func close() { focus = nil }

    /// Fetches the whole thread. Replies keep arriving, so it's fetched on every open and whenever
    /// the conversation changes while it's open; a failed refresh keeps what's shown.
    func load(_ focus: CantripThreadFocus, remote: CantripRemoteModel) {
        let id = focus.threadID
        guard !loading.contains(id) else {
            stale.insert(id)
            return
        }
        loading.insert(id)
        Task {
            do {
                threads[id] = try await remote.thread(sessionID: focus.sessionID, threadID: id, before: nil)
                errors[id] = nil
                remember(id)
            } catch is CancellationError {
            } catch {
                if threads[id] == nil { errors[id] = "Couldn't load this thread: \(error.localizedDescription)" }
            }
            loading.remove(id)
            if stale.remove(id) != nil, self.focus?.threadID == id { load(focus, remote: remote) }
        }
    }

    private func remember(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.limit {
            let dropped = order.removeFirst()
            threads[dropped] = nil
            errors[dropped] = nil
        }
    }
}

enum CantripThreadStyle {
    /// Messages' thread line.
    static let line = Color.secondary.opacity(0.45)
    static let lineWidth: CGFloat = 1.5
    /// The bracket sits in the transcript's 16 pt side margin.
    static let gutter: CGFloat = 12
    /// Pip's bubbles in the open thread (Messages' gray).
    static let replyFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 1)
            : UIColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1)
    })
}

/// Messages' curved thread line: the top half turns from the quote's row down the margin, the
/// bottom half turns into the reply's first row.
struct CantripThreadBracket: Shape {
    enum Part { case top, bottom }
    let part: Part
    /// Space at the bottom of the row that isn't part of its content (the gap below the quote).
    var bottomInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let x = rect.minX + CantripThreadStyle.lineWidth / 2
        let y = (rect.minY + rect.maxY - bottomInset) / 2
        let radius = min(8, rect.width - 2, max(2, (rect.height - bottomInset) / 2))
        var path = Path()
        switch part {
        case .top:
            path.move(to: CGPoint(x: rect.maxX, y: y))
            path.addLine(to: CGPoint(x: x + radius, y: y))
            path.addQuadCurve(to: CGPoint(x: x, y: y + radius), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: y - radius))
            path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: y))
        }
        return path
    }
}

/// A reply's lane badge and, for a reply from another thread, the small copy of the prompt that
/// started it above the badge, joined to it by the thread line.
struct CantripThreadHeader: View {
    var lane: ExecutionLane?
    let tag: CantripRemoteThreadTag?
    let messageID: String
    let sessionID: String?
    let remote: CantripRemoteModel

    private static let gap: CGFloat = 6

    var body: some View {
        if let tag, let sessionID {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    // The line runs on to the quote, which sits on the right like the prompt it copies.
                    Rectangle()
                        .fill(CantripThreadStyle.line)
                        .frame(height: CantripThreadStyle.lineWidth)
                        .frame(minWidth: 28, maxWidth: .infinity)
                        .accessibilityHidden(true)
                    CantripThreadQuote(text: tag.prompt) {
                        CantripThreadTagStore.shared.open(
                            CantripThreadFocus(sessionID: sessionID, threadID: tag.id, prompt: tag.prompt,
                                               messageID: messageID),
                            remote: remote
                        )
                    }
                    .layoutPriority(1)
                    .accessibilityIdentifier("cantrip-thread-tag-\(messageID)")
                }
                .padding(.bottom, Self.gap)
                .background(alignment: .leading) {
                    CantripThreadBracket(part: .top, bottomInset: Self.gap)
                        .stroke(CantripThreadStyle.line, style: StrokeStyle(lineWidth: CantripThreadStyle.lineWidth, lineCap: .round))
                        .frame(width: CantripThreadStyle.gutter)
                        .offset(x: -CantripThreadStyle.gutter)
                        .accessibilityHidden(true)
                }
                Group {
                    if let lane {
                        ExecutionLaneBadge(lane: lane)
                    } else {
                        Color.clear.frame(width: 1, height: 8)
                    }
                }
                .background(alignment: .leading) {
                    CantripThreadBracket(part: .bottom)
                        .stroke(CantripThreadStyle.line, style: StrokeStyle(lineWidth: CantripThreadStyle.lineWidth, lineCap: .round))
                        .frame(width: CantripThreadStyle.gutter)
                        .offset(x: -CantripThreadStyle.gutter)
                        .accessibilityHidden(true)
                }
            }
        } else if let lane {
            ExecutionLaneBadge(lane: lane)
        }
    }
}

/// The small copy of a prompt above a reply from its thread; opens the thread.
struct CantripThreadQuote: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.footnote)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to: \(text)")
        .accessibilityHint("Opens the thread")
    }
}

/// "N Replies ›" under a prompt whose thread other messages split up; opens the thread.
struct CantripThreadRepliesButton: View {
    let count: Int
    let promptID: String
    let prompt: String
    let sessionID: String
    let remote: CantripRemoteModel

    var body: some View {
        Button {
            CantripThreadTagStore.shared.open(
                CantripThreadFocus(sessionID: sessionID, threadID: promptID, prompt: prompt), remote: remote
            )
        } label: {
            HStack(spacing: 3) {
                Text(CantripThreadText.replies(count))
                Image(systemName: "chevron.right").imageScale(.small)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            #if os(iOS)
            // A 44 pt tap target without making the row taller.
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .contentShape(Rectangle())
            .padding(.vertical, -12)
            .padding(.leading, -12)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CantripThreadText.replies(count))
        .accessibilityHint("Opens the thread")
        .accessibilityIdentifier("cantrip-thread-replies-\(promptID)")
    }
}

/// Opens the thread over the conversation: full screen over a blur on iPhone, over the blurred
/// window content on the Mac. Attach once, to the screen that shows Home's conversation.
struct CantripThreadPresenter: ViewModifier {
    let remote: CantripRemoteModel
    @ObservedObject private var store = CantripThreadTagStore.shared

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: Binding(get: { store.focus }, set: { if $0 == nil { store.close() } })) { focus in
            CantripThreadView(focus: focus, remote: remote)
                .presentationBackground(.ultraThinMaterial)
        }
        #else
        content
            .overlay {
                if let focus = store.focus {
                    CantripThreadView(focus: focus, remote: remote)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: store.focus)
        #endif
    }
}

/// The open thread: the prompt, then every message in it, whole, as Messages shows a thread.
struct CantripThreadView: View {
    let focus: CantripThreadFocus
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var store = CantripThreadTagStore.shared
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""
    @State private var scrolled = false

    private var thread: CantripRemoteThread? { store.threads[focus.threadID] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) { content }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: thread?.messages.count) { _, _ in scroll(proxy) }
            }
        }
        // New replies show up while it's open; another tab closes it.
        .onChange(of: remote.selectedSession?.historyRevision) { _, _ in store.load(focus, remote: remote) }
        .onChange(of: remote.selectedSessionID) { _, id in if id != focus.sessionID { store.close() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("cantrip-thread-view")
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("Thread").font(.headline)
                if let thread {
                    Text(CantripThreadText.replies(thread.messages.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button { store.close() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close thread")
                .accessibilityIdentifier("cantrip-thread-close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var content: some View {
        if let thread {
            bubble(thread.prompt.text).id(thread.prompt.id)
            if thread.hasEarlier { note("Earlier messages in this thread aren't shown.") }
            ForEach(thread.messages) { message in
                Group {
                    if message.role == "user" { bubble(message.text) } else { reply(message) }
                }
                .id(message.id)
            }
        } else if let error = store.errors[focus.threadID] {
            bubble(focus.prompt)
            note(error)
            Button("Try Again") { store.open(focus, remote: remote) }
                .font(.callout.weight(.semibold))
                .buttonStyle(.bordered)
        } else {
            bubble(focus.prompt)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading the thread…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// The user's side: a blue bubble on the right.
    private func bubble(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }

    /// Pip's side (and handoff cards and errors): a gray bubble on the left, named above it.
    private func reply(_ message: CantripRemoteThread.Message) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: name(of: message))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            // Whole replies, formatted as in the chat.
            ChatAssistantText(text: message.text, images: [], remote: remote)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(CantripThreadStyle.replyFill, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 48)
    }

    private func name(of message: CantripRemoteThread.Message) -> String {
        switch message.role {
        case "handoff": "Handoff"
        case "error": "Error"
        default: CantripMascotName.display(mascotName)
        }
    }

    /// Opened from a reply: scrolls just far enough to show it, so the prompt stays in view when it fits.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard !scrolled, let id = focus.messageID, thread?.messages.contains(where: { $0.id == id }) == true else { return }
        scrolled = true
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
    }
}
