import Foundation

struct CopilotJSONStreamParser {
    private var buffer = Data()
    private var lastMessageID: String?
    private var processedEventIDs: Set<String> = []
    private var activities: [String: ToolActivity] = [:]
    /// Subagent instance ID → the task tool call that spawned it.
    private var agentParents: [String: String] = [:]
    /// Nested subagent step → the activity it runs under (not always top-level).
    private var childParents: [String: String] = [:]
    private(set) var answer = ""
    /// Whether reasoning streamed as deltas (skip the aggregate block).
    private var reasoningDeltaSeen = false
    private var streamedMessageIDs: Set<String> = []
    /// MCP tool call → its `tool.execution_start` data, for MCP App views.
    private var mcpCalls: [String: [String: Any]] = [:]
    /// Subagents announced before their task call was tracked, by task call ID.
    private var pendingSubagents: [String: SubagentInfo] = [:]
    /// Whether the session can stop one subagent (SDK `tasks.cancel`).
    private let canCancelSubagents: Bool

    init(canCancelSubagents: Bool = false) {
        self.canCancelSubagents = canCancelSubagents
    }

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
            if let agentID = object["agentId"] as? String,
               let content = (eventData?["content"] as? String).flatMap({ SubagentInfo.clipped($0) }) {
                events += updateSubagent(agentID: agentID) { $0.latestMessage = content }
            }
            for request in requests {
                guard let id = request["toolCallId"] as? String,
                      let name = request["name"] as? String else {
                    continue
                }
                var activity = ToolActivityFactory.start(
                    id: id,
                    toolName: name,
                    arguments: request["arguments"],
                    intentionSummary: request["intentionSummary"] as? String
                )
                activity.subagent = pendingSubagents.removeValue(forKey: id)
                if let parentID {
                    events += nest(activity, under: parentID)
                } else {
                    activities[id] = activity
                    events.append(.activity(activity))
                }
            }
            return events

        case "assistant.usage":
            let input = eventData?["inputTokens"] as? Int ?? 0
            let output = eventData?["outputTokens"] as? Int ?? 0
            var events: [BackendEvent] = [.usage(BackendUsage(
                backend: "copilot", costUSD: 0,
                inputTokens: input,
                outputTokens: output
            ))]
            if let agentID = object["agentId"] as? String {
                events += updateSubagent(agentID: agentID) { $0.tokens += input + output }
            }
            return events

        case "assistant.intent":
            guard let agentID = object["agentId"] as? String,
                  let intent = (eventData?["intent"] as? String).flatMap({ SubagentInfo.clipped($0, limit: 160) })
            else { return [] }
            return updateSubagent(agentID: agentID) { $0.intent = intent }

        case "assistant.turn_start":
            // A waiting multi-turn agent picked up a new message.
            guard let agentID = object["agentId"] as? String else { return [] }
            return updateSubagent(agentID: agentID) { if $0.status == .idle { $0.status = .running } }

        case "session.idle":
            guard let agentID = object["agentId"] as? String else { return [] }
            return updateSubagent(agentID: agentID) { if $0.status == .running { $0.status = .idle } }

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
            var activity = ToolActivityFactory.start(
                id: id,
                toolName: name,
                arguments: eventData?["arguments"]
            )
            activity.subagent = pendingSubagents.removeValue(forKey: id)
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
            if childParents[id] != nil,
               let root = modify(id, { step in
                   step = Self.endingSyncSubagent(ToolActivityFactory.complete(
                       step, id: id, success: success, output: output
                   ))
               }) {
                return [.activity(root)]
            }
            var completed = Self.endingSyncSubagent(ToolActivityFactory.complete(
                activities.removeValue(forKey: id),
                id: id,
                success: success,
                output: output
            ))
            // Only root calls get views; nested subagent calls returned above.
            if let eventData {
                completed.app = MCPAppPayload.copilot(callID: id, start: mcpStart, complete: eventData)
            }
            // A background subagent keeps reporting after its task call returns,
            // and may even announce itself only afterwards.
            if agentParents.values.contains(id) || completed.toolName == "task" {
                activities[id] = completed
            }
            return [.activity(completed)]

        case "subagent.started":
            guard let agentID = object["agentId"] as? String,
                  let callID = eventData?["toolCallId"] as? String else { return [] }
            agentParents[agentID] = callID
            let info = SubagentInfo(
                agentID: agentID,
                name: eventData?["agentDisplayName"] as? String ?? "",
                agentType: (eventData?["agentType"] ?? eventData?["agentName"]) as? String ?? "",
                summary: eventData?["agentDescription"] as? String ?? "",
                model: Self.nonEmpty(eventData?["model"]),
                background: eventData?["executionMode"] as? String == "background",
                startedAt: Self.date(object["timestamp"]) ?? Date(),
                canCancel: canCancelSubagents
            )
            if let events = updateSubagent(callID: callID, { $0 = info }) { return events }
            pendingSubagents[callID] = info
            return []

        case "subagent.configured":
            guard let agentID = object["agentId"] as? String else { return [] }
            return updateSubagent(agentID: agentID) { info in
                info.model = Self.nonEmpty(eventData?["model"]) ?? info.model
                info.effort = Self.nonEmpty(eventData?["reasoningEffort"]) ?? info.effort
            }

