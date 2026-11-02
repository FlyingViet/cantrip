import XCTest
@testable import Hermes

/// The host contract's generic fixture and expected results for backend "/" suggestions.
final class BackendSlashCommandsTests: XCTestCase {
    static let fixtureJSON = """
    {"backend":"Copilot","workdir":"/tmp/project","revision":"r1","status":null,"commands":[
     {"name":"plan","description":"Create an implementation plan before coding","kind":"builtin","source":"Copilot","inputHint":"prompt","requiresInput":false,"aliases":[],"insert":"/plan ","availability":"runs","note":null,"action":null},
     {"name":"usage","description":"Display session usage metrics and statistics","kind":"builtin","source":"Copilot","inputHint":null,"requiresInput":false,"aliases":[],"insert":"/usage ","availability":"runs","note":null,"action":null},
     {"name":"model","description":"Select the AI model for this session","kind":"builtin","source":"Copilot","inputHint":"model","requiresInput":false,"aliases":[],"insert":"/model ","availability":"cantrip","note":"Opens this tab's model settings.","action":"modelSettings"},
     {"name":"allow-all","description":"Enable all permissions","kind":"builtin","source":"Copilot","inputHint":"[on|off|show]","requiresInput":false,"aliases":["yolo"],"insert":"/allow-all ","availability":"unavailable","note":"Cantrip's approval settings decide what Copilot may do in this tab.","action":null},
     {"name":"fixture-skill","description":"Fixture project skill for tests","kind":"skill","source":"Project","inputHint":"instructions for the skill","requiresInput":false,"aliases":[],"insert":"/fixture-skill ","availability":"runs","note":null,"action":null},
     {"name":"review-helper","description":"Review the current diff","kind":"custom","source":"Personal","inputHint":null,"requiresInput":false,"aliases":[],"insert":"/review-helper ","availability":"runs","note":null,"action":null}
    ]}
    """

    static func fixture() throws -> BackendCommandsResponse {
        try JSONDecoder().decode(BackendCommandsResponse.self, from: Data(fixtureJSON.utf8))
    }

    private var commands: [BackendCommand] { (try? Self.fixture().commands) ?? [] }

    private func command(_ name: String) throws -> BackendCommand {
        try XCTUnwrap(commands.first { $0.name == name })
    }

    /// Names and scores for the composer text, plus the default highlight; nil when no list shows.
    private func suggest(_ text: String) -> (names: [String], scores: [Int], highlight: Int?)? {
        guard let token = BackendSlashCommands.slashToken(text) else { return nil }
        let matches = BackendSlashCommands.matches(token: token, commands: commands)
        return (matches.map(\.command.name), matches.map(\.score),
                BackendSlashCommands.defaultHighlight(token: token, matches: matches))
    }

    // MARK: Decoding

    func testDecodesTheContractFixture() throws {
        let response = try Self.fixture()
        XCTAssertEqual(response.backend, "Copilot")
        XCTAssertEqual(response.workdir, "/tmp/project")
        XCTAssertEqual(response.revision, "r1")
        XCTAssertNil(response.status)
        XCTAssertEqual(response.commands.map(\.name),
                       ["plan", "usage", "model", "allow-all", "fixture-skill", "review-helper"])
        let allowAll = try command("allow-all")
        XCTAssertTrue(allowAll.isUnavailable)
        XCTAssertEqual(allowAll.aliases, ["yolo"])
        XCTAssertEqual(allowAll.inputHint, "[on|off|show]")
        XCTAssertEqual(try command("model").action, "modelSettings")
        XCTAssertEqual(try command("model").availability, "cantrip")
        XCTAssertEqual(try command("fixture-skill").kind, "skill")
        XCTAssertEqual(try command("review-helper").source, "Personal")
    }

    func testDecodingIsLenientAndDropsRowsWithoutNameOrInsert() throws {
        let json = """
        {"status":"Codex isn't installed on this Mac.","extra":1,"commands":[
         {"name":"bare","insert":"/bare "},
         {"name":"no-insert"},
         {"insert":"/nameless "},
         {"name":"","insert":"/ "},
         {"name":"typed","insert":"/typed ","requiresInput":"yes","aliases":null,"future":true}
        ]}
        """
        let response = try JSONDecoder().decode(BackendCommandsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.commands.map(\.name), ["bare", "typed"])
        let bare = response.commands[0]
        XCTAssertEqual(bare.description, "")
        XCTAssertEqual(bare.kind, "builtin")
        XCTAssertEqual(bare.availability, "runs")
        XCTAssertEqual(bare.aliases, [])
        XCTAssertFalse(bare.requiresInput)
        XCTAssertNil(bare.inputHint)
        XCTAssertFalse(response.commands[1].requiresInput)
        XCTAssertEqual(response.trimmedStatus, "Codex isn't installed on this Mac.")
        XCTAssertNil(response.backend)
    }

