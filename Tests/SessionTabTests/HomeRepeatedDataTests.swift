import Foundation

extension SessionTabTests {
    /// Attended Home on Copilot: data the conversation already holds goes as a short note, and
    /// everything starts over when the conversation may have lost it.
    @MainActor
    static func testHomeRepeatedData() throws {
        let memoryHead = "\n\n(Persistent memory — three layers, all in /tmp/vault:\n\nCORE — always loaded:\n# MEMORY — example\n"
            + String(repeating: "- Example convention about a synthetic machine.\n", count: 20)
            + "\n\nNOTES — procedures: example.md\n\nSESSIONS — logs in /tmp/vault/sessions/."
        let taskLines = "- 1111: Example task\n" + (2...12).map { "- \($0)\($0)\($0): Example task \($0) · daily 8:00" }.joined(separator: "\n")
        let tabLines = "Open project tabs:\n" + (1...12).map { "- Example project \($0) · idle · /tmp/example-\($0)" }.joined(separator: "\n")
        let runs = "Recent background runs:\n" + (1...6).map { "- Example check \($0): finished, nothing new" }.joined(separator: "\n")
        func message(_ text: String, tasks: String = taskLines, tabs: String = tabLines,
                     retrieved: String = "RETRIEVED — example snippet") -> String {
            text + "\n\n" + HomeRepeatedData.dataMarker + "; data.\nExisting tasks:\n" + tasks + "\n" + tabs
                + "\n" + runs + ")" + memoryHead + "\n\n" + retrieved
                + "\n\nMaintain memory silently as you work.)"
        }
        func sections(_ text: String, tasks: String = taskLines, tabs: String = tabLines)
            -> [HomeRepeatedData.Section] {
            [try! requireHome(HomeRepeatedData.memory(in: text, vault: "/tmp/vault")),
             HomeRepeatedData.tasks(tasks, file: "/tmp/tasks.json"), HomeRepeatedData.tabs(tabs),
             HomeRepeatedData.background(runs)]
        }

        let first = message("Hello")
        let memory = try requireHome(HomeRepeatedData.memory(in: first, vault: "/tmp/vault"))
        precondition(memory.text == memoryHead, memory.text)
        precondition(HomeRepeatedData.memory(in: "No memory.", vault: "/tmp/vault") == nil)

        // The first message goes whole; before the backend names its session nothing is shortened.
        var data = HomeRepeatedData()
        func untouched(_ result: (message: String, saved: Int), _ original: String) -> Bool {
            result.message == original && result.saved == 0
        }
        precondition(untouched(data.compact(first, sections: sections(first)), first))
        let second = message("Next")
        precondition(untouched(data.compact(second, sections: sections(second)), second), "no known conversation yet")
        data.observe(session: "session-a")

        // The same conversation: unchanged sections become notes; the snippets and closing rule stay.
        let third = message("Third")
        let short = data.compact(third, sections: sections(third))
        precondition(short.saved > 0 && short.message.count < third.count && short.message.hasPrefix("Third"))
        precondition(!short.message.contains("# MEMORY — example") && short.message.contains("RETRIEVED — example snippet")
                     && short.message.contains("Maintain memory silently") && short.message.contains("re-read MEMORY.md")
                     && short.message.contains("(saved in /tmp/tasks.json)") && short.message.contains("`tab list` shows them now")
                     && !short.message.contains("- 1111: Example task"), short.message)
        precondition(short.message.contains("Existing tasks:\n- unchanged since an earlier message"), "a note keeps its label")

        // A changed section goes whole (and becomes the copy to compare with); the rest stay notes.
        let changed = message("Fourth", tasks: "- 2222: Another example task")
        let partly = data.compact(changed, sections: sections(changed, tasks: "- 2222: Another example task"))
        precondition(partly.message.contains("- 2222: Another example task") && !partly.message.contains("# MEMORY — example"))

        // Text before Home's data (the user's own message) is never touched.
        let quoted = message("Hello " + taskLines)
        let kept = data.compact(quoted, sections: sections(quoted))
        precondition(kept.message.hasPrefix("Hello " + taskLines + "\n\n"), kept.message)

        // Compaction (a sharp drop in context) and a different session start over.
        data.observe(contextTokens: 400_000)
        data.observe(contextTokens: 420_000)
        precondition(data.compact(third, sections: sections(third)).saved > 0, "growing context keeps the copies")
        data.observe(contextTokens: 45_000)
        precondition(data.compact(third, sections: sections(third)).saved == 0, "after compaction everything goes whole")
        precondition(data.compact(third, sections: sections(third)).saved > 0 && data.conversation == "session-a")
        data.observe(session: "session-b")
        precondition(data.compact(third, sections: sections(third)).saved == 0, "a new session gets everything")

        // Every refreshMessages messages it all goes again, even in one conversation.
        var refreshed = HomeRepeatedData()
        refreshed.observe(session: "session-c")
        let saved = (1...(HomeRepeatedData.refreshMessages + 1)).map { _ in refreshed.compact(third, sections: sections(third)).saved }
        precondition(saved.first == 0 && saved.dropFirst().dropLast().allSatisfy { $0 > 0 } && saved.last == 0, "\(saved)")

        // A section shorter than its note always goes whole.
        var tiny = HomeRepeatedData()
        tiny.observe(session: "session-d")
        let small = [HomeRepeatedData.background("Recent background runs:")]
        precondition(third.contains("Recent background runs:"))
        _ = tiny.compact(third, sections: small)
        precondition(tiny.compact(third, sections: small).saved == 0, "a note never makes a message longer")

        // A message without Home's data (a slash command, council) is sent as is and doesn't count.
        var plain = HomeRepeatedData()
        precondition(untouched(plain.compact("/model", sections: sections(first)), "/model"))

        // Home's real per-turn data: every section it reports is in the text it builds.
        let home = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                               makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        defer { home.cancel() }
        let context = home.cantripHomeChatTurnContext(query: "example")
        let marker = try requireHome(context.range(of: HomeRepeatedData.dataMarker))
        precondition(home.homeDataSections.map(\.name) == ["tasks", "tabs", "background"], "\(home.homeDataSections.map(\.name))")
        for section in home.homeDataSections where !section.text.isEmpty {
            precondition(context.range(of: section.text, range: marker.upperBound..<context.endIndex) != nil, section.name)
        }
        print("Home repeated data: notes for unchanged sections, resets on compaction, new sessions and every \(HomeRepeatedData.refreshMessages) messages passed")
    }
}
