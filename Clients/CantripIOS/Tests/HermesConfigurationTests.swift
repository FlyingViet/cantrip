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

    @MainActor
    func testGatewayIdentityIncludesSchemePortAndPath() {
        let env = HermesEnv()
        let original = env.baseURL
        defer { env.baseURL = original }
        env.baseURL = "https://Example.com/hermes-a/"

        XCTAssertEqual(
            env.gatewayIdentity,
            "https://example.com:443/hermes-a"
        )
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

    func testRunStatusDecodesRecoverableOutputAndApproval() throws {
        let data = Data(
            #"""
            {
              "run_id": "run_123",
              "status": "waiting_for_approval",
              "output": null,
              "error": null,
              "approval": {
                "command": "git push",
                "description": "Push changes",
                "choices": ["once", "deny"]
              }
            }
            """#.utf8
        )

        let status = try JSONDecoder().decode(HermesRunStatus.self, from: data)

        XCTAssertEqual(status.runID, "run_123")
        XCTAssertFalse(status.isTerminal)
        XCTAssertEqual(status.approval?.choices, ["once", "deny"])
    }

    func testRunEventDecoderUsesEmbeddedEventName() throws {
        let data = #"{"event":"run.completed","output":"finished"}"#

        let events = HermesClient.decodeRunEvent(data: data)

        guard events.count == 2,
              case .finalText(let output) = events[0],
              case .completed = events[1] else {
            return XCTFail("Expected final text followed by completion")
        }
        XCTAssertEqual(output, "finished")
    }

    func testPendingRunRoundTripsItsIdempotencyKey() throws {
        let pending = PendingHermesRun(
            idempotencyKey: "ios-request",
            assistantTurnID: UUID(),
            input: "Do the work",
            history: [
                HermesConversationMessage(role: "user", content: "Earlier")
            ],
            sessionID: "session",
            executionLane: .copilot,
            showSteps: false,
            startedAt: Date(timeIntervalSince1970: 1)
        )

        let encoded = try JSONEncoder().encode(pending)
        let decoded = try JSONDecoder().decode(PendingHermesRun.self, from: encoded)

        XCTAssertEqual(decoded, pending)
    }

    func testChatStorePersistsActiveRunForRelaunchRecovery() throws {
        defer { ChatStore.clear(for: .local) }
        let assistant = ChatTurn(
            role: .assistant,
            streaming: true,
            executionLane: .local
        )
        let active = ActiveHermesRun(
            runID: "run_recover",
            idempotencyKey: "ios-recover",
            assistantTurnID: assistant.id,
            sessionID: "conversation",
            executionLane: .local,
            startedAt: Date(timeIntervalSince1970: 10)
        )

        ChatStore.save(
            turns: [assistant],
            conversationID: "conversation",
            gatewayIdentity: "gateway.example.com",
            pendingRun: nil,
            activeRun: active,
            for: .local
        )
        let restored = ChatStore.load(for: .local)

        XCTAssertEqual(restored.activeRun, active)
        XCTAssertEqual(restored.conversationID, "conversation")
        XCTAssertEqual(restored.turns.first?.streaming, true)
    }
}
