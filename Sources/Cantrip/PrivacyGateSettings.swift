import Foundation

// MARK: - Settings (the policy file's `privacyGate` section)

/// Where a Home request should run.
enum PrivacyRoute: String, Codable, CaseIterable {
    /// On the user's own model server (Private Local for chat, the Local Model backend for tasks).
    case local
    /// On the cloud backend chosen in Settings, as today.
    case cloud
    /// Hide personal details and ask first. Until hiding exists, enforce mode asks before cloud.
    case redactApprove

    var label: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .redactApprove: return "Ask first"
        }
    }
}

enum PrivacyGateMode: String, Codable, CaseIterable {
    /// Decide and record every request, and change nothing.
    case observe
    /// Route by the decision: local, cloud without private tools, or ask first.
    case enforce
}

/// A fixed route for Home chat or one task, set by the user; `auto` lets the gate decide.
enum PrivacyRouteOverride: String, Codable, CaseIterable {
    case auto
    case local
    /// Cloud, without the private MCP servers and folders (`cloudRuns`).
    case cloud
    /// Cloud with every tool, as before the gate: for runs that need the user's own data sources.
    case cloudWithPrivateTools

    var label: String {
        switch self {
        case .auto: return "Decide each time"
        case .local: return "Always local"
        case .cloud: return "Always cloud, without private tools"
        case .cloudWithPrivateTools: return "Always cloud, with private tools"
        }
    }

    var route: PrivacyRoute? {
        switch self {
        case .auto: return nil
        case .local: return .local
        case .cloud, .cloudWithPrivateTools: return .cloud
        }
    }
}

/// The parts of a request the detectors look at. The always-loaded core memory is left out: it's
/// sent with every message on every backend, so it would flag everything.
enum PrivacySegment: String, Codable, CaseIterable {
    /// What the user typed, or a scheduled task's saved prompt.
    case request
    /// Earlier turns sent along with this one.
    case earlier
    /// Memory snippets retrieved for this message.
    case memory
    /// Everything else Cantrip adds: Home's tabs and tasks data, location, calendar, attachments.
    case context
}

enum PrivacyDetector: String, Codable, CaseIterable {
    case secret, ssn, card, account, email, phone, address, name

    var label: String {
        switch self {
        case .secret: return "a secret"
        case .ssn: return "a Social Security number"
        case .card: return "a card number"
        case .account: return "an account number"
        case .email: return "an email address"
        case .phone: return "a phone number"
        case .address: return "a street address"
        case .name: return "a person's name"
        }
    }
}

/// One fixed rule. It applies when any of its targets matches in its segments; the first enabled
/// rule that applies decides.
struct PrivacyGateRule: Codable, Equatable, Identifiable {
    var id: String
    var route: PrivacyRoute
    var enabled = true
    var detectors: [PrivacyDetector]?
    /// Private data sources a request names: MCP servers (`personal`, `homelab`, `bitwarden`,
    /// `forms`) and `mail` or `messages` attachments.
    var sources: [String]?
    /// The policy's `privateTerms` (words that stay on this Mac).
    var privateTerms: Bool?
    /// Work in a git repository's folder (code), which favours the cloud.
    var repoWorkdir: Bool?
    /// Where detectors and terms look; nil = request, earlier turns and memory snippets.
    var scope: [PrivacySegment]?
    /// A match doesn't decide: the classifier does (signs that are often harmless, such as a
    /// person's name). `route` applies only when no classifier is set up.
    var askClassifier: Bool?

    init(id: String, route: PrivacyRoute, detectors: [PrivacyDetector]? = nil, sources: [String]? = nil,
         privateTerms: Bool? = nil, repoWorkdir: Bool? = nil, scope: [PrivacySegment]? = nil, askClassifier: Bool? = nil) {
        self.id = id
        self.route = route
        self.detectors = detectors
        self.sources = sources
        self.privateTerms = privateTerms
        self.repoWorkdir = repoWorkdir
        self.scope = scope
        self.askClassifier = askClassifier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        route = try c.decode(PrivacyRoute.self, forKey: .route)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        detectors = try c.decodeIfPresent([PrivacyDetector].self, forKey: .detectors)
        sources = try c.decodeIfPresent([String].self, forKey: .sources)
        privateTerms = try c.decodeIfPresent(Bool.self, forKey: .privateTerms)
        repoWorkdir = try c.decodeIfPresent(Bool.self, forKey: .repoWorkdir)
        scope = try c.decodeIfPresent([PrivacySegment].self, forKey: .scope)
        askClassifier = try c.decodeIfPresent(Bool.self, forKey: .askClassifier)
    }

