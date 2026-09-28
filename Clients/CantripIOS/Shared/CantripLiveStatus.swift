import ActivityKit
import Foundation
import Security
import SwiftUI

// Shared by Cantrip Agent and its widget extension. The Mac host serves
// GET /api/v1/live-status and pushes widget refreshes and Live Activity updates.

enum CantripLiveTabState: String, Codable, Hashable {
    case input, running, done, failed, stopped, idle

    var isActive: Bool { self == .input || self == .running }

    var label: String {
        switch self {
        case .input: return "Needs input"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .idle: return "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .input: return "exclamationmark.bubble.fill"
        case .running: return "circle.dotted.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "stop.circle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    var tint: Color {
        switch self {
        case .input: return .orange
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        case .stopped, .idle: return .secondary
        }
    }
}

/// What a waiting tab asks for, from the Mac's `inputKind`.
enum CantripLiveRequest: Equatable {
    case approval, question, secret, login, macAction, other

    init(kind: String?) {
        switch kind {
        case "approval": self = .approval
        case "question": self = .question
        case "secret": self = .secret
        case "login": self = .login
        case "localAction": self = .macAction
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .approval: return "Approval needed"
        case .question: return "Question for you"
        case .secret: return "Password needed"
        case .login: return "Sign-in needed"
        case .macAction: return "Action needed on Mac"
        case .other: return "Needs your response"
        }
    }

    /// Fits the trailing edge of a tab row.
    var shortTitle: String {
        switch self {
        case .approval: return "Approval"
        case .question: return "Question"
        case .secret: return "Password"
        case .login: return "Sign-in"
        case .macAction: return "On Mac"
        case .other: return "Needs input"
        }
    }

    var symbol: String {
        switch self {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .secret: return "key.fill"
        case .login: return "person.badge.key.fill"
        case .macAction: return "desktopcomputer"
        case .other: return "exclamationmark.bubble.fill"
        }
    }
}

struct CantripLiveTab: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let state: String
    var startedAt: Double?
    var finishedAt: Double?
    var detail: String?
    var queued: Int = 0
    var subagents: Int = 0
    /// approval, question, secret, login or localAction; set only while the tab waits.
    var inputKind: String?

    /// Unknown states from a newer host read as running rather than failing to decode.
    var status: CantripLiveTabState { CantripLiveTabState(rawValue: state) ?? .running }
    var startDate: Date? { startedAt.map(Date.init(timeIntervalSince1970:)) }
    var finishDate: Date? { finishedAt.map(Date.init(timeIntervalSince1970:)) }
    /// The pending request while the tab waits for a response.
    var request: CantripLiveRequest? { status == .input ? CantripLiveRequest(kind: inputKind) : nil }
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled tab" : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, state, startedAt, finishedAt, detail, queued, subagents, inputKind
    }

    init(id: String, title: String, state: String, startedAt: Double? = nil, finishedAt: Double? = nil,
         detail: String? = nil, queued: Int = 0, subagents: Int = 0, inputKind: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.detail = detail
        self.queued = queued
        self.subagents = subagents
        self.inputKind = inputKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Double.self, forKey: .finishedAt)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        queued = try container.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        subagents = try container.decodeIfPresent(Int.self, forKey: .subagents) ?? 0
        inputKind = try container.decodeIfPresent(String.self, forKey: .inputKind)
    }
}

struct CantripLiveStatusSnapshot: Codable, Equatable {
    var version = 1
    var generatedAt: Double
    var hostName: String
    var running: Int
    var needsInput: Int
    var total: Int
    var tabs: [CantripLiveTab]

    static let empty = CantripLiveStatusSnapshot(generatedAt: 0, hostName: "Cantrip", running: 0,
                                                 needsInput: 0, total: 0, tabs: [])

    var summary: String { CantripLiveFormat.summary(running: running, needsInput: needsInput, total: total) }
    var isActive: Bool { running + needsInput > 0 }
    var waitingTab: CantripLiveTab? { tabs.first { $0.status == .input } }
}

/// What the widget last knew, and when it learned it.
struct CantripLiveStatusCache: Codable, Equatable {
    var snapshot: CantripLiveStatusSnapshot
    var fetchedAt: Date
    var serverID: String
}

