import Foundation

extension SessionTabTests {
    /// `--build-queue-run DIR SLOTS PRIORITY -- EXECUTABLE ARGS…`: this binary as the queue's
    /// wrapper, so tests run real processes against one queue folder.
    static func runBuildQueueHelper(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 7, let separator = arguments.firstIndex(of: "--"), separator == 5,
              let slots = Int(arguments[3]), let rank = Int(arguments[4]),
              let priority = BuildQueue.Priority(rawValue: rank) else { return 64 }
        return BuildQueue.run(executable: arguments[6], arguments: Array(arguments[7...]), tool: "fake",
                              policy: .init(slots: slots), store: .init(directory: URL(fileURLWithPath: arguments[2])),
                              priority: priority, resources: { .init(load: 0, cores: 10, memoryPressure: 1) },
                              poll: 0.1, reprint: 30)
    }

    /// Heavy builds take turns: the policy, who goes first, which commands the shims send to the
    /// queue, real processes waiting for each other in priority order, and the waiting build card.
    static func testBuildQueue() throws {
        // Policy: the setting's slots, one while the Mac is busy or short of memory.
        let calm = BuildQueue.Resources(load: 8, cores: 10, memoryPressure: 1)
        precondition(BuildQueue.Policy(slots: 2).limit(calm) == 2 && BuildQueue.Policy(slots: 9).slots == 4
                     && BuildQueue.Policy(slots: 0).slots == 1)
        precondition(BuildQueue.Policy(slots: 3).limit(.init(load: 16, cores: 10, memoryPressure: 1)) == 1, "busy")
        precondition(BuildQueue.Policy(slots: 3).limit(.init(load: 1, cores: 10, memoryPressure: 2)) == 1, "memory pressure")
        precondition(BuildQueue.Resources(load: 1, cores: 10, memoryPressure: 4).reason == "macOS reports memory pressure")

        // Priority: CI from GitHub Actions, a working child tab, a Home run with a live journal, else a tab.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("build-queue-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs")
        try fm.createDirectory(at: runs, withIntermediateDirectories: true)
        let (child, settled, homeRun, tab) = (UUID(), UUID(), UUID(), UUID())
        var working = ChildTab(id: child, parentID: UUID(), queueItemID: UUID(), title: "Child", prompt: "Build it",
                               parentTitle: "Parent", createdAt: Date(), updatedAt: Date())
        working.state = .working
        var merged = ChildTab(id: settled, parentID: UUID(), queueItemID: UUID(), title: "Merged", prompt: "Build it",
                              parentTitle: "Parent", createdAt: Date(), updatedAt: Date())
        merged.state = .merged
        let childTabs = root.appendingPathComponent("child-tabs.json")
        try JSONEncoder().encode([working, merged]).write(to: childTabs)
        try Data().write(to: runs.appendingPathComponent("\(homeRun.uuidString).jsonl"))
        func priority(_ environment: [String: String]) -> BuildQueue.Priority {
            BuildQueue.priority(environment: environment, childTabs: childTabs, homeRuns: runs)
        }
        precondition(priority(["GITHUB_ACTIONS": "true"]) == .ci)
        precondition(priority([TabInsight.tabIDVariable: child.uuidString]) == .child)
        precondition(priority([TabInsight.tabIDVariable: settled.uuidString]) == .tab, "a merged child is an ordinary tab")
        precondition(priority([TabInsight.tabIDVariable: homeRun.uuidString]) == .background)
        precondition(priority([TabInsight.tabIDVariable: tab.uuidString]) == .tab && priority([:]) == .tab)

        // Turn order: priority rank (child tabs and CI share one), then who asked first.
        func ticket(_ pid: Int32, _ priority: BuildQueue.Priority, _ at: Double) -> BuildQueue.Ticket {
            .init(pid: pid, priority: priority, enqueuedAt: at, title: "t\(pid)")
        }
        let early = ticket(1, .background, 1), ci = ticket(2, .ci, 3), childTicket = ticket(3, .child, 2), late = ticket(4, .tab, 9)
        let line = [early, ci, childTicket, late]
        precondition(BuildQueue.admits(late, waiting: line, running: 0, limit: 1), "your tab goes first")
        precondition(!BuildQueue.admits(late, waiting: line, running: 1, limit: 1), "but not past the limit")
        precondition(!BuildQueue.admits(ci, waiting: line, running: 0, limit: 2) && BuildQueue.admits(childTicket, waiting: [early, ci, childTicket], running: 0, limit: 2),
                     "child tabs and CI jobs go in the order they asked")
        precondition(!BuildQueue.admits(early, waiting: [early, ci], running: 0, limit: 4), "background runs go last")

        // Waiting lines, and what a card reads from them.
        let holders = [BuildQueue.Holder(pid: 9, priority: .tab, since: 0, title: "xcodebuild archive · Mems")]
        let waitLine = BuildQueue.waitingLine(running: holders, ahead: 1, limit: 1, reason: "macOS reports memory pressure")
        precondition(waitLine == "cantrip build queue: waiting for a build slot · 1 running: xcodebuild archive · Mems · 1 ahead · 1 at a time while macOS reports memory pressure",
                     waitLine)
        precondition(BuildQueueState.latest(in: "x\n" + waitLine + "\n") == .waiting("1 running: xcodebuild archive · Mems · 1 ahead · 1 at a time while macOS reports memory pressure"))
        precondition(BuildQueueState.latest(in: waitLine + "\ncantrip build queue: started swift build · Cantrip\n[3/40] Compiling") == .started)
        precondition(BuildQueueState.latest(in: "[3/40] Compiling") == nil)
        precondition(BuildQueue.title(tool: "xcodebuild", arguments: ["-scheme", "App", "archive"], directory: "/w/Mems") == "xcodebuild archive · Mems"
                     && BuildQueue.title(tool: "swift", arguments: ["build", "-c", "release"], directory: "/w/Cantrip") == "swift build · Cantrip")

        // The shims: heavy invocations go to `cantrip build-queue run`, the rest to the real tool.
        let shims = root.appendingPathComponent("bin"), real = root.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let cantrip = root.appendingPathComponent("fake cantrip")
        func script(_ url: URL, _ body: String) throws {
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script(cantrip, #"echo "QUEUED $*""#)
        for tool in BuildQueue.tools { try script(real.appendingPathComponent(tool), "echo \"REAL \(tool) $*\"") }
        BuildQueue.apply(enabled: true, executable: cantrip.path, folder: shims)
        defer { ToolPath.leadingFolders = [] }
        precondition(ToolPath.leadingFolders == [shims.path]
                     && ToolPath.value(inherited: "/usr/bin:/bin", home: "/h").hasPrefix(shims.path + ":"), "the shims go first")
        precondition(ToolPath.value(inherited: "\(shims.path):/usr/bin", home: "/h").components(separatedBy: shims.path).count == 2,
                     "never twice")
        var profile = ResolvedEnvironment(profile: EnvironmentProfile(name: "Queue order"))
        profile.pathPrefix = ["/opt/xcode/usr/bin"]
        var profiled = ["PATH": "/usr/bin:/bin"]
        EnvironmentProfiles.apply(profile, to: &profiled)
        precondition(profiled["PATH"] == "\(shims.path):/opt/xcode/usr/bin:/usr/bin:/bin", "a profile's folders go after the shims: \(profiled["PATH"] ?? "")")
        let sourced = Process()
        sourced.executableURL = URL(fileURLWithPath: "/bin/bash")
        sourced.arguments = ["-c", "PATH=/opt/xcode/usr/bin:/usr/bin:/bin; source \"$1\"; printf %s \"$PATH\"", "bash", try EnvironmentProfiles.writeScript(profile).path]
        let sourcedOut = Pipe()
        sourced.standardOutput = sourcedOut
        try sourced.run()
        sourced.waitUntilExit()
        let sourcedPath = String(decoding: sourcedOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(sourcedPath == "\(shims.path):/opt/xcode/usr/bin:/usr/bin:/bin", "a shell's profile script puts the shims first again: \(sourcedPath)")
        func shell(_ command: String, slot: String? = nil, path: String? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var environment = ["PATH": path ?? "\(shims.path):\(real.path):/usr/bin:/bin", "HOME": root.path]
            if let slot { environment[BuildQueue.slotVariable] = slot }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let queued = "QUEUED build-queue run --tool"
        for (command, expected) in [
            ("xcodebuild -scheme App -destination generic/platform=iOS archive", "\(queued) xcodebuild -- \(real.path)/xcodebuild -scheme App -destination generic/platform=iOS archive"),
            ("xcodebuild -project A.xcodeproj", "\(queued) xcodebuild -- \(real.path)/xcodebuild -project A.xcodeproj"),
            ("xcodebuild -version", "REAL xcodebuild -version"),
            ("xcodebuild -list -project A.xcodeproj", "REAL xcodebuild -list -project A.xcodeproj"),
            ("xcodebuild -showBuildSettings -scheme App", "REAL xcodebuild -showBuildSettings -scheme App"),
            ("swift build -c release", "\(queued) swift -- \(real.path)/swift build -c release"),
            ("swift test --filter X", "\(queued) swift -- \(real.path)/swift test --filter X"),
            ("swift --version", "REAL swift --version"),
            ("swift package resolve", "REAL swift package resolve"),
            ("swiftc -parse-as-library a.swift -o a", "\(queued) swiftc -- \(real.path)/swiftc -parse-as-library a.swift -o a"),
            ("swiftc --version", "REAL swiftc --version"),
        ] {
            let output = try shell(command)
            precondition(output == expected, "\(command): \(output)")
        }
        let nested = try shell("swift build", slot: "0")
        precondition(nested == "REAL swift build", "inside a build's slot, tools run at once")
        let missing = try shell("swiftc a.swift; echo $?", path: shims.path)
        precondition(missing.hasSuffix("127"), "a missing tool fails like one: \(missing)")
        BuildQueue.apply(enabled: false, executable: cantrip.path, folder: shims)
        precondition(ToolPath.leadingFolders.isEmpty && !fm.fileExists(atPath: shims.appendingPathComponent("xcodebuild").path),
                     "turning it off removes the shims")

        // Real processes against one queue: with one slot they run one after another, and a
        // waiting tab goes before a background run that asked earlier.
        let queue = root.appendingPathComponent("queue")
        let log = root.appendingPathComponent("log.txt")
        func helper(_ name: String, priority: BuildQueue.Priority, seconds: Double) throws -> (Process, Pipe) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--build-queue-run", queue.path, "1", String(priority.rawValue), "--", "/bin/sh", "-c",
                                 "echo \"start \(name) $\(BuildQueue.slotVariable)\" >> '\(log.path)'; sleep \(seconds); echo \"end \(name)\" >> '\(log.path)'"]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            return (process, errors)
        }
        let store = BuildQueue.Store(directory: queue)
        try store.prepare()
        let first = try helper("first", priority: .tab, seconds: 1.0)
        while !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("start first") { Thread.sleep(forTimeInterval: 0.05) }
        precondition(store.holders().count == 1 && store.holders().first?.priority == .tab)
        let background = try helper("background", priority: .background, seconds: 0.2)
        Thread.sleep(forTimeInterval: 0.4)
        let mine = try helper("mine", priority: .tab, seconds: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        let status = BuildQueue.statusText(store: store, policy: .init(slots: 1), enabled: true, resources: calm)
        precondition(status.contains("Running:\n  fake") && status.contains("1. fake") && status.contains("a tab")
                     && status.contains("2. fake") && status.contains("a Home background run"), status)
        for (process, _) in [first, background, mine] { process.waitUntilExit() }
        let order = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map {
            $0.split(separator: " ").prefix(2).joined(separator: " ")
        }
        precondition(order == ["start first", "end first", "start mine", "end mine", "start background", "end background"],
                     "one at a time, your tab first: \(order)")
        precondition(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("start first 0"), "the build knows its slot")
        let backgroundErrors = String(decoding: background.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(backgroundErrors.contains("cantrip build queue: waiting for a build slot · 1 running: fake")
                     && backgroundErrors.contains("cantrip build queue: started fake"), backgroundErrors)
        precondition(first.0.terminationStatus == 0 && store.holders().isEmpty && store.tickets().isEmpty, "slots and tickets are freed")
        let failing = Process()
        failing.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        failing.arguments = ["--build-queue-run", queue.path, "1", "0", "--", "/bin/sh", "-c", "exit 7"]
        try failing.run()
        failing.waitUntilExit()
        precondition(failing.terminationStatus == 7, "the build's exit status comes back")

        // What clients list: each build's tab or CI job, in turn order, and counts for tab lists.
        let tabID = UUID()
        precondition(BuildQueue.Origin.current(environment: ["CANTRIP_TAB_ID": tabID.uuidString]) == .init(tab: tabID.uuidString, job: nil))
        precondition(BuildQueue.Origin.current(environment: ["CANTRIP_TAB_ID": "not-a-tab"]) == .init(tab: nil, job: nil))
        precondition(BuildQueue.Origin.current(environment: ["GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "owner/app",
                                                             "GITHUB_WORKFLOW": "TestFlight", "CANTRIP_TAB_ID": tabID.uuidString])
                     == .init(tab: nil, job: "app · TestFlight"), "a CI job names its repo and workflow")
        let listed = BuildQueue.Store(directory: root.appendingPathComponent("listed"))
        try listed.prepare()
        precondition(BuildQueue.snapshot(store: listed, policy: .init(slots: 2), enabled: false, resources: calm) == nil
                     && BuildQueue.counts(store: listed, enabled: false) == nil, "off and empty: nothing to list")
        let held = try requireHome(listed.take(as: .init(pid: getpid(), priority: .tab, since: 900, title: "xcodebuild archive · App",
                                                         tab: tabID.uuidString), limit: 2))
        defer { close(held.descriptor) }
        try listed.write(.init(pid: getpid(), priority: .ci, enqueuedAt: 950, title: "swift build · App", job: "app · CI"))
        let busy = BuildQueue.Resources(load: 30, cores: 10, memoryPressure: 1)
        let snapshot = try requireHome(BuildQueue.snapshot(store: listed, policy: .init(slots: 2), enabled: false, resources: busy) {
            $0 == tabID.uuidString ? "Docs site" : nil
        })
        precondition(snapshot.running == [.init(pid: getpid(), title: "xcodebuild archive · App", source: "tab", since: 900,
                                                tabID: tabID.uuidString, tabTitle: "Docs site")]
                     && snapshot.waiting == [.init(pid: getpid(), title: "swift build · App", source: "ci", since: 950, job: "app · CI")]
                     && snapshot.limit == 1 && snapshot.slots == 2 && snapshot.reason?.hasPrefix("the Mac is busy") == true
                     && !snapshot.enabled, "a queue turned off still lists what it holds: \(snapshot)")
        let counted = try requireHome(BuildQueue.counts(store: listed, enabled: true))
        precondition(counted.running == 1 && counted.waiting == 1)
        let json = try requireHome(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let firstRunning = try requireHome((json["running"] as? [[String: Any]])?.first)
        precondition(firstRunning["tabTitle"] as? String == "Docs site" && firstRunning["source"] as? String == "tab"
                     && firstRunning["job"] == nil && json["limit"] as? Int == 1, "\(json)")

        // Other long work on the Mac (MachineJobs): a build borrows its own group's details, other
        // jobs follow the builds (paused ones with the waiting), and counts and status include them.
        func job(_ group: Int32, _ pids: [Int32], _ title: String, _ state: MachineJobs.State, tab: String? = nil) -> MachineJobs.Job {
            .init(key: "\(group)-1", group: group, processIDs: pids, title: title, project: "atlas", step: "compile_shaders.py",
                  state: state, since: 100, cpu: 1.5, memory: 4096, processes: pids.count, tabID: tab,
                  logFile: "b.log", logLine: "[5/6] 99%", logUpdatedAt: 120)
        }
        let jobs = [job(70, [70, getpid()], "make app", .running),
                    job(80, [80, 81], "build-atlas.py", .waitingOnDisk, tab: tabID.uuidString),
                    job(90, [90], "export.py", .paused)]
        let withJobs = try requireHome(BuildQueue.snapshot(store: listed, policy: .init(slots: 2), enabled: true, resources: calm,
                                                           jobs: jobs) { $0 == tabID.uuidString ? "Docs site" : nil })
        precondition(withJobs.running.map(\.title) == ["xcodebuild archive · App", "build-atlas.py"]
                     && withJobs.waiting.map(\.title) == ["swift build · App", "export.py"], "\(withJobs)")
        let borrowed = withJobs.running[0], atlas = withJobs.running[1], paused = withJobs.waiting[1]
        precondition(borrowed.kind == nil && borrowed.state == "running" && borrowed.project == "atlas" && borrowed.logLine == "[5/6] 99%",
                     "the build carries its group's details: \(borrowed)")
        precondition(withJobs.waiting[0].state == nil && withJobs.waiting[0].step == "compile_shaders.py", "a queued build keeps its own state")
        precondition(atlas.kind == "job" && atlas.source == "tab" && atlas.tabTitle == "Docs site" && atlas.pid == 80
                     && atlas.state == "waitingOnDisk" && atlas.cpu == 1.5 && atlas.memory == 4096, "\(atlas)")
        precondition(paused.kind == "job" && paused.source == "other" && paused.state == "paused", "\(paused)")
        let jobCounts = try requireHome(BuildQueue.counts(store: listed, enabled: false, jobs: jobs))
        precondition(jobCounts.running == 2 && jobCounts.waiting == 2, "the build's own group isn't counted twice: \(jobCounts)")
        precondition(BuildQueue.counts(store: BuildQueue.Store(directory: root.appendingPathComponent("none")), enabled: false,
                                       jobs: [jobs[1]])?.running == 1, "a job alone shows even with the queue off")
        let jobStatus = BuildQueue.statusText(store: listed, policy: .init(slots: 2), enabled: true, resources: calm, jobs: jobs)
        precondition(jobStatus.contains("Other long jobs:\n  build-atlas.py · atlas (waiting on disk)")
                     && jobStatus.contains("    b.log: [5/6] 99%") && !jobStatus.contains("make app"), jobStatus)
        let jobJSON = try requireHome(JSONSerialization.jsonObject(with: JSONEncoder().encode(atlas)) as? [String: Any])
        precondition(jobJSON["kind"] as? String == "job" && jobJSON["logFile"] as? String == "b.log" && jobJSON["job"] == nil, "\(jobJSON)")
        precondition(MachineJobs.tabIDVariable == TabInsight.tabIDVariable)
        listed.removeTicket(pid: getpid())

        // The card while it waits, and its time from when it got a slot.
        let started = Date(timeIntervalSince1970: 1_000)
        let command = try requireHome(BuildDetector.detect("xcodebuild -scheme App archive", workdir: "/w/Mems"))
        var run = BuildRun(id: "call-1", command: command, startedAt: started, estimate: .init(seconds: 120, runs: 3))
        precondition(run.advance(step: nil, transfer: nil, queue: .waiting("1 running: swift build · Cantrip"), at: started.addingTimeInterval(1)))
        precondition(run.isWaiting && run.label == "Waiting" && run.detail == "Waiting for a build slot · 1 running: swift build · Cantrip"
                     && run.startedAt == started, run.detail)
        let waitingCard = run.document
        let bar = try requireHome(waitingCard.blocks.first { $0.type == "progress" })
        precondition(bar.expectedSeconds == nil && bar.fraction == nil && waitingCard.blocks.first?.symbol == "hourglass",
                     "no estimate while it waits")
        precondition(!run.advance(step: nil, transfer: nil, queue: .waiting("1 running: swift build · Cantrip"), at: started.addingTimeInterval(5)))
        precondition(run.advance(step: nil, transfer: nil, queue: .started, at: started.addingTimeInterval(90)))
        precondition(!run.isWaiting && run.label == command.verb && run.startedAt == started.addingTimeInterval(90)
                     && run.document.blocks.first { $0.type == "progress" }?.expectedSeconds == 120,
                     "its time and estimate start with the slot")
        print("Build queue: policy, priority, turn order, shims, real waiting in priority order, client lists and waiting cards passed")
    }
}
