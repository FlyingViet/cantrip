import Foundation
import Combine

/// Multiple independent chat sessions: each has its own backends and
/// message list, so long-running work continues in one while you use
/// another. Persisted per-session; restored on launch.
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var activeIndex = 0
    @Published private(set) var anyStreaming = false
    /// Fires when any session's run completes (for notifications).
    var onAnyRunFinished: ((ChatSession) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    var active: ChatSession {
        sessions[min(max(activeIndex, 0), sessions.count - 1)]
    }

    /// Which tabs are open (and which is active) survives restarts.
    /// Restoring from the transcript files alone reopened sessions the
    /// user had already closed — closing only archives, so the closed
    /// transcript was still among the newest files at next launch.
    private static let openIDsKey = "openSessionIDs"
    private static let activeIDKey = "activeSessionID"

    init() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return ma < mb
            }
        if let saved = UserDefaults.standard.stringArray(forKey: Self.openIDsKey) {
            // Restore exactly the tabs that were open, in tab order —
            // skipping any whose transcript has since been deleted.
            let onDisk = Set(files.map {
                $0.deletingPathExtension().lastPathComponent.uppercased()
            })
            for idString in saved {
                guard let id = UUID(uuidString: idString),
                      onDisk.contains(id.uuidString.uppercased()) else { continue }
                adopt(ChatSession(id: id))
            }
        } else {
            // First launch after this change: no saved tab list yet, so
            // fall back once to the old recent-files behavior.
            for file in files.suffix(6) {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
                    adopt(ChatSession(id: id))
                }
            }
        }
        if sessions.isEmpty { adopt(ChatSession()) }
        if let activeID = UserDefaults.standard.string(forKey: Self.activeIDKey),
           let index = sessions.firstIndex(where: {
               $0.id.uuidString.caseInsensitiveCompare(activeID) == .orderedSame
           }) {
            activeIndex = index
        } else {
            activeIndex = sessions.count - 1
        }
        persistOpenSessions()
    }

    /// Called after every tab mutation/selection, so a crash or force-quit
    /// still restores the right tabs.
    private func persistOpenSessions() {
        UserDefaults.standard.set(sessions.map(\.id.uuidString),
                                  forKey: Self.openIDsKey)
        let clamped = min(max(activeIndex, 0), sessions.count - 1)
        if sessions.indices.contains(clamped) {
            UserDefaults.standard.set(sessions[clamped].id.uuidString,
                                      forKey: Self.activeIDKey)
        }
    }

    static var chatsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/chats")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func adopt(_ session: ChatSession) {
        session.onRunFinished = { [weak self, weak session] in
            if let session { self?.onAnyRunFinished?(session) }
        }
        // Forward child changes so views observing the manager re-render.
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.anyStreaming = self?.sessions.contains { $0.isStreaming } ?? false
            }
            .store(in: &cancellables)
        sessions.append(session)
    }

    func newSession() {
        adopt(ChatSession())
        activeIndex = sessions.count - 1
        persistOpenSessions()
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
        persistOpenSessions()
    }

    func selectPrevious() {
        guard sessions.count > 1 else { return }
        activeIndex = (activeIndex - 1 + sessions.count) % sessions.count
        persistOpenSessions()
    }

    func selectNext() {
        guard sessions.count > 1 else { return }
        activeIndex = (activeIndex + 1) % sessions.count
        persistOpenSessions()
    }

    /// Closing a tab ARCHIVES it — the transcript stays on disk and the
    /// session can be reopened from the history view's session list.
    func close(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        session.cancel()
        if session.isPrivate { session.deleteTranscript() }
        sessions.remove(at: index)
        if sessions.isEmpty { adopt(ChatSession()) }
        activeIndex = min(activeIndex, sessions.count - 1)
        anyStreaming = sessions.contains { $0.isStreaming }
        persistOpenSessions()
    }

    // MARK: - Archived sessions (transcripts on disk, not open as tabs)

    struct ArchivedSession: Identifiable {
        let id: UUID
        let title: String
        let date: Date
        let messageCount: Int
    }

    func archivedSessions() -> [ArchivedSession] {
        let openIDs = Set(sessions.map(\.id))
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
        var result: [ArchivedSession] = []
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !openIDs.contains(id),
                  let data = try? Data(contentsOf: file),
                  let messages = try? JSONDecoder().decode([ChatMessage].self, from: data),
                  !messages.isEmpty else { continue }
            let title = messages.first(where: { $0.role == .user })
                .map { String($0.text.prefix(60)) } ?? "Untitled"
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            result.append(ArchivedSession(id: id, title: title,
                                          date: date, messageCount: messages.count))
        }
        return result.sorted { $0.date > $1.date }
    }

    /// Reopen an archived session as a tab (or select it if already open).
    func restore(_ id: UUID) {
        if let existing = sessions.firstIndex(where: { $0.id == id }) {
            activeIndex = existing
            persistOpenSessions()
            return
        }
        adopt(ChatSession(id: id))
        activeIndex = sessions.count - 1
        persistOpenSessions()
    }

    func deleteArchived(_ id: UUID) {
        ChatSession(id: id).deleteTranscript()
    }
}
