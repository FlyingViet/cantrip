import Foundation

/// What a backend does with one tool call.
enum AgentPolicyOutcome: Equatable {
    /// Refuse it. `reason` goes to the agent; `by` names the rule in the tab.
    case deny(reason: String, by: String)
    /// Show Cantrip's approval card. Approving lets the identical call repeat this turn (`scope`).
    case ask(title: String, detail: String, scope: String, source: String, action: String)
    /// Run it without the backend's own prompt.
    case allow(by: String)
    /// No rule decided and "Act on my behalf" is off: the backend's usual approval.
    case prompt

    /// Allowed by one of the policy's allow rules (not just by "Act on my behalf").
    var explicitlyAllowed: Bool {
        if case .allow(let by) = self { return by.hasPrefix("Cantrip policy (") }
        return false
    }
}

/// The one host-side check every backend runs before each tool call, for every tab, child tab
/// and Home run: Cantrip's agent policy first, then Cantrip Home's stricter rules for Home and
/// child tabs, then "Act on my behalf", which approves what no rule denies or asks about.
enum AgentPolicyGate {
    nonisolated(unsafe) static var store = AgentPolicyStore.shared

    /// Whether regular tabs check every tool call (the policy file can turn this off).
    static var enforcesEverywhere: Bool { store.current().enabled }

    static func decide(
        _ request: CantripHomeActionRequest, guardrail: CantripHomeGuardrail?, approval: CantripHomeApproval,
        label: String, workdir: String, policy: AgentPolicyDocument? = nil, context: AgentPolicyContext? = nil,
        homeEnvironment: CantripHomeActionPolicy.Environment? = nil
    ) -> AgentPolicyOutcome {
        let document = policy ?? store.current()
        // Home's rules are the stricter layer: its refusals come first in Home and child tabs.
        var home: CantripHomeActionDecision?
        if let guardrail {
            home = CantripHomeActionPolicy.evaluate(request, mode: guardrail, approval: approval,
                                                    environment: homeEnvironment ?? .current(workdir: workdir))
        }
        if let home, home.verdict == .deny {
            Log.write("home policy: denied \(request.kind.rawValue): \(request.command.prefix(160))")
            return .deny(reason: home.reason, by: "Cantrip Home policy")
        }
        var user = AgentPolicyDecision()
        if document.enabled {
            user = document.evaluate(request, context: context ?? .current(workdir: workdir))
        }
        if user.verdict == .deny {
            Log.write("policy: \(user.ruleID) denied \(request.kind.rawValue): \(user.matched.prefix(160))")
            return .deny(reason: user.denial, by: "Cantrip policy (\(user.ruleID))")
        }
        if user.verdict == .ask {
            return .ask(title: "\(label) wants to \(user.action)", detail: detail(user, request: request, privateTerms: document.privateTerms),
                        scope: user.scope, source: "Cantrip policy", action: user.action)
        }
        if let home, home.verdict == .ask {
            return .ask(title: "\(label) wants to \(home.action)", detail: home.detail, scope: home.scope,
                        source: "Cantrip Home", action: home.action)
        }
        if user.verdict == .allow { return .allow(by: "Cantrip policy (\(user.ruleID))") }
        guard approval.runsWithoutAsking(request) else { return .prompt }
        if home?.automatic == true {
            Log.write("home policy: approved \(home?.action ?? "") automatically (Act on my behalf)")
        }
        return .allow(by: approval == .automatic ? "Act on my behalf" : guardrail != nil ? "Cantrip Home policy" : "Read-only")
    }

    /// The approval card's text: which rule asks and why, what would run, and for a push to a
    /// public repository, what the privacy scan found in the outgoing commits.
    static func detail(_ decision: AgentPolicyDecision, request: CantripHomeActionRequest, privateTerms: [String]) -> String {
        let what: String
        switch request.kind {
        case .shell: what = request.command
        case .mcp: what = "\(request.server ?? "MCP") · \(request.tool ?? "tool")"
        default: what = (request.paths + [request.url, request.tool].compactMap { $0 }).joined(separator: "\n")
        }
        var text = "Cantrip's policy asks first (rule \(decision.ruleID)): \(decision.reason)\n\n\(what.prefix(2_000))"
        if decision.rule?.privacyScan == true, let folder = decision.directory {
            text += "\n\n" + AgentPolicyPrivacyScan.scan(folder: folder, privateTerms: privateTerms).summary
        }
        return text
    }

