import Foundation

struct CantripHomeSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case once
        case interval
        case weekdays
    }

    var kind: Kind
    var summary: String
    var timeZone: String
    var startAt: Date?
    var intervalMinutes: Int?
    var weekdays: [Int]?
    var hour: Int?
    var minute: Int?

    func validated(now: Date = Date()) throws -> Self {
        guard summary.trimmingCharacters(in: .whitespacesAndNewlines).count <= 160,
              TimeZone(identifier: timeZone) != nil else {
            throw CantripHomeError(400, "The task schedule or time zone is invalid.")
        }
        switch kind {
        case .once:
            guard let startAt, startAt > now.addingTimeInterval(-60) else {
                throw CantripHomeError(400, "A one-time task needs a future start time.")
            }
        case .interval:
            guard let intervalMinutes, (5...525_600).contains(intervalMinutes) else {
                throw CantripHomeError(400, "Intervals must be between five minutes and one year.")
            }
        case .weekdays:
            guard let weekdays, !weekdays.isEmpty, weekdays.count <= 7,
                  Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0) }),
                  let hour, (0...23).contains(hour),
                  let minute, (0...59).contains(minute) else {
                throw CantripHomeError(400, "A weekday task needs valid weekdays and a local time.")
            }
        }
        return self
    }

    func next(after date: Date) -> Date? {
        switch kind {
        case .once:
            guard let startAt, startAt > date else { return nil }
            return startAt
        case .interval:
            guard let minutes = intervalMinutes else { return nil }
            let interval = TimeInterval(minutes * 60)
            let baseline = startAt ?? date
            if baseline > date { return baseline }
            let elapsed = date.timeIntervalSince(baseline)
            return baseline.addingTimeInterval((floor(elapsed / interval) + 1) * interval)
        case .weekdays:
            guard let weekdays, let hour, let minute,
                  let zone = TimeZone(identifier: timeZone) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                guard weekdays.contains(weekday) else { continue }
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = hour
                components.minute = minute
                components.second = 0
                if let candidate = calendar.date(from: components), candidate > date {
                    return candidate
                }
            }
            return nil
        }
    }
}

struct CantripHomeTaskRun: Codable, Equatable, Identifiable {
    var id = UUID()
    let startedAt: Date
    let finishedAt: Date
    let status: String
    let summary: String
}

struct CantripHomeTask: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case scheduled
        case running
        case succeeded
        case failed
        case paused
    }

    var id = UUID()
    var title: String
    var prompt: String
    var schedule: CantripHomeSchedule
    var enabled = true
    var createdAt = Date()
    var updatedAt = Date()
    var nextRunAt: Date?
    var lastRunAt: Date?
    var state: State = .scheduled
    var activeRunID: UUID?
    var runs: [CantripHomeTaskRun] = []
}

struct CantripHomeArtifact: Codable, Equatable, Identifiable {
    var id = UUID()
    let title: String
    let relativePath: String
    let kind: String
    let mimeType: String
    let size: Int
    let createdAt: Date
}

struct CantripHomeTaskProposal: Decodable {
    let id: UUID?
    let title: String
    let prompt: String
    let schedule: CantripHomeSchedule
}

struct CantripHomeArtifactProposal: Decodable {
    let title: String
    let path: String
    let kind: String?
}

struct CantripHomeTaskUpdate: Decodable {
    let title: String?
    let prompt: String?
    let enabled: Bool?
}

struct CantripHomeTasksSnapshot: Encodable {
    let tasks: [CantripHomeTask]
    let revision: String
    let error: String?
}

struct CantripHomeArtifactsSnapshot: Encodable {
    let artifacts: [CantripHomeArtifact]
    let revision: String
}

struct CantripHomeError: LocalizedError {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
    var errorDescription: String? { message }
}

@MainActor
final class CantripHomeStore: ObservableObject {
    static let shared = CantripHomeStore()
    static let maximumArtifactBytes = 20 * 1024 * 1024

    @Published private(set) var tasks: [CantripHomeTask] = []
    @Published private(set) var artifacts: [CantripHomeArtifact] = []
    @Published private(set) var revision = UUID()
    @Published private(set) var storageError: String?

