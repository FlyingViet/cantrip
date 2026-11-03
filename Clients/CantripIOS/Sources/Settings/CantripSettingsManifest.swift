import Foundation
import SwiftUI

/// One setting's value as the Mac sends it.
enum CantripSettingValue: Codable, Hashable {
    case bool(Bool), int(Int), double(Double), string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    var string: String? { if case .string(let value) = self { return value } else { return nil } }

    var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded(): return Int(value)
        default: return nil
        }
    }

    /// Whole numbers arrive as integers even for decimal settings (1.0 is sent as 1).
    var double: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// The same value for matching, so 1 and 1.0 are equal.
    func matches(_ other: CantripSettingValue) -> Bool {
        if self == other { return true }
        if let lhs = double, let rhs = other.double { return lhs == rhs }
        return false
    }
}

/// `GET /api/v1/settings`: the Mac's own settings as pages of fields, drawn the same way on every
/// client (`SettingsManifestSections`). Keys are the Mac's `cantrip config` names.
struct CantripSettingsManifest: Decodable, Equatable {
    struct Choice: Decodable, Equatable, Hashable {
        let value: CantripSettingValue
        let label: String
        var disabled: Bool? = nil
    }

    struct Condition: Decodable, Equatable {
        let key: String
        let values: [CantripSettingValue]
    }

    struct Field: Decodable, Equatable, Identifiable {
        enum Kind: String, Decodable {
            case toggle, choice, integer, port, number, text, path, secret, action, info, unknown

            init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        let key: String
        let type: Kind
        let label: String
        var help: String? = nil
        var value: CantripSettingValue? = nil
        var isSet: Bool? = nil
        var choices: [Choice]? = nil
        var min: Double? = nil
        var max: Double? = nil
        var step: Double? = nil
        var unit: String? = nil
        var format: String? = nil
        var placeholder: String? = nil
        var zeroLabel: String? = nil
        var visibleWhen: Condition? = nil
        var readOnly: Bool? = nil
        var readOnlyReason: String? = nil
        var guarded: Bool? = nil
        var destructive: Bool? = nil
        var confirmation: String? = nil
        var multiline: Bool? = nil
        var maxLength: Int? = nil
        var tone: String? = nil

        var id: String { key }
        var isReadOnly: Bool { readOnly == true }

        /// The choices to offer: enabled ones, plus the saved one even when it's no longer offered.
        var offeredChoices: [Choice] {
            (choices ?? []).filter { $0.disabled != true || value.map($0.value.matches) == true }
        }

        /// "70%", "30 minutes", "Automatic".
        func display(_ value: CantripSettingValue?) -> String {
            guard let value else { return "" }
            if let match = choices?.first(where: { $0.value.matches(value) }) { return match.label }
            switch type {
            case .number where format == "percent":
                return "\(Int(((value.double ?? 0) * 100).rounded()))%"
            case .port where value.int == 0:
                return zeroLabel ?? "0"
            case .integer, .port:
                let number = value.int.map(String.init) ?? ""
                return unit.map { "\(number) \($0)" } ?? number
            case .toggle:
                return value.bool == true ? "On" : "Off"
            default:
                return value.string ?? ""
            }
        }
    }

    struct Section: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        var footer: String? = nil
        var link: Bool? = nil
        var summary: String? = nil
        let fields: [Field]
    }

    struct Page: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let sections: [Section]
    }

    struct Pending: Decodable, Equatable {
        let id: String
        let keys: [String]
        let summary: String
        let secondsLeft: Int
    }

    let version: Int
    let revision: String
    let mac: String
    var local: Bool? = nil
    let pages: [Page]
    var pending: Pending? = nil

    func page(_ id: String) -> Page? { pages.first { $0.id == id } }

    var fields: [Field] { pages.flatMap { $0.sections.flatMap(\.fields) } }

    func field(_ key: String) -> Field? { fields.first { $0.key == key } }

    /// Shown unless it depends on another field whose value isn't one it waits for.
    func isVisible(_ field: Field) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        guard let value = self.field(condition.key)?.value else { return true }
        return condition.values.contains { $0.matches(value) }
    }

    func visibleFields(_ section: Section) -> [Field] { section.fields.filter(isVisible) }
}

/// What a button on the Mac answered.
struct CantripSettingsActionResult: Decodable, Equatable {
    var title: String? = nil
    var message: String? = nil
    /// Text to copy, shown once (a new endpoint key).
    var copy: String? = nil
    var link: String? = nil
    var qr: Bool? = nil
    /// The Mac's new pairing token after this device replaced it: saved here, then the change is kept.
    var pairingToken: String? = nil

    var showsSheet: Bool { copy != nil || link != nil }
}

/// A manifest with the action's answer, when there was one.
struct CantripSettingsReply: Decodable {
    let manifest: CantripSettingsManifest
    let result: CantripSettingsActionResult?

    private enum CodingKeys: String, CodingKey { case result }

    init(from decoder: Decoder) throws {
        manifest = try CantripSettingsManifest(from: decoder)
        result = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(CantripSettingsActionResult.self, forKey: .result)
    }
}

enum CantripSettingsChange {
    case set([String: CantripSettingValue], revision: String)
    case action(String)
    case keep(String)
    case revert(String)

    var body: Data {
        get throws {
            struct Changes: Encodable { let revision: String; let changes: [String: CantripSettingValue] }
            switch self {
            case .set(let changes, let revision): return try JSONEncoder().encode(Changes(revision: revision, changes: changes))
            case .action(let key): return try JSONEncoder().encode(["action": key])
            case .keep(let id): return try JSONEncoder().encode(["keep": id])
            case .revert(let id): return try JSONEncoder().encode(["revert": id])
            }
        }
    }
}

