import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

// MARK: Stamping and backoff

do {
    var state = ConsolidationState()
    expect(state.isDue(now: start), "a vault never consolidated is due")

    state.recordFailure("Claude Code can't run (OAuth session expired).", at: start)
    expect(state.lastSuccess == nil, "a failed run never stamps lastConsolidation")
    expect(state.failures == 1 && state.lastError?.contains("OAuth") == true, "the failure and its text are kept")
    expect(state.nextRetry == start.addingTimeInterval(30 * 60), "the first retry waits 30 minutes")
    expect(!state.isDue(now: start.addingTimeInterval(29 * 60)), "no retry before the backoff ends")
    expect(state.isDue(now: start.addingTimeInterval(30 * 60)), "a retry is due once the backoff ends")

    state.recordFailure("again", at: start.addingTimeInterval(hour))
    expect(state.nextRetry == start.addingTimeInterval(2 * hour), "the second failure waits an hour")
    for _ in 0..<10 { state.recordFailure("again", at: start) }
    expect(state.nextRetry == start.addingTimeInterval(12 * hour), "backoff stops growing at 12 hours")
    expect(ConsolidationState.backoff(afterFailures: 3) == 2 * hour, "backoff doubles each failure")

    let succeeded = start.addingTimeInterval(13 * hour)
    state.recordSuccess(backend: "Copilot", at: succeeded)
    expect(state.lastSuccess == succeeded && state.failures == 0 && state.lastError == nil && state.nextRetry == nil,
           "success stamps the run and clears the failure streak")
    expect(state.lastBackend == "Copilot", "the backend that succeeded is remembered")
    expect(!state.isDue(now: succeeded.addingTimeInterval(19 * hour)), "a success covers 20 hours")
    expect(state.isDue(now: succeeded.addingTimeInterval(20 * hour + 1)), "the next run is due after 20 hours")
}

// MARK: Warning shown in Cantrip Home

do {
    var state = ConsolidationState()
    expect(state.warning(memoryEnabled: true) == nil, "no warning before any failure")
    state.recordFailure("Claude Code can't run (Failed to authenticate: OAuth session expired); the GitHub Copilot CLI wasn't found to fall back to.", at: start)
    state.recordFailure(String(repeating: "x", count: 1000), at: start)
    let warning = state.warning(memoryEnabled: true, timeZone: TimeZone(identifier: "UTC")!) ?? ""
    expect(warning.hasPrefix("Memory consolidation failed (2 attempts): "), "the warning counts attempts: \(warning)")
    expect(warning.contains("Next try"), "the warning says when it retries")
    expect(warning.count < 420, "long errors are clipped in the warning")
    expect(state.warning(memoryEnabled: false) == nil, "no warning while the memory vault is off")
    state.recordSuccess(backend: "Claude Code", at: start)
    expect(state.warning(memoryEnabled: true) == nil, "success clears the warning")
}

// MARK: Persistence and the legacy stamp

do {
    let suite = "cantrip-consolidation-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // Older builds stamped each run as it started, even runs that then failed.
    defaults.set(start, forKey: "lastConsolidation")
    ConsolidationState.migrateLegacyStamp(in: defaults)
    expect(ConsolidationState.load(from: defaults).lastSuccess == nil, "a legacy start stamp is not trusted")
    expect(ConsolidationState.load(from: defaults).isDue(now: start), "the first check after updating runs")

    var state = ConsolidationState.load(from: defaults)
    state.recordFailure("boom", at: start)
    state.save(to: defaults)
    expect(defaults.object(forKey: "lastConsolidation") == nil, "a saved failure leaves lastConsolidation unset")
    var loaded = ConsolidationState.load(from: defaults)
    expect(loaded == state, "failure state round-trips through defaults")

    loaded.recordSuccess(backend: "Claude Code", at: start.addingTimeInterval(hour))
    loaded.save(to: defaults)
    expect(defaults.object(forKey: "lastConsolidation") as? Date == start.addingTimeInterval(hour),
           "lastConsolidation is written after a success")
    expect(defaults.object(forKey: "consolidationFailures") == nil && defaults.object(forKey: "consolidationLastError") == nil,
           "success removes the stored failure")
    ConsolidationState.migrateLegacyStamp(in: defaults)
    expect(ConsolidationState.load(from: defaults).lastSuccess == start.addingTimeInterval(hour),
           "the migration runs once and keeps real success stamps")
}

