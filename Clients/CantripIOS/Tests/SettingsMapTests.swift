import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class SettingsMapRequestProtocol: URLProtocol {
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

/// The shared settings map: its pages, the status card, Macs with last seen, model tiers from the
/// Mac, the per-tab picker's tiers, and settings saved by the previous version.
@MainActor
final class SettingsMapTests: XCTestCase {
    private static let tiersJSON: [String: Any] = [
        "tiers": ["fast", "standard", "deep"], "revision": "tiers-1",
        "backends": [[
            "id": "Copilot", "label": "Copilot",
            "models": [
                ["id": "claude-haiku-5.5", "label": "claude-haiku-5.5", "efforts": ["low", "high"],
                 "price": "10 in · 50 out credits per 1M tokens"],
                ["id": "claude-opus-5.5", "label": "claude-opus-5.5", "efforts": ["high", "xhigh"]],
                ["id": "gpt-5.6-sol", "label": "gpt-5.6-sol", "efforts": ["high"]],
            ],
            "cells": [
                ["tier": "fast", "label": "Fast", "choices": [["model": "claude-haiku-5.5", "effort": "low", "label": "claude-haiku-5.5", "offered": true]],
                 "isDefault": true, "model": "claude-haiku-5.5", "effort": "low"],
                ["tier": "standard", "label": "Standard", "choices": [["model": "gpt-5.6-sol", "effort": "high"]],
                 "isDefault": true, "model": "gpt-5.6-sol", "effort": "high"],
                ["tier": "deep", "label": "Deep", "choices": [["model": "gone-1", "effort": "", "offered": false],
                                                             ["model": "claude-opus-5.5", "effort": "xhigh"]],
                 "isDefault": false, "model": "claude-opus-5.5", "effort": "xhigh", "note": "gone-1 isn't offered, so claude-opus-5.5"],
            ],
        ]],
    ]

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsMapRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            SettingsMapRequestProtocol.handler = nil
        }
        return client
    }

    private func model() async throws -> CantripRemoteModel {
        let model = CantripRemoteModel(urlSession: client())
        let configured = await model.configure(url: "https://cantrip.example",
                                              pairingToken: "settings-map-test", tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in model.setAppActive(false); model.clearConfiguration() }
        return model
    }

    func testPagesFollowTheSharedMapAndReopenTheLastOne() {
        XCTAssertEqual(SettingsPage.allCases.map(\.title), [
            "Macs", "Models", "Tools & sign-ins", "Memory", "Voice", "Notifications", "Appearance", "About & Updates",
        ])
        XCTAssertEqual(SettingsPage.available, SettingsPage.allCases, "the iPhone shows every page")
        XCTAssertTrue(SettingsPage.allCases.allSatisfy { !$0.summary.isEmpty && !$0.systemImage.isEmpty })
        XCTAssertEqual(SettingsView.restoredPage("models"), .models)
        XCTAssertEqual(SettingsView.restoredPage("gone"), .macs, "an unknown page opens Macs")
        XCTAssertEqual(SettingsView.restoredPage(""), .macs)
        XCTAssertEqual(SettingsPage.lastPageKey, "cantrip.settings.lastPage")
    }

    func testModelTiersLoadAndSaveOneCellOnTheMac() async throws {
        let model = try await model()
        var posted: [String: Any]?
        SettingsMapRequestProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/model-tiers")
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map { stream in
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                    return data
                })
                posted = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (200, try JSONSerialization.data(withJSONObject: Self.tiersJSON))
        }
        let tiers = try await model.modelTiers()
        let copilot = try XCTUnwrap(tiers.backend("Copilot"))
        XCTAssertEqual(copilot.cells.map(\.tier), ["fast", "standard", "deep"])
        let deep = try XCTUnwrap(copilot.cells.last)
        XCTAssertEqual(copilot.runs(deep), "claude-opus-5.5 · xhigh")
        XCTAssertEqual(deep.note, "gone-1 isn't offered, so claude-opus-5.5")
        XCTAssertEqual(deep.choices.first?.offered, false)
        XCTAssertEqual(copilot.tier(of: "claude-opus-5.5")?.tier, "deep")
        XCTAssertEqual(copilot.model("claude-haiku-5.5")?.price, "10 in · 50 out credits per 1M tokens")
        XCTAssertFalse(CantripModelTiers.summary("deep").isEmpty)

        let change = CantripModelTiersChange.set(deep, on: "Copilot", to: [.init(model: "claude-opus-5.5", effort: "high", label: "x", offered: true)],
                                                 revision: tiers.revision)
        let saved = await model.updateModelTiers(change)
        XCTAssertNotNil(saved)
        XCTAssertEqual(posted?["revision"] as? String, "tiers-1")
        XCTAssertEqual(posted?["backend"] as? String, "Copilot")
        XCTAssertEqual(posted?["tier"] as? String, "deep")
        XCTAssertEqual(posted?["choices"] as? [[String: String]], [["model": "claude-opus-5.5", "effort": "high"]],
                       "only a choice's model and effort go back to the Mac")
        let reset = await model.updateModelTiers(.resetting(deep, on: "Copilot", revision: "tiers-1"))
        XCTAssertNotNil(reset)
        XCTAssertEqual(posted?["reset"] as? Bool, true)

        SettingsMapRequestProtocol.handler = { _ in (404, Data("{\"error\":\"not found\"}".utf8)) }
        do {
            _ = try await model.modelTiers()
            XCTFail("an older Mac has no tiers")
        } catch CantripRemoteError.modelTiersUnsupported {}
    }

    func testTabPickerShowsTiersFirstAndAutoNamesTheMacDefault() throws {
        let json: [String: Any] = [
            "selection": ["model": "deep", "effort": "", "contextTier": ""],
            "defaults": ["model": "claude-opus-5.5", "effort": "xhigh", "contextTier": ""],
            "usesDefaults": false, "revision": "r1", "isRefreshing": false,
            "models": [
                ["id": "fast", "reasoningEfforts": ["low", "high"], "contextTiers": []],
                ["id": "standard", "reasoningEfforts": ["high"], "contextTiers": []],
                ["id": "deep", "reasoningEfforts": ["high", "xhigh"], "contextTiers": []],
                ["id": "claude-opus-5.5", "reasoningEfforts": ["high", "xhigh"], "contextTiers": ["default"], "contextWindow": 200_000,
                 "price": ["input": 400, "output": 2000, "cachedInput": 20, "batchSize": 1_000_000]],
                ["id": "mai-code-2-flash", "price": ["input": 0, "output": 0]],
            ],
            "tiers": [
                ["id": "fast", "label": "Fast", "model": "claude-haiku-5.5", "modelLabel": "claude-haiku-5.5", "effort": "low"],
                ["id": "standard", "label": "Standard", "model": "gpt-5.6-sol", "modelLabel": "gpt-5.6-sol", "effort": "high"],
                ["id": "deep", "label": "Deep", "model": "claude-opus-5.5", "modelLabel": "claude-opus-5.5", "effort": "xhigh"],
            ],
        ]
        let settings = try JSONDecoder().decode(CantripModelSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.catalogModels.map(\.id), ["claude-opus-5.5", "mai-code-2-flash"], "tiers aren't listed as models")
        XCTAssertEqual(settings.label("deep"), "Deep · claude-opus-5.5")
        XCTAssertEqual(settings.label("claude-opus-5.5"), "claude-opus-5.5")
        XCTAssertEqual(settings.autoLabel, "Auto (Mac default: claude-opus-5.5)")
        XCTAssertNil(settings.validationError(settings.selection), "a tier is a valid pick")
        XCTAssertNotNil(settings.validationError(.init(model: "deep", effort: "max", contextTier: "")))
        XCTAssertEqual(settings.catalogModels.first?.summary, "200k context · 400 in · 2000 out credits per 1M tokens")
        XCTAssertEqual(settings.catalogModels.last?.summary, "No AI credits")

        // A Mac from before tiers sends no `tiers`.
        var older = json
        older["tiers"] = nil
        older["models"] = Array((json["models"] as! [[String: Any]]).dropFirst(3))
        let old = try JSONDecoder().decode(CantripModelSettings.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(old.tiers)
        XCTAssertEqual(old.catalogModels.count, 2)
    }

    /// Settings › Tools & sign-ins reads the Mac's shared MCP list: the same status words as
    /// Cantrip's own Settings, which backends use each server, and Macs from before `credentials`.
    func testToolsPageShowsEachServersStatusAndBackends() throws {
        let json: [String: Any] = ["revision": "r", "supportsApproval": true, "servers": [
            ["name": "notes", "remote": false, "oauth": false, "relayed": false, "enabled": true,
             "disabledBackends": [String](), "credentials": false],
            ["name": "flows", "remote": true, "oauth": false, "relayed": true, "enabled": true,
             "disabledBackends": ["Codex"], "credentials": true],
            ["name": "design", "remote": true, "oauth": true, "relayed": true, "enabled": true,
             "disabledBackends": ["Codex", "Antigravity"], "state": ["phase": "failed", "message": "Sign-in failed."]],
            ["name": "errors", "remote": true, "oauth": true, "relayed": true, "enabled": true,
             "disabledBackends": [String](), "state": ["phase": "ready", "expiresAt": "2026-11-01T18:30:00Z"]],
            ["name": "old", "remote": false, "oauth": false, "relayed": false, "enabled": false, "disabledBackends": [String]()],
        ]]
        let snapshot = try JSONDecoder().decode(CantripMCPSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let byName = Dictionary(uniqueKeysWithValues: snapshot.servers.map { ($0.name, $0) })
        let status = { (name: String) in CantripMCPServersView.status(try XCTUnwrap(byName[name])) }
        XCTAssertEqual(try status("notes"), "Ready")
        XCTAssertEqual(try status("flows"), "Credentials in Mac keychain")
        XCTAssertEqual(try status("design"), "Sign-in failed")
        XCTAssertEqual(CantripMCPServersView.connectLabel(try XCTUnwrap(byName["design"])), "Retry")
        XCTAssertEqual(CantripMCPServersView.connectLabel(try XCTUnwrap(byName["errors"])), "Connect")
        XCTAssertTrue(try status("errors").hasPrefix("Signed in · token until "))
        XCTAssertEqual(try status("old"), "Off")
        XCTAssertNil(byName["old"]?.credentials, "a Mac from before 1.1.13 sends no credentials flag")

        let backends = { (name: String) in CantripMCPServersView.kindAndBackends(try XCTUnwrap(byName[name])) }
        XCTAssertEqual(try backends("notes"), "Local · All backends")
        XCTAssertEqual(try backends("flows"), "Remote · via Cantrip · Copilot, Claude Code, Antigravity")
        XCTAssertEqual(try backends("design"), "Remote · via Cantrip · Copilot, Claude Code")
        XCTAssertEqual(try backends("old"), "Local")
    }

    func testStatusCardNamesTheModelAndBackups() throws {
        let fallback = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: [
            "backend": "Claude Code", "backends": ["Claude Code", "Codex"], "primary": "Copilot", "revision": "f1",
            "entries": [["backend": "Claude Code", "model": "deep", "effort": "", "label": "Claude Code · Deep · opus · xhigh"],
                        ["backend": "Codex", "model": "", "effort": "", "label": "Codex"]],
            "choices": [["id": "Claude Code", "label": "Claude Code"], ["id": "Codex", "label": "Codex"]],
            "primaryChoice": ["id": "Copilot", "label": "Copilot", "defaultModel": "claude-opus-5.5", "defaultModelID": "claude-opus-5.5"],
            "limited": [], "limitedModels": [],
        ] as [String: Any]))
        XCTAssertEqual(SettingsStatusCard.model(fallback), "Copilot · claude-opus-5.5")
        XCTAssertEqual(SettingsStatusCard.backups(fallback), "Claude Code · Deep, then Codex")
        let off = try JSONDecoder().decode(CantripUsageFallback.self, from: JSONSerialization.data(withJSONObject: [
            "backend": "", "backends": [], "primary": "Codex", "revision": "f2", "choices": [], "limited": [],
        ] as [String: Any]))
        XCTAssertEqual(SettingsStatusCard.model(off), "Codex")
        XCTAssertEqual(SettingsStatusCard.backups(off), "Off")
    }

    func testMacsRememberWhenTheyWereLastSeenWithoutANewKey() throws {
        let suite = "settings-map-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var tokens: [String: String] = [:]
        let store = ServerCredentialStore(read: { tokens[$0] }, write: { tokens[$0] = $1 }, remove: { tokens[$0] = nil })
        // A profile list saved by the previous version: no lastConnectedAt.
        let id = UUID()
        let saved = #"{"servers":[{"id":"\#(id.uuidString)","name":"Studio","url":"https://studio.example.ts.net","tailscaleOnly":false,"usesLegacyHistory":false}],"selectedID":"\#(id.uuidString)"}"#
        defaults.set(Data(saved.utf8), forKey: "cantrip.saved-servers.v1")
        let profiles = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: store)
        XCTAssertNil(profiles.loadIssue)
        XCTAssertEqual(profiles.servers.map(\.name), ["Studio"])
        XCTAssertNil(profiles.servers.first?.lastConnectedAt)
        let keys = Set(defaults.dictionaryRepresentation().keys)

        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        profiles.markConnected(id, at: seen)
        XCTAssertEqual(profiles.servers.first?.lastConnectedAt, seen)
        profiles.markConnected(id, at: seen.addingTimeInterval(20))
        XCTAssertEqual(profiles.servers.first?.lastConnectedAt, seen, "saved at most once a minute")
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), keys, "last seen lives in the saved profile")
        let reloaded = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: store)
        XCTAssertEqual(reloaded.servers.first?.lastConnectedAt, seen)
        XCTAssertEqual(reloaded.selectedID, id)

        XCTAssertEqual(SettingsMacRow.Status.connected("Tailscale").text, "Connected · Tailscale")
        XCTAssertEqual(SettingsMacRow.Status.missingToken.text, "Pairing token missing on this device")
        XCTAssertTrue(SettingsMacRow.Status.lastSeen(seen).text.hasPrefix("Last seen "))
        XCTAssertEqual(SettingsMacRow.Status.neverConnected.text, "Not connected yet")
    }

    /// Settings saved by the previous version keep their values: every page reads the same keys.
    func testSettingsSavedByThePreviousVersionShowTheSameValues() throws {
        let defaults = UserDefaults.standard
        let previous: [String: Any] = [
            "hermes.voiceEngine": "qwen", "hermes.voicePause": 3.5, "hermes.sttEngine": "apple",
            "hermes.showSteps": true, "hermes.qwenPreset": "vivian-plain", "hermes.qwenRate": 1.3,
            "hermes.qwenModelQuality": "high", "cantrip.mascot.name": "Mochi", "hermes.paused": true,
        ]
        let before = previous.keys.map { ($0, defaults.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in before {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in previous { defaults.set(value, forKey: key) }

        func stored<T>(_ view: Any, _ name: String, as _: T.Type) -> T? {
            Mirror(reflecting: view).children.first { $0.label == name }
                .flatMap { $0.value as? AppStorage<T> }?.wrappedValue
        }
        let env = HermesEnv()
        let remote = CantripRemoteModel(urlSession: client())
        let voicePage = SettingsVoicePage(env: env, remote: remote, voice: VoiceController())
        XCTAssertEqual(stored(voicePage, "_voiceEngine", as: String.self), "qwen")
        XCTAssertEqual(stored(voicePage, "_voicePause", as: Double.self), 3.5)
        XCTAssertEqual(stored(voicePage, "_sttEngine", as: String.self), "apple")
        let appearance = SettingsAppearancePage()
        XCTAssertEqual(stored(appearance, "_showSteps", as: Bool.self), true)
        XCTAssertEqual(stored(appearance, "_mascotName", as: String.self), "Mochi")
        let qwen = QwenVoiceSettingsView()
        XCTAssertEqual(stored(qwen, "_presetId", as: String.self), "vivian-plain")
        XCTAssertEqual(stored(qwen, "_rate", as: Double.self), 1.3)
        XCTAssertEqual(stored(qwen, "_modelQuality", as: String.self), "high")
        XCTAssertEqual(stored(SettingsPauseRow(), "_paused", as: Bool.self), true,
                       "Pause Agent in Settings reads the same key the chat's paused bar does")

        // Every page draws at a narrow folded width and the largest text without scrolling sideways.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let pages: [(String, AnyView)] = [
            ("Voice", AnyView(voicePage)),
            ("Appearance", AnyView(appearance)),
            ("Macs", AnyView(SettingsMacsPage(env: env, remote: remote))),
            ("About", AnyView(SettingsAboutPage(env: env, remote: remote))),
            ("Notifications", AnyView(SettingsNotificationsPage(remote: remote))),
        ]
        for (name, page) in pages {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let controller = UIHostingController(rootView: NavigationStack { page }.environment(\.dynamicTypeSize, size))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                for scroll in descendants(controller.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 0 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "\(name) scrolls sideways at \(size)")
                }
            }
        }
    }
}