/// The key Cantrip.app hands its own Home window for This Mac (loopback), sent as
/// `X-Cantrip-Local-Key` so the Mac knows the request is its own window rather than a paired
/// device. Only Cantrip.app registers one; it never goes to another Mac.
enum CantripLocalClientKey {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [String: String] = [:]

    static func register(_ key: String?, for baseURL: String) {
        guard let url = URL(string: baseURL), let origin = origin(url), isLoopback(url) else { return }
        lock.withLock { keys[origin] = key }
    }

    static func key(for url: URL) -> String? {
        guard isLoopback(url), let origin = origin(url) else { return nil }
        return lock.withLock { keys[origin] }
    }

    private static func origin(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return "\(url.scheme?.lowercased() ?? "http")://\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

/// The Mac's settings for every Settings page: loaded once when Settings opens, reloaded when the
/// Mac's settings revision moves (another device changed one) or the Mac in use changes.
@MainActor
final class CantripSettingsStore: ObservableObject {
    @Published private(set) var manifest: CantripSettingsManifest?
    /// The Mac answers 404: it's from before the settings manifest.
    @Published private(set) var unsupported = false
    @Published private(set) var isLoading = false
    @Published private(set) var savingKeys: Set<String> = []
    /// Why the last load or change didn't work, by key (nil key: the whole manifest).
    @Published var errors: [String: String] = [:]
    /// What a button said back, under it.
    @Published var notes: [String: String] = [:]
    @Published var loadError: String?
    @Published var shownResult: ShownResult?
    /// When the waiting change undoes itself, by this device's clock.
    @Published private(set) var pendingDeadline: Date?

    struct ShownResult: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let result: CantripSettingsActionResult
    }

    private(set) var remote: CantripRemoteModel?
    private var loadedFor: UUID?

    /// Settings' Mac connection; set when Settings opens.
    func attach(_ remote: CantripRemoteModel) {
        self.remote = remote
    }

    func load(force: Bool = false) async {
        guard let remote, remote.isConfigured else {
            manifest = nil
            return
        }
        let identity = remote.usageIdentity
        if !force, loadedFor == identity, manifest != nil { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await remote.settingsManifest()
            guard identity == remote.usageIdentity else { return }
            apply(loaded)
            loadedFor = identity
            unsupported = false
            loadError = nil
        } catch CantripRemoteError.settingsUnsupported {
            manifest = nil
            unsupported = true
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Another device (or the Mac) changed a setting, or the Mac in use changed.
    func refresh(revision: String?) async {
        guard let remote else { return }
        if loadedFor != remote.usageIdentity {
            manifest = nil
            await load(force: true)
        } else if let revision, let manifest, revision != manifest.revision, savingKeys.isEmpty {
            await load(force: true)
        }
    }

    func set(_ field: CantripSettingsManifest.Field, _ value: CantripSettingValue) async {
        guard let remote, let manifest else { return }
        if field.type != .secret, let current = field.value, current.matches(value) { return }
        errors[field.key] = nil
        savingKeys.insert(field.key)
        defer { savingKeys.remove(field.key) }
        if let reply = await remote.updateSettings(.set([field.key: value], revision: manifest.revision)) {
            apply(reply.manifest)
        } else {
            errors[field.key] = remote.lastSettingsError ?? "Not saved."
            // A stale revision (another device saved first): show what the Mac has now.
            await load(force: true)
        }
    }

    func run(_ field: CantripSettingsManifest.Field) async {
        guard let remote else { return }
        errors[field.key] = nil
        notes[field.key] = nil
        savingKeys.insert(field.key)
        defer { savingKeys.remove(field.key) }
        guard let reply = await remote.updateSettings(.action(field.key)) else {
            errors[field.key] = remote.lastSettingsError ?? "That didn't work."
            return
        }
        apply(reply.manifest)
        guard var result = reply.result else { return }
        if let token = result.pairingToken, let pending = reply.manifest.pending {
            result.pairingToken = nil
            if let kept = await remote.adoptReplacedPairingToken(token, keep: pending.id) {
                apply(kept)
            } else {
                errors[field.key] = "This device couldn't reconnect with the new token, so the Mac will put the old one back within a minute."
            }
        }
        if result.showsSheet {
            shownResult = ShownResult(label: field.label, result: result)
        } else if let message = result.message, !message.isEmpty {
            notes[field.key] = message
        }
    }

    func keep() async {
        guard let remote, let pending = manifest?.pending else { return }
        if let reply = await remote.updateSettings(.keep(pending.id)) {
            apply(reply.manifest)
        } else {
            loadError = remote.lastSettingsError
            await load(force: true)
        }
    }

    func undo() async {
        guard let remote, let pending = manifest?.pending else { return }
        if let reply = await remote.updateSettings(.revert(pending.id)) { apply(reply.manifest) }
        else { await load(force: true) }
    }

    private func apply(_ manifest: CantripSettingsManifest) {
        self.manifest = manifest
        pendingDeadline = manifest.pending.map { Date().addingTimeInterval(TimeInterval($0.secondsLeft)) }
    }
}

private struct CantripSettingsStoreKey: EnvironmentKey {
    static let defaultValue: CantripSettingsStore? = nil
}

extension EnvironmentValues {
    /// The Mac's settings while Settings is open; pages draw their part with `SettingsManifestSections`.
    var cantripSettings: CantripSettingsStore? {
        get { self[CantripSettingsStoreKey.self] }
        set { self[CantripSettingsStoreKey.self] = newValue }
    }
}