    var segments: Set<PrivacySegment> { Set(scope ?? [.request, .earlier, .memory]) }

    static let defaults: [PrivacyGateRule] = [
        PrivacyGateRule(id: "secrets", route: .local, detectors: [.secret], scope: PrivacySegment.allCases),
        PrivacyGateRule(id: "private-sources", route: .local,
                        sources: ["personal", "homelab", "bitwarden", "forms", "mail", "messages"], scope: [.request]),
        // Numbers that identify a person or an account decide on their own.
        PrivacyGateRule(id: "personal-details", route: .redactApprove, detectors: [.ssn, .card, .account]),
        // Names, private terms and contact details are usually harmless (Home's own data is full of
        // them), so they count only in what the user asked, and the classifier decides.
        PrivacyGateRule(id: "personal-hints", route: .redactApprove, detectors: [.email, .phone, .address, .name],
                        privateTerms: true, scope: [.request], askClassifier: true),
        PrivacyGateRule(id: "code", route: .cloud, repoWorkdir: true),
    ]

    /// The one personal-details rule before November 2026: names, private terms and contact details
    /// anywhere decided "ask first", including in Home's own data, so nearly every request matched.
    static let previousPersonalDetails = PrivacyGateRule(
        id: "personal-details", route: .redactApprove, detectors: [.ssn, .card, .account, .email, .phone, .address, .name],
        privateTerms: true)

    /// Saved rules with that old rule replaced by the current personal-details and personal-hints
    /// (keeping whether it was on). Changed or renamed rules are left as they are.
    static func migrated(_ rules: [PrivacyGateRule]) -> [PrivacyGateRule] {
        guard !rules.contains(where: { $0.id == "personal-hints" }),
              let index = rules.firstIndex(where: { var rule = $0; rule.enabled = true; return rule == previousPersonalDetails })
        else { return rules }
        let replacements = defaults.filter { $0.id == "personal-details" || $0.id == "personal-hints" }.map { rule -> PrivacyGateRule in
            var rule = rule
            rule.enabled = rules[index].enabled
            return rule
        }
        var result = rules
        result.replaceSubrange(index...index, with: replacements)
        return result
    }
}

struct PrivacyClassifierSettings: Codable, Equatable {
    var enabled = true
    /// An OpenAI-compatible server's base URL ending in /v1, with `POST /decisions` (oMLX). Empty:
    /// the Private Local server, when it uses the OpenAI-compatible API.
    var baseURL = ""
    /// Empty: Private Local's model.
    var model = ""
    var timeoutMs = 2500
    /// Scheduled tasks wait longer: nobody is waiting on them, and their long saved prompts take a
    /// few seconds to read when the server hasn't seen them.
    var taskTimeoutMs = 10_000
    /// The question is asked this many times with the options in a different order, and averaged.
    var rotations = 3
    /// Cloud only when the averaged probability of "cloud" is at least this. Below it the gate never
    /// guesses toward the cloud: local, or ask first. 0.75 (Nov 14): plain Home chats scored 75-79%
    /// when the conversation before them read personal; personal requests stay at or below 22%.
    var cloudMinProbability = 0.75
    var cacheMinutes = 60
    /// Scheduled tasks: the request and the latest earlier turn are cut to this many characters.
    var maxInputCharacters = 3000
    /// Home chat: the request, the user's earlier messages and the start of the latest reply are
    /// cut to this many. The server reads every new character before it answers (about 1.2 s plus
    /// 0.4 ms a character on an idle Studio), so this keeps chat within `timeoutMs` with room for
    /// a busier server: real chats at 1,100-1,200 characters took 2.4-2.5 s.
    var chatInputCharacters = 900

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? d.timeoutMs
        taskTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .taskTimeoutMs) ?? d.taskTimeoutMs
        rotations = try c.decodeIfPresent(Int.self, forKey: .rotations) ?? d.rotations
        cloudMinProbability = try c.decodeIfPresent(Double.self, forKey: .cloudMinProbability) ?? d.cloudMinProbability
        cacheMinutes = try c.decodeIfPresent(Int.self, forKey: .cacheMinutes) ?? d.cacheMinutes
        maxInputCharacters = try c.decodeIfPresent(Int.self, forKey: .maxInputCharacters) ?? d.maxInputCharacters
        chatInputCharacters = try c.decodeIfPresent(Int.self, forKey: .chatInputCharacters) ?? d.chatInputCharacters
    }
}

