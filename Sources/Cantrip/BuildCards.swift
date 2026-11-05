import Foundation

// MARK: - Build cards (docs/cards.md "Build cards")

/// A build, test run or upload an agent ran in a tab, shown as a live card under the reply:
/// how long it has run, its progress when the tool prints step counters or earlier runs of the
/// same command give an estimate, then its result and total time. Every number comes from the
/// command itself or from `BuildHistory`.
struct BuildRun: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case running, succeeded, failed, stopped
        /// It ended without Cantrip seeing how (the run ended first, or Cantrip restarted).
        case ended
    }

    /// The tool call that ran the command.
    var id: String
    var title: String
    /// "Building", "Testing", "Archiving", "Uploading"…
    var verb: String
    /// The folder's name, such as the project it built.
    var project: String?
    var key: String
    var startedAt: Date
    var finishedAt: Date?
    var state: State = .running
    var exitCode: Int?
    var step: BuildStep?
    /// Median of this command's recent successful runs in this folder, when there are any.
    var expectedSeconds: Double?
    /// How many earlier runs `expectedSeconds` is from.
    var timedRuns: Int?
    /// The background shell (Copilot) or task (Claude) the command moved to.
    var shellID: String?

    var duration: TimeInterval? { finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }

    init(id: String, command: BuildCommand, startedAt: Date, estimate: BuildHistory.Estimate?) {
        self.id = id
        title = command.title
        verb = command.verb
        project = command.project
        key = command.key
        self.startedAt = startedAt
        expectedSeconds = estimate?.seconds
        timedRuns = estimate?.runs
    }

    mutating func finish(_ state: State, exitCode: Int? = nil, at date: Date) {
        guard self.state == .running else { return }
        self.state = state
        self.exitCode = exitCode ?? self.exitCode
        finishedAt = state == .ended ? nil : max(date, startedAt)
    }
}

extension BuildRun {
    /// The card: a header naming the command and its folder, then a `progress` block that
    /// clients tick locally from `startedAt` (no update from the Mac every second).
    var document: CardDocument {
        var header = CardDocument.Block(type: "header")
        header.symbol = switch state {
        case .running: verb == "Uploading" || verb == "Notarizing" ? "arrow.up.circle" : "hammer"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle"
        case .ended: "questionmark.circle"
        }
        header.title = title
        header.subtitle = project
        header.tone = state == .running ? nil : tone

        var progress = CardDocument.Block(type: "progress")
        progress.status = state.rawValue
        progress.label = label
        progress.tone = tone
        progress.startedAt = Self.iso(startedAt)
        progress.finishedAt = finishedAt.map(Self.iso)
        if state == .running {
            progress.expectedSeconds = expectedSeconds
            if let step { progress.fraction = Double(step.current) / Double(step.total) }
        }
        progress.detail = detail
        progress.accessibilityLabel = [label, detail].compactMap { $0 }.joined(separator: ", ")
        return CardDocument(id: "build-" + id, type: "build", accessibilityLabel: "\(title), \(label)",
                            source: .init(kind: "build", name: title), blocks: [header, progress]).withFallbackText()
    }

    var label: String {
        switch state {
        case .running: verb
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .ended: "Ended"
        }
    }

    var tone: String {
        switch state {
        case .running: "accent"
        case .succeeded: "positive"
        case .failed: "negative"
        case .stopped: "warning"
        case .ended: "neutral"
        }
    }

