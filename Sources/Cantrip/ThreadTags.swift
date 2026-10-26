import Foundation

/// Thread tags (Cantrip Home). Every message records the prompt that started its thread
/// (`ChatMessage.threadID`); a reply that belongs to a different thread from the message just
/// above it shows a tag naming that prompt, and the tag expands to the thread so far.
enum ThreadTags {
    static let excerptLimit = 120
    static let messageLimit = 30
    /// Each message in a thread; the thread view shows them whole, as Messages does.
    static let textLimit = 4000
    static let promptLimit = 4000

    /// Only Home shows tags; other tabs record the links without any visual change.
    static func showsTags(sessionID: UUID) -> Bool { sessionID == ChatSession.cantripHomeID }

    /// Whether a message counts as "the message just above": an empty reply bubble isn't drawn.
    static func isShown(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return true }
        return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.delegations.isEmpty || !message.activities.isEmpty
    }

    /// The tag for each message in `range` that needs one, by message ID:
    /// `["id": thread ID, "prompt": the start of the prompt that started the thread]`.
    static func tags(in messages: [ChatMessage], range: Range<Int>, sessionID: UUID) -> [UUID: [String: Any]] {
        guard showsTags(sessionID: sessionID) else { return [:] }
        let range = range.clamped(to: messages.indices)
        var result: [UUID: [String: Any]] = [:]
        var prompts: [UUID: String]?
        for index in range {
            let message = messages[index]
            guard message.role != .user, message.role != .freshStart, isShown(message),
                  let thread = message.threadID else { continue }
            let above = messages[..<index].last(where: isShown)
            guard above?.threadID != thread else { continue }
            if prompts == nil {
                prompts = Dictionary(messages.lazy.filter { $0.role == .user }.map { ($0.id, $0.text) },
                                     uniquingKeysWith: { first, _ in first })
            }
            guard let prompt = prompts?[thread] else { continue }
            let excerpt = excerpt(of: promptText(prompt, sessionID: sessionID))
            guard !excerpt.isEmpty else { continue }
            result[message.id] = ["id": thread.uuidString, "prompt": excerpt]
        }
        return result
    }

    /// "N Replies" under a prompt whose thread other messages split up (at least one of its
    /// replies carries a tag), by prompt ID: every later message in the thread counts, as in
    /// Messages. Covers the whole history, so clients can update prompts in pages they cached.
    static func replyCounts(in messages: [ChatMessage], sessionID: UUID) -> [UUID: Int] {
        guard showsTags(sessionID: sessionID) else { return [:] }
        var prompts: Set<UUID> = []
        var counts: [UUID: Int] = [:]
        var split: Set<UUID> = []
        var above: ChatMessage?
        for message in messages where isShown(message) {
            defer { above = message }
            if message.role == .user, message.threadID == message.id { prompts.insert(message.id) }
            guard let thread = message.threadID, thread != message.id, prompts.contains(thread),
                  message.role != .freshStart else { continue }
            counts[thread, default: 0] += 1
            if message.role != .user, above?.threadID != thread { split.insert(thread) }
        }
        return counts.filter { split.contains($0.key) }
    }

    /// `replyCounts` as JSON (`{promptID: count}`).
    static func replyCountsObject(in messages: [ChatMessage], sessionID: UUID) -> [String: Int]? {
        guard showsTags(sessionID: sessionID) else { return nil }
        return Dictionary(uniqueKeysWithValues: replyCounts(in: messages, sessionID: sessionID)
            .map { ($0.key.uuidString, $0.value) })
    }

    /// A prompt as the user sees it (attached images become their captions).
    static func promptText(_ text: String, sessionID: UUID) -> String {
        let presentation = RemoteImageAttachments.presentation(text, sessionID: sessionID)
        return TabMentions.plain(presentation.replacesText ? presentation.text : text)
    }

    /// The start of a prompt on one line.
    static func excerpt(of text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > excerptLimit else { return line }
        return String(line.prefix(excerptLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A question Pip asked is saved as "Copilot needs your answer", a blank line, then the
    /// question; the thread shows just the question.
    static func withoutQuestionTitle(_ text: String) -> String {
        guard let range = text.range(of: #"^[^\n]{1,40} needs your answer\n\n"#, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    /// The thread a tag opens: its prompt and every earlier message in it, before `before`
    /// (the tagged message). Unrelated messages are skipped. Nil when the prompt is gone.
    static func thread(_ thread: UUID, in messages: [ChatMessage], before: UUID?, sessionID: UUID,
                       visibleText: (ChatMessage) -> String) -> [String: Any]? {
        guard let prompt = messages.first(where: { $0.id == thread && $0.role == .user }) else { return nil }
        let end = before.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.endIndex
        let related = messages[..<end].filter { message in
            message.threadID == thread && message.id != thread && message.role != .freshStart
        }
        var items: [[String: Any]] = []
        for message in related {
            let text = message.role == .user ? promptText(message.text, sessionID: sessionID)
                : withoutQuestionTitle(visibleText(message))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var item: [String: Any] = [
                "id": message.id.uuidString,
                "role": message.role.rawValue,
                "text": trimmed.count > textLimit ? String(trimmed.prefix(textLimit)) + "…" : trimmed,
            ]
            item["author"] = message.author
            items.append(item)
        }
        let promptText = promptText(prompt.text, sessionID: sessionID)
        return [
            "id": thread.uuidString,
            "prompt": [
                "id": prompt.id.uuidString,
                "text": promptText.count > promptLimit ? String(promptText.prefix(promptLimit)) + "…" : promptText,
            ],
            "messages": Array(items.suffix(messageLimit)),
            "hasEarlier": items.count > messageLimit,
        ]
    }
}
