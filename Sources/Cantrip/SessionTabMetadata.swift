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
    /// Copilot's per-tab model settings.
    var modelSettings: SessionModelSelection?
    /// Claude Code's, kept apart: the two backends' model IDs differ.
    var claudeModelSettings: SessionModelSelection?
    /// The sidebar section this tab is filed under; nil (or a deleted section) shows it under Tabs.
    var sectionID: UUID?

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
        var result = Self(customTitle: value["customTitle"] as? String,
                          isLocked: value["isLocked"] as? Bool ?? false,
                          sectionID: (value["sectionID"] as? String).flatMap(UUID.init(uuidString:)))
        func selection(_ key: String) -> SessionModelSelection? {
            guard let selection = value[key] as? [String: String],
                  let model = selection["model"], let effort = selection["effort"],
                  let contextTier = selection["contextTier"] else { return nil }
            return SessionModelSelection(model: model, effort: effort, contextTier: contextTier)
        }
        result.modelSettings = selection("modelSettings")
        result.claudeModelSettings = selection("claudeModelSettings")
        return result
    }

    func modelSettings(for backend: BackendKind) -> SessionModelSelection? {
        backend == .claudeCode ? claudeModelSettings : modelSettings
    }

    mutating func setModelSettings(_ selection: SessionModelSelection?, for backend: BackendKind) {
        if backend == .claudeCode { claudeModelSettings = selection } else { modelSettings = selection }
    }

    func save(id: UUID, defaults: UserDefaults = .standard) {
        var value: [String: Any] = ["isLocked": isLocked]
        if let customTitle { value["customTitle"] = customTitle }
        if let sectionID { value["sectionID"] = sectionID.uuidString }
        for (key, selection) in [("modelSettings", modelSettings), ("claudeModelSettings", claudeModelSettings)] {
            guard let selection else { continue }
            value[key] = ["model": selection.model, "effort": selection.effort, "contextTier": selection.contextTier]
        }
        defaults.set(value, forKey: Self.key(id))
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(id))
    }

    private static func key(_ id: UUID) -> String { "sessionTab-\(id.uuidString)" }
}
