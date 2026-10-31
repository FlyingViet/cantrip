import Foundation

private final class AutoForkFixtureBackend: Backend {
    var prompts: [String] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}

    func finish(_ text: String) {
        sink?(.textDelta(text))
        sink?(.done)
    }
}

/// What the coordinator reads as the Mac's load, disk and Simulator leases.
private final class ResourceFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ChildTabCapacity.Resources.idle
    var value: ChildTabCapacity.Resources {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

extension SessionTabTests {
    /// Auto-fork (Phase 3): the rule, then in a real git repository: an Auto-delivered message rated
    /// independent starts in a child tab on its own; one that touches the parent's uncommitted file,
    /// one sent with an explicit Queue, and any message with auto-fork off stay queued; and Run in
    /// This Tab Instead puts a child's request back at the front of the parent's queue.
    @MainActor
    static func testChildTabAutoFork() async throws {
        testChildTabAutoForkRule()
        testChildTabCapacity()

        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork,
                     settings.childTabsPerParentLimit, settings.childTabsOverallLimit)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.childTabsAutoFork = true
        settings.childTabsPerParentLimit = 3
        settings.childTabsOverallLimit = 4
        let retry = ChildTabCoordinator.capacityRetryInterval
        ChildTabCoordinator.capacityRetryInterval = 100_000_000
        defer {
            (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork,
             settings.childTabsPerParentLimit, settings.childTabsOverallLimit) = saved
            ChildTabCoordinator.capacityRetryInterval = retry
        }
        let files = FileManager.default
        let repoURL = files.homeDirectoryForCurrentUser.appendingPathComponent("Coding/child-auto-demo", isDirectory: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-child-auto-\(UUID().uuidString)", isDirectory: true)
        try? files.removeItem(at: repoURL)
        try files.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? files.removeItem(at: repoURL)
            try? files.removeItem(at: scratch)
            ChildTabRepositories.invalidate()
        }
        let repo = repoURL.path
        @discardableResult
        func git(_ arguments: String...) -> String {
            let result = ChildTabGit.run(repo, arguments, timeout: 30)
            precondition(result?.succeeded == true, "git \(arguments.joined(separator: " ")): \(result?.error ?? "timed out")")
            return result?.output ?? ""
        }
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Auto Fork Test")
        git("config", "user.email", "auto-fork@example.com")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "docs\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Start")

        let store = ChildTabStore.shared
        let manager = SessionManager()
        let coordinator: ChildTabCoordinator = manager.childTabs
        var backends: [UUID: AutoForkFixtureBackend] = [:]
        coordinator.makeSession = { id in
            let backend = AutoForkFixtureBackend()
            backends[id] = backend
            return ChatSession(id: id, copilotBackend: backend)
        }
        coordinator.worktreesRoot = scratch.appendingPathComponent("worktrees", isDirectory: true)
        let resources = ResourceFixture()
        coordinator.sampleResources = { _ in resources.value }
        let parentBackend = AutoForkFixtureBackend()
        let parent = ChatSession(copilotBackend: parentBackend)
        parent.workdir = repo
        try parent.updateTab(name: "Auto parent")
        manager.sessions.append(parent)
        manager.select(parent.id)
        defer { for session in manager.sessions { session.cancel() } }

        parent.submitRemote("Refactor the parser", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 1 }
        precondition(parent.isStreaming)
        // The parent has uncommitted work in a.txt (and an untracked notes file).
        try "one\nparent edit\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "notes\n".write(toFile: repo + "/notes.txt", atomically: true, encoding: .utf8)
        precondition(ChildTabGit.changedFiles(repo) == ["a.txt", "notes.txt"], "\(ChildTabGit.changedFiles(repo))")

        func queue(_ text: String, auto: Bool, touches: [String]) throws -> QueuedPrompt {
            parent.submitRemote(text, mode: .queue)
            let item = try requireAutoFork(parent.queued.last)
            precondition(item.text == text)
            parent.applyQueuePlans([item.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab",
                                                       title: String(text.prefix(20)), repo: nil, touches: touches)])
            if auto { parent.noteAutoDelivered(item.id) }
            return item
        }
        func child(for text: String) -> ChildTab? {
            store.children(of: parent.id).first { $0.prompt == text }
        }

        precondition(coordinator.forkUnavailableReason(parent) == nil,
                     "\(coordinator.forkUnavailableReason(parent) ?? "") running: \(store.running.map(\.title))")
        // 1. Explicit Queue on the Mac: "after this", even when the plan says independent; its row says so.
        let explicit = try queue("Write the changelog", auto: false, touches: ["CHANGELOG.md"])
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(child(for: explicit.text) == nil && parent.queued.contains(explicit), "an explicit Queue isn't auto-forked")
        precondition(parent.queuePlans[explicit.id]?.reason == ChildTabCoordinator.manualReason
                     && parent.queuePlans[explicit.id]?.kind == .fork, parent.queuePlans[explicit.id]?.reason ?? "")

        // 2. Auto delivery, independent, files don't overlap: it starts in a child tab on its own.
        let docs = try queue("Add a docs page", auto: true, touches: ["docs/page.md"])
        try await waitForJournalTest { child(for: docs.text) != nil }
        var record = try requireAutoFork(child(for: docs.text))
        precondition(record.autoStarted == true && record.state == .working && record.branch != nil, "\(record)")
        precondition(!parent.queued.contains(where: { $0.id == docs.id }), "it left the parent's queue")
        precondition(record.displaySummary == ChildTab.autoStartedNote && record.actions.contains("requeue"))
        let card = try requireAutoFork(parent.messages.first { $0.childResult?.id == record.id }?.childResult)
        precondition(card.snapshot["summary"] as? String == ChildTab.autoStartedNote && card.snapshot["autoStarted"] as? Bool == true)
        precondition(parent.queued.contains(explicit), "the explicit one still waits")

        // 3. Same file as the parent's uncommitted work: it stays queued and says why.
        let overlap = try queue("Tidy a.txt", auto: true, touches: ["a.txt"])
        try await waitForJournalTest { parent.queuePlans[overlap.id]?.kind == .queue }
        precondition(parent.queuePlans[overlap.id]?.reason == "Runs after the current task: it also changes a.txt",
                     parent.queuePlans[overlap.id]?.reason ?? "")
        precondition(child(for: overlap.text) == nil)

        // 4. Auto-fork off in Settings: independent messages wait for Run in Child Tab.
        settings.childTabsAutoFork = false
        let off = try queue("Update the README", auto: true, touches: ["README.md"])
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(child(for: off.text) == nil && parent.queuePlans[off.id]?.kind == .fork)
        settings.childTabsAutoFork = true

        // 5. Run in This Tab Instead: the child stops, its branch goes, and the request is next here.
        let docsChild = try requireAutoFork(manager.sessions.first { $0.id == record.id })
        try await waitForJournalTest { backends[docsChild.id]?.prompts.count == 1 }
        let branch = try requireAutoFork(record.branch)
        try coordinator.perform("requeue", childID: record.id)
        record = try requireAutoFork(store.record(record.id))
        precondition(record.state == .requeued && record.contextDelivered, "\(record.state)")
        precondition(record.statusLine == "Moved back to Auto parent's queue", record.statusLine)
        precondition(!manager.sessions.contains { $0.id == docsChild.id }, "the child closed")
        precondition(parent.queued.first?.text == docs.text, "the request is first in the parent's queue")
        precondition(!parent.autoDeliveredItemIDs.contains(parent.queued[0].id), "it isn't auto-forked again")
        try await waitForJournalTest { !ChildTabGit.branchExists(repo, branch) }
        precondition(parent.messages.first { $0.childResult?.id == record.id }?.childResult?.state == .requeued)
        // The freed slot is checked again: the message that waited while auto-fork was off starts now.
        try await waitForJournalTest { child(for: off.text) != nil }
        precondition(child(for: off.text)?.autoStarted == true && child(for: overlap.text) == nil)
        do {
            try coordinator.perform("requeue", childID: record.id)
            preconditionFailure("requeue applies only while the child runs")
        } catch {}

        // 6. A paired client's queue, several at once: an independent message, a read-only audit
        // with no known files, and one that depends on the first (it follows it into its child).
        // With "off" running that's 3 of 3 for this tab; the next one waits and says why.
        let offRecord = try requireAutoFork(child(for: off.text))
        func remote(_ text: String) throws -> QueuedPrompt {
            parent.submitRemote(text, mode: .queue, autoForkEligible: true)
            let item = try requireAutoFork(parent.queued.last)
            precondition(item.text == text && parent.isAutoForkCandidate(item))
            return item
        }
        let endpoint = try remote("Add the model endpoint")
        let chain = try remote("Add the per-model backup chain")
        let audit = try remote("Audit the settings screens (read-only)")
        let extra = try remote("Write the onboarding guide")
        parent.applyQueuePlans([
            endpoint.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab",
                                   title: "Model endpoint", repo: nil, touches: ["Sources/Limits.swift"]),
            chain.id: QueuePlan(kind: .batch, reason: "Batched with #1: same fallback code", title: "Backup chain",
                                repo: nil, touches: ["Sources/Limits.swift"], after: endpoint.id),
            audit.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab", title: "Settings audit",
                                repo: nil, touches: [], readOnly: true),
            extra.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab", title: "Onboarding guide",
                                repo: nil, touches: ["docs/onboarding.md"]),
        ])
        try await waitForJournalTest { child(for: endpoint.text) != nil && child(for: audit.text) != nil }
        let endpointRecord = try requireAutoFork(child(for: endpoint.text))
        precondition(endpointRecord.followUps == [chain.text] && child(for: chain.text) == nil, "\(endpointRecord)")
        let endpointChild = try requireAutoFork(manager.sessions.first { $0.id == endpointRecord.id })
        precondition(endpointChild.queued.map(\.text) == [chain.text], "the dependent request waits in the child's queue")
        precondition(!parent.queued.contains { [endpoint.id, chain.id, audit.id].contains($0.id) })
        try await waitForJournalTest { parent.queuePlans[extra.id]?.autoFork == .waiting }
        precondition(parent.queuePlans[extra.id]?.reason == "Auto-forks when a child tab finishes (3 of 3 running for this tab)"
                     && parent.queuePlans[extra.id]?.kind == .fork
                     && parent.queuePlans[extra.id]?.snapshot["autoFork"] as? String == "waiting",
                     parent.queuePlans[extra.id]?.reason ?? "")
        precondition(coordinator.forkUnavailableReason(parent) == "This tab already has 3 child tabs running. Wait for one to finish.")

        // 7. A slot frees while the Mac is busy: it waits on the load, then starts once it calms down.
        resources.value = .init(load: 40, cores: 8, freeGB: 100, simulatorLeases: 0)
        try coordinator.perform("discard", childID: offRecord.id)
        try await waitForJournalTest { parent.queuePlans[extra.id]?.reason.hasPrefix("Auto-forks when the Mac is less busy") == true }
        precondition(child(for: extra.text) == nil)
        resources.value = .idle
        try await waitForJournalTest { child(for: extra.text) != nil }
        precondition(child(for: extra.text)?.autoStarted == true)
        for record in [endpointRecord, try requireAutoFork(child(for: audit.text)), try requireAutoFork(child(for: extra.text))] {
            try coordinator.perform("discard", childID: record.id)
        }
        print("Child tab auto-fork tests passed")
    }

    static func testChildTabAutoForkRule() {
        typealias Rule = ChildTabAutoFork
        precondition(Rule.verdict(touches: ["docs/page.md"], hasRepository: true, changedFiles: ["a.txt"],
                                  activity: []) == .fork)
        precondition(Rule.verdict(touches: ["Sources/Cantrip/CantripHome.swift"], hasRepository: true,
                                  changedFiles: ["Sources/Cantrip/CantripHome.swift"], activity: []) == .stay("Runs after the current task: it also changes CantripHome.swift"))
        precondition(Rule.verdict(touches: ["windows/"], hasRepository: true, changedFiles: ["windows/src/app.ts"],
                                  activity: []) == .stay("Runs after the current task: it also changes windows"),
                     "a folder covers the files in it")
        precondition(Rule.verdict(touches: ["TabSections.swift"], hasRepository: true, changedFiles: [],
                                  activity: ["/Users/me/Coding/Cantrip/Sources/Cantrip/TabSections.swift"]) != .fork, "a file the current run edited")
        precondition(Rule.verdict(touches: ["Makefile.swift"], hasRepository: true, changedFiles: [],
                                  activity: ["swift build && sed -i '' s/a/b/ Sources/Makefile.swift"]) != .fork, "a file the current run's commands named")
        precondition(Rule.verdict(touches: ["README"], hasRepository: true, changedFiles: [],
                                  activity: ["cat README && make"]) == .fork,
                     "a bare word in a command isn't a file")
        let planner = UUID()
        precondition(Rule.verdict(touches: ["QueuePlanning.swift"], hasRepository: true, changedFiles: [], activity: [],
                                  children: [.init(id: UUID(), title: "Docs", touches: ["docs/"]),
                                             .init(id: planner, title: "Queue plans", touches: ["Sources/Cantrip/QueuePlanning.swift"])])
                     == .follow(planner, "Follows child tab “Queue plans”: it's changing QueuePlanning.swift"),
                     "work on a running child's files queues behind it, in that child")
        precondition(Rule.verdict(touches: [], hasRepository: true, changedFiles: [], activity: [])
                     == .stay(Rule.unclearFiles))
        // Read-only work (an audit, a plan that ends with a question) has nothing to overlap.
        precondition(Rule.verdict(touches: [], readOnly: true, hasRepository: true, changedFiles: [], activity: []) == .fork)
        precondition(Rule.verdict(touches: ["a.txt"], readOnly: true, hasRepository: false, changedFiles: ["a.txt"],
                                  activity: []) == .fork)
        precondition(Rule.verdict(touches: ["a.txt"], hasRepository: false, changedFiles: [], activity: [])
                     == .stay("Independent; outside a repository it waits for Run in Child Tab"))
        // Paths a request names count as its files.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("named-paths-\(UUID().uuidString)").path
        for folder in ["Sources/Cantrip", "windows/src"] {
            try? FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let named = Rule.mentionedPaths(in: """
            Touch BackendLimits.swift and Sources/Cantrip/UsageFallback.swift, update windows/PARITY.md and \
            the web client in windows/src/. See https://example.com/a/b.html, fixer.example.com, v1.2.11, \
            e.g. iPhone/Duo, \(root)/README.md, \(root)/Sources/App.swift, /etc/hosts and ~/Elsewhere/a.swift. \
            Rules: allow/ask/deny, Backend/copilot_shim.py and Sources/. Tests: rich-cards.test.ts.
            """, root: root)
        precondition(named == ["BackendLimits.swift", "Sources/Cantrip/UsageFallback.swift", "windows/src/",
                               "Sources/App.swift", "Sources/", "rich-cards.test.ts"], "\(named)")
        precondition(Rule.mentionedPaths(in: "Edit windows/src/app.ts and allow/ask/deny") == ["windows/src/app.ts"],
                     "without a root, a folder needs its trailing slash")
        precondition(Rule.mentionedPaths(in: "Audit the Mobbin settings screens and report back").isEmpty)
        precondition(Rule.isPlanOnly("Constraints:\n- Plan first. Reply with the design. Build after the user approves.")
                     && Rule.isPlanOnly("Audit only, no implementation.")
                     && !Rule.isPlanOnly("Implement the plan in docs/plan.md; the personal MCP is read-only."))
        let key = Rule.normalized
        precondition(!Rule.overlaps(key("main.swift"), key("Tests/main.swiftlint"))
                     && Rule.overlaps(key("./Docs/"), key("docs/a.md")) && !Rule.overlaps(key("docs"), key("docsite/a.md")))
    }

    /// The caps and the Mac's resources: why auto-fork waits, on the row.
    static func testChildTabCapacity() {
        typealias Capacity = ChildTabCapacity
        let idle = Capacity.Resources(load: 1, cores: 10, freeGB: 120, simulatorLeases: 0)
        func wait(_ parent: Int, _ overall: Int, _ resources: Capacity.Resources = idle, simulator: Bool = false) -> String? {
            Capacity.autoForkWait(parentRunning: parent, overallRunning: overall, perParentLimit: 3, overallLimit: 4,
                                  resources: resources, needsSimulator: simulator)
        }
        precondition(wait(0, 0) == nil && wait(2, 3) == nil)
        precondition(wait(3, 3) == "Auto-forks when a child tab finishes (3 of 3 running for this tab)")
        precondition(wait(1, 4) == "Auto-forks when a child tab finishes (4 of 4 running)")
        var busy = idle
        busy.load = 8
        precondition(Capacity.autoOverallLimit(4, resources: busy) == 3)
        precondition(wait(1, 3, busy) == "Auto-forks when a child tab finishes (3 of 3 running; fewer while the Mac is busy)")
        busy.load = 12.5
        precondition(wait(0, 0, busy) == "Auto-forks when the Mac is less busy (load 12.5 on 10 cores)")
        var short = idle
        short.freeGB = 22
        precondition(wait(1, 3, short) == "Auto-forks when a child tab finishes (3 of 3 running; fewer while disk is getting full)")
        short.freeGB = 9.6
        precondition(wait(0, 0, short) == "Auto-forks when more disk is free (9 GB free, needs 15 GB)")
        var pressed = idle
        pressed.load = 7.5
        pressed.freeGB = 20
        precondition(Capacity.autoOverallLimit(4, resources: pressed) == 2 && Capacity.autoOverallLimit(1, resources: pressed) == 1)
        var simulators = idle
        simulators.simulatorLeases = 3
        precondition(wait(0, 0, simulators) == nil, "only work that needs a Simulator waits for one")
        precondition(wait(0, 0, simulators, simulator: true) == "Auto-forks when a Simulator frees up (3 in use)")
        precondition(Capacity.needsSimulator("Run the UI tests on the Duo simulator")
                     && Capacity.needsSimulator("xcodebuild -scheme Hermes test")
                     && !Capacity.needsSimulator("Plan the secrets broker; end with a question"))
        let sampled = Capacity.sample(volume: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("not-yet-made/x"))
        precondition(sampled.cores > 0 && (sampled.freeGB ?? 0) > 0 && sampled.load >= 0, "\(sampled)")
    }

    private static func requireAutoFork<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
