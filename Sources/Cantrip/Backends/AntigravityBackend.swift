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
/// - For Cantrip Home (`guardrail != nil`), a `PreToolUse` command hook is registered in
///   `<workdir>/.agents/hooks.json` that calls back into Cantrip over a local Unix domain socket
///   and returns `auto_approve` or `deny`.
final class AntigravityBackend: Backend, CantripHomeGuardedBackend {
    private static let hookEntryKey = "cantrip-home-guardrail"

    private let settings = AppSettings.shared
    private let persistKey: String
    private let readOnly: Bool
    private let modelOverride: String?
    private let effortOverride: String?
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

    // PreToolUse hook server state for Cantrip Home.
    private var hookDirectory: String?
    private var hookSocketFD: Int32 = -1
    private var hookAcceptSource: DispatchSourceRead?
    private var installedHooksFile: String?
    private var createdHooksFile = false

    private let ioQueue = DispatchQueue(label: "cantrip.antigravity.io", qos: .userInitiated)

    init(
        persistKey: String = "agySessionID",
        readOnly: Bool = false,
        modelOverride: String? = nil,
        effortOverride: String? = nil
    ) {
        self.persistKey = persistKey
        self.readOnly = readOnly
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
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
        let mode = settings.agyPermissionMode
        if guardrail != nil {
            // Cantrip Home gates every tool call through the PreToolUse command hook.
            if mode == "sandbox" {
                args.append("--sandbox")
            }
        } else if readOnly || !settings.allowActions {
            // Headless `agy` soft-denies shell commands by default; honor explicit sandbox mode if set.
            if mode == "sandbox" {
                args.append("--sandbox")
            }
        } else {
            switch mode {
            case "bypassPermissions":
                args.append("--dangerously-skip-permissions")
            case "sandbox":
                args.append("--sandbox")
            default:
                break
            }
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

        if guardrail != nil {
            try startHookServer(workdir: workdir)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = buildArguments(resumingSessionID: resumeID)
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)

        var env = ToolPath.environment()
        env["NO_COLOR"] = "1"
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
        stdoutRemainder.removeAll(keepingCapacity: true)
        stateLock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async {
                self?.consumeStdout(chunk)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.stateLock.lock()
            if self.stderrCollected.count < 32_768 {
                self.stderrCollected.append(chunk)
            }
            self.stateLock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.ioQueue.async {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let trailing = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailing.isEmpty {
                    self.consumeStdout(trailing)
                }
                let trailingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailingErr.isEmpty {
                    self.stateLock.lock()
                    if self.stderrCollected.count < 32_768 {
                        self.stderrCollected.append(trailingErr)
                    }
                    self.stateLock.unlock()
                }
                self.handleProcessExit(proc)
            }
        }

        try process.run()
    }

    private func handleProcessExit(_ process: Process) {
        stateLock.lock()
        let isCurrent = (currentProcess === process)
        if isCurrent {
            currentProcess = nil
            stdinHandle = nil
            activeLaunchSignature = ""
        }
        let shouldFinishTurn = turnInFlight && !turnCompleted
        let stderrText = String(data: stderrCollected, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stateLock.unlock()

        if isCurrent {
            stopHookServer()
        }

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

    private func consumeStdout(_ chunk: Data) {
        var lines: [Data] = []
        stateLock.lock()
        stdoutRemainder.append(chunk)
        while let newline = stdoutRemainder.firstIndex(of: 0x0A) {
            let line = stdoutRemainder.subdata(in: stdoutRemainder.startIndex..<newline)
            stdoutRemainder.removeSubrange(stdoutRemainder.startIndex...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        stateLock.unlock()

        for line in lines {
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

    // MARK: - Cantrip Home PreToolUse Hook Server

    private func startHookServer(workdir: String) throws {
        stopHookServer()

        let fm = FileManager.default
        let dirURL = fm.temporaryDirectory.appendingPathComponent("ct-agy-\(UUID().uuidString.prefix(12))")
        let dirPath = dirURL.path
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let socketPath = dirURL.appendingPathComponent("hook.sock").path
        let scriptPath = dirURL.appendingPathComponent("hook.py").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(addrLen)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            let code = Int(errno)
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let hookScript = """
        #!/usr/bin/env python3
        import json, socket, sys

        sock_path = \(Self.jsonStringLiteral(socketPath))
        try:
            payload = sys.stdin.read()
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(600.0)
            s.connect(sock_path)
            s.sendall(payload.encode("utf-8") + b"\\n")
            s.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                data = s.recv(4096)
                if not data:
                    break
                chunks.append(data)
            s.close()
            resp = b"".join(chunks).decode("utf-8").strip()
            if resp:
                print(resp)
            else:
                print(json.dumps({"decision": "deny", "reason": "Empty response from Cantrip Home guardrail hook."}))
        except Exception as exc:
            print(json.dumps({"decision": "deny", "reason": f"Cantrip Home guardrail hook failed: {exc}"}))
        """
        try hookScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)

        let acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        acceptSource.setEventHandler { [weak self] in
            self?.acceptHookConnection(serverFD: fd)
        }
        acceptSource.setCancelHandler {
            close(fd)
        }
        acceptSource.resume()

        try registerWorkspaceHook(workdir: workdir, commandPath: scriptPath)

        stateLock.lock()
        hookDirectory = dirPath
        hookSocketFD = fd
        hookAcceptSource = acceptSource
        stateLock.unlock()
    }

    private func stopHookServer() {
        stateLock.lock()
        let source = hookAcceptSource
        let dir = hookDirectory
        let hooksFile = installedHooksFile
        let createdFile = createdHooksFile
        hookAcceptSource = nil
        hookSocketFD = -1
        hookDirectory = nil
        installedHooksFile = nil
        createdHooksFile = false
        stateLock.unlock()

        source?.cancel()
        if let hooksFile {
            unregisterWorkspaceHook(hooksFile: hooksFile, createdFile: createdFile)
        }
        if let dir {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    private func registerWorkspaceHook(workdir: String, commandPath: String) throws {
        let fm = FileManager.default
        let agentsDir = "\(workdir)/.agents"
        let hooksFile = "\(agentsDir)/hooks.json"
        let existed = fm.fileExists(atPath: hooksFile)
        try fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if existed,
           let data = try? Data(contentsOf: URL(fileURLWithPath: hooksFile)),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }

        root[Self.hookEntryKey] = [
            "enabled": true,
            "PreToolUse": [
                [
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": commandPath,
                            "timeout": 600,
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
        ] as [String: Any]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: hooksFile), options: .atomic)

        stateLock.lock()
        installedHooksFile = hooksFile
        createdHooksFile = !existed
        stateLock.unlock()
    }

    private func unregisterWorkspaceHook(hooksFile: String, createdFile: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hooksFile) else { return }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: hooksFile)),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root.removeValue(forKey: Self.hookEntryKey)
            if root.isEmpty && createdFile {
                try? fm.removeItem(atPath: hooksFile)
            } else if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: URL(fileURLWithPath: hooksFile), options: .atomic)
            }
        } else if createdFile {
            try? fm.removeItem(atPath: hooksFile)
        }
    }

    private func acceptHookConnection(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &len)
                }
            }
            guard clientFD >= 0 else { break }
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            var noSignal: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(clientFD, &chunk, chunk.count)
                    if n <= 0 { break }
                    buffer.append(chunk, count: n)
                }
                guard let self else {
                    Self.writeHookResponse(fd: clientFD, decision: "deny", reason: "Cantrip session ended.")
                    return
                }
                self.handleHookPayload(buffer, clientFD: clientFD)
            }
        }
    }

    private func handleHookPayload(_ data: Data, clientFD: Int32) {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let trimmed = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else {
            Self.writeHookResponse(fd: clientFD, decision: "deny", reason: "Malformed PreToolUse hook payload.")
            return
        }
        let toolCall = json["toolCall"] as? [String: Any]
        guard let toolName = (toolCall?["name"] as? String) ?? (json["tool_name"] as? String) else {
            Self.writeHookResponse(fd: clientFD, decision: "deny", reason: "Malformed PreToolUse hook payload.")
            return
        }
        let args = (toolCall?["args"] as? [String: Any])
            ?? (toolCall?["parameters"] as? [String: Any])
            ?? (json["tool_input"] as? [String: Any])
            ?? [:]

        stateLock.lock()
        let activeGuardrail = guardrail
        let workdir = activeWorkdir
        let callback = turnEventCallback
        stateLock.unlock()

        guard let activeGuardrail else {
            Self.writeHookResponse(fd: clientFD, decision: "auto_approve", reason: nil)
            return
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
            Self.writeHookResponse(fd: clientFD, decision: "deny", reason: decision.reason)

        case .allow:
            if decision.automatic || homeApproval.runsWithoutAsking(action) {
                callback?(.approval(BackendApproval(
                    tool: toolName,
                    decision: "approved",
                    decidedBy: decision.automatic ? "Act on my behalf" : "Cantrip Home policy"
                )))
                Self.writeHookResponse(fd: clientFD, decision: "auto_approve", reason: nil)
            } else {
                promptUserForHookTool(
                    toolName: toolName,
                    title: "Allow Antigravity to run \(toolName)?",
                    detail: ToolActivityFactory.detailText(args) ?? toolName,
                    scope: nil,
                    callback: callback,
                    clientFD: clientFD
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
                Self.writeHookResponse(fd: clientFD, decision: "auto_approve", reason: nil)
            } else {
                promptUserForHookTool(
                    toolName: toolName,
                    title: "\(guardrailLabel) wants to \(decision.action)",
                    detail: decision.detail,
                    scope: decision.scope,
                    callback: callback,
                    clientFD: clientFD
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
        clientFD: Int32
    ) {
        guard let callback else {
            Self.writeHookResponse(fd: clientFD, decision: "deny", reason: "No active session to prompt for approval.")
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
                Self.writeHookResponse(fd: clientFD, decision: "auto_approve", reason: nil)
            } else {
                callback(.approval(BackendApproval(
                    tool: toolName,
                    decision: "denied",
                    decidedBy: "User"
                )))
                Self.writeHookResponse(
                    fd: clientFD,
                    decision: "deny",
                    reason: "The user denied this action in Cantrip. Skip it and continue if possible."
                )
            }
        }
        registerInputRequest(request)
        callback(.inputRequired(request))
    }

    private static func writeHookResponse(fd: Int32, decision: String, reason: String?) {
        var payload: [String: Any] = ["decision": decision]
        if let reason, !reason.isEmpty {
            payload["reason"] = reason
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            var line = data
            line.append(0x0A)
            line.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                _ = write(fd, base, rawBuf.count)
            }
        }
        close(fd)
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8),
              str.count >= 2 else {
            return "\"\(value)\""
        }
        return String(str.dropFirst().dropLast())
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
