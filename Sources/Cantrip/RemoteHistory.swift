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
        if message.role == .user, let usage = message.promptUsage, !usage.isEmpty {
            result["promptUsage"] = usage.snapshot
        }
        if !message.delegations.isEmpty {
            result["delegations"] = message.delegations.map(\.snapshot)
        }
        let reasoning = ReasoningStep.steps(from: message.reasoningBlocks)
        if !reasoning.isEmpty {
            result["reasoning"] = reasoning.enumerated().map { $1.snapshot(number: $0 + 1) }
        }
        let subagents = message.activities.flatMap(\.subagentActivities)
        if !subagents.isEmpty {
            result["subagents"] = subagents.compactMap { activity in
                subagent(activity, textBlock: activity.subagent?.isActive == false
                         ? message.subagentTextBlock(activity.id) : nil)
            }
        }
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

    /// Monitor summary; contract shared with the web UI and Cantrip Agent.
    /// `textBlock`: a finished card follows that many reply blocks (see ReplyBlocks).
    static func subagent(_ activity: ToolActivity, textBlock: Int? = nil) -> [String: Any]? {
        guard let info = activity.subagent else { return nil }
        let current = activity.children.last(where: { $0.state == .running }) ?? activity.children.last
        var item: [String: Any] = [
            "id": activity.id, "agentID": info.agentID, "name": info.name,
            "agentType": info.agentType, "summary": info.summary, "background": info.background,
            "status": info.status.rawValue, "startedAt": info.startedAt.timeIntervalSince1970,
            "steps": info.toolCalls ?? activity.children.count, "tokens": info.tokens,
            "canCancel": info.canCancel && info.isActive,
            "recentSteps": activity.children.suffix(6).map { step in
                ["title": step.title, "toolName": step.toolName, "state": state(step.state)]
            },
        ]
        item["model"] = info.model
        item["effort"] = info.effort
        item["finishedAt"] = info.finishedAt?.timeIntervalSince1970
        item["intent"] = info.intent
        item["currentStep"] = current?.title
        item["latestMessage"] = info.latestMessage
        item["error"] = info.error
        item["textBlock"] = textBlock
        let reasoning = ReasoningStep.steps(from: info.reasoning)
        if !reasoning.isEmpty {
            item["reasoning"] = reasoning.indices.suffix(8).map {
                reasoning[$0].snapshot(number: info.reasoningStepOffset + $0 + 1)
            }
        }
        return item
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
