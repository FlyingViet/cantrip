import Foundation

enum RemoteHistory {
    static let pageSize = 30
    static let pageBytes = 192 * 1024

    static func message(_ message: ChatMessage) -> [String: Any] {
        var result: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "text": message.text,
            "thinking": message.thinking,
            "activities": message.activities.map { activity -> [String: Any] in
                var item: [String: Any] = [
                    "id": activity.id,
                    "title": activity.title,
                    "toolName": activity.toolName,
                    "state": state(activity.state),
                ]
                item["input"] = activity.input
                item["output"] = activity.output
                return item
            },
        ]
        if let author = message.author { result["author"] = author }
        // Summaries only; clients fetch each view's payload on demand.
        if !message.apps.isEmpty, AppSettings.shared.copilotMCPApps {
            result["apps"] = message.apps.map { app -> [String: Any] in
                var item: [String: Any] = ["id": app.id, "serverName": app.serverName, "toolName": app.toolName]
                item["title"] = app.title
                item["prefersBorder"] = app.prefersBorder
                return item
            }
        }
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
