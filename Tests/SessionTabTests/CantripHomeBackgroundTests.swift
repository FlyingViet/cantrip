import Foundation

extension SessionTabTests {
    final class CantripHomeRunPool {
        var fixtures: [(sessionID: UUID, fixture: CantripHomeBackendFixture)] = []

        func fixture(for sessionID: UUID?) -> CantripHomeBackendFixture? {
            fixtures.last { $0.sessionID == sessionID }?.fixture
        }
    }

    /// Parallel hidden background runs, incident routing to owning tabs, dependencies,
    /// Stop, restart recovery and the task-edit inbox.
    @MainActor
    static func testCantripHomeBackgroundRuns(
        bassSession: ChatSession, routeBackend: CantripHomeBackendFixture,
        token: String, port: Int
    ) async throws {
        let store = CantripHomeStore.shared
        let zone = "America/Los_Angeles"
        let previousParallel = AppSettings.shared.cantripHomeParallelRuns
        AppSettings.shared.cantripHomeParallelRuns = 2
        defer { AppSettings.shared.cantripHomeParallelRuns = previousParallel }
        for task in store.tasks where task.isScheduled && task.enabled {
            _ = try store.update(id: task.id, update: .init(title: nil, prompt: nil, enabled: false))
        }

        // Older builds left automated turns in Home; they move once to the background log.
        let homeFixture = CantripHomeBackendFixture()
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: homeFixture)
        let log = ChatSession(
            id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture()
        )
        log.messages = []
        let legacyMarker = "[incident:\(UUID().uuidString.lowercased())]"
        let legacyScheduled = "Scheduled task · Daily interview tracker\n\nRefresh Mail."
        let legacyIncident = "AUTOMATED BASS COMPASS INGESTION INCIDENT \(legacyMarker)\nInvestigate."
        homeChat.messages = [
            ChatMessage(role: .user, text: legacyScheduled),
            ChatMessage(role: .assistant, text: "Tracker refreshed."),
            ChatMessage(role: .user, text: "Hello"),
            ChatMessage(role: .assistant, text: "Hi there."),
            ChatMessage(role: .user, text: legacyIncident),
            ChatMessage(role: .assistant, text: "Investigating the timeout."),
        ]
        let manager = SessionManager(homeSession: homeChat, homeBackgroundSession: log)
        manager.sessions = [bassSession]
        precondition(homeChat.messages.map(\.text) == ["Hello", "Hi there."]
                     && log.messages.map(\.text) == [
                        legacyScheduled, "Tracker refreshed.",
                        legacyIncident, "Investigating the timeout.",
                     ]
                     && homeChat.moveAutomatedCantripHomeTurns(to: log) == 0,
                     "Automated turns older builds left in Home must move once to the background log")

