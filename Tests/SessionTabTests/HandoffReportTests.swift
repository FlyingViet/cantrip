import Foundation

extension SessionTabTests {
    /// `cantrip handoffs`: where Home's handoffs went, as metadata only, with private tabs, prompts,
    /// replies, outcomes and questions never included, and a log that outlives Home's trimming.
    @MainActor
    static func testHandoffReport() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.childTabsAutoFork = false
        defer { (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork) = saved }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-handoff-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The CLI's options, and the help line Opsboard checks before it calls the command.
        let parsed = try CantripCLI.parseHandoffs(["--json", "--days", "3"])
        precondition(parsed.days == 3 && parsed.json)
        let plain = try CantripCLI.parseHandoffs([])
        precondition(plain.days == HandoffReport.defaultDays && !plain.json)
        for bad in [["--days", "0"], ["--days", "31"], ["--days"], ["--prompt"], ["list"]] {
            do {
                _ = try CantripCLI.parseHandoffs(bad)
                preconditionFailure("accepted \(bad)")
            } catch is CantripCLI.Failure {}
        }
        precondition(CantripCLI.usage.contains("cantrip handoffs [--days N] [--json]")
                     && CantripCLI.commands.contains("handoffs"), "listed in `cantrip help`")

        let manager = SessionManager()
        func addTab(_ name: String) throws -> (ChatSession, CantripHomeBackendFixture) {
            let backend = CantripHomeBackendFixture()
            let session = ChatSession(copilotBackend: backend)
            session.workdir = scratch.path
            try session.updateTab(name: name)
            manager.sessions.append(session)
            return (session, backend)
        }
        let (planner, plannerBackend) = try addTab("Planner")
        let (docs, _) = try addTab("Docs")
        let (secret, _) = try addTab("Secret plans")
        secret.isPrivate = true
        defer {
            plannerBackend.sink?(.done)
            for session in manager.sessions { session.cancel() }
        }

        // Planner is busy, and the handoff waits second in its queue.
        let queuedPrompt = "(Handed off by Cantrip Home.)\n\nPROMPT-queued: rename the export button."
        planner.submitRemote("Current work", mode: .queue)
        try await waitForJournalTest { plannerBackend.lastPrompt != nil && planner.isStreaming }
        planner.submitRemote("Earlier request", mode: .queue)
        planner.submitRemote(queuedPrompt, mode: .queue)
        try await waitForJournalTest { planner.queued.count == 2 }

        let now = Date()
        let store = ChildTabStore(url: scratch.appendingPathComponent("child-tabs.json"))
        var transcripts: [URL] = []
        defer { for url in transcripts { try? FileManager.default.removeItem(at: url) } }
        // Archived child tabs keep their saved conversation, as closed tabs do.
        func child(_ title: String, of parent: ChatSession, prompt: String, state: ChildTab.State, auto: Bool?,
                   age: TimeInterval) throws -> ChildTab {
            var record = ChildTab(id: UUID(), parentID: parent.id, queueItemID: UUID(), title: title, prompt: prompt,
                                  parentTitle: parent.title, createdAt: now.addingTimeInterval(-age), updatedAt: now)
            record.state = state
            record.autoStarted = auto
            if !state.isRunning { record.finishedAt = now.addingTimeInterval(-age + 600) }
            store.upsert(record)
            let transcript = SessionManager.chatsDir.appendingPathComponent("\(record.id.uuidString).json")
            try Data("[]".utf8).write(to: transcript)
            transcripts.append(transcript)
            return record
        }
        let forkedPrompt = "PROMPT-forked: fix the parser."
        let forked = try child("Fix the parser", of: planner, prompt: forkedPrompt, state: .working, auto: true, age: 600)
        let autoForked = try child("Tidy docs", of: docs, prompt: "PROMPT-a", state: .merged, auto: true, age: 3_600)
        let manual = try child("Write tests", of: planner, prompt: "PROMPT-b", state: .noChanges, auto: false, age: 7_200)
        let older = try child("Old work", of: docs, prompt: "PROMPT-c", state: .merged, auto: nil, age: 2 * 86_400)
        let hiddenChild = try child("Secret child", of: secret, prompt: "PROMPT-d", state: .working, auto: false, age: 60)
        let stale = try child("Ancient work", of: docs, prompt: "PROMPT-e", state: .merged, auto: true, age: 10 * 86_400)
        // The running child is an open tab.
        let forkedTab = ChatSession(id: forked.id, copilotBackend: CantripHomeBackendFixture())
        try forkedTab.updateTab(name: forked.title)
        manager.sessions.append(forkedTab)

