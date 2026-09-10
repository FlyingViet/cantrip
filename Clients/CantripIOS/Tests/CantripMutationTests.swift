import Foundation
import XCTest
@testable import Hermes

private final class MutationRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let (status, data) = try XCTUnwrap(Self.handler)(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
}

@MainActor
final class CantripMutationTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    private func snapshot(capabilities: Bool = true, list: Bool = false) -> Data {
        let session = """
        {"id":"\(sessionID)","title":"Test","workdir":"/tmp",
         "isStreaming":true,"canResume":true,"councilMode":false,"queuedCount":1,
         "supportsAutoDelivery":\(capabilities),"supportsImageAttachments":\(capabilities),
         "supportsTabMetadata":\(capabilities),"supportsQueueRemoval":\(capabilities),
         "messages":[]}
        """
        return Data((list ? "{\"sessions\":[\(session)]}" : "{\"session\":\(session)}").utf8)
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MutationRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "unit-mutation-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            MutationRequestProtocol.handler = nil
        }
        return model
    }

    func testAllDeliveryModesRecoverFromCooldownBeforePostingOnce() async throws {
        for mode in CantripDeliveryMode.allCases {
            for withImages in [false, true] {
                let model = try await model()
                let response = snapshot()
                MutationRequestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
                await model.selectSession(sessionID)
                XCTAssertNotNil(model.errorMessage)

                var methods: [String] = []
                MutationRequestProtocol.handler = { request in
                    methods.append(request.httpMethod ?? "")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-mutation-token")
                    if request.httpMethod == "POST" {
                        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/messages")
                        XCTAssertEqual(request.timeoutInterval, 12)
                    } else {
                        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
                        XCTAssertEqual(request.timeoutInterval, 3)
                    }
                    return (200, response)
                }
                let sent = await model.send(
                    "Hello", mode: mode,
                    images: withImages ? [ChatImageAttachment(data: Data([1, 2, 3]))] : [],
                    sessionID: sessionID
                )
                XCTAssertTrue(sent, model.errorMessage ?? "Expected recovered send")
                XCTAssertNil(model.errorMessage)
                XCTAssertEqual(methods, ["GET", "POST"], "Reuse preparation rather than reading twice")
                XCTAssertEqual(model.selectedSession?.id, sessionID)
                model.clearConfiguration()
            }
        }
    }

    func testReadFailureIsNotReportedAsPossibleDeliveryAndNextSendCanRecover() async throws {
        let model = try await model()
        var methods: [String] = []
        MutationRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            throw URLError(.networkConnectionLost)
        }
        let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertFalse(sent)
        XCTAssertEqual(methods, ["GET"])
        XCTAssertTrue(model.errorMessage?.contains("was not sent") == true)
        XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isMutating)

        let response = snapshot()
        MutationRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (200, response)
        }
        let retried = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertTrue(retried, model.errorMessage ?? "Explicit retry should recover immediately")
        XCTAssertEqual(methods, ["GET", "GET", "POST"])
    }

    func testNoDiscoveredOrConfiguredRouteReportsNotSentWithoutAnyRequest() async throws {
        let model = try await model()
        let configured = await model.configure(url: "", pairingToken: "unit-mutation-token")
        XCTAssertTrue(configured)
        MutationRequestProtocol.handler = { _ in
            XCTFail("No route should mean no HTTP traffic")
            throw URLError(.badURL)
        }
        let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertFalse(sent)
        XCTAssertTrue(model.errorMessage?.contains("was not sent") == true)
        XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
    }

    func testPostFailuresAreUncertainAndNeverReplayed() async throws {
        for networkFailure in [false, true] {
            let model = try await model()
            let response = snapshot()
            var methods: [String] = []
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                if request.httpMethod == "POST" {
                    if networkFailure { throw URLError(.networkConnectionLost) }
                    return (503, Data(#"{"error":"Proxy unavailable"}"#.utf8))
                }
                return (200, response)
            }
            let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(methods, ["GET", "POST"])
            XCTAssertTrue(model.errorMessage?.contains("may have reached Cantrip") == true)
            XCTAssertFalse(model.errorMessage?.contains("was not sent") == true)
            XCTAssertFalse(model.isConnected)
            model.clearConfiguration()
        }
    }

    func testCapabilityAndAuthenticationRejectionsDoNotWriteOrClaimUncertainDelivery() async throws {
        for status in [200, 401] {
            let model = try await model()
            let response = snapshot(capabilities: false)
            var methods: [String] = []
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (status, response)
            }
            let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(methods, ["GET"])
            XCTAssertTrue(model.errorMessage?.contains(status == 401 ? "pairing token" : "Auto sending") == true)
            XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
            model.clearConfiguration()
        }
    }

    func testOtherMutationsAlsoRecoverAndReuseTheirCapabilityChecks() async throws {
        let operations: [(String, (CantripRemoteModel) async -> Bool)] = [
            ("POST", { await $0.createSession() }),
            ("POST", { await $0.stop(sessionID: self.sessionID) }),
            ("POST", { await $0.resume() }),
            ("POST", { await $0.newConversation() }),
            ("POST", { await $0.updateTab(self.sessionID, name: "Renamed", isLocked: true) }),
            ("DELETE", { await $0.removeQueuedPrompt("pending", sessionID: self.sessionID) })
        ]
        for (method, operation) in operations {
            let model = try await model()
            var methods: [String] = []
            MutationRequestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            await model.selectSession(sessionID)
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, self.snapshot(
                    list: request.httpMethod == "GET" && request.url?.path == "/api/v1/sessions"
                ))
            }
            let succeeded = await operation(model)
            XCTAssertTrue(succeeded, model.errorMessage ?? "Expected recovered mutation")
            XCTAssertEqual(methods, ["GET", method])
            model.clearConfiguration()
        }
    }
}
