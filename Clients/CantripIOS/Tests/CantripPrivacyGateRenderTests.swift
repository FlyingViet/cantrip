import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// A transcript as the chat lists it.
private struct PrivacyTranscript: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(vm.turns) { turn in
                    TurnView(turn: turn, remote: remote, cantripSessionID: remote.selectedSessionID,
                             remoteMessage: vm.remoteMessage(for: turn.id))
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
}

/// Every route in one mode, each right-aligned as it sits under a prompt.
private struct PrivacyBadgeSheet: View {
    let rows: [(String, [CantripPrivacyBadge])]

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(rows, id: \.0) { title, badges in
                    Text(title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(badges, id: \.label) { badge in
                        CantripPrivacyBadgeView(badge: badge).padding(.leading, 40)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
}

/// The Privacy Gate's badge and Settings section: Dynamic Type layout and review renders.
@MainActor
final class CantripPrivacyGateRenderTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000c7"

    static let observe: [CantripPrivacyBadge] = [
        .init(route: "local", label: "Would run locally · secrets",
              detail: "A secret in the request. Rules 1 ms, 2 ms in all. Observing: this run was sent as usual."),
        .init(route: "cloud", label: "Cloud · 98% cloud",
              detail: "The classifier: 98% cloud. Rules 1 ms, classifier 380 ms, 384 ms in all. Observing: this run was sent as usual."),
        .init(route: "redactApprove", label: "Would ask first · personal-details",
              detail: "A phone number in the request. Rules 1 ms, 2 ms in all. Observing: this run was sent as usual."),
        .init(route: "offline", label: "Privacy check offline · classifier offline",
              detail: "The classifier didn't answer within 2500 ms. Observing: this run was sent as usual."),
    ]

    static let enforce: [CantripPrivacyBadge] = [
        .init(route: "local", mode: "enforce", applied: true, label: "Ran locally · private-sources",
              detail: "The request names mail. Rules 1 ms, 3 ms in all."),
        .init(route: "cloud", mode: "enforce", applied: true, label: "Cloud, no private tools · code",
              detail: "Work in a code repository. Rules 1 ms, 2 ms in all."),
        .init(route: "redactApprove", mode: "enforce", applied: true, label: "Asked first · personal-details",
              detail: "A card number in the request. Rules 1 ms, 2 ms in all."),
        .init(route: "offline", mode: "enforce", applied: true, label: "Held: privacy check offline · classifier offline",
              detail: "The classifier didn't answer within 2500 ms."),
    ]

    private func message(_ id: String, _ role: String, _ text: String, privacy: CantripPrivacyBadge? = nil) -> [String: Any] {
        var message: [String: Any] = ["id": id, "role": role, "text": text, "thinking": "", "activities": []]
        if let privacy {
            message["privacy"] = ["route": privacy.route, "mode": privacy.mode, "applied": privacy.applied,
                                  "label": privacy.label, "detail": privacy.detail]
        }
        return message
    }

    private func messages(_ badges: [CantripPrivacyBadge]) -> [[String: Any]] {
        [
            message("p1", "user", "What's the guest Wi-Fi password?", privacy: badges[0]),
            message("r1", "assistant", "It's saved in your vault as Guest Wi-Fi; I'll keep it out of this chat."),
            message("p2", "user", "Write a Swift function that reverses the words in a sentence.", privacy: badges[1]),
            message("r2", "assistant", "Split on spaces, reverse, and join: `words.reversed().joined(separator: \" \")`."),
            message("p3", "user", "Remind me what I asked yesterday."),
        ]
    }

    private func transcript(_ messages: [[String: Any]]) async throws -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        var session: [String: Any] = [
            "id": sessionID, "title": "Home", "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0, "messages": messages,
        ]
        let detail = try JSONSerialization.data(withJSONObject: ["session": session])
        session.removeValue(forKey: "messages")
        let list = try JSONSerialization.data(withJSONObject: ["sessions": [session]])
        StartFreshRequestProtocol.handler = { request in
            (200, request.url?.path == "/api/v1/sessions" ? list : detail)
        }
        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.id, sessionID, model.errorMessage ?? "Tab not selected")
        return (model, try StartFreshFixture.chat(model, for: self))
    }

