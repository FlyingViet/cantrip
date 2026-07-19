import Foundation

struct CopilotJSONStreamParser {
    private var buffer = Data()
    private var lastMessageID: String?
    private var processedEventIDs: Set<String> = []
    private var activities: [String: ToolActivity] = [:]
    private(set) var answer = ""

    mutating func consume(_ data: Data) throws -> [BackendEvent] {
        buffer.append(data)
        var events: [BackendEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let afterNewline = buffer.index(after: newline)
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex..<afterNewline)
            events += try parseLine(line)
        }

        return events
    }

    mutating func finish() throws -> [BackendEvent] {
        guard !buffer.isEmpty else { return [] }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return try parseLine(line)
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
            return [.textDelta(delta)]

        case "assistant.message":
            guard let requests = eventData?["toolRequests"] as? [[String: Any]] else {
                return []
            }
            return requests.compactMap { request in
                guard let id = request["toolCallId"] as? String,
                      let name = request["name"] as? String else {
                    return nil
                }
                let activity = ToolActivityFactory.start(
                    id: id,
                    toolName: name,
                    arguments: request["arguments"],
                    intentionSummary: request["intentionSummary"] as? String
                )
                activities[id] = activity
                return .activity(activity)
            }

        case "tool.execution_start":
            guard let id = eventData?["toolCallId"] as? String,
                  let name = eventData?["toolName"] as? String else {
                return []
            }
            if activities[id] != nil {
                return []
            }
            let activity = ToolActivityFactory.start(
                id: id,
                toolName: name,
                arguments: eventData?["arguments"]
            )
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
            let completed = ToolActivityFactory.complete(
                activities.removeValue(forKey: id),
                id: id,
                success: eventData?["success"] as? Bool ?? false,
                output: output
            )
            return [.activity(completed)]

        default:
            return []
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
