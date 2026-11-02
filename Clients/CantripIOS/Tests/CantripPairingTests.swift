import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class PairingRequestProtocol: URLProtocol {
    @MainActor static var handler: ((PairingRequestProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                try XCTUnwrap(Self.handler)(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    func respond(title: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["session": [
            "id": "shared-id", "title": title, "workdir": "/tmp", "isStreaming": false, "canResume": false,
            "councilMode": false, "queuedCount": 0, "messages": [],
        ]])
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Confirming a pairing link saves and selects it like Settings; cancelling or a busy model saves
/// nothing. Saved servers and credentials are in memory; the legacy pairing slot that `configure`
/// writes is restored afterwards.
@MainActor
final class CantripPairingTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"
    private var credentials: [String: String] = [:]

    private func fixture() throws -> (CantripRemoteModel, ServerProfiles) {
        try preserveLegacyConfiguration()
        let suite = "CantripPairingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: ServerCredentialStore(
            read: { [unowned self] in credentials[$0] },
            write: { [unowned self] in credentials[$0] = $1 },
            remove: { [unowned self] in credentials[$0] = nil }
        ))
        try store.select(try store.add(ServerDraft(name: "Home Mac", url: "https://home.example",
                                                   credential: "home-test-credential", tailscaleOnly: true)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration), servers: store)
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            PairingRequestProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        return (model, store)
    }

    private func preserveLegacyConfiguration() throws {
        let keys = ["cantrip.remote.base-url", "cantrip.remote.tailscale-only"]
        let values = keys.map { UserDefaults.standard.object(forKey: $0) }
        let account = "cantrip.remote.pairing-token"
        let secret = try Keychain.loadCredential(account)
        addTeardownBlock { @MainActor in
            for (key, value) in zip(keys, values) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            if let secret { try Keychain.saveCredential(secret, for: account) }
            else { try Keychain.deleteCredential(account) }
        }
    }

    private func link(_ query: String) throws -> CantripPairingLink {
        try XCTUnwrap(CantripPairingLink.parse(try XCTUnwrap(URL(string: "cantripagent://pair?v=1&\(query)")))).get()
    }

    private var fullLink: CantripPairingLink {
        get throws {
            try link("name=mac-mini&token=\(token)&url=https%3A%2F%2Fmac-mini.tailnet.ts.net"
                     + "&direct=192.168.0.10%3A8766&tailscaleOnly=1")
        }
    }

    func testConfirmingAddsTheServerAndConfiguresItsRoutesAndToken() async throws {
        let (model, store) = try fixture()
        let home = try XCTUnwrap(store.selected)
        var requests: [URLRequest] = []
        PairingRequestProtocol.handler = {
            requests.append($0.request)
            try $0.respond(title: "Paired")
        }
        let server = try await model.pair(with: try fullLink)

        XCTAssertEqual(store.servers.map(\.id), [home.id, server.id], "Pairing adds; the previous server stays saved")
        XCTAssertEqual(server.name, "mac-mini")
        XCTAssertEqual(server.url, "https://mac-mini.tailnet.ts.net")
        XCTAssertEqual(server.directAddress, "192.168.0.10:8766")
        XCTAssertTrue(server.tailscaleOnly)
        XCTAssertEqual(try store.credential(for: server), token)
        XCTAssertEqual(try store.credential(for: home), "home-test-credential")
        XCTAssertEqual(store.selectedID, server.id)
        XCTAssertEqual(model.selectedServerID, server.id)
        XCTAssertEqual(model.configuredURL, "https://mac-mini.tailnet.ts.net")
        XCTAssertEqual(model.directAddress, "192.168.0.10:8766")
        XCTAssertTrue(model.tailscaleOnly)
        XCTAssertTrue(model.isConfigured)
        XCTAssertNil(model.errorMessage)

        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Paired")
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.host, "mac-mini.tailnet.ts.net")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testTokenOnlyLinkSelectsALocalNetworkServer() async throws {
        let (model, store) = try fixture()
        let server = try await model.pair(with: try link("token=\(token)"))
        XCTAssertEqual(server.name, "Cantrip on LAN")
        XCTAssertEqual(server.url, "")
        XCTAssertNil(server.directAddress)
        XCTAssertFalse(server.tailscaleOnly)
        XCTAssertEqual(store.selectedID, server.id)
        XCTAssertEqual(model.configuredURL, "")
        XCTAssertNil(model.directAddress)
        XCTAssertFalse(model.tailscaleOnly)
        XCTAssertTrue(model.hasStoredToken)
    }

    func testAnIdenticalSavedServerIsSelectedInsteadOfAddedAgain() async throws {
        let (model, store) = try fixture()
        let saved = try store.add(try fullLink.draft)
        XCTAssertEqual(model.savedServer(for: try fullLink), saved)
        XCTAssertNil(model.savedServer(for: try link("token=\(token)")))
        let server = try await model.pair(with: try fullLink)
        XCTAssertEqual(server, saved)
        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(store.selectedID, saved.id)
    }

    func testPairingRestoresASavedServerWhoseTokenIsMissing() async throws {
        let (model, store) = try fixture()
        let studio = try link("name=Studio&token=\(token)&url=https%3A%2F%2Fstudio.example")
        let saved = try store.add(studio.draft)
        // As after moving to a new device: the entry is saved, its Keychain token isn't.
        credentials = credentials.filter { !$0.key.contains(saved.id.uuidString) }
        XCTAssertNil(model.savedServer(for: studio))
        XCTAssertEqual(model.serverMissingToken(for: studio), saved)
        PairingRequestProtocol.handler = { try $0.respond(title: "Paired") }

        let server = try await model.pair(with: studio)
        XCTAssertEqual(server, saved)
        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(try store.credential(for: saved), token)
        XCTAssertEqual(store.selectedID, saved.id)
        XCTAssertEqual(model.selectedServerID, saved.id)
        XCTAssertNil(model.serverMissingToken(for: studio))
    }

    func testPairingWaitsForAnInFlightRequestAndSavesNothing() async throws {
        let (model, store) = try fixture()
        let started = expectation(description: "Request in flight")
        var held: PairingRequestProtocol?
        PairingRequestProtocol.handler = {
            held = $0
            started.fulfill()
        }
        let task = Task { await model.createSession() }
        await fulfillment(of: [started], timeout: 2)
        let before = (store.servers, store.selectedID, model.configuredURL, credentials)
        do {
            try await model.pair(with: try fullLink)
            XCTFail("Pairing must wait for the request")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wait for the current request to finish before pairing.")
        }
        XCTAssertEqual(store.servers, before.0)
        XCTAssertEqual(store.selectedID, before.1)
        XCTAssertEqual(model.configuredURL, before.2)
        XCTAssertEqual(credentials, before.3)
        try XCTUnwrap(held).respond(title: "Home")
        _ = await task.value
    }

    func testCancellingTheConfirmationChangesNothing() async throws {
        let (model, store) = try fixture()
        let legacyURL = UserDefaults.standard.object(forKey: "cantrip.remote.base-url") as? String
        let legacyToken = try Keychain.loadCredential("cantrip.remote.pairing-token")
        let before = (store.servers, store.selectedID, model.selectedServerID, model.configuredURL, credentials)
        var paired = false
        let host = CantripPairingPresenter.present(CantripPairingPrompt(result: .success(try fullLink)), model: model) {
            paired = true
        }
        for _ in 0..<40 where host.presentingViewController == nil || host.isBeingPresented {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(host.presentingViewController, "The confirmation is on screen")
        host.rootView.close(false)
        for _ in 0..<40 where host.presentingViewController != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(host.presentingViewController, "Cancel closes the confirmation")
        XCTAssertFalse(paired)
        XCTAssertEqual(store.servers, before.0)
        XCTAssertEqual(store.selectedID, before.1)
        XCTAssertEqual(model.selectedServerID, before.2)
        XCTAssertEqual(model.configuredURL, before.3)
        XCTAssertEqual(credentials, before.4)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "cantrip.remote.base-url") as? String, legacyURL)
        XCTAssertEqual(try Keychain.loadCredential("cantrip.remote.pairing-token"), legacyToken)
    }

    /// Renders the confirmation for review. Set TEST_RUNNER_PAIRING_ARTIFACT_DIR (pass
    /// TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testPairingScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_PAIRING_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_PAIRING_ARTIFACT_DIR to render the pairing confirmation.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (model, _) = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ result: Result<CantripPairingLink, CantripPairingLinkError>, _ name: String,
                     style: UIUserInterfaceStyle, width: CGFloat = 393, height: CGFloat = 852,
                     size: DynamicTypeSize = .large) async throws {
            let view = CantripPairingView(prompt: CantripPairingPrompt(result: result), model: model) { _ in }
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
            try data.write(to: output.appendingPathComponent("ios-\(name).png"))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "ios-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let full = Result<CantripPairingLink, CantripPairingLinkError>.success(try fullLink)
        try await capture(full, "pair-light", style: .light)
        try await capture(full, "pair-dark", style: .dark)
        try await capture(full, "pair-ax-dark", style: .dark, width: 320, height: 2600, size: .accessibility3)
        try await capture(full, "pair-ax-light", style: .light, width: 320, height: 2600, size: .accessibility3)
        try await capture(.success(try link("name=codespaces-abc123&token=\(token)")), "pair-local-only-dark",
                          style: .dark)
        try await capture(.failure(.unsupportedVersion), "update-required-dark", style: .dark)
        try await capture(.failure(.invalidToken), "invalid-token-light", style: .light)
    }
}