    /// The line under the bar: where the numbers come from.
    var detail: String {
        let usual = expectedSeconds.map { seconds in
            "usually " + Self.durationText(seconds) + (timedRuns.map { $0 == 1 ? " (1 earlier run)" : " (\($0) earlier runs)" } ?? "")
        }
        switch state {
        case .running:
            let steps = step.map { "Step \($0.current) of \($0.total)" }
            if let steps, let usual { return steps + " · " + usual }
            if let steps { return steps }
            if let usual { return usual.prefix(1).uppercased() + usual.dropFirst() }
            return "First timed run here, so no estimate yet"
        case .succeeded:
            if let usual { return usual.prefix(1).uppercased() + usual.dropFirst() }
            return "Timed for next time's estimate"
        case .failed:
            return exitCode.map { "Exit code \($0)" } ?? "The command reported a failure"
        case .stopped:
            return "Stopped before it finished"
        case .ended:
            return "Ended without a result Cantrip could read"
        }
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// "45s", "3m 05s", "1h 02m".
    static func durationText(_ seconds: TimeInterval) -> String { SubagentInfo.elapsedLabel(seconds) }
}

// MARK: - Recognizing build commands

/// A build or upload command, as Cantrip names and remembers it.
struct BuildCommand: Equatable {
    /// "xcodebuild test · Hermes", "swift build", "make test", "App Store upload"…
    var title: String
    var verb: String
    /// Where it ran: a `cd` (or `make -C`) in the command, else the tab's folder.
    var directory: String
    /// The same command in the same folder; estimates come from earlier runs with this key.
    var key: String

    var project: String? {
        let name = (directory as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return name.isEmpty || name == "/" || directory == home ? nil : name
    }
}

/// Finds build, test and upload commands in a shell command line: xcodebuild, swift build/test,
/// make, Gradle, npm/pnpm/yarn/bun build scripts, Expo, EAS, fastlane, App Store uploads and
/// notarization, Cargo, Go, .NET, Flutter, CMake/Ninja, Docker, Bazel and `build`/`release`
/// scripts. Only the program a segment runs counts, never a word in its arguments.
enum BuildDetector {
    static func detect(_ command: String, workdir: String) -> BuildCommand? {
        guard command.count <= 20_000 else { return nil }
        var directory = workdir
        var found: [(title: String, verb: String, words: [String], directory: String)] = []
        for segment in ShellCommandText.segments(of: command) {
            let words = unwrapped(ShellCommandText.commandWords(segment))
            guard let program = words.first else { continue }
            let name = ShellCommandText.baseName(program)
            if name == "cd" || name == "pushd" {
                if words.count > 1, !words[1].hasPrefix("-") { directory = resolved(words[1], from: directory) }
                continue
            }
            if ["bash", "sh", "zsh"].contains(name), let index = words.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
               index + 1 < words.count {
                if let inner = detect(words[index + 1], workdir: directory) {
                    found.append((inner.title, inner.verb, [inner.key], inner.directory))
                }
                continue
            }
            var runDirectory = directory
            if let match = match(words, name: name, directory: &runDirectory) {
                found.append((match.title, match.verb, words, runDirectory))
            }
        }
        guard let first = found.first else { return nil }
        let titles = found.map(\.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let title = titles.prefix(2).joined(separator: " → ") + (titles.count > 2 ? " …" : "")
        let normalized = found.map { $0.words.map(normalizedWord).joined(separator: " ") }.joined(separator: " && ")
        return BuildCommand(title: String(title.prefix(90)), verb: first.verb, directory: first.directory,
                            key: first.directory + "\n" + normalized)
    }

    /// The command inside wrappers `ShellCommandText` leaves: xcrun, bundle exec, npx, timeout,
    /// `script -q LOG`, `perl -e '… exec @ARGV'`, `arch -arm64`.
    static func unwrapped(_ words: [String]) -> [String] {
        var words = words
        while let first = words.first {
            var rest = Array(words.dropFirst())
            func dropFlags() { while let flag = rest.first, flag.hasPrefix("-") { rest.removeFirst() } }
            switch ShellCommandText.baseName(first) {
            case "xcrun":
                // `xcrun --sdk iphoneos xcodebuild`: skip its options and their values.
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest.removeFirst()
                    if ["--sdk", "-sdk", "--toolchain", "-toolchain"].contains(flag), !rest.isEmpty { rest.removeFirst() }
                }
            case "bundle" where rest.first == "exec":
                rest.removeFirst()
            case "npx", "bunx", "pnpx", "arch":
                dropFlags()
            case "pnpm" where rest.first == "exec" || rest.first == "dlx",
                 "yarn" where rest.first == "dlx" || rest.first == "exec":
                rest.removeFirst()
                dropFlags()
            case "timeout", "gtimeout", "script":
                // The duration or the log file comes before the command.
                dropFlags()
                if !rest.isEmpty { rest.removeFirst() }
            case "perl":
                guard let script = rest.firstIndex(where: { $0.contains("exec @ARGV") }) else { return words }
                rest = Array(rest[(script + 1)...])
            default:
                return words
            }
            guard !rest.isEmpty else { return words }
            words = rest
        }
        return words
    }

