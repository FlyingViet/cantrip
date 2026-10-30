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
        // Clear legacy backoff when an older build failed only because Antigravity wasn't a
        // consolidation candidate yet.
        var state = ConsolidationState.load(from: .standard)
        if state.failures > 0,
           state.lastError?.contains("Copilot CLI wasn't found to fall back to") == true,
           AppSettings.shared.agyMemoryConsolidation,
           AntigravityBackend.isInstalled(customPath: AppSettings.shared.agyPath) {
            state.failures = 0
            state.lastError = nil
            state.nextRetry = nil
            state.save(to: .standard)
        }
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
        let agyAllowActions = settings.allowActions || settings.agyPermissionMode == "bypassPermissions"
        // Memory stays on Cantrip's own pass unless the user opts in to Antigravity for it.
        let agyPath: String? = settings.agyMemoryConsolidation ? settings.agyPath : nil
        let agyModels = settings.agyAvailableModels
        let claudePath = settings.claudePath
        let copilotPath = settings.copilotPath
        let copilotModels = settings.copilotModelCatalog.map(\.id)
        let prompt = prompt(vault: vault)

        DispatchQueue.global(qos: .utility).async {
            let candidates = ConsolidationBackend.candidates(
                antigravity: agyPath.flatMap { AntigravityBackend.resolveExecutable(customPath: $0) },
                antigravityModels: agyModels,
                preferAntigravity: true,
                claude: ToolLocator.shared.claude(configured: claudePath),
                copilot: ToolLocator.shared.copilot(configured: copilotPath),
                copilotModels: copilotModels
            )
            let outcome = ConsolidationAttempt.execute(candidates) { backend in
                if case .antigravity = backend {
                    return run(backend, prompt: prompt, allowActions: agyAllowActions, vault: vault)
                }
                return run(backend, prompt: prompt, allowActions: allowActions, vault: vault)
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
                    let retry = state.nextRetry.map { ISODate.string(from: $0) } ?? "-"
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
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        environment["NO_COLOR"] = "1"
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                backend.executable, backend.arguments(prompt: prompt, allowActions: allowActions),
                environment: environment, directory: URL(fileURLWithPath: vault), errorOutput: .merge,
                timeout: timeout, killAfter: 10, outputLimit: 1_000_000,
                launched: { Log.write("consolidator: started \(backend.name) (pid \($0.processIdentifier))") }
            )
        } catch {
            return .init(status: -1, output: "",
                         launchError: "couldn't start \(backend.executable): \(error.localizedDescription)")
        }
        var text = String(decoding: result.output, as: UTF8.self)
        if result.timedOut { text += "\nTimed out after \(Int(timeout / 60)) minutes." }
        let status = result.status
        Log.write("consolidator: \(backend.name) exit \(status) — \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        return .init(status: result.timedOut && status == 0 ? -1 : status, output: text)
    }
}
