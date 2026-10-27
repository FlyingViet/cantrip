import Foundation

extension SessionTabTests {
    private static let queueGroupingFakeSDK = #"""
    export const RuntimeConnection = { forStdio: value => value };
    export class CopilotClient {
      async start() {}
      async forceStop() {}
      async createSession(config) {
        const emit = event => config.onEvent({
          id: `event-${Math.random()}`, timestamp: new Date().toISOString(), ...event
        });
        const reply = (id, content) => {
          emit({ type: 'assistant.message', data: { messageId: id, content } });
          emit({ type: 'session.idle', data: {} });
        };
        return {
          async abort() {},
          async send(options) {
            const prompt = options.prompt;
            const main = prompt.match(/Refactor the build scripts \((\d+)\)/);
            if (main) {
              emit({ type: 'assistant.message_delta', data: {
                messageId: 'main-progress', deltaContent: 'Refactoring the build scripts...'
              } });
              setTimeout(() => reply('main-done', 'Finished refactoring.'), Number(main[1]));
              return 'main';
            }
            if (prompt.includes('Cantrip note')) {
              const ok = prompt.includes('these 2 related messages')
                && prompt.includes('Message 1:\nMake the save button blue\n\nMessage 2:\nAlso make the save button bigger')
                && !prompt.includes('weather');
              setTimeout(() => reply('combined', ok ? 'Save button is now blue and bigger.'
                : `BAD COMBINED PROMPT: ${prompt}`), 50);
              return 'combined';
            }
            if (prompt.endsWith('Make the save button blue')) {
              setTimeout(() => reply('blue', 'Save button is now blue.'), 50);
              return 'blue';
            }
            if (prompt.endsWith('Also make the save button bigger')) {
              setTimeout(() => reply('bigger', 'Save button is now bigger.'), 50);
              return 'bigger';
            }
            if (prompt.includes("What's the weather in Seattle?")) {
              setTimeout(() => reply('weather', 'Rain tomorrow.'), 50);
              return 'weather';
            }
            setTimeout(() => reply('unexpected', `UNEXPECTED PROMPT: ${prompt}`), 50);
            return 'unexpected';
          }
        };
      }
    }
    """#

    /// Related queued messages run together in one turn; an unrelated one still runs after.
    /// Covers the decision made while the previous turn runs and the one made at drain time.
    @MainActor
    static func testQueueGrouping() async throws {
        let settings = AppSettings.shared
        let backendKind = settings.backend
        let copilotPath = settings.copilotPath
        let memory = settings.memoryEnabled
        let screen = settings.attachScreen
        let location = settings.shareLocation
        let calendar = settings.shareCalendar
        let files = settings.fileRAGEnabled
        let delay = ChatSession.queueGroupingDelay
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-queue-grouping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            settings.backend = backendKind
            settings.copilotPath = copilotPath
            settings.memoryEnabled = memory
            settings.attachScreen = screen
            settings.shareLocation = location
            settings.shareCalendar = calendar
            settings.fileRAGEnabled = files
            ChatSession.queueGroupingDelay = delay
            try? FileManager.default.removeItem(at: scratch)
        }
        // Stands in for the isolated router CLI: logs each call and groups messages 1 and 3.
        let router = scratch.appendingPathComponent("router")
        let calls = scratch.appendingPathComponent("calls.log")
        let decision = #"{\"combine\":[3],\"confidence\":0.9}"#
        try """
        #!/bin/sh
        case "$2" in
          "You group queued chat messages"*) ;;
          *) exit 9 ;;
        esac
        echo call >> '\(calls.path)'
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"router","deltaContent":"\(decision)"}}'
        """.write(to: router, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: router.path)
        settings.backend = .copilot
        settings.copilotPath = router.path
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let sdkURL = "data:text/javascript;base64,"
            + Data(queueGroupingFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        func routerCalls() -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }

        for decidedEarly in [true, false] {
            try? FileManager.default.removeItem(at: calls)
            // Early: decided while the main task runs. Late: still debouncing, so decided at drain.
            ChatSession.queueGroupingDelay = decidedEarly ? 100_000_000 : 60_000_000_000
            let chat = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
            defer { chat.cancel() }
            chat.submitRemote("Refactor the build scripts (\(decidedEarly ? 2_500 : 1_000))")
            try await waitForJournalTest {
                chat.messages.contains { $0.text.contains("Refactoring the build scripts") }
            }
            let related = ["Make the save button blue", "What's the weather in Seattle?",
                           "Also make the save button bigger"]
            for text in related { chat.submitRemote(text, mode: .queue) }
            precondition(chat.queued.map(\.text) == related, "Messages wait in the queue while the task runs")
            if decidedEarly {
                try await waitForJournalTest { routerCalls() == 1 }
                precondition(chat.isStreaming && chat.queued.count == 3,
                             "Grouping is decided while the main task still runs, without touching the queue")
            } else {
                precondition(routerCalls() == 0, "The debounced decision has not started yet")
            }

            try await waitForJournalTest {
                chat.messages.contains { $0.text.contains("blue and bigger") }
            }
            try await waitForJournalTest {
                !chat.isStreaming && chat.queued.isEmpty
                    && chat.messages.contains { $0.text == "Rain tomorrow." }
            }
            precondition(routerCalls() == 1,
                         "One decision per queue state; the lone remaining message needs none (\(routerCalls()))")

            let users = chat.messages.filter { $0.role == .user }
            precondition(users.map(\.text) == ["Refactor the build scripts (\(decidedEarly ? 2_500 : 1_000))",
                                               "Make the save button blue", "Also make the save button bigger",
                                               "What's the weather in Seattle?"],
                         "Related messages run first, each shown as the user wrote it: \(users.map(\.text))")
            precondition(users[1].runID != nil && users[1].runID == users[2].runID
                         && users[3].runID != users[1].runID,
                         "Combined messages share one run; the unrelated one gets its own")
            let assistant = chat.messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
            precondition(!assistant.contains("BAD COMBINED") && !assistant.contains("UNEXPECTED"),
                         "The agent got the right prompts: \(assistant)")
            precondition(!chat.messages.contains { $0.text.contains("Cantrip note") },
                         "The combining note never appears in the transcript")

            let journalURL = RunJournal.defaultDirectory.appendingPathComponent("\(chat.id.uuidString).jsonl")
            let events = RunJournal.loadEvents(from: journalURL)
            precondition(events.contains { $0.kind == .turnStarted && $0.queueItemIDs?.count == 1 },
                         "The combined turn claims both queue items when it starts")
            precondition(RunJournal.recoveryState(from: events)?.queued.isEmpty ?? true,
                         "Recovery never re-runs combined messages")
            precondition(chat.turnUserText(endingAt: chat.messages.firstIndex { $0.id == users[2].id }!)
                         == "Make the save button blue\n\nAlso make the save button bigger",
                         "History and memory see the combined turn's words together")
        }

        // A queued Home handoff keeps its own turn, so stopping it never stops another request.
        try? FileManager.default.removeItem(at: calls)
        ChatSession.queueGroupingDelay = 60_000_000_000
        let tab = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        manager.sessions = [tab]
        defer {
            tab.cancel()
            homeChat.cancel()
        }
        tab.submitRemote("Refactor the build scripts (1000)")
        try await waitForJournalTest {
            tab.messages.contains { $0.text.contains("Refactoring the build scripts") }
        }
        let handoffPrompt = "Also make the save button bigger"
        for text in ["Make the save button blue", "What's the weather in Seattle?", handoffPrompt] {
            tab.submitRemote(text, mode: .queue)
        }
        var card = ChatMessage(role: .assistant, text: "Handing the button size to the tab.")
        card.delegations = [CantripHomeDelegation(tabID: tab.id, tabTitle: "App", summary: "Bigger button",
                                                  prompt: handoffPrompt, createdAt: Date())]
        homeChat.messages = [card]
        CantripHomeDelegations.shared.attach(manager: manager)
        precondition(CantripHomeDelegations.shared.allHandoffs.contains { $0.isActive && $0.prompt == handoffPrompt },
                     "The handoff is waiting in the tab's queue")
        try await waitForJournalTest {
            !tab.isStreaming && tab.queued.isEmpty
                && tab.messages.contains { $0.text == "Save button is now bigger." }
        }
        let tabUsers = tab.messages.filter { $0.role == .user }
        precondition(tabUsers.map(\.text) == ["Refactor the build scripts (1000)", "Make the save button blue",
                                              "What's the weather in Seattle?", handoffPrompt]
                     && Set(tabUsers.map(\.runID)).count == 4,
                     "Handoffs are never combined; each message runs alone, in order: \(tabUsers.map(\.text))")
        precondition(routerCalls() == 1, "Only the user's own messages were considered (\(routerCalls()))")
    }
}
