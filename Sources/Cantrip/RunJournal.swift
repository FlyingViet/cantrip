import Foundation

/// Append-only, crash-tolerant state for a session's runs. Each event is one
/// JSON line; replay ignores a partial tail and preserves complete records.
/// Unacknowledged events still waiting on the writer can be lost in a crash.
final class RunJournal {
    enum EventKind: String, Codable {
        case turnStarted = "turn_started"
        case messageStarted = "message_started"
        case output
        case toolActivity = "tool_activity"
        case artifact
        case queueAdded = "queue_added"
        case queueRemoved = "queue_removed"
        case queueCleared = "queue_cleared"
        case messageRouted = "message_routed"
        case steeringDelivery = "steering_delivery"
        case attempt
        case usage
        case interruption
        case approval
        case cancelled
        case result
        case conversationReset = "conversation_reset"
    }

    enum Mode: String, Codable {
        case single
        case council
        case shell
        case script
    }

    struct QueueItem: Codable, Equatable, Identifiable {
        let id: UUID
        let text: String
        let includesAmbientContext: Bool
    }

    struct FileChange: Codable, Equatable {
        let id: String
        let path: String
        let diff: String
    }

    struct Activity: Codable, Equatable {
        let id: String
        let title: String
        let toolName: String
        let state: String
        let input: String?
        let output: String?
        let fileChanges: [FileChange]
        let terminalCommand: String?
        let children: [Activity]
    }

    struct Artifact: Codable, Equatable {
        let path: String
        let kind: String
        let content: String?
    }

    struct Usage: Codable, Equatable {
        let backend: String
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
    }

    struct Event: Codable, Equatable {
        var schemaVersion = 1
        var sequence = 0
        let timestamp: Date
        let sessionID: UUID
        let runID: UUID
        let kind: EventKind

        var prompt: String?
        var mode: Mode?
        var backends: [String]?
        var backend: String?
        var workdir: String?
        var includesAmbientContext: Bool?

        var messageID: UUID?
        var role: String?
        var text: String?
        var author: String?
        var channel: String?

        var activity: Activity?
        var artifact: Artifact?
        var queueItem: QueueItem?
        var queueItemID: UUID?
        var nativeMessageID: String?
        var attemptNumber: Int?
        var reason: String?
        var usage: Usage?
        var tool: String?
        var decision: String?
        var decidedBy: String?
        var status: String?
        var durationMS: Int?
        var summaryDigest: String?

        init(
            timestamp: Date = Date(),
            sessionID: UUID,
            runID: UUID,
            kind: EventKind
        ) {
            self.timestamp = timestamp
            self.sessionID = sessionID
            self.runID = runID
            self.kind = kind
        }
    }

    struct RecoveredMessage: Equatable {
        let id: UUID
        let role: String
        var text: String
        let author: String?
        var activities: [Activity]
    }

    struct RecoveredRun: Equatable {
        let id: UUID
        let prompt: String
        let mode: Mode
        let backends: [String]
        let backend: String?
        let workdir: String
        let includesAmbientContext: Bool
        let startedAt: Date
        var messages: [RecoveredMessage]
        var attemptNumber: Int
        var lastInterruptionReason: String?

        var hasProgress: Bool {
            messages.contains {
                ($0.role == "assistant" && !$0.text.isEmpty)
                    || !$0.activities.isEmpty
            }
        }
    }

    struct RecoveryState: Equatable {
        let activeRun: RecoveredRun?
        let queued: [QueueItem]
        let lastRunID: UUID?
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/runs")
    }

    let sessionID: UUID
    let fileURL: URL

    private static let writer = DispatchQueue(label: "cantrip.run-journal", qos: .utility)
    private final class WeakJournal {
        weak var value: RunJournal?
        init(_ value: RunJournal) { self.value = value }
    }
    private static var openJournals: [WeakJournal] = []
    private var handle: FileHandle?
    private var nextSequence = 1
    private var failure: Error?
    private var lastSynchronization: UInt64 = 0
    private var needsSynchronization = false
    private let synchronize: (FileHandle) throws -> Void

