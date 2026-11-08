import Foundation

private final class MemoryFollowUpBackend: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// A tab's memory search reads the message plus the exchange before it: a vague follow-up finds
    /// the earlier topic, a new subject still finds its own, with the search index on and off.
    @MainActor
    static func testMemoryFollowUpQueries() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.memoryPath, settings.memorySearchIndex)
        defer {
            (settings.backend, settings.memoryEnabled, settings.memoryPath, settings.memorySearchIndex) = saved
            MemoryStore.removeSearchIndex()
        }
        let previousUser = "How should we schedule the kiln firings for the glaze batch?"
        let previousReply = """
        Checking the kiln notes first.

        Run the glaze batch on the cone six kiln program with a short hold. The bisque firing stays on the slow
        overnight schedule, so the kiln is free for the glaze firing by morning.

        ```card
        {"title": "Laptop boot decoy card"}
        ```
        """
        func firstSource(_ prompt: String) -> String? {
            prompt.components(separatedBy: "\n").first { $0.hasPrefix("— from ") }
        }

        for indexed in [false, true] {
            let vault = FileManager.default.temporaryDirectory
                .appendingPathComponent("cantrip-memory-follow-up-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: vault) }
            try ("# Kiln schedule\n\n## Firing\nBisque firings run on a slow overnight schedule. Glaze firings use the "
                 + "cone six program with a short hold, then cool with the lid closed.\n")
                .write(to: vault.appendingPathComponent("kiln-schedule.md"), atomically: true, encoding: .utf8)
            try "# Laptop boot\n\nTo make the laptop boot faster, remove login items and keep the disk under eighty percent full.\n"
                .write(to: vault.appendingPathComponent("laptop-boot.md"), atomically: true, encoding: .utf8)
            try "# Garden\n\nWater the raised garden beds every other morning; mulch keeps them from drying out.\n"
                .write(to: vault.appendingPathComponent("garden.md"), atomically: true, encoding: .utf8)
            settings.backend = .copilot
            settings.memoryEnabled = true
            settings.memoryPath = vault.path
            settings.memorySearchIndex = indexed
            let mode = indexed ? "index on" : "index off"

            let backend = MemoryFollowUpBackend()
            let chat = ChatSession(copilotBackend: backend)
            defer { chat.cancel() }
            chat.messages = [ChatMessage(role: .user, text: previousUser), ChatMessage(role: .assistant, text: previousReply)]
            chat.submit("Will that make it faster?")
            try await waitForJournalTest { backend.requests.count == 1 }
            let followUp = backend.requests[0].prompt
            precondition(firstSource(followUp) == "— from kiln-schedule.md:",
                         "\(mode): a vague follow-up finds the earlier topic: \(String(describing: firstSource(followUp)))")
            backend.sink?(.textDelta("Yes: a shorter hold saves about an hour."))
            backend.sink?(.done)
            try await waitForJournalTest { !chat.isStreaming }

            chat.submit("How often should the raised garden beds be watered?")
            try await waitForJournalTest { backend.requests.count == 2 }
            let newTopic = backend.requests[1].prompt
            precondition(firstSource(newTopic) == "— from garden.md:",
                         "\(mode): a new subject finds its own topic: \(String(describing: firstSource(newTopic)))")
            backend.sink?(.textDelta("Every other morning."))
            backend.sink?(.done)
            try await waitForJournalTest { !chat.isStreaming }
            MemoryStore.removeSearchIndex()
        }
        print("Memory follow-ups: the previous exchange finds a vague follow-up's topic, a new subject wins, index on and off passed")
    }
}
