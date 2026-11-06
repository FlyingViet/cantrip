import Foundation

// MARK: - Build queue (docs/updating-and-troubleshooting.md "Heavy builds take turns")

/// Heavy builds on this Mac take turns. With the build queue on (Settings › Home & tabs, off by
/// default), Cantrip puts a folder of small shims for `xcodebuild`, `swift build|test` and `swiftc`
/// at the front of the PATH it gives agents and their terminals (and the GitHub runners use it
/// too). A heavy invocation runs as `cantrip build-queue run`, which waits for one of a few build
/// slots, runs the real tool, and frees the slot when it exits. Your tabs go first, then child tabs
/// and CI jobs, then Cantrip Home's background runs.
///
/// Slots are `flock` locks on files, so a crashed build never keeps one, and the queue works
/// without Cantrip running. Nested tools (the `swift build` inside `make app`) run in their
/// parent's slot.
enum BuildQueue {
    /// Lines the wrapper prints on stderr; build cards read them (`BuildQueueState`).
    static let marker = BuildQueueState.marker
    /// Set for a build holding a slot, so the tools it runs don't wait for another.
    static let slotVariable = "CANTRIP_BUILD_SLOT"
    static let maximumSlots = 4
    static let defaultSlots = 2
    /// The tools the shims stand in for.
    static let tools = ["xcodebuild", "swift", "swiftc"]

    static var directory: URL { CantripPaths.cache("build-queue") }
    static var shimFolder: URL { directory.appendingPathComponent("bin", isDirectory: true) }

    // MARK: Policy

    struct Policy: Equatable {
        var slots: Int
        /// 1-minute load per core above which only one build runs. One build on its own reaches
        /// about 1.0-1.2, so this is two or more running, or other heavy work.
        static let busyLoadPerCore = 1.5

        init(slots: Int) { self.slots = min(max(slots, 1), BuildQueue.maximumSlots) }

        /// Builds that may run at once now: one while the Mac is busy or short of memory.
        func limit(_ resources: Resources) -> Int {
            resources.isBusy ? 1 : slots
        }
    }

    struct Resources: Equatable {
        var load: Double
        var cores: Int
        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        var memoryPressure: Int

        var loadPerCore: Double { load / Double(max(cores, 1)) }
        var isBusy: Bool { memoryPressure >= 2 || loadPerCore >= Policy.busyLoadPerCore }

        var reason: String? {
            if memoryPressure >= 2 { return "macOS reports memory pressure" }
            if loadPerCore >= Policy.busyLoadPerCore {
                return "the Mac is busy (load \(String(format: "%.0f", load)) on \(cores) cores)"
            }
            return nil
        }

        static func current() -> Resources {
            var averages = [Double](repeating: 0, count: 3)
            let load = getloadavg(&averages, 3) > 0 ? averages[0] : 0
            return Resources(load: load, cores: ProcessInfo.processInfo.activeProcessorCount,
                             memoryPressure: SimulatorPool.Memory.current().pressureLevel)
        }
    }

    // MARK: Priority

    enum Priority: Int, Codable, Comparable {
        case tab = 0, child = 1, ci = 2, background = 3

        /// Child tabs and CI jobs share a turn order: whichever asked first.
        var rank: Int {
            switch self {
            case .tab: 0
            case .child, .ci: 1
            case .background: 2
            }
        }