/// What cloud runs lose in enforce mode (unless their route is `cloudWithPrivateTools`).
struct PrivacyCloudRuns: Codable, Equatable {
    var excludeMCP = ["personal", "homelab", "bitwarden", "forms"]
    var denyReads = ["~/Cantrip Memory", "~/Library/Messages", "~/Library/Mail"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludeMCP = try c.decodeIfPresent([String].self, forKey: .excludeMCP) ?? Self().excludeMCP
        denyReads = try c.decodeIfPresent([String].self, forKey: .denyReads) ?? Self().denyReads
    }
}

/// The `privacyGate` section of the agent policy file. A file without it gets these defaults:
/// on, observing (recording only).
struct PrivacyGateSettings: Codable, Equatable {
    enum Scope: String, Codable, CaseIterable { case homeChat, homeTasks }
    enum OfflineChat: String, Codable, CaseIterable { case ask, cancel }
    enum OfflineTasks: String, Codable, CaseIterable { case hold, cancel }
    struct Offline: Codable, Equatable {
        var chat = OfflineChat.ask
        var tasks = OfflineTasks.hold
    }
    struct Timeouts: Codable, Equatable {
        var chat = 10
        var tasks = 240
    }

    var enabled = true
    var mode = PrivacyGateMode.observe
    var appliesTo: [Scope] = Scope.allCases
    /// The route when no rule decides and the classifier is off.
    var defaultRoute = PrivacyRoute.cloud
    /// The route when the classifier answers but isn't sure.
    var uncertainRoute = PrivacyRoute.redactApprove
    var classifier = PrivacyClassifierSettings()
    var rules = PrivacyGateRule.defaults
    /// Home chat's own route.
    var chat = PrivacyRouteOverride.auto
    /// Each scheduled task's own route, by task UUID.
    var tasks: [String: PrivacyRouteOverride] = [:]
    var cloudRuns = PrivacyCloudRuns()
    var offline = Offline()
    var approvalTimeoutMinutes = Timeouts()
    /// Once a Home chat request is routed local, the next turns stay local while it is still among
    /// the earlier turns sent along with each new message (Home has no Start Fresh). 0 = off.
    var stickyTurns = 3
    /// The user's own names ("Pat" or "Pat Example"): never counted as a person's name.
    var ownerNames: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mode = try c.decodeIfPresent(PrivacyGateMode.self, forKey: .mode) ?? d.mode
        appliesTo = try c.decodeIfPresent([Scope].self, forKey: .appliesTo) ?? d.appliesTo
        defaultRoute = try c.decodeIfPresent(PrivacyRoute.self, forKey: .defaultRoute) ?? d.defaultRoute
        uncertainRoute = try c.decodeIfPresent(PrivacyRoute.self, forKey: .uncertainRoute) ?? d.uncertainRoute
        classifier = try c.decodeIfPresent(PrivacyClassifierSettings.self, forKey: .classifier) ?? d.classifier
        rules = try c.decodeIfPresent([PrivacyGateRule].self, forKey: .rules).map(PrivacyGateRule.migrated) ?? d.rules
        chat = try c.decodeIfPresent(PrivacyRouteOverride.self, forKey: .chat) ?? d.chat
        tasks = try c.decodeIfPresent([String: PrivacyRouteOverride].self, forKey: .tasks) ?? d.tasks
        cloudRuns = try c.decodeIfPresent(PrivacyCloudRuns.self, forKey: .cloudRuns) ?? d.cloudRuns
        offline = try c.decodeIfPresent(Offline.self, forKey: .offline) ?? d.offline
        approvalTimeoutMinutes = try c.decodeIfPresent(Timeouts.self, forKey: .approvalTimeoutMinutes) ?? d.approvalTimeoutMinutes
        stickyTurns = try c.decodeIfPresent(Int.self, forKey: .stickyTurns) ?? d.stickyTurns
        ownerNames = try c.decodeIfPresent([String].self, forKey: .ownerNames) ?? d.ownerNames
    }

    func applies(to scope: Scope) -> Bool { enabled && appliesTo.contains(scope) }

    func override(forTask id: UUID?) -> PrivacyRouteOverride {
        guard let id else { return chat }
        return tasks[id.uuidString] ?? tasks[id.uuidString.lowercased()] ?? .auto
    }

    func validationErrors() -> [String] {
        var errors: [String] = []
        var seen: Set<String> = []
        for rule in rules {
            if rule.id.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("A privacy rule has no ID.") }
            else if !seen.insert(rule.id).inserted { errors.append("Two privacy rules share the ID \(rule.id).") }
            let hasTarget = !(rule.detectors ?? []).isEmpty || !(rule.sources ?? []).isEmpty
                || rule.privateTerms == true || rule.repoWorkdir == true
            if !hasTarget { errors.append("Privacy rule \(rule.id) matches nothing: add detectors, sources, privateTerms or repoWorkdir.") }
        }
        for key in tasks.keys where UUID(uuidString: key) == nil {
            errors.append("Privacy routes for tasks need a task UUID (\(key)).")
        }
        let c = classifier
        if !(500...10_000).contains(c.timeoutMs) { errors.append("The classifier timeout must be 500-10000 ms.") }
        if !(500...60_000).contains(c.taskTimeoutMs) { errors.append("The classifier timeout for tasks must be 500-60000 ms.") }
        if !(1...6).contains(c.rotations) { errors.append("Ask the classifier 1-6 times.") }
        if !(0.5...1).contains(c.cloudMinProbability) { errors.append("The cloud threshold must be 0.5-1.") }
        if !(200...20_000).contains(c.maxInputCharacters) { errors.append("Send the classifier 200-20000 characters.") }
        if !(200...20_000).contains(c.chatInputCharacters) { errors.append("Send the classifier 200-20000 characters of Home chat.") }
        if !c.baseURL.isEmpty, let problem = PrivacyHostCheck.problem(with: c.baseURL) { errors.append(problem) }
        if !(0...20).contains(stickyTurns) { errors.append("Stay local for 0-20 turns.") }
        if ownerNames.count > 20 || ownerNames.contains(where: { $0.count > 80 }) {
            errors.append("List up to 20 owner names of up to 80 characters.")
        }
        if !(1...1440).contains(approvalTimeoutMinutes.chat) || !(1...1440).contains(approvalTimeoutMinutes.tasks) {
            errors.append("Approval timeouts must be 1-1440 minutes.")
        }
        return errors
    }
}

