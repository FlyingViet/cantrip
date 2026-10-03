import CryptoKit
import Foundation
import XCTest
@testable import Hermes

private final class NotificationTestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let (status, data) = try await XCTUnwrap(Self.handler)(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                                          httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripNotificationTests: XCTestCase {
    private let ready = Data(#"{"configured":true,"message":"Ready","lastDeliveryError":null}"#.utf8)
    private func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture(
        permission: Bool = true, authorize: ((String) async throws -> Void)? = nil
    ) throws -> (CantripRemoteModel, CantripNotifications, SavedServer, SavedServer, UserDefaults) {
        let suite = "CantripNotificationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var values: [String: String] = [:]
        let credentials = ServerCredentialStore(read: { values[$0] }, write: { values[$0] = $1 }, remove: { values[$0] = nil })
        let servers = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: credentials)
        let a = try servers.add(ServerDraft(name: "Mac A", url: "https://mac-a.example", credential: "paired-a", tailscaleOnly: true))
        let b = try servers.add(ServerDraft(name: "Mac B", url: "https://mac-b.example", credential: "paired-b", tailscaleOnly: true))
        try servers.select(a)
        let alerts = CantripNotifications(defaults: defaults, authorize: { permission }, requestRegistration: {})
        alerts.registered(Data(repeating: 0xab, count: 32))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationTestProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: session, servers: servers, completionAlerts: alerts,
                                       authorizeSensitiveAction: authorize ?? CantripBiometrics.authorize)
        let keys = ["cantrip.remote.base-url", "cantrip.remote.tailscale-only"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            session.invalidateAndCancel()
            NotificationTestProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        return (model, alerts, a, b, defaults)
    }

    private func target(server: SavedServer, session: UUID = UUID(), fingerprint: String = "paired-a") throws -> CantripNotificationTarget {
        try XCTUnwrap(CantripNotificationTarget(userInfo: [
            "cantrip": ["eventID": UUID().uuidString, "sessionID": session.uuidString,
                        "serverID": server.id.uuidString, "fingerprint": self.fingerprint(fingerprint)]
        ]))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEnableAndDisableArePairedPerServerAndPersistAfterAcknowledgement() async throws {
        let (model, alerts, a, b, defaults) = try fixture()
        var methods: [String] = []
        NotificationTestProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/notifications")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer paired-a")
            let method = try XCTUnwrap(request.httpMethod)
            methods.append(method)
            if method != "GET" {
                let body = try self.body(request)
                XCTAssertEqual(body["serverID"] as? String, a.id.uuidString)
                XCTAssertEqual(body["installationID"] as? String, alerts.installationID.uuidString)
                if method == "POST" {
                    XCTAssertFalse(alerts.isEnabled(serverID: a.id), "Wait for durable host acknowledgement")
                    XCTAssertEqual(body["deviceToken"] as? String, String(repeating: "ab", count: 32))
                    XCTAssertEqual(body["environment"] as? String, "development")
                    XCTAssertEqual(body["inputNeeded"] as? Bool, true)
                }
            }
            return (200, self.ready)
        }
        try await model.setCompletionNotifications(enabled: true)
        XCTAssertTrue(alerts.isEnabled(serverID: a.id))
        XCTAssertFalse(alerts.isEnabled(serverID: b.id))
        XCTAssertTrue(CantripNotifications(defaults: defaults).isEnabled(serverID: a.id))
        XCTAssertThrowsError(try model.removeServer(a), "Avoid leaving an active host subscription behind")
        try await model.setCompletionNotifications(enabled: false)
        XCTAssertFalse(alerts.isEnabled(serverID: a.id))
        XCTAssertEqual(methods, ["GET", "POST", "DELETE"])
    }

    func testProviderMissingPermissionDeniedAndOldHostDoNotEnable() async throws {
        let (model, alerts, a, _, _) = try fixture(permission: false)
        NotificationTestProtocol.handler = { _ in
            (200, Data(#"{"configured":false,"message":"Configure Apple push first.","lastDeliveryError":null}"#.utf8))
        }
        do {
            try await model.setCompletionNotifications(enabled: true)
            XCTFail("Missing APNs setup cannot look enabled")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Configure Apple push")) }
        NotificationTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Denied permission must not register on the host")
            return (200, self.ready)
        }
        do {
            try await model.setCompletionNotifications(enabled: true)
            XCTFail("Denied permission must remain disabled")
        } catch { XCTAssertTrue(error.localizedDescription.contains("iOS Settings")) }
        NotificationTestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await model.completionNotificationStatus()
            XCTFail("Old hosts need an update message")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Update and reopen")) }
        XCTAssertFalse(alerts.isEnabled(serverID: a.id))
    }

    func testFailedOptOutDoesNotPretendHostStoppedSending() async throws {
        let (model, alerts, a, _, _) = try fixture()
        alerts.save(serverID: a.id, fingerprint: fingerprint("paired-a"))
        NotificationTestProtocol.handler = { _ in (503, Data(#"{"error":"disk unavailable"}"#.utf8)) }
        do {
            try await model.setCompletionNotifications(enabled: false)
            XCTFail("Failed removal needs a visible retry")
        } catch {}
        XCTAssertTrue(alerts.isEnabled(serverID: a.id))
        XCTAssertFalse(model.isUpdatingNotifications)
    }

    func testUncertainEnableIsPersistedAndCanBeCancelled() async throws {
        let (model, alerts, a, _, defaults) = try fixture()
        NotificationTestProtocol.handler = { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, self.ready)
        }
        do {
            try await model.setCompletionNotifications(enabled: true)
            XCTFail("A lost response cannot confirm registration")
        } catch {}
        XCTAssertFalse(alerts.isEnabled(serverID: a.id))
        XCTAssertTrue(alerts.isPending(serverID: a.id))
        XCTAssertTrue(CantripNotifications(defaults: defaults).isPending(serverID: a.id))
        XCTAssertThrowsError(try model.removeServer(a))
        NotificationTestProtocol.handler = { _ in (200, self.ready) }
        try await model.setCompletionNotifications(enabled: false)
        XCTAssertFalse(alerts.hasSubscription(serverID: a.id))
    }

    func testTapSelectsCorrectSavedServerAndSessionWithoutSubmitting() async throws {
        let (model, _, _, b, _) = try fixture()
        let sessionID = UUID()
        var requests = 0
        NotificationTestProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "mac-b.example")
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(sessionID)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer paired-b")
            return (200, Data("""
            {"session":{"id":"\(sessionID)","title":"Finished tab","workdir":"/tmp",
            "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,"messages":[]}}
            """.utf8))
        }
        await model.openCompletionNotification(try target(server: b, session: sessionID, fingerprint: "paired-b"))
        XCTAssertEqual(model.selectedServerID, b.id)
        XCTAssertEqual(model.selectedSessionID, sessionID.uuidString)
        XCTAssertEqual(model.selectedSession?.title, "Finished tab")
        XCTAssertEqual(requests, 1)
        await model.openCompletionNotification(try target(server: b, fingerprint: "wrong-pairing"))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.errorMessage?.contains("re-paired") == true)
    }

    func testPayloadValidationAndOptOutGate() throws {
        let (_, alerts, a, b, _) = try fixture()
        XCTAssertNil(CantripNotificationTarget(userInfo: [:]))
        XCTAssertNil(CantripNotificationTarget(userInfo: ["cantrip": ["eventID": "../bad"]]))
        let destination = try target(server: a)
        XCTAssertFalse(alerts.accepts(destination))
        alerts.save(serverID: a.id, fingerprint: destination.fingerprint)
        XCTAssertTrue(alerts.accepts(destination))
        XCTAssertFalse(alerts.accepts(try target(server: b)))
        XCTAssertFalse(alerts.accepts(try target(server: a, fingerprint: "rotated")))
        alerts.save(serverID: a.id, fingerprint: nil)
        XCTAssertFalse(alerts.accepts(destination))
    }

    func testMacAttentionOpensPermissionsWithoutStartingViewerOrInput() async throws {
        let (model, _, a, _, _) = try fixture()
        let sessionID = UUID()
        NotificationTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(sessionID)")
            return (200, Data("""
            {"session":{"id":"\(sessionID)","title":"Tab","workdir":"/tmp","isStreaming":false,
             "canResume":false,"councilMode":false,"queuedCount":0,"messages":[]}}
            """.utf8))
        }
        let target = try XCTUnwrap(CantripNotificationTarget(userInfo: [
            "cantrip": ["kind": "macAttention", "eventID": UUID().uuidString, "sessionID": sessionID.uuidString,
                        "serverID": a.id.uuidString, "fingerprint": fingerprint("paired-a")]
        ]))
        await model.openCompletionNotification(target)
        XCTAssertTrue(model.showingMacAccess)
        XCTAssertNil(model.inputRequestsSession)
    }

    func testInputNotificationOpensChatWithoutQuestionModal() async throws {
        let (model, _, a, _, _) = try fixture()
        let sessionID = UUID(), requestID = UUID()
        let navigation = model.notificationNavigationID
        NotificationTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("""
            {"session":{"id":"\(sessionID)","title":"Needs input","workdir":"/tmp","isStreaming":true,
             "canResume":false,"councilMode":false,"queuedCount":0,"messages":[],"pendingInputCount":1,
             "pendingInputs":[{"id":"\(requestID)","kind":"question","title":"Which file?","source":"fixture",
              "detail":"Reply in chat","choices":[],"allowsFreeform":true,"expiresAt":9999999999}]}}
            """.utf8))
        }
        let target = try XCTUnwrap(CantripNotificationTarget(userInfo: [
            "cantrip": ["kind": "input", "eventID": requestID.uuidString, "sessionID": sessionID.uuidString,
                        "serverID": a.id.uuidString, "fingerprint": fingerprint("paired-a")]
        ]))
        await model.openCompletionNotification(target)
        XCTAssertEqual(model.selectedSessionID, sessionID.uuidString)
        XCTAssertEqual(model.chatInputRequest?.id, requestID)
        XCTAssertNil(model.inputRequestsSession)
        XCTAssertFalse(model.showingMacAccess)
        XCTAssertNotEqual(model.notificationNavigationID, navigation)
    }

    // MARK: - Home background run requests

    private let runSession = "40000000-0000-0000-0000-000000000021"
    private let runRequest = "50000000-0000-0000-0000-000000000021"
    private let followUpTask = "10000000-0000-0000-0000-000000000009"

    private func homeSession(waiting: Bool) -> Data {
        Data("""
        {"session":{"id":"\(CantripHomeIdentity.sessionID)","title":"Cantrip Home","workdir":"/tmp",
         "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,"messages":[],
         "isCantripHome":true,"isLocked":true,"supportsBackgroundRuns":true,"backgroundActiveCount":1,
         "backgroundInputCount":\(waiting ? 1 : 0)}}
        """.utf8)
    }

    private func background(waiting: Bool) -> Data {
        let started = Date().timeIntervalSinceReferenceDate.rounded(.down) - 60
        let inputs = waiting ? """
        ,"inputs":[{"id":"\(runRequest)","kind":"approval","source":"Cantrip Home",
          "title":"Daily follow-up tracker wants to send a message","detail":"messages-send '+15551234567' 'On my way'",
          "choices":[],"allowsFreeform":false,"expiresAt":9999999999}]
        """ : ""
        return Data("""
        {"sessionID":"231C484E-0E50-43E0-9ADF-4295F3AC8956","revision":"b1","maxParallel":3,"runningCount":1,
         "supportsStop":true,"queued":[],
         "runs":[{"id":"30000000-0000-0000-0000-000000000021","kind":"task","label":"Daily follow-up tracker",
           "taskID":"\(followUpTask)","startedAt":\(started),"status":"running","summary":"","route":"hidden",
           "canStop":true,"sessionID":"\(runSession)","handoffs":[],
           "activity":"\(waiting ? "Needs your input" : "Sending the message")"\(inputs)}]}
        """.utf8)
    }

    func testHomeRunInputPushOpensHomeAndIsAnsweredInPlace() async throws {
        var authorizations = 0
        let (model, _, a, _, _) = try fixture(authorize: { _ in authorizations += 1 })
        var waiting = true
        var requests: [(method: String, path: String, body: [String: Any])] = []
        NotificationTestProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body = request.httpMethod == "POST" ? ((try? self.body(request)) ?? [:]) : [:]
            requests.append((request.httpMethod ?? "GET", path, body))
            switch path {
            case "/api/v1/home": return (200, self.homeSession(waiting: waiting))
            case "/api/v1/home/tasks": return (200, Data(#"{"tasks":[],"revision":"r"}"#.utf8))
            case "/api/v1/home/artifacts": return (200, Data(#"{"artifacts":[],"revision":"r"}"#.utf8))
            case "/api/v1/home/background": return (200, self.background(waiting: waiting))
            case "/api/v1/sessions/\(self.runSession)/input":
                return (200, Data(waiting ? """
                {"requests":[{"id":"\(self.runRequest)","kind":"approval","source":"Cantrip Home",
                  "title":"Daily follow-up tracker wants to send a message","detail":"messages-send",
                  "choices":[],"allowsFreeform":false,"expiresAt":9999999999}]}
                """.utf8 : #"{"requests":[]}"#.utf8))
            case "/api/v1/sessions/\(self.runSession)/input/\(self.runRequest)":
                waiting = false
                return (200, Data(#"{"accepted":true}"#.utf8))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        let payload: [String: String] = [
            "kind": "input", "home": "run", "eventID": runRequest, "sessionID": runSession,
            "serverID": a.id.uuidString, "fingerprint": fingerprint("paired-a"),
        ]
        let target = try XCTUnwrap(CantripNotificationTarget(userInfo: ["cantrip": payload]))
        XCTAssertTrue(target.isHomeRun)
        var ordinary = payload
        ordinary["home"] = nil
        XCTAssertFalse(try XCTUnwrap(CantripNotificationTarget(userInfo: ["cantrip": ordinary])).isHomeRun)

        let navigation = model.notificationNavigationID
        await model.openHomeRunNotification(target)
        XCTAssertTrue(model.isHomeSelected, "A background run's push opens Home, not Cantrip Remote")
        XCTAssertEqual(model.selectedSessionID, CantripHomeIdentity.sessionID)
        XCTAssertEqual(model.homeBackgroundFocus, runSession, "The Background list opens on that run")
        XCTAssertNotEqual(model.notificationNavigationID, navigation)
        XCTAssertFalse(requests.contains { $0.path == "/api/v1/sessions/\(runSession)" },
                       "The hidden run's session is never opened as a tab")
        let run = try XCTUnwrap(model.homeBackground?.runs.first)
        XCTAssertTrue(run.needsInput)
        XCTAssertEqual(run.inputs?.first?.title, "Daily follow-up tracker wants to send a message")
        XCTAssertEqual(CantripHomeTasksView.waitingRuns(model.homeBackground)[UUID(uuidString: followUpTask)!], runSession,
                       "Tasks shows which task's run waits, and opens it")
        XCTAssertEqual(model.selectedSession?.backgroundInputCount, 1)

        let request = try XCTUnwrap(run.inputs?.first)
        let accepted = await model.respondToInput(sessionID: runSession, id: request.id,
                                                  answer: CantripInputAnswer(decision: "approve"),
                                                  identity: model.usageIdentity)
        XCTAssertTrue(accepted, model.errorMessage ?? "")
        XCTAssertEqual(authorizations, 1, "Approving still asks for Face ID")
        let answer = try XCTUnwrap(requests.last { $0.method == "POST" })
        XCTAssertEqual(answer.path, "/api/v1/sessions/\(runSession)/input/\(runRequest)")
        XCTAssertEqual(answer.body["decision"] as? String, "approve")
        await model.refreshHomeBackground()
        XCTAssertEqual(model.homeBackground?.runs.first?.needsInput, false, "The answered run continues")
        XCTAssertNil(model.homeBackground?.runs.first?.inputs)
        XCTAssertTrue(CantripHomeTasksView.waitingRuns(model.homeBackground).isEmpty)
    }

    func testOpenedHiddenRunStaysSelectedWhilePollingUntilItFinishes() async throws {
        let (model, _, a, _, _) = try fixture()
        let tab = "60000000-0000-0000-0000-000000000001"
        var finished = false
        NotificationTestProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/sessions" {
                return (200, Data("""
                {"sessions":[{"id":"\(tab)","title":"Bass Compass","workdir":"/tmp","isStreaming":false,
                 "canResume":false,"councilMode":false,"queuedCount":0,"historyRevision":"t1"}]}
                """.utf8))
            }
            if path == "/api/v1/sessions/\(self.runSession)" {
                if finished { return (404, Data(#"{"error":"session not found"}"#.utf8)) }
                return (200, Data("""
                {"session":{"id":"\(self.runSession)","title":"Cantrip Home background","workdir":"/tmp",
                 "isStreaming":true,"canResume":false,"councilMode":false,"queuedCount":0,"messages":[],
                 "isLocked":true,"isCantripHomeBackground":true,"historyRevision":"h1"}}
                """.utf8))
            }
            return (200, Data("""
            {"session":{"id":"\(tab)","title":"Bass Compass","workdir":"/tmp","isStreaming":false,
             "canResume":false,"councilMode":false,"queuedCount":0,"messages":[],"historyRevision":"t1"}}
            """.utf8))
        }
        try await model.selectServer(a)
        model.setAppActive(true)
        await model.refreshNow()
        XCTAssertEqual(model.selectedSessionID, tab, model.errorMessage ?? model.detailError ?? "")
        model.prepareToOpenHomeRun(sessionID: runSession)
        await model.selectRegularSession()
        XCTAssertEqual(model.selectedSessionID, runSession)
        for _ in 0..<3 { await model.refreshNow() }
        XCTAssertEqual(model.selectedSessionID, runSession,
                       "Polling keeps an opened hidden run instead of jumping to the first tab")
        finished = true
        await model.refreshNow()
        for _ in 0..<50 where model.detailError == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.detailError, "This background run has finished. Its report is in Home's Background list.")
        await model.refreshNow()
        XCTAssertEqual(model.selectedSessionID, tab, "A finished run falls back to the tabs")
    }
}
