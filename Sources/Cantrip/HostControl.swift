import Foundation

/// Answers `cantrip status|pair|config|tab` over the CLI socket. The socket only accepts this user
/// (0600), and the pairing token is only ever sent to it.
@MainActor
final class HostControl {
    private let manager: SessionManager

    init(manager: SessionManager) {
        self.manager = manager
    }

    func handle(_ request: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        switch request["command"] as? String {
        case "status":
            return status()
        case "app-connection":
            // Cantrip.app as the background engine's client (`BackgroundEngine.connection`).
            guard HostMode.isEngine else { return ["error": "Cantrip isn't running its agents in the background."] }
            guard let token = settings.ensureRemoteControlToken() else {
                return ["error": settings.remoteControlError ?? "The pairing token is unavailable."]
            }
            // Notifications for the app to post after the last it saw (`MacNotices`); a cursor from
            // another engine (this one restarted) doesn't count.
            let cursor = request["outbox"] as? String == MacNotices.outboxID ? request["after"] as? Int : nil
            let notices = MacNotices.outboxJSON(after: cursor)
            return ["port": settings.remoteControlPort, "token": token, "localKey": LocalClientKey.value,
                    "pid": Int(getpid()), "build": CrashRecovery.buildIdentity,
                    "enabled": BackgroundEngine.isEnabled, "busy": HostServices.running?.busyWork ?? 0,
                    "outbox": MacNotices.outboxID, "seq": notices.seq, "notices": notices.entries]
        case "tab":
            return TabInsight.handle(request, manager: manager)
        case "handoffs":
            return HandoffReport.snapshot(manager: manager, days: request["days"] as? Int ?? HandoffReport.defaultDays)
        case "mcp":
            return mcp(request)
        case "api":
            return api(request)
        case "pair":
            guard settings.remoteControlEnabled || (HostMode.isHeadless && !HostMode.isEngine) else {
                return ["error": "Remote control is off. Turn it on with `cantrip config set remoteControlEnabled true`."]
            }
            if request["rotate"] as? Bool == true {
                guard settings.regenerateRemoteControlToken() else {
                    return ["error": settings.remoteControlError ?? "Could not replace the pairing token."]
                }
                Log.write("cli: pairing token replaced from the terminal")
            }
            guard let token = settings.ensureRemoteControlToken() else {
                return ["error": settings.remoteControlError ?? "The pairing token is unavailable."]
            }
            return pairing(token: token)
        case "config":
            if let values = request["set"] as? [String: Any] {
                guard !values.isEmpty else { return ["error": "Nothing to set."] }
                let current = settings.dotfileValues
                var typed: [String: Any] = [:]
                var fallbackEntries: [FallbackEntry]?
                for (rawKey, value) in values {
                    // The single-backend name from before the chain still works.
                    let key = rawKey == "limitFallbackBackend" || rawKey == "limitFallbackEntries" ? "limitFallbackBackends" : rawKey
                    guard let existing = current[key] else {
                        return ["error": "Unknown setting \(key). Run `cantrip config` to list them."]
                    }
                    if key == "backend" {
                        guard let kind = (value as? String).flatMap(Self.backend(named:)) else {
                            return ["error": "backend must be one of: copilot, claude, codex, local, copilot-remote."]
                        }
                        typed[key] = kind.rawValue
                        continue
                    }
                    if key == "limitFallbackBackends" {
                        // "codex, copilot" or ["codex", "copilot"]: tried in that order; off clears it.
                        // "agy:gemini-4-argon-high:high" sets that backup's model and effort (either
                        // may be empty), and a backend can be listed again with another model. A bare
                        // name keeps that backend's next saved entry, or its remembered model.
                        let names = (value as? [String]) ?? ((value as? String) ?? "").split(separator: ",").map(String.init)
                        let trimmed = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if trimmed.isEmpty || (trimmed.count == 1 && ["off", "none"].contains(trimmed[0].lowercased())) {
                            fallbackEntries = []
                            continue
                        }
                        let parts = trimmed.map { $0.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init) }
                        let kinds = parts.map { Self.backend(named: $0[0]) }
                        guard !kinds.contains(where: { $0 == nil }) else {
                            return ["error": "limitFallbackBackends must be off or a comma-separated list of: copilot, claude, codex, antigravity, local, copilot-remote (each optionally :model:effort)."]
                        }
                        var saved = Dictionary(grouping: settings.limitFallbackEntries, by: \.backend)
                        fallbackEntries = zip(parts, kinds).map { part, kind in
                            let backend = kind!.rawValue
                            if part.count > 1 {
                                return FallbackEntry(backend: backend, model: part[1], effort: part.count > 2 ? part[2] : "")
                            }
                            if let next = saved[backend]?.first {
                                saved[backend]?.removeFirst()
                                return next
                            }
                            let chosen = settings.limitFallbackModels[backend]
                            return FallbackEntry(backend: backend, model: chosen?.model ?? "", effort: chosen?.effort ?? "")
                        }
                        continue
                    }
                    guard let converted = Self.convert(value, like: existing) else {
                        return ["error": "\(key) expects \(Self.typeName(existing))."]
                    }
                    typed[key] = converted
                }
                if let fallbackEntries {
                    // Checked against each backend's real models before anything is saved.
                    do {
                        let raw = fallbackEntries.map { ["backend": $0.backend, "model": $0.model, "effort": $0.effort] as [String: Any] }
                        settings.limitFallbackEntries = try UsageFallbackRemote.validatedEntries(raw, settings: settings)
                    } catch {
                        return ["error": "limitFallbackBackends: \(error.localizedDescription)"]
                    }
                }
                var applied = Set(settings.applySettings(typed))
                if let rejected = typed.keys.sorted().first(where: { !applied.contains($0) }) {
                    return ["error": "\(rejected) can't be set to \(typed[rejected]!). Check the allowed values in docs/headless.md."]
                }
                if fallbackEntries != nil { applied.insert("limitFallbackEntries") }
                Log.write("cli: settings changed from the terminal: \(applied.sorted().joined(separator: ", "))")
            }
            return ["settings": settings.dotfileValues]
        default:
            return ["error": "Unknown command. Run `cantrip help`."]
        }
    }

    private func status() -> [String: Any] {
        let settings = AppSettings.shared
        // The tabs remote clients list (Cantrip Home's own sessions aren't tabs).
        let sessions = manager.sessions.filter { !$0.isPrivate }
        var remote: [String: Any] = [
            "enabled": settings.remoteControlEnabled || (HostMode.isHeadless && !HostMode.isEngine),
            "port": settings.remoteControlPort,
            "tokenStore": RemoteTokenFile.inUse ? "file" : "keychain",
        ]
        if let error = settings.remoteControlError { remote["error"] = error }
        if let lan = settings.remoteLANStatus { remote["lanPort"] = lan.port }
        var endpoint: [String: Any] = ["enabled": settings.openAIEndpointEnabled, "port": settings.openAIEndpointPort]
        if let port = settings.openAIEndpointListeningPort { endpoint["listening"] = port }
        if let error = settings.openAIEndpointError { endpoint["error"] = error }
        return [
            "openAIEndpoint": endpoint,
            "host": HostMode.isEngine ? "engine" : HostMode.isHeadless ? "headless" : "app",
            "pid": Int(getpid()),
            "build": CrashRecovery.buildIdentity,
            "backend": settings.backend.rawValue,
            "backendCommand": Self.command(for: settings.backend) ?? "",
            "tabs": sessions.count,
            "busyTabs": sessions.filter(\.isStreaming).count,
            "cantripHome": settings.cantripHomeEnabled,
            "remote": remote,
        ]
    }

    /// `cantrip api`: the OpenAI-compatible endpoint's state and calls per consumer, or a new key.
    private func api(_ request: [String: Any]) -> [String: Any] {
        let settings = AppSettings.shared
        switch request["action"] as? String {
        case "key-new":
            guard let key = settings.generateOpenAIEndpointKey() else { return ["error": "The Keychain didn't save the key."] }
            Log.write("cli: OpenAI endpoint key replaced from the terminal")
            return ["key": key]
        case "key-clear":
            settings.clearOpenAIEndpointKey()
            return ["cleared": true]
        default:
            let encoder = JSONEncoder()
            let consumers = EndpointUsageLedger.shared.consumers().compactMap { consumer -> Any? in
                (try? encoder.encode(consumer)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            var reply: [String: Any] = [
                "enabled": settings.openAIEndpointEnabled, "port": settings.openAIEndpointPort,
                "model": settings.openAIEndpointModel, "effort": settings.openAIEndpointEffort,
                "contextTier": settings.openAIEndpointContextTier, "keySet": settings.openAIEndpointKey != nil,
                "chain": settings.openAIEndpointChain().map(\.label), "consumers": consumers,
                "status": settings.openAIEndpointStatusText,
            ]
            if let port = settings.openAIEndpointListeningPort { reply["listening"] = port }
            if let error = settings.openAIEndpointError { reply["error"] = error }
            return reply
        }
    }

    private func pairing(token: String) -> [String: Any] {
        let settings = AppSettings.shared
        var result: [String: Any] = [
            "name": Self.hostName,
            "token": token,
            "fingerprint": RemoteLANProtocol.tokenFingerprint(token),
            "port": settings.remoteControlPort,
            "addresses": RemoteLANAddresses.ipv4(),
            "tokenStore": RemoteTokenFile.inUse ? "file" : "keychain",
        ]
        if let lan = settings.remoteLANStatus { result["lanPort"] = lan.port }
        if let error = settings.remoteControlError { result["error"] = error }
        return result
    }

    /// A backend by its display name or a short terminal name (copilot, claude, codex, local).
    nonisolated static func backend(named name: String) -> BackendKind? {
        let key = name.lowercased().filter { $0.isLetter }
        let aliases: [String: BackendKind] = ["copilot": .copilot, "claude": .claudeCode, "claudecode": .claudeCode,
                                              "codex": .codex, "agy": .antigravity, "antigravity": .antigravity,
                                              "local": .localModel, "localmodel": .localModel,
                                              "copilotremote": .copilotRemote]
        return aliases[key] ?? BackendKind.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    /// The CLI a backend runs, for `cantrip doctor`.
    static func command(for backend: BackendKind) -> String? {
        switch backend {
        case .copilot, .copilotRemote: return "copilot"
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        case .localModel: return nil
        }
    }

    static var hostName: String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    /// A value typed like the setting it replaces: "true"/"false", whole numbers and text.
    static func convert(_ value: Any, like existing: Any) -> Any? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespaces)
        let number = (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0 }
        switch existing {
        case is Bool:
            if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { return flag.boolValue }
            switch text?.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        case is Int:
            if let number, number.doubleValue == Double(number.intValue) { return number.intValue }
            return text.flatMap { Int($0) }
        case is Double:
            guard let double = number?.doubleValue ?? text.flatMap({ Double($0) }), double.isFinite else { return nil }
            return double
        case is String:
            return value as? String
        default:
            return nil
        }
    }

    private static func typeName(_ value: Any) -> String {
        switch value {
        case is Bool: return "true or false"
        case is String: return "text"
        default: return "a number"
        }
    }

    // MARK: - mcp

    private func mcp(_ request: [String: Any]) -> [String: Any] {
        let hub = MCPServerHub.shared
        let name = request["name"] as? String ?? ""
        func known() -> String? { hub.server(name) == nil ? "Cantrip has no MCP server called \(name). `cantrip mcp` lists them." : nil }
        switch request["action"] as? String {
        case "list", nil:
            return ["text": Self.describe(hub)]
        case "migrate":
            return Self.migrate(dryRun: request["dryRun"] as? Bool ?? true, hub: hub)
        case "restore":
            do {
                let restored = try MCPMigration.restore()
                hub.reload()
                return ["text": restored.isEmpty ? "No backup to restore." : "Restored " + restored.joined(separator: " and ") + "."]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "connect":
            if let problem = known() { return ["error": problem] }
            guard hub.server(name)?.oauth == true else { return ["error": "\(name) doesn't sign in with OAuth."] }
            hub.connect(name)
            return ["text": "Signing in to \(name). Approve the page in Cantrip (Settings > MCP Servers, or Cantrip Agent) when it asks; `cantrip mcp` shows progress."]
        case "approve", "decline":
            if let problem = known() { return ["error": problem] }
            guard hub.states[name]?.phase == .awaitingApproval else { return ["error": "\(name) isn't waiting for approval."] }
            hub.respond(name, approve: request["action"] as? String == "approve")
            return ["text": request["action"] as? String == "approve" ? "Approved. Finishing the sign-in…" : "Declined."]
        case "signout":
            if let problem = known() { return ["error": problem] }
            Task { await hub.signOut(name) }
            return ["text": "Signed out of \(name)."]
        case "enable", "disable":
            if let problem = known() { return ["error": problem] }
            let on = request["action"] as? String == "enable"
            if let tab = (request["tab"] as? String).flatMap(UUID.init(uuidString:)) {
                hub.setTab(tab, server: name, enabled: on)
                return ["text": "\(name) is \(on ? "on" : "off") for that tab."]
            }
            let backend = (request["backend"] as? String).flatMap(Self.backend(named:))
            do {
                try hub.update { snapshot in
                    guard let index = snapshot.servers.firstIndex(where: { $0.name == name }) else { return }
                    if let backend {
                        var off = Set(snapshot.servers[index].disabledBackends)
                        if on { off.remove(backend.rawValue) } else { off.insert(backend.rawValue) }
                        snapshot.servers[index].disabledBackends = off.sorted()
                    } else {
                        snapshot.servers[index].enabled = on
                    }
                }
            } catch {
                return ["error": error.localizedDescription]
            }
            return ["text": "\(name) is \(on ? "on" : "off")\(backend.map { " for \($0.rawValue)" } ?? "")."]
        default:
            return ["error": "Unknown mcp action."]
        }
    }

    /// `cantrip mcp migrate [--apply]`. The list is reloaded whenever something was written, a run
    /// that stopped partway included, so `cantrip mcp` shows what's now shared.
    static func migrate(dryRun: Bool, hub: MCPServerHub,
                        run: (Bool) throws -> MCPMigration.Report = { try MCPMigration.run(dryRun: $0) }) -> [String: Any] {
        let report: MCPMigration.Report
        do {
            report = try run(dryRun)
        } catch let incomplete as MCPMigration.Incomplete {
            hub.reload()
            Task { await hub.refreshStates() }
            return ["error": incomplete.localizedDescription]
        } catch {
            return ["error": "Nothing changed: \(error.localizedDescription)"]
        }
        hub.reload()
        Task { await hub.refreshStates() }
        var lines = [dryRun ? "Would share \(report.servers.count) servers with every backend:" : "Shared \(report.servers.count) servers with every backend:"]
        lines.append("  " + report.servers.joined(separator: ", "))
        lines.append("Through Cantrip's relay (sign-in, credential or tool limit): " + report.relayed.joined(separator: ", "))
        lines.append("\(report.secretsMoved) credential(s) \(dryRun ? "would move" : "moved") to the keychain.")
        lines += report.notes
        if !report.written.isEmpty { lines.append("Updated: " + report.written.joined(separator: "; ")) }
        if dryRun { lines.append("Run `cantrip mcp migrate --apply` to do it (originals stay restorable with `cantrip mcp restore`).") }
        return ["text": lines.joined(separator: "\n")]
    }

    static func describe(_ hub: MCPServerHub) -> String {
        guard !hub.snapshot.servers.isEmpty else {
            return "Cantrip isn't managing MCP servers yet. `cantrip mcp migrate` shows what sharing them would do."
        }
        var lines: [String] = []
        if hub.snapshot.importedAt == nil { lines.append("(Not shared yet: `cantrip mcp migrate --apply`.)") }
        for server in hub.snapshot.servers {
            let state = hub.states[server.name]
            var status = server.enabled ? (state?.phase.rawValue ?? (server.oauth ? "needsSignIn" : "ready")) : "off"
            if let expires = state?.expiresAt, state?.phase == .ready { status += ", token until \(expires.formatted(date: .omitted, time: .shortened))" }
            let kind = server.isRemote ? "remote" : "local"
            let relay = server.isRelayed ? ", via relay" : ""
            let off = server.disabledBackends.isEmpty ? "" : ", off for \(server.disabledBackends.joined(separator: ", "))"
            lines.append("\(server.name): \(kind)\(relay), \(status)\(off)")
            if let message = state?.message, state?.phase != .ready { lines.append("    \(message)") }
        }
        return lines.joined(separator: "\n")
    }
}
