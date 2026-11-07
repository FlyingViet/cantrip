import Darwin
import Foundation

// MARK: - Long jobs on this Mac (docs/cantrip-home.md "Background")

/// Long work on this Mac besides the build queue's builds: shader compiles, exports, archive steps,
/// backups, a script someone left running. A process group of this user counts once it runs under
/// `caffeinate`, runs a build, compile or copy tool, or keeps about a core busy for two looks in a
/// row; it then stays listed until it exits. Agents, apps and system processes never count, and a
/// launchd service only while it runs one of those tools. Builds holding or waiting for a build
/// slot are matched to their group, so the queue's own entries carry the same details.
///
/// Read-only: `ps`, `lsof` (never blocking on network volumes) and one variable,
/// `CANTRIP_TAB_ID`, from the group leader's environment. Nothing else is read or kept.
enum MachineJobs {
    /// The variable Cantrip sets for every command a tab runs (`TabInsight.tabIDVariable`).
    static let tabIDVariable = "CANTRIP_TAB_ID"

    struct ProcessRow: Equatable {
        var pid: Int32
        var ppid: Int32
        var group: Int32
        var uid: UInt32
        /// `ps` state letters: R running, S sleeping, U/D waiting on disk, T stopped.
        var state: String
        var age: TimeInterval
        /// Percent of one core.
        var cpu: Double
        var memory: Int64
        var arguments: String
        var name: String
    }

    enum State: String, Equatable {
        case running
        /// Every busy process is waiting on disk (often a network volume).
        case waitingOnDisk
        case idle
        /// Stopped (SIGSTOP), e.g. to let another job go first.
        case paused
    }

    struct Job: Equatable {
        /// Process group and start time: the same group restarted is a new job.
        var key: String
        var group: Int32
        var processIDs: [Int32]
        var title: String
        var project: String?
        /// What it's doing now, when that differs from the title.
        var step: String?
        var state: State
        var since: Double
        /// Percent of the whole Mac.
        var cpu: Double
        var memory: Int64
        var processes: Int
        var tabID: String?
        var logFile: String?
        var logLine: String?
        var logUpdatedAt: Double?
    }

    /// Tools that make a group a job on their own: builds, compiles, packaging, big copies, backups.
    static let drivers: Set<String> = [
        "xcodebuild", "swift-build", "make", "gmake", "ninja", "cmake", "cargo", "gradle", "gradlew", "dotnet",
        "msbuild", "metal", "metallib", "air-lld", "ffmpeg", "HandBrakeCLI", "rsync", "ditto", "restic", "rclone",
        "borg", "notarytool", "altool", "xcodes",
    ]
    static let compilers: Set<String> = [
        "swift-frontend", "swiftc", "clang", "clang++", "cc", "c++", "ld", "ld64", "rustc", "javac", "kotlinc", "go", "tsc",
    ]
    /// Launchers and shells that never name a job.
    static let launchers: Set<String> = [
        "bash", "sh", "zsh", "dash", "env", "python", "python3", "Python", "node", "caffeinate", "Cantrip", "nohup",
        "sudo", "time", "exec", "nice", "timeout", "gtimeout", "uv", "npx", "xcrun", "arch", "tee", "sleep", "cd",
        "set", "export",
    ]

    // MARK: Reading `ps`

    static let psArguments = ["-A", "-ww", "-o", "pid=,ppid=,pgid=,uid=,stat=,etime=,pcpu=,rss=,args="]

