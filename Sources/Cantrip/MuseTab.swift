import Foundation

extension ChatSession {
    /// The Muse tab's reserved identity: shown while Muse is on, a mirror of Muse's main chat.
    nonisolated static let museID = UUID(uuidString: "6D7A1E5C-0B3F-4C1E-9A3B-5E0C4D2F1A77")!
    var isMuseTab: Bool { id == Self.museID }
}

/// The Muse tab: a chat with the user's Muse with no model of Cantrip's behind it. Everything the
/// user types there goes to Muse's main chat (as if it started with @muse, with the same Privacy
/// Gate check), and the tab mirrors that chat, so it also shows what was sent with @muse from
/// Home or another tab, Muse's own updates, and what the user said to Muse in Meta's apps. Only
/// the user can send from it: Home, other tabs and models can't hand off to it, mention, read or
/// ask it, and no child tab, terminal, attachment or Mac context goes through it.
@MainActor
final class MuseTab {
    static let shared = MuseTab()

    weak var manager: SessionManager?
    var connector: MuseConnector { .shared }
    var directory = MuseConnector.directory
    /// How often the tab checks Muse's main chat while nothing else touched it (one cheap call).
    var syncInterval: TimeInterval = 15 * 60
    /// Opening the tab checks again at most this often.
    var viewedInterval: TimeInterval = 60
    /// The first mirror shows at most this many of Muse's latest messages.
    var firstLimit = 200
    var now: () -> Date = { Date() }

    private struct State: Codable {
        /// Which account the tab mirrors ("demo" or "live"); switching starts the mirror over.
        var account: String?
        var lastSeq = 0
        var lastUpdatedMs: Int?
        var lastSyncAt: Date?
    }

    private var state = State()
    private var syncing = false
    private var again = false
    private var loop: Task<Void, Never>?
    private var stateURL: URL { directory.appendingPathComponent("tab.json") }

    init() { load() }

    func load() {
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder.iso.decode(State.self, from: $0) } ?? State()
    }

    var session: ChatSession? { manager?.sessions.first { $0.isMuseTab } }

    /// Shows the tab while Muse is on and hides it (keeping its history) while it's off.
    func update() {
        let shown = connector.isEnabled
        manager?.setMuseTab(shown: shown)
        if shown { Task { await self.sync(force: true) } }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                if self.connector.isEnabled, self.canCheck, self.session != nil,
                   self.now().timeIntervalSince(self.state.lastSyncAt ?? .distantPast) >= self.syncInterval {
                    await self.sync()
                }
            }
        }
    }

    /// The user opened the tab (on the Mac or a paired device): check for news, at most once a minute.
    func viewed() {
        guard connector.isEnabled, canCheck, now().timeIntervalSince(state.lastSyncAt ?? .distantPast) >= viewedInterval else { return }
        Task { await self.sync() }
    }

    /// Adds Muse's main-chat messages after the last one the tab shows. Unless `force`, one
    /// `sessions` call first says whether the chat changed at all.
    func sync(force: Bool = false) async {
        guard connector.isEnabled, let session else { return }
        guard !syncing else { again = true; return }
        syncing = true
        defer {
            syncing = false
            if again {
                again = false
                Task { await self.sync(force: true) }
            }
        }
        let account = connector.settings().demo ? "demo" : "live"
        if state.account != account {
            // The demo's chat isn't the user's: the tab starts over with the account it now shows.
            if state.account != nil, !session.messages.isEmpty {
                session.messages.removeAll()
                session.persistTranscript()
                MuseLog.write("Muse tab: now showing the \(account == "demo" ? "demo account" : "user's account"); started over")
            }
            state = State(account: account)
        }
        state.lastSyncAt = now()
        save()
        do {
            var updated: Int?
            if !force {
                updated = try await connector.sessions().first { $0.id == nil }?.updatedAtMs
                if let updated, updated > 0, updated == state.lastUpdatedMs { return }
            }
            let first = state.lastSeq == 0
            var messages = try await connector.messages(in: nil, after: state.lastSeq, pages: first ? 1 : 5,
                                                        pageSize: first ? firstLimit : 100)
            // A reply still being written is mirrored when it's finished.
            if let draft = messages.firstIndex(where: { $0.role == "assistant" && !$0.final }) {
                messages = Array(messages[..<draft])
            }
            let mirrored = messages.compactMap(Self.mirrored)
            if !mirrored.isEmpty {
                session.messages.append(contentsOf: mirrored)
                session.persistTranscript()
            }
            if let last = messages.last?.seq { state.lastSeq = max(state.lastSeq, last) }
            if let updated { state.lastUpdatedMs = updated }
            save()
            if !mirrored.isEmpty { MuseLog.write("Muse tab: \(mirrored.count) new from the main chat (now after \(state.lastSeq))") }
        } catch {
            MuseLog.write("Muse tab: couldn't read the main chat (\(error.localizedDescription.prefix(160)))")
        }
    }

    /// One of Muse's main-chat messages as the tab shows it: the user's words as theirs, Muse's as
    /// Muse's (made safe like any Muse text), links and tasks it showed as a line, files by name.
    static func mirrored(_ message: MuseMessage) -> ChatMessage? {
        if message.widget {
            if let card = message.card {
                var line = card.url.map { url -> String in
                    url.hasPrefix("https://") || url.hasPrefix("http://") ? "[\(card.title)](\(url))" : card.title
                } ?? card.title
                if let detail = [card.subtitle, card.status].compactMap({ $0 }).filter({ !$0.isEmpty }).first {
                    line += " · " + detail
                }
                return ChatMessage(role: .assistant, text: MuseExchange.sanitized(line), author: MuseExchange.author)
            }
            guard !message.files.isEmpty else { return nil }
            return ChatMessage(role: .assistant, text: files(message.files), author: MuseExchange.author)
        }
        switch message.role {
        case "user":
            guard !message.text.isEmpty else { return nil }
            return ChatMessage(role: .user, text: message.text)
        case "assistant":
            var parts = [MuseExchange.sanitized(message.text)].filter { !$0.isEmpty }
            if !message.files.isEmpty { parts.append(files(message.files)) }
            guard !parts.isEmpty || !message.choices.isEmpty else { return nil }
            var mirrored = ChatMessage(role: .assistant, text: parts.joined(separator: "\n\n"), author: MuseExchange.author)
            mirrored.cards = MuseExchange.cards(for: MuseReply(text: "", files: [], cards: [], choices: message.choices,
                                                               replied: true, lastSeq: message.seq))
            return mirrored
        default:
            return nil
        }
    }

    /// Background checks wait while there's no working login (sending from a chat still checks).
    private var canCheck: Bool {
        ![.loginNeeded, .notInstalled, .off].contains(connector.status.state)
    }

    private static func files(_ files: [MuseMessage.File]) -> String {
        "Muse shared " + files.prefix(6).map { $0.label?.isEmpty == false ? $0.label! : $0.kind }.joined(separator: ", ")
            + " (open it in the Muse app)."
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder.iso.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
