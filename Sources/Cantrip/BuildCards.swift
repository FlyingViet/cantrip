import Foundation

// MARK: - Build cards (docs/cards.md "Build cards")

/// A build, test run, upload or other transfer an agent ran in a tab, shown as a live card under
/// the reply: how long it has run, its progress when the tool prints step counters or transfer
/// progress, or earlier runs of the same command give an estimate, then its result and total time.
/// Every number comes from the command itself or from `BuildHistory`.
struct BuildRun: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case running, succeeded, failed, stopped
        /// It ended without Cantrip seeing how (the run ended first, or Cantrip restarted).
        case ended
    }

    enum Kind: String, Codable {
        case build, transfer
    }

    /// What a transfer printed about its progress, and when Cantrip read it.
    struct TransferReading: Codable, Equatable {
        var progress: TransferProgress
        var at: Date
    }

    /// The tool call that ran the command.
    var id: String
    var title: String
    /// "Building", "Testing", "Archiving", "Uploading", "Downloading", "Transferring"…
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
    /// Nil for a build (and for cards saved before transfers had them).
    var kind: Kind?
    /// A transfer's first and newest progress readings: its rate and time left come from these.
    var firstReading: TransferReading?
    var reading: TransferReading?
    /// Waiting for a build slot (`BuildQueue`): what runs and its place in line. Its time starts
    /// once it gets one, so estimates and history leave the wait out.
    var queue: String?

    var isWaiting: Bool { state == .running && queue != nil }

    var duration: TimeInterval? { finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    var isTransfer: Bool { kind == .transfer }

    init(id: String, command: BuildCommand, startedAt: Date, estimate: BuildHistory.Estimate?) {
        self.id = id
        title = command.title
        verb = command.verb
        project = command.project
        key = command.key
        self.startedAt = startedAt
        expectedSeconds = estimate?.seconds
        timedRuns = estimate?.runs
        kind = command.isTransfer ? .transfer : nil
    }

    mutating func finish(_ state: State, exitCode: Int? = nil, at date: Date) {
        guard self.state == .running else { return }
        self.state = state
        self.exitCode = exitCode ?? self.exitCode
        finishedAt = state == .ended ? nil : max(date, startedAt)
    }

    /// Takes a running command's newest step counter and, for a transfer, its newest progress.
    /// True when the card moved.
    mutating func advance(step newStep: BuildStep?, transfer: TransferProgress?, queue queued: BuildQueueState? = nil,
                          at date: Date) -> Bool {
        guard state == .running else { return false }
        var moved = false
        switch queued {
        case .waiting(let detail) where queue != detail:
            queue = detail
            moved = true
        case .started where queue != nil:
            queue = nil
            startedAt = date
            moved = true
        default:
            break
        }
        if let newStep, newStep != step {
            step = newStep
            moved = true
        }
        if isTransfer, let transfer, TransferProgress.moves(reading?.progress, to: transfer) {
            let new = TransferReading(progress: transfer, at: max(date, startedAt))
            // Going back or to another total is another file or a restart: the rate starts again.
            let continues = firstReading.map { first in
                transfer.fraction >= (reading?.progress.fraction ?? first.progress.fraction)
                    && transfer.totalBytes == first.progress.totalBytes
            } ?? false
            if !continues { firstReading = new }
            reading = new
            moved = true
        }
        return moved
    }

    /// Bytes a second between the first and newest readings, once they're 5 seconds apart.
    var bytesPerSecond: Double? {
        guard let first = firstReading, let last = reading,
              let from = first.progress.bytes, let to = last.progress.bytes, to > from,
              first.progress.totalBytes == last.progress.totalBytes else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        return seconds >= 5 ? Double(to - from) / seconds : nil
    }

    /// When a transfer will be done at its rate so far, in seconds from `startedAt`: clients count
    /// the time left down from it, as from a build's usual time.
    var transferExpectedSeconds: Double? {
        guard let first = firstReading, let last = reading, last.progress.fraction < 1 else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        let done = last.progress.fraction - first.progress.fraction
        guard seconds >= 5, done > 0 else { return nil }
        return last.at.timeIntervalSince(startedAt) + (1 - last.progress.fraction) * seconds / done
    }
}

extension BuildRun {
    /// Finished builds listed under a reply's card; older ones are counted in the list's title.
    static let listedEarlier = 5
    /// Builds still running beside the leading one that get their own live progress block.
    static let parallelProgress = 3

