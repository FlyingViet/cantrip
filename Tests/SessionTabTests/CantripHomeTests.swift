import Foundation
import ImageIO

extension SessionTabTests {
    @MainActor
    static func testCantripHome() async throws {
        let zone = "America/Los_Angeles"
        let interval = try CantripHomeSchedule(
            kind: .interval, summary: "Every 30 minutes", timeZone: zone,
            startAt: Date(timeIntervalSince1970: 1_000),
            intervalMinutes: 30
        ).validated(now: Date(timeIntervalSince1970: 900))
        precondition(interval.next(after: Date(timeIntervalSince1970: 1_001))
                     == Date(timeIntervalSince1970: 2_800))

        let weekdays = try CantripHomeSchedule(
            kind: .weekdays, summary: "Weekdays at 9 AM", timeZone: zone,
            weekdays: [2, 3, 4, 5, 6], hour: 9, minute: 0
        ).validated(now: Date(timeIntervalSince1970: 1_700_000_000))
        let next = try requireHome(weekdays.next(after: Date(timeIntervalSince1970: 1_700_000_000)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try requireHome(TimeZone(identifier: zone))
        precondition([2, 3, 4, 5, 6].contains(calendar.component(.weekday, from: next)))
        precondition(calendar.component(.hour, from: next) == 9)

        let manager = SessionManager()
        precondition(!manager.sessions.contains { $0.id == ChatSession.cantripHomeID })
        precondition(manager.managedSession(id: ChatSession.cantripHomeID) === manager.homeSession)
        precondition(manager.homeSession.title == "Cantrip Home")
        precondition(manager.homeSession.isLocked)
        let background = manager.homeBackgroundSession
        precondition(manager.managedSession(id: ChatSession.cantripHomeBackgroundID) === background
                     && !manager.sessions.contains { $0.id == ChatSession.cantripHomeBackgroundID }
                     && background.isLocked && background.title == "Cantrip Home background",
                     "Home's background conversation must be reachable by ID but never a tab")
        background.messages = [ChatMessage(role: .user, text: "Background log")]
        background.persistTranscript()
        precondition(!manager.archivedSessions().contains { $0.id == background.id },
                     "Home's background log must stay out of archived history")
        background.messages = []
        background.persistTranscript()
        let routeBackend = CantripHomeBackendFixture()
        let bassSession = ChatSession(copilotBackend: routeBackend)
        try bassSession.updateTab(name: "Bass Compass")
        bassSession.workdir = "/tmp/Bass-Compass"
        manager.sessions = [bassSession]
        defer { bassSession.cancel() }

        let store = CantripHomeStore.shared
        let marker = """
        I can check this every weekday.

        ```cantrip-task
        {"title":"Apartment tracker","prompt":"Check the saved apartment searches and report meaningful price changes.","schedule":{"kind":"weekdays","summary":"Weekdays at 9 AM","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":[2,3,4,5,6],"hour":9,"minute":0}}
        ```
        """
        manager.homeSession.messages = [ChatMessage(role: .assistant, text: marker)]
        manager.homeSession.processCantripHomeBlocks()
        let task = try requireHome(store.tasks.first { $0.title == "Apartment tracker" })
        precondition(manager.homeSession.messages[0].text.contains("Task created: **Apartment tracker**"))
        precondition(!manager.homeSession.messages[0].text.contains("cantrip-task"))
        precondition(task.schedule.weekdays == [2, 3, 4, 5, 6])
        let taskCount = store.tasks.count
        manager.homeSession.messages.append(ChatMessage(role: .assistant, text: """
        I changed the existing tracker.
        ```cantrip-task
        {"id":"\(task.id.uuidString)","title":"Apartment tracker","prompt":"Check the saved apartment searches and report meaningful price changes.","schedule":{"kind":"interval","summary":"Every 6 hours","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":360,"weekdays":null,"hour":null,"minute":null}}
        ```
        """))
        manager.homeSession.processCantripHomeBlocks()
        let updatedTask = try requireHome(store.tasks.first { $0.id == task.id })
        precondition(store.tasks.count == taskCount && updatedTask.schedule.intervalMinutes == 360,
                     "Conversational schedule edits must update the existing task")

        manager.homeSession.messages.append(ChatMessage(role: .assistant, text: """
        I created a flexible application tracker.
        ```cantrip-task
        {"id":null,"title":"Job applications","prompt":"Keep the user's job application lifecycle accurate.","schedule":null,"workspace":{"recordLabel":"Application","recordLabelPlural":"Applications","icon":"briefcase.fill","fields":[{"key":"company","label":"Company","kind":"text","required":true,"options":null},{"key":"appliedAt","label":"Applied","kind":"date","required":true,"options":null},{"key":"status","label":"Status","kind":"choice","required":true,"options":["Applied","Interview","Offer","Closed"]},{"key":"round","label":"Interview round","kind":"number","required":false,"options":null},{"key":"interviewAt","label":"Interview","kind":"dateTime","required":false,"options":null}],"list":{"titleField":"company","subtitleFields":["round"],"badgeField":"status","dateField":"appliedAt"},"detailSections":[{"title":"Lifecycle","fields":["appliedAt","status","round","interviewAt"]}]},"initialRecords":[{"company":"Example Co","appliedAt":"2026-09-29","status":"Applied"}]}
        ```
        """))
        manager.homeSession.processCantripHomeBlocks()
        let tracker = try requireHome(store.tasks.first { $0.title == "Job applications" })
        let application = try requireHome(tracker.workspace?.records.first)
        precondition(!tracker.isScheduled && tracker.state == .ready
                     && tracker.workspace?.fields.count == 5)
        precondition(manager.homeSession.messages.last?.text.contains("Workspace ready") == true)

        manager.homeSession.messages.append(ChatMessage(role: .assistant, text: """
        I moved Example Co into interviews.
        ```cantrip-task-records
        {"taskID":"\(tracker.id.uuidString)","changes":[{"operation":"upsert","id":"\(application.id.uuidString)","values":{"status":"Interview","round":"2","interviewAt":"2026-10-03T17:00:00Z"}}]}
        ```
        """))
        manager.homeSession.processCantripHomeBlocks()
        let trackedApplication = try requireHome(
            store.tasks.first(where: { $0.id == tracker.id })?.workspace?.records.first
        )
        precondition(trackedApplication.values["status"] == "Interview"
                     && trackedApplication.values["round"] == "2")
        precondition(manager.homeSession.messages.last?.text.contains("1 record change") == true)
        try testCantripHomeListGroups(store: store, manager: manager, tracker: tracker)

        let artifactURL = CantripHomeStore.artifactDirectory.appendingPathComponent("home-test.png")
        let imageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        try imageData.write(to: artifactURL)
        defer { try? FileManager.default.removeItem(at: artifactURL) }
        let artifact = try store.register(.init(
            title: "Apartment summary", path: artifactURL.lastPathComponent, kind: "image"
        ))
        let read = try store.artifactData(id: artifact.id)
        precondition(read.1 == imageData, "Relative Home artifact paths must resolve under the guarded root")
        let recoveredURL = CantripHomeStore.artifactDirectory
            .appendingPathComponent("recovered-home-test.txt")
        try "Recovered artifact".write(to: recoveredURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: recoveredURL) }
        let failedArtifactMessage = ChatMessage(
            role: .assistant,
            text: """
            [Recovered artifact](\(recoveredURL.path))

            Could not save artifact: Artifacts must be saved in \(CantripHomeStore.artifactDirectory.path).
            """
        )
        manager.homeSession.messages.append(failedArtifactMessage)
        try store.recoverUnregisteredArtifacts()
        store.attach(manager: manager)
        let recovered = try requireHome(
            store.artifacts.first { $0.relativePath == recoveredURL.lastPathComponent }
        )
        let recoveredData = try store.artifactData(id: recovered.id).1
        precondition(String(decoding: recoveredData, as: UTF8.self) == "Recovered artifact")
        let repairedMessage = try requireHome(
            manager.homeSession.messages.first { $0.id == failedArtifactMessage.id }
        )
        precondition(repairedMessage.text.contains("Saved to Artifacts: **Recovered Home Test**")
                     && !repairedMessage.text.contains("Could not save artifact"))
        do {
            _ = try store.register(.init(
                title: "Escape", path: "/tmp/not-home.txt", kind: "document"
            ))
            preconditionFailure("Artifacts outside the Home directory must be rejected")
        } catch is CantripHomeError {}

        let previousEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = true
        defer { AppSettings.shared.cantripHomeEnabled = previousEnabled }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }

        func call(_ path: String, method: String = "GET", body: Data? = nil,
                  serverPort: Int? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(
                url: URL(string: "http://127.0.0.1:\(serverPort ?? port)\(path)")!
            )
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try JSONSerialization.jsonObject(with: data)) as! [String: Any])
        }

        let listed = try await call("/api/v1/sessions")
        let listedIDs = (listed.1["sessions"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        precondition(!listedIDs.contains(ChatSession.cantripHomeID.uuidString)
                     && !listedIDs.contains(ChatSession.cantripHomeBackgroundID.uuidString))
        let backgroundRoute = try await call(
            "/api/v1/sessions/\(ChatSession.cantripHomeBackgroundID.uuidString)"
        )
        let backgroundSnapshot = try requireHome(backgroundRoute.1["session"] as? [String: Any])
        precondition(backgroundRoute.0 == 200
                     && backgroundSnapshot["isCantripHomeBackground"] as? Bool == true
                     && backgroundSnapshot["isCantripHome"] as? Bool == false
                     && backgroundSnapshot["supportsTabMetadata"] as? Bool == false
                     && backgroundSnapshot["supportsModelSettings"] as? Bool == false,
                     "Notification taps must be able to open the background report")
        let backgroundModel = try await call(
            "/api/v1/sessions/\(ChatSession.cantripHomeBackgroundID.uuidString)/model-settings"
        )
        precondition(backgroundModel.0 == 409, "Background runs follow Home's model")
        let home = try await call("/api/v1/home")
        let homeSession = try requireHome(home.1["session"] as? [String: Any])
        precondition(home.0 == 200 && homeSession["id"] as? String == ChatSession.cantripHomeID.uuidString
                     && homeSession["isCantripHome"] as? Bool == true)
        let delegations = CantripHomeDelegations.shared
        let homeInstructions = manager.homeSession.cantripHomeInstructions
        precondition(homeInstructions.contains(bassSession.id.uuidString)
                     && homeInstructions.contains(
                        "\"Bass Compass\" (idle); folder /tmp/Bass-Compass; projects Bass-Compass"
                     )
                     && homeInstructions.contains("cantrip-delegate"),
                     "Home must see open project tabs and the handoff protocol")
        let contextTab = UUID()
        let contextSummary = CantripHomeDelegations.tabSummary(
            id: contextTab, title: "Cantrip", workdir: NSHomeDirectory(), state: "busy",
            projects: CantripHomeDelegations.projects(in: [
                "Edited ~/Coding/Hermes/Sources/ChatView.swift",
                "Pushed FlyingViet/CantripIOS and rebuilt /Users/me/Coding/Hermes",
                "Mentioned ~/Coding/Alter once",
            ], workdir: NSHomeDirectory()),
            messages: [
                ChatMessage(role: .user, text: "Add an animated mascot to Cantrip Home\nwith outfits"),
                ChatMessage(role: .user, text: "! make test"),
                ChatMessage(role: .user, text: "Deploy to TestFlight (Recommended)"),
                ChatMessage(role: .user, text: "Cantrip remote on cantrip agent should keep its header"),
                ChatMessage(role: .user, text: "Ok"),
            ]
        )
        precondition(contextSummary == "- \(contextTab.uuidString): \"Cantrip\" (busy); "
                     + "projects Hermes; started \"Add an animated mascot to Cantrip Home\"; "
                     + "recent \"Cantrip remote on cantrip agent should keep its header\"",
                     "Tab context must show recurring projects and substantive requests only: \(contextSummary)")
        func homeReply(user: String, assistant: String) -> UUID {
            let reply = ChatMessage(role: .assistant, text: assistant)
            manager.homeSession.messages.append(ChatMessage(role: .user, text: user))
            manager.homeSession.messages.append(reply)
            manager.homeSession.processCantripHomeBlocks()
            return reply.id
        }
        func homeMessage(_ id: UUID) throws -> ChatMessage {
            try requireHome(manager.homeSession.messages.first { $0.id == id })
        }
        func delegateBlock(_ tabID: UUID, _ summary: String, _ prompt: String) -> String {
            """
            ```cantrip-delegate
            {"tabID":"\(tabID.uuidString)","summary":"\(summary)","prompt":"\(prompt)"}
            ```
            """
        }
        let referenceID = homeReply(
            user: "How many users does Bass Compass have?",
            assistant: "Bass Compass has 109 users."
        )
        let referenceMessage = try homeMessage(referenceID)
        precondition(referenceMessage.delegations.isEmpty
                     && !bassSession.isStreaming && bassSession.messages.isEmpty,
                     "Referencing a project must stay in Home")

        let handoffPrompt = "Fix the Bass Compass lineup sorting so headliners appear first."
        let handoffID = homeReply(
            user: "Can you fix the Bass Compass lineup sorting?",
            assistant: "The Bass Compass tab is taking this.\n\n"
                + delegateBlock(bassSession.id, "Fix lineup sorting", handoffPrompt)
        )
        let handoffMessage = try homeMessage(handoffID)
        let handoff = try requireHome(handoffMessage.delegations.first)
        precondition(handoffMessage.text == "The Bass Compass tab is taking this."
                     && handoffMessage.delegations.count == 1
                     && handoff.tabID == bassSession.id && handoff.tabTitle == "Bass Compass"
                     && handoff.summary == "Fix lineup sorting" && handoff.status == .running,
                     "A change request must become a running nested handoff without the raw block")
        try await waitForJournalTest { routeBackend.sink != nil }
        let tabPrompt = try requireHome(bassSession.messages.first { $0.role == .user }?.text)
        precondition(bassSession.isStreaming
                     && tabPrompt.hasPrefix("(Handed off by Cantrip Home.")
                     && tabPrompt.contains(handoffPrompt)
                     && tabPrompt.contains("> Can you fix the Bass Compass lineup sorting?")
                     && tabPrompt.hasSuffix("Cantrip Home reads it to report back."),
                     "The project tab must own a composed, standalone brief with the user's words: \(tabPrompt)")
        let liveHome = try await call("/api/v1/home")
        let liveMessages = try requireHome(
            (liveHome.1["session"] as? [String: Any])?["messages"] as? [[String: Any]]
        )
        let liveCard = try requireHome((liveMessages.first {
            $0["id"] as? String == handoffID.uuidString
        }?["delegations"] as? [[String: Any]])?.first)
        precondition(liveCard["tabID"] as? String == bassSession.id.uuidString
                     && liveCard["tabTitle"] as? String == "Bass Compass"
                     && liveCard["status"] as? String == "running"
                     && liveCard["summary"] as? String == "Fix lineup sorting"
                     && liveCard["latestStatus"] as? String != nil,
                     "The phone must receive the live handoff card")
        routeBackend.sink?(.inputRequired(BackendInputRequest(
            kind: .question, source: "Copilot", title: "Which branch?", detail: "", allowsFreeform: true
        ) { _ in }))
        try await waitForJournalTest { !bassSession.pendingInputs.isEmpty }
        delegations.refresh()
        let asking = try requireHome(homeMessage(handoffID).delegations.first)
        let askingHome = try await call("/api/v1/home")
        let askingCard = try requireHome(((askingHome.1["session"] as? [String: Any])?["messages"]
            as? [[String: Any]])?.first { $0["id"] as? String == handoffID.uuidString }?["delegations"]
            as? [[String: Any]])?.first
        precondition(asking.status == .running && asking.needsInput == true
                     && asking.latestStatus == "Needs your answer"
                     && askingCard?["needsInput"] as? Bool == true,
                     "A tab waiting on the user's answer marks its handoff card")
        func resultCard(_ id: UUID) -> CantripHomeHandoffResult? {
            let cards = manager.homeSession.messages.compactMap(\.handoffResult)
                .filter { $0.delegationID == id }
            precondition(cards.count <= 1, "One result card per handoff")
            return cards.first
        }
        let askingResult = try requireHome(resultCard(handoff.id))
        let askingRemote = try requireHome(((askingHome.1["session"] as? [String: Any])?["messages"]
            as? [[String: Any]])?.last { $0["role"] as? String == "handoff" }?["handoffResult"]
            as? [String: Any])
        precondition(askingResult.state == .needsInput && askingResult.detail == "Which branch?"
                     && askingResult.tabID == bassSession.id
                     && manager.homeSession.messages.last?.role == .handoff
                     && askingRemote["state"] as? String == "needsInput"
                     && askingRemote["tabID"] as? String == bassSession.id.uuidString,
                     "Home's chat shows that the tab needs the user's answer")
        let listing = try await call("/api/v1/sessions")
        let listedTabs = try requireHome(listing.1["sessions"] as? [[String: Any]])
        let listedHome = try requireHome(listing.1["home"] as? [String: Any])
        precondition(listedHome["id"] as? String == ChatSession.cantripHomeID.uuidString
                     && listedHome["isCantripHome"] as? Bool == true
                     && listedHome["supportsTabMetadata"] as? Bool == false
                     && !listedTabs.contains { $0["id"] as? String == ChatSession.cantripHomeID.uuidString },
                     "Web clients get Home as its own pinned entry, never as a tab")
        try bassSession.respondToInput(id: bassSession.pendingInputs[0].id, answer: .init(decision: .cancel))
        try await waitForJournalTest { bassSession.pendingInputs.isEmpty }
        delegations.refresh()
        let answered = try homeMessage(handoffID).delegations.first
        precondition(answered?.needsInput == nil && answered?.latestStatus != "Needs your answer"
                     && resultCard(handoff.id)?.state == .working,
                     "Answering clears the card's needs-answer state")
        let narration = String(repeating: "I'll check the lineup files next. ", count: 30)
        precondition(CantripHomeDelegations.outcome(
            narration + "\n\nHeadliners now sort first. Tests pass.", limit: 600
        ) == "…Headliners now sort first. Tests pass."
                     && CantripHomeDelegations.outcome("Short reply.", limit: 600) == "Short reply.",
                     "Home remembers a tab's outcome, not its progress narration")
        let firstRunSink = routeBackend.sink
        routeBackend.sink = nil
        let queuedPrompt = "Make the Bass Compass lineup collapsible."
        let queuedID = homeReply(
            user: "Also make the Bass Compass lineup collapsible.",
            assistant: delegateBlock(bassSession.id, "Collapsible lineup", queuedPrompt)
        )
        let queuedHandoff = try requireHome(homeMessage(queuedID).delegations.first)
        precondition(queuedHandoff.status == .queued
                     && bassSession.isStreaming
                     && bassSession.queued.count == 1 && bassSession.queued[0].text.contains(queuedPrompt)
                     && bassSession.messages.filter { $0.role == .user }.map(\.text) == [tabPrompt],
                     "A handoff to a busy tab must wait in its queue without interrupting it")
        firstRunSink?(.textDelta("Headliners now sort first."))
        firstRunSink?(.done)
        try await waitForJournalTest { routeBackend.sink != nil }
        delegations.refresh()
        let startedQueued = try homeMessage(queuedID).delegations.first
        precondition(startedQueued?.status == .running,
                     "The queued handoff must start once the tab is free")
        routeBackend.sink?(.textDelta("Past sets now collapse."))
        routeBackend.sink?(.done)
        try await waitForJournalTest { !bassSession.isStreaming }
        delegations.refresh()
        let finishedQueued = try homeMessage(queuedID).delegations.first
        precondition(finishedQueued?.status == .completed
                     && finishedQueued?.result == "Past sets now collapse.")
        let finished = try requireHome(homeMessage(handoffID).delegations.first)
        precondition(finished.status == .completed && finished.finishedAt != nil
                     && finished.result == "Headliners now sort first."
                     && finished.latestStatus == nil,
                     "The card must finish with the tab's reply")
        precondition(resultCard(handoff.id)?.state == .completed
                     && resultCard(handoff.id)?.detail == "Headliners now sort first."
                     && finishedQueued.map { resultCard($0.id)?.detail } == "Past sets now collapse.",
                     "Each finished handoff posts its outcome into Home's chat")
        let savedHome = try JSONDecoder().decode(
            [ChatMessage].self,
            from: Data(contentsOf: SessionManager.chatsDir
                .appendingPathComponent("\(ChatSession.cantripHomeID.uuidString).json"))
        )
        precondition(savedHome.first { $0.id == handoffID }?.delegations.first?.status == .completed,
                     "Finished handoffs must persist with the Home transcript")
        precondition(manager.homeSession.cantripHomeInstructions
            .contains("Bass Compass · Fix lineup sorting · completed: Headliners now sort first."),
                     "Home must know how its recent handoffs ended")

        routeBackend.sink = nil
        let stoppedID = homeReply(
            user: "Also add stage filters to the Bass Compass lineup.",
            assistant: delegateBlock(bassSession.id, "Stage filters",
                                     "Add stage filters to the Bass Compass lineup.")
        )
        let stoppedMessage = try homeMessage(stoppedID)
        precondition(stoppedMessage.text.isEmpty && stoppedMessage.delegations.count == 1,
                     "A reply may consist only of its handoff card")
        try await waitForJournalTest { routeBackend.sink != nil }
        bassSession.cancel()
        try await waitForJournalTest { !bassSession.isStreaming }
        delegations.refresh()
        let stopped = try requireHome(homeMessage(stoppedID).delegations.first)
        precondition(stopped.status == .cancelled && stopped.error == "Stopped in the tab.",
                     "Stopping the tab must stop the nested card")
        precondition(resultCard(stopped.id)?.state == .cancelled
                     && resultCard(stopped.id)?.detail == ""
                     && manager.homeSession.messages.filter { $0.role == .handoff }.count == 3,
                     "A stopped handoff shows its state in Home's chat")

        routeBackend.sink = nil
        let automatedID = homeReply(
            user: "Scheduled task · Nightly check\n\nCheck Bass Compass.",
            assistant: "Handing off.\n\n" + delegateBlock(bassSession.id, "Nightly", "Fix anything broken.")
        )
        let unknownID = homeReply(
            user: "Fix the Plexible player.",
            assistant: delegateBlock(UUID(), "Plexible fix", "Fix the Plexible player.")
        )
        try await Task.sleep(for: .milliseconds(100))
        let automated = try homeMessage(automatedID)
        let unknown = try homeMessage(unknownID)
        precondition(automated.delegations.isEmpty
                     && automated.text.contains("Scheduled and automated runs can't hand work to tabs.")
                     && unknown.delegations.isEmpty
                     && unknown.text.contains("That project tab is no longer open.")
                     && routeBackend.sink == nil && !bassSession.isStreaming,
                     "Automated runs and closed tabs must not dispatch work")
        background.messages = [
            ChatMessage(role: .user, text: "Follow up on that run."),
            ChatMessage(role: .assistant, text: "Handing off.\n\n"
                + delegateBlock(bassSession.id, "Background", "Fix it.")),
        ]
        background.processCantripHomeBlocks()
        try await Task.sleep(for: .milliseconds(100))
        precondition(background.messages.last?.text
                        .contains("The background log can't hand work to tabs.") == true
                     && background.messages.last?.delegations.isEmpty == true
                     && routeBackend.sink == nil && !bassSession.isStreaming,
                     "The background log itself never hands work to tabs")
        background.messages = []
        let orphan = CantripHomeDelegations.evaluate(
            CantripHomeDelegation(
                tabID: UUID(), tabTitle: "Closed", summary: "Closed tab",
                prompt: "Do work.", createdAt: Date(), status: .running
            ),
            target: nil
        )
        precondition(orphan.status == .cancelled
                     && orphan.error == "The tab was closed before this finished.")
        let previewMessage = ChatMessage(
            role: .assistant,
            text: "![Apartment summary](\(artifactURL.path))"
        )
        manager.homeSession.messages.append(previewMessage)
        let refreshedHome = try await call("/api/v1/home")
        let refreshedSession = try requireHome(refreshedHome.1["session"] as? [String: Any])
        let remoteMessages = try requireHome(refreshedSession["messages"] as? [[String: Any]])
        let remotePreview = try requireHome(remoteMessages.first {
            $0["id"] as? String == previewMessage.id.uuidString
        })
        let previewImages = try requireHome(remotePreview["images"] as? [[String: Any]])
        let previewID = try requireHome(previewImages.first?["id"] as? String)
        precondition((remotePreview["displayText"] as? String)?.contains("cantrip-preview://") == true)
        let previewData = try await call(
            "/api/v1/sessions/\(ChatSession.cantripHomeID.uuidString)/\(previewID)/thumbnail"
        )
        precondition(!(previewData.1["data"] as? String ?? "").isEmpty,
                     "Home artifact images must be available as inline previews")
        let taskList = try await call("/api/v1/home/tasks")
        precondition((taskList.1["tasks"] as? [[String: Any]])?.contains {
            $0["id"] as? String == task.id.uuidString
        } == true)
        precondition(taskList.1["supportsReordering"] as? Bool == true)
        // A failing memory consolidation shows above the tasks until a run succeeds, even when the
        // client's revision is current (clients clear the warning on "unchanged").
        let taskRevision = try requireHome(taskList.1["revision"] as? String)
        precondition(taskList.1["error"] == nil, "No warning while consolidation is healthy")
        let memoryWasEnabled = AppSettings.shared.memoryEnabled
        AppSettings.shared.memoryEnabled = true
        var consolidation = ConsolidationState()
        consolidation.recordFailure("Claude Code can't run (Failed to authenticate: OAuth session expired).", at: Date())
        consolidation.save(to: .standard)
        let warned = try await call("/api/v1/home/tasks?revision=\(taskRevision)")
        precondition(warned.1["unchanged"] == nil
                     && (warned.1["error"] as? String)?.hasPrefix(
                         "Memory consolidation failed (1 attempt): Claude Code can't run") == true
                     && (warned.1["tasks"] as? [[String: Any]])?.isEmpty == false,
                     "A failing consolidation is sent with the tasks: \(warned.1)")
        consolidation.recordSuccess(backend: "Copilot", at: Date())
        consolidation.save(to: .standard)
        let healthy = try await call("/api/v1/home/tasks?revision=\(taskRevision)")
        precondition(healthy.1["unchanged"] as? Bool == true,
                     "Once consolidation succeeds the tasks are unchanged again")
        AppSettings.shared.memoryEnabled = memoryWasEnabled
        func taskIDs(_ response: [String: Any]) -> [String] {
            (response["tasks"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        let originalOrder = store.tasks.map(\.id)
        precondition(originalOrder.firstIndex(of: tracker.id)! < originalOrder.firstIndex(of: task.id)!,
                     "New tasks are listed first")
        let moved = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/move", method: "POST",
            body: Data(#"{"targetID":"\#(task.id.uuidString)","placement":"after"}"#.utf8)
        )
        let movedOrder = taskIDs(moved.1)
        precondition(moved.0 == 200
                     && movedOrder.firstIndex(of: task.id.uuidString)!
                        < movedOrder.firstIndex(of: tracker.id.uuidString)!
                     && movedOrder == store.tasks.map(\.id.uuidString)
                     && moved.1["supportsReordering"] as? Bool == true,
                     "Moving a task must return the reordered snapshot")
        let persistedOrder = try JSONDecoder().decode(
            [CantripHomeTask].self,
            from: Data(contentsOf: CantripHomeStore.rootDirectory.appendingPathComponent("tasks.json"))
        ).map(\.id.uuidString)
        precondition(persistedOrder == movedOrder, "Task order must persist across host restarts")
        let badPlacement = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/move", method: "POST",
            body: Data(#"{"targetID":"\#(task.id.uuidString)","placement":"top"}"#.utf8)
        )
        let missingTarget = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/move", method: "POST",
            body: Data(#"{"targetID":"\#(UUID().uuidString)","placement":"before"}"#.utf8)
        )
        let wrongMethod = try await call("/api/v1/home/tasks/\(tracker.id.uuidString)/move")
        precondition(badPlacement.0 == 400 && missingTarget.0 == 404 && wrongMethod.0 == 405
                     && store.tasks.map(\.id.uuidString) == movedOrder,
                     "Rejected moves must leave the order unchanged")
        let restored = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/move", method: "POST",
            body: Data(#"{"targetID":"\#(task.id.uuidString)","placement":"before"}"#.utf8)
        )
        precondition(restored.0 == 200 && store.tasks.map(\.id) == originalOrder)
        let paused = try await call(
            "/api/v1/home/tasks/\(task.id.uuidString)", method: "PATCH",
            body: Data(#"{"enabled":false}"#.utf8)
        )
        precondition(paused.0 == 200 && paused.1["enabled"] as? Bool == false)
        let createdRecord = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/records", method: "POST",
            body: Data(#"{"values":{"company":"Second Co","appliedAt":"2026-09-30","status":"Applied"}}"#.utf8)
        )
        let createdRecords = try requireHome(
            (createdRecord.1["workspace"] as? [String: Any])?["records"] as? [[String: Any]]
        )
        let secondRecord = try requireHome(createdRecords.first(where: {
            ($0["values"] as? [String: String])?["company"] == "Second Co"
        }))
        let secondRecordID = try requireHome(secondRecord["id"] as? String)
        let advancedRecord = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/records/\(secondRecordID)",
            method: "PATCH",
            body: Data(#"{"values":{"status":"Interview","round":"1"}}"#.utf8)
        )
        let advancedRecords = try requireHome(
            (advancedRecord.1["workspace"] as? [String: Any])?["records"] as? [[String: Any]]
        )
        precondition(advancedRecords.contains {
            ($0["values"] as? [String: String])?["status"] == "Interview"
        })
        let removedRecord = try await call(
            "/api/v1/home/tasks/\(tracker.id.uuidString)/records/\(secondRecordID)",
            method: "DELETE"
        )
        precondition(removedRecord.0 == 200)
        let artifactList = try await call("/api/v1/home/artifacts")
        precondition((artifactList.1["artifacts"] as? [[String: Any]])?.contains {
            $0["id"] as? String == artifact.id.uuidString
        } == true)
        let artifactData = try await call("/api/v1/home/artifacts/\(artifact.id.uuidString)")
        precondition(Data(base64Encoded: artifactData.1["data"] as? String ?? "")
                     == imageData)
        let thumbnailRoute = "/api/v1/home/artifacts/\(artifact.id.uuidString)/thumbnail"
        let thumbnail = try await call(thumbnailRoute)
        let thumbnailJPEG = Data(base64Encoded: thumbnail.1["data"] as? String ?? "") ?? Data()
        let thumbnailSource = CGImageSourceCreateWithData(thumbnailJPEG as CFData, nil)
        precondition(thumbnail.0 == 200 && thumbnail.1["width"] as? Int == 1 && thumbnail.1["height"] as? Int == 1
                     && thumbnail.1["durationSeconds"] == nil
                     && thumbnailSource.flatMap { CGImageSourceGetType($0) as String? } == "public.jpeg",
                     "Image artifacts get a JPEG thumbnail: \(thumbnail)")
        let thumbnailCache = CantripHomeStore.rootDirectory
            .appendingPathComponent("thumbnails/\(artifact.id.uuidString).json")
        precondition(FileManager.default.fileExists(atPath: thumbnailCache.path), "Thumbnails are cached on the Mac")
        var anonymous = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(thumbnailRoute)")!)
        anonymous.httpMethod = "GET"
        let (_, anonymousResponse) = try await client.data(for: anonymous)
        let wrongThumbnailMethod = try await call(thumbnailRoute, method: "POST")
        let unknownThumbnail = try await call("/api/v1/home/artifacts/\(UUID().uuidString)/thumbnail")
        let notesURL = CantripHomeStore.artifactDirectory.appendingPathComponent("home-notes.md")
        try Data("# Notes".utf8).write(to: notesURL)
        let notes = try store.register(.init(title: "Notes", path: notesURL.lastPathComponent, kind: nil))
        let notesThumbnail = try await call("/api/v1/home/artifacts/\(notes.id.uuidString)/thumbnail")
        try store.deleteArtifact(id: notes.id)
        precondition((anonymousResponse as! HTTPURLResponse).statusCode == 401 && wrongThumbnailMethod.0 == 405
                     && unknownThumbnail.0 == 404 && notesThumbnail.0 == 404,
                     "Thumbnails need pairing, GET, a known artifact, and an image or video")
        let deletedArtifact = try await call(
            "/api/v1/home/artifacts/\(artifact.id.uuidString)", method: "DELETE"
        )
        precondition(deletedArtifact.0 == 200
                     && deletedArtifact.1["deleted"] as? Bool == true)
        precondition(!store.artifacts.contains { $0.id == artifact.id }
                     && !FileManager.default.fileExists(atPath: artifactURL.path),
                     "Deleting an artifact must remove its registry entry and file")
        for _ in 0..<50 where FileManager.default.fileExists(atPath: thumbnailCache.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!FileManager.default.fileExists(atPath: thumbnailCache.path),
                     "Deleting an artifact must remove its cached thumbnail")
        let deletedArtifactData = try await call(
            "/api/v1/home/artifacts/\(artifact.id.uuidString)"
        )
        precondition(deletedArtifactData.0 == 404)
        let deleted = try await call("/api/v1/home/tasks/\(task.id.uuidString)", method: "DELETE")
        precondition(deleted.1["deleted"] as? Bool == true)
        try store.delete(id: tracker.id)

        try await testCantripHomeBackgroundRuns(
            bassSession: bassSession, routeBackend: routeBackend, token: token,
            port: port == 65535 ? port - 1 : port + 1
        )
        print("Cantrip Home: content-aware tab handoffs, parallel hidden runs, schedules, task/artifact safety and authenticated APIs passed")
    }

    final class CantripHomeBackendFixture: Backend {
        var sink: ((BackendEvent) -> Void)?
        var lastPrompt: String?
        var lastTurnCount = 0
        var lastTurns: [ConversationTurn] = []
        var resets = 0
        func send(_ request: BackendRequest, workdir: String,
                  onEvent: @escaping (BackendEvent) -> Void) {
            lastPrompt = request.prompt
            lastTurnCount = request.previousTurns.count
            lastTurns = request.previousTurns
            sink = onEvent
        }
        func cancel() {}
        func reset() { resets += 1 }
    }

    /// List groups: opt-in, validated against the choice field, and editable on their own.
    @MainActor
    static func testCantripHomeListGroups(
        store: CantripHomeStore, manager: SessionManager, tracker: CantripHomeTask
    ) throws {
        func list(_ json: String) throws -> CantripHomeTaskListPresentation {
            try JSONDecoder().decode(CantripHomeTaskListPresentation.self, from: Data(json.utf8))
        }
        func rejects(_ proposal: CantripHomeTaskProposal, _ expected: String, _ message: String) {
            let before = store.tasks
            do {
                _ = try store.create(proposal)
                preconditionFailure(message)
            } catch {
                precondition(error.localizedDescription.contains(expected),
                             "\(message): \(error.localizedDescription)")
            }
            precondition(store.tasks == before, "\(message): a rejected edit changes nothing")
        }
        let base = #""titleField":"company","subtitleFields":["round"],"badgeField":"status","dateField":"appliedAt""#

        let legacy = try list(#"{"titleField":"company","subtitleFields":[],"badgeField":null,"dateField":null}"#)
        precondition(legacy.groupField == nil && legacy.groups == nil)
        let plain = try requireHome(tracker.workspace?.list)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        precondition(!plainJSON.contains("group"),
                     "Workspaces that never opt in save exactly the keys they had: \(plainJSON)")

        let before = try requireHome(store.tasks.first { $0.id == tracker.id })
        manager.homeSession.messages.append(ChatMessage(role: .assistant, text: """
        I grouped your applications.
        ```cantrip-task
        {"id":"\(tracker.id.uuidString)","list":{\(base),"groupField":"status","groups":[{"title":" Active ","values":["Interview","Offer"]},{"title":"Applied","values":["Applied"]},{"title":"Done","values":["Closed"],"collapsed":true}]}}
        ```
        """))
        manager.homeSession.processCantripHomeBlocks()
        let grouped = try requireHome(store.tasks.first { $0.id == tracker.id })
        let groups = try requireHome(grouped.workspace?.list.groups)
        precondition(grouped.workspace?.list.groupField == "status"
                     && groups.map(\.title) == ["Active", "Applied", "Done"]
                     && groups.map(\.values) == [["Interview", "Offer"], ["Applied"], ["Closed"]]
                     && groups.map(\.collapsed) == [nil, nil, true],
                     "A Home block sets trimmed groups in the order given")
        precondition(grouped.workspace?.records == before.workspace?.records
                     && grouped.workspace?.fields == before.workspace?.fields
                     && grouped.workspace?.detailSections == before.workspace?.detailSections
                     && grouped.workspace?.list.titleField == "company"
                     && grouped.prompt == before.prompt && grouped.title == before.title
                     && grouped.isScheduled == before.isScheduled
                     && grouped.runsAfter == before.runsAfter,
                     "A top-level list edit replaces only the list presentation")
        precondition(manager.homeSession.messages.last?.text.contains("Task updated: **Job applications**") == true
                     && !manager.homeSession.messages.last!.text.contains("cantrip-task"))
        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: CantripHomeStore.tasksFile)
        ) as? [[String: Any]]
        let savedList = (saved?.first { ($0["id"] as? String) == tracker.id.uuidString }?["workspace"]
            as? [String: Any])?["list"] as? [String: Any]
        precondition(savedList?["groupField"] as? String == "status"
                     && (savedList?["groups"] as? [[String: Any]])?.count == 3,
                     "Groups persist in tasks.json")

        let instructions = manager.homeSession.cantripHomeInstructions
        precondition(instructions.contains("status:choice[Applied|Interview|Offer|Closed]")
                     && instructions.contains(#""groupField":"status""#)
                     && instructions.contains(#""title":"Active","values":["Interview","Offer"]"#)
                     && instructions.contains("To change only an existing workspace's list")
                     && instructions.contains(#""groupField":"choice key or null""#),
                     "Home sees each choice field's options and the saved list, and the rules")

        let id = tracker.id
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groups":[{"title":"A","values":["Applied"]}]}"#
        )), "need a groupField", "Groups without a groupField")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"company"}"#
        )), "must be a choice field", "Grouping by a text field")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"missing"}"#
        )), "unknown field", "Grouping by an unknown field")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[{"title":"Done","values":["Rejected"]}]}"#
        )), "isn't a Status option", "A group value outside the options")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[{"title":"A","values":["Applied"]},{"title":"B","values":["Offer","Applied"]}]}"#
        )), "more than one list group", "A value in two groups")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[{"title":"Done","values":["Applied"]},{"title":"done","values":["Offer"]}]}"#
        )), "short, unique titles", "Duplicate group titles")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[{"title":"  ","values":["Applied"]}]}"#
        )), "short, unique titles", "A blank group title")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[{"title":"Empty","values":[]}]}"#
        )), "needs 1 to 50 values", "A group with no values")
        let thirteen = (0..<13).map { #"{"title":"G\#($0)","values":["Applied"]}"# }.joined(separator: ",")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, list: try list(
            #"{\#(base),"groupField":"status","groups":[\#(thirteen)]}"#
        )), "1 to 12 list groups", "Too many groups")
        rejects(.init(id: nil, title: "New", prompt: "Track", schedule: nil, list: plain),
                "only to change an existing task's workspace list", "A list without a task id")
        let workspaceProposal = try JSONDecoder().decode(
            CantripHomeTaskWorkspaceProposal.self,
            from: Data(#"{"recordLabel":"Application","icon":"briefcase.fill","fields":[{"key":"company","label":"Company","kind":"text","required":true,"options":null},{"key":"appliedAt","label":"Applied","kind":"date","required":true,"options":null},{"key":"status","label":"Status","kind":"choice","required":true,"options":["Applied","Interview","Offer","Closed"]},{"key":"round","label":"Interview round","kind":"number","required":false,"options":null},{"key":"interviewAt","label":"Interview","kind":"dateTime","required":false,"options":null}],"list":{\#(base),"groupField":"status","groups":[{"title":"Gone","values":["Withdrawn"]}]},"detailSections":[]}"#.utf8)
        )
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, workspace: workspaceProposal),
                "isn't a Status option", "Full workspace edits validate groups too")
        rejects(.init(id: id, title: nil, prompt: nil, schedule: nil, workspace: workspaceProposal,
                      list: plain),
                "only to change an existing task's workspace list", "A list beside a workspace")
        let scheduleOnly = try requireHome(store.tasks.first { $0.workspace == nil })
        rejects(.init(id: scheduleOnly.id, title: nil, prompt: nil, schedule: nil, list: plain),
                "has no workspace list", "A list for a task without a workspace")

        // A groupField alone means one section per option; local maintenance can queue it.
        try? FileManager.default.createDirectory(
            at: CantripHomeStore.taskEditDirectory, withIntermediateDirectories: true
        )
        let edit = CantripHomeStore.taskEditDirectory.appendingPathComponent("list-groups.json")
        try Data(#"{"version":1,"taskID":"\#(id.uuidString)","list":{\#(base),"groupField":"status"}}"#.utf8)
            .write(to: edit, options: .atomic)
        store.checkNow()
        let perOption = try requireHome(store.tasks.first { $0.id == id })
        precondition(perOption.workspace?.list.groupField == "status"
                     && perOption.workspace?.list.groups == nil
                     && perOption.workspace?.records == before.workspace?.records
                     && !FileManager.default.fileExists(atPath: edit.path),
                     "The task-edit inbox replaces the list")
        let badEdit = CantripHomeStore.taskEditDirectory.appendingPathComponent("list-bad.json")
        try Data(#"{"version":1,"taskID":"\#(id.uuidString)","list":{\#(base),"groupField":"round"}}"#.utf8)
            .write(to: badEdit, options: .atomic)
        store.checkNow()
        precondition(store.tasks.first { $0.id == id }?.workspace?.list.groupField == "status"
                     && FileManager.default.fileExists(atPath: badEdit.path + ".rejected"),
                     "An invalid queued list is set aside")
        try? FileManager.default.removeItem(atPath: badEdit.path + ".rejected")

        // Clearing groups restores the original list exactly.
        _ = try store.create(.init(id: id, title: nil, prompt: nil, schedule: nil, list: plain))
        precondition(store.tasks.first { $0.id == id }?.workspace?.list == plain)
    }

    static func requireHome<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing Home value at line \(line)") }
        return value
    }

    @MainActor
    static func testCantripHomeLive() async throws {
        let settings = AppSettings.shared
        let backend = settings.backend
        let memory = settings.memoryEnabled
        let screen = settings.attachScreen
        let location = settings.shareLocation
        let calendar = settings.shareCalendar
        let files = settings.fileRAGEnabled
        defer {
            settings.backend = backend
            settings.memoryEnabled = memory
            settings.attachScreen = screen
            settings.shareLocation = location
            settings.shareCalendar = calendar
            settings.fileRAGEnabled = files
        }
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let chat = ChatSession(id: ChatSession.cantripHomeID)
        defer { chat.cancel() }
        chat.submitRemote(
            "Create a task named Home live fixture that checks the lowest round-trip economy price for one adult from SFO to JFK, outbound October 20 2026 and returning October 27 2026, every weekday at 8 AM and again at 6 PM in America/Los_Angeles. Report the lowest price and source; do not run it now."
        )
        let deadline = Date().addingTimeInterval(180)
        while chat.isStreaming, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(!chat.isStreaming, "The live Home task proposal did not finish")
        let answer = chat.messages.last(where: { $0.role == .assistant })?.text ?? ""
        let transcript = chat.messages.map { "\($0.role.rawValue): \($0.text)" }
        guard let task = CantripHomeStore.shared.tasks.first(where: {
            $0.title.caseInsensitiveCompare("Home live fixture") == .orderedSame
        }) else {
            preconditionFailure(
                "Live Home task missing. Messages: \(transcript) Tasks: \(CantripHomeStore.shared.tasks.map(\.title))"
            )
        }
        precondition(task.schedule.weekdays == [2, 3, 4, 5, 6]
                     && task.schedule.runTimes == [.init(hour: 8, minute: 0), .init(hour: 18, minute: 0)]
                     && task.schedule.summary == "Weekdays at 8:00 AM and 6:00 PM"
                     && !answer.contains("cantrip-task"),
                     "The live Home protocol did not create one two-time task and hide the marker: \(task.schedule)")
        try CantripHomeStore.shared.delete(id: task.id)
        print("Live Cantrip Home: conversational two-time weekday task created and control marker hidden")
    }
}
