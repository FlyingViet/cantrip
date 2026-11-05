import Foundation

extension SessionTabTests {
    /// Home opens a new tab when asked: only the tab, or the tab with its handoff. It files it
    /// under a section, works in an existing folder, never switches the selected tab, and refuses
    /// names already open, unknown sections, missing folders and background runs.
    @MainActor
    static func testCantripHomeNewTabs() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        defer { (settings.backend, settings.memoryEnabled, settings.attachScreen) = saved }

        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        let existing = ChatSession(copilotBackend: CantripHomeBackendFixture())
        try existing.updateTab(name: "Bass Compass")
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        manager.sessions = [existing]
        let apps = try manager.tabSections.first { $0.name == "Apps" } ?? manager.createSection(named: "Apps")
        let delegations = CantripHomeDelegations.shared
        delegations.attach(manager: manager)
        let savedMakeTab = delegations.makeTab
        var opened: [(ChatSession, CantripHomeBackendFixture)] = []
        delegations.makeTab = {
            let fixture = CantripHomeBackendFixture()
            let tab = ChatSession(copilotBackend: fixture)
            opened.append((tab, fixture))
            return tab
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-new-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            delegations.makeTab = savedMakeTab
            for (tab, _) in opened { tab.cancel() }
            homeChat.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
        let selected = manager.active.id

        func reply(_ user: String, _ block: String) -> ChatMessage? {
            homeChat.messages.append(ChatMessage(role: .user, text: user))
            homeChat.messages.append(ChatMessage(role: .assistant, text: "On it.\n\n```cantrip-delegate\n\(block)\n```"))
            _ = homeChat.processCantripHomeBlocks()
            return homeChat.messages.last { $0.role == .assistant }
        }

        // Home's instructions say when it may open a tab, and list the sections to file it under.
        precondition(delegations.homeHandoffRules.contains("open one only when the user asks for a new tab")
                     && delegations.homeTabsData.contains("Tab sections for a new tab (data): ")
                     && delegations.homeTabsData.contains("Apps"),
                     "Home learns the newTab rule and the sections")

        // Only the tab: filed under its section (named in any case), not selected.
        let onlyTab = reply("Make a new tab for Sketchbook under Apps", #"{"newTab":{"title":"Sketchbook","section":"apps"}}"#)
        let sketchbook = try requireHome(manager.sessions.first { $0.title == "Sketchbook" })
        precondition(onlyTab?.text == "On it.\n\nOpened a new tab, **Sketchbook**, in Apps."
                     && onlyTab?.delegations.isEmpty == true
                     && manager.sectionID(of: sketchbook) == apps.id && manager.active.id == selected
                     && sketchbook.messages.isEmpty && !sketchbook.isStreaming,
                     "A new tab without work just opens, in its section, without switching: \(onlyTab?.text ?? "")")

        // The tab and its work: the brief becomes the new tab's first prompt and a handoff card.
        let brief = #"{"newTab":{"title":"Lineup Fixes","section":null,"folder":"\#(folder.path)"},"summary":"Fix lineup order","goal":"Headliners appear first in the lineup.","context":["Order comes from lineups.position"],"constraints":["Keep the API unchanged"],"doneWhen":"Lineup tests pass."}"#
        let handed = reply("Do this in a new tab: fix the lineup so headliners come first", brief)
        let lineup = try requireHome(manager.sessions.first { $0.title == "Lineup Fixes" })
        let card = try requireHome(handed?.delegations.first)
        try await waitForJournalTest { lineup.messages.contains { $0.role == .user } }
        let firstPrompt = lineup.messages.first { $0.role == .user }?.text ?? ""
        precondition(card.tabID == lineup.id && card.tabTitle == "Lineup Fixes" && card.summary == "Fix lineup order"
                     && lineup.workdir == folder.standardizedFileURL.path && manager.sectionID(of: lineup) == nil
                     && firstPrompt.contains("Goal: Headliners appear first in the lineup.")
                     && firstPrompt.contains("> Do this in a new tab: fix the lineup so headliners come first")
                     && manager.active.id == selected,
                     "A new tab with a brief takes the handoff in its folder: \(firstPrompt)")

        // Refusals: a name already open, an unknown section, a folder that isn't there, both or
        // neither target. Nothing opens.
        let count = manager.sessions.count
        let taken = reply("New tab for Bass Compass", #"{"newTab":{"title":"bass compass"}}"#)?.text ?? ""
        let noSection = reply("New tab under Games", #"{"newTab":{"title":"Puzzles","section":"Games"}}"#)?.text ?? ""
        let noFolder = reply("New tab in my new folder",
                             #"{"newTab":{"title":"Sketches","folder":"\#(folder.path)/missing"}}"#)?.text ?? ""
        let relative = reply("New tab in Coding", #"{"newTab":{"title":"Relative","folder":"Coding"}}"#)?.text ?? ""
        let both = reply("New tab", #"{"tabID":"\#(existing.id.uuidString)","newTab":{"title":"Both"}}"#)?.text ?? ""
        let neither = reply("New tab", #"{"summary":"Nothing to name"}"#)?.text ?? ""
        precondition(manager.sessions.count == count, "Refused blocks open no tab")
        precondition(taken.contains("A tab named “Bass Compass” is already open") && taken.contains(existing.id.uuidString),
                     "An open name points Home at that tab: \(taken)")
        precondition(noSection.contains("There's no tab section named “Games”. Sections: ") && noSection.contains("Apps"),
                     noSection)
        precondition(noFolder.contains("must be an existing folder") && relative.contains("must be an existing folder"),
                     "\(noFolder) / \(relative)")
        precondition(both.contains("not both") && neither.contains("Name the tab"), "\(both) / \(neither)")

        // Background runs hand off to open tabs only.
        let runFixture = CantripHomeBackendFixture()
        let run = ChatSession(copilotBackend: runFixture, cantripHomeRun: true, makeJournal: {
            try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory)
        })
        defer { run.cancel() }
        run.messages = [
            ChatMessage(role: .user, text: "Check the nightly build."),
            ChatMessage(role: .assistant, text: "```cantrip-delegate\n" + #"{"newTab":{"title":"Nightly"}}"# + "\n```"),
        ]
        _ = run.processCantripHomeBlocks()
        let runReply = run.messages.last { $0.role == .assistant }?.text ?? ""
        precondition(runReply.contains("Background runs can't open tabs") && manager.sessions.count == count
                     && !manager.sessions.contains { $0.title == "Nightly" },
                     "A background run never opens a tab: \(runReply)")
        print("Cantrip Home new tabs: open only, with a handoff, sections, folders, refusals and background runs passed")
    }
}