        func handoff(_ tabID: UUID, _ title: String, _ summary: String, prompt: String,
                     status: CantripHomeDelegation.Status, age: TimeInterval) -> CantripHomeDelegation {
            var delegation = CantripHomeDelegation(tabID: tabID, tabTitle: title, summary: summary, prompt: prompt,
                                                   createdAt: now.addingTimeInterval(-age), status: status)
            if status != .queued && status != .running { delegation.finishedAt = now.addingTimeInterval(-age + 300) }
            return delegation
        }
        let queued = handoff(planner.id, "Planner", "Rename the export button", prompt: queuedPrompt, status: .queued, age: 120)
        var inChild = handoff(forked.id, forked.title, "Fix the parser", prompt: forkedPrompt, status: .running, age: 900)
        inChild.parentTabID = planner.id
        inChild.parentTabTitle = "Planner"
        inChild.needsInput = true
        inChild.question = "QUESTION-TEXT: which parser?"
        let toSecret = handoff(secret.id, "Secret plans", "Secret handoff", prompt: "PROMPT-secret", status: .running, age: 300)
        var done = handoff(docs.id, "Docs", "Update the README", prompt: "PROMPT-done", status: .completed, age: 86_400)
        done.result = "REPLY-TEXT"
        done.outcome = "OUTCOME-TEXT"
        done.doneWhenState = .met
        done.doneWhenNote = "NOTE-TEXT"
        var message = ChatMessage(role: .assistant, text: "Handing these off.")
        message.delegations = [queued, inChild, toSecret, done]
        manager.homeSession.messages = [message]

        var failed = handoff(docs.id, "Docs", "Fix the export crash", prompt: "PROMPT-incident", status: .failed, age: 7_200)
        failed.error = "ERROR-TEXT"
        let incidentID = UUID()
        let incidentRun = CantripHomeBackgroundRun(
            id: UUID(), kind: .incident, label: "Export crash", taskID: nil, startedAt: failed.createdAt,
            status: "failed", summary: "RUN-SUMMARY", incidentID: incidentID, route: .tab, handoffs: [failed])
        let fromTask = handoff(planner.id, "Planner", "Refresh the tracker", prompt: "PROMPT-task", status: .completed, age: 10_800)
        let taskID = UUID()
        let taskRun = CantripHomeBackgroundRun(
            id: UUID(), kind: .task, label: "Daily tracker", taskID: taskID, startedAt: fromTask.createdAt,
            status: "succeeded", summary: "RUN-SUMMARY", handoffs: [fromTask])

        // Handoffs Home no longer follows: one still running when it was dropped, one from last week,
        // one to a closed tab that kept its conversation, one to a tab closed without one.
        let closedID = UUID()
        let closedTranscript = SessionManager.chatsDir.appendingPathComponent("\(closedID.uuidString).json")
        try Data("[]".utf8).write(to: closedTranscript)
        defer { try? FileManager.default.removeItem(at: closedTranscript) }
        let lost = handoff(docs.id, "Docs", "Lost track of this", prompt: "PROMPT-lost", status: .running, age: 14_400)
        let lastWeek = handoff(docs.id, "Docs", "Last week's work", prompt: "PROMPT-old", status: .completed, age: 8 * 86_400)
        let closed = handoff(closedID, "Closed project", "Ship the closed project", prompt: "PROMPT-closed",
                             status: .completed, age: 18_000)
        let gone = handoff(UUID(), "Gone tab", "Gone tab's work", prompt: "PROMPT-gone", status: .completed, age: 21_600)
        let log = HandoffLog(url: scratch.appendingPathComponent("handoff-log.json"))
        log.record([lost, lastWeek, closed, gone].map { HandoffRecord($0, source: .homeChat, child: nil) },
                   hidden: { _ in false }, now: now)

        func report(days: Int) throws -> (report: [String: Any], json: String) {
            let report = HandoffReport.snapshot(manager: manager, days: days, now: now, runs: [incidentRun, taskRun],
                                                childStore: store, log: log)
            let data = try JSONSerialization.data(withJSONObject: report)
            return (report, String(decoding: data, as: UTF8.self))
        }
        let (week, json) = try report(days: 7)
        for leaked in ["PROMPT-", "REPLY-TEXT", "OUTCOME-TEXT", "QUESTION-TEXT", "NOTE-TEXT", "ERROR-TEXT", "RUN-SUMMARY",
                       "Secret", secret.id.uuidString, hiddenChild.id.uuidString, ChatSession.cantripHomeID.uuidString,
                       ChatSession.privateLocalID.uuidString] {
            precondition(!json.contains(leaked), "the report includes \(leaked): \(json)")
        }
        precondition(week["version"] as? Int == 1 && week["days"] as? Int == 7 && week["build"] is String
                     && (week["generatedAt"] as? String).flatMap { ISODate.date(from: $0) } != nil, "\(week)")

