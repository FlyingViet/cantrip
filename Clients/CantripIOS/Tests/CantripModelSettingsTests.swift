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

    func testUsageFallbackLoadsSavesAndOldHostsSayUpdate() async throws {
        let model = try await model()
        func fallback(_ backend: String, revision: String, limited: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "backend": backend, "primary": "Claude Code", "revision": revision,
                "choices": [["id": "Copilot", "label": "Copilot · gpt-5.6"], ["id": "Codex", "label": "Codex"]],
                "limited": limited ? [["backend": "Claude Code", "until": "2026-10-28T12:00:00Z", "untilLabel": "5:00 AM"]] : [],
            ])
        }
        var posts: [[String: Any]] = []
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/usage-fallback")
            guard request.httpMethod == "POST" else { return (200, try fallback("", revision: "f1", limited: true)) }
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = stream.read(&bytes, maxLength: bytes.count)
            posts.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any]))
            return (200, try fallback("Copilot", revision: "f2"))
        }
        // A Mac from before the chain: one backup, set through `backend`.
        let loaded = try await model.usageFallback()
        XCTAssertFalse(loaded.supportsChain)
        XCTAssertEqual(loaded.chain, [])
        XCTAssertEqual(loaded.addable.map(\.id), ["Copilot", "Codex"])
        XCTAssertEqual(loaded.status, "At its usage limit: Claude Code until 5:00 AM.")
        let saved = await model.updateUsageFallback(loaded.change(to: ["Copilot"]))
        XCTAssertEqual(saved?.chain, ["Copilot"])
        XCTAssertEqual(saved?.addable.map(\.id), [], "An older Mac takes no second backup")
        XCTAssertNil(posts.first?["backends"], "Older Macs get only the field they know")
        XCTAssertEqual(posts.first?["backend"] as? String, "Copilot")
        XCTAssertEqual(posts.first?["revision"] as? String, "f1")
        XCTAssertNil(posts.first?["resetLimits"], "Only the changed field is sent")
        _ = await model.updateUsageFallback(CantripUsageFallbackChange(revision: "f2", resetLimits: true))
        XCTAssertEqual(posts.last?["resetLimits"] as? Bool, true)
        XCTAssertNil(posts.last?["backend"])

        ModelSettingsRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await model.usageFallback()
            XCTFail("An older Mac has no fallback endpoint")
        } catch CantripRemoteError.usageFallbackUnsupported {}
    }

    func testUsageFallbackChainAddsReordersAndRemovesBackups() async throws {
        let model = try await model()
        var chain = ["Copilot", "Codex"]
        var revision = 1
        var posts: [[String: Any]] = []
        func fallback() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "backend": chain.first ?? "", "backends": chain, "primary": "Claude Code", "revision": "r\(revision)",
                "choices": [["id": "Copilot", "label": "Copilot"], ["id": "Codex", "label": "Codex"],
                            ["id": "Antigravity", "label": "Antigravity"]],
                "limited": [],
            ])
        }
        ModelSettingsRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = stream.read(&bytes, maxLength: bytes.count)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                posts.append(body)
                guard body["revision"] as? String == "r\(revision)" else { return (409, Data(#"{"error":"stale"}"#.utf8)) }
                chain = try XCTUnwrap(body["backends"] as? [String])
                revision += 1
            }
            return (200, try fallback())
        }
        var state = try await model.usageFallback()
        XCTAssertTrue(state.supportsChain)
        XCTAssertEqual(state.chain, ["Copilot", "Codex"])
        XCTAssertEqual(state.addable.map(\.id), ["Antigravity"])
        XCTAssertEqual(state.label("Claude Code"), "Claude Code (skipped: the Mac's backend)")

        let next1 = await model.updateUsageFallback(state.change(to: state.chain + ["Antigravity"]))
        state = try XCTUnwrap(next1)
        XCTAssertEqual(state.chain, ["Copilot", "Codex", "Antigravity"], "Add appends")
        XCTAssertNil(posts.last?["backend"], "A chain-aware Mac gets the whole chain")
        let next2 = await model.updateUsageFallback(state.change(to: ["Antigravity", "Copilot", "Codex"]))
        state = try XCTUnwrap(next2)
        XCTAssertEqual(state.chain, ["Antigravity", "Copilot", "Codex"], "Reorder")
        let next3 = await model.updateUsageFallback(state.change(to: ["Antigravity", "Codex"]))
        state = try XCTUnwrap(next3)
        XCTAssertEqual(state.chain, ["Antigravity", "Codex"], "Remove")
        XCTAssertEqual(state.addable.map(\.id), ["Copilot"])
        let next4 = await model.updateUsageFallback(state.change(to: []))
        state = try XCTUnwrap(next4)
        XCTAssertEqual(state.chain, [])
        XCTAssertEqual(state.status, "Off: a usage limit stops the run with the error.")
        XCTAssertEqual(posts.map { $0["revision"] as? String }, ["r1", "r2", "r3", "r4"])
    }

    func testUsageFallbackBackupsPickTheirModelAndEffort() async throws {
        let model = try await model()
        var entries: [[String: String]] = [["backend": "Claude Code", "model": "", "effort": ""], ["backend": "Codex", "model": "", "effort": ""]]
        var posted: [String: Any]?
        func fallback() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "backend": "Claude Code", "backends": entries.map { $0["backend"]! }, "entries": entries,
                "primary": "Copilot", "revision": "r\(entries.description.count)", "limited": [],
                "choices": [
                    ["id": "Claude Code", "label": "Claude Code", "defaultModel": "opus", "defaultEfforts": ["low", "high"],
                     "models": [["id": "claude-opus-5-5", "label": "claude-opus-5-5", "efforts": ["low", "medium", "high"]],
                                ["id": "claude-sonnet-5-5", "label": "claude-sonnet-5-5", "efforts": []]]],
                    ["id": "Codex", "label": "Codex"],
                ],
            ])
        }
        ModelSettingsRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                posted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                entries = try XCTUnwrap(posted?["entries"] as? [[String: String]])
            }
            return (200, try fallback())
        }
        var state = try await model.usageFallback()
        XCTAssertEqual(state.models(for: "Claude Code")?.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertNil(state.models(for: "Codex"), "A backend without a model picker shows none")
        XCTAssertEqual(state.efforts(for: "Claude Code"), ["low", "high"], "Default model: its efforts")
        let first = await model.updateUsageFallback(state.change(backend: "Claude Code", model: "claude-opus-5-5", effort: "high"))
        state = try XCTUnwrap(first)
        XCTAssertEqual(state.entry("Claude Code"), .init(backend: "Claude Code", model: "claude-opus-5-5", effort: "high"))
        XCTAssertEqual(state.entry("Codex").model, "", "The other backup is kept as it was")
        XCTAssertEqual((posted?["entries"] as? [[String: String]])?.count, 2)
        XCTAssertNil(posted?["backends"], "Model changes go through entries")
        XCTAssertEqual(state.efforts(for: "Claude Code"), ["low", "medium", "high"], "The chosen model's efforts")

        // A Mac from before backup models sends no entries: no pickers, the chain still edits.
        ModelSettingsRequestProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "backend": "Codex", "backends": ["Codex"], "primary": "Copilot", "revision": "old", "limited": [],
                "choices": [["id": "Codex", "label": "Codex"]],
            ]))
        }
        let older = try await model.usageFallback()
        XCTAssertNil(older.models(for: "Codex"))
        XCTAssertTrue(older.supportsChain)
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

    private func privateSnapshot(revision: String = "private-v1", reason: String? = nil) throws -> Data {
        var value: [String: Any] = [
            "revision": revision,
            "configuration": ["baseURL": "https://llm.example.ts.net/ollama", "model": "local:latest",
                              "contextWindow": 8192, "systemPrompt": "Keep this conversation local."]
        ]
        if let reason { value["unavailableReason"] = reason }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testPrivateLocalPreflightPinsConfigurationAndTab() async throws {
        let model = try await model()
        var methods: [String] = []
        let settings = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot())
        ModelSettingsRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.url?.host, "cantrip.example", "The phone sends configuration to the Mac, never directly to an LLM")
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.id)/private-settings")
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["revision", "configuration"])
                XCTAssertEqual(body["revision"] as? String, "private-v1")
                let configuration = try XCTUnwrap(body["configuration"] as? [String: Any])
                XCTAssertEqual(configuration["baseURL"] as? String, "https://llm.example.ts.net/ollama")
                XCTAssertEqual(configuration["model"] as? String, "local:latest")
                XCTAssertEqual(configuration["contextWindow"] as? Int, 8192)
                XCTAssertNil(body["usesDefaults"], "Private Local cannot inherit a cloud route")
            }
            return (200, try self.privateSnapshot())
        }
        let saved = await model.updatePrivateLocalSettings(id: id,
            change: .init(revision: settings.revision, configuration: settings.configuration),
            identity: model.usageIdentity)
        XCTAssertTrue(saved, model.errorMessage ?? "")
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testPrivateLocalBusyStaleAndChangedMacNeverWrite() async throws {
        let model = try await model()
        let snapshot = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot())
        let change = CantripPrivateLocalChange(revision: snapshot.revision, configuration: snapshot.configuration)
        for data in [try privateSnapshot(revision: "newer"), try privateSnapshot(reason: "Wait for the queue.")] {
            var methods: [String] = []
            ModelSettingsRequestProtocol.handler = { request in
                methods.append(request.httpMethod!)
                return (200, data)
            }
            let saved = await model.updatePrivateLocalSettings(id: id, change: change, identity: model.usageIdentity)
            XCTAssertFalse(saved)
            XCTAssertEqual(methods, ["GET"])
        }
        ModelSettingsRequestProtocol.handler = { _ in
            XCTFail("A stale editor must not contact a different Mac")
            return (200, try self.privateSnapshot())
        }
        let saved = await model.updatePrivateLocalSettings(id: id, change: change, identity: UUID())
        XCTAssertFalse(saved)
    }

    func testPrivateLocalUncertainSaveIsNeverReplayed() async throws {
        let model = try await model()
        let snapshot = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot())
        var methods: [String] = []
        ModelSettingsRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, try self.privateSnapshot())
        }
        let saved = await model.updatePrivateLocalSettings(id: id,
            change: .init(revision: snapshot.revision, configuration: snapshot.configuration),
            identity: model.usageIdentity)
        XCTAssertFalse(saved)
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertTrue(model.errorMessage?.contains("may have reached Cantrip") == true)
    }

    func testPrivateModelListUsesPairedMacAndOldHostFailsClosed() async throws {
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                                  token: "fixture", urlSession: client())
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.id)/private-models")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(query?.queryItems?.first(where: { $0.name == "baseURL" })?.value, "https://llm.example.ts.net/ollama")
            return (200, Data(#"{"models":["local:latest"]}"#.utf8))
        }
        let models = try await api.privateLocalModels(id: id, baseURL: "https://llm.example.ts.net/ollama")
        XCTAssertEqual(models, ["local:latest"])
        for code in [404, 405] {
            ModelSettingsRequestProtocol.handler = { _ in (code, Data(#"{"error":"not found"}"#.utf8)) }
            do { _ = try await api.privateLocalSettings(id: id); XCTFail("Do not fall back to cloud model settings") }
            catch CantripRemoteError.privateLocalUnsupported {}
        }
        ModelSettingsRequestProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do { _ = try await api.privateLocalSettings(id: id); XCTFail("Authentication must remain distinct") }
        catch CantripRemoteError.authentication {}
    }

    func testPrivateLocalSettingsAndStatusAtNarrowAndAccessibleWidths() async throws {
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: id, title: "Private Local", workdir: "/tmp",
            isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: false, queued: nil, isLocked: true,
            supportsModelSettings: false, isLocalPrivate: true, supportsPrivateLocalSettings: true)
        XCTAssertEqual(CantripSessionPicker.statusSummary(for: session), "Self-hosted, saved")
        var reads = 0
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.id)/private-settings",
                           "Private tabs must not open Copilot settings or refresh the cloud catalog")
            reads += 1
            return (200, try self.privateSnapshot())
        }
        for width: CGFloat in [320, 768] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let before = reads
                let view = CantripSessionSettingsView(model: model, session: session, identity: model.usageIdentity)
                    .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                try await Task.sleep(for: .milliseconds(400))
                controller.view.layoutIfNeeded()
                XCTAssertGreaterThan(reads, before)
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let scrollViews = descendants(controller.view).compactMap { $0 as? UIScrollView }
                XCTAssertFalse(scrollViews.isEmpty)
                for scroll in scrollViews where scroll.bounds.width > 0 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Private Local \(Int(width)) \(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testModelSettingsFormFitsNarrowAndLargeTextLayouts() async throws {
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: id, title: "My remote conversation", workdir: "/tmp",
            isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsModelSettings: true)
        var reads = 0, fallbackReads = 0
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Opening settings must not modify the Mac")
            if request.url?.path == "/api/v1/usage-fallback" {
                fallbackReads += 1
                return (200, try JSONSerialization.data(withJSONObject: [
                    "backend": "Copilot", "primary": "Claude Code", "revision": "f1", "limited": [],
                    "choices": [["id": "Copilot", "label": "Copilot"], ["id": "Codex", "label": "Codex"]],
                ]))
            }
            reads += 1
            return (200, try self.snapshot())
        }
        for width: CGFloat in [320, 768] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let previousReads = reads, previousFallbackReads = fallbackReads
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
                XCTAssertGreaterThan(fallbackReads, previousFallbackReads, "The sheet loads the Mac's usage limit fallback")
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