struct CantripTabsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var tabs: [CantripLiveTab]
        var running: Int
        var needsInput: Int
        var total: Int
        var updatedAt: Double

        var summary: String { CantripLiveFormat.summary(running: running, needsInput: needsInput, total: total) }
        var isActive: Bool { running + needsInput > 0 }
        /// The Mac lists waiting tabs first; the first one leads the Live Activity.
        var waitingTab: CantripLiveTab? { tabs.first { $0.status == .input } }
        /// Tapping the activity opens the tab that needs a response, if any.
        var primaryLink: URL {
            waitingTab.map { CantripDeepLink.tab($0.id, serverID: nil) } ?? CantripDeepLink.tabs(serverID: nil)
        }
        /// The longest-running tab drives the compact Dynamic Island timer.
        var oldestRunningStart: Date? {
            tabs.filter { $0.status == .running }.compactMap(\.startDate).min()
        }

        init(tabs: [CantripLiveTab], running: Int, needsInput: Int, total: Int, updatedAt: Double) {
            self.tabs = tabs
            self.running = running
            self.needsInput = needsInput
            self.total = total
            self.updatedAt = updatedAt
        }

        init(_ snapshot: CantripLiveStatusSnapshot) {
            self.init(tabs: Array(snapshot.tabs.prefix(5)), running: snapshot.running,
                      needsInput: snapshot.needsInput, total: snapshot.total, updatedAt: snapshot.generatedAt)
        }
    }

    var hostName: String
}

enum CantripLiveFormat {
    static func summary(running: Int, needsInput: Int, total: Int) -> String {
        var parts: [String] = []
        if needsInput > 0 { parts.append("\(needsInput) need\(needsInput == 1 ? "s" : "") input") }
        if running > 0 { parts.append("\(running) running") }
        if parts.isEmpty { return total == 0 ? "No tabs" : "All \(total) tab\(total == 1 ? "" : "s") idle" }
        return parts.joined(separator: " · ")
    }

    static func accessibility(_ tab: CantripLiveTab, now: Date = Date()) -> String {
        var parts = [tab.displayTitle, tab.request?.title ?? tab.status.label]
        if let finished = tab.finishDate, !tab.status.isActive {
            parts.append(RelativeDateTimeFormatter().localizedString(for: finished, relativeTo: now))
        }
        if let detail = tab.detail, !detail.isEmpty { parts.append(detail) }
        if tab.subagents > 0 { parts.append("\(tab.subagents) subagent\(tab.subagents == 1 ? "" : "s")") }
        if tab.queued > 0 { parts.append("\(tab.queued) queued") }
        return parts.joined(separator: ", ")
    }
}

enum CantripDeepLink {
    static let scheme = "cantripagent"

    enum Target: Equatable {
        case tabs(serverID: String?)
        case tab(id: String, serverID: String?)
    }

    static func tabs(serverID: String?) -> URL {
        url(host: "tabs", path: "", serverID: serverID)
    }

    static func tab(_ id: String, serverID: String?) -> URL {
        url(host: "tab", path: "/" + id, serverID: serverID)
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let server = components.queryItems?.first { $0.name == "server" }?.value
        switch components.host?.lowercased() {
        case "tabs":
            return .tabs(serverID: server)
        case "tab":
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard UUID(uuidString: id) != nil else { return .tabs(serverID: server) }
            return .tab(id: id, serverID: server)
        default:
            return nil
        }
    }

    private static func url(host: String, path: String, serverID: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        if let serverID { components.queryItems = [URLQueryItem(name: "server", value: serverID)] }
        return components.url ?? URL(string: "\(scheme)://tabs")!
    }
}

/// Pairing details the widget needs to fetch status on its own.
struct CantripLiveStatusConfig: Codable, Equatable {
    var serverID: String
    var token: String
    /// Tailscale (HTTPS) base URL; nil for local-network-only pairings.
    var baseURL: String?
    var installationID: String
    /// Apple push environment of this build ("development" or "production").
    var environment: String?
}

/// Shared Keychain items (access group `CantripKeychainGroup` from Info.plist),
/// readable by the widget after first unlock. Failures are non-fatal: the app
/// keeps working and the widget shows its last state.
enum CantripSharedStore {
    private static let service = "CantripAgentShared"
    private static let configAccount = "live-status.config"
    private static let cacheAccount = "live-status.cache"
    private static let widgetTokenAccount = "live-status.widget-token"

    static var accessGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CantripKeychainGroup") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") || $0.hasPrefix(".") ? nil : $0 }
    }

    static func loadConfig() -> CantripLiveStatusConfig? { load(configAccount) }
    @discardableResult static func saveConfig(_ config: CantripLiveStatusConfig?) -> Bool { save(config, configAccount) }
    static func loadCache() -> CantripLiveStatusCache? { load(cacheAccount) }
    @discardableResult static func saveCache(_ cache: CantripLiveStatusCache?) -> Bool { save(cache, cacheAccount) }
    static func loadWidgetToken() -> String? { load(widgetTokenAccount) }
    @discardableResult static func saveWidgetToken(_ token: String?) -> Bool { save(token, widgetTokenAccount) }

    private static func query(_ account: String) -> [String: Any]? {
        guard let accessGroup else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true]
    }

    private static func load<T: Decodable>(_ account: String) -> T? {
        guard var query = query(account) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T?, _ account: String) -> Bool {
        guard let query = query(account) else { return false }
        guard let value, let data = try? JSONEncoder().encode(value) else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }
}

enum CantripLiveStatusFetchError: LocalizedError, Equatable {
    case noRoute, hostTooOld, unauthorized, failed(Int)

