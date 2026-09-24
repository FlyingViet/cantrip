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

    private func fixture(permission: Bool = true) throws -> (CantripRemoteModel, CantripNotifications, SavedServer, SavedServer, UserDefaults) {
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
        let model = CantripRemoteModel(urlSession: session, servers: servers, completionAlerts: alerts)
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

    private func body(_ request: URLRequest) throws -> [String: String] {
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
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
                XCTAssertEqual(body["serverID"], a.id.uuidString)
                XCTAssertEqual(body["installationID"], alerts.installationID.uuidString)
                if method == "POST" {
                    XCTAssertFalse(alerts.isEnabled(serverID: a.id), "Wait for durable host acknowledgement")
                    XCTAssertEqual(body["deviceToken"], String(repeating: "ab", count: 32))
                    XCTAssertEqual(body["environment"], "development")
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
}
