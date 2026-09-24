import Foundation
import XCTest
@testable import Hermes

private final class MaintenanceRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                    statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripMaintenanceTests: XCTestCase {
    private let revision = UUID()
    private func data(accepted: [UUID] = [], busy: Int = 0, dirty: Bool = false,
                      branch: String = "main", running: Bool = false) throws -> Data {
        var value: [String: Any] = [
            "revision": revision.uuidString, "available": true, "runningBuild": "old", "installedBuild": "new",
            "busySessions": busy, "branch": branch, "localChanges": dirty,
            "acceptedRequestIDs": accepted.map(\.uuidString),
        ]
        if running {
            value["job"] = [
                "request": ["id": (accepted.first ?? UUID()).uuidString, "action": "rebuild", "revision": revision.uuidString],
                "phase": "building", "message": "Building...", "output": "Progress", "startedAt": 123,
            ]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func snapshot(accepted: [UUID] = [], busy: Int = 0, dirty: Bool = false,
                          branch: String = "main", running: Bool = false) throws -> CantripMaintenanceSnapshot {
        try JSONDecoder().decode(CantripMaintenanceSnapshot.self,
            from: data(accepted: accepted, busy: busy, dirty: dirty, branch: branch, running: running))
    }

    private func defaults() -> UserDefaults {
        let suite = "maintenance-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MaintenanceRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            MaintenanceRequestProtocol.handler = nil
        }
        return client
    }

    func testPairedReadsAndFixedActionPayload() async throws {
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                                  token: "maintenance-test", urlSession: client())
        let action = CantripMaintenanceRequest(id: UUID(), action: .update, revision: revision)
        var methods: [String] = []
        MaintenanceRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.url?.path, "/api/v1/maintenance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer maintenance-test")
            XCTAssertEqual(request.timeoutInterval, request.httpMethod == "GET" ? 20 : 12)
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = stream.read(&bytes, maxLength: bytes.count)
                XCTAssertGreaterThan(count, 0)
                let sent = try JSONDecoder().decode(CantripMaintenanceRequest.self, from: Data(bytes.prefix(count)))
                XCTAssertEqual(sent, action)
                return (202, try self.data(accepted: [action.id], running: true))
            }
            return (200, try self.data())
        }
        _ = try await api.maintenance()
        let response = try await api.maintenance(action)
        XCTAssertEqual(response.job?.request.id, action.id)
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testUnsupportedAndUnauthorizedHostsRemainDistinct() async throws {
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                                  token: "maintenance-test", urlSession: client())
        MaintenanceRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do { _ = try await api.maintenance(); XCTFail("Old hosts need a bootstrap message") }
        catch CantripRemoteError.maintenanceUnsupported {}
        MaintenanceRequestProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do { _ = try await api.maintenance(); XCTFail("Pairing errors must surface") }
        catch CantripRemoteError.authentication {}
    }

    func testUncertainWriteIsPersistedAndRetryReusesID() async throws {
        let defaults = defaults(), server = UUID()
        let model = CantripMaintenanceModel(serverID: server, defaults: defaults)
        await model.refresh { try self.snapshot() }
        var sent: CantripMaintenanceRequest?
        await model.submit(.rebuild) { request in
            sent = request
            throw CantripRemoteError.transport("Connection lost")
        }
        XCTAssertEqual(model.pending, sent)
        XCTAssertNotNil(model.error)
        let recovered = CantripMaintenanceModel(serverID: server, defaults: defaults)
        XCTAssertEqual(recovered.pending, sent)
        XCTAssertNil(CantripMaintenanceModel(serverID: UUID(), defaults: defaults).pending)
        await recovered.submit(.rebuild) { request in
            XCTAssertEqual(request, sent)
            return try self.snapshot(accepted: [request.id], running: true)
        }
        XCTAssertNil(recovered.pending)
        XCTAssertNil(CantripMaintenanceModel(serverID: server, defaults: defaults).pending)
        XCTAssertFalse(recovered.canStart(.rebuild))
    }

    func testReadReconcilesLostAcknowledgementWithoutResubmitting() async throws {
        let model = CantripMaintenanceModel(serverID: UUID(), defaults: defaults())
        await model.refresh { try self.snapshot() }
        var sends = 0
        await model.submit(.update) { _ in
            sends += 1
            throw CantripRemoteError.invalidResponse
        }
        let id = try XCTUnwrap(model.pending?.id)
        await model.refresh { try self.snapshot(accepted: [id], running: true) }
        XCTAssertNil(model.pending)
        XCTAssertNil(model.error)
        XCTAssertEqual(sends, 1)
    }

    func testCancelledWriteStillNeedsRecovery() async throws {
        let model = CantripMaintenanceModel(serverID: UUID(), defaults: defaults())
        await model.refresh { try self.snapshot() }
        await model.submit(.restart) { _ in throw CancellationError() }
        XCTAssertNotNil(model.pending)
        await model.refresh { try self.snapshot() }
        XCTAssertNotNil(model.pending, "An absent receipt does not justify automatically issuing a new ID")
    }

    func testDefinitiveRejectionClearsPendingButKeepsError() async throws {
        let model = CantripMaintenanceModel(serverID: UUID(), defaults: defaults())
        await model.refresh { try self.snapshot() }
        await model.submit(.rebuild) { _ in throw CantripRemoteError.http(409, "Busy Mac tabs") }
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.error?.contains("Busy Mac tabs") == true)
        XCTAssertFalse(model.canStart(.rebuild))
    }

    func testBusyDirtyAndStaleStatusDisableUnsafeActions() async throws {
        let model = CantripMaintenanceModel(serverID: UUID(), defaults: defaults())
        await model.refresh { try self.snapshot(busy: 1) }
        XCTAssertTrue(model.canStart(.check))
        XCTAssertFalse(model.canStart(.restart))
        XCTAssertFalse(model.canStart(.rebuild))
        await model.refresh { try self.snapshot(dirty: true) }
        XCTAssertFalse(model.canStart(.update))
        XCTAssertTrue(model.canStart(.rebuild))
        await model.refresh { try self.snapshot(branch: "work") }
        XCTAssertFalse(model.canStart(.update))
        await model.refresh { throw CantripRemoteError.transport("Offline") }
        XCTAssertNotNil(model.snapshot)
        XCTAssertFalse(model.canStart(.restart))
    }

    func testHostActionIsPreparedButAmbiguousPostIsNeverReplayed() async throws {
        let remote = CantripRemoteModel(urlSession: client())
        let configured = await remote.configure(url: "https://cantrip.example",
            pairingToken: "maintenance-test", tailscaleOnly: true)
        XCTAssertTrue(configured)
        defer { remote.setAppActive(false); remote.clearConfiguration() }
        var methods: [String] = []
        MaintenanceRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, try self.data())
        }
        do {
            _ = try await remote.startMaintenance(CantripMaintenanceRequest(id: UUID(), action: .restart, revision: revision))
            XCTFail("Lost acknowledgement must surface")
        } catch {}
        XCTAssertEqual(methods, ["GET", "POST"])
    }
}