        case "subagent.completed", "subagent.failed", Self.cancelledEventType:
            let agentID = object["agentId"] as? String
            guard let callID = (eventData?["toolCallId"] as? String) ?? agentID.flatMap({ agentParents[$0] })
            else { return [] }
            let finishedAt = Self.date(object["timestamp"]) ?? Date()
            let status: SubagentInfo.Status = type == "subagent.failed" ? .failed
                : type == Self.cancelledEventType || eventData?["cancelled"] as? Bool == true ? .cancelled
                : .completed
            return updateSubagent(callID: callID, { info in
                if info.agentID.isEmpty { info.agentID = agentID ?? "" }
                if info.name.isEmpty { info.name = eventData?["agentDisplayName"] as? String ?? "" }
                if info.agentType.isEmpty { info.agentType = eventData?["agentName"] as? String ?? "" }
                // A user-requested stop outranks the runtime's later completion report.
                if info.status != .cancelled { info.status = status }
                if info.finishedAt == nil || info.isActive { info.finishedAt = finishedAt }
                if let duration = eventData?["durationMs"] as? Double, duration >= 0 {
                    info.finishedAt = info.startedAt.addingTimeInterval(duration / 1000)
                }
                info.model = Self.nonEmpty(eventData?["model"]) ?? info.model
                info.tokens = eventData?["totalTokens"] as? Int ?? info.tokens
                info.toolCalls = eventData?["totalToolCalls"] as? Int ?? info.toolCalls
                info.error = (eventData?["error"] as? String).flatMap { SubagentInfo.clipped($0) } ?? info.error
                info.canCancel = false
            }, finishing: status == .completed ? nil : ToolActivityState(status)) ?? []

        default:
            return []
        }
    }

    /// Synthetic event the Cantrip bridge emits once `tasks.cancel` stops an agent.
    static let cancelledEventType = "cantrip.subagent_cancelled"

    /// A sync subagent is over once its task call returns, even without a report.
    private static func endingSyncSubagent(_ activity: ToolActivity) -> ToolActivity {
        guard let info = activity.subagent, info.isActive, !info.background else { return activity }
        var activity = activity
        activity.subagent?.status = activity.state == .failed ? .failed : .completed
        activity.subagent?.finishedAt = Date()
        activity.subagent?.canCancel = false
        return activity
    }

    /// Applies `change` to the subagent the agent ID belongs to and re-emits its root activity.
    private mutating func updateSubagent(
        agentID: String, _ change: (inout SubagentInfo) -> Void
    ) -> [BackendEvent] {
        guard let callID = agentParents[agentID] else { return [] }
        return updateSubagent(callID: callID, { info in change(&info) }) ?? []
    }

    /// Nil when the task call isn't tracked. `finishing` also ends the agent's unfinished steps.
    private mutating func updateSubagent(
        callID: String, _ change: (inout SubagentInfo) -> Void,
        finishing state: ToolActivityState? = nil
    ) -> [BackendEvent]? {
        if path(to: callID) == nil {
            guard pendingSubagents[callID] != nil else { return nil }
            change(&pendingSubagents[callID]!)
            return []
        }
        var changed = false
        let pending = pendingSubagents.removeValue(forKey: callID)
        let root = modify(callID) { activity in
            var info = activity.subagent ?? pending
                ?? SubagentInfo(agentID: "", name: "", agentType: "", summary: "")
            let before = activity
            change(&info)
            activity.subagent = info
            if let state {
                let date = info.finishedAt ?? Date()
                activity.children = activity.children.map { $0.finishing(as: state, at: date) }
            }
            changed = activity != before
        }
        guard let root, changed else { return [] }
        return [.activity(root)]
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Root-first chain of tracked activity IDs ending at `id`.
    private func path(to id: String) -> [String]? {
        var chain = [id]
        var current = id
        while activities[current] == nil {
            guard let parent = childParents[current], chain.count < 32 else { return nil }
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// Mutates a tracked activity at any depth; returns its updated root.
    private mutating func modify(_ id: String, _ change: (inout ToolActivity) -> Void) -> ToolActivity? {
        guard let chain = path(to: id), var root = activities[chain[0]] else { return nil }
        func descend(_ activity: inout ToolActivity, _ rest: ArraySlice<String>) -> Bool {
            guard let next = rest.first else {
                change(&activity)
                return true
            }
            guard let index = activity.children.firstIndex(where: { $0.id == next }) else { return false }
            return descend(&activity.children[index], rest.dropFirst())
        }
        guard descend(&root, chain.dropFirst()) else { return nil }
        activities[chain[0]] = root
        return root
    }

    /// The tracked task call a subagent event belongs to (its own agent's, at any depth).
    private func subagentParent(_ object: [String: Any], _ data: [String: Any]?) -> String? {
        let agentID = object["agentId"] as? String
        guard let direct = agentID.flatMap({ agentParents[$0] })
                ?? data?["parentToolCallId"] as? String else {
            return nil
        }
        return path(to: direct) == nil ? nil : direct
    }

    private mutating func nest(_ activity: ToolActivity, under parentID: String) -> [BackendEvent] {
        let root = modify(parentID) { parent in
            if let index = parent.children.firstIndex(where: { $0.id == activity.id }) {
                parent.children[index] = activity
            } else {
                parent.children.append(activity)
            }
        }
        guard let root else { return [] }
        childParents[activity.id] = parentID
        return [.activity(root)]
    }

    static func tokenLabel(_ tokens: Int) -> String { SubagentInfo.tokenLabel(tokens) }
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
