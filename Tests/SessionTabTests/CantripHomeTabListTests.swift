import Foundation

extension SessionTabTests {
    /// Home lists every open tab, however many are open: the working and most recently active ones
    /// with their requests, the rest briefly. Tabs past the 20th used to be left out, so Home did
    /// their work itself instead of handing it to the tab that owns it. Background runs get the
    /// same list, in their instructions and in the file a scheduled task reads before a handoff.
    @MainActor
    static func testCantripHomeListsEveryOpenTab() async throws {
        // Which tabs are listed in full: working ones always, then the most recent; never-run
        // tabs and ties keep their sidebar order.
        let ids = (0..<6).map { _ in UUID() }
        let now = Date()
        let picked = CantripHomeDelegations.detailedTabIDs([
            (ids[0], false, nil), (ids[1], false, now.addingTimeInterval(-60)), (ids[2], true, nil),
            (ids[3], false, now), (ids[4], false, nil), (ids[5], false, now.addingTimeInterval(-60)),
        ], limit: 4)
        precondition(picked == [ids[2], ids[3], ids[1], ids[5]], "working, then newest, then sidebar order: \(picked)")
        precondition(CantripHomeDelegations.detailedTabIDs([(ids[0], true, nil), (ids[1], true, nil)], limit: 1)
                     == [ids[0], ids[1]], "working tabs are never cut")
        precondition(CantripHomeDelegations.detailedTabIDs([(ids[0], false, nil), (ids[1], false, nil)], limit: 1)
                     == [ids[0]])

        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        defer { (settings.backend, settings.memoryEnabled, settings.attachScreen) = saved }

        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        let titles = (1...24).map { String(format: "Project %02d", $0) } + ["Festival Planner", "Stage Map"]
        var tabs: [ChatSession] = []
        for (index, title) in titles.enumerated() {
            let tab = ChatSession(copilotBackend: CantripHomeBackendFixture())
            try tab.updateTab(name: title)
            tab.messages = [
                ChatMessage(role: .user, text: "Set up \(title): a native app with its own backend, tests and a release workflow."),
                ChatMessage(role: .assistant, text: "Done."),
                ChatMessage(role: .user, text: "Add offline caching to \(title) and keep the sync conflict rules from step \(index)."),
                ChatMessage(role: .assistant, text: "Done."),
                ChatMessage(role: .user, text: "Ship the \(title) build once its tests pass and the release notes are written."),
                ChatMessage(role: .assistant, text: "Shipped."),
            ]
            tabs.append(tab)
        }
        // The last two tabs in the sidebar are the ones used today.
        for tab in tabs.suffix(2) { tab.persistTranscript() }
        manager.sessions = tabs
        let delegations = CantripHomeDelegations.shared
        delegations.attach(manager: manager)
        defer {
            for tab in tabs { tab.cancel() }
            homeChat.cancel()
        }

        func lines(_ data: String) -> [String] { data.split(separator: "\n").map(String.init) }
        let home = delegations.homeTabsData
        for tab in tabs {
            precondition(home.contains("- \(tab.id.uuidString): \"\(tab.title)\""), "Home lists \(tab.title): \(home)")
            precondition(delegations.backgroundTabsData.contains(tab.id.uuidString)
                         && delegations.backgroundInstructions.contains(tab.id.uuidString),
                         "background runs list \(tab.title)")
        }
        let full = lines(home).filter { $0.hasPrefix("- ") && $0.contains("; recent ") }
        let brief = lines(home).filter { $0.hasPrefix("- ") && $0.contains(": \"Project") && !$0.contains("; recent ") }
        precondition(full.count == CantripHomeDelegations.detailedTabLimit && brief.count == 26 - full.count,
                     "\(full.count) full and \(brief.count) brief lines")
        precondition(full.contains { $0.contains("\"Stage Map\"") } && full.contains { $0.contains("\"Festival Planner\"") },
                     "the most recently used tabs are listed in full, wherever they sit in the sidebar")
        precondition(brief.allSatisfy { $0.contains("; started \"Set up ") } && home.contains("Other open tabs, briefly"),
                     "brief lines keep the first request: \(brief.first ?? "")")
        let tabBlock = home.components(separatedBy: "Tab sections for a new tab")[0]
        // No bigger than the old list, which showed only the first 20 tabs, all in full.
        let oldTwenty = tabs.prefix(20).map {
            CantripHomeDelegations.tabSummary(id: $0.id, title: $0.title, workdir: $0.workdir, state: "idle",
                                              projects: [], messages: $0.messages)
        }.joined(separator: "\n")
        let header = lines(tabBlock).first ?? ""
        precondition(tabBlock.count <= header.count + 1 + oldTwenty.count + 1,
                     "26 tabs take no more room than 20 did: \(tabBlock.count) vs \(header.count + oldTwenty.count + 2)")

        // A scheduled-task run's tab file lists them all too.
        homeChat.writeCantripHomeTaskTabs()
        let file = try String(contentsOf: CantripHomeTaskContext.tabsFile, encoding: .utf8)
        precondition(tabs.allSatisfy { file.contains($0.id.uuidString) }, "tabs.txt lists every tab")
        print("Cantrip Home tab list: all 26 open tabs listed (\(full.count) in full, \(brief.count) briefly), "
              + "\(tabBlock.count) characters (the first 20 in full took \(header.count + oldTwenty.count + 2))")
    }
}