    // MARK: Tools

    private static func match(_ words: [String], name: String, directory: inout String) -> (title: String, verb: String)? {
        let args = Array(words.dropFirst())
        switch name {
        case "xcodebuild": return xcodebuild(args)
        case "swift":
            guard let sub = args.first, ["build", "test"].contains(sub),
                  !args.contains(where: { ["--show-bin-path", "--help", "-h", "--version", "--list-tests", "list"].contains($0) })
            else { return nil }
            let release = args.contains("release") && args.contains { $0 == "-c" || $0 == "--configuration" }
            return ("swift \(sub)" + (release ? " (release)" : ""), sub == "test" ? "Testing" : "Building")
        case "make", "gmake":
            return make(args, directory: &directory)
        case "gradle", "gradlew", "gradlew.bat":
            let tasks = args.filter { !$0.hasPrefix("-") }
            let skipped: Set = ["tasks", "help", "dependencies", "properties", "projects", "clean", "wrapper"]
            guard !tasks.isEmpty, !tasks.allSatisfy(skipped.contains),
                  !args.contains(where: { ["--version", "--stop", "--status", "-v"].contains($0) }) else { return nil }
            return ("gradle " + tasks.prefix(3).joined(separator: " "),
                    tasks.contains { $0.lowercased().contains("test") } ? "Testing" : "Building")
        case "npm", "pnpm", "yarn", "bun":
            return packageScript(name, args)
        case "expo":
            guard let sub = args.first, sub == "export" || sub == "prebuild" || sub.hasPrefix("run:") || sub.hasPrefix("build:")
            else { return nil }
            return ("expo \(sub)", "Building")
        case "eas":
            guard let sub = args.first, sub == "build" || sub == "submit" else { return nil }
            let platform = args.firstIndex(where: { $0 == "--platform" || $0 == "-p" })
                .flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            return ("eas \(sub)" + (platform.map { " (\($0))" } ?? ""), sub == "submit" ? "Uploading" : "Building")
        case "fastlane":
            let lanes = args.filter { !$0.hasPrefix("-") && !$0.contains(":") }
            guard let lane = lanes.last,
                  !["lanes", "list", "env", "init", "action", "actions", "docs", "--version", "version"].contains(lane) else { return nil }
            let upload = lane.range(of: "beta|release|upload|testflight|pilot|deliver|store|submit",
                                    options: [.regularExpression, .caseInsensitive]) != nil
            return ("fastlane " + lanes.prefix(2).joined(separator: " "), upload ? "Uploading" : "Building")
        case "altool":
            if args.contains("--upload-app") || args.contains("--upload-package") { return ("App Store upload", "Uploading") }
            if args.contains("--validate-app") { return ("App Store validation", "Validating") }
            return nil
        case "notarytool":
            return args.first == "submit" ? ("Notarization", "Notarizing") : nil
        case "itmstransporter":
            return args.contains("upload") ? ("App Store upload", "Uploading") : nil
        case "cargo":
            guard let sub = args.first, ["build", "test", "install", "bench"].contains(sub) else { return nil }
            return ("cargo \(sub)", sub == "test" ? "Testing" : "Building")
        case "go":
            guard let sub = args.first, ["build", "test", "install"].contains(sub) else { return nil }
            return ("go \(sub)", sub == "test" ? "Testing" : "Building")
        case "dotnet":
            guard let sub = args.first, ["build", "publish", "test", "pack", "msbuild"].contains(sub) else { return nil }
            return ("dotnet \(sub)", sub == "test" ? "Testing" : "Building")
        case "msbuild", "msbuild.exe":
            return ("msbuild", "Building")
        case "flutter":
            guard args.first == "build" else { return nil }
            return ("flutter build" + (args.dropFirst().first.map { " \($0)" } ?? ""), "Building")
        case "cmake":
            return args.contains("--build") ? ("cmake --build", "Building") : nil
        case "ninja":
            guard !args.contains(where: { ["-t", "--version", "-n", "--help", "-h"].contains($0) }) else { return nil }
            let targets = args.filter { !$0.hasPrefix("-") }
            return ("ninja" + (targets.isEmpty ? "" : " " + targets.prefix(2).joined(separator: " ")), "Building")
        case "docker":
            let words = args.filter { !$0.hasPrefix("-") }
            let builds = words.first == "build" || words.prefix(2) == ["buildx", "build"]
                || words.prefix(2) == ["compose", "build"] || words.prefix(2) == ["image", "build"]
            return builds ? ("docker build", "Building") : nil
        case "bazel", "bazelisk":
            guard let sub = args.first, ["build", "test"].contains(sub) else { return nil }
            return ("bazel \(sub)", sub == "test" ? "Testing" : "Building")
        case "tuist":
            guard let sub = args.first, ["build", "test"].contains(sub) else { return nil }
            return ("tuist \(sub)", sub == "test" ? "Testing" : "Building")
        case "electron-builder":
            return ("electron-builder", "Building")
        case "bash", "sh", "zsh":
            // `bash Scripts/build.sh`: the script decides.
            guard let script = args.first, !script.hasPrefix("-") else { return nil }
            return buildScript(script)
        default:
            return words.first.flatMap(buildScript)
        }
    }