    var errorDescription: String? {
        switch self {
        case .noRoute: return "Open Cantrip Agent to refresh."
        case .hostTooOld: return "Update Cantrip on your Mac."
        case .unauthorized: return "Pair Cantrip Agent with your Mac again."
        case .failed(let status): return "The Mac returned an error (\(status))."
        }
    }
}

enum CantripLiveStatusFetcher {
    /// Fetches over the Tailscale route. The app refreshes local-network-only pairings itself.
    static func fetch(_ config: CantripLiveStatusConfig,
                      session: URLSession = .shared) async throws -> CantripLiveStatusSnapshot {
        guard let url = endpoint(config.baseURL) else { throw CantripLiveStatusFetchError.noRoute }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try decode(data)
        case 404: throw CantripLiveStatusFetchError.hostTooOld
        case 401: throw CantripLiveStatusFetchError.unauthorized
        default: throw CantripLiveStatusFetchError.failed(status)
        }
    }

    /// Merges fields into this installation's live-status subscription on the Mac.
    static func subscribe(_ config: CantripLiveStatusConfig, fields: [String: Any],
                          session: URLSession = .shared) async throws {
        guard let url = endpoint(config.baseURL, path: "/api/v1/live-status/subscription"),
              let environment = config.environment else { throw CantripLiveStatusFetchError.noRoute }
        var body = fields
        body["installationID"] = config.installationID
        body["serverID"] = config.serverID
        body["environment"] = environment
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return
        case 404: throw CantripLiveStatusFetchError.hostTooOld
        case 401: throw CantripLiveStatusFetchError.unauthorized
        default: throw CantripLiveStatusFetchError.failed(status)
        }
    }

    static func endpoint(_ baseURL: String?, path: String = "/api/v1/live-status") -> URL? {
        guard let baseURL, var components = URLComponents(string: baseURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { return nil }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.query = nil
        return components.url
    }

    static func decode(_ data: Data) throws -> CantripLiveStatusSnapshot {
        try JSONDecoder().decode(CantripLiveStatusSnapshot.self, from: data)
    }
}

/// The tab waiting for a response, shown above the other tabs in the Live Activity.
struct CantripLiveRequestCallout: View {
    let tab: CantripLiveTab
    /// Other tabs also waiting.
    var others = 0
    var compact = false

    private var request: CantripLiveRequest { tab.request ?? .other }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: request.symbol)
                .font(compact ? .footnote.weight(.semibold) : .callout.weight(.semibold))
                .foregroundStyle(Color.orange)
                .frame(width: compact ? 16 : 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // Primary text keeps contrast on the tinted background; orange marks the icon and edge.
                    Text(request.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.primary)
                    Text("· \(tab.displayTitle)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                    Spacer(minLength: 4)
                    if others > 0 {
                        Text("+\(others) waiting")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .lineLimit(1)
                Text(tab.detail?.isEmpty == false ? tab.detail! : "Open the tab to respond.")
                    .font(compact ? .caption : .footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .privacySensitive()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the tab so you can respond.")
    }

    private var accessibilityText: String {
        var parts = ["\(request.title) in \(tab.displayTitle)"]
        if let detail = tab.detail, !detail.isEmpty { parts.append(detail) }
        if others > 0 { parts.append("\(others) more tab\(others == 1 ? "" : "s") waiting") }
        return parts.joined(separator: ", ")
    }
}

/// One tab row for the widget and the Live Activity.
struct CantripLiveTabRow: View {
    let tab: CantripLiveTab
    var showsDetail = false
    var compact = false

    var body: some View {
        HStack(alignment: showsDetail ? .top : .center, spacing: 8) {
            Image(systemName: tab.status.symbol)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(tab.status.tint)
                .frame(width: compact ? 14 : 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // Rows sit inside Links: use concrete colors so they don't take the link tint.
                Text(tab.displayTitle)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .privacySensitive()
                if showsDetail, let line = detailLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
            }
            Spacer(minLength: 4)
            trailing
                .font(compact ? .caption2.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(tab.status == .input ? Color.orange : Color.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripLiveFormat.accessibility(tab))
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let detail = tab.detail, !detail.isEmpty { parts.append(detail) }
        if tab.subagents > 0 { parts.append("\(tab.subagents) subagent\(tab.subagents == 1 ? "" : "s")") }
        if tab.queued > 0 { parts.append("\(tab.queued) queued") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch tab.status {
        case .running:
            if let start = tab.startDate {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .frame(maxWidth: 64, alignment: .trailing)
            } else {
                Text("Running")
            }
        case .input:
            Text(tab.request?.shortTitle ?? tab.status.label)
        case .done, .failed, .stopped:
            if let finished = tab.finishDate {
                Text(finished, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            } else {
                Text(tab.status.label)
            }
        case .idle:
            Text("Idle")
        }
    }
}
