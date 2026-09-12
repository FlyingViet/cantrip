import Foundation

enum RemoteHistory {
    static let pageSize = 30
    static let pageBytes = 192 * 1024

    static func preview(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while end.samePosition(in: text.unicodeScalars) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
    }

    static func message(_ message: ChatMessage, compact: Bool) -> [String: Any] {
        let activities = compact ? Array(message.activities.suffix(40)) : message.activities
        var result: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "text": compact ? preview(message.text, bytes: 16 * 1024) : message.text,
            "thinking": compact ? preview(message.thinking, bytes: 4 * 1024) : message.thinking,
            "activities": activities.map { activity -> [String: Any] in
                var item: [String: Any] = [
                    "id": activity.id,
                    "title": compact ? preview(activity.title, bytes: 512) : activity.title,
                    "toolName": activity.toolName,
                    "state": state(activity.state),
                ]
                if !compact {
                    item["input"] = activity.input
                    item["output"] = activity.output
                }
                return item
            },
        ]
        if compact {
            result["isPreview"] = message.text.utf8.count > 16 * 1024
                || message.thinking.utf8.count > 4 * 1024
                || message.activities.count > 40
                || message.activities.contains {
                    $0.input != nil || $0.output != nil || $0.title.utf8.count > 512
                }
        }
        if let author = message.author { result["author"] = author }
        return result
    }

    private static func state(_ state: ToolActivityState) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}
