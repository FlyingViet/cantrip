import Foundation
import Combine
import os

/// Multiple independent chat sessions: each has its own backends and
/// message list, so long-running work continues in one while you use
/// another. Persisted per-session; restored on launch.
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [ChatSession] = [] {
        // Auto-fork follows every tab, however it joined the list.
        didSet { for session in sessions where session.onQueuePlansChanged == nil { wireAutoFork(session) } }
    }
    let homeSession: ChatSession
    /// Runs Home's scheduled tasks and incidents out of sight of the Home chat.
    let homeBackgroundSession: ChatSession
    /// Live hidden sessions, one per running Home background job; never tabs.
    @Published private(set) var homeRuns: [ChatSession] = []
    private var homeRunSubscriptions: [UUID: [AnyCancellable]] = [:]
    @Published var activeIndex = 0
    @Published var showingRemote = false
    @Published private(set) var anyStreaming = false
    @Published var tabActionError: String?
    /// Named groups for the tab lists, in display order (`TabSections.swift`).
    @Published var tabSections: [TabSection] = TabSectionStore.load()
    /// Child tabs: forks queued messages into their own tabs and merges them back.
    private(set) var childTabs: ChildTabCoordinator!
    /// `cantrip tab ask`: questions between tabs and their replies (TabInsight.swift).
    private(set) var tabAsks: TabAskCoordinator!
    /// Fires when any session's run completes (for notifications).
    var onAnyRunFinished: ((ChatSession) -> Void)?
    var onAnyInputNeeded: ((ChatSession, InputRequestSnapshot) -> Void)?
    var onAnyInputResolved: ((UUID) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    var managedSessions: [ChatSession] {
        sessions + [homeSession, homeBackgroundSession] + homeRuns
    }

    func managedSession(id: UUID) -> ChatSession? {
        if id == homeSession.id { return homeSession }
        if id == homeBackgroundSession.id { return homeBackgroundSession }
        if let run = homeRuns.first(where: { $0.id == id }) { return run }
        return sessions.first(where: { $0.id == id })
    }

    /// Live hidden-run IDs, readable off the main actor (history encoding runs on a queue).
    private nonisolated static let liveHomeRunIDs = OSAllocatedUnfairLock(initialState: Set<UUID>())

    /// Home's conversations and its live background runs are never regular tabs or archived history.
    nonisolated static func isCantripHomeReserved(_ id: UUID) -> Bool {
        id == ChatSession.cantripHomeID || id == ChatSession.cantripHomeBackgroundID
            || liveHomeRunIDs.withLock { $0.contains(id) }
    }

    static func isCantripHomeReserved(_ session: ChatSession) -> Bool {
        isCantripHomeReserved(session.id) || session.isCantripHomeRun
    }

    /// Starts tracking a hidden background run so pushes, input replies and Stop reach it.
    func adoptCantripHomeRun(_ session: ChatSession) {
        guard session.isCantripHomeRun, !homeRuns.contains(where: { $0 === session }) else { return }
        homeRunSubscriptions[session.id] = configure(session)
        homeRuns.append(session)
        Self.liveHomeRunIDs.withLock { _ = $0.insert(session.id) }
    }

    func releaseCantripHomeRun(_ session: ChatSession) {
        homeRunSubscriptions[session.id] = nil
        homeRuns.removeAll { $0 === session }
        Self.liveHomeRunIDs.withLock { _ = $0.remove(session.id) }
        anyStreaming = managedSessions.contains { $0.isStreaming }
    }

    var active: ChatSession {
        sessions[min(max(activeIndex, 0), sessions.count - 1)]
    }

    /// Which tabs are open (and which is active) survives restarts.
    /// Restoring from the transcript files alone reopened sessions the
    /// user had already closed — closing only archives, so the closed
    /// transcript was still among the newest files at next launch.
    private static let openIDsKey = "openSessionIDs"
    private static let activeIDKey = "activeSessionID"

    init(homeSession: ChatSession? = nil, homeBackgroundSession: ChatSession? = nil) {
        self.homeSession = homeSession ?? ChatSession(id: ChatSession.cantripHomeID)
        self.homeBackgroundSession = homeBackgroundSession
            ?? ChatSession(id: ChatSession.cantripHomeBackgroundID)
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
                      !Self.isCantripHomeReserved(id),
                      onDisk.contains(id.uuidString.uppercased()) else { continue }
                adopt(ChatSession(id: id))
            }
        } else {
            // First launch after this change: no saved tab list yet, so
            // fall back once to the old recent-files behavior.
            for file in files.suffix(6) {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                   !Self.isCantripHomeReserved(id) {
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
        if !sessions.contains(where: \.isLocalPrivate) {
            adopt(ChatSession(id: ChatSession.privateLocalID))
        }
        configure(self.homeSession)
        configure(self.homeBackgroundSession)
        self.homeSession.moveAutomatedCantripHomeTurns(to: self.homeBackgroundSession)
        sessions = Self.keepingChildrenWithParents(sessions)
        persistOpenSessions()
        childTabs = ChildTabCoordinator(manager: self)
        childTabs.attach()
        tabAsks = TabAskCoordinator(manager: self)
        tabAsks.attach()
        ChatSession.tabContextProvider = { [weak self] session in self?.tabContextNotes(for: session) }
    }

    /// What `session`'s model hears about other tabs with its next message: its child tabs'
    /// status and replies to its `tab ask` questions. Short lines; it reads more on demand.
    func tabContextNotes(for session: ChatSession) -> String? {
        let parts = [
            session.isCantripHome ? nil : childTabs.contextNotes(for: session),
            tabAsks.notes(for: session.id),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Child tabs

    private func wireAutoFork(_ session: ChatSession) {
        session.onQueuePlansChanged = { [weak self] session in self?.childTabs?.considerAutoFork(session) }
    }

    /// The parent of an open child tab that is still running or waiting on its merge.
    func parentID(ofChild id: UUID) -> UUID? {
        ChildTabStore.shared.isActiveChild(id) ? ChildTabStore.shared.record(id)?.parentID : nil
    }

    /// Opens a new child tab right after its parent and its other children, in the parent's
    /// section. The parent stays selected.
    func placeChild(_ child: ChatSession, after parent: ChatSession) {
        let selectedID = showingRemote ? nil : active.id
        configure(child)
        try? child.saveSection(parent.tabMetadata.sectionID)
        let parentIndex = sessions.firstIndex { $0.id == parent.id } ?? (sessions.count - 1)
        let lastSibling = sessions.indices.last { parentID(ofChild: sessions[$0].id) == parent.id }
        sessions.insert(child, at: max(parentIndex, lastSibling ?? parentIndex) + 1)
        if let selectedID, let index = sessions.firstIndex(where: { $0.id == selectedID }) { activeIndex = index }
        anyStreaming = managedSessions.contains { $0.isStreaming }
        persistOpenSessions()
    }

    /// `list` with each open child right after its parent (children keep their order).
    static func keepingChildrenWithParents(_ list: [ChatSession]) -> [ChatSession] {
        let store = ChildTabStore.shared
        let openIDs = Set(list.map(\.id))
        func parent(_ session: ChatSession) -> UUID? {
            guard store.isActiveChild(session.id), let id = store.record(session.id)?.parentID,
                  openIDs.contains(id) else { return nil }
            return id
        }
        let children = list.filter { parent($0) != nil }
        guard !children.isEmpty else { return list }
        var result: [ChatSession] = []
        for session in list where parent(session) == nil {
            result.append(session)
            result += children.filter { parent($0) == session.id }
        }
        return result
    }


    /// After launch, each tab Cantrip quit with work in continues it: the interrupted run, then
    /// its queue. Tabs start a few seconds apart so their Copilot runtimes don't launch at once.
    func continueRestoredWork(after initialDelay: TimeInterval = 3, spacing: TimeInterval = 2) {
        let tabs = ([homeSession] + sessions).filter(\.hasRestoredWork)
        guard !tabs.isEmpty else { return }
        Log.write("launch: continuing work restored in \(tabs.count) tab(s)")
        for (index, tab) in tabs.enumerated() {
            tab.continueAfterLaunch(after: initialDelay + spacing * Double(index))
        }
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

    @discardableResult
    private func configure(_ session: ChatSession) -> [AnyCancellable] {
        session.onRunFinished = { [weak self, weak session] in
            if let session { self?.onAnyRunFinished?(session) }
        }
        session.onInputNeeded = { [weak self, weak session] input in
            if let session { self?.onAnyInputNeeded?(session, input) }
        }
        session.onInputResolved = { [weak self] id in self?.onAnyInputResolved?(id) }
        wireAutoFork(session)
        // Forward child changes so views observing the manager re-render.
        let subscriptions = [
            session.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() },
            session.$isStreaming
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.anyStreaming = self?.managedSessions.contains { $0.isStreaming } ?? false
                },
        ]
        if !session.isCantripHomeRun { cancellables.formUnion(subscriptions) }
        return subscriptions
    }

    private func adopt(_ session: ChatSession) {
        configure(session)
        sessions.append(session)
    }

    @discardableResult
    func newSession() -> ChatSession {
        let session = ChatSession()
        adopt(session)
        activeIndex = sessions.count - 1
        showingRemote = false
        persistOpenSessions()
        return session
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
        showingRemote = false
        persistOpenSessions()
    }

    func select(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            tabActionError = SessionTabError.unavailable.localizedDescription
            return
        }
        select(index)
    }

    func selectRemote() {
        showingRemote = true
    }

    func moveSession(_ id: UUID, relativeTo targetID: UUID, after: Bool) throws {
        guard let source = sessions.firstIndex(where: { $0.id == id }),
              sessions.contains(where: { $0.id == targetID }) else {
            throw SessionTabError.unavailable
        }
        guard id != targetID else { return }
        if parentID(ofChild: id) != nil {
            throw ChildTabError.notAllowed("A child tab stays under its parent tab until its work merges.")
        }
        // Beside a child tab means beside its parent's group: before the parent, or after its last child.
        var targetID = targetID
        var after = after
        if let parent = parentID(ofChild: targetID) {
            guard parent != id else { return }
            if after, let last = sessions.last(where: { $0.id == parent || parentID(ofChild: $0.id) == parent }) {
                targetID = last.id
            } else {
                targetID = parent
                after = false
            }
        }
        let selectedID = active.id
        var reordered = sessions
        let moved = reordered.remove(at: source)
        guard let target = reordered.firstIndex(where: { $0.id == targetID }) else {
            throw SessionTabError.unavailable
        }
        reordered.insert(moved, at: target + (after ? 1 : 0))
        // Dropping a tab beside another files it in that tab's section.
        if let target = sessions.first(where: { $0.id == targetID }), !Self.isCantripHomeReserved(moved),
           moved.tabMetadata.sectionID != sectionID(of: target) {
            try moved.saveSection(sectionID(of: target))
        }
        // A parent's children move with it.
        reordered = Self.keepingChildrenWithParents(reordered)
        for child in reordered where parentID(ofChild: child.id) == moved.id {
            try? child.saveSection(moved.tabMetadata.sectionID)
        }
        guard reordered.map(\.id) != sessions.map(\.id) else { return }
        sessions = reordered
        activeIndex = reordered.firstIndex(where: { $0.id == selectedID })!
        persistOpenSessions()
    }

    func selectPrevious() {
        if showingRemote {
            showingRemote = false
            activeIndex = sessions.count - 1
        } else if activeIndex == 0 {
            showingRemote = true
        } else {
            activeIndex -= 1
        }
        persistOpenSessions()
    }

    func selectNext() {
        if showingRemote {
            showingRemote = false
            activeIndex = 0
        } else if activeIndex == sessions.count - 1 {
            showingRemote = true
        } else {
            activeIndex += 1
        }
        persistOpenSessions()
    }

    func closeSelectedTab() {
        if showingRemote {
            showingRemote = false
        } else {
            close(activeIndex)
        }
    }

    /// Closing a tab ARCHIVES it — the transcript stays on disk and the
    /// session can be reopened from the history view's session list.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            tabActionError = SessionTabError.unavailable.localizedDescription
            return
        }
        close(index)
    }

    func close(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        do {
            if session.isLocalPrivate {
                throw SessionModelSettingsError(409, "Private Local is a permanent tab and cannot be closed.")
            }
            try session.tabMetadata.requireUnlocked()
        }
        catch {
            tabActionError = error.localizedDescription
            return
        }
        let selectedID = active.id
        // A question this tab just answered is collected while the tab can still be read.
        tabAsks?.refresh()
        session.cancel()
        if session.isPrivate { session.deleteTranscript() }
        sessions.remove(at: index)
        childTabs?.sessionClosed(session.id)
        if sessions.isEmpty { adopt(ChatSession()) }
        activeIndex = sessions.firstIndex(where: { $0.id == selectedID }) ?? min(index, sessions.count - 1)
        anyStreaming = managedSessions.contains { $0.isStreaming }
        persistOpenSessions()
    }

    // MARK: - Archived sessions (transcripts on disk, not open as tabs)

    struct ArchivedSession: Identifiable {
        let id: UUID
        let title: String
        let date: Date
        let messageCount: Int
    }

    /// What a transcript file says about itself, kept until the file changes. The toolbar's
    /// "Reopen session" menu lists archived sessions on every redraw.
    private struct TranscriptSummary {
        let modified: Date
        let size: Int
        /// nil when the file isn't a readable transcript.
        let messageCount: Int?
        let firstUserText: String?
    }
    private var transcriptSummaries: [UUID: TranscriptSummary] = [:]

    func archivedSessions() -> [ArchivedSession] {
        let openIDs = Set(sessions.map(\.id))
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.chatsDir, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "json" }
        var result: [ArchivedSession] = []
        var present = Set<UUID>()
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !Self.isCantripHomeReserved(id) else { continue }
            present.insert(id)
            guard !openIDs.contains(id) else { continue }
            let values = try? file.resourceValues(forKeys: keys)
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? -1
            let summary: TranscriptSummary
            if let cached = transcriptSummaries[id], cached.modified == date, cached.size == size {
                summary = cached
            } else {
                let messages = (try? Data(contentsOf: file))
                    .flatMap { try? JSONDecoder().decode([ChatMessage].self, from: $0) }
                summary = TranscriptSummary(
                    modified: date, size: size, messageCount: messages?.count,
                    firstUserText: messages?.first(where: { $0.role == .user }).map { String($0.text.prefix(60)) })
                transcriptSummaries[id] = summary
            }
            guard let messageCount = summary.messageCount else { continue }
            let metadata = SessionTabMetadata.load(id: id)
            guard messageCount > 0 || metadata.customTitle != nil || metadata.isLocked else { continue }
            let title = metadata.customTitle ?? summary.firstUserText ?? "Untitled"
            result.append(ArchivedSession(id: id, title: title,
                                          date: date, messageCount: messageCount))
        }
        transcriptSummaries = transcriptSummaries.filter { present.contains($0.key) }
        return result.sorted { $0.date > $1.date }
    }

    /// Reopen an archived session as a tab (or select it if already open).
    func restore(_ id: UUID) {
        guard !Self.isCantripHomeReserved(id) else {
            tabActionError = "Cantrip Home is available only through its focused Remote mode."
            return
        }
        if let existing = sessions.firstIndex(where: { $0.id == id }) {
            activeIndex = existing
            persistOpenSessions()
            return
        }
        let session = ChatSession(id: id)
        adopt(session)
        activeIndex = sessions.count - 1
        persistOpenSessions()
        childTabs?.sessionOpened(session)
    }

    func deleteArchived(_ id: UUID) {
        guard id != ChatSession.privateLocalID, !Self.isCantripHomeReserved(id),
              !sessions.contains(where: { $0.id == id }),
              !SessionTabMetadata.load(id: id).isLocked else {
            tabActionError = "Open tabs and locked tabs cannot be deleted from history."
            return
        }
        ChatSession(id: id).deleteTranscript()
    }
}
