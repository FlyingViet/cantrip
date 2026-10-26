import Foundation
import XCTest
@testable import Hermes

private final class ThreadRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
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

/// Thread tags from Cantrip's Remote API: a Home message's `thread` (only on replies from another
/// thread), Home's `threadReplies` and `GET /api/v1/sessions/{id}/threads/{threadID}[?before={messageID}]`.
final class CantripThreadTagsTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"
    private let threadID = "11111111-1111-1111-1111-111111111111"
    private let messageID = "22222222-2222-2222-2222-222222222222"

    override func tearDown() {
        ThreadRequestProtocol.handler = nil
        super.tearDown()
    }

    func testMessagesDecodeTheirThreadAndOlderHostsHaveNone() throws {
        let tagged = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"\(messageID)","role":"assistant","text":"Chapters 9 and 12 are done.","thinking":"",
         "activities":[],"threadID":"\(threadID)",
         "thread":{"id":"\(threadID)","prompt":"we have a book called Designing Data Intensive Applications…"}}
        """.utf8))
        XCTAssertEqual(tagged.threadID, threadID)
        XCTAssertEqual(tagged.thread, CantripRemoteThreadTag(
            id: threadID, prompt: "we have a book called Designing Data Intensive Applications…"))
        let older = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"\(messageID)","role":"assistant","text":"Done.","thinking":"","activities":[]}
        """.utf8))
        XCTAssertNil(older.thread)
        XCTAssertNil(older.threadID)
    }

    func testThreadIsFetchedFromTheMacBeforeTheTaggedMessage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadRequestProtocol.self]
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
        var requested: URLRequest?
        ThreadRequestProtocol.handler = { request in
            requested = request
            return (200, Data("""
            {"thread":{"id":"\(self.threadID)","hasEarlier":false,
              "prompt":{"id":"\(self.threadID)","text":"we have a book called Designing Data Intensive Applications on our network storage."},
              "messages":[{"id":"33333333-3333-3333-3333-333333333333","role":"assistant","text":"I'll find the book on the NAS first."},
                          {"id":"44444444-4444-4444-4444-444444444444","role":"user","text":"Yes"}]}}
            """.utf8))
        }
        let thread = try await api.thread(sessionID: homeID, threadID: threadID, before: messageID)
        XCTAssertEqual(requested?.httpMethod, "GET")
        XCTAssertEqual(requested?.url?.path, "/api/v1/sessions/\(homeID)/threads/\(threadID)")
        let query = requested?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertEqual(query?.first { $0.name == "before" }?.value, messageID)
        XCTAssertEqual(thread.prompt.text, "we have a book called Designing Data Intensive Applications on our network storage.")
        XCTAssertEqual(thread.messages.map(\.role), ["assistant", "user"])
        XCTAssertFalse(thread.hasEarlier)
    }

    func testTheWholeThreadIsFetchedWithoutACursor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThreadRequestProtocol.self]
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
        var requested: URLRequest?
        ThreadRequestProtocol.handler = { request in
            requested = request
            return (200, Data("""
            {"thread":{"id":"\(self.threadID)","hasEarlier":false,
              "prompt":{"id":"\(self.threadID)","text":"we have a book"},
              "messages":[{"id":"\(self.messageID)","role":"assistant","text":"Chapters 3 and 4 are done too."}]}}
            """.utf8))
        }
        let thread = try await api.thread(sessionID: homeID, threadID: threadID)
        XCTAssertEqual(requested?.url?.path, "/api/v1/sessions/\(homeID)/threads/\(threadID)")
        let query = requested?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertNil(query?.first { $0.name == "before" }, "The thread view shows every message, the tagged one too")
        XCTAssertEqual(thread.messages.map(\.id), [messageID])
    }

    func testHomeDetailsCarryReplyCountsAndOlderHostsHaveNone() throws {
        func session(_ extra: String) throws -> CantripRemoteSession {
            try JSONDecoder().decode(CantripRemoteSession.self, from: Data("""
            {"id":"\(homeID)","title":"Cantrip Home","workdir":"/","isStreaming":false,"canResume":false,
             "councilMode":false,"queuedCount":0,"messages":[]\(extra)}
            """.utf8))
        }
        XCTAssertEqual(try session(#","threadReplies":{"\#(threadID)":4}"#).threadReplies, [threadID: 4])
        XCTAssertNil(try session("").threadReplies)
        XCTAssertEqual(CantripThreadText.replies(1), "1 Reply")
        XCTAssertEqual(CantripThreadText.replies(4), "4 Replies")
    }

    func testInvalidIDsAreNotRequested() async throws {
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token"
        )
        do {
            _ = try await api.thread(sessionID: homeID, threadID: "../tasks", before: messageID)
            XCTFail("A thread ID that isn't a UUID must not reach the Mac")
        } catch {}
    }
}