    /// A failed step that says why Cantrip refused a call, shown in the tab on every client.
    static func denialActivity(_ request: CantripHomeActionRequest, reason: String, by: String) -> ToolActivity {
        let what = request.kind == .shell ? request.command
            : request.kind == .mcp ? "\(request.server ?? "MCP") \(request.tool ?? "")"
            : (request.paths + [request.url, request.tool].compactMap { $0 }).joined(separator: " ")
        let shown = reason.replacingOccurrences(of: " Don't try another way to do this; tell the user it was blocked if it matters.", with: "")
        return ToolActivity(id: "policy-\(UUID().uuidString)", title: "Blocked by \(by)", toolName: "Cantrip policy",
                            state: .failed, input: String(what.prefix(2_000)), output: shown, fileChanges: [])
    }

    /// What a user's answer tells the agent when they decline.
    static func declined(_ action: String, answered: Bool) -> String {
        let what = action.isEmpty ? "this action" : action
        return answered
            ? "The user declined to \(what). Don't retry it another way; say in your reply that it was skipped."
            : "No approval arrived to \(what), so it was skipped. Say so in your reply."
    }
}

/// Before a push to a public repository: the outgoing commits' authors and added lines, checked
/// for email addresses, private network addresses, tailnet names and the user's own private terms.
enum AgentPolicyPrivacyScan {
    struct Result: Equatable {
        var commits = 0
        var findings: [String] = []
        var failure: String?

        var summary: String {
            if let failure { return "Privacy scan: couldn't run (\(failure)). Check the outgoing commits yourself before approving." }
            if commits == 0 { return "Privacy scan: no outgoing commits found." }
            if findings.isEmpty { return "Privacy scan: \(commits) outgoing commit(s), nothing private found." }
            return "Privacy scan found \(findings.count) possible private detail(s) in \(commits) outgoing commit(s):\n"
                + findings.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        }
    }

    static func scan(folder: String, privateTerms: [String]) -> Result {
        let upstream = AgentPolicyGit.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: folder)
        let range = upstream.map { "\($0)..HEAD" } ?? "HEAD"
        guard let log = AgentPolicyGit.git(["log", range, "--format=%x00%H%x01%an <%ae>", "-p", "--no-color", "--unified=0", "-n", "50"], in: folder) else {
            return Result(failure: "git log failed")
        }
        return scan(log: String(log.prefix(4_000_000)), privateTerms: privateTerms)
    }

    /// `log` is `git log --format=%x00%H%x01%an <%ae> -p` output.
    static func scan(log: String, privateTerms: [String]) -> Result {
        var result = Result()
        var seen: Set<String> = []
        func note(_ finding: String) {
            if seen.insert(finding).inserted { result.findings.append(finding) }
        }
        let patterns: [(String, String)] = [
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "email address"),
            (#"\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|\b192\.168\.\d{1,3}\.\d{1,3}\b|\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b|\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b"#, "private network address"),
            (#"\b[a-z0-9-]+\.ts\.net\b|\btail[0-9a-f]{6}\b"#, "tailnet name"),
            (#"\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b"#, "phone number"),
        ]
        let regexes = patterns.compactMap { pattern, label in (try? NSRegularExpression(pattern: pattern)).map { ($0, label) } }
        let terms = privateTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        for commit in log.components(separatedBy: "\u{0}") where !commit.isEmpty {
            result.commits += 1
            let lines = commit.components(separatedBy: "\n")
            let header = lines.first ?? ""
            let author = header.components(separatedBy: "\u{1}").dropFirst().first ?? ""
            let sha = String(header.prefix(9))
            for term in terms where author.range(of: term, options: .caseInsensitive) != nil {
                note("\(sha) author: \"\(term)\"")
            }
            for line in lines.dropFirst() where line.hasPrefix("+") && !line.hasPrefix("+++") {
                let added = String(line.dropFirst())
                let range = NSRange(added.startIndex..., in: added)
                for (regex, label) in regexes {
                    for match in regex.matches(in: added, range: range) {
                        guard let found = Range(match.range, in: added) else { continue }
                        let value = String(added[found])
                        if label == "email address", value.lowercased().hasSuffix("noreply.github.com") || value.lowercased().hasSuffix("@example.com") { continue }
                        if label == "private network address", value.hasPrefix("127.") || value == "10.0.0.0" { continue }
                        note("\(sha) \(label): \(value)")
                    }
                }
                for term in terms where added.range(of: term, options: .caseInsensitive) != nil {
                    note("\(sha) private term: \"\(term)\"")
                }
            }
        }
        return result
    }
}
