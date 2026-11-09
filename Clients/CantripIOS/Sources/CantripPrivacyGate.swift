import SwiftUI

/// Where the Privacy Gate sent (enforce) or would send (observe) a Cantrip Home run.
enum CantripPrivacyRoute: String, CaseIterable {
    case local, cloud, redactApprove, offline

    var symbol: String {
        switch self {
        case .local: return "house.fill"
        case .cloud: return "cloud"
        case .redactApprove: return "eye.slash"
        case .offline: return "wifi.slash"
        }
    }

    var title: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        case .redactApprove: return "Ask first"
        case .offline: return "Privacy check offline"
        }
    }
}

/// A Home prompt's Privacy Gate decision (`privacy` on a user message). Macs from before the gate
/// leave it out, and it can arrive a moment after the message. Never fails the message's decode.
struct CantripPrivacyBadge: Decodable, Equatable {
    enum Emphasis: Equatable {
        /// Observe mode: recorded only, the run went as usual.
        case quiet
        /// Enforce mode kept the run on the user's own model server.
        case local
        /// Enforce mode routed it anywhere else.
        case enforced
    }

    var route: String
    var mode: String
    var applied: Bool
    var label: String
    var detail: String

    init(route: String, mode: String = "observe", applied: Bool = false, label: String, detail: String = "") {
        self.route = route
        self.mode = mode
        self.applied = applied
        self.label = label
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case route, mode, applied, label, detail }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        route = (try? container?.decodeIfPresent(String.self, forKey: .route)) ?? "offline"
        mode = (try? container?.decodeIfPresent(String.self, forKey: .mode)) ?? "observe"
        applied = (try? container?.decodeIfPresent(Bool.self, forKey: .applied)) ?? false
        label = ((try? container?.decodeIfPresent(String.self, forKey: .label)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        detail = ((try? container?.decodeIfPresent(String.self, forKey: .detail)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var kind: CantripPrivacyRoute? { CantripPrivacyRoute(rawValue: route) }
    var isEnforced: Bool { mode == "enforce" }
    var isVisible: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var symbol: String { kind?.symbol ?? "shield" }

    var emphasis: Emphasis {
        guard isEnforced else { return .quiet }
        return kind == .local ? .local : .enforced
    }

    var accessibilityLabel: String { "Privacy: \(label)" }

    var modeTitle: String { isEnforced ? "Enforcing" : "Observing" }
}

/// The Privacy Gate's decision under a Home prompt: a quiet capsule with the route and why, and the
/// full reason on tap. Shared by the iPhone and iPad chat and Gateway Mac's Home window.
struct CantripPrivacyBadgeView: View {
    let badge: CantripPrivacyBadge
    @State private var showingDetail = false
    @ScaledMetric(relativeTo: .caption2) private var radius: CGFloat = 9

    var body: some View {
        Button { showingDetail = true } label: { capsule }
            .buttonStyle(.plain)
            .accessibilityLabel(badge.accessibilityLabel)
            .accessibilityHint(badge.detail.isEmpty ? "Shows why" : badge.detail)
            .accessibilityIdentifier("cantrip.privacyBadge")
            .popover(isPresented: $showingDetail, arrowEdge: .top) {
                CantripPrivacyBadgeDetail(badge: badge)
                    .frame(idealWidth: 320, maxWidth: 360)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private var capsule: some View {
        let shape = RoundedRectangle(cornerRadius: min(radius, 14), style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: badge.symbol)
                .imageScale(.small)
                .foregroundStyle(iconStyle)
            Text(badge.label)
                .foregroundStyle(textStyle)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        .frame(minHeight: 28)
        .contentShape(Rectangle())
    }

    private var iconStyle: Color {
        switch badge.emphasis {
        case .quiet: return CantripReasoningFormat.secondaryText
        case .local: return .accentColor
        case .enforced: return .primary
        }
    }

    private var textStyle: Color {
        badge.emphasis == .quiet ? CantripReasoningFormat.secondaryText : .primary
    }

    private var fill: Color {
        switch badge.emphasis {
        case .quiet: return Color.secondary.opacity(0.12)
        case .local: return Color.accentColor.opacity(0.2)
        case .enforced: return Color.primary.opacity(0.1)
        }
    }

    private var stroke: Color {
        badge.emphasis == .local ? Color.accentColor.opacity(0.6) : .clear
    }
}

/// The badge's popover: the mode, the decision and the Mac's reason.
struct CantripPrivacyBadgeDetail: View {
    let badge: CantripPrivacyBadge

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privacy Gate · \(badge.modeTitle)", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CantripReasoningFormat.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Label(badge.label, systemImage: badge.symbol)
                .font(.callout.weight(.semibold))
            if !badge.detail.isEmpty {
                Text(badge.detail)
                    .font(.callout)
                    .foregroundStyle(CantripReasoningFormat.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - Settings (the agent policy's `privacyGate` section)

/// Home chat's or one task's own route; `auto` lets the gate decide each time.
enum CantripPrivacyRouteChoice: String, CaseIterable, Identifiable {
    case auto, local, cloud, cloudWithPrivateTools

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Decide each time"
        case .local: return "Always local"
        case .cloud: return "Always cloud, without private tools"
        case .cloudWithPrivateTools: return "Always cloud, with private tools"
        }
    }
}

/// The agent policy's `privacyGate` section, held as the Mac sent it: a change sends the whole
/// section back, so fields this client doesn't show keep their values.
struct CantripPrivacyGate: Decodable, Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case observe, enforce

        var id: String { rawValue }
        var title: String { self == .observe ? "Observe" : "Enforce" }
        var explanation: String {
            switch self {
            case .observe: return "Records what it would do and changes nothing."
            case .enforce: return "Routes runs and removes private tools from cloud runs."
            }
        }
    }

    /// One fixed rule; the first enabled rule that applies decides.
    struct Rule: Equatable, Identifiable {
        let id: String
        let route: String
        let enabled: Bool
        let detectors: [String]
        let sources: [String]
        let privateTerms: Bool
        let repoWorkdir: Bool

        init?(_ value: MCPAppJSONValue) {
            guard case .object(let object) = value, let id = object["id"]?.privacyString, !id.isEmpty else { return nil }
            self.id = id
            route = object["route"]?.privacyString ?? ""
            enabled = object["enabled"]?.privacyBool ?? true
            detectors = object["detectors"]?.privacyStrings ?? []
            sources = object["sources"]?.privacyStrings ?? []
            privateTerms = object["privateTerms"]?.privacyBool ?? false
            repoWorkdir = object["repoWorkdir"]?.privacyBool ?? false
        }

        var routeTitle: String { CantripPrivacyRoute(rawValue: route)?.title ?? route }

        /// What it looks for: "card numbers, phone numbers · private terms".
        var matches: String {
            var parts: [String] = []
            if !detectors.isEmpty { parts.append(detectors.map(CantripPrivacyGate.detectorLabel).joined(separator: ", ")) }
            if !sources.isEmpty { parts.append("private sources: " + sources.joined(separator: ", ")) }
            if privateTerms { parts.append("private terms") }
            if repoWorkdir { parts.append("work in a code repository") }
            return parts.joined(separator: " · ")
        }
    }

    var raw: [String: MCPAppJSONValue]

    init(raw: [String: MCPAppJSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        guard case .object(let object) = try MCPAppJSONValue(from: decoder) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "The Privacy Gate section isn't an object."))
        }
        raw = object
    }

    var enabled: Bool { raw["enabled"]?.privacyBool ?? true }
    var mode: Mode { raw["mode"]?.privacyString.flatMap(Mode.init(rawValue:)) ?? .observe }
    var chat: CantripPrivacyRouteChoice {
        raw["chat"]?.privacyString.flatMap(CantripPrivacyRouteChoice.init(rawValue:)) ?? .auto
    }
    var rules: [Rule] {
        guard case .array(let values)? = raw["rules"] else { return [] }
        return values.compactMap(Rule.init)
    }

    func route(forTask id: UUID) -> CantripPrivacyRouteChoice {
        guard case .object(let tasks)? = raw["tasks"] else { return .auto }
        let value = tasks[id.uuidString] ?? tasks[id.uuidString.lowercased()]
        return value?.privacyString.flatMap(CantripPrivacyRouteChoice.init(rawValue:)) ?? .auto
    }

    /// The section with one top-level field changed.
    func setting(_ key: String, to value: MCPAppJSONValue) -> CantripPrivacyGate {
        var copy = self
        copy.raw[key] = value
        return copy
    }

    /// The section with one rule turned on or off; every other field of every rule as read.
    func settingRule(_ id: String, enabled: Bool) -> CantripPrivacyGate {
        guard case .array(var values)? = raw["rules"] else { return self }
        for index in values.indices {
            guard case .object(var rule) = values[index], rule["id"]?.privacyString == id else { continue }
            rule["enabled"] = .bool(enabled)
            values[index] = .object(rule)
        }
        return setting("rules", to: .array(values))
    }

    /// `{"privacyGate": {…}}`: the whole section (the revision is added when it's saved).
    var change: [String: Any] { ["privacyGate": MCPAppJSONValue.object(raw).any] }

    /// `{"privacyRoute": {"task", "route"}}`: Home chat's route (no task) or one task's; `auto` clears it.
    static func routeChange(task: UUID?, route: CantripPrivacyRouteChoice) -> [String: Any] {
        ["privacyRoute": ["task": task.map { $0.uuidString as Any } ?? NSNull(), "route": route.rawValue]]
    }

    static func detectorLabel(_ detector: String) -> String {
        switch detector {
        case "secret": return "secrets"
        case "ssn": return "Social Security numbers"
        case "card": return "card numbers"
        case "account": return "account numbers"
        case "email": return "email addresses"
        case "phone": return "phone numbers"
        case "address": return "street addresses"
        case "name": return "people's names"
        default: return detector
        }
    }
}

/// `privacyClassifier` in the policy snapshot: where the gate asks, or why it can't.
struct CantripPrivacyClassifierStatus: Decodable, Equatable {
    var address: String?
    var model: String?
    /// "own", "privateLocal" or "none".
    var from: String
    var problem: String?
    var log: String?

    init(address: String? = nil, model: String? = nil, from: String, problem: String? = nil, log: String? = nil) {
        self.address = address
        self.model = model
        self.from = from
        self.problem = problem
        self.log = log
    }

    private enum CodingKeys: String, CodingKey { case address, model, from, problem, log }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try? container.decodeIfPresent(String.self, forKey: .address)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        from = (try? container.decodeIfPresent(String.self, forKey: .from)) ?? "none"
        problem = try? container.decodeIfPresent(String.self, forKey: .problem)
        log = try? container.decodeIfPresent(String.self, forKey: .log)
    }

    var isConfigured: Bool { from != "none" }

    /// "Same server as Private Local", the classifier's own address, or why there's none.
    var headline: String {
        switch from {
        case "privateLocal": return "Same server as Private Local"
        case "own": return address ?? "Its own server"
        default: return problem ?? "No classifier is set up."
        }
    }

    /// The address (when the headline isn't it) and the model.
    var subtitle: String? {
        guard isConfigured else { return nil }
        let parts = [from == "own" ? nil : address, model.map { "Model: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `POST /api/v1/policy/privacy-test`: one synthetic coding question to the classifier.
struct CantripPrivacyTestResult: Decodable, Equatable {
    var ok: Bool
    var address: String? = nil
    var model: String? = nil
    var latencyMs: Int? = nil
    var route: String? = nil
    var probabilities: [String: Double]? = nil
    var error: String? = nil

    /// "Cloud in 412 ms · 97% cloud", or the Mac's reason it didn't answer.
    var summary: String {
        guard ok else { return error ?? "The classifier didn't answer." }
        let route = route.map { CantripPrivacyRoute(rawValue: $0)?.title ?? $0 } ?? "Answered"
        var text = route
        if let latencyMs { text += " in \(latencyMs) ms" }
        if let cloud = probabilities?["cloud"] { text += " · \(Int((cloud * 100).rounded()))% cloud" }
        return text
    }
}

private extension MCPAppJSONValue {
    var privacyString: String? { if case .string(let value) = self { return value } else { return nil } }
    var privacyBool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    var privacyStrings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.privacyString)
    }
}
