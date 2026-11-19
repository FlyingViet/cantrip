import Foundation

extension SessionTabTests {
    /// Copilot's memory limits: a tab resumes its saved session only while the session's history is
    /// small enough that the resumed runtime stays near 0.5 GB, and Home chat compacts at 40%.
    static func testCopilotMemoryLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = CopilotSessionHistory.folder(environment: [:], home: root)
        precondition(folder.path == root.path + "/.copilot/session-state", "the default session folder: \(folder.path)")
        precondition(CopilotSessionHistory.folder(environment: ["COPILOT_HOME": "/tmp/ch"], home: root).path == "/tmp/ch/session-state",
                     "COPILOT_HOME moves it")
        func session(_ id: String, bytes: Int) throws {
            let dir = folder.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let log = dir.appendingPathComponent("events.jsonl")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        try session("small", bytes: 9 << 20)
        try session("large", bytes: (64 << 20) + 1)
        try session("limit", bytes: 64 << 20)
        precondition(CopilotSessionHistory.tooLargeToResume("small", in: folder) == nil, "a 9 MB history resumes")
        precondition(CopilotSessionHistory.tooLargeToResume("limit", in: folder) == nil, "64 MB exactly still resumes")
        precondition(CopilotSessionHistory.tooLargeToResume("large", in: folder) == (64 << 20) + 1, "past 64 MB starts a new session")
        precondition(CopilotSessionHistory.tooLargeToResume("missing", in: folder) == nil, "no log: resume as before")
        precondition(CopilotSessionHistory.bytes(of: "../large", in: folder) == nil && CopilotSessionHistory.bytes(of: "", in: folder) == nil,
                     "only plain session IDs are looked up")

        // Home chat compacts at 40% of the context window; tabs and task runs keep the CLI's default.
        precondition(CopilotBackend().configuration(workdir: NSTemporaryDirectory()).json["compactionThreshold"] == nil,
                     "A tab keeps the CLI's compaction")
        let homeChat = CopilotBackend()
        homeChat.tabID = ChatSession.cantripHomeID
        precondition(homeChat.configuration(workdir: NSTemporaryDirectory()).json["compactionThreshold"] as? Double == 0.4,
                     "Home chat compacts at 40%")
        let taskRun = CopilotBackend()
        taskRun.tabID = UUID()
        precondition(taskRun.configuration(workdir: NSTemporaryDirectory()).json["compactionThreshold"] == nil,
                     "A task run's hidden session keeps the CLI's compaction")
        precondition(CopilotSessionBridge.script.contains("backgroundCompactionThreshold: config.compactionThreshold"),
                     "The bridge passes Home's compaction threshold to the session")
        print("Copilot memory limit tests passed")
    }
}
