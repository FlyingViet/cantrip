#if os(iOS) && canImport(WatchConnectivity)
import CryptoKit
import XCTest
@testable import Hermes

private final class WatchRegistrationProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> (Int, Data))?
    static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request, body)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@MainActor
final class CantripWatchLinkTests: XCTestCase {
    private var credentials: [String: String] = [:]
    private let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()

    override func setUp() {
        WatchRegistrationProtocol.requests = []
        WatchRegistrationProtocol.handler = nil
        credentials = [:]
    }

    private func makeServers(url: String?, directAddress: String = "") throws -> ServerProfiles {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CantripWatchLinkTests.\(UUID().uuidString)"))
        let servers = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: ServerCredentialStore(
            read: { [unowned self] in self.credentials[$0] },
            write: { [unowned self] in self.credentials[$0] = $1 },
            remove: { [unowned self] in self.credentials[$0] = nil }
        ))
        if let url {
            let server = try servers.add(ServerDraft(
                name: "Studio Mac", url: url, credential: "test-pairing-token", directAddress: directAddress
            ))
            try servers.select(server)
        }
        return servers
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchRegistrationProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testRegistersTheWatchWithTheSelectedMac() async throws {
        WatchRegistrationProtocol.handler = { _, _ in
            (201, Data("""
            {"device": {"id": "6F1C2A4E-0000-4000-8000-000000000001", "name": "Apple Watch",
             "addedAt": "2026-11-01T19:00:00Z", "lastUsedAt": null},
             "internet": "https://mac.example.ts.net:10000"}
            """.utf8))
        }
        let reply = await CantripWatchRegistration.register(
            name: "  Apple   Watch ", publicKey: publicKey,
            servers: try makeServers(url: "https://mac.example.ts.net"), session: session
        )
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["deviceID"] as? String, "6F1C2A4E-0000-4000-8000-000000000001")
        XCTAssertEqual(reply["tailnet"] as? String, "https://mac.example.ts.net")
        XCTAssertEqual(reply["internet"] as? String, "https://mac.example.ts.net:10000")
        XCTAssertEqual(reply["server"] as? String, "Studio Mac")

        let (request, body) = try XCTUnwrap(WatchRegistrationProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://mac.example.ts.net/api/v1/watch/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["name": "Apple Watch", "publicKey": publicKey])
    }

    func testInternetRouteIsLeftOutWhenOff() async throws {
        WatchRegistrationProtocol.handler = { _, _ in
            (200, Data(#"{"device": {"id": "D1", "name": "Apple Watch"}, "internet": null}"#.utf8))
        }
        let reply = await CantripWatchRegistration.register(
            name: "Apple Watch", publicKey: publicKey,
            servers: try makeServers(url: "https://mac.example.ts.net"), session: session
        )
        XCTAssertEqual(reply["deviceID"] as? String, "D1")
        XCTAssertNil(reply["internet"])
    }

    func testNeedsAnHTTPSPairingFirst() async throws {
        for servers in [try makeServers(url: nil), try makeServers(url: "", directAddress: "192.168.0.10:8766")] {
            let reply = await CantripWatchRegistration.register(
                name: "Apple Watch", publicKey: publicKey, servers: servers, session: session
            )
            XCTAssertEqual(reply["error"] as? String,
                           "Pair Cantrip on this iPhone with your Mac over Tailscale first, then set up the watch again.")
        }
        XCTAssertTrue(WatchRegistrationProtocol.requests.isEmpty)
    }

    func testPlainErrors() async throws {
        let servers = try makeServers(url: "https://mac.example.ts.net")
        let badKey = await CantripWatchRegistration.register(
            name: "Apple Watch", publicKey: "bm90LWEta2V5", servers: servers, session: session
        )
        XCTAssertEqual(badKey["error"] as? String, "Update Cantrip on your watch, then try again.")

        WatchRegistrationProtocol.handler = { _, _ in (401, Data(#"{"error": "Unauthorized"}"#.utf8)) }
        let rejected = await CantripWatchRegistration.register(
            name: "Apple Watch", publicKey: publicKey, servers: servers, session: session
        )
        XCTAssertEqual(rejected["error"] as? String,
                       "Studio Mac didn't accept this iPhone's pairing. Pair Cantrip on the iPhone again, then set up the watch.")

        WatchRegistrationProtocol.handler = { _, _ in throw URLError(.cannotConnectToHost) }
        let offline = await CantripWatchRegistration.register(
            name: "Apple Watch", publicKey: publicKey, servers: servers, session: session
        )
        XCTAssertEqual(offline["error"] as? String,
                       "Your iPhone can't reach Studio Mac. Check that Tailscale is on, then try again.")
    }
}
#endif
