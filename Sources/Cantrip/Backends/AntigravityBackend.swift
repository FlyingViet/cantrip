import AppKit
import Darwin
import Foundation

/// Google Antigravity (`agy`) backend using the official `agy` CLI headless streaming protocol
/// (`agy --input-format stream-json --output-format stream-json`).
///
/// Protocol overview:
/// - Stdin accepts newline-delimited JSON user messages:
///   `{"event":"user","message":{"content":"..."}}`
/// - Stdout emits newline-delimited JSON events:
///   - `{"event":"init","conversation_id":"...","init":{...}}`
///   - `{"event":"step_update","step_update":{"state":"ACTIVE"|"DONE","step_type":"agent_response"|"tool"|...}}`
///   - `{"event":"result","result":{"status":"SUCCESS"|"ERROR"|"CANCELED"|"INTERRUPTED","usage":{...}}}`
///     (`result.usage` is cumulative across the session; per-turn token usage is computed as a delta.)
/// - Stopping a turn sends `SIGINT`, and subsequent processes resume via `--conversation <id>`.
/// - Unless the session may do anything (`--dangerously-skip-permissions`), every tool call goes
///   through Cantrip's `PreToolUse` hook (see `AntigravityHook`): read-only sessions may only look,
///   "Allow actions" off asks the user, and Cantrip Home applies its action policy.
final class AntigravityBackend: Backend, CantripHomeGuardedBackend {
    /// Who decides a tool call. `nil` means agy runs with `--dangerously-skip-permissions`.
    enum HookPolicy: Equatable {
        case readOnly
        case ask
        case guardrail(CantripHomeGuardrail)
    }

    private let settings = AppSettings.shared
    private let persistKey: String
    private let readOnly: Bool
    /// A tab's own model and effort (nil follows the Mac's Antigravity settings). Set on the main
    /// thread, read when a turn launches `agy`; a change relaunches it on the same conversation.
    private let overrideLock = NSLock()
    private var storedModelOverride: String?
    private var storedEffortOverride: String?
    private var storedTurnModelOverride: String?
    private var storedFallbackSourceModel: String?
    private var storedIsIncidentTurn = false
    var modelOverride: String? {
        get { overrideLock.withLock { storedModelOverride } }
        set { overrideLock.withLock { storedModelOverride = newValue; storedTurnModelOverride = nil } }
    }
    var effortOverride: String? {
        get { overrideLock.withLock { storedEffortOverride } }
        set { overrideLock.withLock { storedEffortOverride = newValue } }
    }
    var turnModelOverride: String? {
        get { overrideLock.withLock { storedTurnModelOverride } }
        set { overrideLock.withLock { storedTurnModelOverride = newValue } }
    }
    var fallbackSourceModel: String? {
        get { overrideLock.withLock { storedFallbackSourceModel } }
        set { overrideLock.withLock { storedFallbackSourceModel = newValue } }
    }
    var isIncidentTurn: Bool {
        get { overrideLock.withLock { storedIsIncidentTurn } }
        set { overrideLock.withLock { storedIsIncidentTurn = newValue } }
    }
    var guardrail: CantripHomeGuardrail?
    var guardrailLabel = "Cantrip Home"

    private let stateLock = NSLock()
    private var currentProcess: Process?
    private var stdinHandle: FileHandle?
    private var activeWorkdir: String = ""
    private var activeLaunchSignature: String = ""
    private var sessionID: String? {
        didSet { UserDefaults.standard.set(sessionID, forKey: persistKey) }
    }
    private var outputSessionKey = UUID().uuidString

    var conversationID: String? {
        stateLock.withLock { sessionID }
    }

    // Cumulative usage reported by `result.usage` on the current persistent `agy` process.
    private var cumulativeInputTokens = 0
    private var cumulativeOutputTokens = 0
    private var cumulativeCachedInputTokens = 0

    // Active turn state.
    private var turnInFlight = false
    private var turnCompleted = false
    private var turnStreamedText = ""
    private var turnEventCallback: ((BackendEvent) -> Void)?
    private var activeTools: [String: ToolActivity] = [:]
    private var activeSubagents: [String: SubagentInfo] = [:]
    private var activeSubagentChildren: [String: [ToolActivity]] = [:]
    private var subagentPollTimer: DispatchSourceTimer?
    private var pendingInputRequests: [UUID: BackendInputRequest] = [:]
    private var approvedGuardrailScopes: Set<String> = []
    private var stdoutRemainder = Data()
    private var stderrCollected = Data()

    // The current process's PreToolUse hook. Tool steps agy reports beyond the hook requests it
    // made mean the hook isn't reaching Cantrip.
    private var hookServer: AntigravityHookServer?
    private var hookRequestCount = 0
    private var hookedToolSteps = 0

    private let ioQueue = DispatchQueue(label: "cantrip.antigravity.io", qos: .userInitiated)

    init(
        persistKey: String = "agySessionID",
        readOnly: Bool = false,
        modelOverride: String? = nil,
        effortOverride: String? = nil
    ) {
        self.persistKey = persistKey
        self.readOnly = readOnly
        self.storedModelOverride = modelOverride
        self.storedEffortOverride = effortOverride
        self.sessionID = UserDefaults.standard.string(forKey: persistKey)
    }

    deinit {
        stopProcessAndCleanUp()
    }

    var supportsMidTurnInjection: Bool { false }
    var canSteerTurns: Bool { false }

    // MARK: - Executable Resolution

    func isAvailable() -> Bool {
        resolveExecutable() != nil
    }

    static func isInstalled(customPath: String = "") -> Bool {
        resolveExecutable(customPath: customPath) != nil
    }

    func resolveExecutable() -> String? {
        Self.resolveExecutable(customPath: settings.agyPath)
    }