    private weak var manager: SessionManager?
    private weak var session: ChatSession?
    private var timer: Timer?

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/home", isDirectory: true)
    }

    static var artifactDirectory: URL {
        rootDirectory.appendingPathComponent("artifacts", isDirectory: true)
    }

    private var tasksURL: URL { Self.rootDirectory.appendingPathComponent("tasks.json") }
    private var artifactsURL: URL { Self.rootDirectory.appendingPathComponent("artifacts.json") }

    private init() {
        do {
            try FileManager.default.createDirectory(
                at: Self.artifactDirectory, withIntermediateDirectories: true
            )
            tasks = try load([CantripHomeTask].self, from: tasksURL) ?? []
            artifacts = try load([CantripHomeArtifact].self, from: artifactsURL) ?? []
        } catch {
            Log.write("home: state load failed: \(error.localizedDescription)")
        }
    }

    func attach(manager: SessionManager) {
        self.manager = manager
        attach(session: manager.homeSession)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func homeAvailabilityChanged() {
        attach(session: manager?.homeSession)
        tick()
    }

    func checkNow() {
        tick()
    }

    private func attach(session: ChatSession?) {
        guard self.session !== session else { return }
        self.session?.onTurnCompleted = nil
        self.session = session
        session?.onTurnCompleted = { [weak self] runID, status, summary in
            self?.complete(runID: runID, status: status, summary: summary)
        }
        if let runID = session?.currentRunIdentifier,
           let index = tasks.firstIndex(where: { $0.activeRunID == runID }) {
            tasks[index].state = .running
        } else {
            for index in tasks.indices where tasks[index].state == .running {
                tasks[index].state = tasks[index].enabled ? .scheduled : .paused
                tasks[index].activeRunID = nil
            }
            do { try persistTasks() }
            catch { recordStorageFailure(error) }
        }
    }

    @discardableResult
    func create(_ proposal: CantripHomeTaskProposal, now: Date = Date()) throws -> CantripHomeTask {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = proposal.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !prompt.isEmpty, prompt.count <= 12_000 else {
            throw CantripHomeError(400, "Tasks need a short title and a prompt under 12,000 characters.")
        }
        let schedule = try proposal.schedule.validated(now: now)
        guard let next = schedule.next(after: now.addingTimeInterval(-1)) else {
            throw CantripHomeError(400, "The task schedule has no future run.")
        }
        if let id = proposal.id {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                throw CantripHomeError(404, "The task being edited no longer exists.")
            }
            guard tasks[index].state != .running else {
                throw CantripHomeError(409, "Wait for the task's current run to finish before changing its schedule.")
            }
            tasks[index].title = title
            tasks[index].prompt = prompt
            tasks[index].schedule = schedule
            tasks[index].nextRunAt = next
            tasks[index].enabled = true
            tasks[index].state = .scheduled
            tasks[index].updatedAt = now
            try persistTasks()
            return tasks[index]
        }
        var task = CantripHomeTask(title: title, prompt: prompt, schedule: schedule)
        task.nextRunAt = next
        tasks.insert(task, at: 0)
        try persistTasks()
        tick()
        return task
    }

    func update(id: UUID, update: CantripHomeTaskUpdate) throws -> CantripHomeTask {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw CantripHomeError(404, "Task not found.")
        }
        if let title = update.title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 120 else {
                throw CantripHomeError(400, "Task titles must be 1–120 characters.")
            }
            tasks[index].title = value
        }
        if let prompt = update.prompt {
            let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 12_000 else {
                throw CantripHomeError(400, "Task prompts must be 1–12,000 characters.")
            }
            tasks[index].prompt = value
        }
        if let enabled = update.enabled {
            tasks[index].enabled = enabled
            tasks[index].state = enabled ? .scheduled : .paused
            if enabled, tasks[index].nextRunAt == nil {
                tasks[index].nextRunAt = tasks[index].schedule.next(after: Date())
            }
        }
        tasks[index].updatedAt = Date()
        try persistTasks()
        tick()
        return tasks[index]
    }

    func delete(id: UUID) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw CantripHomeError(404, "Task not found.")
        }
        guard tasks[index].state != .running else {
            throw CantripHomeError(409, "Pause this task after its current run finishes, then delete it.")
        }
        tasks.remove(at: index)
        try persistTasks()
    }

    @discardableResult
    func register(_ proposal: CantripHomeArtifactProposal) throws -> CantripHomeArtifact {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else {
            throw CantripHomeError(400, "Artifacts need a title under 160 characters.")
        }
        let root = Self.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let raw = URL(fileURLWithPath: proposal.path)
        let candidate = (raw.path.hasPrefix("/") ? raw : root.appendingPathComponent(proposal.path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw CantripHomeError(400, "Artifacts must be saved in \(root.path).")
        }
        let values = try candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (0...Self.maximumArtifactBytes).contains(size) else {
            throw CantripHomeError(400, "The artifact is missing, unsafe, or larger than 20 MB.")
        }
        let relative = String(candidate.path.dropFirst(root.path.count + 1))
        let existingIndex = artifacts.firstIndex(where: { $0.relativePath == relative })
        let ext = candidate.pathExtension.lowercased()
        let mime = Self.mimeType(ext)
        let kind = proposal.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? Self.kind(ext)
        let artifact = CantripHomeArtifact(
            id: existingIndex.map { artifacts[$0].id } ?? UUID(),
            title: title, relativePath: relative, kind: kind, mimeType: mime,
            size: size, createdAt: values.contentModificationDate ?? Date()
        )
        if let existingIndex {
            artifacts.remove(at: existingIndex)
        }
        artifacts.insert(artifact, at: 0)
        try persistArtifacts()
        return artifact
    }

    func artifactData(id: UUID) throws -> (CantripHomeArtifact, Data) {
        guard let artifact = artifacts.first(where: { $0.id == id }) else {
            throw CantripHomeError(404, "Artifact not found.")
        }
        let root = Self.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(artifact.relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            throw CantripHomeError(404, "Artifact not found.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumArtifactBytes else {
            throw CantripHomeError(413, "Artifact is too large to download.")
        }
        return (artifact, data)
    }

    private func tick() {
        guard AppSettings.shared.cantripHomeEnabled,
              let session, !session.isStreaming, session.queued.isEmpty,
              !session.shell.isRunning,
              let index = tasks.indices
                .filter({ tasks[$0].enabled && tasks[$0].state != .running })
                .filter({ (tasks[$0].nextRunAt ?? .distantFuture) <= Date() })
                .min(by: { (tasks[$0].nextRunAt ?? .distantFuture)
                    < (tasks[$1].nextRunAt ?? .distantFuture) }) else { return }
        let taskID = tasks[index].id
        let started = Date()
        tasks[index].state = .running
        tasks[index].lastRunAt = started
        tasks[index].activeRunID = nil
        tasks[index].updatedAt = started
        do { try persistTasks() }
        catch {
            tasks[index].state = .failed
            recordStorageFailure(error)
            return
        }
        session.submitCantripHomeTask(
            id: taskID, title: tasks[index].title, prompt: tasks[index].prompt
        )
        guard let runID = session.currentRunIdentifier else {
            tasks[index].state = .failed
            tasks[index].runs.insert(.init(
                startedAt: started, finishedAt: Date(), status: "failed",
                summary: "Cantrip could not start the scheduled run."
            ), at: 0)
            do { try persistTasks() }
            catch { recordStorageFailure(error) }
            return
        }
        tasks[index].activeRunID = runID
        do { try persistTasks() }
        catch { recordStorageFailure(error) }
    }

    private func complete(runID: UUID, status: String, summary: String) {
        guard let index = tasks.firstIndex(where: { $0.activeRunID == runID }) else { return }
        let finished = Date()
        let clipped = RemoteCompletion.preview(summary)
        tasks[index].runs.insert(.init(
            startedAt: tasks[index].lastRunAt ?? finished,
            finishedAt: finished, status: status, summary: clipped
        ), at: 0)
        if tasks[index].runs.count > 20 { tasks[index].runs.removeLast(tasks[index].runs.count - 20) }
        tasks[index].activeRunID = nil
        tasks[index].state = tasks[index].enabled
            ? (status == "succeeded" ? .succeeded : .failed)
            : .paused
        if tasks[index].schedule.kind == .once {
            tasks[index].enabled = false
            tasks[index].nextRunAt = nil
        } else {
            tasks[index].nextRunAt = tasks[index].schedule.next(after: finished)
        }
        tasks[index].updatedAt = finished
        do { try persistTasks() }
        catch { recordStorageFailure(error) }
        tick()
    }

    private func persistTasks() throws {
        try save(tasks, to: tasksURL)
        storageError = nil
        revision = UUID()
    }

    private func persistArtifacts() throws {
        try save(artifacts, to: artifactsURL)
        storageError = nil
        revision = UUID()
    }

    private func recordStorageFailure(_ error: Error) {
        storageError = "Cantrip Home could not save its state. Scheduled work is paused until storage is writable."
        Log.write("home: state save failed: \(error.localizedDescription)")
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func kind(_ ext: String) -> String {
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return "image" }
        if ["mov", "mp4", "m4v"].contains(ext) { return "video" }
        if ["mp3", "m4a", "wav", "aac"].contains(ext) { return "audio" }
        return "document"
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "md": return "text/markdown"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}

extension ChatSession {
    nonisolated static let cantripHomeID =
        UUID(uuidString: "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D")!

    var isCantripHome: Bool { id == Self.cantripHomeID }

    var cantripHomeInstructions: String {
        let zone = TimeZone.current.identifier
        let savedTasks = CantripHomeStore.shared.tasks.prefix(20).map {
            "- \($0.id.uuidString): \($0.title) — \($0.schedule.summary)"
        }.joined(separator: "\n")
        return """

        (CANTRIP HOME — persistent assistant protocol
        This is the user's dedicated Cantrip Home conversation.
        If and only if the user explicitly asks to create a reminder, monitor, recurring check,
        or scheduled job, gather any missing timing/details conversationally. Once it is fully
        specified, end the reply with exactly one fenced `cantrip-task` JSON object:
        {"id":"existing task UUID or null","title":"short title",
        "prompt":"standalone task instructions","schedule":{
        "kind":"once|interval|weekdays","summary":"natural schedule label",
        "timeZone":"IANA zone","startAt":"ISO-8601 or null","intervalMinutes":null,
        "weekdays":[1-7] or null,"hour":0-23 or null,"minute":0-59 or null}}
        Sunday is 1 and Saturday is 7. Current time zone: \(zone).
        Existing tasks (use the UUID in `id` when the user asks to change one):
        \(savedTasks.isEmpty ? "- none" : savedTasks)
        Do not emit this block for an ordinary immediate request or without explicit user intent.

        Deliverables created for this conversation must be saved under
        \(CantripHomeStore.artifactDirectory.path). For every final document, image, audio,
        or video saved there, end the reply with a fenced `cantrip-artifact` JSON object:
        {"title":"display title","path":"absolute or artifact-directory-relative path",
        "kind":"document|image|audio|video"}. Do not register source-code edits or temporary files.)
        """
    }

    func processCantripHomeBlocks() {
        guard isCantripHome,
              let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        var text = messages[index].text
        var confirmations: [String] = []
        for (language, action) in [
            ("cantrip-task", { (payload: String) throws -> String in
                let proposal = try JSONDecoder().decode(
                    CantripHomeTaskProposal.self, from: Data(payload.utf8)
                )
                let task = try CantripHomeStore.shared.create(proposal)
                return "Task created: **\(task.title)** · \(task.schedule.summary)"
            }),
            ("cantrip-artifact", { (payload: String) throws -> String in
                let proposal = try JSONDecoder().decode(
                    CantripHomeArtifactProposal.self, from: Data(payload.utf8)
                )
                let artifact = try CantripHomeStore.shared.register(proposal)
                return "Saved to Artifacts: **\(artifact.title)**"
            }),
        ] {
            var processed = 0
            while let start = text.range(of: "```\(language)"),
                  let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
                let payload = text[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text.removeSubrange(start.lowerBound..<end.upperBound)
                do {
                    guard processed < 8, payload.utf8.count <= 16_384 else {
                        throw CantripHomeError(400, "Too many or oversized Home items in one reply.")
                    }
                    processed += 1
                    confirmations.append(try action(payload))
                } catch {
                    confirmations.append("Could not save \(language == "cantrip-task" ? "task" : "artifact"): \(error.localizedDescription)")
                }
            }
        }
        guard text != messages[index].text || !confirmations.isEmpty else { return }
        let suffix = confirmations.isEmpty ? "" : "\n\n" + confirmations.joined(separator: "\n\n")
        messages[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }
}
