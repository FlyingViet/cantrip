import Foundation

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
                "Pushed FlyingViet/Hermes and rebuilt /Users/me/Coding/Hermes",
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
        precondition(bassSession.isStreaming
                     && bassSession.messages.contains { $0.role == .user && $0.text == handoffPrompt },
                     "The project tab must own the handed-off prompt")
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
                     && bassSession.queued.map(\.text) == [queuedPrompt]
                     && bassSession.messages.filter { $0.role == .user }.map(\.text) == [handoffPrompt],
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
                        .contains("Scheduled and automated runs can't hand work to tabs.") == true
                     && background.messages.last?.delegations.isEmpty == true
                     && routeBackend.sink == nil && !bassSession.isStreaming,
                     "The background conversation must never hand work to tabs")
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
        let deletedArtifact = try await call(
            "/api/v1/home/artifacts/\(artifact.id.uuidString)", method: "DELETE"
        )
        precondition(deletedArtifact.0 == 200
                     && deletedArtifact.1["deleted"] as? Bool == true)
        precondition(!store.artifacts.contains { $0.id == artifact.id }
                     && !FileManager.default.fileExists(atPath: artifactURL.path),
                     "Deleting an artifact must remove its registry entry and file")
        let deletedArtifactData = try await call(
            "/api/v1/home/artifacts/\(artifact.id.uuidString)"
        )
        precondition(deletedArtifactData.0 == 404)
        let deleted = try await call("/api/v1/home/tasks/\(task.id.uuidString)", method: "DELETE")
        precondition(deleted.1["deleted"] as? Bool == true)
        try store.delete(id: tracker.id)

        let fixture = CantripHomeBackendFixture()
        let homeFixture = CantripHomeBackendFixture()
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: homeFixture)
        let scheduledSession = ChatSession(
            id: ChatSession.cantripHomeBackgroundID, copilotBackend: fixture
        )
        scheduledSession.messages = []
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
        let scheduledManager = SessionManager(
            homeSession: homeChat, homeBackgroundSession: scheduledSession
        )
        let savedHomeAfterMove = try JSONDecoder().decode(
            [ChatMessage].self,
            from: Data(contentsOf: SessionManager.chatsDir
                .appendingPathComponent("\(ChatSession.cantripHomeID.uuidString).json"))
        )
        precondition(homeChat.messages.map(\.text) == ["Hello", "Hi there."]
                     && savedHomeAfterMove.map(\.text) == ["Hello", "Hi there."]
                     && scheduledSession.messages.map(\.text) == [
                        legacyScheduled, "Tracker refreshed.",
                        legacyIncident, "Investigating the timeout.",
                     ]
                     && homeChat.moveAutomatedCantripHomeTurns(to: scheduledSession) == 0,
                     "Automated turns older builds left in Home must move once to the background log")
        store.attach(manager: scheduledManager)
        let backgroundServer = RemoteControlServer(manager: scheduledManager)
        let backgroundPort = port == 65535 ? port - 1 : port + 1
        backgroundServer.start(port: backgroundPort, token: token)
        defer { backgroundServer.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let homeGuidance = homeChat.cantripHomeInstructions
        precondition(homeGuidance.contains(
            "- Automated Bass Compass Ingestion Incident: Investigating the timeout.\n"
                + "- Daily interview tracker: Tracker refreshed.")
                     && homeGuidance.contains(CantripHomeStore.tasksFile.path)
                     && homeGuidance.contains("Project tabs —"),
                     "Home must know recent background results and where saved task prompts live")
        let backgroundGuidance = scheduledSession.cantripHomeInstructions
        precondition(backgroundGuidance.contains("CANTRIP HOME BACKGROUND")
                     && !backgroundGuidance.contains("Project tabs —")
                     && !backgroundGuidance.contains("Recent background runs"),
                     "Background runs get the task/artifact protocol without handoffs")

        homeChat.submit("Can you run the interview tracker again?")
        try await waitForJournalTest { homeFixture.sink != nil }
        precondition(homeChat.isStreaming
                     && homeChat.messages.last(where: { $0.role == .user })?.text
                        == "Can you run the interview tracker again?"
                     && homeFixture.lastPrompt?.contains("Recent background runs") == true,
                     "A request typed in Home must run in the Home chat")

        func writeIncident(_ id: UUID) throws -> (URL, String, [String: Any]) {
            let url = CantripHomeStore.incidentDirectory
                .appendingPathComponent("\(id.uuidString.lowercased()).json")
            let marker = "[incident:\(id.uuidString.lowercased())]"
            let envelope: [String: Any] = [
                "version": 1,
                "id": id.uuidString,
                "prompt": """
                AUTOMATED BASS COMPASS INGESTION INCIDENT \(marker)
                Investigate the fixture without making changes.
                """,
                "createdAt": "2026-09-30T23:00:00.000Z",
            ]
            try JSONSerialization.data(withJSONObject: envelope).write(to: url, options: .atomic)
            return (url, marker, envelope)
        }
        let homeMessageCount = homeChat.messages.count
        let resetsBefore = fixture.resets
        let (incidentURL, incidentMarker, incidentEnvelope) = try writeIncident(UUID())
        store.checkNow()
        try await waitForJournalTest { fixture.sink != nil }
        precondition(!FileManager.default.fileExists(atPath: incidentURL.path)
                     && scheduledSession.messages.contains { $0.text.contains(incidentMarker) }
                     && homeChat.messages.count == homeMessageCount
                     && !homeChat.messages.contains { $0.text.contains(incidentMarker) },
                     "Incidents must run in the background conversation, not the Home chat")
        precondition(fixture.lastPrompt?.contains("untrusted evidence") == true
                     && fixture.lastPrompt?.contains("CANTRIP HOME BACKGROUND") == true
                     && fixture.lastTurnCount == 0 && fixture.resets > resetsBefore
                     && scheduledSession.notificationTitle == "Automated Bass Compass Ingestion Incident",
                     "Each automated run starts from a fresh, labeled context")
        let startedRun = try requireHome(store.backgroundRuns.first)
        precondition(startedRun.id == scheduledSession.currentRunIdentifier
                     && startedRun.kind == .incident && startedRun.status == "running"
                     && startedRun.label == "Automated Bass Compass Ingestion Incident"
                     && startedRun.finishedAt == nil,
                     "The Background list records an incident as soon as it starts")

        let (queuedURL, queuedMarker, _) = try writeIncident(UUID())
        store.checkNow()
        precondition(!FileManager.default.fileExists(atPath: queuedURL.path)
                     && scheduledSession.queued.count == 1
                     && fixture.lastPrompt?.contains(incidentMarker) == true,
                     "A second incident waits behind the running one")
        let backgroundList = try await call("/api/v1/home/background", serverPort: backgroundPort)
        let listedQueue = backgroundList.1["queued"] as? [[String: Any]] ?? []
        let listedRuns = backgroundList.1["runs"] as? [[String: Any]] ?? []
        precondition(backgroundList.0 == 200
                     && backgroundList.1["sessionID"] as? String
                        == ChatSession.cantripHomeBackgroundID.uuidString
                     && listedQueue.count == 1 && listedQueue.first?["kind"] as? String == "incident"
                     && listedQueue.first?["label"] as? String == "Automated Bass Compass Ingestion Incident"
                     && listedRuns.first?["status"] as? String == "running"
                     && backgroundList.1["activity"] is String,
                     "The Background API lists the running run, its activity and the queue")
        let busyHome = try await call("/api/v1/home", serverPort: backgroundPort)
        let busyHomeSession = try requireHome(busyHome.1["session"] as? [String: Any])
        precondition(busyHomeSession["supportsBackgroundRuns"] as? Bool == true
                     && busyHomeSession["backgroundActiveCount"] as? Int == 2,
                     "Home's snapshot counts running and queued background work for the badge")
        let firstIncident = fixture.sink
        fixture.sink = nil
        firstIncident?(.textDelta("Incident fixture finished."))
        firstIncident?(.done)
        try await waitForJournalTest { fixture.sink != nil }
        precondition(fixture.lastPrompt?.contains(queuedMarker) == true
                     && fixture.lastPrompt?.contains("untrusted evidence") == true
                     && fixture.lastTurnCount == 0,
                     "Queued incidents keep their untrusted-evidence framing and fresh context")
        fixture.sink?(.textDelta("Second incident finished."))
        fixture.sink?(.done)
        try await waitForJournalTest { !scheduledSession.isStreaming }
        precondition(scheduledSession.remoteCompletion?.sessionID == ChatSession.cantripHomeBackgroundID
                     && scheduledSession.remoteCompletion?.title
                        == "Automated Bass Compass Ingestion Incident",
                     "Completion notifications name the run and open its background report")
        precondition(store.backgroundRuns.prefix(2).map(\.status) == ["succeeded", "succeeded"]
                     && store.backgroundRuns.prefix(2).map(\.summary)
                        == ["Second incident finished.", "Incident fixture finished."]
                     && store.backgroundRuns.prefix(2).allSatisfy { $0.finishedAt != nil },
                     "Finished incidents keep their full result, newest first")
        let idleHome = try await call("/api/v1/home", serverPort: backgroundPort)
        precondition((idleHome.1["session"] as? [String: Any])?["backgroundActiveCount"] as? Int == 0)
        fixture.sink = nil
        try JSONSerialization.data(withJSONObject: incidentEnvelope)
            .write(to: incidentURL, options: .atomic)
        store.checkNow()
        precondition(!FileManager.default.fileExists(atPath: incidentURL.path)
                     && fixture.sink == nil,
                     "A previously accepted incident must not run twice")

        let scheduled = try store.create(.init(
            id: nil,
            title: "One-time scheduler test",
            prompt: "Return the exact scheduler result.",
            schedule: .init(
                kind: .once, summary: "Once shortly", timeZone: zone,
                startAt: Date().addingTimeInterval(0.2)
            )
        ))
        try await Task.sleep(for: .milliseconds(250))
        store.checkNow()
        try await waitForJournalTest { fixture.sink != nil }
        let scheduledUser = scheduledSession.messages.last { $0.role == .user }?.text ?? ""
        precondition(scheduledUser == "Scheduled task · One-time scheduler test\nOnce shortly · running saved instructions"
                     && fixture.lastPrompt?.contains("Return the exact scheduler result.") == true
                     && fixture.lastTurnCount == 0,
                     "The background log shows a short task label while the agent receives the full prompt")
        precondition(homeChat.isStreaming && homeChat.messages.count == homeMessageCount
                     && store.tasks.first(where: { $0.id == scheduled.id })?.state == .running,
                     "Scheduled runs must not wait for, or write into, the Home chat")
        fixture.sink?(.textDelta("Scheduler finished."))
        fixture.sink?(.done)
        try await waitForJournalTest {
            store.tasks.first(where: { $0.id == scheduled.id })?.runs.first?.status == "succeeded"
        }
        let completed = try requireHome(store.tasks.first { $0.id == scheduled.id })
        precondition(completed.enabled == false && completed.nextRunAt == nil
                     && completed.runs.first?.summary.contains("Scheduler finished.") == true)
        let taskRun = try requireHome(store.backgroundRuns.first)
        precondition(taskRun.kind == .task && taskRun.taskID == scheduled.id
                     && taskRun.label == "One-time scheduler test"
                     && taskRun.status == "succeeded" && taskRun.summary == "Scheduler finished.",
                     "Scheduled runs appear in the Background list linked to their task")
        try await waitForJournalTest { !scheduledSession.isStreaming }
        precondition(scheduledSession.remoteCompletion?.title == "One-time scheduler test"
                     && homeChat.cantripHomeInstructions
                        .contains("- One-time scheduler test: Scheduler finished.")
                     && homeChat.cantripHomeInstructions.contains("last run succeeded"),
                     "Home must see the finished run summary")

        homeFixture.sink?(.textDelta("Tracker refreshed again."))
        homeFixture.sink?(.done)
        try await waitForJournalTest { !homeChat.isStreaming }
        precondition(homeChat.messages.map(\.text) == [
            "Hello", "Hi there.", "Can you run the interview tracker again?", "Tracker refreshed again.",
        ], "Home holds only the user's own conversation")

        fixture.sink = nil
        let (_, interruptedMarker, _) = try writeIncident(UUID())
        store.checkNow()
        try await waitForJournalTest { fixture.sink != nil }
        precondition(fixture.lastPrompt?.contains(interruptedMarker) == true)
        // Separate journals keep the stand-in sessions from touching the live run's journal.
        let relaunched = SessionManager(
            homeSession: ChatSession(
                id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            ),
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        store.attach(manager: relaunched)
        precondition(store.backgroundRuns.first?.status == "interrupted"
                     && store.backgroundRuns.first?.finishedAt != nil,
                     "A run that was live when Cantrip quit must not stay running forever")
        store.attach(manager: scheduledManager)
        fixture.sink?(.textDelta("Late finish."))
        fixture.sink?(.done)
        try await waitForJournalTest { store.backgroundRuns.first?.status == "succeeded" }
        let seeded = CantripHomeStore.seededBackgroundRuns(from: [completed])
        precondition(seeded.count == completed.runs.count
                     && seeded.first?.taskID == completed.id && seeded.first?.kind == .task
                     && seeded.first?.summary == completed.runs.first?.summary,
                     "The first Background list starts from recorded task runs")
        try store.delete(id: scheduled.id)

        // One task, several daily times: Home's protocol, the schedule-edit inbox and catch-up.
        for task in store.tasks where task.isScheduled && task.enabled {
            _ = try store.update(id: task.id, update: .init(title: nil, prompt: nil, enabled: false))
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
        let tasksAPI = try await call("/api/v1/home/tasks")
        let apiSchedule = ((tasksAPI.1["tasks"] as? [[String: Any]])?
            .first { $0["id"] as? String == twice.id.uuidString })?["schedule"] as? [String: Any]
        precondition(apiSchedule?["hour"] as? Int == 7 && apiSchedule?["minute"] as? Int == 0
                     && (apiSchedule?["times"] as? [[String: Int]])?.count == 2,
                     "The tasks API keeps hour/minute for older iPhone builds alongside times")

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
        try await waitForJournalTest { !scheduledSession.isStreaming }
        store.clock = { woke }
        fixture.sink = nil
        store.checkNow()
        try await waitForJournalTest { fixture.sink != nil }
        let catchUpPrompt = fixture.lastPrompt
        precondition(store.tasks.first { $0.id == twice.id }?.state == .running
                     && scheduledSession.queued.isEmpty
                     && catchUpPrompt?.contains("Refresh the interview records.") == true,
                     "An overdue multi-time task starts one catch-up run")
        let queuedEditURL = try writeScheduleEdit("4-later.json", dailyEdit(twice.id, #"["08:30","21:00"]"#))
        store.checkNow()
        precondition(scheduledSession.queued.isEmpty && fixture.lastPrompt == catchUpPrompt
                     && FileManager.default.fileExists(atPath: queuedEditURL.path),
                     "A running task is never started again, and its schedule edit waits")
        let catchUp = fixture.sink
        fixture.sink = nil
        catchUp?(.textDelta("Caught up."))
        catchUp?(.done)
        try await waitForJournalTest {
            store.tasks.first(where: { $0.id == twice.id })?.runs.first?.status == "succeeded"
        }
        let caughtUp = try requireHome(store.tasks.first { $0.id == twice.id })
        precondition(caughtUp.runs.count == 1
                     && !FileManager.default.fileExists(atPath: queuedEditURL.path)
                     && caughtUp.schedule.runTimes.map(\.hour) == [8, 21]
                     && caughtUp.nextRunAt == woke.addingTimeInterval(8 * 3_600),
                     "Missed slots collapse into one run; the next run is the next future slot")
        try await waitForJournalTest { !scheduledSession.isStreaming }
        store.checkNow()
        precondition(fixture.sink == nil && scheduledSession.queued.isEmpty,
                     "No second catch-up run for the other missed slots")
        try store.delete(id: twice.id)
        print("Cantrip Home: content-aware tab handoffs, hidden session, schedules, task/artifact safety and authenticated APIs passed")
    }

    private final class CantripHomeBackendFixture: Backend {
        var sink: ((BackendEvent) -> Void)?
        var lastPrompt: String?
        var lastTurnCount = 0
        var resets = 0
        func send(_ request: BackendRequest, workdir: String,
                  onEvent: @escaping (BackendEvent) -> Void) {
            lastPrompt = request.prompt
            lastTurnCount = request.previousTurns.count
            sink = onEvent
        }
        func cancel() {}
        func reset() { resets += 1 }
    }

    private static func requireHome<T>(_ value: T?, line: UInt = #line) throws -> T {
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
