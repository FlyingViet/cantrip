import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class CantripReasoningTests: XCTestCase {
    func testRemoteMessageDecodesReasoningSteps() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"Done","thinking":"Look.\n\nCheck.","activities":[],
         "reasoning":[{"title":"Look for the parser","text":"It is in Backends/.","number":1},{"title":"Check"},{}],
         "subagents":[{"id":"call_1","agentID":"agent-1","status":"running",
           "reasoning":[{"title":"Exploring local repository options","text":"I'm considering rg.","number":9}]}]}
        """#.utf8))

        XCTAssertEqual(message.reasoning, [
            CantripRemoteReasoningStep(title: "Look for the parser", text: "It is in Backends/.", number: 1),
            CantripRemoteReasoningStep(title: "Check"),
            CantripRemoteReasoningStep(title: ""),
        ])
        XCTAssertEqual(CantripReasoningFormat.steps(for: message, thinking: message.thinking).map(\.title),
                       ["Look for the parser", "Check"], "empty steps are dropped")
        XCTAssertEqual(message.subagents?.first?.reasoning, [
            CantripRemoteReasoningStep(title: "Exploring local repository options", text: "I'm considering rg.", number: 9)
        ])
    }

    func testOlderHostsShowTheirReasoningAsOneStep() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m2","role":"assistant","text":"","thinking":"  All in one block. ","activities":[],
         "subagents":[{"id":"call_2","agentID":"agent-2"}]}
        """#.utf8))

        XCTAssertNil(message.reasoning)
        XCTAssertEqual(CantripReasoningFormat.steps(for: message, thinking: message.thinking), [
            CantripRemoteReasoningStep(title: "Reasoning", text: "All in one block.")
        ])
        XCTAssertEqual(CantripReasoningFormat.steps(for: nil, thinking: " \n"), [])
        XCTAssertEqual(message.subagents?.first?.reasoning, [])
    }

    func testReasoningScreenshotsAtPhoneWidth() async throws {
        let artifactDirectory = ProcessInfo.processInfo.environment["TEST_RUNNER_REASONING_ARTIFACT_DIR"]
        guard let artifactDirectory, !artifactDirectory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_REASONING_ARTIFACT_DIR to write reasoning screenshots.")
        }
        let output = URL(fileURLWithPath: artifactDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let steps = [
            CantripRemoteReasoningStep(title: "Checking which indicators exist for subagents",
                                       text: "The Mac strip, the Progress pane and the Remote cards all read the same monitor data."),
            CantripRemoteReasoningStep(title: "Looking for a spawn notification", text: ""),
            CantripRemoteReasoningStep(title: "Exploring local repository options",
                                       text: "I'm considering `rg` for the parser, then reading the tests."),
        ]
        let running = CantripRemoteSubagent(
            id: "call_running", agentID: "agent-running", name: "find-parser", agentType: "explore",
            summary: "Find the parser", model: "gpt-5.4-mini", status: .running,
            startedAt: Date().timeIntervalSince1970 - 42, intent: "Searching Sources/", steps: 9,
            tokens: 8_400, canCancel: true, reasoning: [
                CantripRemoteReasoningStep(title: "Looking for a spawn notification", number: 11),
                CantripRemoteReasoningStep(title: "Exploring local repository options",
                                           text: "I'm considering `rg` for the parser.", number: 12),
            ]
        )

        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let controller = UIHostingController(rootView:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CantripReasoningSteps(steps: steps, streaming: true)
                        CantripReasoningSteps(steps: steps, streaming: false, initiallyExpanded: true)
                        CantripSubagentCard(remote: CantripRemoteModel(), sessionID: "s", subagent: running)
                        CantripReasoningStepList(steps: running.reasoning, streaming: true)
                    }
                    .padding()
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
            try await Task.sleep(for: .milliseconds(250))
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = output.appendingPathComponent("reasoning-steps-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            let attachment = XCTAttachment(image: image)
            attachment.name = "reasoning-steps-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
