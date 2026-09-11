import Foundation

enum SessionTabError: LocalizedError {
    case nameTooLong
    case locked
    case unavailable

    var errorDescription: String? {
        switch self {
        case .nameTooLong: return "Tab names must be 80 characters or fewer."
        case .locked: return "Unlock this tab before closing it or clearing its conversation."
        case .unavailable: return "A tab is no longer open. Refresh the tabs and try again."
        }
    }
}

struct SessionTabMetadata: Equatable {
    private(set) var customTitle: String?
    var isLocked = false

    mutating func rename(_ name: String) throws {
        let normalized = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count <= 80 else { throw SessionTabError.nameTooLong }
        customTitle = normalized.isEmpty ? nil : normalized
    }

    func requireUnlocked() throws {
        guard !isLocked else { throw SessionTabError.locked }
    }

    static func load(id: UUID, defaults: UserDefaults = .standard) -> Self {
        let value = defaults.dictionary(forKey: key(id)) ?? [:]
        return Self(customTitle: value["customTitle"] as? String,
                    isLocked: value["isLocked"] as? Bool ?? false)
    }

    func save(id: UUID, defaults: UserDefaults = .standard) {
        var value: [String: Any] = ["isLocked": isLocked]
        if let customTitle { value["customTitle"] = customTitle }
        defaults.set(value, forKey: Self.key(id))
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(id))
    }

    private static func key(_ id: UUID) -> String { "sessionTab-\(id.uuidString)" }
}
