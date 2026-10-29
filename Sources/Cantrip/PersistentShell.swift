import Foundation

/// Long-lived zsh behind the panel's terminal mode. A lightweight PTY
/// provides normal signal handling while commands still arrive by line,
/// so shell state persists but full-screen programs remain unsupported.
final class PersistentShell: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var hasAgentCommandRunning = false
    @Published private(set) var agentCommandVersion = 0
    private(set) var commandHistory: [String] = []
    /// Unicode scalars trimmed from the front of `output`, so `outputEnd` only grows
    /// (until Clear starts a new `epoch`). Paired clients tail the output by these offsets.
    private(set) var outputBase = 0
    private(set) var epoch = UUID().uuidString
    var outputEnd: Int { outputBase + output.unicodeScalars.count }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var partialLine = ""
    private var isReady = false
    private var pendingInterrupt = false
    private var suppressNextInterruptEcho = false
    private var mirroredCommands: [String: MirroredCommand] = [:]
    private let maxOutput = 60_000

    private struct MirroredCommand {
        var output = ""
        var state = ToolActivityState.running
    }

    func run(_ command: String, workdir: String) {
        ensureStarted(workdir: workdir)
        append((output.isEmpty ? "" : "\n") + "$ \(command)\n")
        remember(command)
        isRunning = true
        // Sentinel line reports the exit status and marks completion.
        let line = command + "\nprintf '__CANTRIP_EXIT_%d__\\n' $?\n"
        stdinHandle?.write(Data(line.utf8))
    }

    func clear() {
        output = ""
        outputBase = 0
        epoch = UUID().uuidString
    }

    /// The output after scalar offset `from` in `epoch`, or all of it (`reset`) when the
    /// client's place was trimmed, cleared or is unknown.
    func tail(from: Int?, epoch clientEpoch: String?) -> (text: String, start: Int, reset: Bool) {
        let scalars = output.unicodeScalars
        guard let from, clientEpoch == epoch, from >= outputBase, from <= outputEnd else {
            return (output, outputBase, true)
        }
        let start = scalars.index(scalars.startIndex, offsetBy: from - outputBase)
        return (String(scalars[start...]), from, false)
    }

    /// Reflect commands that the agent CLI executes itself. They are not
    /// re-run here; matching tool IDs let streaming updates append once.
    func mirror(_ activity: ToolActivity) {
        if activity.terminalCommand != nil {
            mirrorCommand(activity)
        }
        for child in activity.children {
            mirror(child)
        }
    }

    /// Send SIGINT to the running command while keeping the persistent shell alive.
    func interrupt() {
        guard isRunning, process?.isRunning == true else { return }
        append("^C\n")
        pendingInterrupt = true
        if isReady { scheduleInterrupt() }
    }

    /// Kill the shell (and whatever it's running); next command restarts.
    func restart() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        isRunning = false
        isReady = false
        pendingInterrupt = false
        suppressNextInterruptEcho = false
        append("\n[shell restarted]\n")
    }

    // MARK: - Internals

    private func ensureStarted(workdir: String) {
        guard process?.isRunning != true else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/bin/zsh", "-f"]
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["PATH"] = ToolPath.value(inherited: env["PATH"])
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
                self?.isReady = false
                self?.pendingInterrupt = false
                self?.suppressNextInterruptEcho = false
                self?.append("\n[shell exited]\n")
            }
        }
        do {
            try p.run()
            process = p
            stdinHandle = stdinPipe.fileHandleForWriting
            isReady = false
            pendingInterrupt = false
            partialLine = ""
            // noflsh preserves the queued exit sentinel when Ctrl-C is sent.
            let setup = """
            PS1=''
            PS2=''
            PROMPT_EOL_MARK=''
            stty noflsh
            printf '__CANTRIP_READY__\\n'
            """
            stdinHandle?.write(Data((setup + "\n").utf8))
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
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if !isReady {
                if line == "__CANTRIP_READY__" {
                    isReady = true
                    if pendingInterrupt { scheduleInterrupt() }
                }
                continue
            }
            // zsh's line editor redraws piped input using bracketed-paste
            // markers. The command is already shown by run(), so hide it.
            if line.contains("\u{1B}[?2004h"), line.contains("\u{1B}[?2004l") {
                continue
            }
            if line == "printf '__CANTRIP_EXIT_%d__\\n' $?" {
                continue
            }
            if suppressNextInterruptEcho, line == "^C" {
                suppressNextInterruptEcho = false
                continue
            }
            if let range = line.range(of: #"__CANTRIP_EXIT_(\d+)__"#,
                                      options: .regularExpression) {
                let digits = line[range].filter(\.isNumber)
                if let code = Int(digits), code != 0 {
                    append("exit \(code)\n")
                }
                isRunning = false
                pendingInterrupt = false
                suppressNextInterruptEcho = false
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
            let before = output.unicodeScalars.count
            output = String(output.suffix(maxOutput / 2))
            outputBase += before - output.unicodeScalars.count
        }
    }

    private func mirrorCommand(_ activity: ToolActivity) {
        guard let command = activity.terminalCommand else { return }
        var mirrored = mirroredCommands[activity.id]
        if mirrored == nil {
            append((output.isEmpty ? "" : "\n") + "agent $ \(command)\n")
            remember(command)
            agentCommandVersion &+= 1
            mirrored = MirroredCommand()
        }
        guard var mirrored else { return }

        if let newOutput = activity.output, newOutput != mirrored.output {
            let delta: String
            if newOutput.hasPrefix(mirrored.output) {
                delta = String(newOutput.dropFirst(mirrored.output.count))
            } else {
                delta = (mirrored.output.isEmpty ? "" : "\n") + newOutput
            }
            if !delta.isEmpty {
                append(delta + (delta.hasSuffix("\n") ? "" : "\n"))
            }
            mirrored.output = newOutput
        }

        if mirrored.state == .running, activity.state != .running {
            switch activity.state {
            case .succeeded:
                append("[agent command completed]\n")
            case .failed:
                append("[agent command failed]\n")
            case .cancelled:
                append("[agent command cancelled]\n")
            case .running:
                break
            }
        }
        mirrored.state = activity.state
        mirroredCommands[activity.id] = mirrored
        hasAgentCommandRunning = mirroredCommands.values.contains {
            $0.state == .running
        }
    }

    private func remember(_ command: String) {
        commandHistory.append(command)
        if commandHistory.count > 200 {
            commandHistory.removeFirst(commandHistory.count - 200)
        }
    }

    private func sendInterrupt() {
        suppressNextInterruptEcho = true
        stdinHandle?.write(Data([0x03]))
    }

    private func scheduleInterrupt() {
        pendingInterrupt = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isRunning, self.process?.isRunning == true else { return }
            self.sendInterrupt()
        }
    }
}
