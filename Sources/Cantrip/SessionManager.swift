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
        for file in files.suffix(6) {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
                adopt(ChatSession(id: id))
            }
        }
        if sessions.isEmpty { adopt(ChatSession()) }
        activeIndex = sessions.count - 1
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
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
    }

    func selectPrevious() {
        guard sessions.count > 1 else { return }
        activeIndex = (activeIndex - 1 + sessions.count) % sessions.count
    }

    func selectNext() {
        guard sessions.count > 1 else { return }
        activeIndex = (activeIndex + 1) % sessions.count
    }

    func close(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        session.cancel()
        session.deleteTranscript()
        sessions.remove(at: index)
        if sessions.isEmpty { adopt(ChatSession()) }
        activeIndex = min(activeIndex, sessions.count - 1)
        anyStreaming = sessions.contains { $0.isStreaming }
    }
}
