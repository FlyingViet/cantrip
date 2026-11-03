import Foundation

extension SessionTabTests {
    /// `/api/v1/settings`: one manifest of the Mac's settings for every client. Paired devices
    /// don't see this Mac's app settings and can't change paths; Cantrip's own window (local key)
    /// can. Changes are all-or-nothing, a stale revision is refused, secrets never leave the Mac,
    /// and a paired device's port or token change is undone unless it keeps it.
    @MainActor
    static func testSettingsManifest() async throws {
        let home = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"]!
        precondition(RemoteTokenFile.url.path.hasPrefix(home + "/"), "Token changes stay in the test home, never the Keychain")
        try RemoteTokenFile.store("settings-test-token")
        let settings = AppSettings.shared
        let saved = (settings.cantripHomeParallelRuns, settings.childTabsAutoFork, settings.remoteLANPort, settings.claudeEffort,
                     settings.panelOpacity, settings.claudePath, settings.localAPIKey, settings.copilotIdleReleaseMinutes,
                     settings.cantripHomeEnabled, settings.remoteControlPort)
        let savedSeconds = SettingsManifest.revertSeconds
        defer {
            (settings.cantripHomeParallelRuns, settings.childTabsAutoFork, settings.remoteLANPort, settings.claudeEffort,
             settings.panelOpacity, settings.claudePath, settings.localAPIKey, settings.copilotIdleReleaseMinutes,
             settings.cantripHomeEnabled, settings.remoteControlPort) = saved
            SettingsManifest.revertSeconds = savedSeconds
        }
        settings.cantripHomeEnabled = true
        settings.remoteLANPort = 0
        settings.claudeEffort = ""

        func fields(_ manifest: [String: Any]) -> [String: [String: Any]] {
            var found: [String: [String: Any]] = [:]
            for page in manifest["pages"] as? [[String: Any]] ?? [] {
                for section in page["sections"] as? [[String: Any]] ?? [] {
                    for field in section["fields"] as? [[String: Any]] ?? [] { found[field["key"] as! String] = field }
                }
            }
            return found
        }
        func pageIDs(_ manifest: [String: Any]) -> [String] {
            (manifest["pages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }

        // What each kind of client sees.
        let remoteView = SettingsManifest.manifest(local: false)
        let localView = SettingsManifest.manifest(local: true)
        let remoteFields = fields(remoteView), localFields = fields(localView)
        precondition(pageIDs(remoteView) == ["macs", "models", "tools", "home", "memory", "about"], "\(pageIDs(remoteView))")
        precondition(pageIDs(localView) == ["macs", "models", "tools", "home", "memory", "location", "appearance", "about"])
        precondition(remoteFields["panelOpacity"] == nil && remoteFields["showPairingCode"] == nil
                     && remoteFields["interfaceMode"] == nil && remoteFields["launchAtLogin"] == nil,
                     "Paired devices don't see this Mac's app settings")
        precondition(remoteFields["claudePath"]?["readOnly"] as? Bool == true && localFields["claudePath"]?["readOnly"] == nil,
                     "Paths are read-only away from the Mac")
        precondition(remoteFields["remoteLANPort"]?["guarded"] as? Bool == true && localFields["remoteLANPort"]?["guarded"] == nil)
        precondition(remoteFields["cantripHomeParallelRuns"]?["max"] as? Int == CantripHomeBackgroundRunner.maximumParallelLimit
                     && (remoteFields["cantripHomeParallelRuns"]?["visibleWhen"] as? [String: Any])?["key"] as? String == "cantripHomeEnabled")
        precondition((remoteFields["claudeEffort"]?["choices"] as? [[String: Any]])?.contains { $0["value"] as? String == "high" } == true)
        precondition(remoteView["revision"] as? String == SettingsManifest.revision() && remoteView["version"] as? Int == 1)
        let data = try JSONSerialization.data(withJSONObject: localView)
        precondition(JSONSerialization.isValidJSONObject(remoteView) && data.count < 200_000)

        // Over the server, as a paired device and as Cantrip's own window.
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let port = Int.random(in: 20_000...45_000)
        server.start(port: port, token: "settings-test-token")
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let token = "settings-test-token"
        func call(_ method: String = "GET", _ body: [String: Any]? = nil, local: Bool = false, key: String? = nil,
                  path: String = "/api/v1/settings") async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let key = local ? LocalClientKey.value : key { request.setValue(key, forHTTPHeaderField: "X-Cantrip-Local-Key") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }

        let loaded = try await call()
        precondition(loaded.0 == 200 && loaded.1["local"] as? Bool == false && fields(loaded.1)["panelOpacity"] == nil)
        let forged = try await call(key: String(repeating: "0", count: LocalClientKey.value.count))
        precondition(forged.1["local"] as? Bool == false && fields(forged.1)["panelOpacity"] == nil, "Only the real key is local")
        var revision = loaded.1["revision"] as? String ?? ""
        let listing = try await call(path: "/api/v1/sessions")
        precondition(listing.1["settingsRevision"] as? String == revision && listing.1["supportsSettings"] as? Bool == true,
                     "The tab list carries the revision so open Settings screens refresh")

        let saved1 = try await call("POST", ["revision": revision, "changes": ["cantripHomeParallelRuns": 2, "childTabsAutoFork": false,
                                                                              "copilotIdleReleaseMinutes": 60]])
        precondition(saved1.0 == 200 && settings.cantripHomeParallelRuns == 2 && !settings.childTabsAutoFork
                     && settings.copilotIdleReleaseMinutes == 60, "\(saved1)")
        precondition(saved1.1["revision"] as? String != revision && fields(saved1.1)["cantripHomeParallelRuns"]?["value"] as? Int == 2)
        let stale = try await call("POST", ["revision": revision, "changes": ["cantripHomeParallelRuns": 3]])
        precondition(stale.0 == 409 && settings.cantripHomeParallelRuns == 2 && stale.1["settings"] != nil,
                     "A stale revision is refused with the current settings")
        revision = saved1.1["revision"] as! String

        // All or nothing, with each bad key named.
        let bad = try await call("POST", ["revision": revision, "changes": ["cantripHomeParallelRuns": 99, "claudeEffort": "bogus",
                                                                           "childTabsAutoFork": true, "nope": 1]])
        let problems = bad.1["fields"] as? [String: String] ?? [:]
        precondition(bad.0 == 422 && Set(problems.keys) == ["cantripHomeParallelRuns", "claudeEffort", "nope"]
                     && !settings.childTabsAutoFork && settings.claudeEffort == "", "\(bad)")
        let wrongType = try await call("POST", ["revision": revision, "changes": ["childTabsAutoFork": "yes"]])
        precondition(wrongType.0 == 422)
        let pathAway = try await call("POST", ["revision": revision, "changes": ["claudePath": "/tmp/claude"]])
        let appAway = try await call("POST", ["revision": revision, "changes": ["panelOpacity": 0.7]])
        precondition(pathAway.0 == 422 && settings.claudePath != "/tmp/claude", "Paths change only at the Mac")
        precondition(appAway.0 == 422 && settings.panelOpacity != 0.7, "Paired devices can't reach this Mac's app settings")

        // Cantrip's own window.
        let localLoad = try await call(local: true)
        precondition(localLoad.1["local"] as? Bool == true && fields(localLoad.1)["panelOpacity"] != nil)
        let localSave = try await call("POST", ["revision": revision, "changes": ["panelOpacity": 0.7, "claudePath": "/tmp/claude"]],
                                       local: true)
        precondition(localSave.0 == 200 && settings.panelOpacity == 0.7 && settings.claudePath == "/tmp/claude", "\(localSave)")
        revision = localSave.1["revision"] as! String

        // Secrets: write-only.
        precondition(fields(localSave.1)["localAPIKey"]?["isSet"] as? Bool == false)
        let secret = try await call("POST", ["revision": revision, "changes": ["localAPIKey": "sk-test-value"]])
        precondition(secret.0 == 200 && settings.localAPIKey == "sk-test-value"
                     && fields(secret.1)["localAPIKey"]?["isSet"] as? Bool == true && fields(secret.1)["localAPIKey"]?["value"] == nil)
        let reread = try await call()
        let rereadText = String(decoding: try JSONSerialization.data(withJSONObject: reread.1), as: UTF8.self)
        precondition(!rereadText.contains("sk-test-value"), "A secret's value never leaves the Mac")
        revision = reread.1["revision"] as! String

        // A paired device's port change is undone unless kept.
        SettingsManifest.revertSeconds = 1
        let samePort = try await call("POST", ["revision": revision, "changes": ["remoteLANPort": settings.remoteControlPort]])
        precondition(samePort.0 == 422 && (samePort.1["fields"] as? [String: String])?["remoteLANPort"] != nil)
        let held = try await call("POST", ["revision": revision, "changes": ["remoteLANPort": 47_111]])
        let pending = held.1["pending"] as? [String: Any]
        precondition(held.0 == 200 && settings.remoteLANPort == 47_111 && pending?["keys"] as? [String] == ["remoteLANPort"], "\(held)")
        let second = try await call("POST", ["revision": held.1["revision"] as! String, "changes": ["remoteLANPort": 47_112]])
        precondition(second.0 == 409, "One connection change at a time")
        try await Task.sleep(for: .milliseconds(1_600))
        precondition(settings.remoteLANPort == 0 && SettingsManifest.pending == nil, "Not kept: undone")
        let again = try await call("POST", ["revision": SettingsManifest.revision(), "changes": ["remoteLANPort": 47_113]])
        let id = (again.1["pending"] as? [String: Any])?["id"] as? String ?? ""
        let kept = try await call("POST", ["keep": id])
        try await Task.sleep(for: .milliseconds(1_300))
        precondition(kept.0 == 200 && kept.1["pending"] == nil && settings.remoteLANPort == 47_113, "Kept: stays")
        let late = try await call("POST", ["keep": id])
        precondition(late.0 == 409)
        let local = try await call("POST", ["revision": SettingsManifest.revision(), "changes": ["remoteLANPort": 0]], local: true)
        precondition(local.0 == 200 && local.1["pending"] == nil && settings.remoteLANPort == 0, "The Mac's own window isn't held")

        // Replacing the pairing token from a paired device: it gets the new one; others don't.
        let rotated = try await call("POST", ["action": "rotatePairingToken"])
        let newToken = (rotated.1["result"] as? [String: Any])?["pairingToken"] as? String ?? ""
        precondition(rotated.0 == 200 && newToken.count == 43 && rotated.1["pending"] != nil, "\(rotated)")
        try await Task.sleep(for: .milliseconds(700))
        let applied = try RemoteTokenFile.load()
        precondition(applied == newToken)
        try await Task.sleep(for: .milliseconds(1_000))
        let restored = try RemoteTokenFile.load()
        precondition(restored == "settings-test-token", "Not kept: the old token is back")
        let rotatedLocally = try await call("POST", ["action": "rotatePairingToken"], local: true)
        let replaced = try RemoteTokenFile.load()
        precondition(rotatedLocally.0 == 200 && (rotatedLocally.1["result"] as? [String: Any])?["pairingToken"] == nil
                     && rotatedLocally.1["pending"] == nil && replaced != "settings-test-token",
                     "The Mac's own window replaces it outright and never gets the token")
        let missing = try await call("POST", ["action": "nope"])
        let appOnly = try await call("POST", ["action": "showPairingCode"])
        precondition(missing.0 == 422 && appOnly.0 == 422, "Paired devices can't show the pairing code")

        // `cantrip config` knows the same keys.
        for key in ["copilotMCPApps", "agyAuxiliaryRouting", "agyMemoryConsolidation", "interfaceMode"] {
            precondition(settings.dotfileValues[key] != nil, key)
        }
        let configKeys = Set(settings.dotfileValues.keys)
        let manifestKeys = Set(fields(SettingsManifest.manifest(local: true)).filter {
            !["action", "info", "secret"].contains($0.value["type"] as? String) }.keys)
        let notInConfig = manifestKeys.subtracting(configKeys).subtracting(["remoteDesktopEnabled", "launchAtLogin", "backgroundEngine"])
        precondition(notInConfig.isEmpty, "Every manifest setting is a `cantrip config` name: \(notInConfig.sorted())")
        try testSettingsManifestWeb()
        try testBackgroundEngineSetting(fields: fields, pageIDs: pageIDs)
    }

    /// "Keep agents running when Cantrip quits" is the Mac's own (About › Startup); the engine's
    /// Settings drop the panel's, since its app has no panel yet.
    @MainActor
    private static func testBackgroundEngineSetting(fields: ([String: Any]) -> [String: [String: Any]],
                                                    pageIDs: ([String: Any]) -> [String]) throws {
        let saved = (BackgroundEngine.isEnabled, BackgroundEngine.lastError)
        defer {
            BackgroundEngine.isEnabled = saved.0
            BackgroundEngine.lastError = saved.1
            HostMode.isHeadless = false
            HostMode.isEngine = false
        }
        BackgroundEngine.isEnabled = false
        BackgroundEngine.lastError = nil
        precondition(BackgroundEngine.unavailableReason(homeWindow: nil, agentBundled: true, daemonInstalled: false) == nil)
        precondition(BackgroundEngine.unavailableReason(homeWindow: "The Home window needs macOS 26.", agentBundled: true,
                                                        daemonInstalled: false)?.contains("macOS 26") == true)
        precondition(BackgroundEngine.unavailableReason(homeWindow: nil, agentBundled: false, daemonInstalled: false)?
            .contains("doesn't include the background agent") == true)
        precondition(BackgroundEngine.unavailableReason(homeWindow: nil, agentBundled: true, daemonInstalled: true)?
            .contains("cantrip daemon stop") == true)

        // The test binary has no Home window or login agent: the reason shows instead of the toggle.
        let local = fields(SettingsManifest.manifest(local: true))
        precondition(local["backgroundEngine"] == nil && local["backgroundEngineStatus"]?["type"] as? String == "info",
                     "\(local["backgroundEngineStatus"] ?? [:])")
        precondition(fields(SettingsManifest.manifest(local: false))["backgroundEngineStatus"] == nil, "Paired devices don't see it")

        // Served by the engine: the toggle (turning it off waits for work), and no panel settings.
        HostMode.isHeadless = true
        HostMode.isEngine = true
        BackgroundEngine.isEnabled = true
        var engine = SettingsManifest.manifest(local: true)
        var engineFields = fields(engine)
        precondition(engineFields["backgroundEngine"]?["value"] as? Bool == true && engineFields["backgroundEngineStatus"] == nil)
        precondition(engineFields["interfaceMode"] == nil && engineFields["panelOpacity"] == nil && engineFields["attachScreen"] == nil
                     && engineFields["voiceMode"] == nil && engineFields["shareLocation"] != nil && !pageIDs(engine).contains("appearance"),
                     "\(pageIDs(engine))")
        precondition(fields(SettingsManifest.manifest(local: false))["backgroundEngine"] == nil, "Paired devices don't see it")
        let before = SettingsManifest.revision()
        try SettingsManifest.apply(["backgroundEngine": false], local: true)
        precondition(!BackgroundEngine.isEnabled && SettingsManifest.revision() != before, "Saved, and the revision moves")
        engine = SettingsManifest.manifest(local: true)
        engineFields = fields(engine)
        precondition((engineFields["backgroundEngineStatus"]?["value"] as? String)?.hasPrefix("Turning off") == true,
                     "\(engineFields["backgroundEngineStatus"] ?? [:])")
        BackgroundEngine.lastError = "macOS is holding Cantrip's background agent for approval."
        precondition(fields(SettingsManifest.manifest(local: true))["backgroundEngineStatus"]?["tone"] as? String == "error")
        var refused = false
        do { try SettingsManifest.apply(["backgroundEngine": true], local: false) } catch { refused = true }
        precondition(refused && !BackgroundEngine.isEnabled, "A paired device can't turn it on")
    }
}
