import XCTest
@testable import Hermes

final class HermesConfigurationTests: XCTestCase {
    func testCopilotIsTheDefaultExecutionLane() {
        XCTAssertEqual(ExecutionLane.defaultLane, .copilot)
        XCTAssertEqual(ExecutionLane.copilot.modelAlias, "copilot-coding")
        XCTAssertNotEqual(
            ExecutionLane.copilot.modelAlias,
            ExecutionLane.local.modelAlias
        )
    }

    func testTransportAllowsEncryptedAndLoopbackEndpoints() throws {
        let https = try XCTUnwrap(URL(string: "https://agent.example.com"))
        let loopback = try XCTUnwrap(URL(string: "http://127.0.0.1:8642"))

        XCTAssertNil(GatewayTransportPolicy.issue(for: https))
        XCTAssertNil(GatewayTransportPolicy.issue(for: loopback))
    }

    func testTransportRejectsPlainLANHTTP() throws {
        let lan = try XCTUnwrap(URL(string: "http://192.168.0.10:8642"))

        XCTAssertNotNil(GatewayTransportPolicy.issue(for: lan))
    }

    func testTransportRejectsEmbeddedCredentials() throws {
        let credentialed = try XCTUnwrap(
            URL(string: "https://user:password@agent.example.com")
        )

        XCTAssertNotNil(GatewayTransportPolicy.issue(for: credentialed))
    }

    func testLegacyTurnsDecodeWithoutExecutionLane() throws {
        let data = Data(
            #"""
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "role": "assistant",
              "text": "hello",
              "tools": [],
              "actions": [],
              "streaming": false
            }
            """#.utf8
        )

        let turn = try JSONDecoder().decode(ChatTurn.self, from: data)

        XCTAssertNil(turn.executionLane)
        XCTAssertEqual(turn.text, "hello")
    }
}