    private static func xcodebuild(_ args: [String]) -> (String, String)? {
        let informational: Set = ["-list", "-version", "-showsdks", "-showBuildSettings", "-showdestinations", "-showTestPlans",
                                  "-help", "-usage", "-license", "-checkFirstLaunchStatus", "-runFirstLaunch",
                                  "-downloadPlatform", "-downloadAllPlatforms", "-importPlatform", "-resolvePackageDependencies",
                                  "-exportLocalizations", "-importLocalizations", "-showComponent", "-find-executable", "-find-library"]
        guard !args.contains(where: informational.contains) else { return nil }
        let flags: Set = ["-quiet", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-parallelizeTargets",
                          "-hideShellScriptEnvironment", "-showBuildTimingSummary", "-json", "-verbose", "-skipPackagePluginValidation",
                          "-skipMacroValidation", "-disableAutomaticPackageResolution", "-skipUnavailableActions",
                          "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates", "-alltargets", "-exportArchive"]
        let actions: Set = ["build", "build-for-testing", "analyze", "archive", "test", "test-without-building", "docbuild",
                            "install", "installsrc", "clean"]
        var found: [String] = []
        for (index, word) in args.enumerated() where actions.contains(word) {
            let previous = index > 0 ? args[index - 1] : ""
            if previous.hasPrefix("-"), !flags.contains(previous) { continue }
            found.append(word)
        }
        let scheme = args.firstIndex(of: "-scheme").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let action: String
        if args.contains("-exportArchive") {
            action = "export"
        } else if found.isEmpty {
            action = "build"
        } else if found.allSatisfy({ $0 == "clean" }) {
            return nil
        } else {
            action = found.filter { $0 != "clean" }.joined(separator: " ")
        }
        let verb = action.contains("test") ? "Testing" : action.contains("archive") ? "Archiving"
            : action == "export" ? "Exporting" : "Building"
        return ("xcodebuild \(action)" + (scheme.map { " · \($0)" } ?? ""), verb)
    }

