import Foundation

/// Runs queries through GitHub Copilot CLI in programmatic mode:
///   copilot -p "<prompt>" -s --output-format json --stream on
///     [--allow-all-tools] [--model M]
/// Copilot's headless mode has no session resume, so conversation
/// continuity is emulated by prepending recent turns to the prompt.
final class CopilotBackend: Backend {
    private var process: Process?
    private var history: [(user: String, assistant: String)] = []
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "copilot-backend")
    private let maxHistoryTurns = 6

    func send(_ prompt: String, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        queue.async { [weak self] in
            self?.run(prompt: prompt, workdir: workdir, onEvent: onEvent)
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
        history.removeAll()
    }

    // MARK: - Internals

    private func composePrompt(_ prompt: String) -> String {
        guard !history.isEmpty else { return prompt }
        var lines = ["Context — earlier turns of this conversation:"]
        for turn in history.suffix(maxHistoryTurns) {
            lines.append("User: \(turn.user)")
            lines.append("Assistant: \(turn.assistant)")
        }
        lines.append("")
        lines.append("New message: \(prompt)")
        return lines.joined(separator: "\n")
    }

    private func run(prompt: String, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        // Run through the user's login shell so copilot resolves with the
        // exact same PATH / node environment as their terminal. Arguments
        // are passed positionally ("$@") so no shell-quoting issues.
        let configured = settings.copilotPath.trimmingCharacters(in: .whitespaces)
        let command = configured.isEmpty ? "copilot" : configured

        var copilotArgs = [
            "-p", composePrompt(prompt),
            "-s",
            "--output-format", "json",
            "--stream", "on"
        ]
        if settings.copilotAllowTools || settings.allowActions {
            copilotArgs.append("--allow-all-tools")
        }
        let model = settings.copilotModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { copilotArgs += ["--model", model] }

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
            let answer = output.answer.trimmingCharacters(in: .whitespacesAndNewlines)
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
                if !answer.isEmpty {
                    self?.history.append((user: prompt, assistant: answer))
                }
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

    var answer: String {
        lock.withLock { parser.answer }
    }

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
