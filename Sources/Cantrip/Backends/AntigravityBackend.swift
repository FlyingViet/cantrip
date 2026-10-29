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
    var modelOverride: String? {
        get { overrideLock.withLock { storedModelOverride } }
        set { overrideLock.withLock { storedModelOverride = newValue } }
    }
    var effortOverride: String? {
        get { overrideLock.withLock { storedEffortOverride } }
        set { overrideLock.withLock { storedEffortOverride = newValue } }
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
        let model = (modelOverride ?? settings.agyModel).trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            args += ["--model", model]
        }
        let effort = (effortOverride ?? settings.agyEffort).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.supportedEfforts.contains(effort) {
            args += ["--effort", effort]
        }
        // Headless agy allows file edits inside the workspace on its own, so anything short of
        // "may do anything" is decided by Cantrip's PreToolUse hook instead.
        if hookPolicy == nil {
            args.append("--dangerously-skip-permissions")
        }
        if settings.agyPermissionMode == "sandbox" {
            args.append("--sandbox")
        }
        return args
    }

    private func launchSignature(for workdir: String) -> String {
        let model = (modelOverride ?? settings.agyModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = (effortOverride ?? settings.agyEffort).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let guardrailKey = guardrail?.rawValue ?? "none"
        return "\(workdir)|\(model)|\(effort)|\(readOnly)|\(settings.allowActions)|\(settings.agyPermissionMode)|\(guardrailKey)"
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
        stderrCollected.removeAll(keepingCapacity: true)
        stateLock.unlock()

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
        activeSubagents.removeAll()
        stateLock.unlock()

        guard let callback else { return }
        for var tool in remainingTools where tool.state == .running {
            tool.state = .succeeded
            callback(.activity(tool))
        }
        for var sub in remainingSubagents where sub.status == .running {
            sub.status = .completed
            sub.finishedAt = Date()
            callback(.activity(Self.subagentActivity(for: sub)))
        }
        callback(terminalEvent)
    }

    private func stopProcessAndCleanUp() {
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
        let errorValue = toolInfo?["error"]
        let hasError = (errorValue != nil && !(errorValue is NSNull))
        let outputText = toolInfo?["output"] as? String

        for (idx, item) in subagents.enumerated() {
            let id = (item["conversation_id"] as? String)
                ?? stepIndex.map { "subagent-\($0)-\(idx)" }
                ?? "subagent-\(idx)"
            let role = (item["role"] as? String)
                ?? (idx < paramSpecs.count ? paramSpecs[idx]["Role"] as? String : nil)
                ?? ""
            let typeName = (item["type_name"] as? String)
                ?? (idx < paramSpecs.count ? paramSpecs[idx]["TypeName"] as? String : nil)
                ?? "subagent"
            let prompt = (idx < paramSpecs.count ? paramSpecs[idx]["Prompt"] as? String : nil)

            stateLock.lock()
            var info = activeSubagents[id] ?? SubagentInfo(
                agentID: id,
                name: role.isEmpty ? typeName : role,
                agentType: typeName,
                summary: SubagentInfo.clipped(prompt ?? "", limit: 400) ?? "",
                status: .running,
                startedAt: Date()
            )
            if state == "DONE" {
                info.status = hasError ? .failed : .completed
                info.finishedAt = Date()
                if let outputText, !outputText.isEmpty,
                   let clipped = SubagentInfo.clipped(outputText, limit: 400) {
                    info.summary = clipped
                }
                activeSubagents.removeValue(forKey: id)
            } else {
                info.status = .running
                activeSubagents[id] = info
            }
            stateLock.unlock()

            let activity = Self.subagentActivity(for: info)
            callback(.activity(activity))
            if state == "ACTIVE" {
                callback(.status("Running \(info.displayName)"))
            }
        }
    }

    private static func subagentActivity(for info: SubagentInfo) -> ToolActivity {
        var activity = ToolActivity(
            id: "subagent-\(info.agentID)",
            title: info.displayName,
            toolName: "Subagent",
            state: ToolActivityState(info.status),
            input: info.summary.isEmpty ? nil : info.summary,
            output: info.latestMessage,
            fileChanges: []
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
