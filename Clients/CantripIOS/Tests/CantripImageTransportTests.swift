import Foundation
import XCTest
@testable import Hermes

private final class ImageRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
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

final class CantripImageTransportTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    override func tearDown() {
        ImageRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestProtocol.self]
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
    }

    private func snapshot(support: Bool?) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Test", "workdir": "/tmp",
            "isStreaming": false, "canResume": false, "councilMode": false,
            "queuedCount": 0,
        ]
        if let support { session["supportsImageAttachments"] = support }
        return try JSONSerialization.data(withJSONObject: ["session": session])
    }

    private func tabSnapshot() -> Data {
        Data("""
        {"session":{"id":"\(sessionID)","title":"Project","customTitle":"Project",
        "isLocked":true,"supportsTabMetadata":true,"workdir":"/tmp","isStreaming":true,
        "canResume":false,"councilMode":false,"queuedCount":0}}
        """.utf8)
    }

    func testLegacyHostsDoNotReceiveTabMetadataMutations() async throws {
        let response = try snapshot(support: nil)
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (200, response)
        }
        do {
            _ = try await api().updateTab(id: sessionID, name: "Project", isLocked: true)
            XCTFail("Old hosts must show the update notice")
        } catch CantripRemoteError.tabMetadataUnsupported {}
        XCTAssertEqual(methods, ["GET"])
    }

    func testRenameAndLockAreAuthenticatedPartialUpdates() async throws {
        let response = tabSnapshot()
        var bodies: [[String: Any]] = []
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/metadata")
                let data: Data
                if let body = request.httpBody {
                    data = body
                } else {
                    let stream = try XCTUnwrap(request.httpBodyStream)
                    stream.open()
                    defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 1024)
                    var collected = Data()
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
                        if count == 0 { break }
                        collected.append(contentsOf: bytes.prefix(count))
                    }
                    data = collected
                }
                bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            }
            return (200, response)
        }
        let client = try api()
        let renamed = try await client.updateTab(id: sessionID, name: " Project ")
        XCTAssertEqual(renamed.customTitle, "Project")
        XCTAssertEqual(renamed.isLocked, true)
        XCTAssertTrue(renamed.isStreaming)
        _ = try await client.updateTab(id: sessionID, isLocked: false)
        _ = try await client.updateTab(id: sessionID, name: " ")
        XCTAssertEqual(bodies[0]["customTitle"] as? String, "Project")
        XCTAssertNil(bodies[0]["isLocked"], "Renaming must not overwrite a concurrent lock")
        XCTAssertEqual(bodies[1]["isLocked"] as? Bool, false)
        XCTAssertNil(bodies[1]["customTitle"], "Unlocking must not overwrite a concurrent rename")
        XCTAssertEqual(bodies[2]["customTitle"] as? String, "")
        XCTAssertEqual(methods, ["GET", "POST", "GET", "POST", "GET", "POST"])
    }

    func testTabMutationsAreNotReplayedAndLockedHostErrorsSurface() async throws {
        let response = tabSnapshot()
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, response)
        }
        do {
            _ = try await api().updateTab(id: sessionID, isLocked: true)
            XCTFail("Uncertain changes must surface")
        } catch {}
        XCTAssertEqual(methods, ["GET", "POST"])

        methods = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (409, Data(#"{"error":"Unlock this tab first"}"#.utf8))
        }
        do {
            _ = try await api().closeSession(id: sessionID)
            XCTFail("Host lock must protect against stale client state")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "Unlock this tab first")
        }
        XCTAssertEqual(methods, ["POST"])
    }

    func testLegacyHostIsNeverSentAnImageMutation() async throws {
        for support: Bool? in [nil, false] {
            let response = try snapshot(support: support)
            var requests = 0
            ImageRequestProtocol.handler = { request in
                requests += 1
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, response)
            }
            do {
                _ = try await api().send(
                    "Look at this", mode: .queue, sessionID: sessionID,
                    images: [ChatImageAttachment(data: Data([1, 2, 3]))]
                )
                XCTFail("Unsupported hosts must reject image sends")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("updated Cantrip host"))
            }
            XCTAssertEqual(requests, 1, "Never POST text without its images")
        }
    }

    func testImageSendPreflightsThenPostsOnceWithAuthentication() async throws {
        let response = try snapshot(support: true)
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.timeoutInterval, 12, "Mutations retain their longer deadline")
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/messages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return (202, response)
            }
            XCTAssertEqual(request.timeoutInterval, 3, "Preflight reads use the bounded read deadline")
            return (200, response)
        }
        let result = try await api().send(
            "", mode: .interrupt, sessionID: sessionID,
            images: [ChatImageAttachment(data: Data([1, 2, 3]))]
        )
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(result.id, sessionID)
    }

    func testFailedImageMutationIsNotReplayed() async throws {
        let response = try snapshot(support: true)
        var mutations = 0
        ImageRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                mutations += 1
                return (400, Data(#"{"error":"Invalid image"}"#.utf8))
            }
            return (200, response)
        }
        do {
            _ = try await api().send(
                "Look", mode: .inject, sessionID: sessionID,
                images: [ChatImageAttachment(data: Data([1, 2, 3]))]
            )
            XCTFail("The server error must surface")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid image"))
        }
        XCTAssertEqual(mutations, 1)
    }

    func testTextOnlyStillWorksWithLegacyHostsWithoutPreflight() async throws {
        let response = try snapshot(support: nil)
        var requests = 0
        ImageRequestProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            return (202, response)
        }
        _ = try await api().send("Hello", mode: .queue, sessionID: sessionID)
        XCTAssertEqual(requests, 1)
    }

    func testAutoOnLegacyHostDoesNotSendAMutation() async throws {
        let response = try snapshot(support: nil)
        var requests = 0
        ImageRequestProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, response)
        }
        do {
            _ = try await api().send("Actually, explain it instead", mode: .auto, sessionID: sessionID)
            XCTFail("Auto must not silently fall back on an old host")
        } catch CantripRemoteError.autoDeliveryUnsupported { }
        XCTAssertEqual(requests, 1)
    }

    func testAutoPreflightsAndPostsExactlyOnce() async throws {
        let data = try snapshot(support: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var host = try XCTUnwrap(object["session"] as? [String: Any])
        host["supportsAutoDelivery"] = true
        object["session"] = host
        let response = try JSONSerialization.data(withJSONObject: object)
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (request.httpMethod == "POST" ? 202 : 200, response)
        }
        _ = try await api().send("The config is in /config", mode: .auto, sessionID: sessionID)
        XCTAssertEqual(methods, ["GET", "POST"])
        let body = try JSONEncoder().encode(CantripMessageBody(text: "Hello", mode: .auto, images: []))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(encoded["mode"] as? String, "auto")
    }

    func testQueuedSendAndRefreshReturnAuthoritativeQueue() async throws {
        let queued = Data(
            """
            {"session":{"id":"\(sessionID)","title":"Test","workdir":"/tmp",
            "isStreaming":true,"canResume":false,"councilMode":false,"queuedCount":2,
            "queued":[{"id":"mac-prompt","text":"From the Mac"},
                      {"id":"phone-prompt","text":"From the phone"}],"messages":[]}}
            """.utf8
        )
        let drained = try snapshot(support: true)
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path.hasPrefix("/api/v1/sessions/\(self.sessionID)"), true)
            return request.httpMethod == "POST" ? (202, queued) : (200, drained)
        }
        let client = try api()
        let accepted = try await client.send("From the phone", mode: .queue, sessionID: sessionID)
        XCTAssertEqual(accepted.queued?.map(\.id), ["mac-prompt", "phone-prompt"])
        XCTAssertEqual(accepted.queuedCount, 2)
        let refreshed = try await client.session(id: sessionID)
        XCTAssertEqual(refreshed.queuedCount, 0)
        XCTAssertEqual(methods, ["POST", "GET"], "Queue reads must not replay the send")
    }

    private func queueSnapshot(ids: [String], support: Bool? = true) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Test", "workdir": "/tmp",
            "isStreaming": true, "canResume": false, "councilMode": false,
            "queuedCount": ids.count,
            "queued": ids.map { ["id": $0, "text": "Continue"] },
            "messages": [
                ["id": "active-reply", "role": "assistant", "text": "Still working",
                 "thinking": "", "activities": []] as [String: Any],
            ],
        ]
        if let support { session["supportsQueueRemoval"] = support }
        return try JSONSerialization.data(withJSONObject: ["session": session])
    }

    func testQueueRemovalUsesStableIDAndPreservesOtherPromptsAndActiveTask() async throws {
        let ids = (1...3).map { String(format: "00000000-0000-0000-0000-%012d", $0) }
        let before = try queueSnapshot(ids: ids)
        let after = try queueSnapshot(ids: [ids[0], ids[2]])
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-pairing-token"
            )
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(
                    request.url?.path,
                    "/api/v1/sessions/\(self.sessionID)/queue/\(ids[1])"
                )
                return (200, after)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
            return (200, before)
        }
        let result = try await api().removeQueuedPrompt(id: ids[1], sessionID: sessionID)
        XCTAssertEqual(methods, ["GET", "DELETE"])
        XCTAssertEqual(result.queued?.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(result.queuedCount, 2)
        XCTAssertTrue(result.isStreaming)
        XCTAssertEqual(result.transcript.first?.text, "Still working")
    }

    func testRemovingLastPromptReturnsAnEmptyQueue() async throws {
        let id = "00000000-0000-0000-0000-000000000002"
        let before = try queueSnapshot(ids: [id])
        let after = try queueSnapshot(ids: [])
        ImageRequestProtocol.handler = { request in
            (200, request.httpMethod == "DELETE" ? after : before)
        }
        let result = try await api().removeQueuedPrompt(id: id, sessionID: sessionID)
        XCTAssertEqual(result.queuedCount, 0)
        XCTAssertEqual(result.queued, [])
        XCTAssertTrue(result.isStreaming)
    }

    func testLegacyHostsDoNotReceiveQueueRemovalMutations() async throws {
        for support: Bool? in [nil, false] {
            let response = try queueSnapshot(ids: ["pending"], support: support)
            var methods: [String] = []
            ImageRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, response)
            }
            do {
                _ = try await api().removeQueuedPrompt(id: "pending", sessionID: sessionID)
                XCTFail("An older host must show the update message")
            } catch CantripRemoteError.queueRemovalUnsupported {}
            XCTAssertEqual(methods, ["GET"])
        }
    }

    func testQueueRemovalConflictAndHostErrorsSurfaceWithoutOtherMutations() async throws {
        for status in [409, 500] {
            let response = try queueSnapshot(ids: ["pending"])
            var methods: [String] = []
            ImageRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                if request.httpMethod == "DELETE" {
                    return (status, Data(#"{"error":"Removal rejected by host"}"#.utf8))
                }
                return (200, response)
            }
            do {
                _ = try await api().removeQueuedPrompt(id: "pending", sessionID: sessionID)
                XCTFail("The host error must be surfaced without cancelling the task")
            } catch CantripRemoteError.http(let actualStatus, let message) {
                XCTAssertEqual(actualStatus, status)
                XCTAssertEqual(message, "Removal rejected by host")
            }
            XCTAssertEqual(methods, ["GET", "DELETE"])
        }
    }

    func testQueueRemovalLostResponseIsNotReplayed() async throws {
        let response = try queueSnapshot(ids: ["pending"])
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "DELETE" {
                throw URLError(.networkConnectionLost)
            }
            return (200, response)
        }
        do {
            _ = try await api().removeQueuedPrompt(id: "pending", sessionID: sessionID)
            XCTFail("Unconfirmed removal must not look successful")
        } catch CantripRemoteError.transport {}
        XCTAssertEqual(methods, ["GET", "DELETE"])
    }

    func testUnauthenticatedQueueRemovalNeverReachesTheMutation() async throws {
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (401, Data(#"{"error":"invalid pairing token"}"#.utf8))
        }
        do {
            _ = try await api().removeQueuedPrompt(id: "pending", sessionID: sessionID)
            XCTFail("Authentication errors must be surfaced")
        } catch CantripRemoteError.authentication {}
        XCTAssertEqual(methods, ["GET"])
    }
}