    static func resolveExecutable(
        customPath: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        let fm = FileManager.default
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, fm.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        let pathValue = ToolPath.value(inherited: environment["PATH"], home: home)
        for dir in pathValue.split(separator: ":").map(String.init) {
            let candidate = "\(dir)/agy"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let fallbacks = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        return fallbacks.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - CLI Argument Builder

    static let supportedEfforts: Set<String> = ["low", "medium", "high"]

    var hookPolicy: HookPolicy? {
        if readOnly { return .readOnly }
        if let guardrail { return .guardrail(guardrail) }
        if settings.allowActions || settings.agyPermissionMode == "bypassPermissions" { return nil }
        return .ask
    }

    func buildArguments(resumingSessionID: String?) -> [String] {
        var args = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
        ]
        if let sid = resumingSessionID, !sid.isEmpty {
            args += ["--conversation", sid]
        }
        let model = (turnModelOverride ?? modelOverride ?? settings.agyModel).trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty, model != "auto" {
            args += ["--model", model]
        }
        let effort = (effortOverride ?? settings.agyEffort).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.supportedEfforts.contains(effort) {
            args += ["--effort", effort]
        }
        // Headless agy allows file edits inside the workspace on its own, so anything short of
        // "may do anything" is decided by Cantrip's PreToolUse hook instead. In attended Home
        // sessions with automatic approval enabled, also pass --dangerously-skip-permissions so
        // agy's internal WriteFile confirmation manager does not soft-deny dot-directory writes
        // after Cantrip's PreToolUse hook has already approved them.
        if hookPolicy == nil || (guardrail == .attended && (settings.allowActions || settings.agyPermissionMode == "bypassPermissions")) {
            args.append("--dangerously-skip-permissions")
        }
        if settings.agyPermissionMode == "sandbox" {
            args.append("--sandbox")
        }
        return args
    }

    private func launchSignature(for workdir: String) -> String {
        let model = (turnModelOverride ?? modelOverride ?? settings.agyModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = (effortOverride ?? settings.agyEffort).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guardrailKey = guardrail?.rawValue ?? "none"
        return "\(workdir)|\(model)|\(effort)|\(readOnly)|\(settings.allowActions)|\(settings.agyPermissionMode)|\(guardrailKey)"
    }

    /// Resolves the per-turn Antigravity model when the configured model is auto/default, a fallback
    /// from Claude/ChatGPT/Copilot, or an external credit-consuming model slug.
    func resolveTurnModel(for request: BackendRequest) {
        let configuredModel = (modelOverride ?? settings.agyModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredEffort = (effortOverride ?? settings.agyEffort).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = fallbackSourceModel
        let incident = isIncidentTurn
        fallbackSourceModel = nil
        isIncidentTurn = false

        // Default/Auto tiers by task; a model the user picked is used as picked. Standing in for
        // another backend (the usage-limit fallback the user chose) tiers from that model.
        let automatic = configuredModel.isEmpty || configuredModel == "auto"
        let shouldTier = automatic || source != nil
        guard shouldTier else {
            turnModelOverride = nil
            return
        }
        let queryText = request.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? request.prompt : request.userMessage
        let effectiveSource = source ?? (AntigravityTaskTier.usesExternalCredits(configuredModel) ? configuredModel : nil)
        let chosen = AntigravityTaskTier.chooseModel(
            for: queryText,
            available: settings.agyAvailableModels,
            effort: configuredEffort,
            sourceModel: effectiveSource,
            isIncident: incident
        )
        turnModelOverride = chosen
        Log.write("antigravity: task tiering (\(queryText.count) chars, configured=\(configuredModel.isEmpty ? "default" : configuredModel)) -> \(chosen)")
    }

    // MARK: - Backend Protocol

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        guard let executable = resolveExecutable() else {
            onEvent(.failure("Antigravity CLI (`agy`) not found. Install Antigravity or set its path in Settings."))
            return
        }

        resolveTurnModel(for: request)
        let resolvedWorkdir = workdir.isEmpty ? NSHomeDirectory() : workdir
        let prompt = stagePromptAttachments(in: request.prompt, workdir: resolvedWorkdir)

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.startTurn(
                prompt: prompt,
                executable: executable,
                workdir: resolvedWorkdir,
                onEvent: onEvent
            )
        }
    }

    func interruptTurn() -> Bool {
        stateLock.lock()
        let process = currentProcess
        let inFlight = turnInFlight && !turnCompleted
        stateLock.unlock()

        guard inFlight, let process, process.isRunning else { return false }
        kill(process.processIdentifier, SIGINT)
        return true
    }

    func cancel() {
        cancelPendingInputRequests()
        stateLock.lock()
        turnInFlight = false
        turnCompleted = true
        turnEventCallback = nil
        stateLock.unlock()

        stopProcessAndCleanUp()
    }

    func reset() {
        cancel()
        stateLock.lock()
        sessionID = nil
        outputSessionKey = UUID().uuidString
        approvedGuardrailScopes.removeAll()
        stateLock.unlock()
    }

    // MARK: - Turn & Persistent Process Lifecycle

    private func startTurn(
        prompt: String,
        executable: String,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        stateLock.lock()
        approvedGuardrailScopes.removeAll()
        turnInFlight = true
        turnCompleted = false
        turnStreamedText = ""
        turnEventCallback = onEvent
        activeTools.removeAll()
        activeSubagents.removeAll()
        activeSubagentChildren.removeAll()
        stderrCollected.removeAll(keepingCapacity: true)
        stateLock.unlock()
        stopSubagentPollTimer()

        onEvent(.status("Thinking"))

        do {
            try ensureProcess(executable: executable, workdir: workdir)
        } catch {
            finishTurn(with: .failure("Failed to launch Antigravity CLI: \(error.localizedDescription)"))
            return
        }

        let userFrame: [String: Any] = [
            "event": "user",
            "message": [
                "content": prompt,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: userFrame),
              let handle = stateLock.withLock({ stdinHandle }) else {
            finishTurn(with: .failure("Failed to encode message for Antigravity CLI."))
            return
        }

        var line = data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            stopProcessAndCleanUp()
            finishTurn(with: .failure("Failed to write prompt to Antigravity CLI: \(error.localizedDescription)"))
        }
    }

    private func ensureProcess(executable: String, workdir: String) throws {
        let signature = launchSignature(for: workdir)
        stateLock.lock()
        if let existing = currentProcess, existing.isRunning, activeLaunchSignature == signature {
            stateLock.unlock()
            return
        }
        let resumeID = sessionID
        stateLock.unlock()

        stopProcessAndCleanUp()

        var env = ToolPath.environment()
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: AntigravityHook.socketVariable)
        if let policy = hookPolicy {
            do {
                try AntigravityHook.install()
            } catch {
                throw NSError(domain: "Cantrip", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Cantrip couldn't add its tool check to \(AntigravityHook.configFile.path) "
                    + "(\(error.localizedDescription)). Fix or move that file, or set Antigravity to Allow everything."])
            }
            let server = try AntigravityHookServer { [weak self] request, respond in
                guard let self else {
                    respond("deny", "The Cantrip session ended.")
                    return
                }
                self.handleHookRequest(request, policy: policy, respond: respond)
            }
            env[AntigravityHook.socketVariable] = server.socketPath
            stateLock.withLock { hookServer = server }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = buildArguments(resumingSessionID: resumeID)
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stateLock.lock()
        currentProcess = process
        stdinHandle = stdinPipe.fileHandleForWriting
        activeWorkdir = workdir
        activeLaunchSignature = signature
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0
        cumulativeCachedInputTokens = 0
        hookRequestCount = 0
        hookedToolSteps = 0
        stdoutRemainder.removeAll(keepingCapacity: true)
        stateLock.unlock()

        // Output and exits are only acted on while this is still the current process: a process
        // replaced after a settings change must not end (or write into) the next turn.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async {
                guard let process else { return }
                self?.consumeStdout(chunk, from: process)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async {
                guard let process else { return }
                self?.collectStderr(chunk, from: process)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.ioQueue.async {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailing.isEmpty {
                    self.consumeStdout(trailing, from: proc)
                }
                let trailingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailingErr.isEmpty {
                    self.collectStderr(trailingErr, from: proc)
                }
                self.handleProcessExit(proc)
            }
        }

        do {
            try process.run()
        } catch {
            stopProcessAndCleanUp()
            throw error
        }
    }