/// Where a classifier may be: this Mac, the local network or the tailnet.
enum PrivacyHostCheck {
    /// Cantrip's own OpenAI-compatible API, which would send the question to a cloud backend.
    static let cantripPort = 11439

    /// Why `baseURL` can't be used, or nil. Only this Mac, the LAN and the tailnet; HTTPS unless
    /// on loopback; never Cantrip's own API port.
    static func problem(with baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            return "Enter the classifier server's base URL, such as https://<server>/v1, without credentials or query parameters."
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        if scheme != "https", !loopback {
            return "Use HTTPS for a classifier on another machine (such as its Tailscale Serve URL). HTTP is allowed only on this Mac."
        }
        if components.port == cantripPort {
            return "Port \(cantripPort) is Cantrip's own model API, which can forward to the cloud. Use the model server itself."
        }
        guard loopback || isPrivateHost(host) else {
            return "The classifier must be on this Mac, your local network or your tailnet."
        }
        return nil
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.hasSuffix(".ts.net") || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".internal") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, host.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true   // tailnet (CGNAT range)
            default: return false
            }
        }
        if host.contains(":") { return host.hasPrefix("fd") || host.hasPrefix("fc") || host.hasPrefix("fe80") || host == "::1" }
        // A single-label name only resolves on the local network.
        return !host.contains(".")
    }
}