        let handoffs = try requireHandoffReport(week["handoffs"] as? [[String: Any]])
        let byID = Dictionary(handoffs.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        precondition(handoffs.map { $0["id"] as? String ?? "" }
                     == [queued, inChild, failed, fromTask, lost, closed, done].map(\.id.uuidString),
                     "newest first; last week's, the private tab's and the unsaved closed tab's are left out: \(handoffs)")

        let waiting = try requireHandoffReport(byID[queued.id.uuidString])
        precondition(waiting["status"] as? String == "queued" && waiting["queuePosition"] as? Int == 2
                     && waiting["needsInput"] as? Bool == false && waiting["child"] is NSNull
                     && waiting["doneWhen"] is NSNull && waiting["finishedAt"] is NSNull
                     && waiting["summary"] as? String == "Rename the export button", "\(waiting)")
        let target = try requireHandoffReport(waiting["target"] as? [String: Any])
        let current = try requireHandoffReport(waiting["current"] as? [String: Any])
        precondition(target["id"] as? String == planner.id.uuidString && target["title"] as? String == "Planner"
                     && current["id"] as? String == planner.id.uuidString, "\(waiting)")
        let homeSource = try requireHandoffReport(waiting["source"] as? [String: Any])
        precondition(homeSource["kind"] as? String == "home" && homeSource["title"] is NSNull
                     && homeSource["runID"] is NSNull && homeSource["taskID"] is NSNull, "\(homeSource)")

        let moved = try requireHandoffReport(byID[inChild.id.uuidString])
        let movedChild = try requireHandoffReport(moved["child"] as? [String: Any])
        precondition(moved["status"] as? String == "running" && moved["needsInput"] as? Bool == true
                     && moved["queuePosition"] is NSNull
                     && (moved["target"] as? [String: Any])?["id"] as? String == planner.id.uuidString
                     && movedChild["id"] as? String == forked.id.uuidString && movedChild["title"] as? String == "Fix the parser"
                     && movedChild["state"] as? String == "working" && movedChild["statusLine"] as? String == "Working"
                     && (moved["current"] as? [String: Any])?["id"] as? String == forked.id.uuidString,
                     "a handoff that moved into a child tab: target, child and current: \(moved)")

        let incident = try requireHandoffReport(byID[failed.id.uuidString]?["source"] as? [String: Any])
        precondition(incident["kind"] as? String == "incident" && incident["title"] as? String == "Export crash"
                     && incident["runID"] as? String == incidentRun.id.uuidString
                     && incident["incidentID"] as? String == incidentID.uuidString
                     && byID[failed.id.uuidString]?["status"] as? String == "failed", "\(incident)")
        let task = try requireHandoffReport(byID[fromTask.id.uuidString]?["source"] as? [String: Any])
        precondition(task["kind"] as? String == "background" && task["title"] as? String == "Daily tracker"
                     && task["taskID"] as? String == taskID.uuidString && task["incidentID"] is NSNull, "\(task)")
        precondition(byID[lost.id.uuidString]?["status"] as? String == "unknown",
                     "still running when Home stopped following it: how it ended isn't known")
        precondition((byID[closed.id.uuidString]?["target"] as? [String: Any])?["title"] as? String == "Closed project",
                     "a closed tab keeps its saved title")
        let finished = try requireHandoffReport(byID[done.id.uuidString])
        precondition(finished["doneWhen"] as? String == "met" && finished["finishedAt"] is String
                     && finished["status"] as? String == "completed", "\(finished)")

        let tabs = try requireHandoffReport(week["tabs"] as? [[String: Any]])
        let plannerTab = tabs.first { $0["id"] as? String == planner.id.uuidString }
        precondition(plannerTab?["state"] as? String == "busy" && plannerTab?["queued"] as? Int == 2
                     && tabs.contains { $0["id"] as? String == docs.id.uuidString && $0["state"] as? String == "idle" }
                     && !tabs.contains { $0["id"] as? String == secret.id.uuidString }
                     && !tabs.contains { ($0["id"] as? String).flatMap(UUID.init(uuidString:)).map(TabInsight.isReservedID) ?? true },
                     "open readable tabs only: \(tabs)")

        let children = try requireHandoffReport(week["childTabs"] as? [[String: Any]])
        func origin(_ record: ChildTab) -> String? {
            children.first { $0["id"] as? String == record.id.uuidString }?["origin"] as? String
        }
        precondition(children.map { $0["id"] as? String ?? "" }
                     == [forked, autoForked, manual, older].map(\.id.uuidString),
                     "newest first; the private parent's child and last week's are left out: \(children)")
        precondition(origin(forked) == "handoff" && origin(autoForked) == "autoFork" && origin(manual) == "runInChildTab"
                     && origin(older) == "unknown", "\(children)")
        let forkedItem = try requireHandoffReport(children.first)
        precondition(forkedItem["handoffID"] as? String == inChild.id.uuidString
                     && forkedItem["parentID"] as? String == planner.id.uuidString
                     && forkedItem["parentTitle"] as? String == "Planner" && forkedItem["open"] as? Bool == true
                     && forkedItem["statusLine"] as? String == "Working" && forkedItem["finishedAt"] is NSNull,
                     "\(forkedItem)")
        precondition(children[1]["handoffID"] is NSNull && children[1]["finishedAt"] is String
                     && children[1]["open"] as? Bool == false)

        let (month, _) = try report(days: 30)
        let monthIDs = Set((month["handoffs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let monthChildren = Set((month["childTabs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        precondition(monthIDs.contains(lastWeek.id.uuidString) && monthChildren.contains(stale.id.uuidString),
                     "--days 30 reaches further back")
        let clampedLow = try report(days: 0).report["days"] as? Int
        let clampedHigh = try report(days: 99).report["days"] as? Int
        precondition(clampedLow == 1 && clampedHigh == 30, "days stay within 1 to 30")

        let text = HandoffReport.text(week)
        precondition(text.contains("Home chat → “Planner”") && text.contains("#2 in the queue")
                     && text.contains("Incident “Export crash” → “Docs”") && text.contains("needs your answer")
                     && text.contains("child “Fix the parser” (Working)") && text.contains("Done when met")
                     && !text.contains("PROMPT-"), text)

        // The log follows what Home tracks now: metadata only, private tabs left out, saved and reloaded.
        let synced = HandoffLog(url: scratch.appendingPathComponent("synced-log.json"))
        HandoffReport.sync(manager: manager, runs: [incidentRun, taskRun], childStore: store, log: synced, now: now)
        precondition(Set(synced.records.keys) == Set([queued, inChild, done, failed, fromTask].map(\.id)),
                     "the private tab's handoff isn't kept: \(synced.records.keys)")
        precondition(synced.records[inChild.id]?.startedChild == true && synced.records[inChild.id]?.childState == .working
                     && synced.records[inChild.id]?.targetID == planner.id, "\(String(describing: synced.records[inChild.id]))")
        let savedLog = try String(contentsOf: synced.url, encoding: .utf8)
        for leaked in ["PROMPT-", "REPLY-TEXT", "OUTCOME-TEXT", "QUESTION-TEXT", "NOTE-TEXT", "ERROR-TEXT", "Secret"] {
            precondition(!savedLog.contains(leaked), "the log keeps \(leaked)")
        }
        precondition(HandoffLog(url: synced.url).records == synced.records, "the log reloads")
        func modified() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: synced.url.path)[.modificationDate] as? Date
        }
        let written = try modified()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        HandoffReport.sync(manager: manager, runs: [incidentRun, taskRun], childStore: store, log: synced, now: now)
        let rewritten = try modified()
        precondition(rewritten == written, "nothing changed: the log isn't rewritten")
        docs.isPrivate = true
        HandoffReport.sync(manager: manager, runs: [incidentRun, taskRun], childStore: store, log: synced, now: now)
        precondition(synced.records[done.id] == nil && synced.records[failed.id] == nil && synced.records[queued.id] != nil,
                     "a tab made private drops its handoffs from the log")
        let afterPrivate = try report(days: 7)
        precondition(!afterPrivate.json.contains(docs.id.uuidString) && !afterPrivate.json.contains("Tidy docs"),
                     "nor are they or its child tabs shown")
        docs.isPrivate = false

        // Through the host, as `cantrip handoffs` asks for it.
        let reply = HostControl(manager: manager).handle(["command": "handoffs", "days": 3])
        precondition(reply["error"] == nil && reply["version"] as? Int == 1 && reply["days"] as? Int == 3
                     && reply["handoffs"] is [[String: Any]] && reply["tabs"] is [[String: Any]], "\(reply)")
        print("handoff report: ok")
    }

    private static func requireHandoffReport<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