// MARK: Backend selection and fallback

do {
    let models = ["auto", "claude-sonnet-5.5", "claude-haiku-4.5", "claude-haiku-5.5", "gpt-6-luna"]
    expect(ConsolidationBackend.preferredCopilotModel(models) == "claude-haiku-5.5", "Copilot runs the newest Haiku")
    expect(ConsolidationBackend.preferredCopilotModel(["auto", "gpt-6-luna"]) == nil, "without a Haiku, the CLI default model runs")

    let both = ConsolidationBackend.candidates(claude: "/c/claude", copilot: "/c/copilot", copilotModels: models)
    expect(both == [.claude(path: "/c/claude"), .copilot(path: "/c/copilot", model: "claude-haiku-5.5")],
           "Claude Code runs first and Copilot is the fallback")
    expect(ConsolidationBackend.candidates(claude: nil, copilot: "/c/copilot", copilotModels: [])
            == [.copilot(path: "/c/copilot", model: nil)], "without Claude Code, Copilot runs")
    expect(ConsolidationBackend.candidates(claude: nil, copilot: nil, copilotModels: models).isEmpty, "no CLI, no candidates")

    let expired = "Failed to authenticate: OAuth session expired and could not be refreshed"
    expect(ConsolidationBackend.isAuthenticationFailure(expired), "an expired OAuth session is a sign-in failure")
    expect(ConsolidationBackend.isAuthenticationFailure("Invalid API key · Please run /login"), "an invalid key is a sign-in failure")
    expect(!ConsolidationBackend.isAuthenticationFailure("Error: model overloaded, try again"), "other errors are not sign-in failures")

    typealias Result = ConsolidationAttempt.RunResult
    var ran: [String] = []
    let fellBack = ConsolidationAttempt.execute(both) { backend in
        ran.append(backend.name)
        return backend.name == "Claude Code" ? Result(status: 1, output: expired) : Result(status: 0, output: "Merged 3 notes.\n")
    }
    expect(ran == ["Claude Code", "Copilot"], "a Claude sign-in failure falls back to Copilot")
    expect(fellBack == ConsolidationOutcome(succeeded: true, backend: "Copilot", summary: "Merged 3 notes.", error: nil),
           "the fallback's success counts as the run's: \(fellBack)")

    ran = []
    let bothFailed = ConsolidationAttempt.execute(both) { backend in
        ran.append(backend.name)
        return backend.name == "Claude Code" ? Result(status: 1, output: expired) : Result(status: 1, output: "Error: Copilot quota exhausted")
    }
    expect(!bothFailed.succeeded && ran.count == 2, "both backends were tried")
    expect(bothFailed.error?.contains("Claude Code can't run (Failed to authenticate") == true
            && bothFailed.error?.contains("Copilot: Error: Copilot quota exhausted") == true,
           "the failure names every backend tried: \(bothFailed.error ?? "")")

    ran = []
    let notSignIn = ConsolidationAttempt.execute(both) { backend in
        ran.append(backend.name)
        return Result(status: 2, output: "Error: model overloaded")
    }
    expect(ran == ["Claude Code"] && notSignIn.error == "Claude Code: Error: model overloaded.",
           "a failure after Claude started work does not rerun the prompt on Copilot: \(notSignIn.error ?? "")")

    ran = []
    let launch = ConsolidationAttempt.execute(both) { backend in
        ran.append(backend.name)
        return backend.name == "Claude Code"
            ? Result(status: -1, output: "", launchError: "couldn't start /c/claude: no such file")
            : Result(status: 0, output: "done")
    }
    expect(ran == ["Claude Code", "Copilot"] && launch.succeeded, "a Claude that can't start falls back to Copilot")

    let onlyClaude = ConsolidationAttempt.execute([.claude(path: "/c/claude")]) { _ in Result(status: 1, output: expired) }
    expect(onlyClaude.error?.contains("Copilot CLI wasn't found to fall back to") == true,
           "a signed-out Claude without Copilot says why nothing ran: \(onlyClaude.error ?? "")")
    let none = ConsolidationAttempt.execute([]) { _ in Result(status: 0, output: "") }
    expect(!none.succeeded && none.error?.contains("Neither the Claude Code CLI nor the GitHub Copilot CLI was found") == true,
           "no CLI at all is reported")
    let timedOut = ConsolidationAttempt.execute(both) { _ in Result(status: 15, output: "partial\nTimed out after 30 minutes.") }
    expect(!timedOut.succeeded && timedOut.error?.hasPrefix("Claude Code:") == true, "a timeout fails without falling back")
}

