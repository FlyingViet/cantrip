import CryptoKit
import Foundation

private final class LiveStatusTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

private actor LiveStatusRequestRecorder {
    private var requests: [URLRequest] = []
    private var statuses: [Int]
    private var reason: String

    init(statuses: [Int] = [], reason: String = "Unregistered") {
        self.statuses = statuses
        self.reason = reason
    }

    func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        let data = status == 200 ? Data(#"{}"#.utf8) : Data(#"{"reason":"\\#(reason)"}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func all() -> [URLRequest] { requests }
    func count() -> Int { requests.count }
}

extension SessionTabTests {
    @MainActor
    static func testLiveStatus() async throws {
        try await testLiveStatusSnapshotBuilder()
        try await testLiveStatusRunOutcomes()
        try await testLiveStatusRoutes()
        try await testRemoteLiveStatusPushes()
        print("Live status: snapshot, routes, subscriptions, APNs lifecycle, throttles, invalidation and payload limits passed")
    }

    static func testLiveStatusSnapshotBuilder() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let oldRun = Date(timeIntervalSince1970: 1_000)
        let newRun = Date(timeIntervalSince1970: 1_500)
        let doneAt = Date(timeIntervalSince1970: 1_900)
        let failedAt = Date(timeIntervalSince1970: 1_800)
        let sessions: [LiveStatusSession] = [
            LiveStatusSession(id: UUID(), title: "Private", isPrivate: true, isStreaming: true),
            LiveStatusSession(id: UUID(), title: "Local", isLocalPrivate: true, isStreaming: true),
            LiveStatusSession(id: UUID(), title: "Input tab", isStreaming: true, statusText: "Running",
                              queued: 2, pendingInputs: [LiveStatusInput(title: String(repeating: "Q", count: 90), kind: "question"),
                                                         LiveStatusInput(title: "Second", kind: "approval")],
                              currentRunStartedAt: newRun, activeSubagents: 3),
            LiveStatusSession(id: UUID(), title: String(repeating: "R", count: 60), isStreaming: true,
                              statusText: "", currentActivityTitle: "Building", currentRunStartedAt: oldRun),
            LiveStatusSession(id: UUID(), title: "Newer run", isStreaming: true,
                              statusText: "Testing", currentRunStartedAt: newRun),
            LiveStatusSession(id: UUID(), title: "Done", lastRunOutcome: .init(status: .done, finishedAt: doneAt)),
            LiveStatusSession(id: UUID(), title: "Failed", lastRunOutcome: .init(status: .failed, finishedAt: failedAt)),
            LiveStatusSession(id: UUID(), title: "Stopped", lastRunOutcome: .init(status: .stopped, finishedAt: Date(timeIntervalSince1970: 1_700))),
            LiveStatusSession(id: UUID(), title: "Idle"),
            LiveStatusSession(id: UUID(), title: "Extra", lastRunOutcome: .init(status: .done, finishedAt: Date(timeIntervalSince1970: 1_600))),
        ]
        let snapshot = LiveStatusSnapshot.build(from: sessions, now: now, hostName: "Mac")
        precondition(snapshot.version == 1 && snapshot.generatedAt == now.timeIntervalSince1970)
        precondition(snapshot.total == 8 && snapshot.running == 2 && snapshot.needsInput == 1)
        precondition(snapshot.tabs.count == 8)
        precondition(snapshot.tabs[0].state == .input && snapshot.tabs[0].queued == 2 && snapshot.tabs[0].subagents == 3)
        precondition(snapshot.tabs[0].detail?.count == 72 && snapshot.tabs[0].detail?.last == "…")
        precondition(snapshot.tabs[0].inputKind == "question", "The first pending request names the tab's input kind")
        precondition(snapshot.tabs.dropFirst().allSatisfy { $0.inputKind == nil })
        let inputObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.tabs[0])) as! [String: Any]
        precondition(inputObject["inputKind"] as? String == "question")
        precondition(snapshot.tabs[1].state == .running && snapshot.tabs[1].startedAt == oldRun.timeIntervalSince1970)
        precondition(snapshot.tabs[1].title.count == 48 && snapshot.tabs[1].title.last == "…")
        precondition(snapshot.tabs[2].state == .running && snapshot.tabs[2].startedAt == newRun.timeIntervalSince1970)
        precondition(snapshot.tabs[3].state == .done && snapshot.tabs[3].finishedAt == doneAt.timeIntervalSince1970)
        precondition(snapshot.tabs[4].state == .failed && snapshot.tabs[4].finishedAt == failedAt.timeIntervalSince1970)
        precondition(snapshot.tabs.last?.state == .idle && snapshot.tabs.last?.finishedAt == nil)
        let data = try JSONEncoder().encode(snapshot.tabs.last!)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object.keys.contains("startedAt") && object["startedAt"] is NSNull)
        precondition(object.keys.contains("detail") && object["detail"] is NSNull)
        precondition(!object.keys.contains("inputKind"), "Only waiting tabs carry an input kind")
    }

    @MainActor
    static func testLiveStatusRunOutcomes() async throws {
        AppSettings.shared.memoryEnabled = false
        AppSettings.shared.voiceMode = false
        let chat = ChatSession()
        chat.submitRemote("! /usr/bin/printf done")
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.lastRunOutcome?.status == .done)
        let restored = ChatSession(id: chat.id)
        precondition(restored.lastRunOutcome?.status == .done)

        let restoredRunSessionID = UUID()
        let restoredRunID = UUID()
        let journal = try RunJournal(sessionID: restoredRunSessionID)
        var started = RunJournal.Event(timestamp: Date(timeIntervalSince1970: 1_234),
                                       sessionID: restoredRunSessionID,
                                       runID: restoredRunID,
                                       kind: .turnStarted)
        started.prompt = "unfinished"
        started.mode = .single
        started.backends = ["Shell"]
        started.workdir = FileManager.default.homeDirectoryForCurrentUser.path
        started.includesAmbientContext = false
        try journal.append(started, durable: true)
        let restoredActive = ChatSession(id: restoredRunSessionID)
        precondition(restoredActive.currentRunIdentifier == restoredRunID)
        restoredActive.submitRemote("! /usr/bin/printf superseded")
        precondition(restoredActive.lastRunOutcome?.status != .stopped,
                     "beginRun's superseded cancellation must not record Stop")
        try await waitForJournalTest { !restoredActive.isStreaming }
        precondition(restoredActive.lastRunOutcome?.status == .done)

        chat.submitRemote("! /bin/sleep 1")
        try await waitForJournalTest { chat.isStreaming }
        chat.cancel()
        precondition(chat.lastRunOutcome?.status == .stopped)
    }

    @MainActor
    static func testLiveStatusRoutes() async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/live-status-tests/routes-")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let recorder = LiveStatusRequestRecorder()
        let liveStatus = RemoteLiveStatus(file: directory.appendingPathComponent("state.json"),
                                          configuration: { configuration },
                                          send: { await recorder.respond($0) })
        let manager = SessionManager()
        let visible = ChatSession()
        try visible.updateTab(name: "Visible")
        let privateTab = ChatSession(); privateTab.isPrivate = true
        let local = ChatSession(id: ChatSession.privateLocalID)
        manager.sessions = [visible, privateTab, local]
        let server = RemoteControlServer(manager: manager, liveStatus: liveStatus)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))

        func request(_ path: String, method: String = "GET", auth: Bool = true, body: Data? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            request.httpMethod = method
            request.httpBody = body
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }

        let unauthorized = try await request("/api/v1/live-status", auth: false)
        precondition(unauthorized.0 == 401)
        let live = try await request("/api/v1/live-status")
        precondition(live.0 == 200)
        precondition(live.1["version"] as? Int == 1)
        precondition(live.1["hostName"] is String && live.1["generatedAt"] is Double)
        let tabs = live.1["tabs"] as! [[String: Any]]
        precondition(tabs.count == 1 && tabs[0]["title"] as? String == "Visible")
        precondition(tabs[0].keys.contains("startedAt") && tabs[0]["startedAt"] is NSNull)

        let subPath = "/api/v1/live-status/subscription"
        let unauthSub = try await request(subPath, auth: false)
        let patchSub = try await request(subPath, method: "PATCH")
        let malformedSub = try await request(subPath, method: "POST", body: Data("{}".utf8))
        let oversizedSub = try await request(subPath, method: "POST", body: Data(repeating: 65, count: 4097))
        precondition(unauthSub.0 == 401 && patchSub.0 == 405 && malformedSub.0 == 400 && oversizedSub.0 == 413)
        let bad = try JSONSerialization.data(withJSONObject: [
            "installationID": UUID().uuidString, "serverID": UUID().uuidString,
            "environment": "development", "widgetToken": String(repeating: "A", count: 32),
        ])
        let badSub = try await request(subPath, method: "POST", body: bad)
        precondition(badSub.0 == 400)

        let installationID = UUID(), serverID = UUID()
        func subscriptionBody(_ extra: [String: Any] = [:], id: UUID = installationID) throws -> Data {
            var object: [String: Any] = [
                "installationID": id.uuidString,
                "serverID": serverID.uuidString,
                "environment": "development",
            ]
            for (key, value) in extra { object[key] = value }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let tokenValue = String(repeating: "a", count: 64)
        let posted = try await request(subPath, method: "POST", body: subscriptionBody([
            "widgetToken": tokenValue, "liveActivities": true,
        ]))
        precondition(posted.0 == 200 && posted.1["supportsWidgetPush"] as? Bool == true
                     && posted.1["supportsLiveActivities"] as? Bool == true)
        let cleared = try await request(subPath, method: "POST", body: subscriptionBody(["widgetToken": ""]))
        precondition(cleared.0 == 200)
        let removal = try JSONSerialization.data(withJSONObject: [
            "installationID": installationID.uuidString, "serverID": serverID.uuidString,
        ])
        let removed = try await request(subPath, method: "DELETE", body: removal)
        precondition(removed.0 == 200)

        for _ in 0..<64 {
            let added = try await request(subPath, method: "POST", body: subscriptionBody(id: UUID()))
            precondition(added.0 == 200)
        }
        let overLimit = try await request(subPath, method: "POST", body: subscriptionBody(id: UUID()))
        precondition(overLimit.0 == 409)
    }

    static func testRemoteLiveStatusPushes() async throws {
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        try await testLiveStatusAPNsLifecycle(configuration: configuration)
        try await testLiveStatusInvalidation(configuration: configuration)
        try await testLiveStatusRetry(configuration: configuration)
        try await testLiveStatusPayloadLimit(configuration: configuration)
        try await testLiveStatusInputRequests(configuration: configuration)
    }

    static func testLiveStatusInputRequests(configuration: RemotePushConfiguration) async throws {
        let clock = LiveStatusTestClock(Date(timeIntervalSince1970: 40_000))
        let recorder = LiveStatusRequestRecorder()
        let service = RemoteLiveStatus(
            file: liveStatusStateFile("input"),
            now: clock.now,
            sleep: { seconds in clock.advance(seconds) },
            configuration: { configuration },
            send: { await recorder.respond($0) }
        )
        await service.activate(fingerprint: "paired")
        let installationID = UUID(), serverID = UUID()
        let startToken = String(repeating: "1", count: 64)
        let activityToken = String(repeating: "2", count: 64)
        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": installationID.uuidString,
            "serverID": serverID.uuidString,
            "environment": "development",
            "startToken": startToken,
            "liveActivities": true,
        ]), fingerprint: "paired")
        let waitingID = UUID(), runningID = UUID()
        func snapshot(request: LiveStatusInput, step: String) -> LiveStatusSnapshot {
            LiveStatusSnapshot.build(from: [
                LiveStatusSession(id: runningID, title: "Tests", isStreaming: true, statusText: step,
                                  currentRunStartedAt: clock.now()),
                LiveStatusSession(id: waitingID, title: "Deploy", isStreaming: true,
                                  pendingInputs: [request], currentRunStartedAt: clock.now()),
            ], now: clock.now(), hostName: "Mac")
        }
        let approval = LiveStatusInput(title: "Run the deploy script?", kind: "approval")
        await service.update(snapshot(request: approval, step: "Compiling"))
        try await waitForLiveStatusRequests(recorder, atLeast: 1)
        let start = (await recorder.all())[0]
        precondition(start.url?.lastPathComponent == startToken)
        let startAPS = try aps(start)
        let alert = startAPS["alert"] as? [String: String]
        precondition(alert?["title"] == "Cantrip needs your response")
        precondition(alert?["body"] == "1 tab needs your response · 1 running")
        let startTabs = (startAPS["content-state"] as! [String: Any])["tabs"] as! [[String: Any]]
        precondition(startTabs[0]["id"] as? String == waitingID.uuidString && startTabs[0]["state"] as? String == "input")
        precondition(startTabs[0]["inputKind"] as? String == "approval")
        precondition(startTabs[0]["detail"] as? String == "Run the deploy script?")
        precondition(startTabs[1]["inputKind"] == nil)

        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": installationID.uuidString,
            "serverID": serverID.uuidString,
            "environment": "development",
            "activityToken": activityToken,
            "liveActivities": true,
        ]), fingerprint: "paired")
        await service.update(snapshot(request: approval, step: "Compiling"))
        try await waitForLiveStatusRequests(recorder, atLeast: 2)
        await service.update(snapshot(request: approval, step: "Linking"))
        try await Task.sleep(for: .milliseconds(20))
        let afterStep = await recorder.count()
        precondition(afterStep == 2, "A running tab's step change alone doesn't push")

        let question = LiveStatusInput(title: "Which environment?", kind: "question")
        await service.update(snapshot(request: question, step: "Linking"))
        try await waitForLiveStatusRequests(recorder, atLeast: 3)
        let update = (await recorder.all())[2]
        precondition(update.url?.lastPathComponent == activityToken && liveStatusEvent(update) == "update")
        precondition(update.value(forHTTPHeaderField: "apns-priority") == "10",
                     "A new request in a waiting tab pushes at high priority")
        let tabs = (try aps(update)["content-state"] as! [String: Any])["tabs"] as! [[String: Any]]
        precondition(tabs[0]["inputKind"] as? String == "question" && tabs[0]["detail"] as? String == "Which environment?")
    }

    static func testLiveStatusAPNsLifecycle(configuration: RemotePushConfiguration) async throws {
        let clock = LiveStatusTestClock(Date(timeIntervalSince1970: 10_000))
        let recorder = LiveStatusRequestRecorder()
        let service = RemoteLiveStatus(
            file: liveStatusStateFile("apns"),
            now: clock.now,
            sleep: { seconds in clock.advance(seconds) },
            configuration: { configuration },
            send: { await recorder.respond($0) }
        )
        await service.activate(fingerprint: "paired")
        let installationID = UUID(), serverID = UUID()
        let widgetToken = String(repeating: "a", count: 64)
        let startToken = String(repeating: "b", count: 64)
        let activityToken = String(repeating: "c", count: 64)
        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": installationID.uuidString,
            "serverID": serverID.uuidString,
            "environment": "development",
            "widgetToken": widgetToken,
            "startToken": startToken,
            "liveActivities": true,
        ]), fingerprint: "paired")

        let sessionID = UUID()
        var snapshot = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: sessionID, title: "Build", isStreaming: true, statusText: "Compiling",
            currentRunStartedAt: clock.now()
        )], now: clock.now(), hostName: "Test Mac")
        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 2)
        var requests = await recorder.all()
        let widget = requests.first { $0.value(forHTTPHeaderField: "apns-push-type") == "widgets" }!
        let start = requests.first { liveStatusEvent($0) == "start" }!
        precondition(widget.url?.host == "api.sandbox.push.apple.com")
        precondition(widget.url?.lastPathComponent == widgetToken)
        precondition(widget.value(forHTTPHeaderField: "apns-topic") == "com.itzhoang.hermbot.push-type.widgets")
        let widgetAPS = try aps(widget)
        precondition(widgetAPS["content-changed"] as? Bool == true)
        precondition(start.url?.lastPathComponent == startToken)
        precondition(start.value(forHTTPHeaderField: "apns-topic") == "com.itzhoang.hermbot.push-type.liveactivity")
        precondition(start.value(forHTTPHeaderField: "apns-priority") == "10")
        let startAPS = try aps(start)
        precondition(startAPS["attributes-type"] as? String == "CantripTabsAttributes")
        precondition((startAPS["attributes"] as? [String: Any])?["hostName"] as? String == "Test Mac")
        precondition((startAPS["alert"] as? [String: String])?["title"] == "Cantrip is working")
        precondition((startAPS["content-state"] as? [String: Any])?["running"] as? Int == 1)

        await service.update(snapshot)
        try await Task.sleep(for: .milliseconds(20))
        let startRepeatCount = await recorder.count()
        precondition(startRepeatCount == 2, "Live Activity start must not repeat without an activity token")

        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": installationID.uuidString,
            "serverID": serverID.uuidString,
            "environment": "development",
            "activityToken": activityToken,
            "activityID": "activity-1",
            "liveActivities": true,
        ]), fingerprint: "paired")
        snapshot = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: sessionID, title: "Build", isStreaming: true, statusText: "Linking",
            currentRunStartedAt: clock.now()
        )], now: clock.now(), hostName: "Test Mac")
        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 3)
        requests = await recorder.all()
        let update = requests.first { liveStatusEvent($0) == "update" }!
        precondition(update.url?.lastPathComponent == activityToken)
        precondition(update.value(forHTTPHeaderField: "apns-priority") == "10")
        let updateAPS = try aps(update)
        precondition(updateAPS["stale-date"] is Double)

        let changedTitle = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: sessionID, title: "Build renamed", isStreaming: true, statusText: "Linking",
            currentRunStartedAt: clock.now()
        )], now: clock.now(), hostName: "Test Mac")
        await service.update(changedTitle)
        try await waitForLiveStatusRequests(recorder, atLeast: 5)
        requests = await recorder.all()
        let widgets = requests.filter { $0.value(forHTTPHeaderField: "apns-push-type") == "widgets" }
        precondition(widgets.count >= 2, "Widget throttling must keep a trailing refresh")
        let lowPriorityUpdate = requests.last { liveStatusEvent($0) == "update" }!
        precondition(lowPriorityUpdate.value(forHTTPHeaderField: "apns-priority") == "5")

        let idle = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: sessionID, title: "Build", lastRunOutcome: .init(status: .done, finishedAt: clock.now())
        )], now: clock.now(), hostName: "Test Mac")
        await service.update(idle)
        try await waitForLiveStatusRequests(recorder, atLeast: 6)
        requests = await recorder.all()
        let end = requests.first { liveStatusEvent($0) == "end" }!
        precondition(end.url?.lastPathComponent == activityToken)
        let endAPS = try aps(end)
        precondition(endAPS["dismissal-date"] is Double)

        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 9)
        let restarted = await recorder.all()
        let endIndex = restarted.firstIndex { liveStatusEvent($0) == "end" }!
        precondition(restarted[(endIndex + 1)...].contains { $0.url?.lastPathComponent == startToken },
                     "Ending an activity clears its update token so the next work starts again")
    }

    static func testLiveStatusInvalidation(configuration: RemotePushConfiguration) async throws {
        let clock = LiveStatusTestClock(Date(timeIntervalSince1970: 20_000))
        let recorder = LiveStatusRequestRecorder(statuses: [410, 200])
        let service = RemoteLiveStatus(
            file: liveStatusStateFile("invalid"),
            now: clock.now,
            sleep: { seconds in clock.advance(seconds) },
            configuration: { configuration },
            send: { await recorder.respond($0) }
        )
        await service.activate(fingerprint: "paired")
        let widgetToken = String(repeating: "d", count: 64)
        let startToken = String(repeating: "e", count: 64)
        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": UUID().uuidString,
            "serverID": UUID().uuidString,
            "environment": "production",
            "widgetToken": widgetToken,
            "startToken": startToken,
            "liveActivities": true,
        ]), fingerprint: "paired")
        let snapshot = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: UUID(), title: "Work", isStreaming: true, currentRunStartedAt: clock.now()
        )], now: clock.now(), hostName: "Mac")
        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 2)
        let requests = await recorder.all()
        precondition(requests[0].url?.lastPathComponent == widgetToken)
        precondition(requests[1].url?.lastPathComponent == startToken,
                     "Invalidating the widget token must not clear the start token")
        let changed = LiveStatusSnapshot.build(from: [LiveStatusSession(
            id: UUID(), title: "Work 2", isStreaming: true, currentRunStartedAt: clock.now()
        )], now: clock.now(), hostName: "Mac")
        await service.update(changed)
        try await Task.sleep(for: .milliseconds(20))
        let invalidatedCount = await recorder.count()
        precondition(invalidatedCount == 2, "A 410 widget token is cleared individually")
    }

    static func testLiveStatusRetry(configuration: RemotePushConfiguration) async throws {
        let clock = LiveStatusTestClock(Date(timeIntervalSince1970: 25_000))
        let recorder = LiveStatusRequestRecorder(statuses: [500, 200])
        let service = RemoteLiveStatus(
            file: liveStatusStateFile("retry"),
            now: clock.now,
            sleep: { seconds in clock.advance(seconds) },
            configuration: { configuration },
            send: { await recorder.respond($0) }
        )
        await service.activate(fingerprint: "paired")
        let widgetToken = String(repeating: "a", count: 64)
        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": UUID().uuidString,
            "serverID": UUID().uuidString,
            "environment": "development",
            "widgetToken": widgetToken,
        ]), fingerprint: "paired")
        let snapshot = LiveStatusSnapshot.build(from: [LiveStatusSession(id: UUID(), title: "Retry")],
                                                now: clock.now(), hostName: "Mac")
        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 2)
        let requests = await recorder.all()
        precondition(requests.count == 2 && requests.allSatisfy { $0.url?.lastPathComponent == widgetToken },
                     "Transient APNs failures must retry the same token with backoff")
        precondition(clock.now().timeIntervalSince1970 >= 25_015)
    }

    static func testLiveStatusPayloadLimit(configuration: RemotePushConfiguration) async throws {
        let clock = LiveStatusTestClock(Date(timeIntervalSince1970: 30_000))
        let recorder = LiveStatusRequestRecorder()
        let service = RemoteLiveStatus(
            file: liveStatusStateFile("payload"),
            now: clock.now,
            sleep: { seconds in clock.advance(seconds) },
            configuration: { configuration },
            send: { await recorder.respond($0) }
        )
        await service.activate(fingerprint: "paired")
        try await service.merge(RemoteLiveStatusSubscriptionUpdate(json: [
            "installationID": UUID().uuidString,
            "serverID": UUID().uuidString,
            "environment": "development",
            "activityToken": String(repeating: "f", count: 64),
            "liveActivities": true,
        ]), fingerprint: "paired")
        let huge = String(repeating: "x", count: 5_000)
        let tabs = (0..<5).map { index in
            LiveStatusTab(id: UUID().uuidString, title: huge + "\(index)", state: .running,
                          startedAt: clock.now().timeIntervalSince1970, finishedAt: nil,
                          detail: huge, queued: 0, subagents: 0)
        }
        let snapshot = LiveStatusSnapshot(generatedAt: clock.now().timeIntervalSince1970,
                                          hostName: "Mac", running: 5, needsInput: 0, total: 5, tabs: tabs)
        await service.update(snapshot)
        try await waitForLiveStatusRequests(recorder, atLeast: 1)
        let request = (await recorder.all())[0]
        precondition(request.httpBody!.count <= 4096)
        let state = try aps(request)["content-state"] as! [String: Any]
        precondition((state["tabs"] as! [[String: Any]]).count < 5,
                     "Oversized Live Activity payloads drop tabs from the end")
    }

    private static func liveStatusStateFile(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/live-status-tests/\(name)-\(UUID().uuidString).json")
    }

    private static func waitForLiveStatusRequests(_ recorder: LiveStatusRequestRecorder, atLeast count: Int,
                                                  line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await recorder.count() < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalCount = await recorder.count()
        precondition(finalCount >= count, "Timed out waiting for live status push at line \(line)")
    }

    private static func aps(_ request: URLRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        return object["aps"] as! [String: Any]
    }

    private static func liveStatusEvent(_ request: URLRequest) -> String? {
        guard request.value(forHTTPHeaderField: "apns-push-type") == "liveactivity",
              let aps = try? aps(request) else { return nil }
        return aps["event"] as? String
    }
}
