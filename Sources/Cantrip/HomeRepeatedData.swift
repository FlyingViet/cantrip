import Foundation

/// Attended Cantrip Home on Copilot, which keeps one conversation: a data section identical to the
/// copy already in that conversation goes as a one-line note instead of again, so the same few
/// thousand tokens stop piling up in its history. Nothing is lost: the earlier copy is still in
/// the model's context, and the note says where to read it fresh. Starts over whenever the
/// conversation may no longer hold that copy: a different backend session, a drop in context
/// size (compaction), or every `refreshMessages` messages.
struct HomeRepeatedData {
    struct Section: Equatable {
        var name: String
        /// Exactly as it appears in the message.
        var text: String
        /// What replaces it when unchanged.
        var note: String
    }

    static let refreshMessages = 20
    /// Where Home's per-message data starts; sections are only looked for after it.
    static let dataMarker = "(CANTRIP HOME — data for this message"

    private(set) var conversation: String?
    private var sent: [String: String] = [:]
    private var messages = 0
    private var contextTokens = 0

    /// The message to send: unchanged sections become their notes. Also returns the characters saved.
    mutating func compact(_ message: String, sections: [Section]) -> (message: String, saved: Int) {
        guard let data = message.range(of: Self.dataMarker) else { return (message, 0) }
        messages += 1
        if messages > Self.refreshMessages { sent = [:]; messages = 1 }
        var result = message
        var saved = 0
        let start = result.distance(from: result.startIndex, to: data.lowerBound)
        for section in sections where !section.text.isEmpty {
            let from = result.index(result.startIndex, offsetBy: start)
            guard let range = result.range(of: section.text, range: from..<result.endIndex) else { continue }
            if conversation != nil, sent[section.name] == section.text, section.text.count > section.note.count {
                result.replaceSubrange(range, with: section.note)
                saved += section.text.count - section.note.count
            } else {
                sent[section.name] = section.text
            }
        }
        return (result, saved)
    }

    /// The backend reported the session this message ran in; a different one hasn't seen the copies.
    mutating func observe(session: String) {
        guard session != conversation else { return }
        if conversation != nil { reset() }
        conversation = session
    }

    /// Context size for a model call; a sharp drop means the history was compacted.
    mutating func observe(contextTokens tokens: Int) {
        if tokens < contextTokens * 7 / 10 { reset(keepingConversation: true) }
        contextTokens = tokens
    }

    mutating func reset(keepingConversation: Bool = false) {
        let current = conversation
        self = HomeRepeatedData()
        if keepingConversation { conversation = current }
    }

    // MARK: Home chat's sections

    /// The memory block's stable part: core files, notes list and sessions pointer (the snippets
    /// matched to this message and the closing rule stay).
    static func memory(in message: String, vault: String) -> Section? {
        guard let start = message.range(of: "\n\n(Persistent memory — three layers") else { return nil }
        let ends = ["\n\nRETRIEVED — ", "\n\nMaintain memory silently", "\n\nPRIVATE MODE"]
        guard let end = ends.compactMap({ message.range(of: $0, range: start.upperBound..<message.endIndex)?.lowerBound }).min()
        else { return nil }
        return Section(name: "memory", text: String(message[start.lowerBound..<end]), note: """


            (Persistent memory — three layers, all in \(vault): CORE, NOTES and SESSIONS are unchanged \
            since an earlier message in this conversation; re-read MEMORY.md, USER.md or a note there if \
            you no longer have them.
            """)
    }

    static func tasks(_ index: String, file: String) -> Section {
        Section(name: "tasks", text: index,
                note: "- unchanged since an earlier message in this conversation (saved in \(file))")
    }

    static func tabs(_ data: String) -> Section {
        Section(name: "tabs", text: data,
                note: "Open project tabs, tab sections and recent handoffs: unchanged since an earlier message in this conversation (`tab list` shows them now).")
    }

    static func background(_ data: String) -> Section {
        Section(name: "background", text: data,
                note: "Recent background runs: unchanged since an earlier message in this conversation.")
    }
}
