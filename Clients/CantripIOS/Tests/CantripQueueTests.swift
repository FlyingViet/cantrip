import XCTest
@testable import Hermes

final class CantripQueueTests: XCTestCase {
    private func session(queue: String?, count: Int) throws -> CantripRemoteSession {
        let queueField = queue.map { #","queued":\#($0)"# } ?? ""
        return try JSONDecoder().decode(
            CantripRemoteSession.self,
            from: Data(
                #"""
                {"id":"session-a","title":"Chat","workdir":"/tmp",
                 "isStreaming":true,"canResume":false,"councilMode":false,
                 "queuedCount":\#(count),"messages":[]\#(queueField)}
                """#.utf8
            )
        )
    }

    func testQueuePreservesOrderIdentityAndFullText() throws {
        let decoded = try session(
            queue: #"""
            [{"id":"second-id","text":"First prompt\nwith details"},
             {"id":"first-id","text":"Next prompt"}]
            """#,
            count: 2
        )
        XCTAssertEqual(decoded.queuedCount, 2)
        XCTAssertEqual(decoded.queued?.map(\.id), ["second-id", "first-id"])
        XCTAssertEqual(decoded.queued?.first?.text, "First prompt\nwith details")
        XCTAssertTrue(decoded.transcript.isEmpty, "Queued prompts are not completed conversation turns")
    }

    func testLegacyHostCountIsNotMistakenForAnEmptyQueue() throws {
        let decoded = try session(queue: nil, count: 3)
        XCTAssertEqual(decoded.queuedCount, 3)
        XCTAssertNil(decoded.queued, "Missing details must show the host-update message")
    }

    func testEmptyQueueIsDistinctFromUnsupportedHost() throws {
        let decoded = try session(queue: "[]", count: 0)
        XCTAssertEqual(decoded.queued, [])
    }

    func testQueueChangesInvalidateSessionEvenWhenTranscriptDoesNotChange() throws {
        let first = try session(queue: #"[{"id":"a","text":"First"}]"#, count: 1)
        let second = try session(queue: #"[{"id":"b","text":"Second"}]"#, count: 1)
        let drained = try session(queue: "[]", count: 0)
        XCTAssertEqual(first.transcript, second.transcript)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, drained)
    }

    func testRepeatedPromptsHaveSeparateQueueIdentities() throws {
        let decoded = try session(
            queue: #"[{"id":"a","text":"Continue"},{"id":"b","text":"Continue"}]"#,
            count: 2
        )
        XCTAssertEqual(decoded.queued?.count, 2)
        XCTAssertNotEqual(decoded.queued?.first?.id, decoded.queued?.last?.id)
    }

    func testMalformedQueueIsNotSilentlyDropped() {
        XCTAssertThrowsError(try session(queue: #"[{"id":"a"}]"#, count: 1))
    }
}