    private func fittingSize(_ view: some View, width: CGFloat, size: DynamicTypeSize) -> CGSize {
        UIHostingController(rootView: view.dynamicTypeSize(size))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testBadgeWrapsInsteadOfTruncatingAtAccessibilitySizes() {
        let badge = CantripPrivacyBadgeView(badge: Self.enforce[3])
        let standard = fittingSize(badge, width: 393, size: .large)
        let large = fittingSize(badge, width: 320, size: .accessibility3)
        XCTAssertLessThan(standard.height, 40, "One quiet line at standard sizes")
        XCTAssertGreaterThanOrEqual(standard.height, 28, "Still a comfortable tap target")
        XCTAssertLessThanOrEqual(large.width, 320.5)
        XCTAssertGreaterThan(large.height, standard.height * 2, "The label wraps onto more lines rather than truncating")
    }

    func testOnlyPromptsWithADecisionShowTheBadge() async throws {
        let (remote, vm) = try await transcript(messages(Self.observe))
        let prompts = vm.turns.filter { $0.role == .user }
        XCTAssertEqual(prompts.count, 3)
        let badged = try XCTUnwrap(prompts.first)
        let plain = try XCTUnwrap(prompts.last)
        XCTAssertEqual(vm.remoteMessage(for: badged.id)?.privacy?.label, "Would run locally · secrets")
        XCTAssertNil(vm.remoteMessage(for: plain.id)?.privacy)
        func height(_ turn: ChatTurn, _ message: CantripRemoteMessage?) -> CGFloat {
            fittingSize(TurnView(turn: turn, remote: remote, cantripSessionID: sessionID, remoteMessage: message),
                        width: 393, size: .large).height
        }
        let message = vm.remoteMessage(for: badged.id)
        var withoutPrivacy = message
        withoutPrivacy?.privacy = nil
        XCTAssertGreaterThan(height(badged, message), height(badged, withoutPrivacy) + 20,
                             "The badge sits under the prompt")
    }

    /// Renders the badge and the Settings section for review. Set
    /// TEST_RUNNER_PRIVACY_GATE_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testPrivacyGateScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_PRIVACY_GATE_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_PRIVACY_GATE_ARTIFACT_DIR to render the Privacy Gate.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ view: some View, _ name: String, style: UIUserInterfaceStyle = .dark, width: CGFloat = 393,
                     height: CGFloat = 760, size: DynamicTypeSize = .large) async throws {
            let controller = UIHostingController(rootView: view.dynamicTypeSize(size))
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(600))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: output.appendingPathComponent("ios-privacy-\(name).png"))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "ios-privacy-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let sheet = PrivacyBadgeSheet(rows: [("Observe", Self.observe), ("Enforce", Self.enforce)])
        try await capture(sheet, "badges-dark", height: 520)
        try await capture(sheet, "badges-light", style: .light, height: 520)
        try await capture(sheet, "badges-ax-dark", width: 320, height: 1500, size: .accessibility3)
        try await capture(CantripPrivacyBadgeDetail(badge: Self.observe[0]).frame(width: 320)
                            .background(Color(.secondarySystemBackground)), "detail-dark", width: 320, height: 240)
        try await capture(CantripPrivacyBadgeDetail(badge: Self.enforce[0]).frame(width: 320)
                            .background(Color(.secondarySystemBackground)), "detail-ax-dark", width: 320, height: 760,
                          size: .accessibility3)

        let (observeRemote, observeVM) = try await transcript(messages(Self.observe))
        try await capture(PrivacyTranscript(remote: observeRemote, vm: observeVM), "transcript-observe-dark")
        let (enforceRemote, enforceVM) = try await transcript(messages(Self.enforce))
        try await capture(PrivacyTranscript(remote: enforceRemote, vm: enforceVM), "transcript-enforce-dark")
        try await capture(PrivacyTranscript(remote: enforceRemote, vm: enforceVM), "transcript-enforce-ax-dark",
                          width: 320, height: 1700, size: .accessibility3)

        let snapshot = try PrivacyGateFixture.snapshot()
        let gate = try XCTUnwrap(snapshot.policy.privacyGate)
        let tasks = try PrivacyGateFixture.tasks()
        let tested = CantripPrivacyTestResult(ok: true, address: "http://127.0.0.1:8000/v1", model: "example-classifier-4b",
                                              latencyMs: 380, route: "cloud",
                                              probabilities: ["local": 0.01, "cloud": 0.98, "redactApprove": 0.01])
        func settings(_ gate: CantripPrivacyGate, _ classifier: CantripPrivacyClassifierStatus?,
                      result: CantripPrivacyTestResult?) -> some View {
            NavigationStack {
                Form {
                    SettingsPrivacyGateSections(remote: observeRemote, gate: gate, classifier: classifier,
                                                tasks: tasks, testResult: result) { _ in }
                }
                .formStyle(.grouped)
                .navigationTitle("Agent policy")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        try await capture(settings(gate, snapshot.privacyClassifier, result: tested), "settings-dark", height: 2000)
        try await capture(settings(gate, snapshot.privacyClassifier, result: tested), "settings-ax-dark",
                          height: 5200, size: .accessibility3)
        let enforcing = gate.setting("mode", to: .string("enforce"))
        let problem = CantripPrivacyClassifierStatus(
            from: "none", problem: "No classifier server: set one, or point Private Local at an OpenAI-compatible server.")
        let failed = CantripPrivacyTestResult(ok: false, error: problem.problem)
        try await capture(settings(enforcing, problem, result: failed), "settings-enforce-problem-dark", height: 2000)
    }
}
