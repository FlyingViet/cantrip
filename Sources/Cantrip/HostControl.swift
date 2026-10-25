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
        case "tab":
            return TabInsight.handle(request, manager: manager)
        case "pair":
            guard settings.remoteControlEnabled || HostMode.isHeadless else {
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
                for (key, value) in values {
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
                    guard let converted = Self.convert(value, like: existing) else {
                        return ["error": "\(key) expects \(Self.typeName(existing))."]
                    }
                    typed[key] = converted
                }
                let applied = Set(settings.applySettings(typed))
                if let rejected = typed.keys.sorted().first(where: { !applied.contains($0) }) {
                    return ["error": "\(rejected) can't be set to \(typed[rejected]!). Check the allowed values in docs/headless.md."]
                }
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
            "enabled": settings.remoteControlEnabled || HostMode.isHeadless,
            "port": settings.remoteControlPort,
            "tokenStore": RemoteTokenFile.inUse ? "file" : "keychain",
        ]
        if let error = settings.remoteControlError { remote["error"] = error }
        if let lan = settings.remoteLANStatus { remote["lanPort"] = lan.port }
        return [
            "host": HostMode.isHeadless ? "headless" : "app",
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
    static func backend(named name: String) -> BackendKind? {
        let key = name.lowercased().filter { $0.isLetter }
        let aliases: [String: BackendKind] = ["copilot": .copilot, "claude": .claudeCode, "claudecode": .claudeCode,
                                              "codex": .codex, "local": .localModel, "localmodel": .localModel,
                                              "copilotremote": .copilotRemote]
        return aliases[key] ?? BackendKind.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    /// The CLI a backend runs, for `cantrip doctor`.
    static func command(for backend: BackendKind) -> String? {
        switch backend {
        case .copilot, .copilotRemote: return "copilot"
        case .claudeCode: return "claude"
        case .codex: return "codex"
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
}
