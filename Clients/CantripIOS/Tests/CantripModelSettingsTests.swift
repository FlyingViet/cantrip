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

private let tabBackendChoices: [[String: Any]] = [
    ["id": "Copilot", "label": "Copilot", "available": true],
    ["id": "Claude Code", "label": "Claude Code", "available": true, "note": "Signed out on the Mac"],
    ["id": "Codex", "label": "Codex", "available": true],
    ["id": "Antigravity", "label": "Antigravity", "available": false, "note": "Not installed on the Mac"],
]

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
        XCTAssertTrue(loaded.canResetLimits)
        XCTAssertNil(loaded.limitedModels, "Older Macs send no model limits")
        XCTAssertNil(loaded.primaryChoice)
        let saved = await model.updateUsageFallback(try XCTUnwrap(loaded.adding("Copilot")))
        XCTAssertEqual(saved?.chain, ["Copilot"])
        XCTAssertEqual(saved?.addable.map(\.id), [], "An older Mac takes no second backup")
        XCTAssertNil(posts.first?["backends"], "Older Macs get only the field they know")
        XCTAssertNil(posts.first?["entries"])
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
        XCTAssertEqual(state.addable.map(state.addLabel), ["Antigravity"], "Each backend once on a Mac without entries")
        XCTAssertFalse(state.supportsModels)
        XCTAssertNil(state.models(at: 0))

        let next1 = await model.updateUsageFallback(try XCTUnwrap(state.adding("Antigravity")))
        state = try XCTUnwrap(next1)
        XCTAssertEqual(state.chain, ["Copilot", "Codex", "Antigravity"], "Add appends")
        XCTAssertNil(posts.last?["backend"], "A chain-aware Mac gets the whole chain")
        XCTAssertNil(posts.last?["entries"], "A Mac without entries gets backends")
        XCTAssertNil(state.adding("Antigravity"), "No second Antigravity on a Mac without entries")
        let next2 = await model.updateUsageFallback(state.moving(2, by: -1))
        state = try XCTUnwrap(next2)
        XCTAssertEqual(state.chain, ["Copilot", "Antigravity", "Codex"], "Up one")
        let next3 = await model.updateUsageFallback(state.moving(0, by: 1))
        state = try XCTUnwrap(next3)
        XCTAssertEqual(state.chain, ["Antigravity", "Copilot", "Codex"], "Down one")
        let next4 = await model.updateUsageFallback(state.removing(1))
        state = try XCTUnwrap(next4)
        XCTAssertEqual(state.chain, ["Antigravity", "Codex"], "Remove")
        XCTAssertEqual(state.addable.map(\.id), ["Copilot"])
        let next5 = await model.updateUsageFallback(state.change(to: []))
        state = try XCTUnwrap(next5)
        XCTAssertEqual(state.chain, [])
        XCTAssertEqual(state.status, "Off: a usage limit stops the run with the error.")
        XCTAssertEqual(posts.map { $0["revision"] as? String }, ["r1", "r2", "r3", "r4", "r5"])

        // An older Mac's chain with its own backend in it: the Mac skips that one.
        chain = ["Claude Code", "Codex"]
        state = try await model.usageFallback()
        XCTAssertEqual(state.title(at: 0), "Claude Code (skipped: the Mac's backend)")
        XCTAssertEqual(state.title(at: 1), "Codex")
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
        XCTAssertEqual(state.models(at: 0)?.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertNil(state.models(at: 1), "A backend without a model picker shows none")
        XCTAssertTrue(state.offersDefault(at: 0))
        XCTAssertEqual(state.efforts(at: 0), ["low", "high"], "Default model: its efforts")
        XCTAssertFalse(state.listsBackendsAgain, "A Mac without model limits lists each backend once")
        XCTAssertNil(state.adding("Claude Code"), "So it offers no second Claude Code")
        XCTAssertEqual(state.addable.map(\.id), [])
        let first = await model.updateUsageFallback(state.setting(0, model: "claude-opus-5-5", effort: "high"))
        state = try XCTUnwrap(first)
        XCTAssertEqual(state.rows[0], .init(backend: "Claude Code", model: "claude-opus-5-5", effort: "high"))
        XCTAssertEqual(state.rows[1].model, "", "The other backup is kept as it was")
        XCTAssertEqual((posted?["entries"] as? [[String: String]])?.count, 2)
        XCTAssertEqual((posted?["entries"] as? [[String: String]])?.map { Set($0.keys) },
                       [["backend", "model", "effort"], ["backend", "model", "effort"]],
                       "Only the fields every Mac with entries takes")
        XCTAssertNil(posted?["backends"], "Model changes go through entries")
        XCTAssertEqual(state.efforts(at: 0), ["low", "medium", "high"], "The chosen model's efforts")
        let moved = await model.updateUsageFallback(state.moving(0, by: 1))
        state = try XCTUnwrap(moved)
        XCTAssertEqual(state.rows.map(\.backend), ["Codex", "Claude Code"])
        XCTAssertEqual(state.rows[1].model, "claude-opus-5-5", "Moving keeps the backup's model")
        XCTAssertNil(posted?["backends"], "Moves go through entries too")

        // A Mac from before backup models sends no entries: no pickers, the chain still edits.
        ModelSettingsRequestProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "backend": "Codex", "backends": ["Codex"], "primary": "Copilot", "revision": "old", "limited": [],
                "choices": [["id": "Codex", "label": "Codex"]],
            ]))
        }
        let older = try await model.usageFallback()
        XCTAssertNil(older.models(at: 0))
        XCTAssertTrue(older.supportsChain)
    }

    /// A Mac that lists a backend again with another model: Antigravity is its own backend (it
    /// runs Gemini 4 Argon) and is listed twice with other models, Claude Code once.
    private func perModelFallback(entries: [[String: String]]? = nil, limitedModels: Bool = true,
                                  revision: String = "p1") throws -> Data {
        let entries = entries ?? [
            ["backend": "Antigravity", "model": "gemini-3.8-flash-medium", "effort": "",
             "label": "Antigravity · Gemini 3.8 Flash (Medium)",
             "limitedUntil": "2026-11-01T03:00:00Z", "limitedUntilLabel": "8:00 PM"],
            ["backend": "Antigravity", "model": "claude-sonnet-5-5-low", "effort": "",
             "label": "Antigravity · Claude Sonnet 5.5 (Low)"],
            ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": "high",
             "label": "Claude Code · claude-sonnet-5-5 · high"],
        ]
        let antigravity: [String: Any] = [
            "id": "Antigravity", "label": "Antigravity · Gemini 4 Argon (High)", "defaultModel": "Gemini 4 Argon (High)",
            "defaultModelID": "gemini-4-argon-high", "defaultEfforts": [String](),
            "models": [["id": "gemini-4-argon-high", "label": "Gemini 4 Argon (High)", "efforts": [String]()],
                       ["id": "gemini-3.8-flash-medium", "label": "Gemini 3.8 Flash (Medium)", "efforts": [String]()],
                       ["id": "claude-sonnet-5-5-low", "label": "Claude Sonnet 5.5 (Low)", "efforts": [String]()],
                       ["id": "gpt-oss-120b-medium", "label": "GPT-OSS 120B (Medium)", "efforts": [String]()]],
        ]
        var object: [String: Any] = [
            "backend": entries.first?["backend"] ?? "", "backends": entries.map { $0["backend"]! }, "entries": entries,
            "primary": "Antigravity", "revision": revision,
            "choices": [
                ["id": "Claude Code", "label": "Claude Code · opus", "defaultModel": "opus", "defaultModelID": "claude-opus-5-5",
                 "defaultEfforts": ["low", "high"],
                 "models": [["id": "claude-opus-5-5", "label": "claude-opus-5-5", "efforts": ["low", "medium", "high"]],
                            ["id": "claude-sonnet-5-5", "label": "claude-sonnet-5-5", "efforts": ["low", "high"]]]],
                ["id": "Codex", "label": "Codex"],
                ["id": "Copilot", "label": "Copilot · gpt-5.6",
                 "models": [["id": "gpt-5.6", "label": "gpt-5.6"], ["id": "gpt-5.6-mini", "label": "gpt-5.6-mini"]]],
            ],
            "primaryChoice": antigravity,
            "limited": [["backend": "Copilot", "until": "2026-11-01T05:00:00Z", "untilLabel": "10:00 PM"]],
        ]
        if limitedModels {
            object["limitedModels"] = [["backend": "Antigravity", "scope": "argon", "label": "Gemini 4 Argon",
                                        "until": "2026-11-01T03:00:00Z", "untilLabel": "8:00 PM"]]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ change: CantripUsageFallbackChange) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
    }

    private func entries(_ change: CantripUsageFallbackChange) throws -> [[String: String]] {
        let body = try body(change)
        XCTAssertEqual(Set(body.keys), ["revision", "entries"], "Only the whole chain is sent")
        let entries = try XCTUnwrap(body["entries"] as? [[String: String]])
        for entry in entries { XCTAssertEqual(Set(entry.keys), ["backend", "model", "effort"], "No read-only fields") }
        return entries
    }

    func testUsageFallbackDecodesPerModelChainAndOlderPayloads() throws {
        let state = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback())
        XCTAssertTrue(state.listsBackendsAgain)
        XCTAssertEqual(state.chain, ["Antigravity", "Antigravity", "Claude Code"])
        XCTAssertEqual(state.rows[0].label, "Antigravity · Gemini 3.8 Flash (Medium)")
        XCTAssertEqual(state.rows[0].limitedUntil, "2026-11-01T03:00:00Z")
        XCTAssertEqual(state.rows[0].limitedUntilLabel, "8:00 PM")
        XCTAssertNil(state.rows[1].limitedUntilLabel)
        XCTAssertEqual(state.primaryChoice?.id, "Antigravity")
        XCTAssertEqual(state.primaryChoice?.defaultModelID, "gemini-4-argon-high")
        XCTAssertEqual(state.choice("Claude Code")?.defaultModelID, "claude-opus-5-5")
        XCTAssertNil(state.choice("Copilot")?.defaultModelID)
        XCTAssertEqual(state.limitedModels, [.init(backend: "Antigravity", scope: "argon", label: "Gemini 4 Argon",
                                                   until: "2026-11-01T03:00:00Z", untilLabel: "8:00 PM")])
        XCTAssertEqual(state.title(at: 0), "Antigravity · Gemini 3.8 Flash (Medium)",
                       "The Mac's own backend with another model isn't skipped")
        XCTAssertEqual(state.title(at: 2), "Claude Code · claude-sonnet-5-5 · high")
        XCTAssertEqual(state.status, "At its usage limit: Copilot until 10:00 PM, Antigravity Gemini 4 Argon until 8:00 PM.")
        XCTAssertTrue(state.canResetLimits)
        XCTAssertEqual(Set(state.rowIDs).count, 3)

        // Only a model at its limit still offers Try every backend again.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: perModelFallback()) as? [String: Any])
        object["limited"] = [[String: String]]()
        let onlyModels = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(onlyModels.canResetLimits)
        XCTAssertEqual(onlyModels.status, "At its usage limit: Antigravity Gemini 4 Argon until 8:00 PM.")
        object["limitedModels"] = [[String: String]]()
        let none = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(none.canResetLimits)
        XCTAssertTrue(none.status.contains("only that model is skipped"))

        // A Mac from before repeats: entries without labels, no primaryChoice, limitedModels or defaultModelID.
        let older = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: [
            "backend": "Claude Code", "backends": ["Claude Code"], "primary": "Copilot", "revision": "o1",
            "entries": [["backend": "Claude Code", "model": "", "effort": ""]],
            "choices": [["id": "Claude Code", "label": "Claude Code · opus", "defaultModel": "opus",
                         "models": [["id": "claude-opus-5-5", "label": "claude-opus-5-5"]]]],
            "limited": [],
        ]))
        XCTAssertNil(older.primaryChoice)
        XCTAssertNil(older.limitedModels)
        XCTAssertNil(older.rows[0].label)
        XCTAssertNil(older.choice("Claude Code")?.defaultModelID)
        XCTAssertFalse(older.listsBackendsAgain)
        XCTAssertFalse(older.canResetLimits)
        XCTAssertEqual(older.title(at: 0), "Claude Code · opus")
        XCTAssertFalse(older.status.contains("only that model"), "Older Macs don't skip single models")
    }

    func testAddBackupOffersTheMacsBackendAndListedBackendsWithAnotherModel() throws {
        let state = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback())
        // Antigravity's own model and both listed ones are taken: the next free one is offered.
        XCTAssertEqual(state.takenModels("Antigravity"),
                       ["gemini-3.8-flash-medium", "claude-sonnet-5-5-low", "gemini-4-argon-high"])
        XCTAssertEqual(state.freeModel("Antigravity"), "gpt-oss-120b-medium")
        XCTAssertEqual(state.freeModel("Claude Code"), "", "Default runs opus, which no backup runs")
        XCTAssertEqual(state.freeModel("Codex"), "")
        XCTAssertEqual(state.freeModel("Copilot"), "", "An unknown default counts as its own model")
        XCTAssertEqual(state.addable.map(\.id), ["Claude Code", "Codex", "Copilot", "Antigravity"],
                       "Every backend with a free model, the Mac's own last")
        XCTAssertEqual(state.addable.map(state.addLabel),
                       ["Claude Code with another model", "Codex", "Copilot · gpt-5.6", "Antigravity with another model"])

        let added = try entries(XCTUnwrap(state.adding("Antigravity")))
        XCTAssertEqual(added.count, 4)
        XCTAssertEqual(added.last, ["backend": "Antigravity", "model": "gpt-oss-120b-medium", "effort": ""])
        XCTAssertEqual(Array(added.prefix(3)), [
            ["backend": "Antigravity", "model": "gemini-3.8-flash-medium", "effort": ""],
            ["backend": "Antigravity", "model": "claude-sonnet-5-5-low", "effort": ""],
            ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": "high"],
        ], "The chain is kept as it was")
        XCTAssertEqual(try entries(XCTUnwrap(state.adding("Claude Code"))).last,
                       ["backend": "Claude Code", "model": "", "effort": ""], "Default first when it's free")

        // Claude Code's default (opus) taken by a default backup: the next free model.
        var chain = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback(entries: [
            ["backend": "Claude Code", "model": "", "effort": ""],
            ["backend": "Codex", "model": "", "effort": ""],
        ]))
        XCTAssertEqual(chain.freeModel("Claude Code"), "claude-sonnet-5-5")
        XCTAssertNil(chain.freeModel("Codex"), "A backend without models is added once")
        XCTAssertFalse(chain.addable.map(\.id).contains("Codex"))
        XCTAssertEqual(chain.freeModel("Antigravity"), "gemini-3.8-flash-medium",
                       "The Mac's own backend never offers its own model, Default included")

        // Every model taken: the backend isn't offered.
        chain = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback(entries: [
            ["backend": "Claude Code", "model": "", "effort": ""],
            ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": ""],
            ["backend": "Antigravity", "model": "gemini-3.8-flash-medium", "effort": ""],
            ["backend": "Antigravity", "model": "claude-sonnet-5-5-low", "effort": ""],
            ["backend": "Antigravity", "model": "gpt-oss-120b-medium", "effort": ""],
        ]))
        XCTAssertNil(chain.adding("Claude Code"))
        XCTAssertNil(chain.adding("Antigravity"))
        XCTAssertEqual(chain.addable.map(\.id), ["Codex", "Copilot"])

        // The Mac's backend without a model picker has no primaryChoice: never offered.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: perModelFallback(entries: [])) as? [String: Any])
        object["primaryChoice"] = NSNull()
        let noPicker = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(noPicker.primaryChoice)
        XCTAssertEqual(noPicker.addable.map(\.id), ["Claude Code", "Codex", "Copilot"])
        XCTAssertEqual(noPicker.addable.map(noPicker.addLabel), ["Claude Code · opus", "Codex", "Copilot · gpt-5.6"],
                       "Backends not yet listed keep their own labels")
    }

    func testUsageFallbackRowsChangeMoveAndRemoveByPosition() throws {
        let state = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback())
        let changed = try entries(state.setting(1, model: "gpt-oss-120b-medium", effort: ""))
        XCTAssertEqual(changed.map { $0["model"] }, ["gemini-3.8-flash-medium", "gpt-oss-120b-medium", "claude-sonnet-5-5"],
                       "Only the second Antigravity backup changes")
        XCTAssertEqual(changed[2]["effort"], "high")
        let effort = try entries(state.setting(2, model: "claude-sonnet-5-5", effort: "low"))
        XCTAssertEqual(effort[2], ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": "low"])
        XCTAssertEqual(Array(effort.prefix(2)).map { $0["model"] }, ["gemini-3.8-flash-medium", "claude-sonnet-5-5-low"])

        let up = try entries(state.moving(2, by: -1))
        XCTAssertEqual(up.map { $0["model"] }, ["gemini-3.8-flash-medium", "claude-sonnet-5-5", "claude-sonnet-5-5-low"])
        let down = try entries(state.moving(0, by: 1))
        XCTAssertEqual(down.map { $0["model"] }, ["claude-sonnet-5-5-low", "gemini-3.8-flash-medium", "claude-sonnet-5-5"],
                       "The same backend's backups swap by position")
        let removed = try entries(state.removing(0))
        XCTAssertEqual(removed, [
            ["backend": "Antigravity", "model": "claude-sonnet-5-5-low", "effort": ""],
            ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": "high"],
        ], "Removing one Antigravity backup keeps the other")
        XCTAssertEqual(try entries(state.change(to: [])), [])
        XCTAssertEqual(try body(state.removing(0))["revision"] as? String, "p1")

        // A Mac with backends but no entries gets the order (it keeps each backup's model).
        let older = CantripUsageFallback(backend: "Codex", backends: ["Codex", "Claude Code"], primary: "Copilot",
                                         choices: [.init(id: "Codex", label: "Codex"), .init(id: "Claude Code", label: "Claude Code")],
                                         limited: [], revision: "o1")
        let moved = try body(older.moving(1, by: -1))
        XCTAssertEqual(moved["backends"] as? [String], ["Claude Code", "Codex"])
        XCTAssertNil(moved["entries"])
        XCTAssertEqual(try body(older.removing(0))["backends"] as? [String], ["Claude Code"])
        // The oldest Macs take one backup through `backend`.
        let oldest = CantripUsageFallback(backend: "Codex", primary: "Copilot",
                                          choices: [.init(id: "Codex", label: "Codex")], limited: [], revision: "o0")
        XCTAssertEqual(try body(oldest.removing(0)) as? [String: String], ["revision": "o0", "backend": ""])
    }

    func testBackupModelPickersLeaveOutModelsAnotherBackupRuns() throws {
        let state = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback(entries: [
            ["backend": "Antigravity", "model": "gemini-3.8-flash-medium", "effort": ""],
            ["backend": "Antigravity", "model": "claude-sonnet-5-5-low", "effort": ""],
            ["backend": "Claude Code", "model": "claude-sonnet-5-5", "effort": "high"],
            ["backend": "Claude Code", "model": "", "effort": ""],
            ["backend": "Codex", "model": "", "effort": ""],
        ]))
        // The Mac's own model (Argon) and the other Antigravity backup's are left out; its own stays.
        XCTAssertEqual(state.models(at: 0)?.map(\.id), ["gemini-3.8-flash-medium", "gpt-oss-120b-medium"])
        XCTAssertEqual(state.models(at: 1)?.map(\.id), ["claude-sonnet-5-5-low", "gpt-oss-120b-medium"])
        XCTAssertFalse(state.offersDefault(at: 0), "Default runs the Mac's own model")
        // Claude Code's default backup runs opus: the other one can't pick opus or Default.
        XCTAssertEqual(state.models(at: 2)?.map(\.id), ["claude-sonnet-5-5"])
        XCTAssertFalse(state.offersDefault(at: 2))
        XCTAssertEqual(state.models(at: 3)?.map(\.id), ["claude-opus-5-5"], "Sonnet is the other backup's")
        XCTAssertTrue(state.offersDefault(at: 3), "The row's current Default stays offered")
        XCTAssertNil(state.models(at: 4), "No model picker for a backend without models")
        XCTAssertEqual(state.efforts(at: 2), ["low", "high"], "The chosen model's efforts")
        XCTAssertEqual(state.efforts(at: 3), ["low", "high"], "Default: its default efforts")
        XCTAssertEqual(state.efforts(at: 0), [])

        // A model that left the catalog stays the row's selection.
        let gone = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback(entries: [
            ["backend": "Claude Code", "model": "claude-haiku-4", "effort": ""],
        ]))
        XCTAssertEqual(gone.models(at: 0)?.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertTrue(gone.offersDefault(at: 0))
    }

    func testPerModelChainRoundTripsThroughTheHostAndShowsItsErrors() async throws {
        let model = try await model()
        var current = try perModelFallback()
        var posts: [[String: Any]] = []
        ModelSettingsRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = stream.read(&bytes, maxLength: bytes.count)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                posts.append(body)
                let entries = try XCTUnwrap(body["entries"] as? [[String: String]])
                let keys = entries.map { "\($0["backend"]!)/\($0["model"]!)" }
                guard Set(keys).count == keys.count else {
                    return (400, Data(#"{"error":"Claude Code · opus is in the chain twice. Each backend and model can be listed once."}"#.utf8))
                }
                current = try self.perModelFallback(entries: entries, revision: "p\(posts.count + 1)")
            }
            return (200, current)
        }
        var state = try await model.usageFallback()
        let added = await model.updateUsageFallback(try XCTUnwrap(state.adding("Antigravity")))
        state = try XCTUnwrap(added)
        XCTAssertEqual(state.chain, ["Antigravity", "Antigravity", "Claude Code", "Antigravity"])
        XCTAssertEqual(state.rows.last?.model, "gpt-oss-120b-medium")
        XCTAssertEqual(posts.last?["revision"] as? String, "p1")
        XCTAssertNil(posts.last?["backends"])
        XCTAssertNil(state.adding("Antigravity"), "Every other Antigravity model is listed now")

        let failed = await model.updateUsageFallback(state.setting(3, model: "claude-sonnet-5-5-low", effort: ""))
        XCTAssertNil(failed)
        XCTAssertTrue(model.errorMessage?.contains("is in the chain twice") == true, "The host's message is shown")
    }

    func testBackupRowsFitANarrowFoldedWidthAndLargeText() throws {
        let state = try JSONDecoder().decode(CantripUsageFallback.self, from: perModelFallback())
        // The folded iPhone Duo leaves about 382 pt beside its vertical bar; 300 pt is a narrow split.
        for width: CGFloat in [300, 382, 720] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                for index in state.rows.indices {
                    let row = UIHostingController(rootView: CantripUsageFallbackRow(fallback: state, index: index, saving: false) { _ in }
                        .environment(\.dynamicTypeSize, size))
                    let measured = row.sizeThatFits(in: CGSize(width: width, height: 5000))
                    XCTAssertLessThanOrEqual(measured.width, width + 1, "Row \(index + 1) at \(width) pt, \(size)")
                    XCTAssertGreaterThan(measured.height, 20)
                    XCTAssertLessThan(measured.height, 4000)
                    if index == 0, width == 382, size == .large || size == .accessibility3 {
                        let renderer = ImageRenderer(content: row.rootView.frame(width: width).padding()
                            .background(Color(uiColor: .systemBackground)))
                        renderer.scale = 2
                        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                        attachment.name = "backup-row-\(size)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
        XCTAssertEqual(CantripUsageFallbackRow.name(state, index: 1), "Antigravity backup 2")
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

    // MARK: Tab backends

    /// A Mac with tab backends on Copilot: the tab on `own` (nil follows the Mac's), Claude Code
    /// signed out and Antigravity not installed.
    private func backendSnapshot(own: String? = nil, busy: String? = nil, reason: String? = nil,
                                 backends: [[String: Any]] = tabBackendChoices) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot(reason: reason ?? busy)) as? [String: Any])
        object["backend"] = own ?? "Copilot"
        object["macBackend"] = "Copilot"
        object["backends"] = backends
        if let own { object["ownBackend"] = own }
        if let busy { object["backendUnavailableReason"] = busy }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) throws -> CantripModelSettings {
        try JSONDecoder().decode(CantripModelSettings.self, from: data)
    }

    private func body(_ change: CantripModelSettingsChange) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
    }

    private func postedBody(_ request: URLRequest) throws -> [String: Any] {
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 2048)
        let count = stream.read(&bytes, maxLength: bytes.count)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
    }

    func testBackendKeysDecodeAndOlderMacsHideThePicker() throws {
        let own = try decode(backendSnapshot(own: "Claude Code"))
        XCTAssertEqual(own.backend, "Claude Code")
        XCTAssertEqual(own.ownBackend, "Claude Code")
        XCTAssertEqual(own.macBackend, "Copilot")
        XCTAssertEqual(own.backends?.map(\.id), ["Copilot", "Claude Code", "Codex", "Antigravity"])
        XCTAssertEqual(own.backends?.map(\.available), [true, true, true, false])
        XCTAssertNil(own.backends?.first?.note)
        XCTAssertNil(own.backendUnavailableReason)
        XCTAssertTrue(own.offersBackends)
        XCTAssertEqual(own.backendTag, "Claude Code")
        XCTAssertEqual(own.backendChoice("Copilot")?.menuLabel, "Copilot")
        XCTAssertEqual(own.backendChoice("Antigravity")?.menuLabel, "Antigravity — Not installed on the Mac")
        XCTAssertEqual(own.ownBackendNote, "Claude Code: Signed out on the Mac")
        XCTAssertEqual(own.backendFooter, "Only this tab changes. The next message runs on Claude Code and continues "
                       + "this conversation with the recent history; at a usage limit it moves to the Mac's backend first.")

        let busy = "Wait for this tab and its queued work to finish before changing model settings."
        let following = try decode(backendSnapshot(busy: busy))
        XCTAssertEqual(following.backend, "Copilot")
        XCTAssertNil(following.ownBackend, "A tab that follows the Mac's backend has no ownBackend")
        XCTAssertEqual(following.backendTag, CantripModelSettings.macBackendTag)
        XCTAssertEqual(following.macBackendLabel, "Mac's backend (Copilot)")
        XCTAssertNil(following.ownBackendNote)
        XCTAssertEqual(following.backendUnavailableReason, busy)
        XCTAssertTrue(following.backendFooter.hasPrefix("Only this tab changes. Pick a backend and the next message runs there"))

        let home = try decode(backendSnapshot(backends: []))
        XCTAssertEqual(home.backends, [])
        XCTAssertFalse(home.offersBackends, "Cantrip Home keeps the Mac's backend: no picker")

        let older = try decode(snapshot())
        XCTAssertNil(older.backend)
        XCTAssertNil(older.ownBackend)
        XCTAssertNil(older.macBackend)
        XCTAssertNil(older.backends)
        XCTAssertNil(older.backendUnavailableReason)
        XCTAssertFalse(older.offersBackends, "A Mac from before tab backends shows no picker")
        XCTAssertEqual(older.macBackendLabel, "Mac's backend")
    }

    func testBackendChangeSendsNullForTheMacsAndOmitsItForModelChanges() throws {
        let mac = try body(CantripModelSettingsChange(revision: "v1", backend: .mac))
        XCTAssertEqual(Set(mac.keys), ["revision", "backend"])
        XCTAssertTrue(mac["backend"] is NSNull, "null moves the tab back to the Mac's backend")
        let raw = String(decoding: try JSONEncoder().encode(CantripModelSettingsChange(revision: "v1", backend: .mac)), as: UTF8.self)
        XCTAssertTrue(raw.contains(#""backend":null"#), raw)

        let named = try body(CantripModelSettingsChange(revision: "v1", backend: .named("Claude Code")))
        XCTAssertEqual(Set(named.keys), ["revision", "backend"])
        XCTAssertEqual(named["backend"] as? String, "Claude Code")
        XCTAssertEqual(named["revision"] as? String, "v1")

        let pick = try body(CantripModelSettingsChange(revision: "v1", selection: selection))
        XCTAssertEqual(Set(pick.keys), ["revision", "usesDefaults", "model", "effort", "contextTier"],
                       "A model change leaves the backend out, so the tab keeps it")
        XCTAssertEqual(pick["usesDefaults"] as? Bool, false)
        let auto = try body(CantripModelSettingsChange(revision: "v1", selection: nil))
        XCTAssertEqual(Set(auto.keys), ["revision", "usesDefaults"])

        let settings = try decode(backendSnapshot(own: "Codex"))
        XCTAssertNil(settings.backendChange(to: "Codex"), "Picking the current backend saves nothing")
        XCTAssertNil(settings.backendChange(to: "Antigravity"), "A backend not installed on the Mac can't be picked")
        XCTAssertNil(settings.backendChange(to: "Unknown"))
        XCTAssertEqual(settings.backendChange(to: CantripModelSettings.macBackendTag)?.backend, .mac)
        XCTAssertEqual(settings.backendChange(to: "Claude Code")?.backend, .named("Claude Code"),
                       "A signed-out backend can still be picked; its note says why it may not run")
        XCTAssertEqual(settings.backendChange(to: "Claude Code")?.revision, "v1")
        XCTAssertNil(try decode(backendSnapshot()).backendChange(to: CantripModelSettings.macBackendTag))
    }

    func testBackendSwitchPostsOnlyRevisionAndBackendAndBusyTabsNeverPost() async throws {
        let model = try await model()
        var methods: [String] = []
        var posts: [[String: Any]] = []
        // The Mac runs a backend without per-tab models: the model can't change here, the backend can.
        var current = try backendSnapshot(reason: "Example CLI has no per-tab models. Choose Copilot, Claude Code, Codex or Antigravity for this tab.")
        ModelSettingsRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.id)/model-settings")
            if request.httpMethod == "POST" {
                let body = try self.postedBody(request)
                posts.append(body)
                return (200, try self.backendSnapshot(own: body["backend"] as? String))
            }
            return (200, current)
        }
        var saved = await model.updateModelSettings(id: id,
            change: CantripModelSettingsChange(revision: "v1", backend: .named("Codex")), identity: model.usageIdentity)
        XCTAssertTrue(saved, model.errorMessage ?? "")
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(Set(try XCTUnwrap(posts.last).keys), ["revision", "backend"])
        XCTAssertEqual(posts.last?["backend"] as? String, "Codex")

        current = try backendSnapshot(own: "Codex")
        saved = await model.updateModelSettings(id: id,
            change: CantripModelSettingsChange(revision: "v1", backend: .mac), identity: model.usageIdentity)
        XCTAssertTrue(saved, model.errorMessage ?? "")
        XCTAssertTrue(posts.last?["backend"] is NSNull)
        XCTAssertEqual(posts.count, 2)

        for (data, expected) in [
            (try backendSnapshot(busy: "Turn Council mode off to choose this tab's backend and model."), "Council mode"),
            (try backendSnapshot(backends: []), "runs on the Mac's backend"),
            (try snapshot(), "Update Cantrip on the Mac"),
        ] {
            methods = []
            current = data
            saved = await model.updateModelSettings(id: id,
                change: CantripModelSettingsChange(revision: "v1", backend: .named("Claude Code")), identity: model.usageIdentity)
            XCTAssertFalse(saved)
            XCTAssertEqual(methods, ["GET"], "\(expected): the backend must not be posted")
            XCTAssertTrue(model.errorMessage?.contains(expected) == true, model.errorMessage ?? "no error")
        }
        XCTAssertEqual(posts.count, 2)
    }

    /// The Backend picker's UIKit menu button, found by its first choice.
    private func backendMenu(in window: UIWindow) -> UIButton? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(window).compactMap { $0 as? UIButton }.first { button in
            button.menu?.children.contains { ($0 as? UIAction)?.title.hasPrefix("Mac's backend") == true } == true
        }
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testBackendPickerSavesAtOnceAndSkipsBackendsNotInstalled() async throws {
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: id, title: "Example project tab", workdir: "/tmp",
            isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsModelSettings: true)
        var current = try backendSnapshot()
        var posts: [[String: Any]] = []
        ModelSettingsRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let body = try self.postedBody(request)
                posts.append(body)
                current = try self.backendSnapshot(own: body["backend"] as? String)
            }
            return (200, current)
        }
        let controller = UIHostingController(rootView: CantripModelSettingsView(
            model: model, session: session, identity: model.usageIdentity))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func actions() async throws -> [UIAction] {
            var found: [UIAction] = []
            try await waitUntil {
                found = backendMenu(in: window)?.menu?.children.compactMap { $0 as? UIAction } ?? []
                return !found.isEmpty
            }
            return found
        }
        func selected() async throws -> String? { try await actions().first { $0.state == .on }?.title }

        var menu = try await actions()
        XCTAssertEqual(menu.map(\.title), ["Mac's backend (Copilot)", "Copilot", "Claude Code — Signed out on the Mac",
                                           "Codex", "Antigravity — Not installed on the Mac"])
        XCTAssertEqual(menu.filter { $0.attributes.contains(.disabled) }.map(\.title),
                       ["Antigravity — Not installed on the Mac"], "Only a backend not installed is greyed out")
        let initial = try await selected()
        XCTAssertEqual(initial, "Mac's backend (Copilot)")

        try XCTUnwrap(menu.first { $0.title == "Codex" }).performWithSender(nil, target: nil)
        try await waitUntil { posts.count == 1 }
        XCTAssertEqual(Set(posts[0].keys), ["revision", "backend"], "Picking a backend saves only the backend")
        XCTAssertEqual(posts[0]["backend"] as? String, "Codex")
        try await waitUntil { (backendMenu(in: window)?.menu?.children.compactMap { $0 as? UIAction }
            .first { $0.state == .on }?.title) == "Codex" }

        menu = try await actions()
        try XCTUnwrap(menu.first { $0.title == "Mac's backend (Copilot)" }).performWithSender(nil, target: nil)
        try await waitUntil { posts.count == 2 }
        XCTAssertTrue(posts[1]["backend"] is NSNull, "The Mac's backend is sent as null")
        XCTAssertEqual(Set(posts[1].keys), ["revision", "backend"])
        try await waitUntil { (backendMenu(in: window)?.menu?.children.compactMap { $0 as? UIAction }
            .first { $0.state == .on }?.title) == "Mac's backend (Copilot)" }
    }

    /// Renders the sheet with its Backend section for review. Set TEST_RUNNER_TAB_BACKEND_ARTIFACT_DIR
    /// (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testBackendSectionScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_TAB_BACKEND_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_TAB_BACKEND_ARTIFACT_DIR to render the Backend section.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: id, title: "Example project tab", workdir: "/tmp",
            isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, status: nil,
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsModelSettings: true)
        var current = Data()
        ModelSettingsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Opening settings must not modify the Mac")
            return (200, current)
        }
        func capture(_ name: String, _ data: Data, style: UIUserInterfaceStyle = .dark, width: CGFloat = 393,
                     height: CGFloat = 852, size: DynamicTypeSize = .large) async throws {
            current = data
            let view = CantripModelSettingsView(model: model, session: session, identity: model.usageIdentity)
                .dynamicTypeSize(size)
            let controller = UIHostingController(rootView: view)
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(700))
            controller.view.layoutIfNeeded()
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            for scroll in descendants(controller.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 0 {
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "\(name) scrolls sideways")
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: output.appendingPathComponent("tab-backend-\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "tab-backend-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let own = try backendSnapshot(own: "Claude Code")
        try await capture("dark", own)
        try await capture("light", own, style: .light)
        try await capture("follows-mac-dark", try backendSnapshot())
        try await capture("busy-dark", try backendSnapshot(busy: "Turn Council mode off to choose this tab's backend and model."))
        // The folded Duo beside its bar, a Duo pane, and the largest text on a narrow width.
        try await capture("duo-folded-dark", own, width: 382)
        try await capture("duo-pane-light", own, style: .light, width: 768, height: 1024)
        try await capture("ax3-dark", own, width: 320, height: 1400, size: .accessibility3)
        try await capture("older-mac-dark", try snapshot())
    }

    private func privateSnapshot(revision: String = "private-v1", reason: String? = nil, api: String? = nil) throws -> Data {
        var configuration: [String: Any] = ["baseURL": "https://llm.example.ts.net/ollama", "model": "local:latest",
                                            "contextWindow": 8192, "systemPrompt": "Keep this conversation local."]
        if let api { configuration["api"] = api }
        var value: [String: Any] = ["revision": revision, "configuration": configuration]
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
                XCTAssertNil(configuration["api"], "A Mac without the API choice gets the four fields it accepts")
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

    func testPrivateLocalServerAPIRoundTripsAndOldMacsKeepTheirs() async throws {
        let legacy = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot())
        XCTAssertNil(legacy.configuration.api)
        let legacyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy.configuration)) as? [String: Any])
        XCTAssertEqual(Set(legacyBody.keys), ["baseURL", "model", "contextWindow", "systemPrompt"])
        let ollama = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot(api: "ollama"))
        XCTAssertEqual(ollama.configuration.api, .ollama)
        XCTAssertThrowsError(try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot(api: "cloud")))

        let model = try await model()
        let settings = try JSONDecoder().decode(CantripPrivateLocalSettings.self, from: privateSnapshot(api: "ollama"))
        var configuration = settings.configuration
        configuration.api = .openAI
        configuration.baseURL = "https://llm.example.ts.net/v1"
        var posted: [String: Any]?
        ModelSettingsRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any])
                posted = body["configuration"] as? [String: Any]
            }
            return (200, try self.privateSnapshot(api: "ollama"))
        }
        let saved = await model.updatePrivateLocalSettings(id: id,
            change: .init(revision: settings.revision, configuration: configuration), identity: model.usageIdentity)
        XCTAssertTrue(saved, model.errorMessage ?? "")
        XCTAssertEqual(posted?["api"] as? String, "openai")
        XCTAssertEqual(posted?["baseURL"] as? String, "https://llm.example.ts.net/v1")

        XCTAssertEqual(CantripPrivateLocalAPI.allCases.map(\.rawValue), ["ollama", "openai"])
        XCTAssertEqual(CantripPrivateLocalAPI.openAI.label, "OpenAI-compatible (oMLX, LM Studio, mlx-serve)")
        XCTAssertTrue(CantripPrivateLocalAPI.openAI.urlPlaceholder.hasSuffix("/v1"))
        XCTAssertTrue(CantripPrivateLocalAPI.openAI.urlLabel.contains("/v1"))
        XCTAssertFalse(CantripPrivateLocalAPI.ollama.urlPlaceholder.hasSuffix("/v1"))
        XCTAssertTrue(CantripPrivateLocalSettingsView.footer(for: .openAI).contains("set on the server"))
        XCTAssertFalse(CantripPrivateLocalSettingsView.footer(for: .ollama).contains("set on the server"))
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
            XCTAssertNil(query?.queryItems?.first(where: { $0.name == "api" }), "Old Macs use their saved server API")
            return (200, Data(#"{"models":["local:latest"]}"#.utf8))
        }
        let models = try await api.privateLocalModels(id: id, baseURL: "https://llm.example.ts.net/ollama")
        XCTAssertEqual(models, ["local:latest"])
        ModelSettingsRequestProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(query?.queryItems?.first(where: { $0.name == "baseURL" })?.value, "https://llm.example.ts.net/v1")
            XCTAssertEqual(query?.queryItems?.first(where: { $0.name == "api" })?.value, "openai")
            return (200, Data(#"{"models":["Local-8B-4bit"]}"#.utf8))
        }
        let openAIModels = try await api.privateLocalModels(id: id, baseURL: "https://llm.example.ts.net/v1", api: .openAI)
        XCTAssertEqual(openAIModels, ["Local-8B-4bit"])
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
            // The OpenAI-compatible choice has the longest picker and URL labels.
            return (200, try self.privateSnapshot(api: "openai"))
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
                // Backups that list a backend again, one at its limit: the longest rows.
                return (200, try self.perModelFallback())
            }
            reads += 1
            // A tab on its own backend, signed out there: the Backend section's longest rows.
            return (200, try self.backendSnapshot(own: "Claude Code"))
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
                XCTAssertEqual(fallbackReads, previousFallbackReads, "The backups are in Settings › Models, not the tab's sheet")
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
                // The rest of the sheet, further down.
                if let form = scrollViews.max(by: { $0.contentSize.height < $1.contentSize.height }) {
                    form.setContentOffset(CGPoint(x: 0, y: max(0, form.contentSize.height * 0.45)), animated: false)
                    try await Task.sleep(for: .milliseconds(300))
                    let fallbacks = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    fallbacks.name = "Model settings scrolled \(Int(width)) \(size)"
                    fallbacks.lifetime = .keepAlways
                    add(fallbacks)
                }
            }
        }
    }
}
