import Foundation

/// Claude Code tabs get the features first built for Copilot: background watchers and parallel
/// requests keep the run open until the CLI's own wake turn, one agent can be stopped, child tabs
/// follow the shared-resource rules, idle processes are freed, and Home's protocol and the tab's
/// model reach the launch. Fixtures replay the stream-json the real CLI (2.1.312) produced.
extension SessionTabTests {
    @MainActor
    static func testClaudeBackendParity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-parity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("claude-fixture")
        try Data(claudeFixture.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let settings = AppSettings.shared
        let saved = (settings.claudePath, settings.claudeModel, settings.claudeEffort, settings.allowActions,
                     settings.claudePermissionMode, ClaudeCodeBackend.wakeGrace)
        defer {
            (settings.claudePath, settings.claudeModel, settings.claudeEffort, settings.allowActions,
             settings.claudePermissionMode, ClaudeCodeBackend.wakeGrace) = saved
        }
        settings.claudePath = script.path
        settings.claudeModel = "opus"
        settings.claudeEffort = "high"
        settings.allowActions = true
        settings.claudePermissionMode = "default"
        ClaudeCodeBackend.wakeGrace = 0.5

        try await testClaudeWatcherWake(directory)
        try await testClaudeStopsOneAgent(directory)
        try await testClaudeChildTabPolicy(directory)
        try await testClaudeLaunchAndIdleRelease(directory)
        try await testClaudeTabModels(script)
    }