    /// `ps -A -ww -o pid=,ppid=,pgid=,uid=,stat=,etime=,pcpu=,rss=,args=` by process ID.
    static func parse(ps text: String) -> [Int32: ProcessRow] {
        var processes: [Int32: ProcessRow] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let group = Int32(fields[2]),
                  let uid = UInt32(fields[3]), let age = elapsed(String(fields[5])), let cpu = Double(fields[6]),
                  let kilobytes = Int64(fields[7]) else { continue }
            let arguments = String(fields[8])
            let executable = arguments.split(separator: " ", maxSplits: 1).first.map(String.init) ?? arguments
            processes[pid] = ProcessRow(pid: pid, ppid: ppid, group: group, uid: uid, state: String(fields[4]), age: age,
                                         cpu: cpu, memory: kilobytes * 1024, arguments: arguments,
                                         name: (executable as NSString).lastPathComponent)
        }
        return processes
    }

    /// `ps` elapsed time "[[dd-]hh:]mm:ss" in seconds.
    static func elapsed(_ text: String) -> TimeInterval? {
        let dayParts = text.split(separator: "-")
        guard (1...2).contains(dayParts.count), let clock = dayParts.last else { return nil }
        let days = dayParts.count == 2 ? Int(dayParts[0]) : 0
        let parts = clock.split(separator: ":").map { Int($0) }
        guard let days, (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = Array(repeating: 0, count: 3 - parts.count) + parts.compactMap { $0 }
        return TimeInterval(days * 86_400 + values[0] * 3_600 + values[1] * 60 + values[2])
    }

    // MARK: Naming

    /// A short name for a command line: "xcodebuild archive · App", "swift build", "make app",
    /// "render-assets.py", "rsync".
    static func summary(_ arguments: String) -> String {
        let text = arguments.replacingOccurrences(of: "\\012", with: "\n")
        if let rest = firstMatch(#"\bxcodebuild\b(.*)"#, in: text, group: 1) {
            let actions = ["archive", "test", "build-for-testing", "test-without-building", "build", "clean"]
            let action = actions.first { firstMatch("(^|\\s)\($0)(\\s|$)", in: rest, group: 0) != nil } ?? "build"
            let scheme = firstMatch(#"-scheme\s+['"]?([^'"\s]+)"#, in: rest, group: 1)
            return "xcodebuild \(action)" + (scheme.map { " · \($0)" } ?? "")
        }
        if let verb = firstMatch(#"\bswift\s+(build|test|run)\b"#, in: text, group: 1) { return "swift \(verb)" }
        if let tool = firstMatch(#"(?:^|[;&|\s])(make|gmake|ninja)\s+([\w.-]+)"#, in: text, group: 1),
           let target = firstMatch(#"(?:^|[;&|\s])(?:make|gmake|ninja)\s+([\w.-]+)"#, in: text, group: 1),
           !target.hasPrefix("-") {
            return "\(tool) \(target)"
        }
        if let script = firstMatch(#"([\w.@+-]+\.(?:py|sh|js|mjs|cjs|ts|rb|pl|swift|ps1))\b"#, in: text, group: 1) {
            return script
        }
        for token in text.components(separatedBy: CharacterSet(charactersIn: " \t\n;&|()")) {
            let name = (token.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) as NSString).lastPathComponent
            if !name.isEmpty, !name.contains("="), !name.hasPrefix("-"), !launchers.contains(name),
               firstMatch(#"^[A-Za-z][\w.+-]*$"#, in: name, group: 0) != nil {
                return name
            }
        }
        let executable = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let name = (executable as NSString).lastPathComponent
        return name.isEmpty ? "A job" : name
    }

    /// The project a command works in: a folder under ~/Coding, a worktree, or a build volume's projects.
    static func project(in texts: [String]) -> String? {
        for text in texts {
            if let name = firstMatch(#"/(?:Coding|projects|worktrees)/([A-Za-z0-9][\w.+-]*)"#, in: text, group: 1) {
                return name
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Logs

    /// The last line a job printed to its log: progress bars redraw with \r, colors are dropped,
    /// anything that looks like a secret is masked.
    static func lastLine(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
        let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
        for raw in text.components(separatedBy: "\n").reversed() {
            var line = raw
            if let ansi { line = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "") }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return String(masked(line).prefix(220))
        }
        return nil
    }

    static func masked(_ line: String) -> String {
        var line = line
        let patterns = [#"(?i)((?:bearer|token|key|password|secret)[=:\s]+)\S+"#, #"\b[A-Za-z0-9_\-]{40,}\b"#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            line = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line),
                                                  withTemplate: index == 0 ? "$1•••" : "•••")
        }
        return line
    }

    /// Files each process writes that look like logs (its stdout/stderr, or a *log* file), from `lsof`.
    static func parse(lsof text: String) -> [Int32: [String]] {
        var result: [Int32: [String]] = [:]
        var pid: Int32?
        var record: [Character: String] = [:]
        func flush() {
            guard let pid, record["t"] == "REG", let access = record["a"], access == "w" || access == "u",
                  let name = record["n"], !name.hasPrefix("/dev/") else { return }
            let file = (name as NSString).lastPathComponent.lowercased()
            if record["f"] == "1" || record["f"] == "2" || file.contains("log") || file.hasSuffix(".out") {
                result[pid, default: []].append(name)
            }
        }
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value); record = [:]
            case "f": flush(); record = ["f": value]
            case "t", "a", "n": record[tag] = value
            default: break
            }
        }
        flush()
        return result
    }

    // MARK: Environment

    /// One variable from a process's environment (same user only); nil when it's unset or unreadable.
    static func environmentValue(_ name: String, pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return environmentValue(name, procargs: Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` layout: argc, the executable path, padding, argc arguments, then the environment.
    static func environmentValue(_ name: String, procargs bytes: [UInt8]) -> String? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        func skipString() { while index < bytes.count && bytes[index] != 0 { index += 1 } }
        skipString()
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        for _ in 0..<argc {
            skipString()
            index += 1
        }
        let prefix = Array("\(name)=".utf8)
        while index < bytes.count {
            let start = index
            skipString()
            if index == start { break }
            let entry = bytes[start..<index]
            if entry.starts(with: prefix) { return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self) }
            index += 1
        }
        return nil
    }

    // MARK: Finding jobs

    /// Remembers groups between looks (once a job, always a job until it exits) and which run hot.
    final class Scanner {
        typealias ProcessList = () -> String?
        typealias LogFinder = ([Int32]) -> [Int32: [String]]
        typealias Environment = (Int32) -> String?

        private let uid: UInt32
        private let ownGroup: Int32
        private let cores: Double
        private let listProcesses: ProcessList
        private let findLogs: LogFinder
        private let tabID: Environment
        private var hot: [Int32: Int] = [:]
        /// Groups listed before, with the start first seen (ps elapsed times wobble by a second).
        private var known: [Int32: Double] = [:]
        private var logs: [String: (file: String, line: String?, updated: Double)] = [:]
        private var logsTried: Set<String> = []
        private var logsAt: Double = 0

        init(uid: UInt32 = getuid(), ownGroup: Int32 = getpgrp(), cores: Int = Foundation.ProcessInfo.processInfo.activeProcessorCount,
             listProcesses: @escaping ProcessList, findLogs: @escaping LogFinder, tabID: @escaping Environment) {
            self.uid = uid
            self.ownGroup = ownGroup
            self.cores = Double(max(cores, 1))
            self.listProcesses = listProcesses
            self.findLogs = findLogs
            self.tabID = tabID
        }

        /// Jobs now. `queued` are build-queue processes (holding or waiting for a slot): their groups
        /// are always listed so the queue's entries can borrow the details.
        func scan(queued: Set<Int32> = [], now: Double = Date().timeIntervalSince1970) -> [Job] {
            guard let text = listProcesses() else { return [] }
            let processes = MachineJobs.parse(ps: text)
            var groups: [Int32: [ProcessRow]] = [:]
            for process in processes.values where process.uid == uid { groups[process.group, default: []].append(process) }
            var jobs: [Job] = []
            var seen: [Int32: Double] = [:]
            for (group, members) in groups {
                guard group != ownGroup, let leader = processes[group] ?? members.max(by: { $0.age < $1.age }),
                      !MachineJobs.isAgentOrSystem(leader) else { continue }
                let launchdChild = leader.ppid == 1
                if launchdChild && (leader.arguments.split(separator: " ").first ?? "").contains(".app/Contents/MacOS/") { continue }
                let measured = now - leader.age
                let listed = known[group].map { abs($0 - measured) <= 5 } ?? false
                let start = listed ? known[group]! : measured
                let key = "\(group)-\(Int(start))"
                let cpu = members.reduce(0) { $0 + $1.cpu }
                hot[group] = cpu >= 90 ? (hot[group] ?? 0) + 1 : 0
                let names = Set(members.map(\.name))
                let caffeinated = names.contains("caffeinate") || leader.arguments.range(of: #"(^|[\s/;&|(])caffeinate\s"#,
                                                                                         options: .regularExpression) != nil
                let tooling = !names.isDisjoint(with: MachineJobs.drivers.union(MachineJobs.compilers))
                let qualifies = members.contains { queued.contains($0.pid) }
                    || (caffeinated && leader.age >= 30)
                    || (tooling && leader.age >= 15)
                    || (!launchdChild && (hot[group] ?? 0) >= 2)
                guard qualifies || listed else { continue }
                seen[group] = start
                jobs.append(job(key: key, group: group, leader: leader, members: members, start: start, cpu: cpu))
            }
            known = seen
            hot = hot.filter { groups[$0.key] != nil }
            if now - logsAt >= 30 || jobs.contains(where: { !logsTried.contains($0.key) }) { refreshLogs(jobs, now: now) }
            return jobs.map { job in
                var job = job
                if let log = logs[job.key] {
                    job.logFile = (log.file as NSString).lastPathComponent
                    job.logLine = log.line
                    job.logUpdatedAt = log.updated
                }
                return job
            }.sorted { $0.since < $1.since }
        }

        private func job(key: String, group: Int32, leader: ProcessRow, members: [ProcessRow], start: Double, cpu: Double) -> Job {
            let ordered = members.sorted { $0.pid < $1.pid }
            let busiest = members.max { ($0.cpu, $0.pid) < ($1.cpu, $1.pid) } ?? leader
            let current = busiest.cpu < 1 ? (ordered.last ?? leader) : busiest
            let stopped = members.contains { $0.state.hasPrefix("T") && $0.name != "caffeinate" }
            let onDisk = members.contains { $0.state.hasPrefix("U") || $0.state.hasPrefix("D") }
            let state: State = stopped && cpu < 1 ? .paused : onDisk && cpu < 20 ? .waitingOnDisk : cpu < 2 ? .idle : .running
            let tool = ordered.first { MachineJobs.drivers.contains($0.name) }
            var title = MachineJobs.summary((tool ?? leader).arguments)
            if title == leader.name, ordered.count > 1 { title = MachineJobs.summary(current.arguments) }
            let step = MachineJobs.summary(current.arguments)
            let tab = tabID(leader.pid) ?? ordered.prefix(3).lazy.compactMap { self.tabID($0.pid) }.first
            return Job(key: key, group: group, processIDs: ordered.map(\.pid), title: title,
                       project: MachineJobs.project(in: [leader.arguments] + ordered.map(\.arguments)),
                       step: step == title ? nil : step, state: state, since: start,
                       cpu: (cpu / cores * 10).rounded() / 10, memory: members.reduce(0) { $0 + $1.memory },
                       processes: members.count, tabID: tab.flatMap { UUID(uuidString: $0)?.uuidString })
        }

        private func refreshLogs(_ jobs: [Job], now: Double) {
            logsAt = now
            logsTried = Set(jobs.map(\.key))
            let found = findLogs(Array(jobs.flatMap(\.processIDs).prefix(200)))
            var fresh: [String: (file: String, line: String?, updated: Double)] = [:]
            for job in jobs {
                var best: (file: String, updated: Double)?
                for file in Set(job.processIDs.flatMap { found[$0] ?? [] }) {
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                          let modified = attributes[.modificationDate] as? Date else { continue }
                    if best == nil || modified.timeIntervalSince1970 > best!.updated { best = (file, modified.timeIntervalSince1970) }
                }
                if let best { fresh[job.key] = (best.file, MachineJobs.tail(of: best.file), best.updated) }
            }
            logs = fresh
        }
    }

    static func isAgentOrSystem(_ leader: ProcessRow) -> Bool {
        let text = leader.arguments
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains(where: text.hasPrefix) { return true }
        let agent = #"@github/copilot|/copilot(\s|$)|/claude(\s|$)|claude-code|/codex(\s|$)|codex app-server|/agy(\s|$)|/gemini(\s|$)|/Cantrip\.app/Contents/MacOS/Cantrip\s*$|mcp-on-demand"#
        return text.range(of: agent, options: .regularExpression) != nil
    }

    /// The last line of a log file, reading at most its last 4 KB.
    static func tail(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastLine(of: data)
    }

    // MARK: The live scanner

    /// A scanner that reads this Mac (`ps`, `lsof`, the tab variable).
    static func makeScanner() -> Scanner {
        Scanner(
            listProcesses: { try? ProcessRunner.run("/bin/ps", MachineJobs.psArguments, errorOutput: .discard, timeout: 8).text },
            findLogs: { pids in
                guard !pids.isEmpty, let result = try? ProcessRunner.run(
                    "/usr/sbin/lsof", ["-n", "-P", "-w", "-b", "-p", pids.map(String.init).joined(separator: ","), "-Ftfan"],
                    errorOutput: .discard, timeout: 8) else { return [:] }
                return MachineJobs.parse(lsof: result.text)
            },
            tabID: { MachineJobs.environmentValue(MachineJobs.tabIDVariable, pid: $0) })
    }

    /// Looks at most every few seconds, off the main thread; callers get the latest result at once.
    final class Live: @unchecked Sendable {
        static let shared = Live()
        private let queue = DispatchQueue(label: "cantrip.machine-jobs", qos: .utility)
        private let lock = NSLock()
        private var latest: [Job] = []
        private var lookedAt: Double = 0
        private var looking = false
        private lazy var scanner = MachineJobs.makeScanner()

        /// The jobs from the latest look; starts another look when that one is older than `maxAge`.
        func current(queued: Set<Int32> = [], maxAge: TimeInterval = 8) -> [Job] {
            lock.lock()
            let jobs = latest
            let stale = Date().timeIntervalSince1970 - lookedAt >= maxAge && !looking
            if stale { looking = true }
            lock.unlock()
            if stale {
                queue.async { [self] in
                    let fresh = scanner.scan(queued: queued)
                    lock.lock()
                    latest = fresh
                    lookedAt = Date().timeIntervalSince1970
                    looking = false
                    lock.unlock()
                }
            }
            return jobs
        }
    }
}