// MARK: Same permission policy for either CLI

do {
    let claude = ConsolidationBackend.claude(path: "/c/claude")
    let copilot = ConsolidationBackend.copilot(path: "/c/copilot", model: "claude-haiku-5.5")
    expect(claude.arguments(prompt: "P", allowActions: true) == ["-p", "P", "--model", "haiku", "--permission-mode", "bypassPermissions"],
           "Allow actions: Claude runs every tool")
    expect(claude.arguments(prompt: "P", allowActions: false) == ["-p", "P", "--model", "haiku", "--permission-mode", "acceptEdits"],
           "otherwise Claude may only edit files")
    let all = copilot.arguments(prompt: "P", allowActions: true)
    expect(all == ["-p", "P", "--silent", "--no-color", "--no-ask-user", "--model", "claude-haiku-5.5", "--allow-all-tools"],
           "Allow actions: Copilot runs every tool: \(all)")
    let edits = copilot.arguments(prompt: "P", allowActions: false)
    expect(edits.suffix(4) == ["--allow-tool", "write", "--deny-tool", "shell"] && !edits.contains("--allow-all-tools"),
           "otherwise Copilot may only edit files, never run commands: \(edits)")
    expect(!all.contains("--allow-all") && !all.contains("--allow-all-paths") && !all.contains("--yolo"),
           "Copilot keeps its path and URL checks")
    expect(ConsolidationBackend.copilot(path: "/c/copilot", model: nil).arguments(prompt: "P", allowActions: true).contains("--model") == false,
           "without a Haiku, no model is forced")
}

// MARK: Log rotation

do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cantrip-log-rotation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("Cantrip.log")
    func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    for generation in 1...5 {
        try "generation \(generation)\n".write(to: log, atomically: true, encoding: .utf8)
        LogRotation.rotate(log, maximumBytes: 1_000, archives: 3)
    }
    expect(!FileManager.default.fileExists(atPath: log.path), "rotation moves the live log aside")
    expect(contents(LogRotation.archive(of: log, 1)) == "generation 5\n", ".1 is the newest archive")
    expect(contents(LogRotation.archive(of: log, 3)) == "generation 3\n", "archives shift up")
    expect(!FileManager.default.fileExists(atPath: LogRotation.archive(of: log, 4).path), "only three archives are kept")

    // A log grown before rotation existed keeps only its newest lines.
    let lines = (1...2_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try lines.write(to: log, atomically: true, encoding: .utf8)
    LogRotation.rotate(log, maximumBytes: 1_000, archives: 3)
    let trimmed = contents(LogRotation.archive(of: log, 1)) ?? ""
    expect(trimmed.utf8.count <= 1_000 && trimmed.hasSuffix("line 2000\n"), "an oversized log keeps its tail")
    expect(trimmed.hasPrefix("line "), "the kept tail starts at a whole line")
    expect(contents(LogRotation.archive(of: log, 2)) == "generation 5\n", "earlier archives still shift")
    expect(Log.maximumBytes == 10 * 1024 * 1024 && Log.archiveCount == 3, "Cantrip.log caps at 10 MB with 3 archives")
} catch {
    failures += 1
    fputs("FAIL: unexpected error: \(error)\n", stderr)
}

if failures == 0 {
    print("Consolidation tests passed")
} else {
    exit(1)
}