    /// Claude Code's own model list (from `initialize`) drives per-tab model settings, saved
    /// apart from Copilot's, and the tab's pick reaches its Claude backend.
    @MainActor
    private static func testClaudeTabModels(_ script: URL) async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.claudeModelCatalog, settings.claudeCatalogUpdatedAt)
        defer { (settings.backend, settings.claudeModelCatalog, settings.claudeCatalogUpdatedAt) = saved }
        settings.claudeModelCatalog = []
        settings.refreshClaudeModels()
        try await waitForJournalTest { !settings.claudeRefreshInFlight }
        let catalog = settings.claudeModelCatalog
        precondition(catalog.map(\.id) == ["default", "fable[1m]", "claude-haiku-4-5-20251001"]
                        && catalog[1].reasoningEfforts == ["low", "max"] && catalog[1].contextWindow == 1_000_000
                        && catalog[2].reasoningEfforts == [] && catalog[0].contextTiers == [],
                     "The CLI's model list becomes the catalog: \(catalog) \(settings.claudeModelRefreshError ?? "")")

        settings.backend = .claudeCode
        let chat = ChatSession()
        defer { chat.cancel() }
        precondition(chat.modelSettingsUnavailableReason == nil, "Claude Code tabs can pick a model")
        precondition(chat.modelSettingsSnapshot.models.map(\.id) == catalog.map(\.id),
                     "Clients get Claude Code's models")
        do {
            try chat.updateModelSettings(.init(model: "gpt-5.6", effort: "", contextTier: ""), revision: chat.modelSettingsRevision)
            preconditionFailure("A model Claude Code doesn't list is refused")
        } catch {}
        try chat.updateModelSettings(.init(model: "fable[1m]", effort: "max", contextTier: ""),
                                     revision: chat.modelSettingsRevision)
        precondition(chat.claudeCode.modelOverride == "fable[1m]" && chat.claudeCode.effortOverride == "max",
                     "The tab's pick reaches its Claude backend")
        precondition(chat.tabMetadata.modelSettings == nil && chat.tabMetadata.claudeModelSettings?.model == "fable[1m]",
                     "Claude's pick is stored apart from Copilot's")
        let reply = chat.modelCommandReply("default")
        precondition(reply.contains("the Mac's default model") && chat.claudeCode.modelOverride == nil,
                     "/model default returns the tab to the Mac's model: \(reply)")
        settings.backend = .copilot
        precondition(chat.modelSelection == chat.defaultModelSelection, "Copilot keeps its own (unset) selection")
    }

    /// A watch-* agent outlives the root turn: the run waits (no done), the agent finishes with its
    /// summary, and the CLI's own next turn arrives as a background wake before the run ends.
    @MainActor
    private static func testClaudeWatcherWake(_ directory: URL) async throws {
        let backend = ClaudeCodeBackend(persistKey: "test-claude-watcher")
        backend.reset()
        defer { backend.cancel() }
        let turn = ClaudeTurn()
        backend.send(BackendRequest(prompt: "watcher", userMessage: "watcher", previousTurns: []),
                     workdir: directory.path, onEvent: turn.record)
        try await waitForJournalTest { turn.statuses.contains("Background watcher running") }
        precondition(!turn.finished, "The run stays open while the watcher runs: \(turn.log)")
        precondition(backend.supportsMidTurnInjection && backend.supportsParallelSubagents,
                     "A waiting run takes new messages and parallel requests")
        let running = turn.activities["toolu_agent"]?.subagent
        precondition(running?.isActive == true && running?.isBackgroundWatcher == true && running?.canCancel == true,
                     "The watcher shows as a running, stoppable watcher: \(String(describing: running))")
        try await waitForJournalTest { turn.finished }
        precondition(turn.failure == nil, "No failure: \(turn.log)")
        precondition(turn.wakes == [["toolu_agent"]], "One wake names the watcher's call: \(turn.wakes)")
        let index = turn.log.firstIndex(of: "wake") ?? 0
        precondition(turn.log.firstIndex(of: "done") ?? 0 > index && turn.log.filter({ $0 == "done" }).count == 1,
                     "Done comes once, after the wake: \(turn.log)")
        precondition(turn.text == "Started.\n\nThe build passed.", "The wake turn's reply reaches the run: \(turn.text)")
        let finished = turn.activities["toolu_agent"]
        precondition(finished?.subagent?.status == .completed
                        && finished?.subagent?.latestMessage == "Build 42 passed",
                     "The watcher finishes with its summary: \(String(describing: finished?.subagent))")
        precondition(finished?.children.map(\.id) == ["toolu_sub_bash"],
                     "The watcher's own steps nest under it: \(String(describing: finished?.children.map(\.id)))")
        precondition(turn.activities["toolu_sub_bash"] == nil, "Its steps never become root activities")
    }

    /// stop_task stops one background agent; with no wake turn the run still ends.
    @MainActor
    private static func testClaudeStopsOneAgent(_ directory: URL) async throws {
        let backend = ClaudeCodeBackend(persistKey: "test-claude-stop")
        backend.reset()
        defer { backend.cancel() }
        let turn = ClaudeTurn()
        backend.send(BackendRequest(prompt: "stoppable", userMessage: "stoppable", previousTurns: []),
                     workdir: directory.path, onEvent: turn.record)
        try await waitForJournalTest { turn.statuses.contains("Parallel request running") }
        var stopped: Result<Bool, Error>?
        backend.cancelSubagent(agentID: "toolu_agent") { stopped = $0 }
        try await waitForJournalTest { stopped != nil && turn.finished }
        guard case .success(true) = stopped else { preconditionFailure("stop_task is confirmed: \(String(describing: stopped))") }
        precondition(turn.activities["toolu_agent"]?.subagent?.status == .cancelled,
                     "The stopped agent shows as cancelled")
        precondition(turn.failure == nil && turn.log.last == "done", "The run ends cleanly: \(turn.log)")
    }

    /// A child tab's shell commands wait for (or are refused) a shared-resource turn first.
    @MainActor
    private static func testClaudeChildTabPolicy(_ directory: URL) async throws {
        let backend = ClaudeCodeBackend(persistKey: "test-claude-child")
        backend.reset()
        defer { backend.cancel() }
        backend.guardrail = .attended
        var asked: [String] = []
        backend.childPolicy = { request, decide, status in
            asked.append(request.command)
            status("Waiting for the Simulator")
            decide(.deny("Another child tab is using the Simulator."))
        }
        let turn = ClaudeTurn()
        backend.send(BackendRequest(prompt: "child", userMessage: "child", previousTurns: []),
                     workdir: directory.path, onEvent: turn.record)
        try await waitForJournalTest { turn.finished }
        precondition(asked == ["xcrun simctl boot test-device"], "The shell command reached the child policy: \(asked)")
        precondition(turn.statuses.contains("Waiting for the Simulator"), "Its waiting status shows: \(turn.statuses)")
        precondition(turn.text == "deny: Another child tab is using the Simulator.",
                     "The CLI receives the refusal and its reason: \(turn.text)")
    }

    /// The tab's model and effort and Home's protocol reach the launch (a change restarts and
    /// resumes), and an idle process is freed, then resumed by the next message.
    @MainActor
    private static func testClaudeLaunchAndIdleRelease(_ directory: URL) async throws {
        let backend = ClaudeCodeBackend(persistKey: "test-claude-launch")
        backend.reset()
        defer { backend.cancel() }
        backend.idleReleaseDelay = 0.5
        backend.modelOverride = "sonnet"
        backend.effortOverride = "low"
        backend.homeProtocol = "HOME-PROTOCOL-MARKER"
        let first = ClaudeTurn()
        backend.send(BackendRequest(prompt: "args", userMessage: "args", previousTurns: []),
                     workdir: directory.path, onEvent: first.record)
        try await waitForJournalTest { first.finished }
        let args = first.text
        precondition(args.contains("model=sonnet") && args.contains("effort=low") && args.contains("home=1")
                        && args.contains("watch-") && args.contains("resume=none"),
                     "The tab's model, effort, Home protocol and watcher guidance reach the launch: \(args)")
        precondition(first.limits.contains(1_000_000), "The context window comes from modelUsage: \(first.limits)")
        let pid = Int32(args.split(separator: " ").first { $0.hasPrefix("pid=") }?.dropFirst(4) ?? "") ?? 0
        try await waitForJournalTest { pid > 0 && kill(pid, 0) != 0 }

        backend.effortOverride = nil
        let second = ClaudeTurn()
        backend.send(BackendRequest(prompt: "args", userMessage: "args", previousTurns: []),
                     workdir: directory.path, onEvent: second.record)
        try await waitForJournalTest { second.finished }
        precondition(second.text.contains("resume=session-args") && second.text.contains("effort=high"),
                     "A freed process resumes its session with the current settings: \(second.text)")
    }

    @MainActor
    private final class ClaudeTurn {
        var text = "", failure: String?, finished = false
        var statuses: [String] = [], log: [String] = [], wakes: [[String]] = [], limits: [Int] = []
        var activities: [String: ToolActivity] = [:]

        nonisolated func record(_ event: BackendEvent) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(event) } }
        }

        private func apply(_ event: BackendEvent) {
            switch event {
            case .textDelta(let delta): text += delta
            case .status(let status): statuses.append(status); log.append("status:\(status)")
            case .activity(let activity):
                activities[activity.id] = activity
                for child in activity.children { activities.removeValue(forKey: child.id) }
            case .context(let context): if let limit = context.limit { limits.append(limit) }
            case .backgroundWake(let ids): wakes.append(ids); log.append("wake")
            case .done: finished = true; log.append("done")
            case .failure(let message): failure = message; finished = true; log.append("failure")
            default: break
            }
        }
    }

    private static let claudeFixture = #"""
    #!/usr/bin/env python3
    import json, os, sys, time

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + '\n')
        sys.stdout.flush()

    def arg(name):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else 'none'

    def agent_turn(name):
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'session-' + name, 'model': 'claude-opus-5-5'})
        emit({'type': 'assistant', 'parent_tool_use_id': None, 'message': {'id': 'm1', 'content': [
            {'type': 'tool_use', 'id': 'toolu_agent', 'name': 'Agent', 'input': {
                'description': name, 'subagent_type': 'general-purpose', 'run_in_background': True, 'prompt': 'wait'}}]}})
        emit({'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': [
            {'task_id': 'task1', 'task_type': 'local_agent', 'description': name}]})
        emit({'type': 'system', 'subtype': 'task_started', 'task_id': 'task1', 'tool_use_id': 'toolu_agent',
              'description': name, 'is_backgrounded': True, 'task_type': 'local_agent'})
        emit({'type': 'user', 'message': {'content': [
            {'type': 'tool_result', 'tool_use_id': 'toolu_agent', 'content': 'Async agent launched successfully.'}]}})
        emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Started.'}}})
        emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Started.', 'num_turns': 2})

    for line in sys.stdin:
        message = json.loads(line)
        kind = message.get('type')
        if kind == 'control_request' and message['request'].get('subtype') == 'stop_task':
            emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id']}})
            emit({'type': 'system', 'subtype': 'task_notification', 'task_id': message['request']['task_id'],
                  'tool_use_id': 'toolu_agent', 'status': 'stopped', 'summary': 'Stopped'})
            emit({'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': []})
            continue
        if kind == 'control_request' and message['request_id'] == 'cantrip-models':
            emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': 'cantrip-models',
                  'response': {'models': [
                      {'value': 'default', 'supportsEffort': True, 'supportedEffortLevels': ['low', 'high', 'max']},
                      {'value': 'fable[1m]', 'supportsEffort': True, 'supportedEffortLevels': ['low', 'max']},
                      {'value': 'claude-haiku-4-5-20251001', 'supportsThinkingOff': True}]}}})
            continue
        if kind == 'control_response':
            decision = message['response']['response'].get('hookSpecificOutput', {})
            text = decision.get('permissionDecision', 'none') + ': ' + decision.get('permissionDecisionReason', '')
            emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': text}}})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': text, 'num_turns': 1})
            continue
        if kind != 'user':
            continue
        prompt = message['message']['content']
        if prompt == 'watcher':
            agent_turn('watch-build')
            time.sleep(0.4)
            emit({'type': 'assistant', 'parent_tool_use_id': 'toolu_agent', 'message': {'id': 's1', 'content': [
                {'type': 'tool_use', 'id': 'toolu_sub_bash', 'name': 'Bash', 'input': {'command': 'sleep 1'}}]}})
            emit({'type': 'system', 'subtype': 'task_started', 'task_id': 'sub1', 'tool_use_id': 'toolu_sub_bash',
                  'owned_by_subagent': True, 'parent_task_id': 'task1', 'is_backgrounded': False})
            emit({'type': 'system', 'subtype': 'task_progress', 'task_id': 'task1', 'tool_use_id': 'toolu_agent',
                  'description': 'Waiting for build 42', 'usage': {'total_tokens': 900, 'tool_uses': 1}})
            emit({'type': 'user', 'parent_tool_use_id': 'toolu_agent', 'message': {'content': [
                {'type': 'tool_result', 'tool_use_id': 'toolu_sub_bash', 'content': 'ok'}]}})
            emit({'type': 'system', 'subtype': 'task_notification', 'task_id': 'task1', 'tool_use_id': 'toolu_agent',
                  'status': 'completed', 'summary': 'Build 42 passed'})
            emit({'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': []})
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'session-watch', 'model': 'claude-opus-5-5'})
            emit({'type': 'stream_event', 'event': {'type': 'content_block_start', 'content_block': {'type': 'text'}}})
            emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'The build passed.'}}})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'The build passed.', 'num_turns': 1})
        elif prompt == 'stoppable':
            agent_turn('side-lookup')
        elif prompt == 'child':
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'session-child', 'model': 'claude-opus-5-5'})
            emit({'type': 'control_request', 'request_id': 'hook1', 'request': {
                'subtype': 'hook_callback', 'callback_id': 'cantrip_home_policy',
                'input': {'tool_name': 'Bash', 'tool_input': {'command': 'xcrun simctl boot test-device'}}}})
        elif prompt == 'args':
            prompt_text = arg('--append-system-prompt')
            text = 'pid=%d model=%s effort=%s resume=%s home=%d %s' % (
                os.getpid(), arg('--model'), arg('--effort'), arg('--resume'),
                int('HOME-PROTOCOL-MARKER' in prompt_text), 'watch-' if 'watch-' in prompt_text else '')
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'session-args', 'model': 'claude-opus-5-5'})
            emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': text}}})
            emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': text, 'num_turns': 1,
                  'modelUsage': {'claude-opus-5-5': {'contextWindow': 1000000}, 'claude-haiku-5-5': {'contextWindow': 200000}}})
    """#
}
