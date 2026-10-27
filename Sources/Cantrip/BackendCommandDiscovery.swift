import Foundation
import CryptoKit
import Darwin

/// Asks each agent CLI for its own command and skill list, in the tab's folder:
/// - Copilot: a throwaway SDK session (MCP servers off) -> `commands.list` + `skills.list`, deleted after.
/// - Claude Code: the stream-json `initialize` handshake (what the Agent SDK uses); no prompt is sent.
/// - Codex: `codex app-server` -> `skills/list` (Codex has no command list; built-ins are terminal-only).
/// Free of app types: callers pass paths and the environment. Tests run it against fake CLIs.
enum BackendCommandDiscovery {
    struct Result: Equatable {
        var commands: [BackendCommand]
        var status: String?
    }

    // MARK: Copilot

    static let copilotScript = CopilotRuntime.discoveryScript + "\n" + #"""
    const config = JSON.parse(process.argv[1] ?? '{}');
    const out = value => new Promise(resolve => process.stdout.write(JSON.stringify(value) + '\n', resolve));
    const text = error => String(error?.message ?? error).slice(0, 400);
    let client, sessionId;
    const timer = setTimeout(() => { void out({ error: 'Copilot took too long to list its commands.' }).then(() => process.exit(2)); }, 25000);
    try {
      const paths = resolveCopilotRuntime(config.command);
      const sdk = await import(paths.sdk);
      client = new sdk.CopilotClient({
        connection: sdk.RuntimeConnection.forStdio({ path: paths.sessionRuntime }),
        workingDirectory: config.workdir, logLevel: 'none', useLoggedInUser: true
      });
      await client.start();
      let disabled = [];
      try {
        disabled = ((await client.rpc.mcp.discover({ workingDirectory: config.workdir }))?.servers ?? [])
          .map(server => server.name).filter(Boolean);
      } catch {}
      let commands = [], skills = [], note = null;
      try {
        // A session in the tab's folder lists exactly what a turn there can run. MCP servers stay
        // off: they never add commands, and starting them would be slow.
        const session = await client.createSession({
          clientName: 'Cantrip', workingDirectory: config.workdir, enableConfigDiscovery: true,
          remoteSession: 'off', disabledMcpServers: disabled, onPermissionRequest: () => ({ kind: 'reject' })
        });
        sessionId = session.sessionId;
        commands = (await session.rpc.commands.list({ includeBuiltins: true, includeSkills: true, includeClientCommands: false }))?.commands ?? [];
        try { skills = (await session.rpc.skills.list())?.skills ?? []; } catch {}
      } catch (error) {
        // Signed out or no session support: the runtime still lists commands and skills on its own.
        note = text(error);
        commands = (await client.rpc.commands.list())?.commands ?? [];
        skills = (await client.rpc.skills.discover({ projectPaths: [config.workdir] }))?.skills ?? [];
        const invocable = skills.filter(skill => skill.userInvocable !== false && skill.enabled !== false);
        commands = commands.concat(invocable.map(skill => ({
          name: skill.name, description: skill.description ?? '', kind: 'skill',
          input: { hint: skill.argumentHint || 'instructions for the skill' }
        })));
      }
      await out({ commands, note, skills: skills.map(skill => ({
        name: skill.name, commandName: skill.commandName, description: skill.description,
        source: skill.source, userInvocable: skill.userInvocable, enabled: skill.enabled, path: skill.path
      })) });
    } catch (error) {
      await out({ error: text(error) });
    } finally {
      clearTimeout(timer);
      try { if (sessionId) await client.deleteSession(sessionId); } catch {}
      try { await client?.forceStop(); } catch {}
      process.exit(0);
    }
    """#

    static func copilot(command: String, workdir: String, environment: [String: String],
                        family: BackendCommandFamily = .copilot) async -> Result {
        let config = ["command": command.isEmpty ? "copilot" : command, "workdir": workdir]
        let configJSON = String(data: (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8),
                                encoding: .utf8) ?? "{}"
        let outcome = await JSONLineProcess.run(
            "/bin/zsh",
            ["-l", "-c", "exec node --input-type=module -e \"$1\" \"$2\"", "cantrip-copilot-commands",
             copilotScript, configJSON],
            environment: environment, directory: workdir, input: [], timeout: 40
        ) { $0["commands"] != nil || $0["error"] != nil }
        guard let object = outcome.object else {
            return Result(commands: [], status: "Couldn't list Copilot's commands: \(outcome.failureText)")
        }
        if let error = object["error"] as? String {
            return Result(commands: [], status: "Couldn't list Copilot's commands: \(error)")
        }
        let commands = BackendCommandParsers.copilot(
            commands: object["commands"] as? [[String: Any]] ?? [],
            skills: object["skills"] as? [[String: Any]] ?? [], family: family)
        let note = object["note"] as? String
        return Result(commands: commands, status: note.map {
            "Copilot couldn't open a session here (\($0)), so session-only commands may be missing."
        })
    }

    // MARK: Claude Code

    static func claude(path: String?, workdir: String, environment: [String: String],
                       home: String) async -> Result {
        guard let path, !path.isEmpty else {
            return Result(commands: [], status: "Claude Code isn't installed on this Mac.")
        }
        var environment = environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"], home: home)
        let requestID = "cantrip-commands-\(UUID().uuidString)"
        let outcome = await JSONLineProcess.run(
            path,
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--no-session-persistence"],
            environment: environment, directory: workdir,
            input: [["type": "control_request", "request_id": requestID, "request": ["subtype": "initialize"]]],
            timeout: 20
        ) { object in
            object["type"] as? String == "control_response"
                && (object["response"] as? [String: Any])?["request_id"] as? String == requestID
        }
        guard let envelope = outcome.object?["response"] as? [String: Any] else {
            return Result(commands: [], status: "Couldn't list Claude Code's commands: \(outcome.failureText)")
        }
        guard envelope["subtype"] as? String == "success", let response = envelope["response"] as? [String: Any] else {
            let error = envelope["error"] as? String ?? "it refused the request"
            return Result(commands: [], status: "Couldn't list Claude Code's commands: \(error)")
        }
        let fm = FileManager.default
        func names(_ directory: String, files: Bool) -> Set<String> {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
            return Set(entries.compactMap { entry in
                guard !entry.hasPrefix(".") else { return nil }
                if files { return entry.hasSuffix(".md") ? String(entry.dropLast(3)) : nil }
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: "\(directory)/\(entry)", isDirectory: &isDirectory) && isDirectory.boolValue
                    ? entry : nil
            })
        }
        let parsed = BackendCommandParsers.claude(
            response,
            personalSkills: names("\(home)/.claude/skills", files: false),
            personalCommands: names("\(home)/.claude/commands", files: true),
            projectSkills: names("\(workdir)/.claude/skills", files: false))
        let status = parsed.signedIn == false
            ? "Claude Code isn't signed in on this Mac, so only its local commands (like /context) run until you sign in with `claude auth login`."
            : nil
        return Result(commands: parsed.commands, status: status)
    }

    // MARK: Codex

    static func codex(command: String, workdir: String, environment: [String: String]) async -> Result {
        let outcome = await JSONLineProcess.run(
            "/bin/zsh",
            ["-l", "-c", "exec \"$0\" \"$@\"", command.isEmpty ? "codex" : command, "app-server"],
            environment: environment, directory: workdir,
            input: [
                ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "cantrip", "version": "1"]]],
                ["method": "initialized"],
                ["id": 2, "method": "skills/list", "params": ["cwds": [workdir]]],
            ],
            timeout: 20
        ) { $0["id"] as? Int == 2 }
        if outcome.exitStatus == 127 || outcome.stderr.contains("command not found") {
            return Result(commands: [], status: "Codex isn't installed on this Mac.")
        }
        guard let object = outcome.object else {
            return Result(commands: [], status: "Couldn't list Codex's skills: \(outcome.failureText)")
        }
        if let error = object["error"] as? [String: Any] {
            return Result(commands: [], status: "Couldn't list Codex's skills: \(error["message"] as? String ?? "error")")
        }
        let commands = BackendCommandParsers.codex(object["result"] as? [String: Any] ?? [:])
        return Result(commands: commands, status: commands.isEmpty
            ? "Codex has no skills here. Its built-in commands only work in its terminal app." : nil)
    }
}

/// Runs a CLI that speaks newline-delimited JSON: writes `input`, returns the first stdout object
/// `isFinal` accepts, then closes stdin and stops the process (TERM, then KILL).
enum JSONLineProcess {
    struct Outcome {
        var object: [String: Any]?
        var exitStatus: Int32?
        var stderr = ""
        var timedOut = false
        var launchError: String?

        var failureText: String {
            if let launchError { return launchError }
            if timedOut { return "it took too long to answer" }
            let detail = stderr.split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !detail.isEmpty { return String(detail.prefix(300)) }
            return exitStatus.map { "it exited with status \($0)" } ?? "no answer"
        }
    }

    /// One run: the process, its pipes and the single answer, guarded by `lock`.
    private final class Run: @unchecked Sendable {
        let lock = NSLock()
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        var finished = false
        var stdoutBuffer = Data()
        var stderrBuffer = Data()
        var continuation: CheckedContinuation<Outcome, Never>?

        func finish(_ outcome: Outcome) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true
            self.continuation = nil
            var outcome = outcome
            outcome.stderr = String(data: stderrBuffer.prefix(4000), encoding: .utf8) ?? ""
            lock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            JSONLineProcess.stop(process)
            continuation.resume(returning: outcome)
        }

        /// Complete lines received so far.
        func lines(after data: Data) -> [Data] {
            lock.withLock {
                stdoutBuffer.append(data)
                var lines: [Data] = []
                while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                    lines.append(stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline))
                    stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
                }
                if stdoutBuffer.count > 8_000_000 { stdoutBuffer.removeAll() }
                return lines
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    directory: String, input: [[String: Any]], timeout: TimeInterval,
                    until isFinal: @escaping @Sendable ([String: Any]) -> Bool) async -> Outcome {
        let run = Run()
        let process = run.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = run.stdin
        process.standardOutput = run.stdout
        process.standardError = run.stderr
        var payload = Data()
        for line in input {
            guard let data = try? JSONSerialization.data(withJSONObject: line) else { continue }
            payload.append(data)
            payload.append(0x0A)
        }

        return await withCheckedContinuation { continuation in
            run.continuation = continuation
            run.stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                run.lock.withLock { if run.stderrBuffer.count < 16_000 { run.stderrBuffer.append(data) } }
            }
            run.stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in run.lines(after: data) {
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          isFinal(object) else { continue }
                    run.finish(Outcome(object: object))
                    return
                }
            }
            process.terminationHandler = { process in
                let status = process.terminationStatus
                // Let a final stdout line that raced the exit be read first.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    run.finish(Outcome(exitStatus: status))
                }
            }
            do {
                try process.run()
            } catch {
                run.finish(Outcome(launchError: error.localizedDescription))
                return
            }
            if !payload.isEmpty { try? run.stdin.fileHandleForWriting.write(contentsOf: payload) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                run.finish(Outcome(timedOut: true))
            }
        }
    }

    /// Closing stdin ends these CLIs on their own; TERM and KILL follow if they linger.
    fileprivate static func stop(_ process: Process) {
        guard process.isRunning else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// Modification times of the folders the CLIs read skills, commands and plugins from, plus the
/// CLIs themselves: a different value means something was installed, removed or updated.
enum BackendCommandFingerprint {
    static let homePaths = [
        // Not .copilot/config.json: Copilot rewrites it every time it starts.
        ".copilot/skills", ".copilot/agents", ".copilot/installed-plugins",
        ".agents/skills", ".claude/skills", ".claude/commands", ".claude/plugins", ".claude/settings.json",
        ".codex/skills", ".codex/config.toml", ".config/cantrip/commands",
    ]
    static let projectPaths = [
        ".github/skills", ".github/agents", ".claude/skills", ".claude/commands", ".claude/settings.json",
        ".agents/skills", ".codex/skills",
    ]
    static let cliNames = ["copilot", "claude", "codex"]

    static func compute(workdir: String, home: String, environment: [String: String]) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        func stamp(_ path: String, children: Bool) {
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  let date = attributes[.modificationDate] as? Date else { return }
            parts.append("\(path)|\(date.timeIntervalSince1970)")
            guard children, attributes[.type] as? FileAttributeType == .typeDirectory,
                  let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                if let child = try? fm.attributesOfItem(atPath: "\(path)/\(entry)"),
                   let date = child[.modificationDate] as? Date {
                    parts.append("\(path)/\(entry)|\(date.timeIntervalSince1970)")
                }
            }
        }
        for path in homePaths { stamp("\(home)/\(path)", children: true) }
        var directory = workdir
        for _ in 0..<8 {
            for path in projectPaths { stamp("\(directory)/\(path)", children: true) }
            if fm.fileExists(atPath: "\(directory)/.git") || directory == home || directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ToolPath.toolFolders(home: home)
        for name in cliNames {
            guard let path = searchPath.lazy.map({ "\($0)/\(name)" }).first(where: { fm.isExecutableFile(atPath: $0) })
            else { parts.append("\(name)|missing"); continue }
            stamp(path, children: false)
            stamp((path as NSString).resolvingSymlinksInPath, children: false)
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
