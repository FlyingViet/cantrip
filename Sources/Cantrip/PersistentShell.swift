import Foundation

/// Long-lived zsh behind the panel's terminal mode. Commands stream in
/// over stdin, so shell state (cwd, exports, vars) persists between
/// commands — unlike the one-shot `!` prefix. No PTY: line tools work,
/// full-screen interactive programs (vim, top) don't.
final class PersistentShell: ObservableObject {
    static let shared = PersistentShell()
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var partialLine = ""
    private let maxOutput = 60_000
    private init() {}

    func run(_ command: String, workdir: String) {
        ensureStarted(workdir: workdir)
        append((output.isEmpty ? "" : "\n") + "$ \(command)\n")
        isRunning = true
        // Sentinel line reports the exit status and marks completion.
        let line = command + "\nprintf '__CANTRIP_EXIT_%d__\\n' $?\n"
        stdinHandle?.write(Data(line.utf8))
    }

    func clear() {
        output = ""
    }

    /// Kill the shell (and whatever it's running); next command restarts.
    func restart() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        isRunning = false
        append("\n[shell restarted]\n")
    }

    // MARK: - Internals

    private func ensureStarted(workdir: String) {
        guard process?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l"] // login shell, reading commands from stdin
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let stdinPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = outPipe
        p.standardError = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.process = nil
                self?.stdinHandle = nil
                self?.isRunning = false
                self?.append("\n[shell exited]\n")
            }
        }
        do {
            try p.run()
            process = p
            stdinHandle = stdinPipe.fileHandleForWriting
            Log.write("terminal: shell started in \(workdir)")
        } catch {
            append("[failed to start shell: \(error.localizedDescription)]\n")
        }
    }

    /// Line-parse the stream, intercepting exit sentinels.
    private func consume(_ chunk: String) {
        let combined = partialLine + chunk
        var lines = combined.components(separatedBy: "\n")
        partialLine = lines.removeLast() // may be incomplete
        for line in lines {
            if let range = line.range(of: #"__CANTRIP_EXIT_(\d+)__"#,
                                      options: .regularExpression) {
                let digits = line[range].filter(\.isNumber)
                if let code = Int(digits), code != 0 {
                    append("exit \(code)\n")
                }
                isRunning = false
                // Anything else on the sentinel line is real output.
                let rest = line.replacingCharacters(in: range, with: "")
                if !rest.isEmpty { append(rest + "\n") }
            } else {
                append(line + "\n")
            }
        }
    }

    private func append(_ text: String) {
        output += text
        if output.count > maxOutput {
            output = String(output.suffix(maxOutput / 2))
        }
    }
}
