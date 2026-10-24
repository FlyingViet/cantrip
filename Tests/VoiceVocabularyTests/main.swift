import Foundation
import SQLite3

// Made-up names only: this repository is public.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

/// Fixtures live under the folder the Makefile passes in (the build folder), else the temp folder.
private let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_VOCABULARY_TEST_DIR"]
                          ?? FileManager.default.temporaryDirectory.path)
    .appendingPathComponent("voice-vocabulary-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

private typealias V = VoiceVocabulary

private func makeDatabase(_ name: String, _ sql: String) -> String {
    let path = scratch.appendingPathComponent(name).path
    var database: OpaquePointer?
    precondition(sqlite3_open(path, &database) == SQLITE_OK)
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
        fatalError("fixture SQL failed: \(String(cString: error!))")
    }
    sqlite3_close(database)
    return path
}

private func reason(_ work: () throws -> Any) -> String? {
    do {
        _ = try work()
        return nil
    } catch let error as VoiceVocabularySources.Unavailable {
        return error.reason
    } catch {
        return "unexpected \(error)"
    }
}

private func rounded(_ weights: [Double]) -> [Double] { weights.map { ($0 * 1000).rounded() / 1000 } }

private final class Counter {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private let now = Date(timeIntervalSince1970: 1_798_000_000)
private let day: TimeInterval = 86_400

// MARK: Proper-noun phrases

do {
    let cases: [(String, [String])] = [
        ("Kestrel Labs development workflow", ["Kestrel Labs"]),
        ("Orbitly (internal project: Plexo)", ["Orbitly", "Plexo"]),
        ("QuillKit - development and reliability", ["QuillKit"]),
        ("Daily interview tracker", []),
        ("LuméPath TD → native iPhone", ["LuméPath TD"]),
        ("Weekly Orbitly briefing", ["Orbitly"]),
        ("Bank of Plexo account notes", ["Bank of Plexo"]),
        ("Marisol & Quintero catering", ["Marisol & Quintero"]),
        ("Kestrel and friends", ["Kestrel"]),
        ("The Orbitly Times", ["Orbitly Times"]),
        ("Cantrip release builds", ["Cantrip"]),
        ("Plexo's roadmap — Orbitly, Kestrel Labs; QuillKit | Plexo", ["Plexo", "Orbitly", "Kestrel Labs", "QuillKit"]),
        ("Q3 numbers", []),
        ("track 2FA codes for Orbitly", ["2FA", "Orbitly"]),
        ("One Two Three Four Five", []),
        ("Orbitly. Plexo", ["Orbitly", "Plexo"]),
        ("the of and", []),
        ("", []),
        ("Ok", []),
        ("iOS", []),
        ("“Orbitly” launch", ["Orbitly"]),
    ]
    for (title, expected) in cases {
        let phrases = V.properNounPhrases(in: title)
        expect(phrases == expected, "phrases in \"\(title)\": expected \(expected), got \(phrases)")
    }
    expect(V.isNameLike("iOS") && V.isNameLike("QuillKit") && V.isNameLike("TD") && !V.isNameLike("native")
           && !V.isNameLike("2026"), "name-like tokens start with or contain a capital")
}

// MARK: Tabs

do {
    let terms = V.tabTerms(["  Kestrel Labs   development workflow ", "New Tab", "Tab 3", "new chat", "Private Local",
                            "Orbitly", "", "42"])
    expect(terms.map(\.text) == ["Kestrel Labs development workflow", "Kestrel Labs", "Orbitly"],
           "tab names are kept exactly (trimmed) with their proper nouns; generic names are skipped: \(terms.map(\.text))")
    expect(terms.allSatisfy { $0.kind == .project && $0.weight == 0.9 && $0.sources == ["tabs"] },
           "tab terms are projects weighted 0.9")
}

// MARK: Memory notes

do {
    expect(V.firstHeading(in: "intro\n## Sub\n```\n# not a heading\n```\n# Plexo rollout ##\nbody") == "Plexo rollout",
           "the first H1 outside code fences, without closing hashes")
    expect(V.firstHeading(in: "#hashtag\n## Only a subheading") == nil, "no H1")
    expect(V.prettifiedNoteName("orbitly-launch.md") == "Orbitly Launch", "file names are prettified")
    expect(V.prettifiedNoteName("quillKit_notes.md") == "QuillKit Notes", "inner capitals survive prettifying")
    expect(V.prettifiedNoteName("2026-09-15.md") == nil, "dates are not names")
    expect(V.prettifiedNoteName("daily-notes.md") == nil, "all-generic names are skipped")
    expect(V.prettifiedNoteName("a-b-c-d-e.md") == nil, "long file names are descriptions, not names")
    expect(V.noteTerms(fileName: "x.md", heading: "Kestrel Labs procedures").map(\.text) == ["Kestrel Labs"],
           "heading phrases win")
    expect(V.noteTerms(fileName: "orbitly.md", heading: "deploy checklist").map(\.text) == ["Orbitly"],
           "the file name is used when the heading names nothing")

    let vault = scratch.appendingPathComponent("vault")
    let fm = FileManager.default
    try! fm.createDirectory(at: vault.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    func write(_ name: String, _ text: String) {
        try! text.write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    write("MEMORY.md", "# Kestrel Secret Environment\n")
    write("USER.md", "# Marisol Quintero Preferences\n")
    write("sessions/2026-09-15.md", "# Plexo Session\n")
    write(".hidden.md", "# Hidden Orbitly\n")
    write("plexo-rollout.md", "---\ntags: x\n---\n# Plexo rollout with Kestrel Labs\nbody")
    write("orbitly.md", "no heading here")
    write("late-heading.md", String(repeating: "x", count: 5_000) + "\n# Hidden Late Heading\n")
    write("notes.txt", "# Not Markdown\n")
    let outside = scratch.appendingPathComponent("outside.md")
    try! "# Outside Secret\n".write(to: outside, atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(at: vault.appendingPathComponent("link.md"), withDestinationURL: outside)
    let terms = try! VoiceVocabularySources.memoryNoteTerms(directory: vault)
    expect(terms.map(\.text) == ["Late Heading", "Orbitly", "Plexo", "Kestrel Labs"],
           "top-level notes only, first 4 KB, symlinks and core files skipped: \(terms.map(\.text))")
    expect(terms.allSatisfy { $0.kind == .note && $0.weight == 0.7 && $0.sources == ["memory"] }, "note terms")
    expect(reason { try VoiceVocabularySources.memoryNoteTerms(directory: scratch.appendingPathComponent("none")) }
           == "the memory folder doesn't exist", "a missing memory folder is reported")
}

// MARK: Home tasks and workspaces

private let workspaceJSON = """
[
  {"id": "6F9C1E52-0000-4000-8000-000000000001", "title": "Daily interview tracker", "prompt": "unused",
   "workspace": {
     "recordLabel": "Interview", "icon": "person",
     "fields": [
       {"key": "company", "label": "Company", "kind": "text", "required": true},
       {"key": "recruiter", "label": "Recruiter", "kind": "text", "required": false},
       {"key": "contactEmail", "label": "Contact email", "kind": "text", "required": false},
       {"key": "vendorSite", "label": "Vendor site", "kind": "url", "required": false},
       {"key": "salary", "label": "Salary", "kind": "number", "required": false},
       {"key": "appliedOn", "label": "Applied", "kind": "date", "required": false},
       {"key": "stage", "label": "Stage", "kind": "choice", "required": false},
       {"key": "notes", "label": "Notes", "kind": "longText", "required": false}
     ],
     "records": [
       {"values": {"company": "Kestrel Labs", "recruiter": "Marisol Quintero", "contactEmail": "marisol@example.com",
                   "vendorSite": "https://orbitly.example", "salary": "185000", "appliedOn": "2026-10-01",
                   "stage": "Onsite", "notes": "Talked with Dana Whitfield about Plexo."}},
       {"values": {"company": "https://kestrel.example", "recruiter": "Talent Team"}},
       {"values": {"company": "42"}},
       {"values": {"company": "2026-10-24"}},
       {"values": {"company": "Oct 24, 2026"}},
       {"values": {"company": "N/A"}},
       {"values": {"company": "orbitly.com"}},
       {"values": {"company": "+1 (555) 010-2030"}},
       {"values": {"company": "\(String(repeating: "Long", count: 16))"}},
       {"values": {"company": "  Orbitly   Health  "}}
     ]
   }},
  {"id": "6F9C1E52-0000-4000-8000-000000000002", "title": "Kestrel Labs daily briefing", "prompt": "unused"},
  {"id": "6F9C1E52-0000-4000-8000-000000000003", "title": "Bills", "prompt": "unused",
   "workspace": {"recordLabel": "Bill", "icon": "doc",
     "fields": [{"key": "amount", "label": "Amount", "kind": "number", "required": true},
                {"key": "memo", "label": "Memo", "kind": "longText", "required": false}],
     "records": [{"values": {"amount": "12", "memo": "Paid Quintero Plumbing"}}]}}
]
"""

do {
    let tasks = try! JSONDecoder().decode([V.HomeTask].self, from: Data(workspaceJSON.utf8))
    expect(tasks.count == 3 && tasks[1].workspace == nil, "tasks.json decodes into the pure task shape")
    expect(V.entityFields(of: tasks[0].workspace!).map(\.key) == ["company", "recruiter", "contactEmail"],
           "only text fields named like a company/contact are picked")
    expect(V.entityFields(of: tasks[2].workspace!).isEmpty, "a workspace without company/contact fields is skipped")
    expect(V.usableWorkspaceValue("  Kestrel   Labs ") == "Kestrel Labs", "values are trimmed")
    for bad in ["https://kestrel.example", "www.orbitly.example", "marisol@example.com", "42", "$1,200.00",
                "2026-10-24", "2026-10-24T10:00:00Z", "Oct 24, 2026", "24 October 2026", "N/A", "TBD",
                "orbitly.com", "+1 (555) 010-2030", String(repeating: "x", count: 61), "Q3 2026"] {
        expect(V.usableWorkspaceValue(bad) == nil, "\"\(bad)\" is not a name")
    }

    let people: Set<String> = ["Marisol Quintero"]
    var tagged: [String] = []
    let terms = V.homeTaskTerms(tasks) { value in
        tagged.append(value)
        return people.contains(value)
    }
    expect(terms.map(\.text) == ["Kestrel Labs", "Marisol Quintero", "Talent Team", "Orbitly Health", "Kestrel Labs"],
           "titles' proper nouns and company/contact values: \(terms.map(\.text))")
    expect(terms.map(\.kind) == [.company, .person, .company, .company, .task],
           "recruiter values tagged as names are people; the rest are companies")
    expect(terms.map(\.weight) == [0.8, 0.8, 0.8, 0.8, 0.6], "field values weigh 0.8, title phrases 0.6")
    expect(tagged == ["Marisol Quintero", "Talent Team"], "only person-like fields are sent to the name tagger")

    var lengths: [Int] = []
    let fake: V.NameTagger = { text in
        lengths.append(text.count)
        var found: [V.NameEntity] = []
        if text.contains("Dana Whitfield") { found.append(.init(text: "Dana Whitfield", kind: .person)) }
        if text.contains("Plexo") { found.append(.init(text: "Plexo", kind: .company)) }
        if text.contains("Paris") { found.append(.init(text: "Paris", kind: .place)) }
        if text.contains("kestrel") { found.append(.init(text: "kestrel", kind: .company)) }
        return found
    }
    let entities = V.workspaceEntityTerms(tasks, tagger: fake)
    expect(entities.map(\.text) == ["Dana Whitfield", "Plexo"], "names in workspace text: \(entities.map(\.text))")
    expect(entities.map(\.kind) == [.person, .company] && entities.map(\.weight) == [0.5, 0.4],
           "people weigh 0.5, organizations 0.4")
    expect(!lengths.isEmpty && lengths.allSatisfy { $0 <= 2_000 }, "values are truncated before tagging")

    var big = tasks[0]
    big.workspace!.records = (0..<300).map { _ in V.WorkspaceRecord(values: ["notes": String(repeating: "Plexo ", count: 1_000)]) }
    lengths = []
    _ = V.workspaceEntityTerms([big, big], tagger: fake)
    expect(lengths.count == 200 && lengths.allSatisfy { $0 == 2_000 }, "at most 200 records and 2,000 characters each")

    let tagger = VoiceVocabularySources.makeNameTagger()
    expect(!tagger("Marisol Quintero flew to Paris to meet the Kestrel Labs team.").isEmpty,
           "NLTagger finds names in a sentence")
    expect(tagger("").isEmpty, "empty text has no names")
}

// MARK: Handles

do {
    let cases: [(String, String?)] = [
        ("(555) 010-2030", "+15550102030"),
        ("555.010.2030", "+15550102030"),
        ("1-555-010-2030", "+15550102030"),
        ("+1 555 010 2030", "+15550102030"),
        ("+44 20 7946 0958", "+442079460958"),
        ("tel:+33 1 23 45 67 89", "+33123456789"),
        ("0207 946 0958", "+02079460958"),
        (" Marisol@Example.COM ", "marisol@example.com"),
        ("mailto:Dana@Example.org", "dana@example.org"),
        ("72975", nil),
        ("urn:biz:1234567", nil),
        ("not-an-email@", nil),
        ("@example.com", nil),
        ("", nil),
    ]
    for (raw, expected) in cases {
        let actual = V.normalizedHandle(raw)
        expect(actual == expected, "handle \"\(raw)\" -> \(String(describing: expected)), got \(String(describing: actual))")
    }
    expect(V.phoneSuffix("+442079460958") == "2079460958" && V.phoneSuffix("dana@example.org") == nil, "phone suffixes")
}

// MARK: Terms: dedupe, casing, ranking, caps

do {
    let terms = V.mergeTerms([
        .init("Quillkit", .project, 0.9, sources: ["tabs"]),
        .init("quillkit", .note, 0.7, sources: ["memory", "tabs"]),
        .init("QuillKit", .company, 0.4, sources: ["home"]),
        .init("  Orbitly  ", .note, 0.7, sources: ["memory"]),
        .init("orbitly", .project, 0.9, sources: ["tabs"]),
        .init("LuméPath", .task, 0.6, sources: ["home"]),
        .init("Aardvark", .note, 0.7, sources: ["memory"]),
        .init("x", .other, 1, sources: ["tabs"]),
        .init("123", .other, 1, sources: ["tabs"]),
        .init("Too heavy", .other, 7, sources: ["tabs"]),
        .init("Not a number", .other, .nan, sources: ["tabs"]),
    ])
    expect(terms.map(\.text) == ["Too heavy", "Orbitly", "QuillKit", "Aardvark", "LuméPath"],
           "sorted by weight then text, deduped case-insensitively: \(terms.map(\.text))")
    let quill = terms.first { $0.text == "QuillKit" }
    expect(quill?.weight == 0.9 && quill?.kind == .project && quill?.sources == ["tabs", "memory", "home"],
           "the highest weight and its kind win; sources merge; internal capitals win the spelling")
    let orbitly = terms.first { $0.text == "Orbitly" }
    expect(orbitly?.kind == .project && orbitly?.sources == ["memory", "tabs"],
           "kind follows the highest weight; capitalized spelling beats lowercase")
    expect(terms.first?.weight == 1, "weights are clamped to 0...1")
    expect(terms.first { $0.text == "LuméPath" }?.aliases == ["LumePath"], "accented terms get a plain alias")
    expect(terms.first { $0.text == "Aardvark" }?.aliases == [], "plain terms have no aliases")
    expect(V.mergeTerms([.init("NETLIKE", .other, 0.5, sources: ["a"]), .init("NetLike", .other, 0.4, sources: ["b"])])
        .map(\.text) == ["NetLike"], "internal capitals beat all caps")

    let many = (0..<400).map { V.TermCandidate("Term \($0)", .other, Double($0 % 10) / 10, sources: ["tabs"]) }
    let capped = V.mergeTerms(many)
    expect(capped.count == V.maximumTerms, "at most 300 terms")
    expect(zip(capped, capped.dropFirst()).allSatisfy { $0.weight >= $1.weight }, "heaviest terms first")
    expect(capped.first?.weight == 0.9 && capped.last?.weight == 0.2, "the lightest terms are dropped")
}

// MARK: People

do {
    let merged = V.mergePeople([
        .init(name: nil, handles: ["+15550102030"], count: 10, source: "messages"),
        .init(name: "Marisol Quintero", handles: ["(555) 010-2030"], count: 3, source: "calls"),
        .init(name: "marisol quintero", handles: [], count: 2, source: "calendar"),
        .init(name: "Marisol Quintero", handles: ["marisol@example.com"], count: 4, source: "messages"),
        .init(name: nil, handles: ["dana@example.org"], count: 7, source: "messages"),
        .init(name: "Dana Whitfield", handles: ["DANA@example.org", "+1 555 010 9999", "+15550108888",
                                                "+15550107777", "+15550106666"], count: 1, source: "calls"),
        .init(name: nil, handles: ["72975"], count: 50, source: "messages"),
        .init(name: "Spam Risk", handles: ["+15550100000"], count: 2, source: "calls"),
        .init(name: "Conference Room 4", handles: [], count: 9, source: "calendar"),
    ])
    expect(merged.count == 3, "people sharing a handle or a name merge; junk is dropped: \(merged)")
    let marisol = merged[0]
    expect(marisol.name == "Marisol Quintero" && marisol.count == 19, "counts add up across sources")
    expect(marisol.sources == ["messages", "calls", "calendar"], "sources are combined")
    expect(marisol.handles == ["+15550102030", "marisol@example.com"], "handles are normalized and combined")
    let dana = merged[1]
    expect(dana.name == "Dana Whitfield" && dana.count == 8 && dana.handles.count == V.maximumHandlesPerPerson
           && dana.handles.first == "dana@example.org", "at most 4 handles, busiest first: \(dana)")
    expect(merged[2].name == nil && merged[2].handles == ["+15550100000"], "unnamed people keep their handles")

    let crowd = (0..<150).map { V.PersonCandidate(name: nil, handles: ["+1555010\(String(format: "%04d", $0))"],
                                                  count: $0 + 1, source: "messages") }
    let capped = V.mergePeople(crowd)
    expect(capped.count == V.maximumPeople && capped.first?.count == 150, "at most 100 people, busiest first")

    let terms = V.personTerms([
        .init(name: "Marisol Quintero", handles: [], count: 9, sources: ["messages"]),
        .init(name: nil, handles: ["+15550102030"], count: 8, sources: ["messages"]),
        .init(name: "Dana Whitfield", handles: [], count: 5, sources: ["calls"]),
        .init(name: "Rowan Pike", handles: [], count: 1, sources: ["calendar"]),
    ])
    expect(terms.map(\.text) == ["Marisol Quintero", "Dana Whitfield", "Rowan Pike"], "named people become terms")
    expect(rounded(terms.map(\.weight)) == [0.85, 0.675, 0.5] && terms.allSatisfy { $0.kind == .person },
           "weights scale by rank from 0.85 to 0.5: \(terms.map(\.weight))")
    expect(V.personTerms([.init(name: "Rowan Pike", handles: [], count: 1, sources: ["calls"])]).first?.weight == 0.85,
           "a single named person weighs 0.85")

    let resolved = V.resolvingNames([
        .init(name: nil, handles: ["+15550102030"], count: 1, source: "messages"),
        .init(name: nil, handles: ["+442079460958"], count: 1, source: "messages"),
        .init(name: "Old Name", handles: ["dana@example.org"], count: 1, source: "calls"),
        .init(name: nil, handles: ["+15550109999"], count: 1, source: "messages"),
    ], directory: ["+15550102030": "Marisol Quintero", "+02079460958": "Rowan Pike", "dana@example.org": "Dana Whitfield"])
    expect(resolved.map(\.name) == ["Marisol Quintero", "Rowan Pike", "Dana Whitfield", nil],
           "contacts name handles, matching numbers saved without a country code by their last 10 digits")
}

// MARK: Response encoding

do {
    let response = V.response(
        terms: [.init("Orbitly", .project, 0.9, sources: ["tabs"])],
        people: [.init(name: nil, handles: ["+15550102030"], count: 2, source: "messages"),
                 .init(name: "Rowan Pike", handles: [], count: 1, source: "calendar")],
        unavailable: ["calls: Cantrip can't read call history (Full Disk Access is off)"], generatedAt: now)
    let json = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(response)) as! [String: Any]
    expect(json["version"] as? Int == 1 && json["generatedAt"] as? Double == 1_798_000_000, "version and date")
    let people = json["people"] as! [[String: Any]]
    expect(people[0]["name"] == nil && people[0]["handles"] as? [String] == ["+15550102030"]
           && people[0]["sources"] as? [String] == ["messages"] && people[0]["count"] as? Int == 2,
           "unknown names are omitted")
    let terms = json["terms"] as! [[String: Any]]
    expect(terms.map { $0["text"] as! String } == ["Orbitly", "Rowan Pike"], "person names join the terms")
    expect(terms[0]["kind"] as? String == "project" && terms[0]["aliases"] as? [String] == [], "term shape")
    expect(json["unavailable"] as? [String] == response.unavailable, "unavailable sources are listed")
}

// MARK: Messages database

private let messagesNs = { (date: Date) in Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000) }
private let messagesSeconds = { (date: Date) in Int64(date.timeIntervalSinceReferenceDate) }
private let messagesSchema = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, date INTEGER);
"""

do {
    var sql = messagesSchema + """
    INSERT INTO handle VALUES (1, '+15550102030'), (2, '5550102030'), (3, 'Marisol@Example.com'),
                              (4, '+15550109999'), (5, '72975'), (6, '+15550108888');
    """
    func add(_ handle: Int, _ count: Int, _ date: Int64) {
        for _ in 0..<count { sql += "INSERT INTO message (handle_id, date) VALUES (\(handle), \(date));\n" }
    }
    add(1, 5, messagesNs(now.addingTimeInterval(-day)))
    add(2, 3, messagesSeconds(now.addingTimeInterval(-10 * day)))   // seconds since 2001 on old macOS
    add(3, 4, messagesNs(now.addingTimeInterval(-59 * day)))
    add(3, 6, messagesNs(now.addingTimeInterval(-61 * day)))        // too old
    add(4, 9, messagesSeconds(now.addingTimeInterval(-90 * day)))   // too old
    add(5, 20, messagesNs(now))                                      // short code
    add(6, 1, messagesNs(now))
    add(0, 4, messagesNs(now))                                       // no handle
    let path = makeDatabase("chat.db", sql)
    let people = try! VoiceVocabularySources.messagePeople(databasePath: path, now: now)
    expect(people.map(\.handles) == [["+15550102030"], ["marisol@example.com"], ["+15550108888"]],
           "counts the last 60 days per normalized handle: \(people)")
    expect(people.map(\.count) == [8, 4, 1] && people.allSatisfy { $0.source == "messages" && $0.name == nil },
           "nanosecond and second dates both count")
    expect(try! VoiceVocabularySources.messagePeople(databasePath: path, now: now, limit: 2).count == 2,
           "only the busiest handles are kept")
    let before = try! Data(contentsOf: URL(fileURLWithPath: path))
    _ = try! VoiceVocabularySources.messagePeople(databasePath: path, now: now)
    expect(try! Data(contentsOf: URL(fileURLWithPath: path)) == before, "reading never changes the database")

    expect(reason { try VoiceVocabularySources.messagePeople(databasePath: scratch.appendingPathComponent("missing.db").path) }
           == "there's no Messages history on this Mac", "a missing database is reported")
    let garbage = scratch.appendingPathComponent("garbage.db")
    try! Data(repeating: 7, count: 4_096).write(to: garbage)
    expect(reason { try VoiceVocabularySources.messagePeople(databasePath: garbage.path) }
           == "the Messages database format isn't recognized", "a non-database is reported")
    let wrongSchema = makeDatabase("wrong.db", "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT);")
    expect(reason { try VoiceVocabularySources.messagePeople(databasePath: wrongSchema) }
           == "the Messages database format isn't recognized", "an unexpected schema is reported")
    let locked = makeDatabase("locked.db", messagesSchema)
    chmod(locked, 0)
    expect(reason { try VoiceVocabularySources.messagePeople(databasePath: locked) }
           == "Cantrip can't read Messages (Full Disk Access is off)", "an unreadable database is reported as access")
    chmod(locked, 0o600)

    let busy = makeDatabase("busy-chat.db", messagesSchema + """
    INSERT INTO handle VALUES (1, '+15550102030');
    WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 20000)
    INSERT INTO message (handle_id, date) SELECT 1, \(messagesNs(now)) FROM n;
    """)
    expect(reason { try VoiceVocabularySources.messagePeople(databasePath: busy, now: now, deadline: .now()) }
           == VoiceVocabularySources.Unavailable.timedOut.reason, "a query past its deadline stops")
    expect((try? VoiceVocabularySources.messagePeople(databasePath: busy, now: now))?.first?.count == 20_000,
           "the same query finishes without a deadline")
}

// MARK: Call history database

do {
    var sql = "CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZADDRESS VARCHAR, ZNAME VARCHAR, ZDATE TIMESTAMP);\n"
    func add(_ address: String, _ name: String?, _ count: Int, _ date: Date) {
        let nameSQL = name.map { "'\($0)'" } ?? "NULL"
        for _ in 0..<count {
            sql += "INSERT INTO ZCALLRECORD (ZADDRESS, ZNAME, ZDATE) VALUES ('\(address)', \(nameSQL), \(date.timeIntervalSinceReferenceDate));\n"
        }
    }
    add("+15550102030", "Marisol Quintero", 2, now.addingTimeInterval(-day))
    add("(555) 010-2030", nil, 1, now.addingTimeInterval(-2 * day))
    add("dana@example.org", "", 3, now.addingTimeInterval(-3 * day))
    add("+15550109999", "Rowan Pike", 5, now.addingTimeInterval(-70 * day))
    let path = makeDatabase("CallHistory.storedata", sql)
    let people = try! VoiceVocabularySources.callPeople(databasePath: path, now: now)
    expect(people.map(\.handles) == [["dana@example.org"], ["+15550102030"]] && people.map(\.count) == [3, 3],
           "calls in the last 60 days per normalized address: \(people)")
    expect(people.map(\.name) == [nil, "Marisol Quintero"] && people.allSatisfy { $0.source == "calls" },
           "ZNAME is used when present")
    let other = makeDatabase("OtherCalls.storedata", "CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZADDRESS VARCHAR);")
    expect(reason { try VoiceVocabularySources.callPeople(databasePath: other) }
           == "the call history format isn't recognized", "a different schema is reported")
    expect(reason { try VoiceVocabularySources.callPeople(databasePath: scratch.appendingPathComponent("none").path) }
           == "there's no call history on this Mac", "missing call history is reported")
}

// MARK: Bounded sources

do {
    let started = Date()
    let outcomes = VoiceVocabularyService.runBounded([
        ("slow", { _ in Thread.sleep(forTimeInterval: 1.5); return .init() }),
        ("fast", { _ in .init(terms: [.init("Orbitly", .project, 0.9, sources: ["tabs"])]) }),
        ("broken", { _ in throw VoiceVocabularySources.Unavailable("no access") }),
    ], timeout: 0.2)
    expect(Date().timeIntervalSince(started) < 1, "a slow source doesn't hold up the others")
    expect(outcomes.map(\.name) == ["slow", "fast", "broken"], "results keep the sources' order")
    expect(outcomes[0].result == nil, "a source past the timeout has no result")
    if case .success(let output)? = outcomes[1].result {
        expect(output.terms.count == 1, "fast output")
    } else {
        expect(false, "the fast source finishes")
    }
    if case .failure? = outcomes[2].result {} else { expect(false, "a failing source reports its error") }
}

// MARK: Service: assembly and cache

do {
    var clock = now
    let configuration = VoiceVocabularyService.Configuration(
        messagesDatabase: scratch.appendingPathComponent("chat.db"),
        callHistoryDatabase: scratch.appendingPathComponent("missing.storedata"),
        readsCalendar: false, readsContacts: false)
    let service = VoiceVocabularyService(configuration: configuration, now: { clock })
    let tasks = try! JSONDecoder().decode([V.HomeTask].self, from: Data(workspaceJSON.utf8))
    let conversions = Counter()
    let inputs = VoiceVocabularyService.Inputs(
        tabTitles: ["Orbitly", "New Tab"],
        homeTasks: { conversions.bump(); return tasks },
        memoryDirectory: scratch.appendingPathComponent("vault"))
    let (response, reports) = service.compute(inputs)
    expect(reports.map(\.name) == ["tabs", "memory", "home", "home-records", "messages", "calls"],
           "every configured source reports: \(reports.map(\.name))")
    expect(response.version == 1 && response.generatedAt == now.timeIntervalSince1970, "version and date")
    let kinds = Dictionary(grouping: response.terms, by: \.kind)
    expect(kinds[.project]?.map(\.text) == ["Orbitly"], "tab terms: \(kinds[.project] ?? [])")
    expect(kinds[.note]?.isEmpty == false && kinds[.company]?.isEmpty == false, "note and company terms")
    expect(response.terms.first { $0.text == "Kestrel Labs" }.map { Set($0.sources) } == ["home", "memory"],
           "terms found in several sources merge them")
    expect(response.people.map(\.count) == [8, 4, 1], "message people")
    expect(response.unavailable == ["calls: there's no call history on this Mac"], "unavailable: \(response.unavailable)")

    let first = try! service.responseData(for: inputs)
    let conversionsAfterFirst = conversions.value
    clock = now.addingTimeInterval(599)
    expect(service.cachedData() == first, "the response is cached")
    expect(try! service.responseData(for: inputs) == first && conversions.value == conversionsAfterFirst,
           "a cached response reads nothing")
    clock = now.addingTimeInterval(601)
    expect(service.cachedData() == nil, "the cache lasts 10 minutes")
    let second = try! service.responseData(for: inputs)
    expect((try? JSONDecoder().decode(V.Response.self, from: second))?.generatedAt == clock.timeIntervalSince1970,
           "an expired cache is recomputed")

    let empty = VoiceVocabularyService(configuration: configuration).compute(.init())
    expect(empty.response.unavailable.first == "memory: no memory folder is configured",
           "a missing memory setting is reported, not fatal")
}

try? FileManager.default.removeItem(at: scratch)
if failures > 0 {
    fputs("\(failures) voice vocabulary test(s) failed\n", stderr)
    exit(1)
}
print("Voice vocabulary tests passed")
