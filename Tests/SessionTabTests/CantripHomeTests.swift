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

        func call(_ path: String, method: String = "GET", body: Data? = nil) async throws
            -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
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
        precondition(!listedIDs.contains(ChatSession.cantripHomeID.uuidString))
        let home = try await call("/api/v1/home")
        let homeSession = try requireHome(home.1["session"] as? [String: Any])
        precondition(home.0 == 200 && homeSession["id"] as? String == ChatSession.cantripHomeID.uuidString
                     && homeSession["isCantripHome"] as? Bool == true)
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
        let deleted = try await call("/api/v1/home/tasks/\(task.id.uuidString)", method: "DELETE")
        precondition(deleted.1["deleted"] as? Bool == true)
        try store.delete(id: tracker.id)

        let fixture = CantripHomeBackendFixture()
        let scheduledSession = ChatSession(
            id: ChatSession.cantripHomeID, copilotBackend: fixture
        )
        let scheduledManager = SessionManager(homeSession: scheduledSession)
        store.attach(manager: scheduledManager)
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
        fixture.sink?(.textDelta("Scheduler finished."))
        fixture.sink?(.done)
        try await waitForJournalTest {
            store.tasks.first(where: { $0.id == scheduled.id })?.runs.first?.status == "succeeded"
        }
        let completed = try requireHome(store.tasks.first { $0.id == scheduled.id })
        precondition(completed.enabled == false && completed.nextRunAt == nil
                     && completed.runs.first?.summary.contains("Scheduler finished.") == true)
        try store.delete(id: scheduled.id)
        print("Cantrip Home: hidden session, schedules, task/artifact safety and authenticated APIs passed")
    }

    private final class CantripHomeBackendFixture: Backend {
        var sink: ((BackendEvent) -> Void)?
        func send(_ request: BackendRequest, workdir: String,
                  onEvent: @escaping (BackendEvent) -> Void) {
            sink = onEvent
        }
        func cancel() {}
        func reset() {}
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
            "Create a task named Home live fixture that checks the lowest round-trip economy price for one adult from SFO to JFK, outbound October 20 2026 and returning October 27 2026, every weekday at 8 AM in America/Los_Angeles. Report the lowest price and source; do not run it now."
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
                     && task.schedule.hour == 8
                     && !answer.contains("cantrip-task"),
                     "The live Home protocol did not create and hide the task marker")
        try CantripHomeStore.shared.delete(id: task.id)
        print("Live Cantrip Home: conversational weekday task created and control marker hidden")
    }
}
