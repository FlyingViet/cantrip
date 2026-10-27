import Foundation

extension SessionTabTests {
    private static let parallelRequestFakeSDK = #"""
    export const RuntimeConnection = { forStdio: value => value };
    export class CopilotClient {
      async start() {}
      async forceStop() {}
      async createSession(config) {
        const emit = event => config.onEvent({
          id: `event-${Math.random()}`, timestamp: new Date().toISOString(), ...event
        });
        return {
          async abort() {},
          async send(options) {
            if (options.prompt.includes('Cantrip internal background completion')) {
              const ok = options.mode === 'immediate'
                && options.prompt.includes('"agentID":"agent-side"')
                && options.prompt.includes('"kind":"parallel"');
              emit({ type: 'assistant.message', data: {
                messageId: 'side-report',
                content: ok ? '**Seattle weather:** rain tomorrow, high of 54.'
                  : 'The parallel wake-up was missing its agent.'
              } });
              emit({ type: 'session.idle', data: {} });
              return 'side-report';
            }
            if (options.prompt.includes('weather in Seattle')) {
              const briefed = options.mode === 'immediate'
                && options.prompt.includes('`side-`')
                && options.prompt.endsWith("While that runs, what's the weather in Seattle tomorrow?");
              if (!briefed) {
                emit({ type: 'assistant.message', data: {
                  messageId: 'bad-brief', content: 'The parallel request arrived without its brief.'
                } });
                return 'bad-brief';
              }
              emit({ type: 'tool.execution_start', data: {
                toolCallId: 'task-side', toolName: 'task',
                arguments: {
                  description: 'Check Seattle weather', agent_type: 'general-purpose',
                  name: 'side-weather', mode: 'background'
                }
              } });
              emit({ type: 'tool.execution_complete', data: {
                toolCallId: 'task-side', success: true,
                result: { content: "Agent started in background with agent_id: agent-side. You'll be notified when it completes." }
              } });
              setTimeout(() => {
                emit({ type: 'subagent.started', agentId: 'agent-side', data: {
                  toolCallId: 'task-side', agentName: 'general-purpose',
                  agentDisplayName: 'side-weather', agentDescription: 'Check Seattle weather',
                  agentType: 'general-purpose', executionMode: 'background'
                } });
                emit({ type: 'assistant.message', data: {
                  messageId: 'main-done', content: 'Finished refactoring the build scripts.'
                } });
                emit({ type: 'session.idle', data: {} });
                setTimeout(() => emit({ type: 'subagent.completed', agentId: 'agent-side', data: {
                  toolCallId: 'task-side', agentName: 'general-purpose',
                  agentDisplayName: 'side-weather', totalTokens: 900, totalToolCalls: 1, durationMs: 1500
                } }), 1500);
              }, 100);
              return 'parallel-accepted';
            }
            emit({ type: 'assistant.message_delta', data: {
              messageId: 'main-progress', deltaContent: 'Refactoring the build scripts...'
            } });
            return 'main-started';
          }
        };
      }
    }
    """#

    /// A busy tab gets an independent request: Auto runs it in a background agent, and the
    /// agent's answer is reported in the same thread after the main task finishes.
    @MainActor
    static func testParallelRequestRouting() async throws {
        let settings = AppSettings.shared
        let backendKind = settings.backend
        let copilotPath = settings.copilotPath
        let tools = settings.copilotAllowTools
        let subagents = settings.copilotAllowSubagents
        let memory = settings.memoryEnabled
        let screen = settings.attachScreen
        let location = settings.shareLocation
        let calendar = settings.shareCalendar
        let files = settings.fileRAGEnabled
        let router = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-parallel-router-\(UUID().uuidString)")
        defer {
            settings.backend = backendKind
            settings.copilotPath = copilotPath
            settings.copilotAllowTools = tools
            settings.copilotAllowSubagents = subagents
            settings.memoryEnabled = memory
            settings.attachScreen = screen
            settings.shareLocation = location
            settings.shareCalendar = calendar
            settings.fileRAGEnabled = files
            try? FileManager.default.removeItem(at: router)
        }
        // Stands in for the isolated router CLI: one JSONL answer, no tools.
        let decision = #"{\"intent\":\"parallel\",\"confidence\":0.95,\"evidence\":\"weather in Seattle\"}"#
        try """
        #!/bin/sh
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"router","deltaContent":"\(decision)"}}'
        """.write(to: router, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: router.path)
        settings.backend = .copilot
        settings.copilotPath = router.path
        settings.copilotAllowTools = true
        settings.copilotAllowSubagents = true
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let sdkURL = "data:text/javascript;base64,"
            + Data(parallelRequestFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        let chat = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
        defer { chat.cancel() }

        chat.submitRemote("Refactor the build scripts")
        try await waitForJournalTest {
            chat.messages.contains { $0.text.contains("Refactoring the build scripts") }
        }
        precondition(chat.isStreaming && !chat.isWaitingOnBackgroundWatchers,
                     "The main task should still be running when the second message arrives")

        let request = "While that runs, what's the weather in Seattle tomorrow?"
        chat.submitRemote(request, mode: .auto)
        try await waitForJournalTest { chat.subagent(agentID: "agent-side") != nil }
        precondition(chat.queued.isEmpty, "A parallel request must not wait in the queue")
        precondition(chat.messages.contains { $0.role == .user && $0.text == request },
                     "The transcript shows the user's own words")
        precondition(!chat.messages.contains { $0.text.contains("Cantrip note") },
                     "The agent brief must never appear in the transcript")
        guard let side = chat.subagent(agentID: "agent-side") else {
            preconditionFailure("The side agent should be visible")
        }
        precondition(side.isParallelRequest && side.keepsRunAvailable && !side.isBackgroundWatcher,
                     "side-* agents are parallel requests, not watchers: \(side)")

        try await waitForJournalTest {
            chat.messages.contains { $0.text.contains("Finished refactoring") }
                && chat.isWaitingOnBackgroundWatchers
        }
        precondition(chat.isStreaming,
                     "The run stays available while the parallel request is still running")
        precondition(chat.statusText == "Parallel request running",
                     "Status names the parallel request: \(chat.statusText ?? "nil")")

        try await waitForJournalTest { !chat.isStreaming }
        let assistantText = chat.messages
            .filter { $0.role == .assistant }
            .map(\.text)
            .joined(separator: "\n")
        precondition(assistantText.contains("Finished refactoring")
                     && assistantText.contains("Seattle weather:")
                     && !assistantText.contains("missing its agent")
                     && !assistantText.contains("without its brief"),
                     "The parallel result should be reported in the same thread: \(assistantText)")
        precondition(chat.messages.filter { $0.role == .user }.count == 2,
                     "The internal wake-up must not appear as a user message")
        guard let finished = chat.subagent(agentID: "agent-side") else {
            preconditionFailure("The finished side agent should remain in the transcript")
        }
        precondition(finished.status == .completed, "The side agent card should settle: \(finished)")
    }
}