    private func isCurrent(_ process: Process) -> Bool {
        stateLock.withLock { currentProcess === process }
    }

    private func collectStderr(_ chunk: Data, from process: Process) {
        stateLock.withLock {
            guard currentProcess === process, stderrCollected.count < 32_768 else { return }
            stderrCollected.append(chunk)
        }
    }

    private func handleProcessExit(_ process: Process) {
        stateLock.lock()
        guard currentProcess === process else {
            stateLock.unlock()
            return
        }
        currentProcess = nil
        stdinHandle = nil
        activeLaunchSignature = ""
        let shouldFinishTurn = turnInFlight && !turnCompleted
        let stderrText = String(data: stderrCollected, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stateLock.unlock()

        stopHookServer()

        guard shouldFinishTurn else { return }
        let status = process.terminationStatus
        let reason = process.terminationReason
        if reason == .uncaughtSignal && (status == SIGINT || status == SIGTERM) {
            finishTurn(with: .done)
            return
        }
        if status == 0 {
            finishTurn(with: .done)
        } else {
            let detail = stderrText.isEmpty ? "Antigravity exited with code \(status)." : stderrText
            finishTurn(with: .failure(detail))
        }
    }

    private func finishTurn(with terminalEvent: BackendEvent) {
        stopSubagentPollTimer()
        cancelPendingInputRequests()
        stateLock.lock()
        guard turnInFlight, !turnCompleted else {
            stateLock.unlock()
            return
        }
        turnInFlight = false
        turnCompleted = true
        let callback = turnEventCallback
        turnEventCallback = nil
        let remainingTools = Array(activeTools.values)
        activeTools.removeAll()
        let remainingSubagents = Array(activeSubagents.values)
        let remainingChildren = activeSubagentChildren
        activeSubagents.removeAll()
        activeSubagentChildren.removeAll()
        stateLock.unlock()

        guard let callback else { return }
        for var tool in remainingTools where tool.state == .running {
            tool.state = .succeeded
            callback(.activity(tool))
        }
        for var sub in remainingSubagents where sub.status == .running {
            var children = remainingChildren[sub.agentID] ?? []
            _ = AntigravitySubagentTranscript.hydrate(&sub, children: &children, forceComplete: true)
            if sub.status == .running {
                sub.status = .completed
                sub.finishedAt = sub.finishedAt ?? Date()
            }
            callback(.activity(Self.subagentActivity(for: sub, children: children)))
        }
        callback(terminalEvent)
    }

    private func stopProcessAndCleanUp() {
        stopSubagentPollTimer()
        cancelPendingInputRequests()
        stateLock.lock()
        let process = currentProcess
        let stdin = stdinHandle
        currentProcess = nil
        stdinHandle = nil
        activeLaunchSignature = ""
        stateLock.unlock()

        try? stdin?.close()
        if let process, process.isRunning {
            let pid = process.processIdentifier
            kill(pid, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        }
        stopHookServer()
    }

    // MARK: - Stream-JSON Parsing

    private func consumeStdout(_ chunk: Data, from process: Process) {
        var lines: [Data] = []
        stateLock.lock()
        guard currentProcess === process else {
            stateLock.unlock()
            return
        }
        stdoutRemainder.append(chunk)
        while let newline = stdoutRemainder.firstIndex(of: 0x0A) {
            let line = stdoutRemainder.subdata(in: stdoutRemainder.startIndex..<newline)
            stdoutRemainder.removeSubrange(stdoutRemainder.startIndex...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        stateLock.unlock()

        for line in lines where isCurrent(process) {
            handleStreamLine(line)
        }
    }

    private func handleStreamLine(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        switch event {
        case "init":
            let initDict = json["init"] as? [String: Any]
            if let cid = (json["conversation_id"] as? String) ?? (initDict?["conversation_id"] as? String),
               !cid.isEmpty {
                stateLock.withLock { sessionID = cid }
            }

        case "step_update":
            guard let step = json["step_update"] as? [String: Any] else { return }
            handleStepUpdate(step, root: json)

        case "result":
            let result = (json["result"] as? [String: Any]) ?? json
            handleResult(result, root: json)

        default:
            break
        }
    }

    private func handleStepUpdate(_ step: [String: Any], root: [String: Any]) {
        if let cid = (step["conversation_id"] as? String) ?? (root["conversation_id"] as? String),
           !cid.isEmpty {
            stateLock.withLock { sessionID = cid }
        }

        guard let callback = stateLock.withLock({ turnInFlight && !turnCompleted ? turnEventCallback : nil }) else {
            return
        }

        let state = (step["state"] as? String ?? "").uppercased()
        let stepType = (step["step_type"] as? String ?? "").lowercased()
        let stepIndex = step["step_index"] as? Int

        if stepType == "agent_response" {
            if let thinking = (step["thinking_delta"] as? String) ?? (step["thinking"] as? String),
               !thinking.isEmpty {
                callback(.thinkingDelta(thinking))
            }
            if let delta = step["text_delta"] as? String, !delta.isEmpty {
                stateLock.withLock { turnStreamedText += delta }
                callback(.textDelta(delta))
            }
            return
        }

        if let subagentContainer = step["subagent_info"] as? [String: Any],
           let subagents = subagentContainer["subagents"] as? [[String: Any]],
           !subagents.isEmpty {
            handleSubagentUpdate(subagents, state: state, stepIndex: stepIndex, toolInfo: step["tool_info"] as? [String: Any], callback: callback)
            return
        }

        if stepType == "tool" || step["tool_info"] != nil || step["tool_name"] != nil {
            let toolInfo = step["tool_info"] as? [String: Any]
            let toolName = (toolInfo?["name"] as? String)
                ?? (step["tool_name"] as? String)
                ?? "Tool"
            let params = toolInfo?["parameters"] as? [String: Any]
            let toolID = stepIndex.map { "step-\($0)" } ?? "tool-\(toolName)"

            if state == "ACTIVE" {
                let activity = ToolActivityFactory.start(
                    id: toolID,
                    toolName: toolName,
                    arguments: params
                )
                stateLock.withLock { activeTools[toolID] = activity }
                callback(.activity(activity))
                callback(.status(activity.title))
            } else if state == "DONE" {
                let starting: ToolActivity? = stateLock.withLock {
                    activeTools.removeValue(forKey: toolID)
                } ?? (params != nil ? ToolActivityFactory.start(id: toolID, toolName: toolName, arguments: params) : nil)

                let errorValue = toolInfo?["error"]
                let hasError = (errorValue != nil && !(errorValue is NSNull))
                let errorMessage: String? = {
                    if let dict = errorValue as? [String: Any] {
                        return (dict["message"] as? String) ?? (dict["type"] as? String)
                    }
                    return errorValue as? String
                }()
                let output: Any? = errorMessage ?? toolInfo?["output"]
                let completed = ToolActivityFactory.complete(
                    starting,
                    id: toolID,
                    toolName: toolName,
                    success: !hasError,
                    output: output
                )
                callback(.activity(completed))
                if stepType == "tool" { checkToolWasHooked(toolName) }
            }
        }
    }

    private func handleSubagentUpdate(
        _ subagents: [[String: Any]],
        state: String,
        stepIndex: Int?,
        toolInfo: [String: Any]?,
        callback: (BackendEvent) -> Void
    ) {
        let paramSpecs = ((toolInfo?["parameters"] as? [String: Any])?["Subagents"] as? [[String: Any]]) ?? []
        let singleParams = toolInfo?["parameters"] as? [String: Any]
        let errorValue = toolInfo?["error"]
        let hasError = (errorValue != nil && !(errorValue is NSNull))
        let outputText = toolInfo?["output"] as? String
        let isAsyncSpawn = outputText?.contains("Created the following subagent") == true

        for (idx, item) in subagents.enumerated() {
            let fallbackID = stepIndex.map { "subagent-\($0)-\(idx)" } ?? "subagent-\(idx)"
            let rawID = (item["conversation_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (rawID?.isEmpty == false ? rawID : nil)
                ?? Self.extractSpawnedConversationID(from: outputText)
                ?? fallbackID
            let role = (item["role"] as? String)
                ?? (idx < paramSpecs.count ? paramSpecs[idx]["Role"] as? String : nil)
                ?? (singleParams?["Role"] as? String)
                ?? ""
            let typeName = (item["type_name"] as? String)
                ?? (idx < paramSpecs.count ? paramSpecs[idx]["TypeName"] as? String : nil)
                ?? (singleParams?["TypeName"] as? String)
                ?? "subagent"
            let prompt = (idx < paramSpecs.count ? paramSpecs[idx]["Prompt"] as? String : nil)
                ?? (singleParams?["Prompt"] as? String)

            stateLock.lock()
            if id != fallbackID {
                activeSubagents.removeValue(forKey: fallbackID)
                activeSubagentChildren.removeValue(forKey: fallbackID)
            }
            var info = activeSubagents[id] ?? SubagentInfo(
                agentID: id,
                name: role.isEmpty ? typeName : role,
                agentType: typeName,
                summary: SubagentInfo.clipped(prompt ?? "", limit: 400) ?? "",
                status: .running,
                startedAt: Date()
            )
            info.agentID = id
            if !role.isEmpty { info.name = role }
            if !typeName.isEmpty { info.agentType = typeName }
            if let prompt, !prompt.isEmpty,
               info.summary.isEmpty || info.summary.hasPrefix("Created the following subagent") {
                info.summary = SubagentInfo.clipped(prompt, limit: 400) ?? ""
            }
            var children = activeSubagentChildren[id] ?? []
            _ = AntigravitySubagentTranscript.hydrate(&info, children: &children, forceComplete: false)

            if state == "DONE" {
                if hasError {
                    info.status = .failed
                    info.finishedAt = Date()
                    activeSubagents.removeValue(forKey: id)
                    activeSubagentChildren.removeValue(forKey: id)
                } else if isAsyncSpawn {
                    // `invoke_subagent` returns immediately after spawning the background agent;
                    // keep tracking its transcript until it finishes or the parent turn ends.
                    if info.status != .completed && info.status != .failed {
                        info.status = .running
                        activeSubagents[id] = info
                        activeSubagentChildren[id] = children
                    } else {
                        activeSubagents.removeValue(forKey: id)
                        activeSubagentChildren.removeValue(forKey: id)
                    }
                } else {
                    info.status = .completed
                    info.finishedAt = info.finishedAt ?? Date()
                    if let outputText, !outputText.isEmpty,
                       let clipped = SubagentInfo.clipped(outputText, limit: 400) {
                        info.summary = clipped
                    }
                    activeSubagents.removeValue(forKey: id)
                    activeSubagentChildren.removeValue(forKey: id)
                }
            } else {
                info.status = .running
                activeSubagents[id] = info
                activeSubagentChildren[id] = children
            }
            let shouldPoll = !activeSubagents.isEmpty && turnInFlight && !turnCompleted
            stateLock.unlock()

            let activity = Self.subagentActivity(for: info, children: children)
            callback(.activity(activity))
            if state == "ACTIVE" || info.status == .running {
                callback(.status("Running \(info.displayName)"))
            }
            if shouldPoll {
                ensureSubagentPollTimer()
            }
        }
    }

    private static func extractSpawnedConversationID(from output: String?) -> String? {
        guard let output, output.contains("conversationId") else { return nil }
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else { return nil }
        let jsonSlice = String(output[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cid = (obj["conversationId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cid.isEmpty else {
            return nil
        }
        return cid
    }

    private func ensureSubagentPollTimer() {
        stateLock.lock()
        guard subagentPollTimer == nil, turnInFlight, !turnCompleted, !activeSubagents.isEmpty else {
            stateLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.pollActiveSubagents()
        }
        subagentPollTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopSubagentPollTimer() {
        let timer: DispatchSourceTimer? = stateLock.withLock {
            defer { subagentPollTimer = nil }
            return subagentPollTimer
        }
        timer?.cancel()
    }

    private func pollActiveSubagents() {
        stateLock.lock()
        guard turnInFlight, !turnCompleted, let callback = turnEventCallback, !activeSubagents.isEmpty else {
            stateLock.unlock()
            stopSubagentPollTimer()
            return
        }
        let currentIDs = Array(activeSubagents.keys)
        stateLock.unlock()

        var updates: [ToolActivity] = []
        for id in currentIDs {
            stateLock.lock()
            guard var info = activeSubagents[id] else {
                stateLock.unlock()
                continue
            }
            var children = activeSubagentChildren[id] ?? []
            stateLock.unlock()

            let changed = AntigravitySubagentTranscript.hydrate(&info, children: &children, forceComplete: false)
            guard changed else { continue }

            stateLock.lock()
            if info.status == .completed || info.status == .failed {
                activeSubagents.removeValue(forKey: id)
                activeSubagentChildren.removeValue(forKey: id)
            } else {
                activeSubagents[id] = info
                activeSubagentChildren[id] = children
            }
            stateLock.unlock()

            updates.append(Self.subagentActivity(for: info, children: children))
        }

        for activity in updates {
            callback(.activity(activity))
        }

        let stillActive = stateLock.withLock { !activeSubagents.isEmpty && turnInFlight && !turnCompleted }
        if !stillActive {
            stopSubagentPollTimer()
        }
    }

    fileprivate static func subagentActivity(for info: SubagentInfo, children: [ToolActivity] = []) -> ToolActivity {
        var activity = ToolActivity(
            id: "subagent-\(info.agentID)",
            title: info.displayName,
            toolName: "Subagent",
            state: ToolActivityState(info.status),
            input: info.summary.isEmpty ? nil : info.summary,
            output: info.latestMessage,
            fileChanges: [],
            children: children
        )
        activity.subagent = info
        return activity
    }

    private func handleResult(_ result: [String: Any], root: [String: Any]) {
        if let cid = (result["conversation_id"] as? String) ?? (root["conversation_id"] as? String),
           !cid.isEmpty {
            stateLock.withLock { sessionID = cid }
        }

        let callback = stateLock.withLock { turnInFlight && !turnCompleted ? turnEventCallback : nil }

        if let usage = result["usage"] as? [String: Any] {
            let totalInput = (usage["input_tokens"] as? Int) ?? 0
            let totalOutput = (usage["output_tokens"] as? Int) ?? 0
            let totalCached = (usage["cache_read_tokens"] as? Int) ?? 0

            stateLock.lock()
            let deltaInput = max(0, totalInput - cumulativeInputTokens)
            let deltaOutput = max(0, totalOutput - cumulativeOutputTokens)
            let deltaCached = max(0, totalCached - cumulativeCachedInputTokens)
            cumulativeInputTokens = max(cumulativeInputTokens, totalInput)
            cumulativeOutputTokens = max(cumulativeOutputTokens, totalOutput)
            cumulativeCachedInputTokens = max(cumulativeCachedInputTokens, totalCached)
            stateLock.unlock()

            if let callback, deltaInput > 0 || deltaOutput > 0 {
                callback(.usage(BackendUsage(
                    backend: "antigravity",
                    costUSD: 0,
                    inputTokens: deltaInput,
                    outputTokens: deltaOutput,
                    cachedInputTokens: deltaCached
                )))
                callback(.context(BackendContextUsage(tokens: deltaInput)))
            }
        }

        let streamedEmpty = stateLock.withLock { turnStreamedText.isEmpty }
        if streamedEmpty,
           let response = result["response"] as? String,
           !response.isEmpty {
            stateLock.withLock { turnStreamedText = response }
            callback?(.textDelta(response))
        }

        let status = (result["status"] as? String ?? "SUCCESS").uppercased()
        switch status {
        case "SUCCESS", "CANCELED", "INTERRUPTED":
            finishTurn(with: .done)
        case "WAITING", "RUNNING":
            break
        default:
            let errText = (result["error"] as? String)
                ?? (result["response"] as? String)
                ?? "Antigravity ended with status \(status)."
            finishTurn(with: .failure(errText))
        }
    }

    // MARK: - Attachment Staging

    private func outputFolderID() -> String {
        stateLock.withLock { sessionID ?? outputSessionKey }
    }

    func stagePromptAttachments(in prompt: String, workdir: String) -> String {
        let prefixes = [
            "[Attached image — read this file with your Read/view tool: ",
            "(Attached image: ",
        ]
        guard prefixes.contains(where: { prompt.contains($0) }) else { return prompt }
        let fm = FileManager.default
        let destinationDir = RemoteGeneratedImages.sourceRoot
            .appendingPathComponent("agy-attachments/\(outputFolderID())", isDirectory: true)
        try? fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var rewritten = prompt
        for (prefix, closeToken) in [
            ("[Attached image — read this file with your Read/view tool: ", "]"),
            ("(Attached image: ", ")"),
        ] {
            var searchRange = rewritten.startIndex..<rewritten.endIndex
            while let prefixRange = rewritten.range(of: prefix, range: searchRange),
                  let closeRange = rewritten.range(of: closeToken, range: prefixRange.upperBound..<rewritten.endIndex) {
                let sourcePath = String(rewritten[prefixRange.upperBound..<closeRange.lowerBound])
                let sourceURL = URL(fileURLWithPath: sourcePath)
                if fm.fileExists(atPath: sourcePath) {
                    let targetURL = destinationDir.appendingPathComponent(sourceURL.lastPathComponent)
                    if sourceURL.standardizedFileURL != targetURL.standardizedFileURL {
                        try? fm.removeItem(at: targetURL)
                        try? fm.copyItem(at: sourceURL, to: targetURL)
                    }
                    if fm.fileExists(atPath: targetURL.path) {
                        rewritten.replaceSubrange(prefixRange.upperBound..<closeRange.lowerBound, with: targetURL.path)
                        let advance = rewritten.index(prefixRange.upperBound, offsetBy: targetURL.path.count, limitedBy: rewritten.endIndex) ?? rewritten.endIndex
                        searchRange = advance..<rewritten.endIndex
                        continue
                    }
                }
                searchRange = closeRange.upperBound..<rewritten.endIndex
            }
        }
        return rewritten
    }

    // MARK: - PreToolUse Hook

    /// A finished tool step agy never asked the hook about means the hook isn't in effect (its
    /// entry was removed or disabled, say), so the session stops instead of running unchecked.
    private func checkToolWasHooked(_ toolName: String) {
        let bypassed = stateLock.withLock { () -> Bool in
            guard hookServer != nil else { return false }
            hookedToolSteps += 1
            return hookedToolSteps > hookRequestCount
        }
        guard bypassed else { return }
        Log.write("antigravity: \(toolName) ran without a PreToolUse hook request; stopping")
        stopProcessAndCleanUp()
        finishTurn(with: .failure(
            "Antigravity ran \(toolName) without asking Cantrip first, so Cantrip stopped it. Check that "
                + "\(AntigravityHook.configFile.path) still has an enabled \"\(AntigravityHook.entryName)\" entry."
        ))
    }

    private func stopHookServer() {
        let server = stateLock.withLock { () -> AntigravityHookServer? in
            defer { hookServer = nil }
            return hookServer
        }
        server?.stop()
    }

    private func handleHookRequest(
        _ request: [String: Any],
        policy: HookPolicy,
        respond: @escaping AntigravityHookServer.Respond
    ) {
        let toolCall = request["toolCall"] as? [String: Any]
        guard let toolName = toolCall?["name"] as? String, !toolName.isEmpty else {
            respond("deny", "Cantrip couldn't read this tool call.")
            return
        }
        let args = (toolCall?["args"] as? [String: Any]) ?? [:]

        stateLock.lock()
        hookRequestCount += 1
        let workdir = activeWorkdir
        let callback = turnEventCallback
        stateLock.unlock()

        let activeGuardrail: CantripHomeGuardrail
        switch policy {
        case .readOnly:
            if AntigravityHook.isReadOnly(tool: toolName, arguments: args) {
                respond("allow", nil)
            } else {
                respond("deny", "Read-only session: look and report, but don't change anything.")
            }
            return
        case .ask:
            if AntigravityHook.isReadOnly(tool: toolName, arguments: args) {
                respond("allow", nil)
            } else {
                promptUserForHookTool(
                    toolName: toolName,
                    title: "Allow Antigravity to run \(toolName)?",
                    detail: ToolActivityFactory.detailText(args) ?? toolName,
                    scope: nil,
                    callback: callback,
                    respond: respond
                )
            }
            return
        case .guardrail(let mode):
            activeGuardrail = mode
        }

        let action = CantripHomeActionRequest(antigravityTool: toolName, input: args)
        let homeApproval = CantripHomeApproval.chosen(for: .antigravity, settings: settings)
        let decision = CantripHomeActionPolicy.evaluate(
            action,
            mode: activeGuardrail,
            approval: homeApproval,
            environment: .current(workdir: workdir)
        )

        switch decision.verdict {
        case .deny:
            Log.write("antigravity: Cantrip Home blocked \(toolName): \(decision.reason)")
            callback?(.approval(BackendApproval(
                tool: toolName,
                decision: "denied",
                decidedBy: "Cantrip Home policy"
            )))
            respond("deny", decision.reason)

        case .allow:
            if decision.automatic || homeApproval.runsWithoutAsking(action) {
                callback?(.approval(BackendApproval(
                    tool: toolName,
                    decision: "approved",
                    decidedBy: decision.automatic ? "Act on my behalf" : "Cantrip Home policy"
                )))
                respond("auto_approve", nil)
            } else {
                promptUserForHookTool(
                    toolName: toolName,
                    title: "Allow Antigravity to run \(toolName)?",
                    detail: ToolActivityFactory.detailText(args) ?? toolName,
                    scope: nil,
                    callback: callback,
                    respond: respond
                )
            }

        case .ask:
            let alreadyApproved = stateLock.withLock {
                !decision.scope.isEmpty && approvedGuardrailScopes.contains(decision.scope)
            }
            if alreadyApproved {
                callback?(.approval(BackendApproval(
                    tool: toolName,
                    decision: "approved",
                    decidedBy: "Earlier approval"
                )))
                respond("auto_approve", nil)
            } else {
                promptUserForHookTool(
                    toolName: toolName,
                    title: "\(guardrailLabel) wants to \(decision.action)",
                    detail: decision.detail,
                    scope: decision.scope,
                    callback: callback,
                    respond: respond
                )
            }
        }
    }

    private func promptUserForHookTool(
        toolName: String,
        title: String,
        detail: String,
        scope: String?,
        callback: ((BackendEvent) -> Void)?,
        respond: @escaping AntigravityHookServer.Respond
    ) {
        guard let callback else {
            respond("deny", "No one is here to approve this right now.")
            return
        }
        let request = BackendInputRequest(
            kind: .approval,
            source: guardrail != nil ? "Cantrip Home" : "Antigravity",
            title: title,
            detail: detail
        ) { [weak self] answer in
            if answer.decision == .approve {
                if let scope, !scope.isEmpty {
                    self?.stateLock.withLock {
                        _ = self?.approvedGuardrailScopes.insert(scope)
                    }
                }
                callback(.approval(BackendApproval(
                    tool: toolName,
                    decision: "approved",
                    decidedBy: "User"
                )))
                respond("auto_approve", nil)
            } else {
                callback(.approval(BackendApproval(
                    tool: toolName,
                    decision: "denied",
                    decidedBy: "User"
                )))
                respond("deny", "The user denied this action in Cantrip. Skip it and continue if possible.")
            }
        }
        registerInputRequest(request)
        callback(.inputRequired(request))
    }

    // MARK: - Pending Input Requests

    private func registerInputRequest(_ request: BackendInputRequest) {
        let id = request.snapshot.id
        stateLock.withLock { pendingInputRequests[id] = request }
        request.onResolved = { [weak self] in
            _ = self?.stateLock.withLock { self?.pendingInputRequests.removeValue(forKey: id) }
        }
    }

    private func cancelPendingInputRequests() {
        let requests = stateLock.withLock { () -> [BackendInputRequest] in
            let current = Array(pendingInputRequests.values)
            pendingInputRequests.removeAll()
            return current
        }
        requests.forEach { $0.cancel() }
    }
}

// MARK: - Antigravity Subagent Transcript Hydration

/// Reads and caches `~/.gemini/antigravity-cli/brain/<agentID>/.system_generated/logs/transcript.jsonl`
/// so background subagents spawned by `invoke_subagent` report their real runtime status, elapsed
/// duration, token usage, tool call steps, reasoning blocks, and final synthesis message.
enum AntigravitySubagentTranscript {
    struct Snapshot: Equatable {
        var startedAt: Date?
        var lastStepAt: Date?
        var summary: String?
        var tokens: Int = 0
        var children: [ToolActivity] = []
        var reasoning: [String] = []
        var intent: String?
        var latestMessage: String?
        var isCompleted: Bool = false
        var hasError: Bool = false
    }

    private struct CacheEntry {
        let fileSize: UInt64
        let modDate: Date
        let snapshot: Snapshot
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    private static let conversationLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\[\]\n]{1,200})\]\(conversation://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    /// Reconstructs subagent activities from `conversation://<uuid>` references in an assistant
    /// message when runtime activities were not persisted across a Cantrip restart.
    static func reconstructedActivities(fromText text: String) -> [ToolActivity] {
        guard text.contains("](conversation://") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [ToolActivity] = []
        for match in conversationLinkRegex.matches(in: text, range: whole) {
            guard let labelRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text) else { continue }
            let agentID = String(text[idRange]).lowercased()
            guard !seen.contains(agentID), transcriptURL(for: agentID) != nil else { continue }
            seen.insert(agentID)
            let rawName = String(text[labelRange])
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var info = SubagentInfo(
                agentID: agentID,
                name: rawName.isEmpty ? "Subagent" : rawName,
                agentType: "self",
                summary: "",
                status: .completed,
                startedAt: Date()
            )
            var children: [ToolActivity] = []
            _ = hydrate(&info, children: &children, forceComplete: true)
            result.append(AntigravityBackend.subagentActivity(for: info, children: children))
        }
        return result
    }

    static func enriched(_ activity: ToolActivity) -> ToolActivity {
        var activity = activity
        if activity.subagent == nil,
           activity.id.hasPrefix("subagent-"),
           activity.toolName == "Subagent" {
            let agentID = String(activity.id.dropFirst("subagent-".count))
            activity.subagent = SubagentInfo(
                agentID: agentID,
                name: activity.title,
                agentType: "self",
                summary: activity.input ?? "",
                status: activity.state == .running ? .running : .completed,
                startedAt: Date()
            )
        }
        guard var info = activity.subagent, !info.agentID.isEmpty else { return activity }
        var children = activity.children
        let forceComplete = !info.isActive
        guard hydrate(&info, children: &children, forceComplete: forceComplete)
                || children.count != activity.children.count
                || info != activity.subagent else {
            return activity
        }
        activity.subagent = info
        activity.children = children
        activity.state = ToolActivityState(info.status)
        if !info.summary.isEmpty { activity.input = info.summary }
        if let latest = info.latestMessage { activity.output = latest }
        return activity
    }

    @discardableResult
    static func hydrate(
        _ info: inout SubagentInfo,
        children: inout [ToolActivity],
        forceComplete: Bool
    ) -> Bool {
        guard let snap = snapshot(for: info.agentID) else { return false }
        let beforeInfo = info
        let beforeChildren = children

        if let started = snap.startedAt {
            info.startedAt = started
        }
        if let summary = snap.summary,
           !summary.isEmpty,
           info.summary.isEmpty || info.summary.hasPrefix("Created the following subagent") {
            info.summary = summary
        }
        if snap.tokens > 0 {
            info.tokens = snap.tokens
        }
        if !snap.children.isEmpty {
            children = snap.children
            info.toolCalls = snap.children.count
        }
        if !snap.reasoning.isEmpty {
            info.reasoning = snap.reasoning
        }
        if let intent = snap.intent, !intent.isEmpty {
            info.intent = intent
        }
        if let latest = snap.latestMessage, !latest.isEmpty {
            info.latestMessage = latest
        }
        if snap.hasError {
            info.status = .failed
            info.finishedAt = snap.lastStepAt ?? info.finishedAt ?? Date()
        } else if snap.isCompleted || forceComplete {
            info.status = .completed
            info.finishedAt = snap.lastStepAt ?? info.finishedAt ?? Date()
        }
        return info != beforeInfo || children != beforeChildren
    }

    private static func transcriptURL(for agentID: String) -> URL? {
        let trimmed = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("..") else { return nil }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".gemini/antigravity-cli/brain/\(trimmed)/.system_generated/logs/transcript.jsonl"),
            home.appendingPathComponent(".gemini/antigravity/brain/\(trimmed)/.system_generated/logs/transcript.jsonl"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func snapshot(for agentID: String) -> Snapshot? {
        guard let url = transcriptURL(for: agentID),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date,
              size > 0 else {
            return nil
        }

        lock.lock()
        if let cached = cache[agentID], cached.fileSize == size, cached.modDate == modDate {
            lock.unlock()
            return cached.snapshot
        }
        lock.unlock()

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parsed = parseTranscript(text, agentID: agentID)
        lock.lock()
        cache[agentID] = CacheEntry(fileSize: size, modDate: modDate, snapshot: parsed)
        lock.unlock()
        return parsed
    }

    private static func parseTranscript(_ text: String, agentID: String) -> Snapshot {
        var snap = Snapshot()
        let iso = ISO8601DateFormatter()
        let lines = text.split(whereSeparator: \.isNewline)

        var pendingToolIndices: [Int] = []
        var sentMessageToParent = false
        var lastStepWasFinalResponse = false

        for rawLine in lines {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }

            let stepIndex = obj["step_index"] as? Int ?? snap.children.count
            let type = (obj["type"] as? String ?? "").uppercased()
            let status = (obj["status"] as? String ?? "").uppercased()
            if let createdStr = obj["created_at"] as? String,
               let date = iso.date(from: createdStr) {
                if snap.startedAt == nil { snap.startedAt = date }
                snap.lastStepAt = date
            }

            if type == "SYSTEM_MESSAGE", snap.summary == nil,
               let content = obj["content"] as? String,
               let range = content.range(of: "content=") {
                var body = String(content[range.upperBound...])
                if let endRange = body.range(of: "</SYSTEM_MESSAGE>") {
                    body = String(body[..<endRange.lowerBound])
                }
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    snap.summary = SubagentInfo.clipped(body, limit: 400)
                }
            }

            if type == "PLANNER_RESPONSE" {
                let inputTokens = (obj["input_tokens"] as? Int) ?? 0
                let outputTokens = (obj["output_tokens"] as? Int) ?? 0
                snap.tokens += inputTokens + outputTokens

                if let thinking = obj["thinking"] as? String {
                    let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        snap.reasoning.append(trimmed)
                        if let title = ReasoningStep.steps(from: [trimmed]).last?.title {
                            snap.intent = title
                        }
                    }
                }

                let toolCalls = (obj["tool_calls"] as? [[String: Any]]) ?? []
                pendingToolIndices.removeAll()

                if !toolCalls.isEmpty {
                    lastStepWasFinalResponse = false
                    for (tIdx, tc) in toolCalls.enumerated() {
                        let toolName = (tc["name"] as? String) ?? "Tool"
                        let rawArgs = (tc["args"] as? [String: Any]) ?? [:]
                        let cleanedArgs = cleanTranscriptArgs(rawArgs)

                        if toolName == "send_message",
                           let msg = cleanedArgs["Message"] as? String,
                           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            snap.latestMessage = TabMentions.stripConversationLinks(msg)
                            sentMessageToParent = true
                        }

                        var activity = ToolActivityFactory.start(
                            id: "sub-\(agentID.prefix(8))-\(stepIndex)-\(tIdx)",
                            toolName: toolName,
                            arguments: cleanedArgs
                        )
                        if status == "DONE" {
                            activity.state = .succeeded
                        } else if status == "ERROR" {
                            activity.state = .failed
                        }
                        snap.intent = activity.title
                        pendingToolIndices.append(snap.children.count)
                        snap.children.append(activity)
                    }
                } else if let content = obj["content"] as? String {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if snap.latestMessage == nil {
                            snap.latestMessage = TabMentions.stripConversationLinks(trimmed)
                        }
                        if status == "DONE" {
                            lastStepWasFinalResponse = true
                        }
                    }
                }
            } else if type == "GENERIC" {
                let output = obj["content"] ?? obj["error"]
                let hasError = obj["error"] != nil && !(obj["error"] is NSNull)
                if let idx = pendingToolIndices.first, idx < snap.children.count {
                    pendingToolIndices.removeFirst()
                    let existing = snap.children[idx]
                    snap.children[idx] = ToolActivityFactory.complete(
                        existing,
                        id: existing.id,
                        toolName: existing.toolName,
                        success: !hasError && status != "ERROR",
                        output: output
                    )
                }
            }
        }

        snap.isCompleted = sentMessageToParent || lastStepWasFinalResponse
        return snap
    }

    private static func cleanTranscriptArgs(_ raw: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (key, value) in raw {
            if let str = value as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"",
                   let data = trimmed.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(String.self, from: data) {
                    cleaned[key] = decoded
                } else {
                    cleaned[key] = str
                }
            } else {
                cleaned[key] = value
            }
        }
        return cleaned
    }
}