    /// A reply's builds as one card that changes in place as the work moves on, instead of a
    /// card per command: the newest build still running (else the newest) leads with its header
    /// and live progress, other running builds follow with their own progress, and finished ones
    /// are rows under "Earlier steps" with their result and time.
    static func card(for runs: [BuildRun]) -> CardDocument? {
        guard let first = runs.first else { return nil }
        guard runs.count > 1 else { return first.document }
        let lead = runs.last { $0.state == .running } ?? runs[runs.count - 1]
        var blocks = [lead.headerBlock, lead.progressBlock]
        let parallel = runs.filter { $0.state == .running && $0.id != lead.id }
        for run in parallel.suffix(parallelProgress) {
            var progress = run.progressBlock
            progress.label = run.title
            progress.accessibilityLabel = [run.title, run.label, run.detail].joined(separator: ", ")
            blocks.append(progress)
        }
        let listed = Set(parallel.suffix(parallelProgress).map(\.id)).union([lead.id])
        let earlier = runs.filter { !listed.contains($0.id) }
        if !earlier.isEmpty {
            let shown = earlier.suffix(listedEarlier)
            var list = CardDocument.Block(type: "list")
            list.title = shown.count < earlier.count ? "Earlier steps · latest \(shown.count) of \(earlier.count)" : "Earlier steps"
            list.items = shown.map { $0.row(leadProject: lead.project) }
            let summary = earlierSummary(earlier, counted: shown.count == earlier.count)
            list.collapsed = true
            list.subtitle = summary.text
            list.tone = summary.tone
            blocks.append(list)
        }
        let steps = earlier.count + parallel.count
        var card = CardDocument(id: "build-" + first.id, type: lead.isTransfer ? "transfer" : "build",
                                accessibilityLabel: "\(lead.title), \(lead.label), and \(steps) other \(steps == 1 ? "step" : "steps")",
                                source: .init(kind: "build", name: lead.title), blocks: blocks)
        // A list's plain text leaves out notes, and here they hold each earlier step's result.
        let live = CardDocument(id: card.id, type: card.type, blocks: blocks.filter { $0.type != "list" }).plainText
        let rows = blocks.last { $0.type == "list" }.map { list in
            [list.title ?? ""] + (list.items ?? []).map { item in
                "• " + [item.title, item.subtitle, item.note, item.trailing].compactMap { $0 }.joined(separator: " — ")
            }
        } ?? []
        card.fallbackText = ([live] + rows).joined(separator: "\n")
        return card
    }

