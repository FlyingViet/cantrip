import Foundation

extension SessionTabTests {
    /// Copilot CLI 1.0.88+: `assistant.idle` ends the root turn, `session.idle` waits for every
    /// background agent and shell, and the runtime wakes the root itself when they finish.
    private static let queueSendNowFakeSDK = #"""
    export const RuntimeConnection = { forStdio: value => value };
    export class CopilotClient {
      async start() {}
      async forceStop() {}
      async createSession(config) {
        const emit = event => config.onEvent({
          id: `event-${Math.random()}`, timestamp: new Date().toISOString(), ...event
        });
        const tasks = new Map();
        let blocked = false, promoteCalls = 0;
        const rootIdle = () => {
          emit({ type: 'assistant.idle', data: {} });
          if (![...tasks.values()].some(task => task.status === 'running')) {
            emit({ type: 'session.idle', data: {} });
          }
        };
        const finishBackground = () => {
          tasks.get('agent-release').status = 'completed';
          tasks.get('shell-0').status = 'completed';
          emit({ type: 'subagent.completed', agentId: 'agent-release', data: {
            toolCallId: 'task-release', agentName: 'task', agentDisplayName: 'watch-testflight',
            totalTokens: 10, totalToolCalls: 1, durationMs: 5
          } });
          emit({ type: 'session.background_tasks_changed', data: {} });
          emit({ type: 'system.notification', data: { content: 'Background agent finished' } });
          emit({ type: 'assistant.turn_start', data: { turnId: 'wake' } });
          emit({ type: 'assistant.message', data: {
            messageId: 'native-wake',
            content: 'The release watcher finished, so I resumed the deployment handoff.'
          } });
          rootIdle();
        };
        const reply = (messageId, content, then) => {
          setTimeout(() => {
            emit({ type: 'assistant.message', data: {
              messageId, content: typeof content === 'function' ? content() : content
            } });
            rootIdle();
            if (then) setTimeout(then, 50);
          }, 20);
          return messageId;
        };
        return {
          rpc: { tasks: {
            list: async () => ({ tasks: [...tasks.values()] }),
            promoteCurrentToBackground: async () => { promoteCalls++; return {}; }
          } },
          async abort() { throw new Error('abort cancels every background agent'); },
          async send(options) {
            if (options.prompt.includes('Cantrip internal background completion')) {
              return reply('duplicate', 'DUPLICATE WAKE');
            }
            if (options.prompt.includes('Ship the hotfix now')) {
              if (options.mode !== 'immediate') throw new Error('Send now must steer the live turn');
              if (blocked) {
                // The runtime backgrounds the blocking command when a user message arrives.
                blocked = false;
                tasks.set('shell-0', { id: 'shell-0', type: 'shell', status: 'running' });
                emit({ type: 'tool.execution_complete', data: {
                  toolCallId: 'bash-block', success: true,
                  result: { content: '<command with shellId: 0 moved to background by the user.>' }
                } });
                emit({ type: 'session.background_tasks_changed', data: {} });
              }
              return reply('pushed', () =>
                `Shipping the hotfix while the watcher keeps running (promotions: ${promoteCalls}).`);
            }
            if (options.prompt.includes('Check the changelog too')) {
              return reply('changelog', 'I checked the changelog while the release watcher kept running.');
            }
            if (options.prompt.includes('Wrap up when the upload lands')) {
              return reply('wrap-up', 'I will wrap up once the upload lands.', finishBackground);
            }
            // The runtime is slow to accept the first prompt, as when it is launching.
            await new Promise(resolve => setTimeout(resolve, 800));
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
            tasks.set('agent-release', {
              id: 'agent-release', type: 'agent', status: 'running',
              displayName: 'watch-testflight', agentType: 'task'
            });
            emit({ type: 'subagent.started', agentId: 'agent-release', data: {
              toolCallId: 'task-release', agentName: 'task', agentDisplayName: 'watch-testflight',
              agentDescription: 'Wait for the TestFlight upload', agentType: 'task',
              executionMode: 'background'
            } });
            // The model then blocks the root on a long synchronous command.
            emit({ type: 'tool.execution_start', data: {
              toolCallId: 'bash-block', toolName: 'bash',
              arguments: { command: 'sleep 600', mode: 'sync', description: 'Wait for the upload' }
            } });
            blocked = true;
            return 'initial';
          }
        };
      }
    }
    """#

    @MainActor
    static func testQueueSendNow() async throws {
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

        let sdkURL = "data:text/javascript;base64," + Data(queueSendNowFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        let chat = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
        defer { chat.cancel() }

        precondition(chat.sendQueuedNow(id: UUID())?.contains("no longer queued") == true,
                     "An unknown queued message must be refused")

        chat.submitRemote("Start a release watcher, then wait for the upload")
        chat.submitRemote("Ship the hotfix now", mode: .queue)
        precondition(chat.isStreaming && chat.queued.count == 1)
        let early = chat.sendQueuedNow(id: chat.queued[0].id)
        precondition(early?.contains("starting or saving") == true && chat.queued.count == 1
                     && chat.isStreaming,
                     "Send now while the turn starts must not redirect or drop it: \(early ?? "sent")")
        try await waitForJournalTest {
            chat.subagent(agentID: "agent-release") != nil
                && chat.currentActivity?.toolName == "Shell"
        }
        precondition(chat.isStreaming && !chat.isWaitingOnBackgroundWatchers,
                     "A root blocked on a synchronous command is busy, not waiting on watchers")

        precondition(chat.queued.count == 1, "An explicit Queue override waits behind the busy root")
        precondition(chat.sendQueuedNow(id: chat.queued[0].id) == nil)
        try await waitForJournalTest { chat.messages.contains { $0.text.contains("Shipping the hotfix") } }
        precondition(chat.queued.isEmpty, "A message sent now leaves the queue")
        precondition(chat.messages.contains { $0.role == .user && $0.text == "Ship the hotfix now" })
        precondition(chat.messages.contains { $0.text.contains("(promotions: 1)") },
                     "Send now also asks Copilot to move the blocking step to the background")
        try await waitForJournalTest { chat.isWaitingOnBackgroundWatchers }
        precondition(chat.isStreaming, "Background work keeps the run open after the root idles")
        precondition(chat.statusText == "2 background tasks running",
                     "The watcher and the backgrounded command are reported: \(chat.statusText ?? "nil")")
        guard let watcher = chat.subagent(agentID: "agent-release"), watcher.isActive else {
            preconditionFailure("The watcher must keep running after Send now")
        }

        chat.submitRemote("Check the changelog too", mode: .queue)
        precondition(chat.queued.count == 1, "An explicit Queue override still queues while waiting")
        precondition(chat.sendQueuedNow(id: chat.queued[0].id) == nil)
        try await waitForJournalTest { chat.messages.contains { $0.text.contains("checked the changelog") } }
        try await waitForJournalTest {
            chat.deliveryStatus == "Sent now. Background work keeps running."
        }
        try await waitForJournalTest { chat.isWaitingOnBackgroundWatchers }

        chat.submitRemote("Wrap up when the upload lands", mode: .auto)
        precondition(chat.queued.isEmpty, "While only background work runs, Auto messages go straight to the root")
        try await waitForJournalTest { !chat.isStreaming }
        let assistantText = chat.messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
        precondition(assistantText.contains("wrap up once the upload lands")
                     && assistantText.contains("resumed the deployment handoff"),
                     "The runtime's own wake-up continues the same run: \(assistantText)")
        precondition(!assistantText.contains("DUPLICATE WAKE"),
                     "Cantrip must not repeat the runtime's wake-up: \(assistantText)")
        precondition(chat.messages.filter { $0.role == .user }.count == 4)
        guard let finished = chat.subagent(agentID: "agent-release") else {
            preconditionFailure("The finished watcher should remain in the transcript")
        }
        precondition(finished.status == .completed, "The watcher settles as completed: \(finished)")
    }

    /// `CANTRIP_SENDNOW_LIVE_TEST=1`: the real Copilot runtime, with a watcher running and the root
    /// blocked on a synchronous command, takes a queued message sent now.
    @MainActor
    static func testQueueSendNowLive() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.copilotModel, settings.copilotEffort,
                     settings.copilotAllowTools, settings.copilotAllowSubagents, settings.allowActions,
                     settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
                     settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.copilotModel, settings.copilotEffort,
             settings.copilotAllowTools, settings.copilotAllowSubagents, settings.allowActions,
             settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
             settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.backend = .copilot
        settings.copilotModel = ProcessInfo.processInfo.environment["CANTRIP_LIVE_MODEL"] ?? "gpt-5.6-luna"
        settings.copilotEffort = ""
        settings.copilotAllowTools = true
        settings.copilotAllowSubagents = true
        settings.allowActions = true
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        func wait(_ seconds: TimeInterval, _ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                precondition(Date() < deadline, "Live send-now timed out: \(what)")
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let started = Date()
        func log(_ text: String) { print(String(format: "%6.1fs %@", Date().timeIntervalSince(started), text)) }
        let chat = ChatSession()
        defer { chat.cancel() }
        chat.submitRemote("""
        This is a Cantrip send-now integration test. Do exactly these steps:
        1. Use the task tool to launch ONE background agent: agent_type "task", mode "background",
           name "watch-sendnow-fixture". Its prompt: run `sleep 20`, then report WATCHER_DONE_731.
        2. Then run the bash command `sleep 45` in the foreground (mode sync, not detached) and wait for it.
        3. When everything has finished, reply with ALL_DONE_731.
        """)
        try await wait(150, "the root to block on its foreground command") {
            chat.subagent(agentID: chat.messages.flatMap(\.activities)
                .flatMap(\.subagentActivities).compactMap { $0.subagent?.agentID }.first ?? "") != nil
                && chat.currentActivity?.toolName == "Shell"
        }
        log("root blocked on a foreground command with a watcher running")
        chat.submitRemote("Reply with exactly PUSHED_731 and nothing else. Do not use any tools.", mode: .queue)
        precondition(chat.queued.count == 1)
        precondition(chat.sendQueuedNow(id: chat.queued[0].id) == nil)
        try await wait(90, "the pushed reply") {
            chat.messages.contains { $0.role == .assistant && $0.text.contains("PUSHED_731") }
        }
        log("pushed message answered: \(chat.deliveryStatus ?? "")")
        precondition(chat.isStreaming, "Background work keeps the run open")
        let watcherActive = chat.messages.flatMap(\.activities).flatMap(\.subagentActivities)
            .contains { $0.subagent?.isActive == true }
        precondition(watcherActive, "The watcher must survive Send now")
        try await wait(60, "the waiting state after the root idles") { chat.isWaitingOnBackgroundWatchers }
        log("waiting: \(chat.statusText ?? "")")
        chat.submitRemote("Reply with exactly AUTO_731 and nothing else. Do not use any tools.", mode: .auto)
        precondition(chat.queued.isEmpty, "Auto messages go straight to an idle root")
        try await wait(90, "the Auto reply") {
            chat.messages.contains { $0.role == .assistant && $0.text.contains("AUTO_731") }
        }
        log("Auto message answered while background work ran")
        try await wait(240, "the run to end after background work") { !chat.isStreaming }
        log("run ended")
        let text = chat.messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
        precondition(!chat.messages.contains { $0.text.contains("Cantrip internal background completion") })
        print("Live send-now transcript tail: \(text.suffix(400))")
    }
}
