import Foundation

/// Runs queries through GitHub Copilot CLI in programmatic mode:
///   copilot -p "<prompt>" -s --output-format json --stream on
///     [--allow-all-tools] [--model M] [--context TIER]
/// Copilot's headless mode has no session resume, so conversation
/// continuity uses a bounded window of raw recent and related turns.
final class CopilotBackend: Backend {
    private var process: Process?
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "copilot-backend")

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        queue.async { [weak self] in
            self?.run(request: request, workdir: workdir, onEvent: onEvent)
        }
    }

    func cancel() {
        guard let p = process else { return }
        process = nil
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
    }

    // MARK: - Internals

    private func run(
        request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        // Run through the user's login shell so copilot resolves with the
        // exact same PATH / node environment as their terminal. Arguments
        // are passed positionally ("$@") so no shell-quoting issues.
        let configured = settings.copilotPath.trimmingCharacters(in: .whitespaces)
        let command = configured.isEmpty ? "copilot" : configured

        var composed = ConversationContextBuilder.composePrompt(
            currentPrompt: request.prompt,
            query: request.userMessage,
            turns: request.previousTurns
        )
        if settings.copilotDiscourageSubagents {
            composed += "\n\n(Work directly in this session; avoid spawning subagents or delegating tasks unless strictly necessary — delegation is slow in this environment.)"
        }
        var copilotArgs = [
            "-p", composed,
            "-s",
            "--output-format", "json",
            "--stream", "on"
        ]
        if settings.copilotAllowTools || settings.allowActions {
            copilotArgs.append("--allow-all-tools")
        }
        let model = settings.copilotModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { copilotArgs += ["--model", model] }
        let effort = settings.copilotEffort.trimmingCharacters(in: .whitespaces)
        if !effort.isEmpty { copilotArgs += ["--reasoning-effort", effort] }
        let contextTier = settings.copilotContextTier.trimmingCharacters(in: .whitespaces)
        if !contextTier.isEmpty { copilotArgs += ["--context", contextTier] }

        Log.write("launching \(command) via login shell, workdir=\(workdir)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", command] + copilotArgs
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        // Discourage ANSI decoration in output.
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        p.standardInput = FileHandle.nullDevice

        var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        let output = CopilotJSONOutputCollector()
        let stdoutLock = NSLock()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutLock.withLock {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for event in output.consume(data) {
                    onEvent(event)
                }
                if output.errorDescription != nil, p.isRunning {
                    p.terminate()
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Log.write("copilot exited, status=\(proc.terminationStatus), reason=\(proc.terminationReason.rawValue)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutLock.withLock {
                for event in output.consume(stdout.fileHandleForReading.readDataToEndOfFile()) {
                    onEvent(event)
                }
                for event in output.finish() {
                    onEvent(event)
                }
            }
            if let parseError = output.errorDescription {
                onEvent(.failure(parseError))
            } else if proc.terminationStatus != 0 {
                errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationReason == .uncaughtSignal {
                    onEvent(.done) // cancelled by user
                } else {
                    onEvent(.failure(errText.isEmpty ? "copilot exited with status \(proc.terminationStatus)" : errText))
                }
            } else {
                onEvent(.done)
            }
            self?.process = nil
        }

        do {
            try p.run()
            process = p
            Log.write("copilot started, pid=\(p.processIdentifier)")
        } catch {
            Log.write("copilot launch failed: \(error.localizedDescription)")
            onEvent(.failure("Failed to launch copilot: \(error.localizedDescription)"))
        }
    }
}

private final class CopilotJSONOutputCollector {
    private let lock = NSLock()
    private var parser = CopilotJSONStreamParser()
    private var parsingError: Error?

    var errorDescription: String? {
        lock.withLock {
            parsingError.map { "Failed to parse Copilot output: \($0.localizedDescription)" }
        }
    }

    func consume(_ data: Data) -> [BackendEvent] {
        lock.withLock {
            guard parsingError == nil else { return [] }
            do {
                return try parser.consume(data)
            } catch {
                parsingError = error
                return []
            }
        }
    }

    func finish() -> [BackendEvent] {
        lock.withLock {
            guard parsingError == nil else { return [] }
            do {
                return try parser.finish()
            } catch {
                parsingError = error
                return []
            }
        }
    }
}
