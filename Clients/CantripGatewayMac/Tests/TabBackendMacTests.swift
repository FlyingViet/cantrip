import AppKit
import SwiftUI
import XCTest
@testable import Hermes

private final class TabBackendRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                    statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

/// A tab's Model Settings as the Mac's Home window shows it (the shared sheet): the Backend
/// section for a tab on its own backend, in both appearances. The picker's saves are covered by
/// the iOS model settings tests, which share the view.
@MainActor
final class TabBackendMacTests: XCTestCase {
    private func snapshot(own: String?) throws -> Data {
        var object: [String: Any] = [
            "selection": ["model": "model-a", "effort": "", "contextTier": ""],
            "defaults": ["model": "model-a", "effort": "", "contextTier": ""],
            "usesDefaults": true, "revision": "r1", "isRefreshing": false,
            "models": [["id": "model-a", "reasoningEfforts": ["low", "high"]], ["id": "model-b"]],
            "backend": own ?? "Copilot", "macBackend": "Copilot",
            "backends": [
                ["id": "Copilot", "label": "Copilot", "available": true],
                ["id": "Claude Code", "label": "Claude Code", "available": true, "note": "Signed out on the Mac"],
                ["id": "Codex", "label": "Codex", "available": true],
                ["id": "Antigravity", "label": "Antigravity", "available": false, "note": "Not installed on the Mac"],
            ],
        ]
        if let own { object["ownBackend"] = own }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TabBackendRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "tab-backend-test",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            TabBackendRequestProtocol.handler = nil
        }
        return model
    }

    /// Set TEST_RUNNER_TAB_BACKEND_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild) to keep the renders.
    func testBackendSectionInTheMacSheet() async throws {
        let model = try await model()
        let session = CantripRemoteSession(id: "00000000-0000-0000-0000-0000000000b4", title: "Example project tab",
            workdir: "/tmp", isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsModelSettings: true)
        var reads = 0
        TabBackendRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Opening the sheet must not change the tab")
            if request.url?.path.hasSuffix("/model-settings") == true { reads += 1 }
            return (200, try self.snapshot(own: "Claude Code"))
        }
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_TAB_BACKEND_ARTIFACT_DIR"]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let before = reads
            // As `MacHomeWindow` presents it (`macSheetFrame()`: 600 x 600).
            let view = CantripSessionSettingsView(model: model, session: session, identity: model.usageIdentity)
                .frame(width: 600, height: 600)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(reads, before, "The sheet reads the tab's settings and backends")
            guard let directory, !directory.isEmpty else { continue }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appendingPathComponent("tab-backend-gateway-mac-\(appearance == .darkAqua ? "dark" : "light").png"))
        }
    }
}
