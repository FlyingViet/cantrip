import Foundation

struct CopilotJSONStreamParser {
    private var buffer = Data()
    private var lastMessageID: String?
    private var processedEventIDs: Set<String> = []
    private var activities: [String: ToolActivity] = [:]
    /// Subagent instance ID → the task tool call that spawned it.
    private var agentParents: [String: String] = [:]
    /// Nested subagent step → its top-level activity.
    private var childParents: [String: String] = [:]
    private(set) var answer = ""
    /// Whether reasoning streamed as deltas (skip the aggregate block).
    private var reasoningDeltaSeen = false
    private var streamedMessageIDs: Set<String> = []
    /// MCP tool call → its `tool.execution_start` data, for MCP App views.
    private var mcpCalls: [String: [String: Any]] = [:]

    mutating func consume(
        _ data: Data,
        onMalformedLine: (CopilotJSONStreamParserError, Data) -> Void
    ) -> [BackendEvent] {
        buffer.append(data)
        var events: [BackendEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let afterNewline = buffer.index(after: newline)
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex..<afterNewline)
            events += parseRecovering(line, onMalformedLine: onMalformedLine)
        }

        return events
    }

    mutating func finish(
        onMalformedLine: (CopilotJSONStreamParserError, Data) -> Void
    ) -> [BackendEvent] {
        guard !buffer.isEmpty else { return [] }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return parseRecovering(line, onMalformedLine: onMalformedLine)
    }

    private mutating func parseRecovering(
        _ line: Data,
        onMalformedLine: (CopilotJSONStreamParserError, Data) -> Void
    ) -> [BackendEvent] {
        do {
            return try parseLine(line)
        } catch let error as CopilotJSONStreamParserError {
            onMalformedLine(error, line)
        } catch {
            onMalformedLine(.invalidEvent(error), line)
        }
        return []
    }

    private mutating func parseLine(_ data: Data) throws -> [BackendEvent] {
        var line = data
        if line.last == 0x0D {
            line.removeLast()
        }
        guard !line.isEmpty else { return [] }

        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CopilotJSONStreamParserError.missingEventType
            }
            object = parsed
        } catch {
            if let parserError = error as? CopilotJSONStreamParserError {
                throw parserError
            }
            throw CopilotJSONStreamParserError.invalidEvent(error)
        }

        guard let type = object["type"] as? String else {
            throw CopilotJSONStreamParserError.missingEventType
        }
        if let eventID = object["id"] as? String,
           !processedEventIDs.insert(eventID).inserted {
            return []
        }
        let eventData = object["data"] as? [String: Any]

        switch type {
        case "assistant.message_delta":
            // Delegated agents share the parent's JSONL stream. Their text is
            // surfaced through the task activity and must not be appended to
            // the root assistant response.
            guard object["agentId"] as? String == nil,
                  eventData?["parentToolCallId"] as? String == nil else {
                return []
            }
            guard let messageID = eventData?["messageId"] as? String,
                  let content = eventData?["deltaContent"] as? String else {
                throw CopilotJSONStreamParserError.missingDeltaFields
            }
            guard !content.isEmpty else { return [] }

            let separator = !answer.isEmpty && lastMessageID != messageID ? "\n\n" : ""
            let delta = separator + content
            answer += delta
            lastMessageID = messageID
            streamedMessageIDs.insert(messageID)
            return [.textDelta(delta)]

        case "assistant.reasoning_delta", "assistant.reasoning":
            // Reasoning-model thinking. Documented event types, but the
            // data schema isn't formalized (github/copilot-cli#3551) and
            // emission is provider-dependent — parse leniently and never
            // throw; a missing event just means no reasoning display.
            guard object["agentId"] as? String == nil,
                  eventData?["parentToolCallId"] as? String == nil else {
                return []
            }
            let text = (eventData?["deltaContent"] ?? eventData?["content"]
                ?? eventData?["delta"] ?? eventData?["text"]) as? String ?? ""
            guard !text.isEmpty else { return [] }
            if type == "assistant.reasoning_delta" {
                reasoningDeltaSeen = true
                return [.thinkingDelta(text)]
            }
            // Aggregate block — only useful if deltas never streamed.
            return reasoningDeltaSeen ? [] : [.thinkingDelta(text)]

        case "assistant.message":
            var events: [BackendEvent] = []
            if object["agentId"] as? String == nil,
               eventData?["parentToolCallId"] as? String == nil,
               let messageID = eventData?["messageId"] as? String,
               !streamedMessageIDs.contains(messageID),
               let content = eventData?["content"] as? String, !content.isEmpty {
                let delta = (!answer.isEmpty && lastMessageID != messageID ? "\n\n" : "") + content
                answer += delta
                lastMessageID = messageID
                streamedMessageIDs.insert(messageID)
                events.append(.textDelta(delta))
            }
            let requests = eventData?["toolRequests"] as? [[String: Any]] ?? []
            let parentID = subagentParent(object, eventData)
            for request in requests {
                guard let id = request["toolCallId"] as? String,
                      let name = request["name"] as? String else {
                    continue
                }
                let activity = ToolActivityFactory.start(
                    id: id,
                    toolName: name,
                    arguments: request["arguments"],
                    intentionSummary: request["intentionSummary"] as? String
                )
                if let parentID {
                    events += nest(activity, under: parentID)
                } else {
                    activities[id] = activity
                    events.append(.activity(activity))
                }
            }
            return events

        case "assistant.usage":
            return [.usage(BackendUsage(
                backend: "copilot", costUSD: 0,
                inputTokens: eventData?["inputTokens"] as? Int ?? 0,
                outputTokens: eventData?["outputTokens"] as? Int ?? 0
            ))]

        case "tool.execution_start":
            guard let id = eventData?["toolCallId"] as? String,
                  let name = eventData?["toolName"] as? String else {
                return []
            }
            if let eventData, eventData["mcpServerName"] is String {
                mcpCalls[id] = eventData
            }
            if activities[id] != nil || childParents[id] != nil {
                return []
            }
            let activity = ToolActivityFactory.start(
                id: id,
                toolName: name,
                arguments: eventData?["arguments"]
            )
            if let parentID = subagentParent(object, eventData) {
                return nest(activity, under: parentID)
            }
            activities[id] = activity
            return [.activity(activity)]

        case "tool.execution_complete":
            guard let id = eventData?["toolCallId"] as? String else {
                return []
            }
            let result = eventData?["result"] as? [String: Any]
            let output: Any?
            if let detailedContent = result?["detailedContent"] {
                output = detailedContent
            } else if let content = result?["content"] {
                output = content
            } else {
                output = result
            }
            let success = eventData?["success"] as? Bool ?? false
            let mcpStart = mcpCalls.removeValue(forKey: id)
            if let parentID = childParents[id], var parent = activities[parentID],
               let index = parent.children.firstIndex(where: { $0.id == id }) {
                parent.children[index] = ToolActivityFactory.complete(
                    parent.children[index], id: id, success: success, output: output
                )
                activities[parentID] = parent
                return [.activity(parent)]
            }
            var completed = ToolActivityFactory.complete(
                activities.removeValue(forKey: id),
                id: id,
                success: success,
                output: output
            )
            // Only root calls get views; nested subagent calls returned above.
            if let eventData {
                completed.app = MCPAppPayload.copilot(callID: id, start: mcpStart, complete: eventData)
            }
            // A background subagent keeps reporting after its task call returns.
            if agentParents.values.contains(id) {
                activities[id] = completed
            }
            return [.activity(completed)]

        case "subagent.started":
            if let agentID = object["agentId"] as? String,
               let callID = eventData?["toolCallId"] as? String {
                agentParents[agentID] = callID
            }
            return []

        case "subagent.completed", "subagent.failed":
            guard let callID = eventData?["toolCallId"] as? String else { return [] }
            let details = [eventData?["model"] as? String,
                           (eventData?["totalTokens"] as? Int).map(Self.tokenLabel)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            guard !details.isEmpty else { return [] }
            let suffix = " · " + details.joined(separator: " · ")
            if var activity = activities[callID] {
                activity.title += suffix
                activities[callID] = activity
                return [.activity(activity)]
            }
            if let parentID = childParents[callID], var parent = activities[parentID],
               let index = parent.children.firstIndex(where: { $0.id == callID }) {
                parent.children[index].title += suffix
                activities[parentID] = parent
                return [.activity(parent)]
            }
            return []

        default:
            return []
        }
    }

    /// The top-level activity a subagent event belongs to, if it is still tracked.
    private func subagentParent(_ object: [String: Any], _ data: [String: Any]?) -> String? {
        let agentID = object["agentId"] as? String
        guard let direct = agentID.flatMap({ agentParents[$0] })
                ?? data?["parentToolCallId"] as? String else {
            return nil
        }
        let root = childParents[direct] ?? direct
        return activities[root] != nil ? root : nil
    }

    private mutating func nest(_ activity: ToolActivity, under parentID: String) -> [BackendEvent] {
        guard var parent = activities[parentID] else { return [] }
        if let index = parent.children.firstIndex(where: { $0.id == activity.id }) {
            parent.children[index] = activity
        } else {
            parent.children.append(activity)
        }
        childParents[activity.id] = parentID
        activities[parentID] = parent
        return [.activity(parent)]
    }

    static func tokenLabel(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens) tokens"
        case ..<1_000_000: return String(format: "%.1fk tokens", Double(tokens) / 1_000)
        default: return String(format: "%.1fM tokens", Double(tokens) / 1_000_000)
        }
    }
}

enum CopilotJSONStreamParserError: LocalizedError {
    case invalidEvent(Error)
    case missingEventType
    case missingDeltaFields

    var errorDescription: String? {
        switch self {
        case .invalidEvent(let error):
            return "Invalid JSONL event (\(error.localizedDescription))"
        case .missingEventType:
            return "JSONL event is missing its type"
        case .missingDeltaFields:
            return "Assistant delta is missing its message ID or content"
        }
    }
}
