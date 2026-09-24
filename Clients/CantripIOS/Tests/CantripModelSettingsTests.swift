import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class ModelSettingsRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                    statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripModelSettingsTests: XCTestCase {
    private let id = UUID().uuidString
    private let selection = CantripModelSelection(model: "model-a", effort: "high", contextTier: "long_context")

    private func snapshot(revision: String = "v1", reason: String? = nil) throws -> Data {
        var object: [String: Any] = [
            "selection": ["model": "model-a", "effort": "low", "contextTier": "default"],
            "defaults": ["model": "model-a", "effort": "low", "contextTier": "default"],
            "usesDefaults": true, "revision": revision, "isRefreshing": false,
            "models": [
                ["id": "model-a", "reasoningEfforts": ["low", "high"], "contextTiers": ["default", "long_context"],
                 "contextWindow": 1_050_000, "defaultContextPromptTokens": 272_000, "longContextPromptTokens": 1_050_000],
                ["id": "model-b", "reasoningEfforts": [], "contextTiers": ["default"]],
                ["id": "unknown-capabilities"]
            ]
        ]
        if let reason { object["unavailableReason"] = reason }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSettingsRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            ModelSettingsRequestProtocol.handler = nil
        }
        return client
    }

    private func model() async throws -> CantripRemoteModel {
        let model = CantripRemoteModel(urlSession: client())
        let configured = await model.configure(url: "https://cantrip.example",
                                              pairingToken: "model-settings-test", tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in model.setAppActive(false); model.clearConfiguration() }
        return model
    }

    func testCatalogCapabilitiesPrecisionAndUnsupportedSelections() throws {
        let value = try JSONDecoder().decode(CantripModelSettings.self, from: snapshot())
        XCTAssertNil(value.validationError(selection))
        XCTAssertEqual(CantripModelOption.tokenLabel(1_050_000), "1.05M")
        XCTAssertEqual(value.models[0].contextLabel("default"), "Standard - 272k input")
        XCTAssertEqual(value.models[0].contextLabel("long_context"), "Long - 1.05M input")
        XCTAssertEqual(value.models[1].reasoningEfforts, [])
        XCTAssertNil(value.models[2].reasoningEfforts)
        for invalid in [
            CantripModelSelection(model: "model-b", effort: "high", contextTier: "default"),
            CantripModelSelection(model: "model-b", effort: "", contextTier: "long_context"),
            CantripModelSelection(model: "missing", effort: "", contextTier: ""),
            CantripModelSelection(model: "unknown-capabilities", effort: "high", contextTier: "")
        ] { XCTAssertNotNil(value.validationError(invalid)) }
        let defaults = CantripModelSettingsChange(revision: "v1", selection: nil)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["revision", "usesDefaults"])
        XCTAssertEqual(body["usesDefaults"] as? Bool, true)
    }

    func testSavePreflightsOnceAndPinsTheOriginalTabAndRevision() async throws {
        let model = try await model()
        var methods: [String] = []
        ModelSettingsRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.id)/model-settings")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer model-settings-test")
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = stream.read(&bytes, maxLength: bytes.count)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                XCTAssertEqual(body["revision"] as? String, "v1")
                XCTAssertEqual(body["model"] as? String, "model-a")
                XCTAssertEqual(body["effort"] as? String, "high")
                XCTAssertEqual(body["contextTier"] as? String, "long_context")
                XCTAssertEqual(body["usesDefaults"] as? Bool, false)
            }
            return (200, try self.snapshot())
        }
        let saved = await model.updateModelSettings(id: id,
            change: CantripModelSettingsChange(revision: "v1", selection: selection), identity: model.usageIdentity)
        XCTAssertTrue(saved, model.errorMessage ?? "")
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testStaleOrBusyPreflightNeverPosts() async throws {
        let model = try await model()
        for data in [try snapshot(revision: "changed"), try snapshot(reason: "Wait for queued work.")] {
            var methods: [String] = []
            ModelSettingsRequestProtocol.handler = { request in
                methods.append(request.httpMethod!)
                return (200, data)
            }
            let saved = await model.updateModelSettings(id: id,
                change: CantripModelSettingsChange(revision: "v1", selection: selection), identity: model.usageIdentity)
            XCTAssertFalse(saved)
            XCTAssertEqual(methods, ["GET"])
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testServerChangesRejectBeforeNetworkAccess() async throws {
        let model = try await model()
        ModelSettingsRequestProtocol.handler = { _ in
            XCTFail("A stale server identity must not access the new Mac")
            return (200, try self.snapshot())
        }
        let saved = await model.updateModelSettings(id: id,
            change: CantripModelSettingsChange(revision: "v1", selection: selection), identity: UUID())
        XCTAssertFalse(saved)
        XCTAssertTrue(model.errorMessage?.contains("connected Mac changed") == true)
    }

    func testUncertainWriteIsNotReplayed() async throws {
        let model = try await model()
        var methods: [String] = []
        ModelSettingsRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, try self.snapshot())
        }
        let saved = await model.updateModelSettings(id: id,
            change: CantripModelSettingsChange(revision: "v1", selection: selection), identity: model.usageIdentity)
        XCTAssertFalse(saved)
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertTrue(model.errorMessage?.contains("may have reached Cantrip") == true)
    }

    func testOldHostAndAuthenticationRemainDistinct() async throws {
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                                  token: "fixture", urlSession: client())
        ModelSettingsRequestProtocol.handler = { request in
            if request.url?.path.hasSuffix("model-settings") == true {
                return (405, Data(#"{"error":"method not allowed"}"#.utf8))
            }
            return (200, Data("""
            {"session":{"id":"\(self.id)","title":"Old host","workdir":"/tmp","isStreaming":false,
              "canResume":false,"councilMode":false,"queuedCount":0,"messages":[]}}
            """.utf8))
        }
        do { _ = try await api.modelSettings(id: id); XCTFail("Old hosts need an update message") }
        catch CantripRemoteError.modelSettingsUnsupported {}
        ModelSettingsRequestProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do { _ = try await api.modelSettings(id: id); XCTFail("Authentication must not be masked") }
        catch CantripRemoteError.authentication {}
    }

    func testModelSettingsFormFitsNarrowAndLargeTextLayouts() async throws {
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: id, title: "My remote conversation", workdir: "/tmp",
            isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsModelSettings: true)
        var reads = 0
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Opening settings must not modify the Mac")
            reads += 1
            return (200, try self.snapshot())
        }
        for width: CGFloat in [320, 768] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let previousReads = reads
                let view = CantripModelSettingsView(model: model, session: session, identity: model.usageIdentity)
                    .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                try await Task.sleep(for: .milliseconds(400))
                controller.view.layoutIfNeeded()
                XCTAssertGreaterThan(reads, previousReads, "The form must load the host's options")
                func descendants(_ view: UIView) -> [UIView] {
                    [view] + view.subviews.flatMap(descendants)
                }
                let scrollViews = descendants(controller.view).compactMap { $0 as? UIScrollView }
                XCTAssertFalse(scrollViews.isEmpty, "All settings remain reachable by scrolling")
                for scroll in scrollViews where scroll.bounds.width > 0 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                             "Model settings must not scroll horizontally")
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Model settings \(Int(width)) \(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
