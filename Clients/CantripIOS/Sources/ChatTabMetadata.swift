import Foundation

struct ChatTabMetadata: Codable, Equatable {
    private(set) var customTitle: String?
    var isLocked = false

    mutating func rename(_ name: String) throws {
        let normalized = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count <= 80 else { throw ChatTabError.nameTooLong }
        customTitle = normalized.isEmpty ? nil : normalized
    }
}

enum ChatTabError: LocalizedError {
    case nameTooLong
    case locked

    var errorDescription: String? {
        switch self {
        case .nameTooLong: return "Tab names must be 80 characters or fewer."
        case .locked: return "Unlock this tab before closing it or clearing its conversation."
        }
    }
}