    init(sessionID: UUID, directory: URL = RunJournal.defaultDirectory,
         synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() }) throws {
        self.sessionID = sessionID
        fileURL = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        self.synchronize = synchronize
        try Self.writer.sync {
            try open(directory: directory)
            Self.openJournals.removeAll { $0.value == nil }
            Self.openJournals.append(WeakJournal(self))
        }
    }

    private func open(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }

        let events = Self.loadEvents(from: fileURL)
        nextSequence = (events.map(\.sequence).max() ?? 0) + 1
        handle = try FileHandle(forWritingTo: fileURL)
        // A crashed partial line must not absorb the next complete event.
        // Discard only the incomplete tail, retaining all complete records.
        let data = try Data(contentsOf: fileURL)
        if !data.isEmpty, data.last != 0x0A {
            let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            try handle?.truncate(atOffset: UInt64(end))
            needsSynchronization = true
        }
        try handle?.seekToEnd()
    }

    deinit {
        let handle = handle
        Self.writer.async {
            do { try handle?.close() }
            catch { NSLog("run-journal: close failed (code %ld)", (error as NSError).code) }
        }
    }

    /// Synchronous barriers are for restoration/tests, not streamed events.
    func append(_ event: Event, durable: Bool = false) throws {
        try Self.writer.sync { try write(event, durable: durable) }
    }

    /// Accepts an immutable value; encoding, writes and fsync run in FIFO order.
    /// A durable completion acknowledges fsync, not merely enqueueing the event.
    func enqueue(_ event: Event, durable: Bool = false,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        Self.writer.async {
            completion(Result { try self.write(event, durable: durable) })
        }
    }

    private func write(_ event: Event, durable: Bool) throws {
        if let failure { throw failure }
        do {
            try writeRecord(event, durable: durable)
        } catch {
            // Never append a terminal success after a missing/partial event.
            failure = error
            throw error
        }
    }

    private func writeRecord(_ event: Event, durable: Bool) throws {
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        var stamped = event
        stamped.sequence = nextSequence
        var data = try Self.encoder.encode(stamped)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        needsSynchronization = true
        nextSequence += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if durable || now - lastSynchronization >= 1_000_000_000 {
            try flushOnWriter()
        }
    }

    func flush(completion: @escaping (Result<Void, Error>) -> Void) {
        Self.writer.async {
            completion(Result { try self.flushOnWriter() })
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { continuation in
            flush { continuation.resume(with: $0) }
        }
    }

    private func flushOnWriter() throws {
        if let failure { throw failure }
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        guard needsSynchronization else { return }
        do {
            try synchronize(handle)
            needsSynchronization = false
            lastSynchronization = DispatchTime.now().uptimeNanoseconds
        } catch {
            failure = error
            throw error
        }
    }

    /// Exit is the one global synchronous drain: no queued records are abandoned.
    static func drainForTermination() -> [Error] {
        writer.sync {
            openJournals.compactMap { entry in
                guard let journal = entry.value, journal.handle != nil else { return nil }
                do { try journal.flushOnWriter(); return nil }
                catch { return error }
            }
        }
    }

    func recoveryState() -> RecoveryState? {
        Self.writer.sync {
            Self.recoveryState(from: Self.loadEvents(from: fileURL))
        }
    }

    func remove() throws {
        // Privacy/deletion must wait for earlier writes; they cannot recreate
        // the file after this barrier returns.
        try Self.writer.sync {
            try handle?.close()
            handle = nil
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    static func loadEvents(from url: URL) -> [Event] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Event.self, from: Data(line))
        }
    }

    static func recoveryState(from events: [Event]) -> RecoveryState? {
        var queueOrder: [UUID] = []
        var queueItems: [UUID: QueueItem] = [:]
        for event in events {
            switch event.kind {
            case .queueAdded:
                if let item = event.queueItem {
                    if queueItems[item.id] == nil { queueOrder.append(item.id) }
                    queueItems[item.id] = item
                }
            case .queueRemoved:
                if let id = event.queueItem?.id {
                    queueItems.removeValue(forKey: id)
                    queueOrder.removeAll { $0 == id }
                }
            case .queueCleared:
                queueItems.removeAll()
                queueOrder.removeAll()
            case .turnStarted, .messageStarted:
                if let id = event.queueItemID {
                    queueItems.removeValue(forKey: id)
                    queueOrder.removeAll { $0 == id }
                }
            default:
                break
            }
        }
        let queued = queueOrder.compactMap { queueItems[$0] }

        guard let startIndex = events.lastIndex(where: { $0.kind == .turnStarted }) else {
            return queued.isEmpty
                ? nil
                : RecoveryState(activeRun: nil, queued: queued, lastRunID: events.last?.runID)
        }
        let start = events[startIndex]
        let tail = events[startIndex...].filter { $0.runID == start.runID }
        if tail.contains(where: {
            $0.kind == .result || $0.kind == .cancelled
                || $0.kind == .conversationReset
        }) {
            return queued.isEmpty
                ? nil
                : RecoveryState(activeRun: nil, queued: queued, lastRunID: start.runID)
        }

        var recovered = RecoveredRun(
            id: start.runID,
            prompt: start.prompt ?? "",
            mode: start.mode ?? .single,
            backends: start.backends ?? [],
            backend: start.backend,
            workdir: start.workdir ?? NSHomeDirectory(),
            includesAmbientContext: start.includesAmbientContext ?? true,
            startedAt: start.timestamp,
            messages: [],
            attemptNumber: 1,
            lastInterruptionReason: nil
        )
        var messageIndexes: [UUID: Int] = [:]

        for event in tail.dropFirst() {
            switch event.kind {
            case .messageStarted:
                guard let id = event.messageID, let role = event.role else { continue }
                if let index = messageIndexes[id] {
                    recovered.messages[index].text = event.text ?? ""
                } else {
                    messageIndexes[id] = recovered.messages.count
                    recovered.messages.append(RecoveredMessage(
                        id: id,
                        role: role,
                        text: event.text ?? "",
                        author: event.author,
                        activities: []
                    ))
                }
            case .output:
                guard let id = event.messageID else { continue }
                if let index = messageIndexes[id] {
                    recovered.messages[index].text += event.text ?? ""
                } else {
                    messageIndexes[id] = recovered.messages.count
                    recovered.messages.append(RecoveredMessage(
                        id: id,
                        role: event.role ?? "assistant",
                        text: event.text ?? "",
                        author: event.author,
                        activities: []
                    ))
                }
            case .toolActivity:
                guard let id = event.messageID, let activity = event.activity else { continue }
                let index: Int
                if let existing = messageIndexes[id] {
                    index = existing
                } else {
                    index = recovered.messages.count
                    messageIndexes[id] = index
                    recovered.messages.append(RecoveredMessage(
                        id: id,
                        role: "assistant",
                        text: "",
                        author: event.author,
                        activities: []
                    ))
                }
                if let activityIndex = recovered.messages[index].activities.firstIndex(
                    where: { $0.id == activity.id }
                ) {
                    recovered.messages[index].activities[activityIndex] = activity
                } else {
                    recovered.messages[index].activities.append(activity)
                }
            case .attempt:
                recovered.attemptNumber = max(
                    recovered.attemptNumber,
                    event.attemptNumber ?? recovered.attemptNumber
                )
            case .interruption:
                recovered.lastInterruptionReason = event.reason
            default:
                break
            }
        }
        return RecoveryState(activeRun: recovered, queued: queued, lastRunID: start.runID)
    }

    static func prune(
        directory: URL = RunJournal.defaultDirectory,
        olderThan age: TimeInterval = 60 * 24 * 60 * 60,
        now: Date = Date()
    ) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for url in urls where url.pathExtension == "jsonl" {
            let modified = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantFuture
            if now.timeIntervalSince(modified) > age {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

}