    private static func make(_ args: [String], directory: inout String) -> (String, String)? {
        var targets: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            index += 1
            if ["-C", "--directory"].contains(word), index < args.count {
                directory = resolved(args[index], from: directory)
                index += 1
            } else if word.hasPrefix("--directory=") {
                directory = resolved(String(word.dropFirst("--directory=".count)), from: directory)
            } else if ["-f", "--file", "--makefile", "-o", "-W", "-I"].contains(word) {
                index += 1
            } else if ["-n", "--dry-run", "--just-print", "-q", "--question", "-p", "--print-data-base", "--help", "-v", "--version"]
                        .contains(word) {
                return nil
            } else if !word.hasPrefix("-"), !word.contains("="), Int(word) == nil {
                targets.append(word)
            }
        }
        let skipped: Set = ["clean", "distclean", "help", "run", "lint", "format", "fmt", "print", "list", "install-hooks"]
        guard targets.isEmpty || !targets.allSatisfy(skipped.contains) else { return nil }
        let title = targets.isEmpty ? "make" : "make " + targets.prefix(3).joined(separator: " ")
        return (title, targets.contains { $0.hasPrefix("test") } ? "Testing" : "Building")
    }

    private static func packageScript(_ manager: String, _ args: [String]) -> (String, String)? {
        let words = args.filter { !$0.hasPrefix("-") }
        let script: String?
        switch manager {
        case "npm":
            guard let run = words.firstIndex(where: { $0 == "run" || $0 == "run-script" }), run + 1 < words.count else { return nil }
            script = words[run + 1]
        default:
            if words.first == "run", words.count > 1 { script = words[1] } else { script = words.first }
        }
        guard let script, isBuildScript(script) else { return nil }
        return ((manager == "npm" || words.first == "run" ? "\(manager) run " : "\(manager) ") + script, "Building")
    }

    /// Script names like build, build:ios, package:win, ios:build, dist, bundle, export.
    static func isBuildScript(_ script: String) -> Bool {
        let parts = script.lowercased().split(whereSeparator: { ":._-".contains($0) }).map(String.init)
        let words: Set = ["build", "package", "dist", "bundle", "compile", "export", "release", "archive", "prebuild", "make"]
        return parts.contains(where: words.contains)
    }

    /// `./build.sh`, `Scripts/build-home-window.sh`, `scripts/release.sh`: a script named for building.
    private static func buildScript(_ program: String) -> (String, String)? {
        guard program.contains("/") || program.hasSuffix(".sh") else { return nil }
        let name = (program as NSString).lastPathComponent
        let stem = name.hasSuffix(".sh") ? String(name.dropLast(3)) : name
        let parts = stem.lowercased().split(whereSeparator: { "-_.".contains($0) }).map(String.init)
        guard parts.contains(where: ["build", "release", "archive"].contains) else { return nil }
        return (name, "Building")
    }

