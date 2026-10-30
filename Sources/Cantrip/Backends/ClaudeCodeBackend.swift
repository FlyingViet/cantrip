import Foundation

/// Runs queries through the Claude Code CLI in headless mode:
///   claude -p "<prompt>" --output-format stream-json --verbose
/// Follow-ups resume the same session via --resume <session_id>.
final class ClaudeCodeBackend: Backend, CantripHomeGuardedBackend {
    private var process: Process?
    /// The tab this backend serves: its shell commands see `CANTRIP_TAB_ID` (`cantrip tab ask`).
    var tabID: UUID?
    /// Persisted so conversations resume across app restarts.
    private let persistKey: String
    private var sessionID: String? {
        didSet { UserDefaults.standard.set(sessionID, forKey: persistKey) }
    }
    private var activities: [String: ToolActivity] = [:]
    /// child tool_use id → parent Task activity id (subagent steps).
    private var childIndex: [String: String] = [:]
    /// Claude repeats a message's full usage on every content-block event.
    private var countedSubagentMessages: Set<String> = []
    /// Root model calls already reported as context, by message ID.
    private var countedRootMessages: Set<String> = []
    /// Whether any text has streamed this run (for block separation).
    private var hasEmittedText = false
    /// Same, for thinking blocks (separate consecutive reasoning blocks).
    private var hasEmittedThinking = false
    /// Claude's own text for a turn the plan's usage limit stopped (an assistant message marked
    /// `rate_limit` or `billing_error`), so the turn ends as a failure Cantrip can fall back on.
    private var usageLimitText: String?
    /// Claude's own code for a usage limit this turn: the assistant message's `error`, or a
    /// `rate_limit_event` whose status is `rejected` (with its reset time).
    private var usageLimitReport: UsageLimitReport?
    /// A turn is running and owes exactly one terminal `result` event.
    private var turnInFlight = false
    /// Set by a graceful interrupt while a turn is in flight: the aborted
    /// turn's trailing events (stale tool_results, its error `result`)
    /// arrive on the SAME live process and would otherwise leak into the
    /// next turn's event sink — swallow everything up to and including
    /// that terminal `result`.
    private var suppressUntilResult = false
    /// Per-instance model override (council members run models different
    /// from the session's setting). Nil = use the configured model.
    var modelOverride: String?
    /// Read-only instance (council advisors): plan mode — read/analyze
    /// tools only, no edits, no commands, regardless of global autonomy.
    var readOnly = false
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "claude-code-backend")
    /// Persistent-process plumbing: stdin stays open so new user messages
    /// (including mid-turn injections) stream into the running session.
    private var stdinHandle: FileHandle?
    private var processWorkdir = ""
    private var currentOnEvent: ((BackendEvent) -> Void)?
    private var inputRequests: [String: BackendInputRequest] = [:]
    private var askpass: RemoteAskpass?
    private let guardrailLock = NSLock()
    private var storedGuardrail: CantripHomeGuardrail?
    private var storedGuardrailLabel = "Cantrip Home"
    /// Actions the user approved while this process ran (queue-owned).
    private var approvedScopes: Set<String> = []
    private var storedChildPolicy: CopilotBackend.ChildPolicy?
    /// Root background work the CLI reports as live (`background_tasks_changed`), by task ID.
    private var liveBackgroundTasks: [String: (type: String, name: String)] = [:]
    /// Task ID <-> the tool call that started it (agent stops, finished-work wakes).
    private var taskCalls: [String: String] = [:]
    private var callTasks: [String: String] = [:]
    /// The root turn ended while background work runs: the run stays open until it reports,
    /// when the CLI starts a turn of its own to deliver the result.
    private var waitingOnBackground = false
    /// Background work that finished since the root's last turn started, for the wake's bubble.
    private var finishedBackground: [String] = []
    /// One of them was a `side-*` agent (the wake replies to a parallel request).
    private var finishedParallel = false
    /// Ends a wait whose wake turn never came (the result reached a turn that was still running).
    private var wakeFallback: DispatchWorkItem?
    private var stopRequests: [String: (Result<Bool, Error>) -> Void] = [:]
    private var rootModel: String?
    private var contextLimit: Int?
    private var idleRelease: DispatchWorkItem?
    /// What the running process was launched with; a change starts a new one (resuming the session).
    private var processSignature = ""
    /// Per-tab effort (tab model settings); nil = the configured effort.
    var effortOverride: String?
    /// Attended Home's static protocol, kept in the system prompt instead of every message.
    var homeProtocol: String?
    /// Seconds an idle process is kept before it's stopped to free memory; nil = the setting.
    var idleReleaseDelay: TimeInterval?
    static var wakeGrace: TimeInterval = 5

    /// A child tab's shared-resource rules, consulted before Cantrip's policy for shell commands.
    var childPolicy: CopilotBackend.ChildPolicy? {
        get { guardrailLock.withLock { storedChildPolicy } }
        set { guardrailLock.withLock { storedChildPolicy = newValue } }
    }

    /// Cantrip Home sessions never bypass permissions: every tool call is checked by the host.
    var guardrail: CantripHomeGuardrail? {
        get { guardrailLock.withLock { storedGuardrail } }
        set { guardrailLock.withLock { storedGuardrail = newValue } }
    }

    var guardrailLabel: String {
        get { guardrailLock.withLock { storedGuardrailLabel } }
        set { guardrailLock.withLock { storedGuardrailLabel = newValue } }
    }

    init(persistKey: String = "claudeSessionID") {
        self.persistKey = persistKey
        sessionID = UserDefaults.standard.string(forKey: persistKey)
    }

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentOnEvent = onEvent
            self.hasEmittedText = false
            self.hasEmittedThinking = false
            self.usageLimitText = nil
            self.usageLimitReport = nil
            self.idleRelease?.cancel()
            self.endBackgroundWait()
            if self.process?.isRunning != true || self.processWorkdir != workdir
                || self.processSignature != self.launchSignature(workdir: workdir) {
                self.cancelInputs()
                self.askpass?.stop()
                self.process?.terminate()
                self.resetBackgroundTracking()
                self.startProcess(workdir: workdir)
            }
            self.askpass?.beginTurn()
            self.countedRootMessages.removeAll()
            let prompt = self.promptWithMissedTurns(request)
            self.writeUserMessage(prompt)
            onEvent(.context(BackendContextUsage(limit: self.contextLimit, messageCharacters: prompt.count)))
        }
    }

    /// How many of the tab's completed turns this Claude session has seen (saved with its session).
    private var seenTurnsKey: String { persistKey + ".seenTurns" }
    /// The count to save once this turn completes.
    private var pendingSeenTurns: Int?

    /// Claude Code keeps its own session, so earlier turns usually need no replay. They do when this
    /// is a new session (a tab that ran on Copilot until now, or a lost session) or when other
    /// backends answered turns since this session last ran: those turns go in front of the message,
    /// selected like Copilot's continuity (summary, related and most recent turns).
    private func promptWithMissedTurns(_ request: BackendRequest) -> String {
        let turns = request.previousTurns
        let seen = UserDefaults.standard.object(forKey: seenTurnsKey) as? Int
        let missed: ArraySlice<ConversationTurn>
        if sessionID == nil {
            missed = turns[...]
        } else if let seen {
            missed = seen <= turns.count ? turns.dropFirst(seen) : []
        } else {
            // A session from before Cantrip counted turns: it may not have seen any of them.
            missed = turns[...]
        }
        pendingSeenTurns = turns.count + 1
        guard !missed.isEmpty else { return request.prompt }
        Log.write("claude: carrying \(missed.count) earlier turn(s) into the session")
        return ConversationContextBuilder.composePrompt(
            currentPrompt: request.prompt, query: request.userMessage, turns: Array(missed)
        )
    }

    private func commitSeenTurns() {
        guard let pendingSeenTurns else { return }
        UserDefaults.standard.set(pendingSeenTurns, forKey: seenTurnsKey)
        self.pendingSeenTurns = nil
    }

    private var model: String { (modelOverride ?? settings.claudeModel).trimmingCharacters(in: .whitespaces) }
    private var effort: String { (effortOverride ?? settings.claudeEffort).trimmingCharacters(in: .whitespaces) }

    private func launchSignature(workdir: String) -> String {
        [workdir, String(settings.allowActions), settings.claudePermissionMode, model, effort, guardrail?.rawValue ?? "",
         String(readOnly), homeProtocol ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Claude-style mid-turn injection: append a user message into the
    /// RUNNING turn's context without interrupting it. Returns false when
    /// no live process exists (caller should queue instead). While the run waits on
    /// background agents, a message starts a root turn alongside them.
    var supportsMidTurnInjection: Bool {
        process?.isRunning == true && stdinHandle != nil && (turnInFlight || waitingOnBackground)
    }

    var canSteerTurns: Bool { true }

    /// The root can hand a forwarded request to a background agent (`side-*`) mid-turn.
    var supportsParallelSubagents: Bool { !readOnly && supportsMidTurnInjection }

    func injectMidTurn(_ text: String) -> Bool {
        guard process?.isRunning == true, stdinHandle != nil else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            // A message into a run waiting on background work starts the next root turn.
            if self.waitingOnBackground { self.endBackgroundWait() }
            self.writeUserMessage(text)
        }
        Log.write("inject: mid-turn message (\(text.count) chars)")
        return true
    }

    /// Stops one background agent through the CLI's `stop_task` (its result then reports it stopped).
    func cancelSubagent(agentID: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let taskID = self.callTasks[agentID] else {
                return completion(.failure(SubagentCancelError.finished))
            }
            guard self.stdinHandle != nil, self.process?.isRunning == true else {
                return completion(.failure(SubagentCancelError.sessionUnavailable))
            }
            let id = "cantrip-stop-\(UUID().uuidString)"
            self.stopRequests[id] = completion
            self.writeControlRequest(["subtype": "stop_task", "task_id": taskID], id: id)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.stopRequests.removeValue(forKey: id)?(.failure(SubagentCancelError.timedOut))
            }
        }
    }

    /// Graceful in-band interrupt (same mechanism as Esc in Claude Code's
    /// own UI): a control_request aborts the current turn, the CLI answers
    /// with a control_response + an error_during_execution result, and the
    /// process stays alive with the session intact for the next message.
    /// Verified against CLI v2.1.221; unknown stdin lines are ignored by
    /// the CLI, so this is safe to send even on older versions.
    func interruptTurn() -> Bool {
        // Background agents would wake the root again after the stop: end everything instead.
        guard process?.isRunning == true, stdinHandle != nil, liveBackgroundTasks.isEmpty,
              !waitingOnBackground else { return false }
        let message: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ]
        queue.async { [weak self] in
            guard let self, let handle = self.stdinHandle,
                  var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            // Only suppress if a turn is actually running — otherwise the
            // next turn's result would be swallowed and the UI would hang.
            // (Verified: an idle interrupt yields only a control_response,
            // never a spurious result.)
            if self.turnInFlight {
                self.cancelInputs()
                self.suppressUntilResult = true
                // The aborted turn no longer counts as in-flight — a
                // redirect's writeUserMessage may re-arm this for the
                // NEXT turn before the aborted result arrives, and that
                // state must survive the suppression branch.
                self.turnInFlight = false
                self.activities.removeAll()
                self.childIndex.removeAll()
                self.countedSubagentMessages.removeAll()
            }
            data.append(0x0A)
            handle.write(data)
        }
        Log.write("interrupt: sent control_request (graceful)")
        return true
    }

    private func writeUserMessage(_ text: String) {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        guard let handle = stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            currentOnEvent?(.failure("Claude process has no input channel."))
            return
        }
        data.append(0x0A)
        handle.write(data)
        turnInFlight = true
    }

    func cancel() {
        cancelInputs()
        askpass?.stop()
        askpass = nil
        guard let p = process else { return }
        process = nil
        stdinHandle = nil
        // Detach the event sink so this process's termination handler
        // can't emit into a stream started after the cancel (e.g. an
        // auto-resume) — SIGTERM can take a moment to land.
        currentOnEvent = nil
        activities.removeAll()
        childIndex.removeAll()
        countedSubagentMessages.removeAll()
        turnInFlight = false
        suppressUntilResult = false
        idleRelease?.cancel()
        resetBackgroundTracking()
        p.terminate()
        // Escalate to SIGKILL if it ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning {
                Log.write("cancel: escalating to SIGKILL (pid \(p.processIdentifier))")
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    func reset() {
        cancel()
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: seenTurnsKey)
        pendingSeenTurns = nil
        activities.removeAll()
    }

    // MARK: - Background agents and shells

    private func resetBackgroundTracking() {
        wakeFallback?.cancel()
        wakeFallback = nil
        waitingOnBackground = false
        liveBackgroundTasks.removeAll()
        taskCalls.removeAll()
        callTasks.removeAll()
        finishedBackground.removeAll()
        finishedParallel = false
        let stops = stopRequests.values
        stopRequests.removeAll()
        for stop in stops { stop(.failure(SubagentCancelError.sessionUnavailable)) }
    }

    private func endBackgroundWait() {
        wakeFallback?.cancel()
        wakeFallback = nil
        waitingOnBackground = false
    }

    /// The run's waiting line, counted like Copilot's (watch-*, side-*, anything else).
    private var backgroundWaitStatus: String {
        let names = liveBackgroundTasks.values.map { $0.type == "local_agent" ? $0.name.lowercased() : "" }
        let watchers = names.filter { $0.hasPrefix("watch-") }.count
        let parallel = names.filter { $0.hasPrefix("side-") }.count
        return BackgroundWaitStatus.waiting(watchers: watchers, parallel: parallel,
                                            other: names.count - watchers - parallel)
    }

    /// The root turn ended. Background work still running (or a result still on its way) keeps
    /// the run open: the CLI starts a turn of its own when that work reports.
    private func finishRootTurn(_ onEvent: (BackendEvent) -> Void) {
        if !liveBackgroundTasks.isEmpty {
            waitingOnBackground = true
            onEvent(.status(backgroundWaitStatus))
        } else if !finishedBackground.isEmpty {
            waitingOnBackground = true
            scheduleWakeFallback()
        } else {
            onEvent(.done)
            scheduleIdleRelease()
        }
    }

    /// Background work finished while the root waits for it; its wake turn should follow.
    private func scheduleWakeFallback() {
        wakeFallback?.cancel()
        let owner = process
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.process === owner, self.waitingOnBackground, !self.turnInFlight,
                  self.liveBackgroundTasks.isEmpty else { return }
            Log.write("claude: background work finished without a wake turn; ending the run")
            self.waitingOnBackground = false
            self.finishedBackground.removeAll()
            self.currentOnEvent?(.done)
            self.scheduleIdleRelease()
        }
        wakeFallback = work
        queue.asyncAfter(deadline: .now() + Self.wakeGrace, execute: work)
    }

    /// Stops a process left idle so its memory is returned; the next message resumes the
    /// session (`--resume`) in a new one. Uses Copilot's "Free an idle tab's memory" setting.
    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        let delay = idleReleaseDelay ?? TimeInterval(settings.copilotIdleReleaseMinutes * 60)
        guard delay > 0 else { return }
        let owner = process
        let work = DispatchWorkItem { [weak self] in
            guard let self, let owner, self.process === owner, !self.turnInFlight, !self.waitingOnBackground,
                  self.liveBackgroundTasks.isEmpty, self.inputRequests.isEmpty else { return }
            Log.write("claude: freeing idle process pid \(owner.processIdentifier); the next message resumes it")
            self.process = nil
            self.stdinHandle = nil
            self.currentOnEvent = nil
            self.askpass?.stop()
            self.askpass = nil
            self.activities.removeAll()
            self.childIndex.removeAll()
            self.resetBackgroundTracking()
            owner.terminate()
        }
        idleRelease = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// `system` events about background tasks (agents and shells the root started).
    private func handleTaskEvent(_ subtype: String, _ obj: [String: Any], _ onEvent: (BackendEvent) -> Void) {
        let taskID = obj["task_id"] as? String
        let callID = obj["tool_use_id"] as? String
        switch subtype {
        case "task_started":
            // Foreground commands and agents report as tasks too; only detached work is tracked.
            guard let taskID, let callID, obj["is_backgrounded"] as? Bool == true, obj["parent_task_id"] == nil,
                  obj["owned_by_subagent"] as? Bool != true else { return }
            taskCalls[taskID] = callID
            callTasks[callID] = taskID
            if var activity = activities[callID], activity.subagent != nil, activity.subagent?.canCancel == false {
                activity.subagent?.canCancel = !readOnly
                activities[callID] = activity
                onEvent(.activity(activity))
            }
        case "background_tasks_changed":
            let tasks = obj["tasks"] as? [[String: Any]] ?? []
            var live: [String: (type: String, name: String)] = [:]
            for task in tasks {
                guard let id = task["task_id"] as? String else { continue }
                live[id] = (task["task_type"] as? String ?? "", task["description"] as? String ?? "")
            }
            liveBackgroundTasks = live
            guard waitingOnBackground, !turnInFlight else { return }
            if live.isEmpty { scheduleWakeFallback() } else { onEvent(.status(backgroundWaitStatus)) }
        case "task_progress":
            guard let callID, var activity = activities[callID], activity.subagent != nil else { return }
            let usage = obj["usage"] as? [String: Any]
            if let description = obj["description"] as? String { activity.subagent?.intent = description }
            if let tokens = usage?["total_tokens"] as? Int, tokens > activity.subagent?.tokens ?? 0 {
                activity.subagent?.tokens = tokens
            }
            if let calls = usage?["tool_uses"] as? Int { activity.subagent?.toolCalls = calls }
            if activity != activities[callID] {
                activities[callID] = activity
                onEvent(.activity(activity))
            }
        case "task_notification":
            guard let taskID, taskCalls[taskID] != nil || callID.map({ callTasks[$0] != nil }) == true else { return }
            let call = callID ?? taskCalls[taskID] ?? taskID
            taskCalls.removeValue(forKey: taskID)
            callTasks.removeValue(forKey: call)
            finishedBackground.append(call)
            guard var activity = activities.removeValue(forKey: call) else { return }
            if activity.subagent?.isParallelRequest == true { finishedParallel = true }
            for (child, parent) in childIndex where parent == call { childIndex.removeValue(forKey: child) }
            let status = obj["status"] as? String ?? "completed"
            let state: ToolActivityState = status == "completed" ? .succeeded
                : status == "failed" ? .failed : .cancelled
            activity = activity.finishing(as: state)
            activity.subagent?.canCancel = false
            if activity.subagent?.toolCalls == nil { activity.subagent?.toolCalls = activity.children.count }
            if let summary = SubagentInfo.clipped(obj["summary"] as? String ?? "") {
                activity.subagent?.latestMessage = summary
            }
            if state == .failed { activity.subagent?.error = obj["summary"] as? String }
            onEvent(.activity(activity))
        default:
            break
        }
    }

    // MARK: - Internals

    static let policyHookID = "cantrip_home_policy"

    /// Copilot's watcher and parallel-request conventions, in Claude Code's terms.
    static let subagentGuidance = """
    For passive waiting after you have already started an external build, TestFlight upload, \
    download, or similar long-running job, launch one background agent (Agent tool, \
    run_in_background: true) whose description starts with `watch-`. Its only job is to wait \
    with a bounded timeout, verify the terminal result, and report it; it must not edit files \
    or start the job again. Continue all independent work immediately, and when your immediate \
    work is done, briefly tell the user the watcher is continuing and end your turn. Cantrip \
    keeps the run open and you are woken with the watcher's result, so continue from the exact \
    point you paused. Never use the `watch-` prefix for implementation, research, or other \
    delegated work.

    When Cantrip forwards a user message it judged independent of your current task, it asks \
    you to hand it to a background agent whose description starts with `side-`. Launch it, then \
    keep working on your current task; reply to that request in the chat when its result \
    arrives. Use the `side-` prefix only for those forwarded requests.
    """

    private func writeControlRequest(_ request: [String: Any], id: String = "cantrip-\(UUID().uuidString)") {
        do {
            guard let handle = stdinHandle else { throw CocoaError(.fileWriteUnknown) }
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "control_request", "request_id": id, "request": request,
            ])
            data.append(10)
            try handle.write(contentsOf: data)
        } catch {
            Log.write("claude: could not send \(request["subtype"] ?? "a control request"): \(error.localizedDescription)")
            stopRequests.removeValue(forKey: id)?(.failure(SubagentCancelError.sessionUnavailable))
        }
    }

    /// What the user chose for Claude in Cantrip ("Act on my behalf" or Permissions). Home always
    /// launches Claude in default mode so every tool reaches Cantrip; the choice is applied here.
    private var homeApproval: CantripHomeApproval { .chosen(for: .claudeCode, settings: settings) }

    /// Cantrip's PreToolUse hook. Hooks run before Claude Code's own permission rules, so a
    /// user's `Bash(*)` allow rule can't bypass the Home policy. Tools the policy doesn't
    /// cover get no decision and follow the normal flow (including AskUserQuestion).
    private func answerPolicyHook(id: String, request: [String: Any]) {
        let undecided: [String: Any] = ["continue": true]
        guard request["callback_id"] as? String == Self.policyHookID, let mode = guardrail, !readOnly,
              let input = request["input"] as? [String: Any],
              let tool = input["tool_name"] as? String else {
            sendControlResponse(id: id, response: undecided)
            return
        }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let action = CantripHomeActionRequest(claudeTool: tool, input: toolInput)
        func decide(_ permission: String, _ reason: String? = nil) {
            var output: [String: Any] = ["hookEventName": "PreToolUse", "permissionDecision": permission]
            if let reason { output["permissionDecisionReason"] = reason }
            sendControlResponse(id: id, response: ["hookSpecificOutput": output])
        }
        guard [.shell, .write, .mcp].contains(action.kind) else {
            sendControlResponse(id: id, response: undecided)
            return
        }
        if action.kind == .shell, let childPolicy {
            // A child tab's shared-resource turn (Simulator, builds, deploys) comes first.
            let owner = process
            childPolicy(action, { [weak self] verdict in
                self?.queue.async {
                    guard let self, self.process === owner else { return }
                    switch verdict {
                    case .proceed: self.decideWithPolicy(id: id, tool: tool, action: action, mode: mode)
                    case .deny(let reason): decide("deny", reason)
                    }
                }
            }, { [weak self] status in
                self?.queue.async {
                    guard let self, self.process === owner else { return }
                    self.currentOnEvent?(.status(status))
                }
            })
            return
        }
        decideWithPolicy(id: id, tool: tool, action: action, mode: mode)
    }

    private func decideWithPolicy(id: String, tool: String, action: CantripHomeActionRequest,
                                  mode: CantripHomeGuardrail) {
        let undecided: [String: Any] = ["continue": true]
        func decide(_ permission: String, _ reason: String? = nil) {
            var output: [String: Any] = ["hookEventName": "PreToolUse", "permissionDecision": permission]
            if let reason { output["permissionDecisionReason"] = reason }
            sendControlResponse(id: id, response: ["hookSpecificOutput": output])
        }
        let decision = CantripHomeActionPolicy.evaluate(
            action, mode: mode, approval: homeApproval, environment: .current(workdir: processWorkdir)
        )
        switch decision.verdict {
        case .allow:
            // Claude's own deny rules still apply; the permission request then reaches Cantrip.
            sendControlResponse(id: id, response: undecided)
        case .deny:
            Log.write("home policy: denied \(tool): \(action.command.prefix(160))")
            decide("deny", decision.reason)
        case .ask:
            if approvedScopes.contains(decision.scope) { return decide("allow") }
            let owner = process
            let pending = BackendInputRequest(
                kind: .approval, source: "Cantrip Home",
                title: "\(guardrailLabel) wants to \(decision.action)", detail: decision.detail
            ) { [weak self] answer in
                self?.queue.async {
                    guard let self, self.process === owner,
                          self.inputRequests.removeValue(forKey: id) != nil else { return }
                    if answer.decision == .approve {
                        self.approvedScopes.insert(decision.scope)
                        decide("allow")
                    } else {
                        decide("deny", answer.decision == .deny
                            ? "The user declined to \(decision.action). Don't retry it another way; say in your reply that it was skipped."
                            : "No approval arrived to \(decision.action), so it was skipped. Say so in your reply.")
                    }
                }
            }
            Log.write("home policy: asking the user before \(decision.action)")
            inputRequests[id] = pending
            currentOnEvent?(.inputRequired(pending))
        }
    }

    /// Answers one tool call with the Home policy; false falls through to a normal approval.
    /// Asked actions become an approval request that answers the control request later.
    private func answerWithGuardrail(
        tool: String, input: [String: Any], mode: CantripHomeGuardrail, id: String
    ) -> Bool {
        let request = CantripHomeActionRequest(claudeTool: tool, input: input)
        let approval = homeApproval
        let decision = CantripHomeActionPolicy.evaluate(
            request, mode: mode, approval: approval, environment: .current(workdir: processWorkdir)
        )
        switch decision.verdict {
        case .deny:
            Log.write("home policy: denied \(tool): \(request.command.prefix(160))")
            sendControlResponse(id: id, response: ["behavior": "deny", "message": decision.reason])
            return true
        case .allow:
            guard approval.runsWithoutAsking(request) else { return false }
            if decision.automatic {
                Log.write("home policy: approved \(decision.action) automatically (Act on my behalf or Allow everything)")
            }
            sendControlResponse(id: id, response: ["behavior": "allow", "updatedInput": input])
            return true
        case .ask:
            if approvedScopes.contains(decision.scope) {
                sendControlResponse(id: id, response: ["behavior": "allow", "updatedInput": input])
                return true
            }
            let owner = process
            let pending = BackendInputRequest(
                kind: .approval, source: "Cantrip Home",
                title: "\(guardrailLabel) wants to \(decision.action)", detail: decision.detail
            ) { [weak self] answer in
                self?.queue.async {
                    guard let self, self.process === owner,
                          self.inputRequests.removeValue(forKey: id) != nil else { return }
                    if answer.decision == .approve {
                        self.approvedScopes.insert(decision.scope)
                        self.sendControlResponse(id: id, response: ["behavior": "allow", "updatedInput": input])
                    } else {
                        self.sendControlResponse(id: id, response: ["behavior": "deny", "message": answer.decision == .deny
                            ? "The user declined to \(decision.action). Don't retry it another way; say in your reply that it was skipped."
                            : "No approval arrived to \(decision.action), so it was skipped. Say so in your reply."])
                    }
                }
            }
            Log.write("home policy: asking the user before \(decision.action)")
            inputRequests[id] = pending
            currentOnEvent?(.inputRequired(pending))
            return true
        }
    }

    private func sendControlResponse(id: String, response: [String: Any]) {
        do {
            guard let handle = stdinHandle else { throw CocoaError(.fileWriteUnknown) }
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]
            ])
            data.append(10)
            try handle.write(contentsOf: data)
        } catch {
            currentOnEvent?(.failure("Could not deliver your response to Claude. It was not retried."))
        }
    }

    private func askQuestion(id: String, input: [String: Any], questions: [[String: Any]], answers: [String: String]) {
        guard let question = questions.first, let text = question["question"] as? String else {
            sendControlResponse(id: id, response: ["behavior": "allow",
                "updatedInput": input.merging(["answers": answers]) { _, new in new }])
            return
        }
        let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        let owner = process
        let pending = BackendInputRequest(kind: .question, source: "Claude Code", title: "Your answer is needed",
            detail: text, choices: options, allowsFreeform: true) { [weak self] answer in
            self?.queue.async {
                guard let self, self.process === owner, self.inputRequests.removeValue(forKey: id) != nil else { return }
                guard answer.decision == .submit, let value = answer.text else {
                    self.sendControlResponse(id: id, response: ["behavior": "deny", "message": "User cancelled the question."])
                    return
                }
                var answers = answers
                answers[text] = value
                self.askQuestion(id: id, input: input, questions: Array(questions.dropFirst()), answers: answers)
            }
        }
        inputRequests[id] = pending
        currentOnEvent?(.inputRequired(pending))
    }

    private func cancelInputs() {
        let requests = Array(inputRequests.values)
        inputRequests.removeAll()
        for request in requests { request.cancel() }
    }

    private func resolveClaudePath() -> String? {
        ToolLocator.shared.claude(configured: settings.claudePath)
    }

    private func startProcess(workdir: String) {
        guard let claudePath = resolveClaudePath() else {
            Log.write("claude CLI not found")
            currentOnEvent?(.failure("Couldn't find the `claude` CLI. Set its path in Settings."))
            return
        }
        Log.write("launching \(claudePath) (streaming input), workdir=\(workdir)")

        var args = ["-p", "--input-format", "stream-json",
                    "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages"]
        if !readOnly { args += ["--permission-prompt-tool", "stdio"] }
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        if readOnly {
            args += ["--permission-mode", "plan"] // read-only tool set
        } else if guardrail != nil {
            // Cantrip's PreToolUse hook (registered at launch) runs before Claude's own allow
            // rules; default mode sends anything else undecided over stdio.
            args += ["--permission-mode", "default"]
        } else if settings.allowActions {
            args += ["--permission-mode", "bypassPermissions"]
        } else if settings.claudePermissionMode != "default" {
            args += ["--permission-mode", settings.claudePermissionMode]
        }
        if let sessionID { args += ["--resume", sessionID] }
        // Claude Code has no per-session files folder, so images go to Cantrip's output folder.
        var guidance = RemoteGeneratedImages.agentGuidance(sessionFilesFolder: false) + "\n\n" + ReplyVisibility.guidance
        if !readOnly { guidance += "\n\n" + Self.subagentGuidance }
        if let homeProtocol { guidance += "\n\n" + homeProtocol }
        args += ["--append-system-prompt", guidance]
        // MCP servers from enabled+approved plugins (see Plugins.swift), and the Copilot CLI's own
        // local servers, so a Claude tab reaches the same tools as a Copilot one.
        let mcpConfigs = [PluginManager.claudeMCPConfigPath(), ClaudeSharedMCP.configPath()].compactMap { $0 }
        if !mcpConfigs.isEmpty {
            args += ["--mcp-config"] + mcpConfigs
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolPath.value(inherited: env["PATH"])
        if let tabID { env[TabInsight.tabIDVariable] = tabID.uuidString }
        if !readOnly {
            do {
                let broker = try RemoteAskpass(process: p) { [weak self] request in
                    self?.queue.async {
                        guard let self, self.process === p, self.turnInFlight else { request.cancel(); return }
                        self.currentOnEvent?(.inputRequired(request))
                    }
                }
                env.merge(broker.environment) { _, new in new }
                askpass = broker
            } catch {
                currentOnEvent?(.failure("Could not prepare secure Claude input. The process was not started."))
                return
            }
        }
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        // Critical: claude -p waits for stdin EOF when spawned from a GUI app.
        // Keep stdin open: this is the channel for follow-ups & injections.
        let stdinPipe = Pipe()
        p.standardInput = stdinPipe

        // Drain stderr continuously so the pipe never fills and blocks the process.
        var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            buffer.append(data)
            // Process complete lines — on the backend's serial queue, so
            // handleLine's state (turn flags, activities, event sink)
            // is synchronized with send/inject/interrupt.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                self?.queue.async { self?.handleLine(lineData) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Log.write("claude exited, status=\(proc.terminationStatus), reason=\(proc.terminationReason.rawValue)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // A cancelled/superseded process (its slot was reassigned or
            // cleared) must not emit events or clobber the current run's
            // handles — SIGKILL escalation can land seconds after cancel().
            guard let self, self.process === proc else { return }
            let onEvent = self.currentOnEvent
            if proc.terminationStatus != 0 {
                errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationReason == .uncaughtSignal {
                    onEvent?(.done) // cancelled by user
                } else {
                    onEvent?(.failure(errText.isEmpty ? "claude exited with status \(proc.terminationStatus)" : errText))
                }
            } else {
                onEvent?(.done)
            }
            self.process = nil
            self.stdinHandle = nil
        }

        do {
            try p.run()
            process = p
            stdinHandle = stdinPipe.fileHandleForWriting
            processWorkdir = workdir
            processSignature = launchSignature(workdir: workdir)
            if guardrail != nil, !readOnly {
                writeControlRequest([
                    "subtype": "initialize",
                    "hooks": ["PreToolUse": [["matcher": "", "hookCallbackIds": [Self.policyHookID]]]],
                ])
            }
            turnInFlight = false
            suppressUntilResult = false
            Log.write("claude started, pid=\(p.processIdentifier)")
        } catch {
            Log.write("launch failed: \(error.localizedDescription)")
            currentOnEvent?(.failure("Failed to launch claude: \(error.localizedDescription)"))
        }
    }

    private func handleLine(_ data: Data) {
        guard let onEvent = currentOnEvent else { return }
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            Log.write("unparseable line (\(data.count) bytes): \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            return
        }
        if type != "stream_event" { Log.write("line type=\(type)") }

        if let sid = obj["session_id"] as? String { sessionID = sid }

        // Aborted-turn suppression (see interruptTurn): drop everything
        // from the interrupted turn, up to and including its terminal
        // `result`, so it can't leak into the next turn's event sink.
        // (The interrupted turn's cost/usage is knowingly not recorded.)
        // Deliberately does NOT touch turnInFlight — that may already
        // describe a successor turn queued behind the interrupt.
        if suppressUntilResult {
            if type == "result" {
                suppressUntilResult = false
                Log.write("interrupt: aborted turn's result consumed")
            }
            return
        }
        if type == "result" { turnInFlight = false; askpass?.endTurn(); cancelInputs() }

        switch type {
        case "control_response":
            guard let response = obj["response"] as? [String: Any],
                  let id = response["request_id"] as? String,
                  let stop = stopRequests.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "success" {
                Log.write("claude: background task stop confirmed")
                stop(.success(true))
            } else {
                stop(.failure(SubagentCancelError.server(
                    response["error"] as? String ?? "Claude Code couldn't stop that agent.")))
            }
        case "control_request":
            guard let id = obj["request_id"] as? String,
                  let request = obj["request"] as? [String: Any] else { return }
            if request["subtype"] as? String == "hook_callback" {
                answerPolicyHook(id: id, request: request)
                return
            }
            guard request["subtype"] as? String == "can_use_tool" else {
                sendControlResponse(id: id, response: ["behavior": "deny", "message": "Unsupported interactive request."])
                return
            }
            let tool = request["tool_name"] as? String ?? "tool"
            let input = request["input"] as? [String: Any] ?? [:]
            if readOnly {
                sendControlResponse(id: id, response: ["behavior": "deny", "message": "Read-only session."])
            } else if tool != "AskUserQuestion", let guardrail,
                      answerWithGuardrail(tool: tool, input: input, mode: guardrail, id: id) {
                // Answered now, or once the user responds to the approval request.
            } else if tool == "AskUserQuestion",
                      let questions = input["questions"] as? [[String: Any]], !questions.isEmpty {
                askQuestion(id: id, input: input, questions: questions, answers: [:])
            } else {
                let detail = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? tool
                let owner = process
                let pending = BackendInputRequest(kind: .approval, source: "Claude Code",
                    title: "Allow \(tool)?", detail: detail) { [weak self] answer in
                    self?.queue.async {
                        guard let self, self.process === owner, self.inputRequests.removeValue(forKey: id) != nil else { return }
                        self.sendControlResponse(id: id, response: answer.decision == .approve
                            ? ["behavior": "allow", "updatedInput": input]
                            : ["behavior": "deny", "message": "The user declined or cancelled this action."])
                    }
                }
                inputRequests[id] = pending
                onEvent(.inputRequired(pending))
            }
        case "control_cancel_request":
            if let id = obj["request_id"] as? String { inputRequests.removeValue(forKey: id)?.cancel() }
        case "stream_event":
            // Token-level streaming (--include-partial-messages).
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return }
            if eventType == "content_block_start",
               let block = event["content_block"] as? [String: Any] {
                switch block["type"] as? String {
                case "text" where hasEmittedText:
                    onEvent(.textDelta("\n\n")) // separate consecutive blocks
                case "thinking" where hasEmittedThinking:
                    onEvent(.thinkingDelta("\n\n"))
                default:
                    break
                }
            } else if eventType == "content_block_delta",
                      let delta = event["delta"] as? [String: Any] {
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        hasEmittedText = true
                        onEvent(.textDelta(text))
                    }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String, !text.isEmpty {
                        hasEmittedThinking = true
                        onEvent(.thinkingDelta(text))
                    }
                default:
                    break // signature_delta etc.
                }
            }
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let parentID = obj["parent_tool_use_id"] as? String
            if parentID == nil, let error = obj["error"] as? String, ["rate_limit", "billing_error"].contains(error) {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                usageLimitText = text.isEmpty ? "Claude usage limit reached." : text
                if usageLimitReport == nil { usageLimitReport = UsageLimitReport(code: error, resetsAt: nil) }
            }
            if let parentID, var parent = activities[parentID], parent.subagent != nil {
                // A subagent's own message: feed the monitor, keep it out of the answer.
                let messageID = message["id"] as? String
                let firstReport = messageID.map { countedSubagentMessages.insert($0).inserted } ?? true
                let usage = firstReport ? message["usage"] as? [String: Any] : nil
                parent.subagent?.tokens += (usage?["input_tokens"] as? Int ?? 0)
                    + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage?["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage?["output_tokens"] as? Int ?? 0)
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                if let latest = SubagentInfo.clipped(text) { parent.subagent?.latestMessage = latest }
                if parent != activities[parentID] {
                    activities[parentID] = parent
                    onEvent(.activity(parent))
                }
            } else if parentID == nil, let messageID = message["id"] as? String,
                      countedRootMessages.insert(messageID).inserted,
                      let usage = message["usage"] as? [String: Any] {
                // Each root model call's full prompt: the context at that point in the turn.
                onEvent(.context(BackendContextUsage(tokens: (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0))))
            }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    // Text already streamed token-by-token via stream_event;
                    // the complete message would duplicate it.
                    break
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "tool"
                    var activity = ToolActivityFactory.start(
                        id: id,
                        toolName: name,
                        arguments: block["input"]
                    )
                    if parentID == nil, ["Task", "Agent"].contains(name) {
                        let input = block["input"] as? [String: Any]
                        activity.subagent = SubagentInfo(
                            agentID: id,
                            name: input?["description"] as? String ?? "",
                            agentType: input?["subagent_type"] as? String ?? "general-purpose",
                            summary: "",
                            model: input?["model"] as? String,
                            background: input?["run_in_background"] as? Bool ?? false
                        )
                    }
                    if let parentID, var parent = activities[parentID] {
                        // Subagent step: nest under its Task activity.
                        parent.children.append(activity)
                        activities[parentID] = parent
                        childIndex[id] = parentID
                        onEvent(.activity(parent))
                    } else {
                        activities[id] = activity
                        onEvent(.activity(activity))
                    }
                default:
                    break
                }
            }
        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let isError = block["is_error"] as? Bool ?? false
                let output = block["content"] ?? obj["tool_use_result"]
                if let parentID = childIndex.removeValue(forKey: id),
                   var parent = activities[parentID] {
                    // Complete the nested subagent step; re-emit the parent.
                    if let childIdx = parent.children.firstIndex(where: { $0.id == id }) {
                        parent.children[childIdx] = ToolActivityFactory.complete(
                            parent.children[childIdx], id: id,
                            success: !isError, output: output)
                    }
                    activities[parentID] = parent
                    onEvent(.activity(parent))
                    continue
                }
                var completed = ToolActivityFactory.complete(
                    activities.removeValue(forKey: id),
                    id: id,
                    success: !isError,
                    output: output
                )
                if let info = completed.subagent, info.isActive, !info.background || isError {
                    callTasks.removeValue(forKey: id).map { _ = taskCalls.removeValue(forKey: $0) }
                    completed = completed.finishing(as: isError ? .failed : .succeeded)
                    completed.subagent?.toolCalls = completed.children.count
                } else if completed.subagent?.isActive == true {
                    // Launched in the background: its steps keep nesting here until it reports.
                    activities[id] = completed
                }
                onEvent(.activity(completed))
            }
        case "result":
            if let usage = obj["modelUsage"] as? [String: Any] {
                let windows = usage.compactMap { key, value -> (String, Int)? in
                    ((value as? [String: Any])?["contextWindow"] as? Int).map { (key, $0) }
                }
                if let window = windows.first(where: { $0.0 == rootModel })?.1 ?? windows.map(\.1).max() {
                    contextLimit = window
                    onEvent(.context(BackendContextUsage(limit: window)))
                }
            }
            if let cost = obj["total_cost_usd"] as? Double {
                let usage = obj["usage"] as? [String: Any]
                onEvent(.usage(BackendUsage(
                    backend: "Claude Code", costUSD: cost,
                    inputTokens: (usage?["input_tokens"] as? Int ?? 0)
                        + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                        + (usage?["cache_read_input_tokens"] as? Int ?? 0),
                    outputTokens: usage?["output_tokens"] as? Int ?? 0,
                    cachedInputTokens: usage?["cache_read_input_tokens"] as? Int ?? 0,
                    modelCalls: max(1, obj["num_turns"] as? Int ?? 1)
                )))
            }
            if let isError = obj["is_error"] as? Bool, isError,
               let result = obj["result"] as? String {
                if let report = usageLimitReport { onEvent(.usageLimit(report)) }
                onEvent(.failure(result))
            } else if let limit = usageLimitText, !hasEmittedText {
                if let report = usageLimitReport { onEvent(.usageLimit(report)) }
                onEvent(.failure(UsageLimit.isLimitError(limit) ? limit : "Claude usage limit reached: \(limit)"))
            } else {
                // Local slash commands (/context, /cost, ...) answer with a synthetic message and
                // no streamed text; their output is only in the result.
                if !hasEmittedText, let result = obj["result"] as? String,
                   !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasEmittedText = true
                    onEvent(.textDelta(result))
                }
                // Turn complete — the process stays alive for the next
                // message, so "result" is now the end-of-turn signal.
                commitSeenTurns()
                finishRootTurn(onEvent)
            }
        case "tool_progress":
            // A long command or agent still running; nothing to show, but the run is alive.
            onEvent(.heartbeat)
        case "rate_limit_event":
            if let info = obj["rate_limit_info"] as? [String: Any],
               let resets = info["resetsAt"] as? TimeInterval {
                // Utilization appears only in some CLI versions/situations;
                // grab it under any of its known names when present.
                let rawUtil = (info["utilization"] ?? info["used_percentage"]
                    ?? info["percentUsed"] ?? info["percent_used"]) as? Double
                let percent = rawUtil.map { $0 <= 1.0 ? $0 * 100 : $0 }
                let type = info["rateLimitType"] as? String ?? "window"
                let status = info["status"] as? String ?? "unknown"
                UsageTracker.shared.updateRateLimit(
                    type: type,
                    resetsAtEpoch: resets,
                    status: status,
                    percentUsed: percent)
                if status == "rejected" {
                    // The window that's used up, and when it opens again.
                    usageLimitReport = UsageLimitReport(code: "rate_limit/\(type)",
                                                        resetsAt: Date(timeIntervalSince1970: resets))
                }
            }
        case "system":
            let subtype = obj["subtype"] as? String ?? ""
            if subtype == "init" {
                if let model = obj["model"] as? String { rootModel = model }
                if !turnInFlight, waitingOnBackground {
                    // The CLI started a turn of its own: finished background work reports to the root.
                    let finished = finishedBackground
                    let parallel = finishedParallel
                    endBackgroundWait()
                    finishedBackground.removeAll()
                    finishedParallel = false
                    // hasEmittedText stays set, so the wake's reply starts a new paragraph.
                    turnInFlight = true
                    countedRootMessages.removeAll()
                    Log.write("claude: background work woke the root (\(finished.count) finished)")
                    onEvent(.status(BackgroundWaitStatus.resuming(parallel: parallel)))
                    onEvent(.backgroundWake(finished))
                } else {
                    if turnInFlight { finishedBackground.removeAll(); finishedParallel = false }
                    onEvent(.status("Thinking…"))
                }
            } else {
                handleTaskEvent(subtype, obj, onEvent)
            }
        default:
            break
        }
    }
}