        var label: String {
            switch self {
            case .tab: "a tab"
            case .child: "a child tab"
            case .ci: "a CI job"
            case .background: "a Home background run"
            }
        }

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rank < rhs.rank }
    }

    /// Who's asking: a GitHub Actions job, or the tab named by `CANTRIP_TAB_ID` (a child tab that's
    /// still working, a Home background run with a live journal, or else one of your tabs).
    static func priority(environment: [String: String] = ProcessInfo.processInfo.environment,
                         childTabs: URL = CantripPaths.cache("child-tabs.json"),
                         homeRuns: URL = CantripHomeStore.rootDirectory.appendingPathComponent("runs", isDirectory: true)) -> Priority {
        if environment["GITHUB_ACTIONS"] == "true" { return .ci }
        guard let raw = environment[TabInsight.tabIDVariable], let id = UUID(uuidString: raw) else { return .tab }
        if let data = try? Data(contentsOf: childTabs),
           let records = try? JSONDecoder().decode([ChildTab].self, from: data),
           records.contains(where: { $0.id == id && !$0.state.isSettled }) {
            return .child
        }
        if FileManager.default.fileExists(atPath: homeRuns.appendingPathComponent("\(id.uuidString).jsonl").path) {
            return .background
        }
        return .tab
    }

    // MARK: Waiting and running

    /// A build waiting for a slot.
    struct Ticket: Codable, Equatable {
        var pid: Int32
        var priority: Priority
        var enqueuedAt: Double
        var title: String

        /// Turn order: priority, then who asked first.
        func goesBefore(_ other: Ticket) -> Bool {
            if priority.rank != other.priority.rank { return priority.rank < other.priority.rank }
            if enqueuedAt != other.enqueuedAt { return enqueuedAt < other.enqueuedAt }
            return pid < other.pid
        }
    }

    /// A build holding a slot.
    struct Holder: Codable, Equatable {
        var pid: Int32
        var priority: Priority
        var since: Double
        var title: String
    }

    /// Whether `ticket` may take a slot now: it's first in line and fewer than `limit` builds run.
    static func admits(_ ticket: Ticket, waiting: [Ticket], running: Int, limit: Int) -> Bool {
        running < limit && !waiting.contains { $0 != ticket && $0.goesBefore(ticket) }
    }

    /// The queue's files: tickets in `waiting/`, slot locks in `slots/`, one lock for admission.
    struct Store {
        var directory: URL

        var waitingFolder: URL { directory.appendingPathComponent("waiting", isDirectory: true) }
        var slotsFolder: URL { directory.appendingPathComponent("slots", isDirectory: true) }

        func prepare() throws {
            for folder in [waitingFolder, slotsFolder] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func slotURL(_ index: Int) -> URL { slotsFolder.appendingPathComponent("slot-\(index).lock") }

        /// Live tickets; a ticket whose process is gone is removed.
        func tickets() -> [Ticket] {
            let files = (try? FileManager.default.contentsOfDirectory(at: waitingFolder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url), let ticket = try? JSONDecoder().decode(Ticket.self, from: data) else {
                    return nil
                }
                guard BuildQueue.isAlive(ticket.pid) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return ticket
            }
        }

        func write(_ ticket: Ticket) throws {
            try JSONEncoder().encode(ticket).write(to: waitingFolder.appendingPathComponent("\(ticket.pid).json"), options: .atomic)
        }

        func removeTicket(pid: Int32) {
            try? FileManager.default.removeItem(at: waitingFolder.appendingPathComponent("\(pid).json"))
        }

        /// Builds holding a slot: a slot is held while another open file keeps its lock.
        func holders() -> [Holder] {
            (0..<BuildQueue.maximumSlots).compactMap { index in
                let url = slotURL(index)
                let fd = open(url.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                defer { close(fd) }
                if flock(fd, LOCK_SH | LOCK_NB) == 0 {
                    flock(fd, LOCK_UN)
                    return nil
                }
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      let holder = try? JSONDecoder().decode(Holder.self, from: data) else {
                    return Holder(pid: 0, priority: .tab, since: 0, title: "a build")
                }
                return holder
            }
        }

        /// Runs `body` while holding the admission lock, so counting slots and taking one is atomic.
        func admitting<T>(_ body: () throws -> T) rethrows -> T {
            let fd = open(directory.appendingPathComponent("admission.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            if fd >= 0 { flock(fd, LOCK_EX) }
            defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
            return try body()
        }

        /// Takes a free slot below `limit` and records `holder` in it; the descriptor holds it.
        func take(as holder: Holder, limit: Int) -> (index: Int, descriptor: Int32)? {
            for index in 0..<min(max(limit, 1), BuildQueue.maximumSlots) {
                let fd = open(slotURL(index).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
                guard fd >= 0 else { continue }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    ftruncate(fd, 0)
                    if let data = try? JSONEncoder().encode(holder) {
                        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
                    }
                    return (index, fd)
                }
                close(fd)
            }
            return nil
        }
    }

    static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// "xcodebuild archive · Cantrip", "swift build · Mems": what the status and cards call it.
    static func title(tool: String, arguments: [String], directory: String) -> String {
        let action: String? = switch tool {
        case "swift": arguments.first
        case "xcodebuild": arguments.first { ["build", "archive", "test", "build-for-testing", "test-without-building", "analyze"].contains($0) }
        default: nil
        }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return ([tool, action].compactMap { $0 }.joined(separator: " ")) + (folder.isEmpty ? "" : " · \(folder)")
    }

    /// The line a waiting build prints: what runs, and its place in line.
    static func waitingLine(running: [Holder], ahead: Int, limit: Int, reason: String?) -> String {
        let names = running.map(\.title).joined(separator: ", ")
        var parts = ["waiting for a build slot"]
        parts.append(running.isEmpty ? "starting next" : "\(running.count) running: \(names)")
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if let reason, limit == 1 { parts.append("1 at a time while \(reason)") }
        return "\(marker) " + parts.joined(separator: " · ")
    }

    /// Waits for a slot, runs `executable` with `arguments`, frees the slot, and returns its exit
    /// status (128 + signal when a signal ended it). Prints `cantrip build queue:` lines while it waits.
    static func run(executable: String, arguments: [String], tool: String, policy: Policy,
                    store: Store = Store(directory: directory), priority: Priority = BuildQueue.priority(),
                    resources: @escaping () -> Resources = Resources.current,
                    poll: TimeInterval = 1, reprint: TimeInterval = 30,
                    stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        do { try store.prepare() } catch {
            stderr("\(marker) can't use \(store.directory.path) (\(error.localizedDescription)); running without waiting")
            return launch(executable, arguments, slot: nil)
        }
        let pid = getpid()
        let title = Self.title(tool: tool, arguments: arguments, directory: FileManager.default.currentDirectoryPath)
        let ticket = Ticket(pid: pid, priority: priority, enqueuedAt: Date().timeIntervalSince1970, title: title)
        try? store.write(ticket)
        var waited = false
        var lastLine: String?
        var lastPrinted = Date.distantPast
        var taken: (index: Int, descriptor: Int32)?
        while taken == nil {
            let now = resources()
            let limit = policy.limit(now)
            let outcome: (taken: (index: Int, descriptor: Int32)?, line: String?) = store.admitting {
                let waiting = store.tickets()
                let running = store.holders()
                if admits(ticket, waiting: waiting, running: running.count, limit: limit),
                   let slot = store.take(as: Holder(pid: pid, priority: priority, since: Date().timeIntervalSince1970, title: title),
                                         limit: limit) {
                    store.removeTicket(pid: pid)
                    return (slot, nil)
                }
                let ahead = waiting.filter { $0 != ticket && $0.goesBefore(ticket) }.count
                return (nil, waitingLine(running: running, ahead: ahead, limit: limit, reason: now.reason))
            }
            if let slot = outcome.taken {
                taken = slot
                break
            }
            if let line = outcome.line, line != lastLine || Date().timeIntervalSince(lastPrinted) >= reprint {
                stderr(line)
                lastLine = line
                lastPrinted = Date()
            }
            waited = true
            Thread.sleep(forTimeInterval: poll)
        }
        guard let slot = taken else { return 1 }
        if waited { stderr("\(marker) started \(title)") }
        defer {
            flock(slot.descriptor, LOCK_UN)
            close(slot.descriptor)
        }
        return launch(executable, arguments, slot: slot.index)
    }

    /// The queue is off: run the tool as it is.
    static func runWithoutWaiting(executable: String, arguments: [String]) -> Int32 {
        launch(executable, arguments, slot: nil)
    }

    /// Runs the tool with this process's standard input and output, passing on Ctrl-C and termination.
    private static func launch(_ executable: String, _ arguments: [String], slot: Int?) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[slotVariable] = slot.map(String.init) ?? "none"
        process.environment = environment
        let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
        var sources: [DispatchSourceSignal] = []
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { if process.isRunning { kill(process.processIdentifier, number) } }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("\(marker) couldn't run \(executable): \(error.localizedDescription)\n".utf8))
            return 127
        }
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }

    // MARK: Shims

    /// Puts the shims in place (`cantrip` is the executable they hand heavy builds to), or removes
    /// them. Their folder goes at the front of the PATH Cantrip gives tools while they exist.
    static func apply(enabled: Bool, executable: String? = Bundle.main.executablePath, folder: URL = shimFolder) {
        if enabled, let executable {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for tool in tools {
                    let url = folder.appendingPathComponent(tool)
                    let script = shim(tool: tool, cantrip: executable)
                    if (try? String(contentsOf: url, encoding: .utf8)) != script {
                        try script.write(to: url, atomically: true, encoding: .utf8)
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                ToolPath.leadingFolders = [folder.path]
            } catch {
                Log.write("build-queue: couldn't install its shims: \(error.localizedDescription)")
                ToolPath.leadingFolders = []
            }
        } else {
            for tool in tools { try? FileManager.default.removeItem(at: folder.appendingPathComponent(tool)) }
            ToolPath.leadingFolders = []
        }
    }

    /// A POSIX shell script standing in for `tool`: heavy invocations go to `cantrip build-queue
    /// run` with the real tool (the next one on PATH); everything else, and anything already
    /// inside a build's slot, runs the real tool directly.
    static func shim(tool: String, cantrip: String) -> String {
        let heavy: String = switch tool {
        case "xcodebuild":
            """
            heavy=1
            for a in "$@"; do
              case "$a" in
                -version|-showsdks|-list|-showBuildSettings|-showdestinations|-showTestPlans|-help|-usage|-license|\\
                -downloadPlatform|-downloadAllPlatforms|-importPlatform|-exportArchive|-runFirstLaunch|\\
                -checkFirstLaunchStatus|-find|-find-*|-showComponent|-exportLocalizations|-importLocalizations|\\
                -resolvePackageDependencies|-create-xcframework) heavy=0 ;;
              esac
            done
            """
        case "swift":
            """
            heavy=0
            case "$1" in build|test) heavy=1 ;; esac
            """
        default:
            """
            heavy=0
            [ $# -gt 0 ] && heavy=1
            for a in "$@"; do
              case "$a" in
                -version|--version|-v|-print-target-info|-print-supported-features|-frontend|-help|--help) heavy=0 ;;
              esac
            done
            """
        }
        return """
        #!/bin/sh
        # Cantrip build queue ("Heavy builds take turns" in Cantrip's docs): a heavy `\(tool)` waits for a build slot first.
        # Written by Cantrip while the queue is on; removed when it's off.
        tool=\(tool)
        cantrip='\(cantrip.replacingOccurrences(of: "'", with: "'\\''"))'
        case "$0" in */*) here=${0%/*} ;; *) here=. ;; esac
        here=$(CDPATH= cd -- "$here" && pwd)
        real=
        saved_ifs=$IFS
        IFS=:
        for d in $PATH; do
          [ -z "$d" ] && continue
          [ "$d" = "$here" ] && continue
          if [ -f "$d/$tool" ] && [ -x "$d/$tool" ]; then real="$d/$tool"; break; fi
        done
        IFS=$saved_ifs
        if [ -z "$real" ]; then echo "\(marker) $tool isn't on PATH" >&2; exit 127; fi
        \(heavy)
        if [ "$heavy" = 1 ] && [ -z "${\(slotVariable):-}" ] && [ -x "$cantrip" ]; then
          exec "$cantrip" build-queue run --tool "$tool" -- "$real" "$@"
        fi
        exec "$real" "$@"

        """
    }

    // MARK: Status

    static func statusText(store: Store = Store(directory: directory), policy: Policy, enabled: Bool,
                           resources: Resources = .current()) -> String {
        let running = store.holders()
        let waiting = store.tickets().sorted { $0.goesBefore($1) }
        let limit = policy.limit(resources)
        var lines = ["Build queue: " + (enabled
            ? "on, \(limit) at a time" + (limit < policy.slots ? " (of \(policy.slots); \(resources.reason ?? "busy"))" : "")
            : "off (cantrip config set buildQueueEnabled true)")]
        let now = Date().timeIntervalSince1970
        lines.append(running.isEmpty ? "Running: none" : "Running:")
        for holder in running {
            lines.append("  \(holder.title) — \(holder.priority.label), \(SubagentInfo.elapsedLabel(max(0, now - holder.since)))"
                         + (holder.pid > 0 ? ", pid \(holder.pid)" : ""))
        }
        lines.append(waiting.isEmpty ? "Waiting: none" : "Waiting:")
        for (place, ticket) in waiting.enumerated() {
            lines.append("  \(place + 1). \(ticket.title) — \(ticket.priority.label), "
                         + "\(SubagentInfo.elapsedLabel(max(0, now - ticket.enqueuedAt))), pid \(ticket.pid)")
        }
        return lines.joined(separator: "\n")
    }
}
