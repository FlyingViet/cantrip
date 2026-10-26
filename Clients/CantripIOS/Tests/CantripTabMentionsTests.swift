import Foundation
import SwiftUI
import XCTest
@testable import Hermes

/// @-mentions of tabs (host contract, Mac `TabMentions`): tokens, the composer's "@" query,
/// matching, picking, encoding several picks together, the pop-up's keys and the session fields.
final class CantripTabMentionsTests: XCTestCase {
    private let tv = "11111111-2222-3333-4444-555555555555"
    private let remote = "AAAAAAAA-2222-3333-4444-555555555555"

    private func token(_ label: String, _ id: String) -> String { "@[\(label)](cantrip-tab:\(id))" }

    // MARK: Tokens

    func testLabelsAndTokens() {
        XCTAssertEqual(CantripTabMentions.label(for: "  Fix [the]\n TV  "), "Fix the TV")
        XCTAssertEqual(CantripTabMentions.label(for: " [] "), "tab")
        XCTAssertEqual(CantripTabMentions.label(for: "Tabs\tand\r\nlines"), "Tabs and lines")
        XCTAssertEqual(CantripTabMentions.label(for: String(repeating: "x", count: 90)).count, CantripTabMentions.labelLimit)
        // Cut on a character boundary.
        XCTAssertEqual(CantripTabMentions.label(for: String(repeating: "é", count: 70)), String(repeating: "é", count: 60))
        XCTAssertEqual(CantripTabMentions.token(label: "Sony TV", id: tv.lowercased()), token("Sony TV", tv))

        let text = "Ask \(token("TV", tv)) and \(token("TV Remote", remote.lowercased()))."
        let parsed = CantripTabMentions.parse(text)
        XCTAssertEqual(parsed.map(\.label), ["TV", "TV Remote"])
        XCTAssertEqual(parsed.map(\.id), [tv, remote], "IDs are read in either case")
        XCTAssertEqual(CantripTabMentions.plain(text), "Ask @TV and @TV Remote.")
        XCTAssertTrue(CantripTabMentions.parse("@[TV](cantrip-tab:not-a-uuid) [x](cantrip-tab:\(tv))").isEmpty)
        XCTAssertEqual(CantripTabMentions.plain("no mentions [here](https://x.y)"), "no mentions [here](https://x.y)")
        XCTAssertEqual(CantripTabMentions.tabID(from: URL(string: "cantrip-tab:\(tv.lowercased())")!), tv)
        XCTAssertNil(CantripTabMentions.tabID(from: URL(string: "https://example.com")!))
    }

    // MARK: Composer

    private func query(_ text: String, caret: Int? = nil) -> String? {
        let index = caret.map { text.index(text.startIndex, offsetBy: $0) }
        return CantripTabMentions.query(in: text, caret: index)?.query
    }

    func testQueryStartsOnlyAtAWordStart() {
        // Emails and handles inside words never start one.
        XCTAssertNil(query("mail a@b.com"))
        XCTAssertNil(query("a@b.com"))
        XCTAssertNil(query("x@handle"))
        XCTAssertEqual(query("@"), "")
        XCTAssertEqual(query("hi @ba"), "ba")
        XCTAssertEqual(query("(@tv"), "tv")
        XCTAssertEqual(query("“@tv"), "tv")
        XCTAssertEqual(query("\"@tv"), "tv")
        XCTAssertNil(query("hi @ "), "a query can't start with a space")
        XCTAssertNil(query("@a\nb"))
        XCTAssertNil(query("@[TV](x"), "already a token")
        XCTAssertNil(query("", caret: 0))
        XCTAssertEqual(query("@bass co"), "bass co")
        XCTAssertEqual(query("@ab cd", caret: 3), "ab", "the caret, not the end of the text")
        XCTAssertNil(query("@" + String(repeating: "a", count: 49)), "too far back")
        XCTAssertEqual(query("@" + String(repeating: "a", count: 48)), String(repeating: "a", count: 48))
    }

