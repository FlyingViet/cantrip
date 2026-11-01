import Foundation

/// `GET/POST /api/v1/policy`: Cantrip's agent policy for paired clients. Every client can read it;
/// the browser/Mac Remote also edits it. POST takes the `revision` it read and one change:
/// `{"enabled": Bool}`, `{"rule": {…}}` (adds or replaces a Mac-wide rule by ID),
/// `{"removeRule": "id"}`, `{"setRuleEnabled": {"id", "enabled"}}`, or
/// `{"policy": {"enabled", "rules", "projects", "privateTerms"}}` to replace the editable parts.
/// Imports and the CLIs' deny lists stay Cantrip's.
struct AgentPolicyRemoteSnapshot: Encodable, Equatable {
    let policy: AgentPolicyDocument
    /// The rule each line describes, by ID.
    let summaries: [String: String]
    let file: String
    let loadError: String?
    /// Groups a command pattern can name with `@`.
    let namedCommands: [String]
}

enum AgentPolicyRemote {
    nonisolated(unsafe) static var store: AgentPolicyStore { AgentPolicyGate.store }

    static func snapshot() -> AgentPolicyRemoteSnapshot {
        let policy = store.current()
        var summaries: [String: String] = [:]
        for rule in policy.rules + policy.projects.flatMap(\.rules) { summaries[rule.id] = rule.summary }
        return AgentPolicyRemoteSnapshot(
            policy: policy, summaries: summaries,
            file: store.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"),
            loadError: store.loadError, namedCommands: AgentPolicyRule.namedCommands.keys.sorted())
    }

    static func apply(_ json: [String: Any]) throws -> AgentPolicyRemoteSnapshot {
        guard let revision = json["revision"] as? Int else {
            throw AgentPolicyStore.SaveError(status: 400, message: "Send the revision you read.")
        }
        var document = store.current()
        func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
            do {
                let data = try JSONSerialization.data(withJSONObject: value)
                return try AgentPolicyStore.decoder.decode(type, from: data)
            } catch {
                throw AgentPolicyStore.SaveError(status: 400, message: "Cantrip couldn't read that rule: \(error.localizedDescription)")
            }
        }
        if let enabled = json["enabled"] as? Bool {
            document.enabled = enabled
        } else if let value = json["rule"] {
            var rule = try decode(AgentPolicyRule.self, value)
            rule.source = rule.source ?? "user"
            if let index = document.rules.firstIndex(where: { $0.id == rule.id }) { document.rules[index] = rule }
            else { document.rules.append(rule) }
        } else if let id = json["removeRule"] as? String {
            guard document.rules.contains(where: { $0.id == id }) else {
                throw AgentPolicyStore.SaveError(status: 404, message: "There's no rule \(id).")
            }
            document.rules.removeAll { $0.id == id }
        } else if let change = json["setRuleEnabled"] as? [String: Any], let id = change["id"] as? String,
                  let enabled = change["enabled"] as? Bool {
            guard let index = document.rules.firstIndex(where: { $0.id == id }) else {
                throw AgentPolicyStore.SaveError(status: 404, message: "There's no rule \(id).")
            }
            document.rules[index].enabled = enabled
        } else if let value = json["policy"] as? [String: Any] {
            let edited = try decode(AgentPolicyDocument.self, value)
            document.enabled = edited.enabled
            document.rules = edited.rules
            document.projects = edited.projects
            document.privateTerms = edited.privateTerms
        } else {
            throw AgentPolicyStore.SaveError(status: 400, message: "Send one change: enabled, rule, removeRule, setRuleEnabled or policy.")
        }
        try AgentPolicySetup.save(document, basedOn: store.exists ? revision : nil)
        return snapshot()
    }
}
