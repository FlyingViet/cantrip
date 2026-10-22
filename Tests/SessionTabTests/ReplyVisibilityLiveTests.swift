import Foundation

extension SessionTabTests {
    /// Opt-in (CANTRIP_NARRATION_LIVE_TEST=1): a real Claude model through Copilot. A note longer
    /// than a sentence or two before a tool call comes back as hidden "narration"; the user must
    /// still see it (as its summary), and a decision question must carry its own context.
    @MainActor
    static func testReplyVisibilityLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.copilotModel, settings.copilotEffort, settings.copilotAllowTools,
                     settings.allowActions, settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
                     settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.copilotModel, settings.copilotEffort, settings.copilotAllowTools,
             settings.allowActions, settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
             settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.backend = .copilot
        settings.copilotModel = environment["CANTRIP_LIVE_MODEL"] ?? "claude-sonnet-5.5"
        settings.copilotEffort = environment["CANTRIP_LIVE_EFFORT"] ?? "high"
        settings.copilotAllowTools = true
        settings.allowActions = true
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        let started = Date()
        func log(_ text: String) { print(String(format: "%6.1fs %@", Date().timeIntervalSince(started), text)) }
        func wait(_ seconds: TimeInterval, _ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                precondition(Date() < deadline, "Live reply visibility timed out: \(what)")
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let chat = ChatSession()
        defer { chat.cancel() }
        chat.submitRemote("""
        This is a Cantrip harness test. Step 1: in one response, first write a note of three \
        sentences (about 280 characters) about what you are going to check regarding this Mac's \
        uptime, then call bash with `uptime`. Step 2: ask me with ask_user whether to show the \
        load averages or stop, with the choices "Show load" and "Stop here". Step 3: after my \
        answer, reply with DONE.
        """)
        try await wait(240, "the question") { !chat.pendingInputs.isEmpty }
        let question = chat.pendingInputs[0]
        let userIndex = chat.messages.lastIndex { $0.role == .user }!
        let before = chat.messages[(userIndex + 1)...].filter { $0.role == .assistant }.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log("visible text before the question (\(before.count) chars): \(before.prefix(300))")
        log("question (\(question.detail.count) chars): \(question.detail.prefix(400))")
        try chat.respondToInput(id: question.id, answer: InputRequestAnswer(decision: .submit, text: "Stop here"))
        try await wait(240, "the end of the run") { !chat.isStreaming }
        log("final: \(chat.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text.prefix(80) ?? "")")
        precondition(before.count >= 40, "The note before the tool call must reach the user (directly or as its summary)")
        let sentences = question.detail.split(whereSeparator: { ".?!".contains($0) }).count
        precondition(sentences >= 2, "The question must carry its own context: \(question.detail)")
    }
}