    private let tabs = [
        CantripTabMentions.Candidate(id: "1", title: "Sony TV"),
        CantripTabMentions.Candidate(id: "2", title: "Bass Compass", workdir: "/tmp/bass-compass"),
        CantripTabMentions.Candidate(id: "3", title: "Café Ops"),
        CantripTabMentions.Candidate(id: "4", title: "Cantrip", workdir: "/tmp/Cantrip", isStreaming: true),
        CantripTabMentions.Candidate(id: "5", title: "Notes file", parentTitle: "Cantrip", needsAnswer: true),
    ]

    private func titles(_ query: String) -> [String] { CantripTabMentions.matches(query, in: tabs).map(\.title) }

    func testMatchingIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(titles(""), tabs.map(\.title), "an empty query lists every tab in list order")
        XCTAssertEqual(titles("ba"), ["Bass Compass"])
        XCTAssertEqual(titles("comp"), ["Bass Compass"])
        XCTAssertEqual(titles("bass c"), ["Bass Compass"])
        XCTAssertEqual(titles("BASS   c"), ["Bass Compass"], "spaces collapse")
        XCTAssertEqual(titles("cafe"), ["Café Ops"])
        XCTAssertEqual(titles("CAFÉ"), ["Café Ops"])
        XCTAssertEqual(titles("CA"), ["Café Ops", "Cantrip"])
        XCTAssertEqual(titles("tv"), ["Sony TV"])
        XCTAssertEqual(titles("ass"), ["Bass Compass"], "contains")
        XCTAssertEqual(titles("bass-c"), ["Bass Compass"], "the project folder")
        XCTAssertTrue(titles("bass x").isEmpty)
        XCTAssertEqual(CantripTabMentions.matches("", in: tabs + tabs).count, 8, "at most 8")
        // Title prefix beats word prefix beats contains.
        let ranked = [
            CantripTabMentions.Candidate(id: "a", title: "Rebase tool"),
            CantripTabMentions.Candidate(id: "b", title: "Old base"),
            CantripTabMentions.Candidate(id: "c", title: "Base camp"),
        ]
        XCTAssertEqual(CantripTabMentions.matches("base", in: ranked).map(\.id), ["c", "b", "a"])
    }

    func testRowDetailsAndAccessibility() {
        XCTAssertEqual(tabs[1].detail, "bass-compass")
        XCTAssertEqual(tabs[3].detail, "Working", "the project named like the tab is left out")
        XCTAssertEqual(tabs[3].project, "Cantrip")
        XCTAssertEqual(tabs[4].detail, "Child of Cantrip · Needs your answer")
        XCTAssertEqual(tabs[4].accessibilityLabel, "Notes file, child of Cantrip, needs your answer")
        XCTAssertEqual(tabs[1].accessibilityLabel, "Bass Compass, project bass-compass")
        // A home folder (or the root) isn't a project.
        XCTAssertNil(CantripTabMentions.Candidate(id: "h", title: "Home", workdir: "/Users/alex").project)
        XCTAssertNil(CantripTabMentions.Candidate(id: "h", title: "Home", workdir: "/Users/alex/").project)
        XCTAssertNil(CantripTabMentions.Candidate(id: "h", title: "Root", workdir: "/").project)
        XCTAssertEqual(CantripTabMentions.Candidate(id: "p", title: "X", workdir: "/Users/alex/Coding/Plexa").project, "Plexa")
        XCTAssertEqual(CantripTabMentions.countAnnouncement(1), "1 tab")
        XCTAssertEqual(CantripTabMentions.countAnnouncement(3), "3 tabs")
    }

    func testPickingInsertsTheLabelAndMovesTheCaret() {
        let text = "Hey @so later"
        let at = text.firstIndex(of: "@")!
        let caret = text.index(at, offsetBy: 3)
        let picked = CantripTabMentions.insert(tabs[0], at: at, caret: caret, in: text)
        XCTAssertEqual(picked.text, "Hey @Sony TV later")
        XCTAssertEqual(picked.label, "Sony TV")
        XCTAssertEqual(String(picked.text[picked.caret...]), "later", "the caret skips the space that was already there")

        let atEnd = CantripTabMentions.insert(tabs[1], at: "@ba".startIndex, in: "@ba")
        XCTAssertEqual(atEnd.text, "@Bass Compass ")
        XCTAssertEqual(atEnd.caret, atEnd.text.endIndex)

        let bracket = "Ask (@ca"
        let picked2 = CantripTabMentions.insert(tabs[2], at: bracket.firstIndex(of: "@")!, in: bracket)
        XCTAssertEqual(picked2.text, "Ask (@Café Ops ")
        let mention = CantripTabMention(id: "1", label: "Sony TV")
        XCTAssertEqual(CantripTabMentions.adding(mention, to: [mention]), [mention], "picked twice, one chip")
    }

    // MARK: Encoding several picks

    /// After a pick the list stays closed at that "@": Return sends, and the next word typed isn't
    /// taken for a query and replaced.
    func testAPickedMentionIsNotAQuery() throws {
        let sony = CantripTabMention(id: tv, label: "Sony TV")
        let candidates = [CantripTabMentions.Candidate(id: tv, title: "Sony TV"),
                          CantripTabMentions.Candidate(id: remote, title: "Sony TV Stand")]
        for text in ["@Sony TV ", "Ask @Sony TV so", "@Sony TV", "@Sony TV, then"] {
            let found = try XCTUnwrap(CantripTabMentions.query(in: text), text)
            XCTAssertTrue(CantripTabMentions.isPicked(at: found.at, in: text, picks: [sony]), text)
            XCTAssertNil(CantripTabMentions.popup(text: text, caret: nil, candidates: candidates, dismissedAt: nil,
                                                  picks: [sony]), text)
        }
        XCTAssertFalse(CantripTabMentions.isPicked(at: "@Sony TVs".startIndex, in: "@Sony TVs", picks: [sony]))
        XCTAssertFalse(CantripTabMentions.isPicked(at: "@So".startIndex, in: "@So", picks: [sony]))
        XCTAssertNotNil(CantripTabMentions.popup(text: "@Sony T", caret: nil, candidates: candidates, dismissedAt: nil,
                                                 picks: [sony]), "editing the label asks again")
        XCTAssertNotNil(CantripTabMentions.popup(text: "@Sony TV ", caret: nil, candidates: candidates, dismissedAt: nil),
                        "without the pick it's an ordinary query")
        // A new "@" after the picked one is a query again.
        let next = try XCTUnwrap(CantripTabMentions.popup(text: "@Sony TV and @so", caret: nil, candidates: candidates,
                                                          dismissedAt: nil, picks: [sony]))
        XCTAssertEqual(next.query, "so")
    }

    /// A label stands for one ID: a second tab with the same title gets its project, then a number.
    func testSameTitledTabsGetTheirOwnLabels() {
        let first = CantripTabMentions.Candidate(id: tv, title: "Sony TV", workdir: "/tmp/sony-tv")
        let twin = CantripTabMentions.Candidate(id: remote, title: "Sony TV", workdir: "/tmp/tv-two")
        let bare = CantripTabMentions.Candidate(id: "BBBBBBBB-2222-3333-4444-555555555555", title: "Sony TV")
        let picks = [CantripTabMention(id: tv, label: "Sony TV")]
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: first, among: picks), "Sony TV", "re-picking keeps the label")
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: first, among: []), "Sony TV")
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: twin, among: picks), "Sony TV (tv-two)")
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: bare, among: picks), "Sony TV 2")
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: bare, among: picks + [CantripTabMention(id: remote, label: "Sony TV 2")]),
                       "Sony TV 3")

        // A title already at the 60-character limit is shortened so the suffix fits (no endless loop).
        let long = String(repeating: "x", count: 70)
        let longPicks = [CantripTabMention(id: tv, label: String(repeating: "x", count: 60)),
                         CantripTabMention(id: remote, label: String(repeating: "x", count: 58) + " 2")]
        let longLabel = CantripTabMentions.uniqueLabel(
            for: CantripTabMentions.Candidate(id: "CCCCCCCC-2222-3333-4444-555555555555", title: long), among: longPicks
        )
        XCTAssertEqual(longLabel, String(repeating: "x", count: 58) + " 3")
        XCTAssertLessThanOrEqual(longLabel.count, CantripTabMentions.labelLimit)
        // A long project name isn't used; a number is.
        let longProject = CantripTabMentions.Candidate(id: remote, title: "Sony TV",
                                                       workdir: "/tmp/" + String(repeating: "p", count: 40))
        XCTAssertEqual(CantripTabMentions.uniqueLabel(for: longProject, among: picks), "Sony TV 2")

        let label = CantripTabMentions.uniqueLabel(for: twin, among: picks)
        let text = "compare @Sony TV with @so"
        let picked = CantripTabMentions.insert(twin, at: text.lastIndex(of: "@")!, in: text, label: label)
        XCTAssertEqual(picked.text, "compare @Sony TV with @Sony TV (tv-two) ")
        let both = picks + [CantripTabMention(id: remote, label: picked.label)]
        let sent = CantripTabMentions.encode(picked.text, mentions: both)
        XCTAssertEqual(CantripTabMentions.parse(sent).map(\.id), [tv, remote], sent)
        XCTAssertEqual(CantripTabMentions.remaining(both, in: picked.text), both)
        XCTAssertEqual(CantripTabMentions.plain(sent), picked.text)
    }

    /// Titles and lines taken from a message read "@Label".
    func testTitlesFromMessagesShowLabels() throws {
        let json = #"{"id":"c1","title":"Ask @[Sony TV](cantrip-tab:11111111-2222-3333-4444-555555555555) what port","prompt":"Ask @[Sony TV](cantrip-tab:11111111-2222-3333-4444-555555555555) what port\nthen fix it","state":"working"}"#
        let child = try JSONDecoder().decode(CantripRemoteChildResult.self, from: Data(json.utf8))
        XCTAssertEqual(child.title, "Ask @Sony TV what port")
        XCTAssertEqual(CantripChildTabText.firstLine(child.prompt), "Ask @Sony TV what port")
        let tab = try JSONDecoder().decode(CantripRemoteChildTab.self, from: Data(
            #"{"state":"working","title":"\#(token("TV", tv)) notes","parentTitle":"Planner","statusLine":"Working"}"#.utf8))
        XCTAssertEqual(tab.title, "@TV notes")
    }

    func testEncodingLongestLabelFirst() {
        let picks = [CantripTabMention(id: tv, label: "TV"), CantripTabMention(id: remote, label: "TV Remote")]
        let encoded = CantripTabMentions.encode("ask @TV and @TV Remote, mail a@TV (@TV) @TVs", mentions: picks)
        XCTAssertEqual(encoded, "ask \(token("TV", tv)) and \(token("TV Remote", remote)), mail a@TV (\(token("TV", tv))) @TVs")
        XCTAssertEqual(CantripTabMentions.plain(encoded), "ask @TV and @TV Remote, mail a@TV (@TV) @TVs")
        XCTAssertEqual(CantripTabMentions.encode("typed @Sony TV by hand", mentions: []), "typed @Sony TV by hand",
                       "a name typed without picking stays plain text")
        XCTAssertEqual(CantripTabMentions.encode("@Sony TV, please", mentions: [CantripTabMention(id: tv, label: "Sony TV")]),
                       "\(token("Sony TV", tv)), please")
    }

    /// "@TV" alone is gone when only "@TV Remote" is left, though "@TV" matches its start.
    func testPicksAreCheckedTogether() {
        let tvPick = CantripTabMention(id: tv, label: "TV")
        let remotePick = CantripTabMention(id: remote, label: "TV Remote")
        let picks = [tvPick, remotePick]
        XCTAssertEqual(CantripTabMentions.remaining(picks, in: "only @TV Remote here"), [remotePick])
        XCTAssertEqual(CantripTabMentions.remaining(picks, in: "@TV and @TV Remote"), picks)
        XCTAssertEqual(CantripTabMentions.remaining(picks, in: "@TV only"), [tvPick])
        XCTAssertEqual(CantripTabMentions.remaining(picks, in: "@TVs only"), [], "not at a word boundary")
        XCTAssertEqual(CantripTabMentions.remaining([remotePick, tvPick], in: "only @TV Remote here"), [remotePick],
                       "pick order doesn't matter")

        // Removing a chip takes its "@Label" (and one space) out and keeps the other pick's text.
        XCTAssertEqual(CantripTabMentions.removing(tvPick, from: "ask @TV now, @TV Remote stays", among: picks),
                       "ask now, @TV Remote stays")
        XCTAssertEqual(CantripTabMentions.removing(remotePick, from: "ask @TV now, @TV Remote stays", among: picks),
                       "ask @TV now, stays")
        XCTAssertEqual(CantripTabMentions.removing(tvPick, from: "@TV Remote only", among: picks), "@TV Remote only",
                       "nothing to remove: \"@TV Remote\" isn't \"@TV\"")
        XCTAssertEqual(CantripTabMentions.removing(tvPick, from: "end @TV", among: [tvPick]), "end ")
    }

    // MARK: Pop-up

    func testPopupStatesAndDismissal() throws {
        let rows = try XCTUnwrap(CantripTabMentions.popup(text: "Ask @ba", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertEqual(rows.at, 4)
        XCTAssertEqual(rows.query, "ba")
        XCTAssertEqual(rows.rows.map(\.title), ["Bass Compass"])

        let none = try XCTUnwrap(CantripTabMentions.popup(text: "@zz", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertEqual(none.content, .noMatch("zz"))
        XCTAssertEqual(CantripTabMentions.noMatchText("zz"), "No open tab matches “zz”")
        XCTAssertNil(CantripTabMentions.popup(text: "@zz top", caret: nil, candidates: tabs, dismissedAt: nil),
                     "no match with a space: the @ text stays plain")
        XCTAssertNil(CantripTabMentions.popup(text: "mail a@b", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertNil(CantripTabMentions.popup(text: "Ask @ba", caret: nil, candidates: tabs, dismissedAt: 4), "Escape")

        // Escape lasts while that "@" starts the text being typed; a new "@" shows again.
        XCTAssertEqual(CantripTabMentions.keepsDismissal(4, text: "Ask @bass", caret: nil), 4)
        XCTAssertNil(CantripTabMentions.keepsDismissal(4, text: "Ask ", caret: nil))
        XCTAssertNil(CantripTabMentions.keepsDismissal(4, text: "Ask @bass and @c", caret: nil))
        XCTAssertNotNil(CantripTabMentions.popup(text: "Ask @bass and @c", caret: nil, candidates: tabs, dismissedAt: nil))
    }

    func testKeys() throws {
        let popup = try XCTUnwrap(CantripTabMentions.popup(text: "@c", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertEqual(popup.rows.map(\.title), ["Café Ops", "Cantrip", "Bass Compass"])
        XCTAssertEqual(CantripTabMentions.handle(.down, popup: popup, highlighted: 0), .highlight(1))
        XCTAssertEqual(CantripTabMentions.handle(.down, popup: popup, highlighted: 2), .highlight(0), "wraps")
        XCTAssertEqual(CantripTabMentions.handle(.up, popup: popup, highlighted: 0), .highlight(2), "wraps")
        XCTAssertEqual(CantripTabMentions.handle(.return, popup: popup, highlighted: 1), .pick(popup.rows[1]))
        XCTAssertEqual(CantripTabMentions.handle(.tab, popup: popup, highlighted: 0), .pick(popup.rows[0]))
        XCTAssertEqual(CantripTabMentions.handle(.escape, popup: popup, highlighted: 0), .dismiss)

        let none = try XCTUnwrap(CantripTabMentions.popup(text: "@zz", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertEqual(CantripTabMentions.handle(.return, popup: none, highlighted: 0), .ignore, "Return sends as usual")
        XCTAssertEqual(CantripTabMentions.handle(.down, popup: none, highlighted: 0), .ignore)
        XCTAssertEqual(CantripTabMentions.handle(.escape, popup: none, highlighted: 0), .dismiss)

        // The highlight follows the query it was moved on; a new query starts at the first row.
        let moved = CantripMentionHighlight(at: popup.at, query: popup.query, index: 2)
        XCTAssertEqual(CantripMentionHighlight.index(moved, popup: popup), 2)
        let other = try XCTUnwrap(CantripTabMentions.popup(text: "@ca", caret: nil, candidates: tabs, dismissedAt: nil))
        XCTAssertEqual(CantripMentionHighlight.index(moved, popup: other), 0)
    }

    func testCaretFromTheTextFieldSelection() {
        let text = "@ab cd"
        XCTAssertEqual(CantripMentionCaret.position(in: text, selection: nil), text.endIndex, "no caret: end of text")
        let caret = text.index(text.startIndex, offsetBy: 3)
        XCTAssertEqual(CantripMentionCaret.position(in: text, selection: TextSelection(insertionPoint: caret)), caret)
        XCTAssertNil(CantripMentionCaret.position(in: text, selection: TextSelection(range: text.startIndex..<caret)),
                     "a selected range shows no suggestions")
        // A caret read off the text view (the Gateway Mac): UTF-16 offsets.
        XCTAssertEqual(CantripMentionCaret.position(in: text, utf16Offset: 3), caret)
        XCTAssertEqual(CantripMentionCaret.position(in: text, utf16Offset: nil), text.endIndex)
        XCTAssertEqual(CantripMentionCaret.position(in: text, utf16Offset: 99), text.endIndex, "from before an edit")
        XCTAssertNil(CantripMentionCaret.position(in: text, utf16Offset: -1), "a selected range")
        let emoji = "🎉 @ta"
        XCTAssertEqual(CantripMentionCaret.position(in: emoji, utf16Offset: 1), emoji.index(after: emoji.startIndex),
                       "never inside a character")
        XCTAssertEqual(CantripTabMentions.query(in: emoji, caret: CantripMentionCaret.position(in: emoji, utf16Offset: 6))?.query, "ta")
    }

    // MARK: Sessions

    private func session(_ id: String, _ title: String, mentionable: Bool? = true, parent: String? = nil,
                         section: String? = nil) -> CantripRemoteSession {
        var session = CantripRemoteSession(id: id, title: title, workdir: "/tmp/\(title)", isStreaming: false,
                                           canResume: false, councilMode: false, queuedCount: 0, status: nil,
                                           messages: nil, supportsImageAttachments: true, queued: nil)
        session.mentionable = mentionable
        session.parentID = parent
        session.sectionID = section
        return session
    }

    func testCandidatesKeepTheTabListOrderAndSkipWhatCantBeMentioned() {
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "AAAAAAAA-0000-0000-0000-000000000002"
        let c = "AAAAAAAA-0000-0000-0000-000000000003", d = "AAAAAAAA-0000-0000-0000-000000000004"
        let e = "AAAAAAAA-0000-0000-0000-000000000005"
        let sessions = [
            session(a, "Planner"),
            session(b, "Notes child", parent: a),
            session(c, "Secret", mentionable: false),
            session(d, "Old host tab", mentionable: nil),
            session(e, "Sony TV", section: "s1"),
        ]
        let flat = CantripTabMentions.candidates(sessions: sessions, sections: [], composingID: nil)
        XCTAssertEqual(flat.map(\.title), ["Planner", "Notes child", "Sony TV"])
        XCTAssertEqual(flat[1].parentTitle, "Planner")
        XCTAssertEqual(flat[1].detail, "Child of Planner", "a project named like the tab is left out")
        XCTAssertEqual(CantripTabMentions.candidates(sessions: sessions, sections: [], composingID: a).map(\.title),
                       ["Notes child", "Sony TV"], "never the tab being written in")
        // Sections first, then Tabs, as the lists show them.
        let grouped = CantripTabMentions.candidates(sessions: sessions, sections: [CantripTabSection(id: "s1", name: "Work")],
                                                    composingID: nil)
        XCTAssertEqual(grouped.map(\.title), ["Sony TV", "Planner", "Notes child"])
    }

    func testSessionFieldsDecodeAndOldHostsShowNoMentions() throws {
        let json = #"""
        {"sessions":[
          {"id":"AAAAAAAA-0000-0000-0000-000000000001","title":"Tab","workdir":"/tmp","isStreaming":false,"canResume":false,
           "councilMode":false,"queuedCount":0,"supportsTabMentions":true,"mentionable":true},
          {"id":"AAAAAAAA-0000-0000-0000-000000000002","title":"Old","workdir":"/tmp","isStreaming":false,"canResume":false,
           "councilMode":false,"queuedCount":0}],
         "home":{"id":"AAAAAAAA-0000-0000-0000-00000000000F","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,
           "canResume":false,"councilMode":false,"queuedCount":0,"isCantripHome":true,"supportsTabMentions":true,"mentionable":false}}
        """#
        let listing = try JSONDecoder().decode(CantripSessionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(listing.sessions[0].supportsTabMentions, true)
        XCTAssertEqual(listing.sessions[0].mentionable, true)
        XCTAssertNil(listing.sessions[1].supportsTabMentions)
        XCTAssertNil(listing.sessions[1].mentionable)
        XCTAssertTrue(CantripTabMentions.supportsMentions(listing.sessions[0]))
        XCTAssertFalse(CantripTabMentions.supportsMentions(listing.sessions[1]), "older Macs: no mention UI")
        XCTAssertFalse(CantripTabMentions.supportsMentions(nil))
        let home = try XCTUnwrap(listing.home)
        XCTAssertTrue(CantripTabMentions.supportsMentions(home))
        XCTAssertEqual(CantripTabMentions.candidates(sessions: listing.sessions + [home], sections: [],
                                                     composingID: home.id).map(\.title), ["Tab"],
                       "Home and tabs from older Macs are never suggested")
    }

    // MARK: Rendering

    func testRenderingShowsLabelsNeverTokens() {
        let text = "Ask \(token("Sony TV", tv)) now"
        XCTAssertEqual(CantripTabMentions.segments(text), [.text("Ask "), .mention(label: "Sony TV", id: tv), .text(" now")])
        XCTAssertEqual(CantripTabMentions.markdown("Ask \(token("A*b_", tv)) now"), #"Ask **@A\*b\_** now"#)
        XCTAssertEqual(CantripTabMentions.markdown(text) { $0 == tv }, "Ask [**@Sony TV**](cantrip-tab:\(tv)) now",
                       "an open tab is a link")
        XCTAssertEqual(CantripTabMentions.markdown("```\n\(text)\n```\n\(text)"),
                       "```\nAsk @Sony TV now\n```\nAsk **@Sony TV** now", "code reads as plain text")

        let links = CantripMentionLinks(openable: [tv], open: { _ in })
        let attributed = CantripTabMentions.attributed(text, style: .standard, links: links)
        XCTAssertEqual(String(attributed.characters), "Ask @Sony TV now")
        let mentionRun = attributed.runs.first { $0.link != nil }
        XCTAssertEqual(mentionRun?.link, URL(string: "cantrip-tab:\(tv)"))
        XCTAssertEqual(mentionRun?.inlinePresentationIntent, .stronglyEmphasized)
        let unlinked = CantripTabMentions.attributed(text, style: .onAccent)
        XCTAssertTrue(unlinked.runs.allSatisfy { $0.link == nil }, "tabs that can't open aren't links")

        // A long prompt's preview never stops inside a token.
        let long = String(repeating: "a", count: PromptText.previewLimit - 5) + " " + token("Sony TV", tv) + " end"
        let preview = PromptText(long).preview
        XCTAssertTrue(preview.hasSuffix("a "))
        XCTAssertFalse(preview.contains("@["))
    }
}
