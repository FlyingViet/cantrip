import Foundation

extension SessionTabTests {
    private static let backgroundWatcherFakeSDK = #"""
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
              const continued = options.mode === 'immediate'
                && options.prompt.includes('"agentID":"agent-release"');
              emit({ type: 'assistant.message', data: {
                messageId: 'watcher-continuation',
                content: continued
                  ? 'The release watcher finished, so I resumed the deployment handoff.'
                  : 'The watcher wake-up was missing its agent.'
              } });
              emit({ type: 'session.idle', data: {} });
              return 'watcher-continuation';
            }
            if (options.prompt.includes('Check the changelog too')) {
              emit({ type: 'assistant.message', data: {
                messageId: 'independent-action',
                content: 'I checked the changelog while the release watcher kept running.'
              } });
              emit({ type: 'session.idle', data: {} });
              return 'independent-action';
            }
            emit({ type: 'tool.execution_start', data: {
              toolCallId: 'task-release', toolName: 'task',
              arguments: {
                description: 'Wait for the TestFlight upload',
                agent_type: 'task', name: 'watch-testflight', mode: 'background'
              }
            } });
            emit({ type: 'tool.execution_complete', data: {
              toolCallId: 'task-release', success: true,
              result: { content: "Agent started in background with agent_id: agent-release. You'll be notified when it completes." }
            } });
            emit({ type: 'assistant.message', data: {
              messageId: 'initial-answer',
              content: 'The TestFlight watcher is running in the background.'
            } });
            emit({ type: 'session.idle', data: {} });
            setTimeout(() => {
              emit({ type: 'subagent.started', agentId: 'agent-release', data: {
                toolCallId: 'task-release', agentName: 'task',
                agentDisplayName: 'watch-testflight',
                agentDescription: 'Wait for the TestFlight upload',
                agentType: 'task', executionMode: 'background'
              } });
              setTimeout(() => {
                emit({ type: 'subagent.completed', agentId: 'agent-release', data: {
                  toolCallId: 'task-release', agentName: 'task',
                  agentDisplayName: 'watch-testflight',
                  totalTokens: 1200, totalToolCalls: 2, durationMs: 800
                } });
              }, 800);
            }, 50);
            return 'initial-answer';
          }
        };
      }
    }
    """#

    @MainActor
    static func testBackgroundWatcherContinuation() async throws {
        let settings = AppSettings.shared
        let backendKind = settings.backend
        let memory = settings.memoryEnabled
        let screen = settings.attachScreen
        let location = settings.shareLocation
        let calendar = settings.shareCalendar
        let files = settings.fileRAGEnabled
        defer {
            settings.backend = backendKind
            settings.memoryEnabled = memory
            settings.attachScreen = screen
            settings.shareLocation = location
            settings.shareCalendar = calendar
            settings.fileRAGEnabled = files
        }
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let sdkURL = "data:text/javascript;base64,"
            + Data(backgroundWatcherFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture',sessionRuntime:'fixture'}}"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        let chat = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
        defer { chat.cancel() }

        chat.submitRemote("Start a release watcher")
        try await waitForJournalTest {
            chat.messages.contains { $0.text.contains("watcher is running") }
                && chat.subagent(agentID: "agent-release") != nil
        }
        precondition(chat.isStreaming, "The root may go idle while its background watcher keeps the run available")
        precondition(chat.isWaitingOnBackgroundWatchers,
                     "The session should expose that only passive watchers remain")
        guard let queued = chat.subagent(agentID: "agent-release") else {
            preconditionFailure("The queued watcher should be visible")
        }
        precondition(queued.isBackgroundWatcher && queued.isActive,
                     "Only an explicit watch-* task agent gets detached waiter behavior: \(queued)")

        chat.submitRemote("Check the changelog too", mode: .auto)
        precondition(chat.queued.isEmpty,
                     "Watcher-only Auto messages must bypass the queued-message path")
        try await waitForJournalTest {
            chat.messages.contains { $0.text.contains("checked the changelog") }
        }
        precondition(chat.isStreaming, "Injected work must not end or block the background watcher")
        precondition(chat.queued.isEmpty,
                     "A directly accepted watcher-time message must never appear queued")
        try await waitForJournalTest { chat.isWaitingOnBackgroundWatchers }

        try await waitForJournalTest { !chat.isStreaming }
        let assistantText = chat.messages
            .filter { $0.role == .assistant }
            .map(\.text)
            .joined(separator: "\n")
        precondition(assistantText.contains("checked the changelog")
                     && assistantText.contains("resumed the deployment handoff")
                     && !assistantText.contains("missing its agent"),
                     "Watcher completion should resume the same run: \(assistantText)")
        precondition(chat.messages.filter { $0.role == .user }.count == 2,
                     "The internal watcher wake-up must not appear as a user message")
        // The watcher's result opens its own bubble in the thread that started it.
        let prompts = chat.messages.filter { $0.role == .user }
        let changelog = chat.messages.first { $0.text.contains("checked the changelog") }
        let resumed = chat.messages.first { $0.text.contains("resumed the deployment handoff") }
        precondition(prompts.allSatisfy { $0.threadID == $0.id }
                     && changelog?.threadID == prompts[1].id && changelog?.id != resumed?.id
                     && resumed?.threadID == prompts[0].id && chat.messages.last?.id == resumed?.id,
                     "A late result must not join the reply that's open: "
                        + chat.messages.map { "\($0.role.rawValue):\($0.threadID?.uuidString.prefix(4) ?? "-"):\($0.text.prefix(30))" }
                            .joined(separator: " | "))
        guard let finished = chat.subagent(agentID: "agent-release") else {
            preconditionFailure("The finished watcher should remain in the transcript")
        }
        precondition(finished.status == .completed && finished.finishedAt != nil,
                     "The watcher card should settle before continuation: \(finished)")
    }

    private static let runtimeWakeFakeSDK = #"""
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
            emit({ type: 'tool.execution_start', data: {
              toolCallId: 'bash-build', toolName: 'bash',
              arguments: { command: 'make app', description: 'Build', mode: 'async', shellId: 'build-1' }
            } });
            emit({ type: 'tool.execution_complete', data: {
              toolCallId: 'bash-build', success: true, result: { content: '<shellId: build-1 running>' }
            } });
            emit({ type: 'assistant.message', data: { messageId: 'started', content: 'The build is running.' } });
            emit({ type: 'assistant.idle', data: {} });
            setTimeout(() => {
              emit({ type: 'system.notification', data: {
                content: '<system_notification>Shell build-1 completed</system_notification>',
                kind: { type: 'shell_completed', shellId: 'build-1', exitCode: 0 }
              } });
              emit({ type: 'assistant.turn_start', data: { turnId: 'wake' } });
              emit({ type: 'assistant.message', data: { messageId: 'finished', content: 'The build finished.' } });
              emit({ type: 'session.idle', data: {} });
            }, 300);
            return 'started';
          }
        };
      }
    }
    """#

    /// The runtime itself wakes the idle root when a background shell finishes: that reply gets
    /// its own bubble in the shell's thread (Home).
    @MainActor
    static func testBackgroundRuntimeWake() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen,
                     settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.memoryEnabled, settings.attachScreen,
             settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false
        let sdkURL = "data:text/javascript;base64," + Data(runtimeWakeFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture',sessionRuntime:'fixture'}}"
        let script = CopilotSessionBridge.script.replacingOccurrences(of: CopilotRuntime.discoveryScript, with: discovery)
        let chat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CopilotBackend(bridgeScript: script),
                               makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        chat.messages = []
        defer { chat.cancel() }
        chat.submitRemote("Build the app")
        try await waitForJournalTest { !chat.isStreaming && chat.messages.contains { $0.text.contains("build finished") } }
        let prompt = chat.messages.first { $0.role == .user }
        let replies = chat.messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        precondition(replies.count == 2 && replies[0].text.contains("build is running")
                     && replies[1].text.contains("build finished") && !replies[0].text.contains("build finished")
                     && replies.allSatisfy { $0.threadID == prompt?.id && prompt?.id != nil },
                     "The shell's result opens its own bubble in its thread: "
                        + chat.messages.map { "\($0.role.rawValue):\($0.text.prefix(30))" }.joined(separator: " | "))
    }

    @MainActor
    static func testBackgroundWatcherLive() async throws {
        let settings = AppSettings.shared
        let backend = settings.backend
        let tools = settings.copilotAllowTools
        let subagents = settings.copilotAllowSubagents
        let actions = settings.allowActions
        let memory = settings.memoryEnabled
        let screen = settings.attachScreen
        let location = settings.shareLocation
        let calendar = settings.shareCalendar
        let files = settings.fileRAGEnabled
        defer {
            settings.backend = backend
            settings.copilotAllowTools = tools
            settings.copilotAllowSubagents = subagents
            settings.allowActions = actions
            settings.memoryEnabled = memory
            settings.attachScreen = screen
            settings.shareLocation = location
            settings.shareCalendar = calendar
            settings.fileRAGEnabled = files
        }
        settings.backend = .copilot
        settings.copilotAllowTools = true
        settings.copilotAllowSubagents = true
        settings.allowActions = true
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let chat = ChatSession()
        defer { chat.cancel() }
        chat.submitRemote("""
        This is a Cantrip background-watcher integration test. Launch exactly one background
        task agent named watch-cantrip-fixture. Its prompt is: run `sleep 3`, then report the
        exact marker WATCHER_DONE_493. After launching it, immediately say the watcher is
        running and finish your root turn; do not call read_agent yourself. When Cantrip wakes
        you after completion, call read_agent once. If its result contains WATCHER_DONE_493,
        end your response with the exact marker WATCHER_RESUMED_493.
        """)
        let deadline = Date().addingTimeInterval(180)
        var sawWatcher = false
        while chat.isStreaming, Date() < deadline {
            sawWatcher = sawWatcher || chat.messages.contains { message in
                message.activities.contains { activity in
                    activity.subagentActivities.contains {
                        $0.subagent?.isBackgroundWatcher == true
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let text = chat.messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
        precondition(!chat.isStreaming, "The live watcher did not return control within three minutes")
        precondition(sawWatcher, "The live agent did not launch an explicit watch-* task")
        precondition(text.contains("WATCHER_RESUMED_493"),
                     "The live watcher did not resume the root conversation: \(text)")
        print("Live watcher: root idled, task completed, and Cantrip resumed the same run")
    }
}