    func testSessionCapabilityDefaultsToOffWhenMissing() throws {
        func session(_ extra: String) throws -> CantripRemoteSession {
            try JSONDecoder().decode(CantripRemoteSession.self, from: Data("""
            {"id":"tab","title":"Project","workdir":"/tmp","isStreaming":false,"canResume":false,
             "councilMode":false,"queuedCount":0\(extra)}
            """.utf8))
        }
        XCTAssertNil(try session("").supportsBackendCommands)
        XCTAssertFalse(try session("").offersBackendCommands)
        XCTAssertFalse(try session(#","supportsBackendCommands":false"#).offersBackendCommands)
        XCTAssertTrue(try session(#","supportsBackendCommands":true"#).offersBackendCommands)
    }

    func testCommandsRouteGetsTheLongerContentReadDeadline() {
        XCTAssertTrue(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/sessions/ABC/commands"))
        XCTAssertTrue(CantripRemoteAPI.isContentRead(method: "GET",
                                                     path: "/api/v1/sessions/ABC/commands?refresh=true"))
        XCTAssertFalse(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/sessions/ABC/model-settings"))
    }

    // MARK: When to show

    func testSlashToken() {
        XCTAssertEqual(BackendSlashCommands.slashToken("/"), "")
        XCTAssertEqual(BackendSlashCommands.slashToken("/PL"), "pl")
        XCTAssertEqual(BackendSlashCommands.slashToken("/fixture-skill"), "fixture-skill")
        XCTAssertNil(BackendSlashCommands.slashToken(""))
        XCTAssertNil(BackendSlashCommands.slashToken("plan"))
        XCTAssertNil(BackendSlashCommands.slashToken("$imagegen"))
        // Paths
        XCTAssertNil(BackendSlashCommands.slashToken("/tmp/x"))
        XCTAssertNil(BackendSlashCommands.slashToken("/Users/x"))
        XCTAssertNil(BackendSlashCommands.slashToken("//"))
        // An argument is being typed.
        XCTAssertNil(BackendSlashCommands.slashToken("/plan x"))
        XCTAssertNil(BackendSlashCommands.slashToken("/plan "))
        XCTAssertNil(BackendSlashCommands.slashToken("/plan\tx"))
        // Leading whitespace
        XCTAssertNil(BackendSlashCommands.slashToken(" /plan"))
        XCTAssertNil(BackendSlashCommands.slashToken("\n/plan"))
        // Multiline
        XCTAssertNil(BackendSlashCommands.slashToken("/plan\nmore"))
        XCTAssertNil(BackendSlashCommands.slashToken("/plan\n"))
        XCTAssertNil(BackendSlashCommands.slashToken("/plan\r\n"))
    }

    // MARK: Contract expected results

    func testSlashAloneListsEveryCommandWithUnavailableLastAndNoHighlight() throws {
        let result = try XCTUnwrap(suggest("/"))
        XCTAssertEqual(result.names, ["plan", "usage", "model", "fixture-skill", "review-helper", "allow-all"])
        XCTAssertEqual(Set(result.scores), [1])
        XCTAssertNil(result.highlight)
    }

    func testUMatchesUsageThenFixtureSkill() throws {
        let result = try XCTUnwrap(suggest("/u"))
        XCTAssertEqual(result.names, ["usage", "fixture-skill"])
        XCTAssertEqual(result.scores, [1, 3])
        XCTAssertEqual(result.highlight, 0)
    }

    func testPlMatchesPlan() throws {
        let result = try XCTUnwrap(suggest("/pl"))
        XCTAssertEqual(result.names, ["plan"])
        XCTAssertEqual(result.scores, [1])
        XCTAssertEqual(result.highlight, 0)
    }

    func testReMatchesReviewHelperThenFixtureSkill() throws {
        let result = try XCTUnwrap(suggest("/re"))
        XCTAssertEqual(result.names, ["review-helper", "fixture-skill"])
        XCTAssertEqual(result.scores, [1, 3])
        XCTAssertEqual(result.highlight, 0)
    }

    func testYoMatchesTheUnavailableAliasWithoutHighlight() throws {
        let result = try XCTUnwrap(suggest("/yo"))
        XCTAssertEqual(result.names, ["allow-all"])
        XCTAssertEqual(result.scores, [2])
        XCTAssertNil(result.highlight)
    }

    func testPathsSpacesAndLeadingSpaceShowNoList() {
        XCTAssertNil(suggest("/tmp/x"))
        XCTAssertNil(suggest("/plan x"))
        XCTAssertNil(suggest(" /plan"))
        XCTAssertNil(suggest("/plan\nx"))
    }

    // MARK: Ranking rules

    func testExactNameScoresZero() throws {
        let result = try XCTUnwrap(suggest("/plan"))
        XCTAssertEqual(result.names, ["plan"])
        XCTAssertEqual(result.scores, [0])
        XCTAssertEqual(result.highlight, 0)
    }

    func testUppercaseTokensMatchCaseInsensitively() throws {
        XCTAssertEqual(try XCTUnwrap(suggest("/USAGE")).names, ["usage"])
        XCTAssertEqual(try XCTUnwrap(suggest("/YO")).names, ["allow-all"])
    }

    func testSeparatorInsensitiveContains() throws {
        // "reviewhelper" contains "ewhel" although "review-helper" doesn't.
        let result = try XCTUnwrap(suggest("/ewhel"))
        XCTAssertEqual(result.names, ["review-helper"])
        XCTAssertEqual(result.scores, [3])
        XCTAssertNil(result.highlight, "Only strong matches (score <= 2) are highlighted")
        XCTAssertEqual(try XCTUnwrap(suggest("/fixture_skill")).names, ["fixture-skill"])
    }

    func testDescriptionWordsMatchOnlyFromTwoCharacters() throws {
        let coding = try XCTUnwrap(suggest("/coding"))
        XCTAssertEqual(coding.names, ["plan"])
        XCTAssertEqual(coding.scores, [4])
        XCTAssertNil(coding.highlight)
        // "Display session usage metrics..." and "Select the AI model for this session"
        let session = try XCTUnwrap(suggest("/sess"))
        XCTAssertEqual(session.names, ["usage", "model"])
        XCTAssertEqual(session.scores, [4, 4])
        // One letter never matches a description word: "c" is in no command name.
        XCTAssertEqual(try XCTUnwrap(suggest("/c")).names, [])
        // Mid-word text isn't a word prefix.
        XCTAssertEqual(try XCTUnwrap(suggest("/plementation")).names, [])
    }

    func testLowestRuleWinsAndHostOrderBreaksTies() {
        let list = [
            BackendCommand(name: "zz-review", insert: "/zz-review "),
            BackendCommand(name: "reviewer", insert: "/reviewer "),
            BackendCommand(name: "aa", description: "Review things", aliases: ["rev"], insert: "/aa "),
            BackendCommand(name: "review", insert: "/review "),
            BackendCommand(name: "reviews", insert: "/reviews ", availability: "unavailable"),
            BackendCommand(name: "bb", description: "Review again", insert: "/bb "),
        ]
        let matches = BackendSlashCommands.matches(token: "rev", commands: list)
        XCTAssertEqual(matches.map(\.command.name), ["reviewer", "review", "aa", "zz-review", "bb", "reviews"])
        XCTAssertEqual(matches.map(\.score), [1, 1, 2, 3, 4, 1])
        let exact = BackendSlashCommands.matches(token: "review", commands: list)
        XCTAssertEqual(exact.first?.command.name, "review")
        XCTAssertEqual(exact.first?.score, 0)
    }

    func testListStopsAtFiftyRows() {
        let many = (0..<80).map { BackendCommand(name: "cmd\($0)", insert: "/cmd\($0) ") }
        let matches = BackendSlashCommands.matches(token: "", commands: many)
        XCTAssertEqual(matches.count, 50)
        XCTAssertEqual(matches.first?.command.name, "cmd0")
        XCTAssertEqual(matches.last?.command.name, "cmd49")
    }

    // MARK: Choosing

    func testCommandsWithoutArgumentsSendOnReturnClickOrTap() throws {
        for name in ["usage", "review-helper"] {
            let choice = try XCTUnwrap(BackendSlashCommands.choose(try command(name), via: .activate,
                                                                   canOpenModelSettings: true))
            XCTAssertEqual(choice.text, "/\(name) ")
            XCTAssertTrue(choice.sendsImmediately, name)
            XCTAssertFalse(choice.opensModelSettings)
            XCTAssertEqual(choice.text.trimmingCharacters(in: .whitespacesAndNewlines), "/\(name)")
        }
    }

    func testCommandsWithAnInputHintInsertAndKeepFocus() throws {
        for name in ["plan", "fixture-skill"] {
            let choice = try XCTUnwrap(BackendSlashCommands.choose(try command(name), via: .activate,
                                                                   canOpenModelSettings: true))
            XCTAssertEqual(choice.text, "/\(name) ")
            XCTAssertFalse(choice.sendsImmediately, name)
        }
    }

    func testRequiresInputInsertsEvenWithoutAHint() throws {
        let needsText = BackendCommand(name: "ask", requiresInput: true, insert: "/ask ")
        XCTAssertFalse(try XCTUnwrap(BackendSlashCommands.choose(needsText, via: .activate,
                                                                 canOpenModelSettings: false)).sendsImmediately)
        let blankHint = BackendCommand(name: "go", inputHint: "  ", insert: "/go ")
        XCTAssertTrue(try XCTUnwrap(BackendSlashCommands.choose(blankHint, via: .activate,
                                                                canOpenModelSettings: false)).sendsImmediately)
        let emptyHint = BackendCommand(name: "go", inputHint: "", insert: "/go ")
        XCTAssertTrue(emptyHint.sendsWhenChosen)
    }

    func testTabOnlyInserts() throws {
        for command in commands where !command.isUnavailable && !command.opensModelSettings {
            let choice = try XCTUnwrap(BackendSlashCommands.choose(command, via: .tab, canOpenModelSettings: true))
            XCTAssertEqual(choice.text, command.insert)
            XCTAssertFalse(choice.sendsImmediately)
        }
    }

    func testCodexSkillInsertsItsDollarMentionVerbatim() throws {
        let json = """
        {"name":"imagegen","description":"Generate an image","kind":"skill","source":"System",
         "inputHint":"prompt","requiresInput":false,"aliases":[],"insert":"$imagegen ","availability":"runs"}
        """
        let skill = try JSONDecoder().decode(BackendCommand.self, from: Data(json.utf8))
        // The row shows what will be inserted, while matching still uses the name.
        XCTAssertEqual(skill.title, "$imagegen")
        XCTAssertEqual(BackendSlashCommands.accessibilityLabel(for: skill), "$imagegen, Generate an image, System")
        XCTAssertEqual(BackendSlashCommands.matches(token: "img", commands: [skill]).count, 0)
        XCTAssertEqual(BackendSlashCommands.matches(token: "image", commands: [skill]).first?.score, 1)
        let tapped = try XCTUnwrap(BackendSlashCommands.choose(skill, via: .activate, canOpenModelSettings: false))
        XCTAssertEqual(tapped.text, "$imagegen ")
        XCTAssertFalse(tapped.sendsImmediately)
        XCTAssertEqual(try XCTUnwrap(BackendSlashCommands.choose(skill, via: .tab, canOpenModelSettings: false)).text,
                       "$imagegen ")
        // The inserted mention closes the list.
        XCTAssertNil(BackendSlashCommands.slashToken(tapped.text))
        // A Codex skill without an argument sends its mention at once (trimmed by the sender).
        let bare = BackendCommand(name: "imagegen", kind: "skill", source: "System", insert: "$imagegen ")
        XCTAssertTrue(try XCTUnwrap(BackendSlashCommands.choose(bare, via: .activate,
                                                                canOpenModelSettings: false)).sendsImmediately)
    }

    func testUnavailableRowsAreNotChoosable() throws {
        let allowAll = try command("allow-all")
        XCTAssertNil(BackendSlashCommands.choose(allowAll, via: .activate, canOpenModelSettings: true))
        XCTAssertNil(BackendSlashCommands.choose(allowAll, via: .tab, canOpenModelSettings: true))
        let matches = BackendSlashCommands.matches(token: "yo", commands: commands)
        XCTAssertEqual(BackendSlashCommands.handle(.return, matches: matches, highlighted: 0), .ignore)
        XCTAssertEqual(BackendSlashCommands.handle(.tab, matches: matches, highlighted: nil), .ignore)
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: matches, highlighted: nil), .ignore)
    }

    func testModelSettingsActionOpensSettingsOnlyWhereTheClientCan() throws {
        let model = try command("model")
        let opens = try XCTUnwrap(BackendSlashCommands.choose(model, via: .activate, canOpenModelSettings: true))
        XCTAssertEqual(opens, BackendCommandChoice(text: "", sendsImmediately: false, opensModelSettings: true))
        XCTAssertTrue(try XCTUnwrap(BackendSlashCommands.choose(model, via: .tab,
                                                                canOpenModelSettings: true)).opensModelSettings)
        // Without model settings it is an ordinary row: "/model " takes an argument, so it is inserted.
        let inserts = try XCTUnwrap(BackendSlashCommands.choose(model, via: .activate, canOpenModelSettings: false))
        XCTAssertEqual(inserts, BackendCommandChoice(text: "/model ", sendsImmediately: false, opensModelSettings: false))
        // Unknown actions just insert.
        let unknown = BackendCommand(name: "x", insert: "/x ", availability: "cantrip", action: "somethingNew")
        XCTAssertEqual(try XCTUnwrap(BackendSlashCommands.choose(unknown, via: .activate,
                                                                 canOpenModelSettings: true)).text, "/x ")
    }

    // MARK: Keyboard

    func testArrowKeysWrapAndSkipUnavailableRows() {
        let all = BackendSlashCommands.matches(token: "", commands: commands)
        XCTAssertEqual(all.last?.command.name, "allow-all")
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: all, highlighted: nil), .highlight(0))
        XCTAssertEqual(BackendSlashCommands.handle(.up, matches: all, highlighted: nil), .highlight(4))
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: all, highlighted: 4), .highlight(0))
        XCTAssertEqual(BackendSlashCommands.handle(.up, matches: all, highlighted: 0), .highlight(4))
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: all, highlighted: 1), .highlight(2))
        let u = BackendSlashCommands.matches(token: "u", commands: commands)
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: u, highlighted: 0), .highlight(1))
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: u, highlighted: 1), .highlight(0))
    }

    func testReturnTabAndEscape() {
        let all = BackendSlashCommands.matches(token: "", commands: commands)
        // No highlight: Return sends the text unchanged.
        XCTAssertEqual(BackendSlashCommands.handle(.return, matches: all, highlighted: nil), .ignore)
        XCTAssertEqual(BackendSlashCommands.handle(.return, matches: all, highlighted: 1), .choose(all[1], .activate))
        XCTAssertEqual(BackendSlashCommands.handle(.tab, matches: all, highlighted: 2), .choose(all[2], .tab))
        XCTAssertEqual(BackendSlashCommands.handle(.tab, matches: all, highlighted: nil), .choose(all[0], .tab))
        XCTAssertEqual(BackendSlashCommands.handle(.escape, matches: all, highlighted: nil), .dismiss)
        XCTAssertEqual(BackendSlashCommands.handle(.escape, matches: [], highlighted: nil), .dismiss)
        XCTAssertEqual(BackendSlashCommands.handle(.up, matches: [], highlighted: nil), .ignore)
    }

    // MARK: Presentation

    func testPresentation() throws {
        let response = try Self.fixture()
        XCTAssertNil(BackendSlashCommands.presentation(token: nil, response: response, isLoading: false))
        XCTAssertEqual(BackendSlashCommands.presentation(token: "", response: nil, isLoading: true), .loading)
        XCTAssertNil(BackendSlashCommands.presentation(token: "", response: nil, isLoading: false),
                     "A failed first fetch shows nothing")
        XCTAssertEqual(BackendSlashCommands.presentation(token: "pl", response: response, isLoading: true)?.matches
            .map(\.command.name), ["plan"], "Cached rows show while a refetch runs")
        XCTAssertNil(BackendSlashCommands.presentation(token: "zzz", response: response, isLoading: false))
        let empty = BackendCommandsResponse(backend: "Codex", status: "Codex isn't installed on this Mac.")
        XCTAssertEqual(BackendSlashCommands.presentation(token: "", response: empty, isLoading: false),
                       .rows([], status: "Codex isn't installed on this Mac."))
        var partial = response
        partial.status = "  Claude Code isn't signed in.  "
        guard case .rows(let rows, let status)? = BackendSlashCommands.presentation(
            token: "u", response: partial, isLoading: false) else { return XCTFail("Expected rows") }
        XCTAssertEqual(rows.map(\.command.name), ["usage", "fixture-skill"])
        XCTAssertEqual(status, "Claude Code isn't signed in.")
    }

    // MARK: Accessibility

    func testRowTitleIsTheFirstTokenOfInsert() throws {
        XCTAssertEqual(try command("plan").title, "/plan")
        XCTAssertEqual(try command("allow-all").title, "/allow-all")
        XCTAssertEqual(BackendCommand(name: "x", insert: "/x-renamed  arg").title, "/x-renamed")
        XCTAssertEqual(BackendCommand(name: "x", insert: "   ").title, "/x")
    }

    func testRowStyleIsCompactOnlyForAVerticalBarInLandscape() {
        // iPhone Duo unfolded on its side: the system's vertical bar beside a landscape window.
        XCTAssertEqual(BackendSlashRowStyle.resolve(ChatDisplayTraits(hasVerticalBar: true, isLandscape: true)), .compact)
        // Duo unfolded upright keeps the iPhone rows.
        XCTAssertEqual(BackendSlashRowStyle.resolve(ChatDisplayTraits(hasVerticalBar: true, isLandscape: false)), .touch)
        // Other iPhones, upright or on their side.
        XCTAssertEqual(BackendSlashRowStyle.resolve(ChatDisplayTraits(hasVerticalBar: false, isLandscape: true)), .touch)
        XCTAssertEqual(BackendSlashRowStyle.resolve(ChatDisplayTraits(hasVerticalBar: false, isLandscape: false)), .touch)
        XCTAssertEqual(BackendSlashRowStyle.resolve(ChatDisplayTraits()), .touch)
    }

    // MARK: iPhone Duo sidebar layout

    func testUnfoldedDuoGetsTheRailUprightAndOnItsSide() {
        for landscape in [true, false] {
            let unfolded = ChatDisplayTraits(hasVerticalBar: true, isLandscape: landscape)
            XCTAssertTrue(unfolded.isUnfoldedDuo, "Unfolded \(landscape ? "on its side" : "upright") has the rail and sidebar")
            XCTAssertTrue(unfolded.placesActionsInVerticalBar, "The rail (the system's vertical bar) holds the actions")
        }
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: false, isLandscape: true).isUnfoldedDuo,
                       "Other iPhones on their side keep today's layout")
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: false, isLandscape: false).isUnfoldedDuo)
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: false).placesActionsInVerticalBar)
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: true, isLandscape: true, allowsSidebarLayout: false)
            .isUnfoldedDuo, "iPad keeps its split navigation")
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: true, isLandscape: true).usesAppRail,
                       "On its side the system's vertical bar is the rail")
    }

    func testUnfoldedUprightDrawsItsOwnRail() {
        // Unfolded upright the system's bar runs along the top: only the hinge says it's a Duo.
        let upright = ChatDisplayTraits(hasVerticalBar: false, isLandscape: false, isHingeOpen: true)
        XCTAssertTrue(upright.isUnfoldedDuo)
        XCTAssertTrue(upright.usesAppRail, "The app draws the rail")
        XCTAssertFalse(upright.placesActionsInVerticalBar)
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: false, isFolded: true, isHingeOpen: false).usesAppRail)
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: false, allowsSidebarLayout: false, isHingeOpen: true)
            .usesAppRail, "iPad keeps its split navigation")
    }

    func testFoldedDuoKeepsTheIPhoneLayoutOnItsSide() {
        // The outer display turned sideways (or squeezed by the keyboard) is still a folded phone.
        let foldedSideways = ChatDisplayTraits(hasVerticalBar: true, isLandscape: true, isFolded: true)
        XCTAssertFalse(foldedSideways.isUnfoldedDuo, "No rail items or sidebar while folded")
        XCTAssertTrue(foldedSideways.placesActionsInVerticalBar, "Actions stay in the system's side bar")
        XCTAssertEqual(BackendSlashRowStyle.resolve(foldedSideways), .touch)
        XCTAssertFalse(ChatDisplayTraits(hasVerticalBar: true, isLandscape: false, isFolded: true).isUnfoldedDuo)
    }

    func testSkillsGroupYoursBuiltInAndCantRunHere() throws {
        let sections = BackendSkillsSidebar.sections(try Self.fixture().commands)
        XCTAssertEqual(sections.map(\.group), [.yours, .builtIn, .unavailable])
        XCTAssertEqual(sections[0].matches.map(\.command.name), ["fixture-skill", "review-helper"])
        XCTAssertEqual(sections[1].matches.map(\.command.name), ["plan", "usage", "model"],
                       "Built-in commands that run or that Cantrip handles, in host order")
        XCTAssertEqual(sections[2].matches.map(\.command.name), ["allow-all"])
        XCTAssertEqual(sections.map(\.group.title), ["Your skills & commands", "Built-in", "Can't run here"])
        XCTAssertEqual(BackendSkillsSidebar.Group.allCases.filter(\.isCollapsedByDefault), [.unavailable])
        let cantripCommand = BackendCommand(name: "handoff", kind: "cantrip", insert: "/handoff ")
        XCTAssertEqual(BackendSkillsSidebar.group(of: cantripCommand), .yours)
        XCTAssertEqual(BackendSkillsSidebar.sections([]), [])
    }

    func testTypingSlashFiltersTheSidebarWithTheSameRankingAndHighlight() throws {
        let response = try Self.fixture()
        let token = try XCTUnwrap(BackendSlashCommands.slashToken("/re"))
        let matches = BackendSlashCommands.matches(token: token, commands: response.commands)
        let highlight = BackendSlashCommands.defaultHighlight(token: token, matches: matches)
        let filtered = BackendSkillsSidebar.content(response: response, isLoading: false, token: token,
                                                    highlighted: highlight)
        guard case .filtered(let rows, let highlighted, let status)? = filtered else { return XCTFail("Expected matches") }
        XCTAssertEqual(rows.map(\.command.name), ["review-helper", "fixture-skill"])
        XCTAssertEqual(highlighted, 0)
        XCTAssertNil(status)
        // Arrow keys move the same highlight the pop-up would use.
        XCTAssertEqual(BackendSlashCommands.handle(.down, matches: rows, highlighted: highlighted), .highlight(1))
        guard case .filtered(_, nil, _)? = BackendSkillsSidebar.content(
            response: response, isLoading: false, token: "", highlighted: nil
        ) else { return XCTFail("\"/\" lists everything without a highlight") }
        guard case .grouped(let groups, _)? = BackendSkillsSidebar.content(
            response: response, isLoading: true, token: nil, highlighted: 3
        ) else { return XCTFail("An idle composer lists the groups") }
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(BackendSkillsSidebar.content(response: nil, isLoading: true, token: "re", highlighted: nil), .loading)
        XCTAssertNil(BackendSkillsSidebar.content(response: nil, isLoading: false, token: nil, highlighted: nil),
                     "A failed first fetch shows nothing")
        guard case .filtered(_, nil, _)? = BackendSkillsSidebar.content(
            response: response, isLoading: false, token: "re", highlighted: 9
        ) else { return XCTFail("A stale highlight is dropped") }
        XCTAssertTrue(BackendSkillsSidebar.isExpanded(stored: false, isFiltering: true), "Filtering opens Skills")
        XCTAssertFalse(BackendSkillsSidebar.isExpanded(stored: false, isFiltering: false))
        XCTAssertTrue(BackendSkillsSidebar.isExpanded(stored: true, isFiltering: false))
    }

    func testAccessibilityLabelsAndHints() throws {
        XCTAssertEqual(BackendSlashCommands.accessibilityLabel(for: try command("usage")),
                       "/usage, Display session usage metrics and statistics, Copilot")
        XCTAssertEqual(BackendSlashCommands.accessibilityLabel(for: try command("allow-all")),
                       "/allow-all, Enable all permissions, Copilot, Cantrip's approval settings decide what Copilot may do in this tab., unavailable")
        XCTAssertEqual(BackendSlashCommands.accessibilityLabel(for: try command("model")),
                       "/model, Select the AI model for this session, Copilot, Opens this tab's model settings.")
        XCTAssertEqual(BackendSlashCommands.accessibilityHint(for: try command("usage"), canOpenModelSettings: false),
                       "Runs the command")
        XCTAssertEqual(BackendSlashCommands.accessibilityHint(for: try command("plan"), canOpenModelSettings: false),
                       "Inserts the command")
        XCTAssertEqual(BackendSlashCommands.accessibilityHint(for: try command("model"), canOpenModelSettings: true),
                       "Opens model settings")
        XCTAssertEqual(BackendSlashCommands.accessibilityHint(for: try command("model"), canOpenModelSettings: false),
                       "Inserts the command")
        XCTAssertEqual(BackendSlashCommands.countAnnouncement(1), "1 command")
        XCTAssertEqual(BackendSlashCommands.countAnnouncement(6), "6 commands")
    }
}

