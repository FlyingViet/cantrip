import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// The transcript as the chat lists it, for layout checks and renders.
private struct StartFreshTranscript: View {
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
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemBackground))
    }
}

/// Start Fresh's divider and repeated-error actions: Dynamic Type layout and review renders.
@MainActor
final class CantripStartFreshRenderTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000f2"
    private let failure = "Execution failed: 400 The requested model is not supported"

    private func message(_ id: String, _ role: String, _ text: String) -> [String: Any] {
        ["id": id, "role": role, "text": text, "thinking": "", "activities": []]
    }

    private var dividerMessages: [[String: Any]] {
        [
            message("p1", "user", "Ship the beta build"),
            message("r1", "assistant", "Shipped build 1.4 (210) to TestFlight."),
            message("f1", "freshStart", CantripStartFresh.defaultCaption),
            message("p2", "user", "Draft the release notes"),
            message("r2", "assistant", "Here are the release notes for 1.4: faster sync and a new widget."),
        ]
    }

    private var errorMessages: [[String: Any]] {
        [
            message("p1", "user", "What's the admin password for the router?"),
            message("r1", "assistant", "I can't help find or reveal passwords."),
            message("p2", "user", "Ship the beta build"),
            message("e1", "error", failure),
            message("p3", "user", "Try again"),
            message("e2", "error", failure),
        ]
    }

    private func transcript(_ messages: [[String: Any]], repeatedError: String? = nil,
                            privateLocal: Bool = false) async throws -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        var session: [String: Any] = [
            "id": sessionID, "title": "Plexa", "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0,
            "supportsStartFresh": true, "supportsModelSettings": true, "messages": messages,
        ]
        if privateLocal { session["isLocalPrivate"] = true }
        if let repeatedError { session["repeatedErrorMessageID"] = repeatedError }
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

    func testDividerWrapsInsteadOfTruncatingAtAccessibilitySizes() {
        let divider = CantripFreshStartDivider(text: CantripStartFresh.defaultCaption)
        let standard = fittingSize(divider, width: 320, size: .large)
        let large = fittingSize(divider, width: 320, size: .accessibility5)
        XCTAssertLessThanOrEqual(large.width, 320.5)
        XCTAssertGreaterThan(large.height, standard.height * 2.5,
                             "The caption wraps onto more lines rather than truncating")
        XCTAssertEqual(CantripFreshStartDivider(text: "  ").caption, CantripStartFresh.defaultCaption)
    }

    func testRepeatedErrorActionsStackWhenTheyDontFitSideBySide() async throws {
        let (model, _) = try await transcript(errorMessages, repeatedError: "e2")
        let session = try XCTUnwrap(model.selectedSession)
        let actions = CantripRepeatedErrorActions(model: model, session: session)
        let standard = fittingSize(actions, width: 393, size: .large)
        let large = fittingSize(actions, width: 320, size: .accessibility3)
        XCTAssertGreaterThanOrEqual(standard.height, 44)
        XCTAssertLessThan(standard.height, 80, "Both buttons share a row at standard sizes")
        XCTAssertLessThanOrEqual(large.width, 320.5)
        XCTAssertGreaterThan(large.height, standard.height * 1.8, "Large text stacks the buttons")
    }

    /// Renders the divider and the repeated-error actions for review. Set
    /// TEST_RUNNER_START_FRESH_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testStartFreshScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_START_FRESH_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_START_FRESH_ARTIFACT_DIR to render Start Fresh.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ view: some View, _ name: String, style: UIUserInterfaceStyle, width: CGFloat = 393,
                     height: CGFloat = 760, size: DynamicTypeSize = .large) async throws {
            let controller = UIHostingController(rootView: view.dynamicTypeSize(size))
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: output.appendingPathComponent("ios-\(name).png"))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "ios-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let (dividerModel, dividerVM) = try await transcript(dividerMessages)
        let (errorModel, errorVM) = try await transcript(errorMessages, repeatedError: "e2")
        let (privateModel, privateVM) = try await transcript(errorMessages, repeatedError: "e2", privateLocal: true)
        let divider = StartFreshTranscript(remote: dividerModel, vm: dividerVM)
        let error = StartFreshTranscript(remote: errorModel, vm: errorVM)
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            try await capture(divider, "divider-\(name)", style: style)
            try await capture(error, "error-actions-\(name)", style: style)
        }
        try await capture(divider, "divider-ax-dark", style: .dark, width: 320, height: 1100, size: .accessibility3)
        try await capture(error, "error-actions-ax-dark", style: .dark, width: 320, height: 1100, size: .accessibility3)
        try await capture(error, "error-actions-ax-light", style: .light, width: 320, height: 1100, size: .accessibility3)
        try await capture(StartFreshTranscript(remote: privateModel, vm: privateVM),
                          "error-actions-private-local-dark", style: .dark)
    }
}