    /// The collapsed "Earlier steps" line: "4 steps · 1 failed", "3 steps · all succeeded" (the step
    /// count is left to the title when it already says "latest 5 of 8").
    static func earlierSummary(_ runs: [BuildRun], counted: Bool) -> (text: String, tone: String?) {
        func count(_ state: State) -> Int { runs.filter { $0.state == state }.count }
        let failed = count(.failed), stopped = count(.stopped), running = count(.running), ended = count(.ended)
        var parts = counted ? ["\(runs.count) \(runs.count == 1 ? "step" : "steps")"] : []
        if failed > 0 { parts.append("\(failed) failed") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        if running > 0 { parts.append("\(running) running") }
        if ended > 0 { parts.append("\(ended) ended") }
        let allSucceeded = failed + stopped + running + ended == 0
        if allSucceeded { parts.append(runs.count == 1 ? "succeeded" : "all succeeded") }
        var text = parts.joined(separator: " · ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        let tone: String? = failed > 0 ? "negative" : stopped > 0 ? "warning" : allSucceeded ? "positive" : nil
        return (text, tone)
    }

    /// The card: a header naming the command and its folder, then a `progress` block that
    /// clients tick locally from `startedAt` (no update from the Mac every second).
    var document: CardDocument {
        CardDocument(id: "build-" + id, type: isTransfer ? "transfer" : "build", accessibilityLabel: "\(title), \(label)",
                     source: .init(kind: "build", name: title), blocks: [headerBlock, progressBlock]).withFallbackText()
    }

    private var stateSymbol: String {
        switch state {
        case .running: isWaiting ? "hourglass" : runningSymbol
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle"
        case .ended: "questionmark.circle"
        }
    }

    private var headerBlock: CardDocument.Block {
        var header = CardDocument.Block(type: "header")
        header.symbol = stateSymbol
        header.title = title
        header.subtitle = project
        header.tone = state == .running ? nil : tone
        return header
    }

    /// A finished build as a row of a reply's card: its result (tinted) and how long it took.
    private func row(leadProject: String?) -> CardDocument.Item {
        var item = CardDocument.Item()
        item.id = id
        item.title = title
        item.subtitle = project == leadProject ? nil : project
        item.note = switch state {
        case .running: isWaiting ? "Waiting for a build slot" : [verb, "still running"].joined(separator: " · ")
        case .succeeded: [label, transferDetail].compactMap { $0 }.joined(separator: " · ")
        case .failed: label + " · " + detail
        case .stopped: transferDetail ?? label
        case .ended: detail
        }
        item.tone = tone
        item.trailing = duration.map(CardProgress.clock)
        item.accessibilityLabel = [title, item.subtitle, item.note,
                                   duration.map { "took " + CardProgress.spoken($0) }].compactMap { $0 }.joined(separator: ", ")
        return item
    }

    private var progressBlock: CardDocument.Block {
        var progress = CardDocument.Block(type: "progress")
        progress.status = state.rawValue
        progress.label = label
        progress.tone = tone
        progress.startedAt = Self.iso(startedAt)
        progress.finishedAt = finishedAt.map(Self.iso)
        if state == .running, !isWaiting {
            if let reading {
                // The transfer's own numbers: its share done, and the time left at its rate so far.
                progress.fraction = reading.progress.fraction
                progress.expectedSeconds = transferExpectedSeconds
            } else {
                progress.expectedSeconds = expectedSeconds
                if let step { progress.fraction = Double(step.current) / Double(step.total) }
            }
        }
        progress.detail = detail
        progress.accessibilityLabel = [label, detail].compactMap { $0 }.joined(separator: ", ")
        return progress
    }

    private var runningSymbol: String {
        switch verb {
        case "Downloading": "arrow.down.circle"
        case "Copying", "Syncing": "arrow.left.arrow.right"
        case "Uploading", "Notarizing", "Transferring", "Installing": "arrow.up.circle"
        default: "hammer"
        }
    }

    var label: String {
        switch state {
        case .running: isWaiting ? "Waiting" : verb
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
        if isWaiting, let queue {
            return "Waiting for a build slot" + (queue.isEmpty ? "" : " · " + queue)
        }
        if let transfer = transferDetail { return transfer }
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

    /// A transfer that printed its progress: how much of it is done ("27.0 GB of 29.1 GB", or
    /// "45%") and its rate, measured between Cantrip's readings.
    private var transferDetail: String? {
        guard let progress = reading?.progress else { return nil }
        let amount = if let bytes = progress.bytes, let total = progress.totalBytes {
            Self.bytesText(Double(bytes)) + " of " + Self.bytesText(Double(total))
        } else {
            "\(progress.percent)%"
        }
        let rate = bytesPerSecond.map { Self.bytesText($0) + "/s" }
        switch state {
        case .running:
            return [amount, rate].compactMap { $0 }.joined(separator: " · ")
        case .succeeded:
            guard let total = progress.totalBytes else { return nil }
            return [Self.bytesText(Double(total)), rate].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return (exitCode.map { "Exit code \($0)" } ?? "Failed") + " at " + amount
        case .stopped:
            return "Stopped at " + amount
        case .ended:
            return "Last read at \(amount); ended without a result Cantrip could read"
        }
    }

    /// "555 MB", "1.85 GB", "29.1 GB": counted in 1000s, as Finder does.
    static func bytesText(_ bytes: Double) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1000 else { return "\(Int(bytes)) bytes" }
        var value = bytes / 1000
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: value < 10 ? "%.2f %@" : value < 100 ? "%.1f %@" : "%.0f %@", value, units[index])
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

/// A build, upload or transfer command, as Cantrip names and remembers it.
struct BuildCommand: Equatable {
    /// "xcodebuild test · Hermes", "swift build", "make test", "App Store upload", "rsync · Roms"…
    var title: String
    var verb: String
    /// Where it ran: a `cd` (or `make -C`) in the command, else the tab's folder.
    var directory: String
    /// The same command in the same folder; estimates come from earlier runs with this key.
    var key: String
    /// It moves data (a copy, download, upload or device install): its card follows the bytes
    /// or percentage it prints.
    var isTransfer = false

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
        var found: [(title: String, verb: String, words: [String], directory: String, transfer: Bool)] = []
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
                    found.append((inner.title, inner.verb, [inner.key], inner.directory, inner.isTransfer))
                }
                continue
            }
            var runDirectory = directory
            if let match = match(words, name: name, directory: &runDirectory) {
                found.append((match.title, match.verb, words, runDirectory, false))
            } else if let moved = transfer(words, name: name) {
                found.append((moved.title, moved.verb, words, runDirectory, true))
            }
        }
        guard let first = found.first else { return nil }
        let titles = found.map(\.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let title = titles.prefix(2).joined(separator: " → ") + (titles.count > 2 ? " …" : "")
        let normalized = found.map { $0.words.map(normalizedWord).joined(separator: " ") }.joined(separator: " && ")
        return BuildCommand(title: String(title.prefix(90)), verb: first.verb, directory: first.directory,
                            key: first.directory + "\n" + normalized, isTransfer: first.transfer)
    }

    /// The command inside wrappers `ShellCommandText` leaves: xcrun, bundle exec, npx, timeout,
    /// `script -q LOG`, `perl -e '… exec @ARGV'`, `arch -arm64`, `cantrip env run … --`, and the
    /// script or module an interpreter runs (`python -u push.py`, `python -m pymobiledevice3`, `node build.js`).
    static func unwrapped(_ words: [String]) -> [String] {
        var words = words
        while let first = words.first {
            var rest = Array(words.dropFirst())
            func dropFlags() { while let flag = rest.first, flag.hasPrefix("-") { rest.removeFirst() } }
            let name = ShellCommandText.baseName(first)
            switch name {
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
            case "cantrip" where rest.starts(with: ["env", "run"]):
                // `cantrip env run --dir DIR -- COMMAND`: a project's environment, then the command.
                guard let separator = rest.firstIndex(of: "--") else { return words }
                rest = Array(rest[(separator + 1)...])
            case _ where name.range(of: #"^python[0-9.]*$"#, options: .regularExpression) != nil:
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest.removeFirst()
                    if flag == "-m" { break }
                    if flag == "-" || flag.hasPrefix("-c") { return words }
                    if ["-X", "-W"].contains(flag), !rest.isEmpty { rest.removeFirst() }
                }
            case "node", "tsx", "ts-node", "ruby":
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest.removeFirst()
                    if ["-e", "--eval", "-p", "--print"].contains(flag) { return words }
                    if ["-r", "--require", "--import", "--loader", "-I"].contains(flag), !rest.isEmpty { rest.removeFirst() }
                }
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

    /// `./build.sh`, `Scripts/build-home-window.sh`, `scripts/release.sh`, `build-fefw.py`: a script named for building.
    private static func buildScript(_ program: String) -> (String, String)? {
        guard isScript(program) else { return nil }
        let name = (program as NSString).lastPathComponent
        guard scriptWords(name).contains(where: ["build", "release", "archive"].contains) else { return nil }
        return (name, "Building")
    }

    private static let scriptExtensions: Set = ["sh", "bash", "zsh", "command", "py", "js", "mjs", "cjs", "ts", "rb", "pl"]

    private static func isScript(_ program: String) -> Bool {
        program.contains("/") || scriptExtensions.contains((program as NSString).pathExtension.lowercased())
    }

    /// `push-fefw-usb.py` → push, fefw, usb.
    private static func scriptWords(_ name: String) -> [String] {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = scriptExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
        return stem.lowercased().split(whereSeparator: { "-_.".contains($0) }).map(String.init)
    }

    // MARK: Transfers

    /// Copies, downloads, uploads and device installs: rsync, scp, rclone, `aws s3`, curl and wget
    /// downloads of big files, aria2c, Hugging Face and Ollama model pulls, `devicectl device copy`
    /// and `install app`, ios-deploy, pymobiledevice3, ideviceinstaller, adb, and scripts named for
    /// moving data (`push-…`, `upload_…`, `download-…`, `sync-…`).
    static func transfer(_ words: [String], name: String) -> (title: String, verb: String)? {
        let args = Array(words.dropFirst())
        func titled(_ tool: String, _ target: String?) -> String { tool + (targetName(target).map { " · " + $0 } ?? "") }
        switch name {
        case "rsync":
            guard !args.contains(where: { ["--dry-run", "--list-only", "--version", "--help"].contains($0) || shortFlags($0, contain: "n") })
            else { return nil }
            let paths = operands(args, valued: ["-e", "-f", "-T", "-B", "-M", "--rsh", "--filter", "--exclude", "--include",
                                                "--exclude-from", "--include-from", "--files-from", "--log-file", "--partial-dir",
                                                "--temp-dir", "--backup-dir", "--link-dest", "--compare-dest", "--copy-dest", "--port",
                                                "--timeout", "--bwlimit", "--chmod", "--chown", "--password-file", "--out-format",
                                                "--max-size", "--min-size", "--suffix", "--info", "--debug", "--remote-option",
                                                "--usermap", "--groupmap", "--iconv", "--max-delete", "--block-size", "--contimeout"])
            guard paths.count >= 2, let destination = paths.last else { return nil }
            return (titled("rsync", destination), direction(from: paths.dropLast(), to: destination))
        case "scp":
            let paths = operands(args, valued: ["-c", "-D", "-F", "-i", "-J", "-l", "-o", "-P", "-S", "-X"])
            guard paths.count >= 2, let destination = paths.last else { return nil }
            return (titled("scp", destination), direction(from: paths.dropLast(), to: destination))
        case "rclone":
            let words = operands(args, valued: ["--transfers", "--checkers", "--bwlimit", "--config", "--log-file", "--log-level",
                                                "--include", "--exclude", "--filter", "--files-from", "--include-from", "--exclude-from",
                                                "--max-age", "--min-age", "--max-size", "--min-size", "--stats", "--backup-dir",
                                                "--retries", "--timeout"])
            guard let sub = words.first, ["copy", "copyto", "sync", "bisync", "move", "moveto", "copyurl"].contains(sub),
                  words.count >= 3, !args.contains(where: { ["--dry-run", "-n", "--interactive", "-i"].contains($0) }) else { return nil }
            let verb = sub.hasSuffix("sync") ? "Syncing" : direction(from: [words[1]], to: words[2])
            return (titled("rclone \(sub)", words[2]), verb)
        case "aws":
            guard let s3 = args.firstIndex(of: "s3"), s3 + 1 < args.count, ["cp", "sync", "mv"].contains(args[s3 + 1]),
                  !args.contains("--dryrun") else { return nil }
            let paths = operands(Array(args[(s3 + 2)...]), valued: ["--profile", "--region", "--exclude", "--include",
                                                                   "--storage-class", "--acl", "--sse", "--content-type",
                                                                   "--cache-control", "--endpoint-url", "--metadata", "--expected-size"])
            guard paths.count >= 2 else { return nil }
            let remote = { (path: String) in path.hasPrefix("s3://") }
            let verb = remote(paths[1]) ? (remote(paths[0]) ? "Copying" : "Uploading") : remote(paths[0]) ? "Downloading" : "Copying"
            return (titled("aws s3 \(args[s3 + 1])", paths[1]), args[s3 + 1] == "sync" ? "Syncing" : verb)
        case "curl":
            return curl(args)
        case "wget":
            return wget(args)
        case "aria2c":
            let urls = operands(args, valued: ["-d", "--dir", "-o", "--out", "-i", "--input-file", "-x", "-s", "-j", "-k", "--max-tries"])
            return (titled("aria2c", urls.first.map(urlFileName)), "Downloading")
        case "huggingface-cli", "hf":
            let words = operands(args, valued: ["--local-dir", "--cache-dir", "--revision", "--include", "--exclude", "--repo-type", "--token"])
            guard let sub = words.first, sub == "download" || sub == "upload" else { return nil }
            return (titled("\(name) \(sub)", words.dropFirst().first), sub == "download" ? "Downloading" : "Uploading")
        case "ollama":
            guard let sub = args.first, sub == "pull" || sub == "push", args.count > 1 else { return nil }
            return ("ollama \(sub) · \(args[1])", sub == "pull" ? "Downloading" : "Uploading")
        case "devicectl":
            if args.starts(with: ["device", "copy", "to"]) || args.starts(with: ["device", "copy", "from"]) {
                let destination = value(of: ["--destination", "--dest"], in: args)
                return (titled("devicectl copy \(args[2])", destination), args[2] == "to" ? "Transferring" : "Downloading")
            }
            if args.starts(with: ["device", "install", "app"]) {
                return (titled("devicectl install", args.last { $0.hasSuffix(".app") || $0.hasSuffix(".ipa") }), "Installing")
            }
            return nil
        case "ios-deploy":
            if let bundle = value(of: ["-b", "--bundle"], in: args) { return (titled("ios-deploy", bundle), "Installing") }
            if let file = value(of: ["-o", "--upload"], in: args) { return (titled("ios-deploy upload", file), "Transferring") }
            if args.contains(where: { $0 == "-w" || $0.hasPrefix("--download") }) { return ("ios-deploy download", "Downloading") }
            return nil
        case "pymobiledevice3":
            let words = operands(args, valued: ["--udid", "--rsd", "--tunnel"])
            if words.starts(with: ["afc", "push"]) || words.starts(with: ["afc", "pull"]) {
                return (titled("pymobiledevice3 afc \(words[1])", words.count > 3 ? words[3] : nil),
                        words[1] == "push" ? "Transferring" : "Downloading")
            }
            if words.starts(with: ["apps", "install"]) { return (titled("pymobiledevice3 install", words.dropFirst(2).first), "Installing") }
            return nil
        case "ideviceinstaller":
            guard let index = args.firstIndex(where: { ["-i", "--install", "install"].contains($0) }) else { return nil }
            return (titled("ideviceinstaller", index + 1 < args.count ? args[index + 1] : nil), "Installing")
        case "adb":
            let words = operands(args, valued: ["-s", "-t", "-H", "-P", "-L"])
            guard let sub = words.first else { return nil }
            switch sub {
            case "push": return (titled("adb push", words.count > 2 ? words.last : nil), "Transferring")
            case "pull": return (titled("adb pull", words.dropFirst().first), "Downloading")
            case "install", "install-multiple": return (titled("adb install", words.last), "Installing")
            case "sync": return ("adb sync", "Syncing")
            default: return nil
            }
        case "bash", "sh", "zsh":
            guard let script = args.first, !script.hasPrefix("-") else { return nil }
            return transferScript(script)
        default:
            return words.first.flatMap(transferScript)
        }
    }

    /// `push-fefw-usb.py`, `scripts/upload-ipa.sh`, `download_models.py`: a script named for moving data.
    private static func transferScript(_ program: String) -> (String, String)? {
        guard isScript(program) else { return nil }
        let name = (program as NSString).lastPathComponent
        let verbs = ["push": "Transferring", "transfer": "Transferring", "upload": "Uploading", "download": "Downloading",
                     "pull": "Downloading", "sync": "Syncing", "rsync": "Syncing", "mirror": "Syncing", "copy": "Copying",
                     "backup": "Copying"]
        return scriptWords(name).lazy.compactMap { verbs[$0] }.first.map { (name, $0) }
    }

    /// A copy's direction: to a remote host (`host:path`, `user@host:path`, `rsync://`) is an
    /// upload, from one a download, and anything else a copy.
    private static func direction(from sources: some Collection<String>, to destination: String) -> String {
        let fromRemote = sources.contains(where: isRemote)
        switch (fromRemote, isRemote(destination)) {
        case (false, true): return "Uploading"
        case (true, false): return "Downloading"
        default: return "Copying"
        }
    }

    private static func isRemote(_ path: String) -> Bool {
        path.range(of: #"^(?:[a-z][a-z0-9+.-]*://|[^/:\s]+:)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a path or URL names, for a card's title: `nas:/Volumes/Roms/` → Roms.
    private static func targetName(_ target: String?) -> String? {
        guard var path = target, !path.isEmpty, !path.contains("$") else { return nil }
        if path.contains("://") { return urlFileName(path) }
        if isRemote(path), let colon = path.firstIndex(of: ":") {
            let rest = String(path[path.index(after: colon)...])
            if rest.trimmingCharacters(in: CharacterSet(charactersIn: "/.~")).isEmpty { return String(path[..<colon]) }
            path = rest
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        return [".", "..", "~", "/", ""].contains(name) ? nil : String(name.prefix(60))
    }

    private static func urlFileName(_ url: String) -> String {
        let path = URL(string: url)?.path ?? url
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? (URL(string: url)?.host ?? url) : name
    }

    /// The words that aren't options or option values: `valued` options take the next word.
    private static func operands(_ args: [String], valued: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            index += 1
            if word == "--" {
                result += args[index...]
                break
            }
            if word.hasPrefix("-"), word.count > 1 {
                if valued.contains(word) { index += 1 }
                continue
            }
            result.append(word)
        }
        return result
    }

    private static func value(of options: [String], in args: [String]) -> String? {
        for (index, word) in args.enumerated() {
            if options.contains(word), index + 1 < args.count { return args[index + 1] }
            if let option = options.first(where: { $0.hasPrefix("--") && word.hasPrefix($0 + "=") }) {
                return String(word.dropFirst(option.count + 1))
            }
        }
        return nil
    }

    /// `-avn` holds `-n`.
    private static func shortFlags(_ word: String, contain letter: Character) -> Bool {
        word.hasPrefix("-") && !word.hasPrefix("--") && word.count > 1 && word.dropFirst().contains(letter)
    }

    /// Downloads worth a card: files with a big file's extension (archives, disk images, apps,
    /// media, models), resumed ones, or ones that draw a progress bar; not API calls or pages.
    private static let bigFileExtensions: Set = [
        "zip", "xip", "ipa", "apk", "aab", "dmg", "pkg", "iso", "img", "tar", "tgz", "gz", "bz2", "xz", "zst", "7z", "rar",
        "bin", "mp4", "mkv", "mov", "m4v", "avi", "mp3", "flac", "wav", "nsp", "xci", "nsz", "gguf", "safetensors", "ckpt",
        "pt", "pth", "onnx", "deb", "rpm", "exe", "msi", "appimage", "vmdk", "qcow2", "ova", "raw",
    ]

    private static func isBigFile(_ name: String?) -> Bool {
        guard let name else { return false }
        return bigFileExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func curl(_ args: [String]) -> (String, String)? {
        let valuedShort = Set("AbcCdDeEFHKmoPQrTuUwxXyYz")
        let valuedLong: Set = ["--output", "--upload-file", "--continue-at", "--url", "--header", "--data", "--data-binary",
                               "--data-raw", "--data-urlencode", "--request", "--user", "--user-agent", "--referer", "--cookie",
                               "--cookie-jar", "--form", "--max-time", "--write-out", "--proxy", "--config", "--range", "--retry",
                               "--retry-delay", "--retry-max-time", "--connect-timeout", "--limit-rate", "--cacert", "--cert",
                               "--key", "--resolve", "--dump-header", "--output-dir", "--speed-limit", "--speed-time", "--max-filesize"]
        var output: String?
        var upload: String?
        var remoteName = false
        var resumed = false
        var bar = false
        var urls: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            index += 1
            let next = index < args.count ? args[index] : nil
            if word.hasPrefix("--") {
                let option = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
                let inline = word.contains("=") ? String(word.drop(while: { $0 != "=" }).dropFirst()) : nil
                let given = inline ?? next
                switch option {
                case "--output": output = given
                case "--upload-file": upload = given
                case "--continue-at": resumed = true
                case "--url": if let given { urls.append(given) }
                case "--remote-name", "--remote-name-all": remoteName = true
                case "--progress-bar": bar = true
                default: break
                }
                if inline == nil, valuedLong.contains(option) { index += 1 }
            } else if word.hasPrefix("-"), word.count > 1 {
                // `-sSLo FILE`, `-ofile.zip`, `-LO`: flags up to the first one that takes a value,
                // which is the rest of the cluster or the next word.
                let letters = Array(word.dropFirst())
                let at = letters.firstIndex(where: valuedShort.contains)
                let flags = at.map { letters[..<$0] } ?? letters[...]
                if flags.contains("O") { remoteName = true }
                if flags.contains("#") { bar = true }
                guard let at else { continue }
                let attached = at + 1 < letters.count ? String(letters[(at + 1)...]) : nil
                let given = attached ?? next
                switch letters[at] {
                case "o": output = given
                case "T": upload = given
                case "C": resumed = true
                default: break
                }
                if attached == nil { index += 1 }
            } else {
                urls.append(word)
            }
        }
        if let upload {
            return isBigFile(upload) || resumed || bar ? ("curl · " + (targetName(upload) ?? upload), "Uploading") : nil
        }
        guard (output != nil && output != "-" && output != "/dev/null") || remoteName else { return nil }
        let name = output.flatMap(targetName) ?? urls.first.map(urlFileName)
        guard isBigFile(name) || resumed || bar else { return nil }
        return ("curl" + (name.map { " · " + $0 } ?? ""), "Downloading")
    }

    private static func wget(_ args: [String]) -> (String, String)? {
        guard !args.contains("--spider") else { return nil }
        let valuedShort = Set("OoPatTwQeUiBlARDXI")
        var output: String?
        var resumed = false
        var urls: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            index += 1
            if word.hasPrefix("--") {
                if word == "--continue" { resumed = true }
                if word.hasPrefix("--output-document=") { output = String(word.dropFirst("--output-document=".count)) }
                if word == "--output-document", index < args.count { output = args[index]; index += 1 }
            } else if word.hasPrefix("-"), word.count > 1 {
                let letters = Array(word.dropFirst())
                let at = letters.firstIndex(where: valuedShort.contains)
                if (at.map { letters[..<$0] } ?? letters[...]).contains("c") { resumed = true }
                guard let at else { continue }
                let attached = at + 1 < letters.count ? String(letters[(at + 1)...]) : nil
                if letters[at] == "O" { output = attached ?? (index < args.count ? args[index] : nil) }
                if attached == nil { index += 1 }
            } else {
                urls.append(word)
            }
        }
        let name = (output == "-" ? nil : output.flatMap(targetName)) ?? urls.first.map(urlFileName)
        guard isBigFile(name) || resumed else { return nil }
        return ("wget" + (name.map { " · " + $0 } ?? ""), "Downloading")
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
                    let printed = run.isTransfer ? TransferProgress.latest(in: output) ?? step.transfer : nil
                    if step.state != .succeeded, BuildOutput.neverRan(output) {
                        working.remove(run, at: index)
                    } else if let shell = BuildOutput.backgroundShell(in: output) {
                        run.shellID = shell
                        _ = run.advance(step: step.buildStep, transfer: printed, at: now)
                        working.put(run, at: index, ended: false)
                    } else {
                        // Its last progress says where a failed or stopped transfer got to.
                        _ = run.advance(step: nil, transfer: printed, at: now)
                        let (state, code) = BuildOutput.outcome(output: output, state: step.state)
                        run.finish(state, exitCode: code, at: now)
                        working.put(run, at: index, ended: true)
                    }
                } else if run.advance(step: step.buildStep, transfer: step.transfer, queue: step.buildQueue, at: now) {
                    working.put(run, at: index, ended: false)
                }
                continue
            }
            if step.state == .running {
                guard seen.starts.insert(step.id).inserted, let command = step.terminalCommand,
                      let detected = BuildDetector.detect(command, workdir: workdir) else { continue }
                var run = BuildRun(id: step.id, command: detected, startedAt: now, estimate: history.estimate(for: detected.key))
                _ = run.advance(step: nil, transfer: nil, queue: step.buildQueue, at: now)
                working.put(run, at: messageIndex, ended: false)
                known.insert(step.id)
                continue
            }
            // A finished step that isn't a build: reading or stopping a build's background shell.
            guard seen.ends.insert(step.id).inserted,
                  working.find({ $0.state == .running && $0.shellID != nil }) != nil else { continue }
            let output = Self.output(of: step)
            // Reading a transfer's background shell (read_bash, BashOutput): its newest progress.
            if let shell = Self.shellRead(by: step),
               let (index, found) = working.find({ $0.state == .running && $0.shellID == shell && $0.isTransfer }) {
                var run = found
                if run.advance(step: nil, transfer: TransferProgress.latest(in: output), at: now) {
                    working.put(run, at: index, ended: false)
                }
            }
            for shell in BuildOutput.finishedShells(in: output) {
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

    /// The background shell a step reads: Copilot's `read_bash`/`write_bash`, Claude's `BashOutput`/`TaskOutput`.
    private static func shellRead(by step: ToolActivity) -> String? {
        guard ["readbash", "writebash", "bashoutput", "taskoutput"].contains(ToolCards.normalized(step.toolName)),
              let input = step.input, let object = JSONPrefix.firstObject(in: input) else { return nil }
        for key in ["shellId", "shell_id", "bash_id", "task_id"] {
            if let id = object[key] as? String { return id }
            if let id = object[key] as? NSNumber { return id.stringValue }
        }
        return nil
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
