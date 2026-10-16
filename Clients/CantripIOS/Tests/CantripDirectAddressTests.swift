import Foundation
import Network
import XCTest
@testable import Hermes

/// A stand-in for a Mac's pinned TLS-PSK listener, reached only by host:port (no Bonjour).
private final class DirectTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cantrip-direct-address-test")
    // Accessed only on `queue`.
    private var connections: [NWConnection] = []
    private var requestPaths: [String] = []

    init(token: String) throws {
        let parameters = CantripLANProtocol.parameters(token: token)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var paths: [String] { queue.sync { requestPaths } }

    func start() async throws -> NWEndpoint.Port {
        let ready = AsyncStream<NWEndpoint.Port?> { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.yield(listener.port); continuation.finish()
                case .failed, .cancelled: continuation.yield(nil); continuation.finish()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        for await port in ready { return try XCTUnwrap(port, "Test TLS-PSK listener failed") }
        throw XCTSkip("Listener never reported a state")
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            guard let end = next.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete, error == nil { self.receive(on: connection, buffer: next) }
                return
            }
            let head = String(decoding: next[..<end.lowerBound], as: UTF8.self)
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = target.split(separator: "?").first.map(String.init) ?? target
            self.requestPaths.append(path)
            let (status, body) = path == "/api/v1/sessions"
                ? ("200 OK", #"{"sessions":[]}"#)
                : ("404 Not Found", #"{"error":"not found"}"#)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in })
        }
    }
}

/// Fails every HTTPS request as an unreachable Tailscale route would.
private final class UnreachableTailscaleProtocol: URLProtocol {
    nonisolated(unsafe) static var hits = 0
    nonisolated(unsafe) static var healthy = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.hits += 1
        guard Self.healthy, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"sessions":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class CantripDirectAddressTests: XCTestCase {
    func testDirectAddressesNormalizeAndRejectAnythingButHostAndPort() throws {
        XCTAssertNil(try CantripDirectAddress.normalized("  "))
        XCTAssertEqual(try CantripDirectAddress.normalized(" 192.168.0.152:8766 "), "192.168.0.152:8766")
        XCTAssertEqual(try CantripDirectAddress.normalized("Work-Laptop.local:8766"), "work-laptop.local:8766")
        XCTAssertEqual(try CantripDirectAddress.normalized("[FE80::1%en0]:8766"), "[fe80::1%en0]:8766")
        for bad in ["192.168.0.152", "192.168.0.152:", ":8766", "192.168.0.152:0", "192.168.0.152:70000",
                    "https://192.168.0.152:8766", "192.168.0.152:8766/api", "a b:1", "fe80::1:8766",
                    "192.168.0.152:87a6"] {
            XCTAssertThrowsError(try CantripDirectAddress.normalized(bad), bad)
        }
        XCTAssertEqual(CantripDirectAddress.endpoint("192.168.0.152:8766"),
                       .hostPort(host: "192.168.0.152", port: 8766))
        XCTAssertNil(CantripDirectAddress.endpoint(nil))
    }

    func testCantripProfilesSaveDirectAddressesAndOlderProfilesStillDecode() throws {
        let suite = "CantripDirectAddressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var secrets: [String: String] = [:]
        let credentials = ServerCredentialStore(read: { secrets[$0] }, write: { secrets[$0] = $1 },
                                                remove: { secrets[$0] = nil })
        let store = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: credentials)
        let laptop = try store.add(ServerDraft(name: "Work laptop", credential: "laptop-token",
                                               directAddress: " 192.168.0.152:8766 "))
        XCTAssertEqual(laptop.directAddress, "192.168.0.152:8766")
        XCTAssertEqual(laptop.url, "")
        XCTAssertEqual(laptop.address, "Direct 192.168.0.152:8766")
        let unnamed = try store.add(ServerDraft(credential: "other-token", directAddress: "10.0.0.2:8766"))
        XCTAssertEqual(unnamed.name, "10.0.0.2:8766")
        let both = try store.add(ServerDraft(url: "https://mini.example", credential: "mini-token",
                                             directAddress: "192.168.0.94:8766"))
        XCTAssertEqual(both.address, "https://mini.example · Direct 192.168.0.94:8766")
        // A Bonjour-only profile is still distinct from one with a direct address.
        _ = try store.add(ServerDraft(name: "LAN", credential: "lan-token"))
        XCTAssertThrowsError(try store.add(ServerDraft(credential: "laptop-token", directAddress: "192.168.0.152:8766")),
                             "The same direct address with the same token is a duplicate")
        XCTAssertThrowsError(try store.add(ServerDraft(credential: "x-token", directAddress: "192.168.0.152")))
        XCTAssertEqual(store.servers.count, 4, "A rejected address must not save a profile")

        let restored = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.servers.first?.directAddress, "192.168.0.152:8766")
        XCTAssertEqual(try restored.credential(for: laptop), "laptop-token")

        let hermes = ServerProfiles(kind: .hermes, defaults: defaults, credentials: credentials)
        let agent = try hermes.add(ServerDraft(url: "https://agent.example", credential: "k",
                                               directAddress: "192.168.0.152:8766"))
        XCTAssertNil(agent.directAddress, "Only Cantrip servers have a TLS-PSK listener")

        let legacy = Data(#"""
        [{"id":"\#(UUID().uuidString)","name":"Mac mini","url":"https://mini.example",
          "tailscaleOnly":false,"usesLegacyHistory":false}]
        """#.utf8)
        let decoded = try JSONDecoder().decode([SavedServer].self, from: legacy)
        XCTAssertNil(decoded.first?.directAddress, "Profiles saved by older builds keep decoding")
        XCTAssertEqual(decoded.first?.address, "https://mini.example")
    }

    func testDirectOnlyProfileConnectsOverTLSPSKWithoutBonjour() async throws {
        let token = "direct-address-test-token"
        let server = try DirectTLSServer(token: token)
        let port = try await server.start()
        defer { server.stop() }
        let model = CantripRemoteModel()
        let configured = await model.configure(url: "", pairingToken: token,
                                               directAddress: "127.0.0.1:\(port.rawValue)")
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
        }
        XCTAssertTrue(model.isConfigured, "A direct address alone is enough to connect")
        XCTAssertEqual(model.directAddress, "127.0.0.1:\(port.rawValue)")
        model.setAppActive(true)
        try await waitUntil { model.isConnected }
        XCTAssertEqual(model.endpointHost, "127.0.0.1:\(port.rawValue)")
        XCTAssertTrue(server.paths.contains("/api/v1/sessions"))

        let endpoint = try XCTUnwrap(CantripDirectAddress.endpoint("127.0.0.1:\(port.rawValue)"))
        do {
            _ = try await CantripRemoteAPI(transport: .lan(endpoint), token: "not-the-pairing-token").sessions()
            XCTFail("A different pairing token must fail the TLS-PSK handshake")
        } catch {
            XCTAssertTrue(CantripRemoteError.isRouteFailure(error))
        }
    }

    func testTailscaleStaysFirstAndTheDirectAddressTakesOverWhenItIsUnreachable() async throws {
        let token = "direct-fallback-test-token"
        let server = try DirectTLSServer(token: token)
        let port = try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnreachableTailscaleProtocol.self]
        let client = URLSession(configuration: configuration)
        UnreachableTailscaleProtocol.hits = 0
        UnreachableTailscaleProtocol.healthy = true
        let model = CantripRemoteModel(urlSession: client)
        // Tailscale-only still uses an explicitly saved direct address; it only skips Bonjour.
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: token,
                                               tailscaleOnly: true,
                                               directAddress: "127.0.0.1:\(port.rawValue)")
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
        }
        model.setAppActive(true)
        try await waitUntil { model.isConnected }
        XCTAssertGreaterThan(UnreachableTailscaleProtocol.hits, 0)
        XCTAssertTrue(server.paths.isEmpty, "A healthy Tailscale route never touches the direct address")
        XCTAssertEqual(model.endpointHost, "cantrip.example")

        UnreachableTailscaleProtocol.healthy = false
        let configuredAgain = await model.configure(url: "https://cantrip.example", pairingToken: token,
                                                    tailscaleOnly: true,
                                                    directAddress: "127.0.0.1:\(port.rawValue)")
        XCTAssertTrue(configuredAgain)
        let failedBefore = UnreachableTailscaleProtocol.hits
        await model.refreshNow()
        try await waitUntil { model.isConnected && model.endpointHost == "127.0.0.1:\(port.rawValue)" }
        XCTAssertGreaterThan(UnreachableTailscaleProtocol.hits, failedBefore, "Tailscale is tried first")
        XCTAssertTrue(server.paths.contains("/api/v1/sessions"))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition never became true", file: file, line: line)
    }
}
