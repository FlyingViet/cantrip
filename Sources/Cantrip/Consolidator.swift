import Foundation

/// Background memory consolidation (Hermes-style reflection): about once a day a cheap headless
/// run distills recent session logs into MEMORY.md / USER.md / procedure notes and prunes stale
/// content. Claude Code (Haiku) runs it; when Claude is missing or can't sign in, the Copilot CLI
/// does. Only a successful run moves the daily stamp; failures retry with backoff and show above
/// Cantrip Home's tasks (see `ConsolidationState`).
enum Consolidator {
    /// How often the host checks whether a run (or a retry) is due.
    static let checkInterval: TimeInterval = 15 * 60
    /// A run still going after this long is stopped and counted as a failure.
    static let timeout: TimeInterval = 30 * 60
    /// Main thread only.
    private static var running = false
    private static var timer: Timer?

    /// Checks 15 s after launch, then every `checkInterval`. Main thread.
    static func start() {
        ConsolidationState.migrateLegacyStamp(in: .standard)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { runIfDue() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in runIfDue() }
    }

    /// The warning Cantrip Home shows above its tasks while consolidation keeps failing.
    static var healthWarning: String? {
        ConsolidationState.load(from: .standard).warning(memoryEnabled: AppSettings.shared.memoryEnabled)
    }

    static func runIfDue() {
        dispatchPrecondition(condition: .onQueue(.main))
        let settings = AppSettings.shared
        guard settings.memoryEnabled, !running else { return }
        let defaults = UserDefaults.standard
        guard ConsolidationState.load(from: defaults).isDue(now: Date()) else { return }
        running = true
        MemoryStore.shared.ensureVault()
        let vault = settings.memoryPath
        let allowActions = settings.allowActions
        let claudePath = settings.claudePath
        let copilotPath = settings.copilotPath
        let copilotModels = settings.copilotModelCatalog.map(\.id)
        let prompt = prompt(vault: vault)

        DispatchQueue.global(qos: .utility).async {
            let candidates = ConsolidationBackend.candidates(
                claude: ClaudeCodeBackend.findClaude(configured: claudePath),
                copilot: findCopilot(configured: copilotPath),
                copilotModels: copilotModels
            )
            let outcome = ConsolidationAttempt.execute(candidates) { backend in
                run(backend, prompt: prompt, allowActions: allowActions, vault: vault)
            }
            DispatchQueue.main.async {
                running = false
                var state = ConsolidationState.load(from: defaults)
                if outcome.succeeded, let backend = outcome.backend {
                    state.recordSuccess(backend: backend, at: Date())
                    Log.write("consolidator: succeeded via \(backend) — \(outcome.summary.prefix(300))")
                } else {
                    let error = outcome.error ?? "Memory consolidation failed."
                    state.recordFailure(error, at: Date())
                    let retry = state.nextRetry.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                    Log.write("consolidator: failed (\(state.failures) in a row, next try \(retry)) — \(error)")
                }
                state.save(to: defaults)
            }
        }
    }

    private static func prompt(vault: String) -> String {
        """
        You are Cantrip's background memory consolidator. Working \
        directory is the memory vault (\(vault)). Do the following, then \
        reply with ONE line summarizing what changed:
        1. Read sessions/*.md logs from the last 3 days (skip if none).
        2. Update MEMORY.md (environment/conventions, HARD CAP \(MemoryStore.memoryCap) \
        chars) and USER.md (user model, HARD CAP \(MemoryStore.userCap) chars): add \
        durable facts learned in sessions but not yet saved; merge duplicates; \
        drop stale entries. Consolidate — never exceed the caps.
        3. Review the other *.md procedure notes: merge overlapping ones and \
        update any contradicted by newer sessions. Notes marked [stale?] in \
        past prompts deserve scrutiny.
        4. Delete sessions/ files older than 30 days.
        """
    }

    /// Runs one backend to completion (or `timeout`), collecting at most 1 MB of output.
    private static func run(_ backend: ConsolidationBackend, prompt: String, allowActions: Bool,
                            vault: String) -> ConsolidationAttempt.RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: backend.executable)
        process.arguments = backend.arguments(prompt: prompt, allowActions: allowActions)
        process.currentDirectoryURL = URL(fileURLWithPath: vault)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let lock = NSLock()
        var output = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // At end of file the handler keeps firing with empty data until it's removed.
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            lock.withLock { if output.count < 1_000_000 { output.append(chunk) } }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .init(status: -1, output: "",
                         launchError: "couldn't start \(backend.executable): \(error.localizedDescription)")
        }
        Log.write("consolidator: started \(backend.name) (pid \(process.processIdentifier))")
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 10) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        // Let the last chunk land; a lingering child can hold the pipe open, so don't read to EOF.
        Thread.sleep(forTimeInterval: 0.3)
        pipe.fileHandleForReading.readabilityHandler = nil
        var text = lock.withLock { String(decoding: output, as: UTF8.self) }
        if timedOut { text += "\nTimed out after \(Int(timeout / 60)) minutes." }
        let status = process.isRunning ? -1 : process.terminationStatus
        Log.write("consolidator: \(backend.name) exit \(status) — \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        return .init(status: timedOut && status == 0 ? -1 : status, output: text)
    }

    /// The `copilot` CLI: the configured path, a usual install location, or the login shell's PATH.
    static func findCopilot(configured raw: String) -> String? {
        let configured = raw.trimmingCharacters(in: .whitespaces)
        if configured.contains("/") { return configured }
        let name = configured.isEmpty ? "copilot" : configured
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "\(NSHomeDirectory())/.npm-global/bin/\(name)",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-l", "-c", "command -v \"$1\"", "cantrip", name]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        do { try shell.run() } catch { return nil }
        shell.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.hasPrefix("/") ? found : nil
    }
}