    static func resolved(_ path: String, from directory: String) -> String {
        guard !path.contains("$") else { return directory }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    private static let volatileWords: [(NSRegularExpression, String)] = [
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<id>"),
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}"#, "<id>"),
        (#"\b[0-9A-Fa-f]{24,}\b"#, "<id>"),
        (#"(?:/private)?/(?:tmp|var/folders)/\S*"#, "<tmp>"),
        (#"\d{4,}"#, "#"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Simulator and device IDs, temporary folders and long numbers (run IDs, ports, timestamps)
    /// change between runs of what is the same build.
    static func normalizedWord(_ word: String) -> String {
        var word = word
        for (pattern, replacement) in volatileWords {
            word = pattern.stringByReplacingMatches(in: word, range: NSRange(word.startIndex..., in: word), withTemplate: replacement)
        }
        return word
    }
}

// MARK: - Reading command results

enum BuildOutput {
    private static func lastMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func backgroundShell(in output: String) -> String? { BackgroundCommand.shellID(in: output) }

    /// The call was refused before the command started (a policy, a hook or the user said no):
    /// there was no build, so it gets no card.
    static func neverRan(_ output: String) -> Bool {
        let head = output.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["The user rejected this tool call", "Command not executed", "Blocked by Cantrip",
                "Permission denied and could not request permission", "The user doesn't want to proceed",
                "Cantrip did not get approval", "Declined: Cantrip didn't allow"].contains { head.hasPrefix($0) }
            || head.hasPrefix("PreToolUse:") && head.contains("hook error")
    }

    /// Exit codes a result reports: Copilot's `<shellId: X completed with exit code N>` /
    /// `<exited with exit code N>`, Claude's "Exit code N".
    static func exitCode(in output: String) -> Int? {
        let tail = String(output.suffix(4_000))
        if let match = lastMatch(#"(?:completed|exited) with exit code (-?\d+)"#, in: tail) { return Int(match[1]) }
        if let match = lastMatch(#"(?m)^(?:Error: )?Exit code (-?\d+)\s*$"#, in: String(output.prefix(400))) { return Int(match[1]) }
        return nil
    }

    /// Shells a result reports finished (`read_bash` after a command moved to the background).
    static func finishedShells(in output: String) -> [(id: String, exitCode: Int)] {
        guard output.contains("completed with exit code"),
              let regex = try? NSRegularExpression(pattern: #"<shellId: ([^\s>]+) completed with exit code (-?\d+)>"#) else { return [] }
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match in
            guard let id = Range(match.range(at: 1), in: output).map({ String(output[$0]) }),
                  let code = Range(match.range(at: 2), in: output).flatMap({ Int(output[$0]) }) else { return nil }
            return (id, code)
        }
    }

    private static let failures = [#"\*\* [A-Z ]*FAILED \*\*"#, #"(?m)^BUILD FAILED"#, #"(?m)^g?make(\[\d+\])?: \*\*\* "#,
                                    #"(?m)^error: fatalError"#]
    private static let successes = [#"\*\* [A-Z ]*SUCCEEDED \*\*"#, #"(?m)^BUILD SUCCESSFUL"#, #"(?m)^Build complete!"#]

    /// How a finished command went: a tool's own failure line first (a piped `| tail` exits 0),
    /// then the exit code, then a success line, then the call's own state.
    static func outcome(output: String, state: ToolActivityState) -> (BuildRun.State, Int?) {
        let tail = String(output.suffix(6_000))
        let code = exitCode(in: output)
        if failures.contains(where: { lastMatch($0, in: tail) != nil }) { return (.failed, code) }
        if let code { return (code == 0 ? .succeeded : .failed, code) }
        if successes.contains(where: { lastMatch($0, in: tail) != nil }) { return (.succeeded, nil) }
        switch state {
        case .succeeded: return (.succeeded, nil)
        case .failed: return (.failed, nil)
        case .cancelled: return (.stopped, nil)
        case .running: return (.ended, nil)
        }
    }
}

// MARK: - Earlier runs

/// How long each build command took in each folder, kept on this Mac
/// (`~/.cache/Cantrip/build-history.json`): estimates come only from these.
@MainActor
final class BuildHistory {
    struct Entry: Codable, Equatable {
        var seconds: Double
        var succeeded: Bool
        var finishedAt: Date
    }

    struct Estimate: Equatable {
        var seconds: Double
        var runs: Int
    }

    private struct Stored: Codable {
        var version = 1
        var commands: [String: [Entry]] = [:]
    }

    static let shared = BuildHistory(file: CantripPaths.cache("build-history.json"))
    static let keptRuns = 10
    static let estimatedFrom = 5
    static let keptCommands = 300

    let file: URL
    private var stored: Stored?

    init(file: URL) { self.file = file }

    private var commands: [String: [Entry]] {
        get {
            if stored == nil { stored = (try? PrivateFile.read(Stored.self, from: file)) ?? nil ?? Stored() }
            return stored?.commands ?? [:]
        }
        set { stored = Stored(commands: newValue) }
    }

    func runs(for key: String) -> [Entry] { commands[key] ?? [] }

    /// The median of the last few successful runs: failures stop early, so they don't count.
    func estimate(for key: String) -> Estimate? {
        let recent = runs(for: key).filter(\.succeeded).suffix(Self.estimatedFrom).map(\.seconds).sorted()
        guard !recent.isEmpty else { return nil }
        let middle = recent.count / 2
        let median = recent.count.isMultiple(of: 2) ? (recent[middle - 1] + recent[middle]) / 2 : recent[middle]
        return Estimate(seconds: median, runs: recent.count)
    }

    func record(_ run: BuildRun) {
        guard let seconds = run.duration, run.state == .succeeded || run.state == .failed else { return }
        var all = commands
        var entries = all[run.key] ?? []
        entries.append(Entry(seconds: (seconds * 10).rounded() / 10, succeeded: run.state == .succeeded,
                             finishedAt: run.finishedAt ?? Date()))
        all[run.key] = Array(entries.suffix(Self.keptRuns))
        if all.count > Self.keptCommands {
            let oldest = all.sorted { ($0.value.last?.finishedAt ?? .distantPast) < ($1.value.last?.finishedAt ?? .distantPast) }
                .prefix(all.count - Self.keptCommands).map(\.key)
            for key in oldest { all.removeValue(forKey: key) }
        }
        commands = all
        do {
            try PrivateFile.write(stored ?? Stored(), to: file)
        } catch {
            Log.write("build-history: could not save (\(error.localizedDescription))")
        }
    }
}

// MARK: - Following builds in a conversation

/// Turns tool steps into build card updates. It only reads the transcript; the session applies
/// the updates, so nothing changes (and nothing redraws) unless a build did.
@MainActor
enum BuildTracker {
    struct Update: Equatable {
        var messageIndex: Int
        var run: BuildRun
        /// It just finished: record it and stop following it.
        var ended: Bool
        /// The command never ran (refused before it started): take its card away.
        var removed = false
    }

    /// Calls already read, so a subagent's step tree (sent whole on each change) isn't re-read.
    struct Seen {
        var starts: Set<String> = []
        var ends: Set<String> = []
    }

    /// The transcript's builds with this pass's updates applied.
    private struct Working {
        let messages: [ChatMessage]
        var changed: [Int: [BuildRun]] = [:]
        var updates: [Update] = []

        func find(_ test: (BuildRun) -> Bool) -> (Int, BuildRun)? {
            for index in messages.indices.reversed() {
                if let run = (changed[index] ?? messages[index].builds).last(where: test) { return (index, run) }
            }
            return nil
        }

        mutating func put(_ run: BuildRun, at index: Int, ended: Bool) {
            var builds = changed[index] ?? messages[index].builds
            if let existing = builds.firstIndex(where: { $0.id == run.id }) { builds[existing] = run } else { builds.append(run) }
            changed[index] = builds
            updates.append(Update(messageIndex: index, run: run, ended: ended))
        }

        mutating func remove(_ run: BuildRun, at index: Int) {
            changed[index] = (changed[index] ?? messages[index].builds).filter { $0.id != run.id }
            updates.append(Update(messageIndex: index, run: run, ended: false, removed: true))
        }
    }

    static func updates(for activity: ToolActivity, at messageIndex: Int, in messages: [ChatMessage], workdir: String,
                        history: BuildHistory, seen: inout Seen, now: Date = Date()) -> [Update] {
        guard messages.indices.contains(messageIndex) else { return [] }
        var working = Working(messages: messages)
        var known = Set(messages.flatMap { $0.builds.map(\.id) })
        for step in ToolCards.flattened([activity]) {
            if known.contains(step.id) {
                guard let (index, found) = working.find({ $0.id == step.id }), found.state == .running else { continue }
                var run = found
                if step.state != .running, run.shellID == nil {
                    // The call returned: the command finished, or moved to a background shell.
                    let output = Self.output(of: step)
                    if step.state != .succeeded, BuildOutput.neverRan(output) {
                        working.remove(run, at: index)
                    } else if let shell = BuildOutput.backgroundShell(in: output) {
                        run.shellID = shell
                        run.step = step.buildStep ?? run.step
                        working.put(run, at: index, ended: false)
                    } else {
                        let (state, code) = BuildOutput.outcome(output: output, state: step.state)
                        run.finish(state, exitCode: code, at: now)
                        working.put(run, at: index, ended: true)
                    }
                } else if let progress = step.buildStep, progress != run.step {
                    run.step = progress
                    working.put(run, at: index, ended: false)
                }
                continue
            }
            if step.state == .running {
                guard seen.starts.insert(step.id).inserted, let command = step.terminalCommand,
                      let detected = BuildDetector.detect(command, workdir: workdir) else { continue }
                let run = BuildRun(id: step.id, command: detected, startedAt: now, estimate: history.estimate(for: detected.key))
                working.put(run, at: messageIndex, ended: false)
                known.insert(step.id)
                continue
            }
            // A finished step that isn't a build: reading or stopping a build's background shell.
            guard seen.ends.insert(step.id).inserted,
                  working.find({ $0.state == .running && $0.shellID != nil }) != nil else { continue }
            for shell in BuildOutput.finishedShells(in: Self.output(of: step)) {
                guard let (index, found) = working.find({ $0.state == .running && $0.shellID == shell.id }) else { continue }
                var run = found
                run.finish(shell.exitCode == 0 ? .succeeded : .failed, exitCode: shell.exitCode, at: now)
                working.put(run, at: index, ended: true)
            }
            if ToolCards.normalized(step.toolName) == "stopbash", step.state == .succeeded,
               let input = step.input, let shell = JSONPrefix.firstObject(in: input)?["shellId"] as? String,
               let (index, found) = working.find({ $0.state == .running && $0.shellID == shell }) {
                var run = found
                run.finish(.stopped, at: now)
                working.put(run, at: index, ended: true)
            }
        }
        return working.updates
    }

    /// A background command ended (Copilot's shell notification, Claude's task notification).
    static func updates(for finished: FinishedCommand, in messages: [ChatMessage], now: Date = Date()) -> [Update] {
        let ids = Set(finished.ids)
        var working = Working(messages: messages)
        guard let (index, found) = working.find({
            $0.state == .running && ($0.shellID.map(ids.contains) == true || ids.contains($0.id))
        }) else { return [] }
        var run = found
        let state: BuildRun.State = switch finished.state {
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .stopped
        case .running, nil: .ended
        }
        run.finish(state, exitCode: finished.exitCode, at: now)
        working.put(run, at: index, ended: true)
        return working.updates
    }

    /// The run ended with builds Cantrip never saw finish: stopped when the run was, else ended.
    static func endingUnfinished(in messages: [ChatMessage], stopped: Bool, now: Date = Date()) -> [Update] {
        messages.indices.flatMap { index in
            messages[index].builds.filter { $0.state == .running }.map { found in
                var run = found
                run.finish(stopped ? .stopped : .ended, at: now)
                return Update(messageIndex: index, run: run, ended: true)
            }
        }
    }

    private static func output(of step: ToolActivity) -> String {
        [step.output, step.outputTail].compactMap { $0 }.joined(separator: "\n")
    }
}

extension ChatMessage {
    mutating func remove(_ run: BuildRun) {
        builds.removeAll { $0.id == run.id }
    }

    mutating func apply(_ run: BuildRun) {
        if let index = builds.firstIndex(where: { $0.id == run.id }) {
            builds[index] = run
        } else {
            builds.append(run)
        }
    }
}
