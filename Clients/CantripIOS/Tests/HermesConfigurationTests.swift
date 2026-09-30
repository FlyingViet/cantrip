import SwiftUI
import UIKit
import XCTest
@testable import Hermes

final class HermesConfigurationTests: XCTestCase {
    @MainActor
    func testParakeetOnlyReportsDownloadAfterCacheCheck() {
        XCTAssertEqual(
            ParakeetSpeechEngine.initialPreparationPhase(isKnownCached: true),
            "Loading Parakeet"
        )
        XCTAssertEqual(
            ParakeetSpeechEngine.initialPreparationPhase(isKnownCached: false),
            "Checking speech model"
        )
    }

    func testCopilotIsTheDefaultExecutionLane() {
        XCTAssertEqual(ExecutionLane.defaultLane, .copilot)
        XCTAssertEqual(ExecutionLane.copilot.modelAlias, "copilot-coding")
        XCTAssertNotEqual(
            ExecutionLane.copilot.modelAlias,
            ExecutionLane.local.modelAlias
        )
    }

    @MainActor
    func testBackendVisibilityAndOrderPersistAndKeepOneVisible() throws {
        let suite = "HermesConfigurationTests.backendPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ExecutionLane.copilot.rawValue, forKey: "hermes.executionLane")

        let env = HermesEnv(defaults: defaults)
        XCTAssertEqual(env.backendOrder, ExecutionLane.allCases)
        XCTAssertEqual(env.selectableLanes, ExecutionLane.allCases)

        env.moveBackends(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(env.backendOrder, [.local, .cantrip, .home, .copilot])
        env.setLaneVisible(.home, isVisible: false)
        env.setLaneVisible(.copilot, isVisible: false)
        XCTAssertEqual(env.selectableLanes, [.local, .cantrip])
        XCTAssertEqual(env.executionLane, .cantrip)

        let restored = HermesEnv(defaults: defaults)
        XCTAssertEqual(restored.backendOrder, [.local, .cantrip, .home, .copilot])
        XCTAssertEqual(restored.selectableLanes, [.local, .cantrip])
        XCTAssertEqual(restored.executionLane, .cantrip)

        restored.setLaneVisible(.local, isVisible: false)
        restored.setLaneVisible(.cantrip, isVisible: false)
        XCTAssertEqual(restored.selectableLanes, [.cantrip])
        XCTAssertTrue(restored.isLaneVisible(.cantrip))
        XCTAssertFalse(restored.canHide(.cantrip))
    }

    @MainActor
    func testBackendSettingsScreenshot() async throws {
        let directory = ProcessInfo.processInfo.environment[
            "TEST_RUNNER_BACKEND_ARTIFACT_DIR"
        ]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BACKEND_ARTIFACT_DIR to render backend settings.")
        }
        let suite = "HermesConfigurationTests.backendRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let env = HermesEnv(defaults: defaults)
        env.moveBackends(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        env.setLaneVisible(.local, isVisible: false)

        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let controller = UIHostingController(rootView:
                NavigationStack {
                    BackendSettingsView(env: env)
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(200))
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(
                to: output.appendingPathComponent("backend-settings-\(name).png")
            )
        }
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
