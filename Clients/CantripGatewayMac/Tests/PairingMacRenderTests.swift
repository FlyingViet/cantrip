import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// The pairing confirmation as the Mac's Home window shows it for an opened `cantrip pair` link.
@MainActor
final class PairingMacRenderTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"

    /// Renders for review. Set TEST_RUNNER_PAIRING_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testPairingMacScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_PAIRING_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_PAIRING_ARTIFACT_DIR to render the pairing confirmation on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try StartFreshFixture.model(for: self)
        let url = try XCTUnwrap(URL(string: "cantripagent://pair?v=1&name=codespaces-abc123&token=\(token)"
            + "&url=https%3A%2F%2Fcodespaces-abc123-8765.app.github.dev&direct=192.168.0.10%3A8766"))
        let link = try XCTUnwrap(CantripPairingLink.parse(url))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await capture(link, model, "mac-pair-\(name)", appearance, output)
        }
        try await capture(.failure(.unsupportedVersion), model, "mac-update-required-dark", .darkAqua, output)
    }

    private func capture(_ result: Result<CantripPairingLink, CantripPairingLinkError>, _ model: CantripRemoteModel,
                         _ name: String, _ appearance: NSAppearance.Name, _ output: URL) async throws {
        let view = CantripPairingView(prompt: CantripPairingPrompt(result: result), model: model) { _ in }
            .frame(width: 520, height: 600)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
