import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class QueueViewRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
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

@MainActor
final class CantripQueueViewTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    private func sessionJSON(sendNow: Bool?) -> [String: Any] {
        var session: [String: Any] = [
            "id": sessionID, "title": "Release build", "workdir": "/tmp",
            "isStreaming": true, "canResume": false, "councilMode": false,
            "queuedCount": 2, "supportsQueueRemoval": true,
            "queued": [
                ["id": "queued-1", "text": "Skip the watcher and check why the release build failed on the signing step."],
                ["id": "queued-2", "text": "Then update the README with the new install steps."],
            ],
            "messages": [
                ["id": "reply", "role": "assistant", "text": "Waiting on the build watcher…",
                 "thinking": "", "activities": []] as [String: Any],
            ],
        ]
        if let sendNow { session["supportsQueueSendNow"] = sendNow }
        return session
    }

    private func session(sendNow: Bool?) throws -> CantripRemoteSession {
        try JSONDecoder().decode(
            CantripRemoteSession.self,
            from: JSONSerialization.data(withJSONObject: sessionJSON(sendNow: sendNow))
        )
    }

    private func height(_ view: some View, width: CGFloat = 361, size: DynamicTypeSize = .large) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: 2_000)).height
    }

    func testSendNowOnlyChangesTheQueueRowWhenOfferedAndSupported() throws {
        let legacy = try session(sendNow: nil)
        let supported = try session(sendNow: true)
        for size in [DynamicTypeSize.large, .accessibility3] {
            let plain = height(CantripQueueButton(session: legacy) {}, size: size)
            XCTAssertEqual(height(CantripQueueButton(session: legacy, sendNow: {}) {}, size: size), plain,
                           accuracy: 0.5, "Older hosts keep the old row")
            XCTAssertEqual(height(CantripQueueButton(session: supported) {}, size: size), plain,
                           accuracy: 0.5, "No action keeps the old row")
        }
    }

    func testSendNowKeepsFullSizeTargetsAtEveryTextSize() throws {
        let supported = try session(sendNow: true)
        let legacy = try session(sendNow: nil)
        for width in [320.0, 393] {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
                let plain = height(CantripQueueButton(session: legacy) {}, width: width, size: size)
                let row = height(CantripQueueButton(session: supported, sendNow: {}) {}, width: width, size: size)
                XCTAssertGreaterThanOrEqual(row, 44, "\(size) at \(width)")
                if size.isAccessibilitySize {
                    XCTAssertGreaterThanOrEqual(row, plain + 44, "Large text moves Send now below the preview")
                } else {
                    XCTAssertGreaterThanOrEqual(row, plain - 0.5, "\(size) at \(width)")
                }
            }
        }
    }

    private func configuredModel() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueViewRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let session = sessionJSON(sendNow: true)
        QueueViewRequestProtocol.handler = { request in
            let list = request.httpMethod == "GET" && request.url?.path == "/api/v1/sessions"
            return (200, try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session]))
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "unit-queue-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            QueueViewRequestProtocol.handler = nil
        }
        // Polling connects the model, so the sheet shows its enabled controls.
        model.setAppActive(true)
        var attempts = 0
        while !(model.isConnected && model.selectedSession != nil), attempts < 300 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.selectSession(sessionID)
        XCTAssertTrue(model.isConnected, model.errorMessage ?? "Not connected")
        XCTAssertEqual(model.selectedSession?.queued?.count, 2)
        return model
    }

    /// The queue row above a stand-in composer, as the chat's input bar shows it.
    private func composer(
        _ session: CantripRemoteSession, isSending: Bool = false, size: DynamicTypeSize = .large
    ) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                CantripQueueButton(session: session, sendNow: {}, isSendingNow: isSending,
                                   canSendNow: !isSending) {}
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 44)
                    .overlay(alignment: .leading) {
                        Text("Message").foregroundStyle(.secondary).padding(.horizontal, 14)
                    }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
        .dynamicTypeSize(size)
        .background(Color(.systemBackground))
    }

    /// Renders the queue sheet and the composer's queue row for review.
    func testQueueSendNowScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["QUEUE_SEND_NOW_ARTIFACT_DIR"]
            ?? environment["TEST_RUNNER_QUEUE_SEND_NOW_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_QUEUE_SEND_NOW_ARTIFACT_DIR to render the queue screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = try await configuredModel()
        let session = try XCTUnwrap(model.selectedSession)

        func capture<V: View>(_ name: String, height: CGFloat = 852, style: UIUserInterfaceStyle = .dark,
                              _ view: V) async throws {
            let controller = UIHostingController(rootView: view)
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: height))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(600))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }

        try await capture("queue-sheet-dark", CantripQueueView(remote: model, sessionID: sessionID))
        try await capture("queue-sheet-light", style: .light, CantripQueueView(remote: model, sessionID: sessionID))
        try await capture("queue-sheet-ax3", CantripQueueView(remote: model, sessionID: sessionID)
            .dynamicTypeSize(.accessibility3))
        try await capture("composer-queue-row-dark", height: 260, composer(session))
        try await capture("composer-queue-row-light", height: 260, style: .light, composer(session))
        try await capture("composer-queue-row-sending", height: 260, composer(session, isSending: true))
        try await capture("composer-queue-row-ax3", height: 420, composer(session, size: .accessibility3))
    }
}