/// Fetching and caching per session.
@MainActor
final class BackendSlashCommandStoreTests: XCTestCase {
    @MainActor
    private final class Fetches {
        var calls: [(sessionID: String, continuation: CheckedContinuation<BackendCommandsResponse, Error>)] = []

        func fetch(_ sessionID: String) async throws -> BackendCommandsResponse {
            try await withCheckedThrowingContinuation { calls.append((sessionID, $0)) }
        }
    }

    private func context(_ session: String, server: String = "S", workdir: String = "/tmp/project",
                         revision: String? = "m1") -> BackendSlashCommandStore.Context {
        .init(key: "\(server)/\(session)", sessionID: session, workdir: workdir, modelSettingsRevision: revision)
    }

    private func response(_ name: String) -> BackendCommandsResponse {
        BackendCommandsResponse(revision: name, commands: [BackendCommand(name: name, insert: "/\(name) ")])
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testLoadsThenCachesPerSession() async {
        let store = BackendSlashCommandStore()
        let fetches = Fetches()
        let a = context("A")
        XCTAssertTrue(store.needsFetch(a))
        store.refreshIfNeeded(a, fetch: fetches.fetch)
        XCTAssertTrue(store.isLoading(a.key))
        XCTAssertNil(store.response(for: a.key))
        store.refreshIfNeeded(a, fetch: fetches.fetch)
        await settle { fetches.calls.count == 1 }
        XCTAssertEqual(fetches.calls.map(\.sessionID), ["A"], "One request per session at a time")
        fetches.calls[0].continuation.resume(returning: response("a"))
        await settle { !store.isLoading(a.key) }
        XCTAssertEqual(store.response(for: a.key)?.revision, "a")
        XCTAssertFalse(store.needsFetch(a))
        XCTAssertNil(store.response(for: context("B").key), "Never another session's list")
        XCTAssertNil(store.response(for: context("A", server: "Other").key), "Never another Mac's list")
    }

    func testRefetchesWhenOldOrTheBackendChanged() async {
        let store = BackendSlashCommandStore()
        let fetches = Fetches()
        let a = context("A")
        store.refreshIfNeeded(a, fetch: fetches.fetch)
        await settle { fetches.calls.count == 1 }
        fetches.calls[0].continuation.resume(returning: response("a"))
        await settle { !store.isLoading(a.key) }
        XCTAssertFalse(store.needsFetch(a, now: Date().addingTimeInterval(20)))
        XCTAssertTrue(store.needsFetch(a, now: Date().addingTimeInterval(31)))
        XCTAssertTrue(store.needsFetch(context("A", workdir: "/tmp/other")))
        XCTAssertTrue(store.needsFetch(context("A", revision: "m2")))
        XCTAssertTrue(store.needsFetch(context("A", revision: nil)))

        store.refreshIfNeeded(context("A", revision: "m2"), fetch: fetches.fetch)
        XCTAssertEqual(store.response(for: a.key)?.revision, "a", "Cached rows stay while the refetch runs")
        await settle { fetches.calls.count == 2 }
        fetches.calls[1].continuation.resume(returning: response("b"))
        await settle { !store.isLoading(a.key) }
        XCTAssertEqual(store.response(for: a.key)?.revision, "b")
        XCTAssertFalse(store.needsFetch(context("A", revision: "m2")))
    }

    func testFailureShowsNothingAndRetriesOnTheNextEntry() async {
        let store = BackendSlashCommandStore()
        let fetches = Fetches()
        let a = context("A")
        store.refreshIfNeeded(a, fetch: fetches.fetch)
        await settle { fetches.calls.count == 1 }
        fetches.calls[0].continuation.resume(throwing: URLError(.timedOut))
        await settle { !store.isLoading(a.key) }
        XCTAssertNil(store.response(for: a.key))
        XCTAssertNil(BackendSlashCommands.presentation(token: "", response: store.response(for: a.key),
                                                       isLoading: store.isLoading(a.key)))
        XCTAssertTrue(store.needsFetch(a))
    }

    func testDropsSupersededAndClearedResponses() async {
        let store = BackendSlashCommandStore()
        let fetches = Fetches()
        store.refreshIfNeeded(context("A"), fetch: fetches.fetch)
        await settle { fetches.calls.count == 1 }
        // The tab's backend changes while the first request is still out: the newer request wins.
        store.refreshIfNeeded(context("A", workdir: "/tmp/other"), fetch: fetches.fetch)
        await settle { fetches.calls.count == 2 }
        fetches.calls[1].continuation.resume(returning: response("new"))
        await settle { !store.isLoading("S/A") }
        fetches.calls[0].continuation.resume(returning: response("old"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.response(for: "S/A")?.revision, "new", "A stale response never replaces a newer one")

        // Connecting to another Mac forgets everything, including answers still on their way.
        store.refreshIfNeeded(context("B"), fetch: fetches.fetch)
        await settle { fetches.calls.count == 3 }
        store.removeAll()
        XCTAssertNil(store.response(for: "S/A"))
        fetches.calls[2].continuation.resume(returning: response("b"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.response(for: "S/B"))
        XCTAssertFalse(store.isLoading("S/B"))
    }
}
