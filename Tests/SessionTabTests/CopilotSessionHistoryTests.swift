import Foundation

extension SessionTabTests {
    /// A tab resumes its saved Copilot session only while the session's history is small enough
    /// that the resumed runtime stays near 0.5 GB of memory.
    static func testCopilotSessionHistory() throws {
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
        print("Copilot session history tests passed")
    }
}