        let pool = CantripHomeRunPool()
        func useFixtureRuns() {
            store.runner.makeSession = { id in
                let fixture = CantripHomeBackendFixture()
                pool.fixtures.append((id, fixture))
                return ChatSession(id: id, copilotBackend: fixture, cantripHomeRun: true, makeJournal: {
                    try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory)
                })
            }
        }
        useFixtureRuns()
        var handoffNotices: [(run: CantripHomeBackgroundRun, handoff: CantripHomeDelegation)] = []
        store.onHandoff = { handoffNotices.append(($0, $1)) }
        defer { store.onHandoff = nil }
        store.attach(manager: manager)

        let server = RemoteControlServer(manager: manager)
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET") async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try JSONSerialization.jsonObject(with: data)) as! [String: Any])
        }
        func run(_ id: UUID?) -> CantripHomeBackgroundRun? {
            store.backgroundRuns.first { $0.id == id }
        }
        func runningRun(forTask id: UUID) -> UUID? {
            store.backgroundRuns.first { $0.taskID == id && $0.status == "running" }?.id
        }
        func fixture(forRun id: UUID) -> CantripHomeBackendFixture? {
            pool.fixture(for: store.runner.session(forRun: id)?.id)
        }
        func finish(_ id: UUID, _ text: String, line: UInt = #line) async throws {
            try await waitForJournalTest(line: line) { fixture(forRun: id)?.sink != nil }
            let session = try requireHome(store.runner.session(forRun: id), line: line)
            let sink = fixture(forRun: id)?.sink
            sink?(.textDelta(text))
            sink?(.done)
            try await waitForJournalTest(line: line) { run(id)?.status != "running" }
            try await waitForJournalTest(line: line) {
                !store.backgroundSession!.messages.isEmpty
                    && !(store.runner.liveRunIDs.contains(id))
                    && !SessionManager.isCantripHomeReserved(session.id)
            }
        }
        func onceTask(
            _ title: String, _ prompt: String, due: Date, runsAfter: [UUID]? = nil
        ) throws -> CantripHomeTask {
            try store.create(.init(
                id: nil, title: title, prompt: prompt,
                schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: due),
                runsAfter: runsAfter
            ), now: due.addingTimeInterval(-30))
        }

        // Protocols: Home learns where background work runs; each hidden run gets the task
        // protocol, the open tabs with the same matching rules, and the shared Mail refresh.
        let homeGuidance = homeChat.cantripHomeInstructions
        precondition(homeGuidance.contains(
            "- Automated Bass Compass Ingestion Incident: Investigating the timeout.\n"
                + "- Daily interview tracker: Tracker refreshed.")
                     && homeGuidance.contains(CantripHomeStore.tasksFile.path)
                     && homeGuidance.contains("hidden background sessions")
                     && homeGuidance.contains("Project tabs —")
                     && !homeGuidance.contains("Never emit this block for scheduled task runs"),
                     "Home must know where background work runs and may be handed off")
        let probe = ChatSession(cantripHomeRun: true, makeJournal: { _ in
            try RunJournal(sessionID: UUID(), directory: CantripHomeStore.runsDirectory)
        })
        let backgroundGuidance = probe.cantripHomeInstructions
        precondition(backgroundGuidance.contains("CANTRIP HOME BACKGROUND")
                     && backgroundGuidance.contains("in its own hidden session")
                     && backgroundGuidance.contains(CantripHomeStore.mailRefreshCommand)
                     && backgroundGuidance.contains("Project tabs —")
                     && backgroundGuidance.contains(bassSession.id.uuidString)
                     && backgroundGuidance.contains("Scheduled personal tasks")
                     && !backgroundGuidance.contains("Recent background runs")
                     && probe.isLocked && probe.title == "Cantrip Home background",
                     "Hidden runs get the background protocol with tab handoffs and Mail safety")

        homeChat.submit("Can you run the interview tracker again?")
        try await waitForJournalTest { homeFixture.sink != nil }
        let homeCount = homeChat.messages.count

        // Three due tasks with a cap of two: two run at once in hidden sessions, one waits.
        let now = Date()
        AppSettings.shared.cantripHomeEnabled = false
        let taskA = try onceTask("Parallel A", "Report A.", due: now.addingTimeInterval(-30))
        let taskB = try onceTask("Parallel B", "Report B.", due: now.addingTimeInterval(-20))
        let taskC = try onceTask("Parallel C", "Report C.", due: now.addingTimeInterval(-10))
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let runA = try requireHome(runningRun(forTask: taskA.id))
        let runB = try requireHome(runningRun(forTask: taskB.id))
        let waitingC = try requireHome(store.runner.pendingJobs.first { $0.taskID == taskC.id })
        let sessionA = try requireHome(store.runner.session(forRun: runA))
        let sessionB = try requireHome(store.runner.session(forRun: runB))
        precondition(runningRun(forTask: taskC.id) == nil && store.runner.runningCount == 2
                     && manager.homeRuns.count == 2 && sessionA !== sessionB
                     && manager.sessions.map(\.id) == [bassSession.id]
                     && store.runner.waitReasons[waitingC.id]?.contains("free slot") == true
                     && store.tasks.first { $0.id == taskA.id }?.state == .running
                     && store.tasks.first { $0.id == taskB.id }?.state == .running,
                     "Unrelated tasks run in parallel hidden sessions up to the limit")
        precondition(homeChat.isStreaming && homeChat.messages.count == homeCount
                     && !homeChat.messages.contains { $0.text.contains("Parallel A") },
                     "Background runs never wait for, or write into, the Home chat")
        try await waitForJournalTest { fixture(forRun: runA)?.sink != nil }
        let promptA = fixture(forRun: runA)?.lastPrompt ?? ""
        precondition(promptA.contains("Report A.") && promptA.contains("CANTRIP HOME BACKGROUND")
                     && promptA.contains("saved Cantrip Home task \(taskA.id.uuidString)")
                     && !promptA.contains("runs a missed schedule once")
                     && fixture(forRun: runA)?.lastTurnCount == 0
                     && sessionA.notificationTitle == "Parallel A"
                     && sessionA.messages.first?.text
                        == "Scheduled task · Parallel A\nOnce · running saved instructions",
                     "Each run starts fresh with its saved prompt and a short label")
        let listed = try await call("/api/v1/sessions")
        let listedIDs = (listed.1["sessions"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
        precondition(!listedIDs.contains(sessionA.id.uuidString)
                     && !manager.archivedSessions().contains { $0.id == sessionA.id }
                     && SessionManager.isCantripHomeReserved(sessionA.id),
                     "Hidden runs never appear in tab lists or archives")
        let liveRoute = try await call("/api/v1/sessions/\(sessionA.id.uuidString)")
        let liveSnapshot = try requireHome(liveRoute.1["session"] as? [String: Any])
        precondition(liveRoute.0 == 200
                     && liveSnapshot["isCantripHomeBackground"] as? Bool == true
                     && liveSnapshot["supportsTabMetadata"] as? Bool == false
                     && liveSnapshot["isLocked"] as? Bool == true,
                     "Input pushes can open a live hidden run by ID")
        let backgroundList = try await call("/api/v1/home/background")
        let listedRuns = backgroundList.1["runs"] as? [[String: Any]] ?? []
        let listedQueue = backgroundList.1["queued"] as? [[String: Any]] ?? []
        let liveA = listedRuns.first { $0["id"] as? String == runA.uuidString }
        precondition(backgroundList.0 == 200
                     && backgroundList.1["sessionID"] as? String
                        == ChatSession.cantripHomeBackgroundID.uuidString
                     && backgroundList.1["maxParallel"] as? Int == 2
                     && backgroundList.1["runningCount"] as? Int == 2
                     && backgroundList.1["supportsStop"] as? Bool == true
                     && backgroundList.1["activity"] == nil
                     && liveA?["status"] as? String == "running"
                     && liveA?["canStop"] as? Bool == true
                     && liveA?["route"] as? String == "hidden"
                     && liveA?["sessionID"] as? String == sessionA.id.uuidString
                     && liveA?["activity"] is String
                     && listedQueue.count == 1
                     && listedQueue.first?["label"] as? String == "Parallel C"
                     && (listedQueue.first?["reason"] as? String)?.contains("free slot") == true,
                     "The Background API lists each live run, its activity and why work waits")
        let busyHome = try await call("/api/v1/home")
        precondition((busyHome.1["session"] as? [String: Any])?["backgroundActiveCount"] as? Int == 3,
                     "Home's badge counts running and queued background work")

        // A run that needs the user is answered in place: the Background list, Home's badge and
        // the tab list (for clients without Home) carry the request, and answering it through the
        // hidden run's own session resumes that run. The run never becomes a tab.
        var approvalAnswer: InputRequestAnswer.Decision?
        fixture(forRun: runA)?.sink?(.inputRequired(BackendInputRequest(
            kind: .approval, source: "Cantrip Home", title: "Parallel A wants to push to a git remote",
            detail: "git push origin main"
        ) { approvalAnswer = $0.decision }))
        try await waitForJournalTest { !sessionA.pendingInputs.isEmpty }
        let requestID = sessionA.pendingInputs[0].id.uuidString
        let asking = try await call("/api/v1/home/background")
        let askingA = (asking.1["runs"] as? [[String: Any]] ?? []).first { $0["id"] as? String == runA.uuidString }
        let askingInputs = askingA?["inputs"] as? [[String: Any]] ?? []
        let otherInputs = (asking.1["runs"] as? [[String: Any]] ?? []).first { $0["id"] as? String == runB.uuidString }?["inputs"]
        precondition(askingA?["activity"] as? String == "Needs your input"
                     && askingInputs.count == 1 && askingInputs[0]["id"] as? String == requestID
                     && askingInputs[0]["kind"] as? String == "approval"
                     && askingInputs[0]["title"] as? String == "Parallel A wants to push to a git remote"
                     && askingInputs[0]["detail"] as? String == "git push origin main"
                     && askingA?["sessionID"] as? String == sessionA.id.uuidString && otherInputs == nil,
                     "The Background list carries a run's pending approval with the session that answers it")
        let askingHome = try await call("/api/v1/home")
        precondition((askingHome.1["session"] as? [String: Any])?["backgroundInputCount"] as? Int == 1,
                     "Home's snapshot says how many background requests wait for the user")
        let askingTabs = try await call("/api/v1/sessions")
        let homeInputs = askingTabs.1["homeInputs"] as? [[String: Any]] ?? []
        precondition(homeInputs.count == 1 && homeInputs[0]["runID"] as? String == runA.uuidString
                     && homeInputs[0]["sessionID"] as? String == sessionA.id.uuidString
                     && homeInputs[0]["label"] as? String == "Parallel A"
                     && (homeInputs[0]["requests"] as? [[String: Any]])?.first?["id"] as? String == requestID
                     && !((askingTabs.1["sessions"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == sessionA.id.uuidString },
                     "The tab list carries Home's waiting requests without listing the hidden run")
        var answer = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(sessionA.id.uuidString)/input/\(requestID)")!)
        answer.httpMethod = "POST"
        answer.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        answer.setValue("application/json", forHTTPHeaderField: "Content-Type")
        answer.httpBody = Data(#"{"decision":"approve"}"#.utf8)
        let (_, answered) = try await client.data(for: answer)
        try await waitForJournalTest { approvalAnswer != nil }
        precondition((answered as? HTTPURLResponse)?.statusCode == 200 && approvalAnswer == .approve
                     && sessionA.pendingInputs.isEmpty && run(runA)?.status == "running",
                     "Approving through the hidden run's session reaches that run, which keeps going")
        let resolved = try await call("/api/v1/sessions")
        let resolvedHome = try await call("/api/v1/home")
        precondition(resolved.1["homeInputs"] == nil
                     && (resolvedHome.1["session"] as? [String: Any])?["backgroundInputCount"] as? Int == 0,
                     "Answered requests leave every list")

        // Finishing A frees a slot for C; A's session is torn down and its report kept.
        try await finish(runA, "A finished.")
        try await waitForJournalTest { runningRun(forTask: taskC.id) != nil }
        let runC = try requireHome(runningRun(forTask: taskC.id))
        precondition(run(runA)?.summary == "A finished." && run(runA)?.status == "succeeded"
                     && run(runA)?.sessionID == nil
                     && !manager.homeRuns.contains { $0 === sessionA }
                     && sessionA.remoteCompletion?.sessionID == ChatSession.cantripHomeBackgroundID
                     && sessionA.remoteCompletion?.title == "Parallel A"
                     && log.messages.contains { $0.text.hasPrefix("Scheduled task · Parallel A") }
                     && log.messages.contains { $0.text == "A finished." }
                     && store.tasks.first { $0.id == taskA.id }?.runs.first?.status == "succeeded",
                     "A finished run keeps its report in the background log and opens it from pushes")
        let runFiles = try FileManager.default.contentsOfDirectory(atPath: CantripHomeStore.runsDirectory.path)
        precondition(!runFiles.contains { $0.hasPrefix(sessionA.id.uuidString) }
                     && UserDefaults.standard.object(forKey: "lastRunOutcome-\(sessionA.id.uuidString)") == nil
                     && UserDefaults.standard.object(forKey: "sessionTab-\(sessionA.id.uuidString)") == nil,
                     "Finished hidden sessions leave no transcript, journal or defaults behind")
        precondition(homeChat.cantripHomeInstructions.contains("- Parallel A: A finished."),
                     "Home sees finished background results")

        // Per-run Stop: a running run, then a run still waiting for a slot.
        let stopped = try await call("/api/v1/home/background/\(runB.uuidString)/stop", method: "POST")
        try await waitForJournalTest { run(runB)?.status == "cancelled" }
        precondition(stopped.0 == 200 && run(runB)?.summary == "Stopped."
                     && !store.runner.liveRunIDs.contains(runB),
                     "Stop ends one hidden run without touching the others")
        let stoppedAgain = try await call("/api/v1/home/background/\(runB.uuidString)/stop", method: "POST")
        precondition(stoppedAgain.0 == 409)
        AppSettings.shared.cantripHomeParallelRuns = 1
        AppSettings.shared.cantripHomeEnabled = false
        let taskD = try onceTask("Queued D", "Report D.", due: Date().addingTimeInterval(-5))
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let waitingD = try requireHome(store.runner.pendingJobs.first { $0.taskID == taskD.id })
        let stoppedQueued = try await call(
            "/api/v1/home/background/\(waitingD.id.uuidString)/stop", method: "POST"
        )
        store.checkNow()
        precondition(stoppedQueued.0 == 200 && run(waitingD.id)?.status == "cancelled"
                     && run(waitingD.id)?.summary == "Stopped before it started."
                     && !store.runner.hasJob(forTask: taskD.id)
                     && store.tasks.first { $0.id == taskD.id }?.enabled == false,
                     "Stopping queued work skips that run instead of starting it later")
        try await finish(runC, "C finished.")
        AppSettings.shared.cantripHomeParallelRuns = 2

        // A task is never started twice; an overdue task runs once and says it is late.
        AppSettings.shared.cantripHomeEnabled = false
        let interval = try store.create(.init(
            id: nil, title: "Interval check", prompt: "Check the interval.",
            schedule: .init(kind: .interval, summary: "Every 5 minutes", timeZone: zone,
                            startAt: Date().addingTimeInterval(-3_600), intervalMinutes: 5)
        ), now: Date().addingTimeInterval(-3_630))
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        store.checkNow()
        store.checkNow()
        let intervalRun = try requireHome(runningRun(forTask: interval.id))
        try await waitForJournalTest { fixture(forRun: intervalRun)?.sink != nil }
        precondition(store.runner.jobs.filter { $0.taskID == interval.id }.count == 1
                     && store.backgroundRuns.filter { $0.taskID == interval.id }.count == 1
                     && fixture(forRun: intervalRun)?.lastPrompt?.contains("starting 60 minutes late") == true
                     && fixture(forRun: intervalRun)?.lastPrompt?.contains("runs a missed schedule once") == true,
                     "Duplicate triggers for a running task coalesce into the one run")
        try await finish(intervalRun, "Interval done.")
        store.checkNow()
        precondition(runningRun(forTask: interval.id) == nil
                     && (store.tasks.first { $0.id == interval.id }?.nextRunAt ?? .distantPast) > Date(),
                     "After a catch-up run the next slot is in the future")
        _ = try store.update(id: interval.id, update: .init(title: nil, prompt: nil, enabled: false))

        // Tasks that write the same workspace never overlap.
        AppSettings.shared.cantripHomeEnabled = false
        let writerX = try onceTask("Writer X", "Update the records.", due: Date().addingTimeInterval(-20))
        let writerY = try onceTask(
            "Writer Y", "Also update task \(writerX.id.uuidString)'s records.",
            due: Date().addingTimeInterval(-10)
        )
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let runX = try requireHome(runningRun(forTask: writerX.id))
        let waitingY = try requireHome(store.runner.pendingJobs.first { $0.taskID == writerY.id })
        precondition(store.runner.runningCount == 1
                     && store.runner.waitReasons[waitingY.id] == "Waiting for Writer X to finish",
                     "A job that writes another task's workspace waits for it")
        try await finish(runX, "X done.")
        try await waitForJournalTest { runningRun(forTask: writerY.id) != nil }
        try await finish(try requireHome(runningRun(forTask: writerY.id)), "Y done.")

        // runsAfter: a briefing waits for trackers due before it, not ones due after it,
        // and stops waiting at its limit.
        let base = Date().addingTimeInterval(3 * 86_400)
        store.clock = { base.addingTimeInterval(60) }
        defer { store.clock = { Date() } }
        AppSettings.shared.cantripHomeEnabled = false
        func futureTask(_ title: String, at offset: TimeInterval, runsAfter: [UUID]? = nil) throws -> CantripHomeTask {
            try store.create(.init(
                id: nil, title: title, prompt: "Run \(title).",
                schedule: .init(kind: .once, summary: "Once", timeZone: zone,
                                startAt: base.addingTimeInterval(offset)),
                runsAfter: runsAfter
            ), now: base.addingTimeInterval(-7_200))
        }
        let bills = try futureTask("Bills", at: -900)
        let trip = try futureTask("Trip", at: 900)
        let briefing = try futureTask("Briefing", at: 0, runsAfter: [bills.id, trip.id])
        precondition(briefing.runsAfter == [bills.id, trip.id]
                     && homeChat.cantripHomeInstructions.contains(
                        "runsAfter \(bills.id.uuidString),\(trip.id.uuidString)")
                     && homeChat.cantripHomeInstructions.contains(#""runsAfter":["other task UUID"] or null"#),
                     "Home's protocol documents and lists task dependencies")
        do {
            _ = try store.create(.init(id: briefing.id, title: nil, prompt: nil, schedule: nil,
                                       runsAfter: [briefing.id]))
            preconditionFailure("A task cannot run after itself")
        } catch is CantripHomeError {}
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let billsRun = try requireHome(runningRun(forTask: bills.id))
        let waitingBriefing = try requireHome(store.runner.pendingJobs.first { $0.taskID == briefing.id })
        precondition(store.runner.runningCount == 1
                     && store.runner.waitReasons[waitingBriefing.id]?.hasPrefix("Waiting for Bills") == true
                     && store.runner.waitReasons[waitingBriefing.id]?.contains("Trip") == false,
                     "A dependent task waits only for prerequisites due before it")
        try await finish(billsRun, "Bills done.")
        try await waitForJournalTest { runningRun(forTask: briefing.id) != nil }
        let briefingRun = try requireHome(runningRun(forTask: briefing.id))
        try await waitForJournalTest { fixture(forRun: briefingRun)?.sink != nil }
        precondition(fixture(forRun: briefingRun)?.lastPrompt?.contains("wait limit") == false,
                     "The briefing starts as soon as its earlier prerequisites finish")
        try await finish(briefingRun, "Briefing done.")
        AppSettings.shared.cantripHomeEnabled = false
        _ = try store.update(id: trip.id, update: .init(title: nil, prompt: nil, enabled: false))
        let slow = try futureTask("Slow tracker", at: 3_000)
        let late = try futureTask("Late briefing", at: 3_600, runsAfter: [slow.id])
        store.clock = { base.addingTimeInterval(3_660) }
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let slowRun = try requireHome(runningRun(forTask: slow.id))
        precondition(runningRun(forTask: late.id) == nil, "The dependent task waits for the slow tracker")
        store.clock = { base.addingTimeInterval(3_600 + 31 * 60) }
        store.checkNow()
        let lateRun = try requireHome(runningRun(forTask: late.id))
        try await waitForJournalTest { fixture(forRun: lateRun)?.sink != nil }
        precondition(fixture(forRun: lateRun)?.lastPrompt?.contains(
            "Started after its wait limit while Slow tracker had not finished") == true,
                     "After its wait limit a dependent task starts and says what is missing")
        try await finish(slowRun, "Slow done.")
        try await finish(lateRun, "Late done.")

        // A dependent whose prompt names its prerequisite never blocks that prerequisite.
        let sameTime = Date().addingTimeInterval(5 * 86_400)
        store.clock = { sameTime.addingTimeInterval(60) }
        AppSettings.shared.cantripHomeEnabled = false
        func dueAt(_ date: Date, _ title: String, _ prompt: String, after: [UUID]? = nil) throws -> CantripHomeTask {
            try store.create(.init(
                id: nil, title: title, prompt: prompt,
                schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: date),
                runsAfter: after
            ), now: date.addingTimeInterval(-600))
        }
        let source = try dueAt(sameTime, "Source tracker", "Track sources.")
        let digest = try dueAt(sameTime, "Digest", "Summarize task \(source.id.uuidString).",
                               after: [source.id])
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let sourceRun = try requireHome(runningRun(forTask: source.id))
        precondition(runningRun(forTask: digest.id) == nil
                     && store.runner.pendingJobs.contains { $0.taskID == digest.id },
                     "The prerequisite starts even though its dependent names it and was queued first")
        try await finish(sourceRun, "Sources tracked.")
        try await waitForJournalTest { runningRun(forTask: digest.id) != nil }
        try await finish(try requireHome(runningRun(forTask: digest.id)), "Digest done.")
        store.clock = { Date() }

        // A hidden run that fails again after its one automatic resume ends as failed.
        let flaky = try onceTask("Flaky check", "Run the flaky check.", due: Date().addingTimeInterval(-5))
        let flakyRun = try requireHome(runningRun(forTask: flaky.id))
        try await waitForJournalTest { fixture(forRun: flakyRun)?.sink != nil }
        let flakyFixture = try requireHome(fixture(forRun: flakyRun))
        let firstAttempt = flakyFixture.sink
        flakyFixture.sink = nil
        firstAttempt?(.textDelta("Partial progress."))
        firstAttempt?(.failure("Network dropped."))
        let resumeDeadline = Date().addingTimeInterval(12)
        while flakyFixture.sink == nil, Date() < resumeDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(flakyFixture.sink != nil && run(flakyRun)?.status == "running",
                     "The first interruption resumes automatically")
        flakyFixture.sink?(.failure("Network dropped again."))
        try await waitForJournalTest { run(flakyRun)?.status == "failed" }
        precondition(run(flakyRun)?.summary == "Network dropped again."
                     && !store.runner.liveRunIDs.contains(flakyRun)
                     && store.tasks.first { $0.id == flaky.id }?.state == .failed,
                     "A run that cannot resume again releases its slot and records the failure")

        // A session that goes idle without completing is failed by the stall reaper.
        let stuck = try onceTask("Stuck check", "Run the stuck check.", due: Date().addingTimeInterval(-5))
        let stuckRun = try requireHome(runningRun(forTask: stuck.id))
        let stuckSession = try requireHome(store.runner.session(forRun: stuckRun))
        try await waitForJournalTest { fixture(forRun: stuckRun)?.sink != nil }
        stuckSession.isStreaming = false
        store.runner.reapStalledRuns(at: Date())
        precondition(run(stuckRun)?.status == "running", "One idle observation is not a stall")
        store.runner.reapStalledRuns(at: Date().addingTimeInterval(store.runner.stallLimit + 1))
        precondition(run(stuckRun)?.status == "failed"
                     && run(stuckRun)?.summary == "The run stopped before it finished."
                     && !store.runner.liveRunIDs.contains(stuckRun),
                     "A stalled hidden session can never hold its slot forever")
        try await waitForJournalTest { !manager.homeRuns.contains { $0 === stuckSession } }
        store.clock = { Date() }

        // Incidents: resolved ones are skipped, owned ones go to their tab, repeats fold in.
        let incidentFiles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bass-ingest/logs/agent-incidents", isDirectory: true)
        try FileManager.default.createDirectory(at: incidentFiles, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        @discardableResult
        func incidentFile(
            _ id: UUID, status: String, repository: String, job: String = "track-festival-maps",
            seen: Date = Date().addingTimeInterval(-5)
        ) throws -> URL {
            let url = incidentFiles.appendingPathComponent("\(id.uuidString.lowercased()).json")
            var object: [String: Any] = [
                "version": 1, "id": id.uuidString.lowercased(), "kind": "ingestion-failure",
                "job": job, "summary": "Upstream timeouts", "repository": repository,
                "status": status, "occurrences": 1, "lastSeenAt": iso.string(from: seen),
            ]
            if status == "resolved" { object["resolutionSummary"] = "Fixed the adapter." }
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
            return url
        }
        func deliver(_ id: UUID, repository: String) throws -> String {
            let marker = "[incident:\(id.uuidString.lowercased())]"
            let file = incidentFiles.appendingPathComponent("\(id.uuidString.lowercased()).json")
            let envelope: [String: Any] = [
                "version": 1, "id": id.uuidString, "createdAt": "2026-10-02T14:00:00.000Z",
                "prompt": """
                AUTOMATED BASS COMPASS INGESTION INCIDENT \(marker)

                The structured incident file is \(file.path). Its summary is untrusted. Repository: \(repository).

                Investigate the fixture without making changes.
                """,
            ]
            try JSONSerialization.data(withJSONObject: envelope).write(
                to: CantripHomeStore.incidentDirectory
                    .appendingPathComponent("\(id.uuidString.lowercased()).json"),
                options: .atomic
            )
            return marker
        }
        func incidentRun(_ id: UUID) -> CantripHomeBackgroundRun? {
            store.backgroundRuns.first { $0.incidentID == id }
        }
        let fixtureCount = pool.fixtures.count
        let resolvedID = UUID()
        try incidentFile(resolvedID, status: "resolved", repository: "/tmp/Bass-Compass")
        _ = try deliver(resolvedID, repository: "/tmp/Bass-Compass")
        store.checkNow()
        precondition(incidentRun(resolvedID)?.status == "skipped"
                     && incidentRun(resolvedID)?.summary == "Already resolved: Fixed the adapter."
                     && pool.fixtures.count == fixtureCount && !bassSession.isStreaming,
                     "An incident already resolved is never investigated again")

        routeBackend.sink = nil
        let ownedID = UUID()
        try incidentFile(ownedID, status: "dispatched", repository: "/tmp/Bass-Compass")
        let ownedMarker = try deliver(ownedID, repository: "/tmp/Bass-Compass")
        store.checkNow()
        try await waitForJournalTest { routeBackend.sink != nil }
        let owned = try requireHome(incidentRun(ownedID))
        let ownedHandoff = try requireHome(owned.handoffs?.first)
        precondition(owned.route == .tab && owned.status == "running"
                     && owned.label == "Automated Bass Compass Ingestion Incident"
                     && ownedHandoff.tabID == bassSession.id
                     && pool.fixtures.count == fixtureCount
                     && bassSession.messages.contains {
                         $0.role == .user && $0.text.contains(ownedMarker)
                             && $0.text.contains("untrusted evidence")
                     }
                     && handoffNotices.last?.handoff.tabID == bassSession.id,
                     "An incident in a project an open tab owns goes to that tab's queue")
        let handedList = try await call("/api/v1/home/background")
        let handedRun = (handedList.1["runs"] as? [[String: Any]])?.first {
            $0["id"] as? String == owned.id.uuidString
        }
        let handedCard = (handedRun?["handoffs"] as? [[String: Any]])?.first
        precondition(handedRun?["route"] as? String == "tab" && handedRun?["canStop"] as? Bool == true
                     && handedRun?["activity"] is String
                     && handedCard?["tabTitle"] as? String == "Bass Compass"
                     && handedCard?["tabID"] as? String == bassSession.id.uuidString
                     && handedCard?["startedAt"] is Double,
                     "The Background list shows the handoff with its tab and live status")
        precondition(homeChat.cantripHomeInstructions.contains(
            "Bass Compass · Automated Bass Compass Ingestion Incident · running"),
                     "Background handoffs appear under Home's recent handoffs")
        let tabPrompts = bassSession.messages.filter { $0.role == .user }.count
        _ = try deliver(ownedID, repository: "/tmp/Bass-Compass")
        store.checkNow()
        precondition(incidentRun(ownedID)?.repeats == 1
                     && store.backgroundRuns.filter { $0.incidentID == ownedID }.count == 1
                     && bassSession.messages.filter { $0.role == .user }.count == tabPrompts
                     && bassSession.queued.isEmpty,
                     "A repeat of an incident already in a tab folds into that handoff")
        let groupedID = UUID()
        let groupedFile = try incidentFile(groupedID, status: "dispatched", repository: "/tmp/Bass-Compass")
        _ = try deliver(groupedID, repository: "/tmp/Bass-Compass")
        store.checkNow()
        let groupedJob = try requireHome(store.runner.pendingJobs.first { $0.incidentID == groupedID })
        precondition(store.runner.waitReasons[groupedJob.id]?.contains("in Bass Compass") == true
                     && bassSession.queued.isEmpty,
                     "Another failure of the same job waits for the active investigation")
        // The tab's fix also resolves the grouped incident.
        try incidentFile(groupedID, status: "resolved", repository: "/tmp/Bass-Compass")
        precondition(FileManager.default.fileExists(atPath: groupedFile.path))
        routeBackend.sink?(.textDelta("Fixed the map timeouts."))
        routeBackend.sink?(.done)
        try await waitForJournalTest { !bassSession.isStreaming }
        CantripHomeDelegations.shared.refresh()
        try await waitForJournalTest { incidentRun(groupedID)?.status == "skipped" }
        precondition(incidentRun(ownedID)?.status == "succeeded"
                     && incidentRun(ownedID)?.summary == "Fixed the map timeouts."
                     && incidentRun(ownedID)?.handoffs?.first?.status == .completed
                     && pool.fixtures.count == fixtureCount,
                     "The handed-off incident finishes with the tab, then grouped repeats are rechecked")

        let unownedID = UUID()
        try incidentFile(unownedID, status: "dispatched", repository: "/tmp/unowned-pipeline")
        let unownedMarker = try deliver(unownedID, repository: "/tmp/unowned-pipeline")
        store.checkNow()
        let unownedRun = try requireHome(incidentRun(unownedID))
        let unownedSession = try requireHome(store.runner.session(forRun: unownedRun.id))
        try await waitForJournalTest { fixture(forRun: unownedRun.id)?.sink != nil }
        let unownedPrompt = fixture(forRun: unownedRun.id)?.lastPrompt ?? ""
        precondition(unownedRun.route == .hidden && unownedPrompt.contains(unownedMarker)
                     && unownedPrompt.contains("untrusted evidence")
                     && unownedPrompt.contains("CANTRIP HOME BACKGROUND")
                     && fixture(forRun: unownedRun.id)?.lastTurnCount == 0
                     && unownedSession.notificationTitle == "Automated Bass Compass Ingestion Incident",
                     "With no owning tab an incident runs in its own hidden session")
        try await finish(unownedRun.id, "Investigated.")
        _ = try deliver(unownedID, repository: "/tmp/unowned-pipeline")
        store.checkNow()
        precondition(store.backgroundRuns.filter { $0.incidentID == unownedID }.count == 1
                     && incidentRun(unownedID)?.repeats == 1 && store.runner.jobs.isEmpty,
                     "Redelivering an incident with no new occurrence never runs it twice")

        // A hidden run may hand change work it finds to the owning tab, once.
        routeBackend.sink = nil
        func delegate(_ prompt: String) -> String {
            """
            Report done. Handing off the fix.

            ```cantrip-delegate
            {"tabID":"\(bassSession.id.uuidString)","summary":"Fix lineup data","prompt":"\(prompt)"}
            ```
            """
        }
        let nightly = try onceTask("Nightly Bass check", "Check Bass Compass.", due: Date().addingTimeInterval(-5))
        let nightlyRun = try requireHome(runningRun(forTask: nightly.id))
        let lineupFix = "Fix the stale Portola 2026 lineup rows that still show last year's set times."
        try await finish(nightlyRun, delegate(lineupFix))
        try await waitForJournalTest { routeBackend.sink != nil }
        let nightlyResult = try requireHome(run(nightlyRun))
        let nightlyBrief = bassSession.messages.last { $0.role == .user }?.text ?? ""
        precondition(nightlyResult.status == "succeeded"
                     && nightlyResult.handoffs?.first?.tabID == bassSession.id
                     && nightlyResult.summary.contains("Handed to **Bass Compass**: Fix lineup data")
                     && !nightlyResult.summary.contains("cantrip-delegate")
                     && nightlyBrief.hasPrefix("(Handed off by a Cantrip Home background run \"Nightly Bass check\".")
                     && nightlyBrief.contains(lineupFix),
                     "A background run's handoff lands in the tab and on its Background entry: \(nightlyBrief)")
        let nightlyAgain = try onceTask("Nightly Bass check 2", "Check Bass Compass.", due: Date().addingTimeInterval(-5))
        let againRun = try requireHome(runningRun(forTask: nightlyAgain.id))
        try await finish(againRun, delegate(lineupFix))
        precondition(run(againRun)?.handoffs == nil
                     && run(againRun)?.summary.contains("Already running in **Bass Compass**") == true
                     && bassSession.queued.isEmpty,
                     "The same change is never handed to a tab twice while it is active")
        routeBackend.sink?(.textDelta("Rows fixed."))
        routeBackend.sink?(.done)
        try await waitForJournalTest { !bassSession.isStreaming }
        CantripHomeDelegations.shared.refresh()
        precondition(run(nightlyRun)?.handoffs?.first?.status == .completed,
                     "Background handoff cards follow the tab to completion")

        // A quit while runs are live: the task catches up once, the incident retries once,
        // and their partial transcripts are kept in the background log.
        AppSettings.shared.cantripHomeEnabled = false
        let quitTask = try onceTask("Quit task", "Survive a quit.", due: Date().addingTimeInterval(-5))
        let quitIncident = UUID()
        try incidentFile(quitIncident, status: "dispatched", repository: "/tmp/unowned-pipeline")
        _ = try deliver(quitIncident, repository: "/tmp/unowned-pipeline")
        AppSettings.shared.cantripHomeEnabled = true
        store.checkNow()
        let quitTaskRun = try requireHome(runningRun(forTask: quitTask.id))
        let quitIncidentRun = try requireHome(incidentRun(quitIncident))
        try await waitForJournalTest {
            fixture(forRun: quitTaskRun)?.sink != nil && fixture(forRun: quitIncidentRun.id)?.sink != nil
        }
        let oldRuns = manager.homeRuns
        let relaunchedLog = ChatSession(
            id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
            makeJournal: { _ in try RunJournal(sessionID: UUID()) }
        )
        let relaunched = SessionManager(
            homeSession: ChatSession(
                id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            ),
            homeBackgroundSession: relaunchedLog
        )
        relaunched.sessions = [bassSession]
        store.relaunchRunnerForTesting(manager: relaunched)
        useFixtureRuns()
        precondition(run(quitTaskRun)?.status == "interrupted"
                     && run(quitIncidentRun.id)?.status == "interrupted"
                     && store.tasks.first { $0.id == quitTask.id }?.state == .scheduled
                     && relaunchedLog.messages.contains { $0.text.hasPrefix("Scheduled task · Quit task") }
                     && relaunchedLog.messages.contains {
                         $0.text == "Cantrip quit before this background run finished."
                     },
                     "Runs live at a quit are marked interrupted and their transcripts kept")
        for session in oldRuns {
            session.cancel()
            session.discardCantripHomeRun()
            manager.releaseCantripHomeRun(session)
        }
        store.checkNow()
        let retriedTask = try requireHome(runningRun(forTask: quitTask.id))
        let retriedIncident = try requireHome(store.backgroundRuns.first {
            $0.incidentID == quitIncident && $0.status == "running"
        })
        try await waitForJournalTest {
            fixture(forRun: retriedTask)?.sink != nil && fixture(forRun: retriedIncident.id)?.sink != nil
        }
        precondition(retriedTask != quitTaskRun && relaunched.homeRuns.count == 2
                     && fixture(forRun: retriedTask)?.lastPrompt?.contains(
                        "previous attempt was interrupted") == true,
                     "After a restart the missed task runs once and knows the last attempt was cut off")
        try await finish(retriedTask, "Quit task done.")
        try await finish(retriedIncident.id, "Quit incident done.")

        // The task-edit inbox sets dependencies for existing tasks.
        func writeEdit(_ directory: URL, _ name: String, _ body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(body.utf8).write(to: url, options: .atomic)
            return url
        }
        let editAttributes = try FileManager.default.attributesOfItem(
            atPath: CantripHomeStore.taskEditDirectory.path
        )
        precondition((editAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let dependencyEdit = try writeEdit(CantripHomeStore.taskEditDirectory, "1-briefing.json",
            #"{"version":1,"taskID":"\#(briefing.id.uuidString)","runsAfter":["\#(bills.id.uuidString)"],"runsAfterTimeoutMinutes":45}"#)
        let selfEdit = try writeEdit(CantripHomeStore.taskEditDirectory, "2-self.json",
            #"{"version":1,"taskID":"\#(bills.id.uuidString)","runsAfter":["\#(bills.id.uuidString)"]}"#)
        let emptyEdit = try writeEdit(CantripHomeStore.taskEditDirectory, "3-empty.json",
            #"{"version":1,"taskID":"\#(bills.id.uuidString)"}"#)
        store.checkNow()
        let edited = try requireHome(store.tasks.first { $0.id == briefing.id })
        precondition(edited.runsAfter == [bills.id] && edited.runsAfterTimeoutMinutes == 45
                     && !FileManager.default.fileExists(atPath: dependencyEdit.path)
                     && FileManager.default.fileExists(atPath: selfEdit.path + ".rejected")
                     && FileManager.default.fileExists(atPath: emptyEdit.path + ".rejected"),
                     "Queued task edits set runsAfter; invalid ones are set aside")

        homeFixture.sink?(.textDelta("Tracker refreshed again."))
        homeFixture.sink?(.done)
        try await waitForJournalTest { !homeChat.isStreaming }
        precondition(homeChat.messages.map(\.text) == [
            "Hello", "Hi there.", "Can you run the interview tracker again?", "Tracker refreshed again.",
        ], "Home holds only the user's own conversation")

        try await testCantripHomeMultiTimeCatchUp(
            homeChat: homeChat, pool: pool, useFixtureRuns: useFixtureRuns
        )
        try testMailRefreshCoalesces()

        for task in [taskA, taskB, taskC, taskD, interval, writerX, writerY, bills, trip, briefing,
                     slow, late, nightly, nightlyAgain, quitTask, source, digest, flaky, stuck] {
            try? store.delete(id: task.id)
        }
        precondition(manager.homeRuns.isEmpty && relaunched.homeRuns.isEmpty
                     && store.runner.jobs.isEmpty,
                     "No hidden sessions or jobs are left behind")

        // The list keeps 30 runs, but never drops one that is still active.
        let longRunning = UUID()
        store.insertBackgroundRun(.init(
            id: longRunning, kind: .incident, label: "Long handoff",
            startedAt: Date().addingTimeInterval(-7_200), status: "running", summary: ""
        ))
        for index in 0..<35 {
            store.insertBackgroundRun(.init(
                id: UUID(), kind: .task, label: "Old run \(index)", startedAt: Date(),
                finishedAt: Date(), status: "succeeded", summary: ""
            ))
        }
        precondition(store.backgroundRuns.count == CantripHomeStore.maximumBackgroundRuns
                     && store.backgroundRuns.contains { $0.id == longRunning },
                     "Trimming the run list keeps active runs")
        store.updateBackgroundRun(id: longRunning) {
            $0.status = "cancelled"
            $0.finishedAt = Date()
        }
    }

    /// One task, several daily times: Home's protocol, the schedule-edit inbox and catch-up.
    @MainActor
    static func testCantripHomeMultiTimeCatchUp(
        homeChat: ChatSession, pool: CantripHomeRunPool, useFixtureRuns: () -> Void
    ) async throws {
        let store = CantripHomeStore.shared
        func fixture(forRun id: UUID) -> CantripHomeBackendFixture? {
            pool.fixture(for: store.runner.session(forRun: id)?.id)
        }
        homeChat.messages.append(ChatMessage(role: .assistant, text: """
        Your tracker will run twice a day.
        ```cantrip-task
        {"id":null,"title":"Interview tracker","prompt":"Refresh the interview records.","schedule":{"kind":"weekdays","summary":"Twice daily","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":[1,2,3,4,5,6,7],"times":[{"hour":22,"minute":0},{"hour":8,"minute":30}]}}
        ```
        """))
        homeChat.processCantripHomeBlocks()
        let twice = try requireHome(store.tasks.first { $0.title == "Interview tracker" })
        precondition(twice.schedule.runTimes.map(\.hour) == [8, 22]
                     && twice.schedule.hour == 8 && twice.schedule.minute == 30
                     && homeChat.messages.last?.text.hasSuffix(
                        "Task created: **Interview tracker** · Every day at 8:30 AM and 10:00 PM"
                     ) == true,
                     "Home creates one task with several run times and a natural summary")
        let taskCountBeforeEdit = store.tasks.count
        homeChat.messages.append(ChatMessage(role: .assistant, text: """
        Weekdays only now.
        ```cantrip-task
        {"id":"\(twice.id.uuidString)","schedule":{"kind":"weekdays","summary":"","timeZone":"America/Los_Angeles","weekdays":[2,3,4,5,6],"times":["07:00","19:00"]}}
        ```
        """))
        homeChat.processCantripHomeBlocks()
        let retimed = try requireHome(store.tasks.first { $0.id == twice.id })
        precondition(store.tasks.count == taskCountBeforeEdit
                     && retimed.prompt == "Refresh the interview records."
                     && retimed.title == "Interview tracker"
                     && retimed.schedule.summary == "Weekdays at 7:00 AM and 7:00 PM"
                     && homeChat.messages.last?.text.contains("Task updated") == true,
                     "Editing by id may send only the schedule and keeps the saved prompt")
        let protocolText = homeChat.cantripHomeInstructions
        precondition(protocolText.contains(#""times":[{"hour":0-23,"minute":0-59}]"#)
                     && protocolText.contains("never create a second task for another time")
                     && protocolText.contains(
                        "Weekdays at 7:00 AM and 7:00 PM (times 07:00,19:00; weekdays 2,3,4,5,6; America/Los_Angeles)"
                     ),
                     "Home's protocol documents run times and lists each task's exact times")

        func writeScheduleEdit(_ name: String, _ body: String) throws -> URL {
            let url = CantripHomeStore.scheduleEditDirectory.appendingPathComponent(name)
            try Data(body.utf8).write(to: url, options: .atomic)
            return url
        }
        func dailyEdit(_ taskID: UUID, _ times: String) -> String {
            #"{"version":1,"taskID":"\#(taskID.uuidString)","schedule":{"kind":"weekdays","summary":"","timeZone":"America/Los_Angeles","weekdays":[1,2,3,4,5,6,7],"times":\#(times)}}"#
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: CantripHomeStore.scheduleEditDirectory.path
        )
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                     "The schedule edit inbox is private to the user")
        // Sunday, October 4 2026 at noon, Los Angeles.
        let base = Date(timeIntervalSince1970: 1_791_140_400)
        store.clock = { base }
        defer { store.clock = { Date() } }
        let editURL = try writeScheduleEdit("1-interview.json", dailyEdit(twice.id, #"["08:30","22:00"]"#))
        let unknownURL = try writeScheduleEdit("2-unknown.json", dailyEdit(UUID(), #"["08:30"]"#))
        let brokenURL = try writeScheduleEdit("3-broken.json", #"{"version":1}"#)
        store.checkNow()
        let migrated = try requireHome(store.tasks.first { $0.id == twice.id })
        precondition(!FileManager.default.fileExists(atPath: editURL.path)
                     && migrated.schedule.summary == "Every day at 8:30 AM and 10:00 PM"
                     && migrated.prompt == retimed.prompt && migrated.enabled
                     && migrated.nextRunAt == base.addingTimeInterval(10 * 3_600),
                     "A queued schedule edit replaces only the schedule")
        precondition(FileManager.default.fileExists(atPath: unknownURL.path + ".rejected")
                     && FileManager.default.fileExists(atPath: brokenURL.path + ".rejected")
                     && !FileManager.default.fileExists(atPath: unknownURL.path),
                     "Edits for missing tasks or malformed files are set aside")

        // The Mac slept through six slots; Wednesday 1 PM it runs once, then waits for 9 PM.
        let woke = base.addingTimeInterval(3 * 86_400 + 3_600)
        store.clock = { woke }
        store.checkNow()
        let catchUpRun = try requireHome(store.backgroundRuns.first {
            $0.taskID == twice.id && $0.status == "running"
        }?.id)
        try await waitForJournalTest { fixture(forRun: catchUpRun)?.sink != nil }
        let catchUpPrompt = fixture(forRun: catchUpRun)?.lastPrompt
        precondition(store.tasks.first { $0.id == twice.id }?.state == .running
                     && catchUpPrompt?.contains("Refresh the interview records.") == true
                     && catchUpPrompt?.contains("runs a missed schedule once") == true,
                     "An overdue multi-time task starts one catch-up run")
        let queuedEditURL = try writeScheduleEdit("4-later.json", dailyEdit(twice.id, #"["08:30","21:00"]"#))
        store.checkNow()
        precondition(store.runner.jobs.filter { $0.taskID == twice.id }.count == 1
                     && FileManager.default.fileExists(atPath: queuedEditURL.path),
                     "A running task is never started again, and its schedule edit waits")
        let sink = fixture(forRun: catchUpRun)?.sink
        sink?(.textDelta("Caught up."))
        sink?(.done)
        try await waitForJournalTest {
            store.tasks.first(where: { $0.id == twice.id })?.runs.first?.status == "succeeded"
        }
        let caughtUp = try requireHome(store.tasks.first { $0.id == twice.id })
        precondition(caughtUp.runs.count == 1
                     && !FileManager.default.fileExists(atPath: queuedEditURL.path)
                     && caughtUp.schedule.runTimes.map(\.hour) == [8, 21]
                     && caughtUp.nextRunAt == woke.addingTimeInterval(8 * 3_600),
                     "Missed slots collapse into one run; the next run is the next future slot")
        try await waitForJournalTest { store.runner.liveRunIDs.isEmpty }
        store.checkNow()
        precondition(store.runner.jobs.isEmpty,
                     "No second catch-up run for the other missed slots")
        try store.delete(id: twice.id)
    }

    /// Concurrent jobs share one Apple Mail refresh.
    static func testMailRefreshCoalesces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-mail-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index")
        let checks = root.appendingPathComponent("checks")
        FileManager.default.createFile(atPath: index.path, contents: Data())
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/mail-refresh")
        var processes: [(Process, Pipe)] = []
        for _ in 0..<3 {
            let process = Process()
            let output = Pipe()
            process.executableURL = script
            process.arguments = ["--settle-timeout", "3"]
            var environment = ProcessInfo.processInfo.environment
            environment["CANTRIP_MAIL_REFRESH_DIR"] = root.appendingPathComponent("state").path
            environment["CANTRIP_MAIL_INDEX"] = index.path
            environment["CANTRIP_MAIL_CHECK_COMMAND"] = "echo check >> '\(checks.path)'; sleep 1"
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            processes.append((process, output))
        }
        var outputs: [String] = []
        for (process, output) in processes {
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "mail-refresh failed")
            outputs.append(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let checkCount = (try String(contentsOf: checks, encoding: .utf8))
            .split(separator: "\n").count
        precondition(checkCount == 1
                     && outputs.filter { $0.contains("using that refresh") }.count == 2,
                     "Three concurrent jobs must trigger exactly one Mail refresh: \(outputs)")
    }
}
