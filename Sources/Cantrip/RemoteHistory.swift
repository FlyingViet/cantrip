import Foundation

enum RemoteHistory {
    static let pageSize = 30
    static let pageBytes = 192 * 1024
    /// With step summaries, a step whose input and output together are larger than this sends
    /// neither: the client loads them (`step`) when the step is opened.
    static let inlineStepBytes = 1_024
    static let summaryTitleBytes = 512

    /// `live`: the tab is still writing this reply (see `ChatMessage.workSplit`). `stepSummaries`:
    /// the client asked for `steps=summary`, so large steps carry `detailBytes` instead of their
    /// input and output. A busy tab's last turns hold hundreds of steps (0.5–1 MB of commands and
    /// their output) that a phone shows only once a step is opened; on a slow link they kept the
    /// conversation from loading at all.
    static func message(_ message: ChatMessage, live: Bool = false, stepSummaries: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            "id": message.id.uuidString,
            // A child tab's card reads as a reply to clients that don't draw it.
            "role": message.childResult != nil ? "assistant" : message.role.rawValue,
            "text": TabMentions.stripConversationLinks(message.text),
            "thinking": message.thinking,
            "activities": message.activities.map { activity -> [String: Any] in
                stepSummaries ? summary(activity) : step(activity)
            },
        ]
        if let author = message.author { result["author"] = author }
        if let thread = message.threadID { result["threadID"] = thread.uuidString }
        if message.role == .user, let usage = message.promptUsage, !usage.isEmpty {
            result["promptUsage"] = usage.snapshot
        }
        if let privacy = message.privacy {
            result["privacy"] = ["route": privacy.route, "mode": privacy.mode, "applied": privacy.applied,
                                 "label": privacy.label, "detail": privacy.detail]
        }
        if !message.delegations.isEmpty {
            result["delegations"] = message.delegations.map(\.snapshot)
        }
        if let handoff = message.handoffResult { result["handoffResult"] = handoff.snapshot }
        // Progress notes vs. the answer: clients fold the first `noteBlocks` markdown blocks.
        if let work = message.workSplit(live: live) { result["work"] = work.snapshot }
        if let child = message.childResult { result["childResult"] = child.snapshot }
        if let muse = message.muse {
            // `@muse` exchange: role handoff, author Muse; `text` is what to show.
            var exchange: [String: Any] = ["state": muse.state.rawValue, "chat": muse.chat]
            exchange["findings"] = muse.findings
            result["muse"] = exchange
        }
        // Home's Muse request card: the exact text, its state and the actions open now.
        if let card = message.museRequest { result["museRequest"] = card.snapshot }
        let reasoning = ReasoningStep.steps(from: message.reasoningBlocks)
        if !reasoning.isEmpty {
            result["reasoning"] = reasoning.enumerated().map { $1.snapshot(number: $0 + 1) }
        }
        var subagents = message.activities.flatMap(\.subagentActivities)
        if subagents.isEmpty, message.role == .assistant {
            subagents = AntigravitySubagentTranscript.reconstructedActivities(fromText: message.text)
        }
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
        if !message.linkPreviews.isEmpty, AppSettings.shared.linkPreviewsEnabled {
            let previews = message.visibleLinkPreviews
            if !previews.isEmpty { result["linkPreviews"] = previews.map(\.snapshot) }
        }
        if let placeCard = message.placeCard {
            result["placeCard"] = placeCard.snapshot
        }
        if let weatherCard = message.weatherCard {
            result["weatherCard"] = weatherCard.snapshot
        }
        // Every card as generic blocks (`cards`); the keys above stay for clients from before them.
        let cards = message.cardDocuments(linkPreviews: AppSettings.shared.linkPreviewsEnabled)
        if !cards.isEmpty { result["cards"] = cards.map(\.snapshot) }
        return result
    }

    /// Monitor summary; contract shared with the web UI and Cantrip Agent.
    /// `textBlock`: a finished card follows that many reply blocks (see ReplyBlocks).
    static func subagent(_ activity: ToolActivity, textBlock: Int? = nil) -> [String: Any]? {
        let activity = AntigravitySubagentTranscript.enriched(activity)
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

    /// A step with its full title, input and output (`GET …/messages/<id>/steps/<step>`).
    static func step(_ activity: ToolActivity) -> [String: Any] {
        var item: [String: Any] = [
            "id": activity.id,
            "title": activity.title,
            "toolName": activity.toolName,
            "state": state(activity.state),
        ]
        item["input"] = activity.input
        item["output"] = activity.output
        if BrowserPreview.isBrowserTool(activity.toolName) { item["browser"] = true }
        return item
    }

    /// A step for a client that loads details on request: small steps whole, large ones with a bounded
    /// title and `detailBytes` (title, input and output sizes) in place of their input and output.
    static func summary(_ activity: ToolActivity) -> [String: Any] {
        let bytes = activity.title.utf8.count + (activity.input?.utf8.count ?? 0) + (activity.output?.utf8.count ?? 0)
        guard bytes > inlineStepBytes || activity.title.utf8.count > summaryTitleBytes else { return step(activity) }
        var item = step(activity)
        item["input"] = nil
        item["output"] = nil
        item["title"] = preview(activity.title, bytes: summaryTitleBytes)
        item["detailBytes"] = bytes
        return item
    }

    static func preview(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while end.samePosition(in: text.unicodeScalars) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
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

extension ChatSession {
    /// How many recent messages are searched for running background agents: an agent a turn
    /// started keeps running through the next few turns, never across dozens.
    static let backgroundAgentWindow = 40

    /// The reply the tab is still writing, if it's running.
    var liveReplyID: UUID? {
        isStreaming ? messages.last(where: { $0.role == .assistant })?.id : nil
    }

    /// Background agents still running in this tab (watchers, `side-` requests…), oldest first.
    var liveBackgroundAgents: [ToolActivity] {
        messages.suffix(Self.backgroundAgentWindow).flatMap(\.activities).flatMap(\.subagentActivities)
            .filter { $0.subagent?.background == true && $0.subagent?.isActive == true }
    }
}
