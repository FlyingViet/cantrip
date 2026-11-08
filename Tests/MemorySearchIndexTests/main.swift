import Foundation

// Focused tests for MemorySearchIndex on a synthetic vault (no real notes or names).
// Each ranking case also runs the old keyword counter (copied below) to show what changed.

func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if (try? condition()) != true {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message())\n".utf8))
        exit(1)
    }
}

/// The keyword retrieval MemoryStore uses when the index is off: whole files ranked by raw
/// term occurrences, then each file's best paragraph.
func keywordRetrieve(vault: URL, terms: [String]) -> [(file: String, chunk: String)] {
    func score(_ text: String) -> Int {
        terms.reduce(0) { total, term in
            var count = 0
            var start = text.startIndex
            while let range = text.range(of: term, range: start..<text.endIndex) { count += 1; start = range.upperBound }
            return total + count
        }
    }
    let fm = FileManager.default
    var files = ((try? fm.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "md" && !["MEMORY.md", "USER.md"].contains($0.lastPathComponent) }
    files += ((try? fm.contentsOfDirectory(at: vault.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(14)
    var scored: [(file: String, score: Int, chunk: String)] = []
    for url in files {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let total = score(text.lowercased())
        guard total > 0 else { continue }
        let best = text.components(separatedBy: "\n\n").max { score($0.lowercased()) < score($1.lowercased()) } ?? text
        scored.append((url.lastPathComponent, total, String(best.prefix(800))))
    }
    return scored.sorted { $0.score > $1.score }.prefix(3).map { ($0.file, $0.chunk) }
}

func write(_ text: String, _ path: String, in vault: URL, modified: Date? = nil) throws {
    let url = vault.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("cantrip-memory-index-\(UUID().uuidString)", isDirectory: true)
let vault = base.appendingPathComponent("vault", isDirectory: true)
let dbURL = base.appendingPathComponent("index/memory-index.sqlite")
try FileManager.default.createDirectory(at: vault.appendingPathComponent("sessions"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = .current
let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!

// MARK: Chunking

let chunks = MemorySearchIndex.chunks(of: """
# Release notes

## Packaging
Build the archive with the release script, then upload it.

```sh
release.sh --upload --token example-token
```

Line one of a paragraph
continues here with more words.

14:24:31.620 [example.subsystem/General] Widget declares video entitlement.
2026-01-05T08:46:17.019Z worker started with seed 42
Retry 1 failed, waiting before the next attempt
Retry 2 failed, waiting before the next attempt
Retry 3 failed, waiting before the next attempt
\(String(repeating: "A", count: 140))

## Packaging
Build the archive with the release script, then upload it.

Line one of a paragraph
continues here with more words.
""", isSession: false, stamp: 0)
check(chunks.count == 1, "the duplicate section is kept once: \(chunks)")
check(chunks.first?.heading == "## Packaging", "chunks carry their heading: \(chunks)")
check(chunks.first?.body.contains("release script") == true && chunks.first?.body.contains("continues here") == true,
      "paragraphs under one heading group into a chunk: \(chunks)")
for skipped in ["--token", "declares video", "worker started", "Retry", "AAAA"] {
    check(chunks.first?.body.contains(skipped) == false, "\(skipped) is left out: \(chunks)")
}
check(MemorySearchIndex.isLogLine("[2026-01-05 08:46:17] up") && !MemorySearchIndex.isLogLine("- 2026-01-05 notes"),
      "timestamps mark log lines; dated bullets aren't")
let long = MemorySearchIndex.chunks(of: (1...60).map { "Sentence number \($0) talks about topic \($0 % 7) in detail." }
    .joined(separator: " "), isSession: false, stamp: 0)
check(long.count > 1 && long.allSatisfy { $0.body.count <= MemorySearchIndex.chunkTarget },
      "a long paragraph is split near the target: \(long.map(\.body.count))")
let entries = MemorySearchIndex.chunks(
    of: "\n## 09:30 · Backend\n**User:** first question about lanterns\n\n**Assistant:** an answer about lanterns\n",
    isSession: true, stamp: 1_000)
check(entries.count == 1 && entries.first?.stamp == 1_000 + 570 * 60 && entries.first?.body.contains("**Assistant:**") == true,
      "a session entry keeps its question and answer together, stamped with its time: \(entries)")

// MARK: Ranking on a synthetic vault

// A short, relevant note.
try write("""
# Deploy waiter

## Restarting it
If the deploy waiter gives up after eight hours of busy tabs, restart the waiter with the
staged build's version. It installs once every tab is idle.
""", "deploy-waiter.md", in: vault)
// A long, loosely related note that mentions "deploy" constantly.
let topics = ["pipeline", "dashboard", "schedule", "checklist", "rollback", "budget", "review", "metrics"]
let verbs = ["discussed", "drafted", "revised", "approved", "postponed", "shared", "archived"]
let teams = ["north", "south", "east", "west"]
var bulk = "# Weekly notes\n"
for week in 0..<120 {
    bulk += "\n## Week \(week)\n"
    for (i, topic) in topics.enumerated() {
        bulk += "- \(verbs[(week + i) % verbs.count].capitalized) the deploy \(topic) for team \(teams[(week + i) % 4]) "
            + "and the deploy notes on \(topics[(i + week) % topics.count]).\n"
    }
}
try write(bulk, "weekly-notes.md", in: vault)
// A session log with a pasted device log.
let pasted = (0..<600).map {
    "14:24:31.\(String(format: "%03d", $0)) [example.carframework/General] Application declares video entitlement."
}
try write("""
## 08:15 · Backend
**User:** The car display shows a black screen; here is the log.

Log lines (600 of 1507):
\(pasted.joined(separator: "\n"))

**Assistant:** The template app never draws its root view, so the car display stays black.
""", "sessions/2026-01-03.md", in: vault)
// The same fact on two days.
let lanternEntry = "## 10:00 · Backend\n**User:** Which lantern supplier did we settle on?\n\n"
    + "**Assistant:** We settled on the harbor lantern supplier for the spring fair.\n"
try write(lanternEntry, "sessions/2026-01-02.md", in: vault)
try write(lanternEntry, "sessions/2026-01-09.md", in: vault)
// A note whose code sample mentions the query; its prose doesn't.
try write("# Shell snippets\n\nHandy commands for the terminal.\n\n```sh\nfrobnicate --quasar --nebula\n```\n",
          "snippets.md", in: vault)
// Core files are always loaded, never retrieved.
try write("# MEMORY\n- deploy waiter restart rules\n", "MEMORY.md", in: vault)

let index = try MemorySearchIndex(url: dbURL)
let first = try index.refresh(vault: vault)
check(first.indexed == 6 && first.removed == 0, "every note and session log is indexed once: \(first)")
let mode = try FileManager.default.attributesOfItem(atPath: dbURL.path)[.posixPermissions] as? Int
check(mode == 0o600, "the index is owner-only: \(String(describing: mode))")

// 1. A huge file no longer crowds out a short relevant note.
let waiterTerms = ["restart", "deploy", "waiter", "gives"]
let oldWaiter = keywordRetrieve(vault: vault, terms: waiterTerms)
check(oldWaiter.first?.file == "weekly-notes.md", "old: the long note wins on word count: \(oldWaiter.map(\.file))")
let waiter = try index.search(terms: waiterTerms, now: now)
check(waiter.first?.file == "deploy-waiter.md" && waiter.first?.text.contains("restart the waiter") == true,
      "new: the short note that answers the question comes first: \(waiter.map(\.file))")
check(!waiter.contains { $0.file == "MEMORY.md" }, "core files aren't retrieved")

// 2. Pasted log lines are skipped.
let videoTerms = ["application", "video", "entitlement", "declares"]
let oldVideo = keywordRetrieve(vault: vault, terms: videoTerms)
check(oldVideo.first?.chunk.contains("Application declares video entitlement") == true,
      "old: the pasted log is the snippet: \(oldVideo)")
let video = try index.search(terms: videoTerms, now: now)
check(!video.contains { $0.text.contains("declares video entitlement") },
      "new: no log line is ever returned: \(video.map(\.text))")
let blackScreen = try index.search(terms: ["car", "display", "black", "screen"], now: now)
check(blackScreen.first?.file == "sessions/2026-01-03.md" && blackScreen.first?.text.contains("never draws its root view") == true,
      "the conversation around a pasted log is still found: \(blackScreen.map(\.text))")

// 3. Recent entries win ties, and the older copy isn't repeated.
let lantern = try index.search(terms: ["lantern", "supplier", "settle"], now: now)
check(lantern.first?.file == "sessions/2026-01-09.md", "the newer of two equal entries wins: \(lantern.map(\.file))")
check(!lantern.contains { $0.file == "sessions/2026-01-02.md" }, "a near-identical older entry isn't returned too: \(lantern.map(\.file))")
check(lantern.first?.snippet(limit: 800).hasPrefix("## 10:00 · Backend\n**User:**") == true, "snippets lead with their heading")
check(lantern.first?.snippet(limit: 20).count == 20, "snippets respect their limit")

// Porter stemming, fenced code, and junk in the query.
check(try index.search(terms: ["restarting", "waiters"], now: now).first?.file == "deploy-waiter.md", "stems match")
check(try index.search(terms: ["quasar", "nebula"], now: now).isEmpty, "fenced code isn't searched")
check(try index.search(terms: ["\"or", "near(", ""], now: now).isEmpty, "query syntax in terms is ignored")
check(try index.search(terms: ["deploy"], limit: 2, now: now).count == 2, "the limit holds")

// MARK: Incremental refresh

check(try index.refresh(vault: vault) == .init(), "unchanged files aren't read again")
try write("# Deploy waiter\n\nThe waiter now retries for twelve hours before it gives up.\n", "deploy-waiter.md", in: vault,
          modified: now)
let changed = try index.refresh(vault: vault)
check(changed.indexed == 1 && changed.removed == 0, "only the edited file is read again: \(changed)")
check(try index.search(terms: ["twelve"], now: now).first?.file == "deploy-waiter.md", "its new text is found")
check(try index.search(terms: ["eight"], now: now).isEmpty, "its old text is gone")
try FileManager.default.removeItem(at: vault.appendingPathComponent("sessions/2026-01-09.md"))
check(try index.refresh(vault: vault).removed == 1, "a deleted file is dropped")
check(try index.search(terms: ["lantern"], now: now).map(\.file) == ["sessions/2026-01-02.md"], "and its entries with it")

// Another vault starts over; reopening keeps the index.
let other = base.appendingPathComponent("other-vault", isDirectory: true)
try write("# Garden\n\nWater the tomatoes every morning.\n", "garden.md", in: other)
check(try index.refresh(vault: other).indexed == 1, "a different vault is indexed from scratch")
check(try index.search(terms: ["deploy"], now: now).isEmpty, "the old vault's chunks are gone")
index.close()
let reopened = try MemorySearchIndex(url: dbURL)
check(try reopened.refresh(vault: other) == .init(), "a reopened index is still current")
check(try reopened.search(terms: ["tomatoes"], now: now).first?.file == "garden.md", "and searchable")
reopened.close()

// MARK: All history: every session log and archive/

let history = base.appendingPathComponent("history-vault", isDirectory: true)
let supplier = "The harbor lantern supplier delivers every Friday before the market opens."
try write("# Lanterns\n\n## Supplier\n\(supplier)\n", "lanterns.md", in: history)
try write("""
# Lanterns (history)

## Supplier
\(supplier)

## Glassworks
In March the glassworks kiln cracked, and the replacement kiln came from the ridge foundry.
""", "archive/lanterns-history.md", in: history)
try write("# Ferry (older)\n\nThe dock crane was repainted green after the storm season.\n",
          "archive/2025/ferry-history.md", in: history)
// Fifteen recent days of unrelated chat, then one older day with the answer.
for day in 1...15 {
    try write("## 09:00 · Backend\n**User:** How often should the garden beds be watered in week \(day)?\n\n"
              + "**Assistant:** Water the raised garden beds every \(["morning", "evening", "other day"][day % 3]).\n",
              "sessions/2026-01-\(String(format: "%02d", day)).md", in: history)
}
try write("## 18:20 · Backend\n**User:** When does the ferry switch timetables?\n\n"
          + "**Assistant:** The ferry timetable changes to the winter schedule on the first Monday of November.\n",
          "sessions/2025-10-02.md", in: history)
// A large unrelated note that keeps saying "kiln".
var kilnBulk = "# Pottery log\n"
for week in 0..<150 {
    kilnBulk += "\n## Batch \(week)\n- Loaded the kiln with \(["bowls", "mugs", "plates", "vases"][week % 4]) "
        + "glazed in \(["blue", "white", "rust", "green", "sand"][week % 5]); the kiln ran \(["hot", "even", "slow"][week % 3]).\n"
}
try write(kilnBulk, "pottery-log.md", in: history)

let all = try MemorySearchIndex(url: base.appendingPathComponent("history/memory-index.sqlite"))
let built = try all.refresh(vault: history)
check(built.indexed == 20, "both notes, all 16 session logs and both archive files are indexed: \(built)")

let kilnTerms = ["glassworks", "kiln", "cracked", "replacement"]
check(!keywordRetrieve(vault: history, terms: kilnTerms).contains { $0.file.contains("history") },
      "old: archive/ is never searched: \(keywordRetrieve(vault: history, terms: kilnTerms).map(\.file))")
let kiln = try all.search(terms: kilnTerms, now: now)
check(kiln.first?.file == "archive/lanterns-history.md" && kiln.first?.kind == .archive
      && kiln.first?.text.contains("ridge foundry") == true,
      "new: the archived paragraph is found, ahead of the large note that only repeats one word: \(kiln.map(\.file))")

let ferryTerms = ["ferry", "timetable", "winter", "schedule"]
check(keywordRetrieve(vault: history, terms: ferryTerms).isEmpty,
      "old: a session log older than the 14 newest is never searched")
let ferry = try all.search(terms: ferryTerms, now: now)
check(ferry.first?.file == "sessions/2025-10-02.md" && ferry.first?.text.contains("first Monday of November") == true,
      "new: the older session entry is found: \(ferry.map(\.file))")
check(try all.search(terms: ["crane", "repainted"], now: now).first?.file == "archive/2025/ferry-history.md",
      "archive subfolders are indexed and hits keep their path")

let tie = try all.search(terms: ["harbor", "lantern", "supplier", "friday"], now: now)
check(tie.first?.file == "lanterns.md" && !tie.contains { $0.file == "archive/lanterns-history.md" },
      "on a tie the current note wins and the archived copy isn't repeated: \(tie.map(\.file))")
check(MemorySearchIndex.archiveWeight < MemorySearchIndex.noteWeight, "archive ranks just below notes")
check(try all.search(terms: ["kiln", "garden", "ferry", "lantern", "crane"], now: now).count == 3,
      "still at most three snippets")
all.close()

// MARK: Follow-ups: the previous exchange joins the query

let follow = base.appendingPathComponent("follow-vault", isDirectory: true)
try write("# Kiln schedule\n\n## Firing\nBisque firings run on a slow overnight schedule. Glaze firings use the "
          + "cone six program with a short hold, then cool with the lid closed.\n", "kiln-schedule.md", in: follow)
try write("# Laptop boot\n\nTo make the laptop boot faster, remove login items and keep the disk under eighty "
          + "percent full.\n", "laptop-boot.md", in: follow)
try write("# Garden\n\nWater the raised garden beds every other morning; mulch keeps them from drying out.\n",
          "garden.md", in: follow)
let followIndex = try MemorySearchIndex(url: base.appendingPathComponent("follow/memory-index.sqlite"))
try followIndex.refresh(vault: follow)
let kilnTurn = ConversationTurn(
    user: "How should we schedule the kiln firings for the glaze batch?",
    assistant: """
    Checking the kiln notes first.

    Run the glaze batch on the cone six kiln program with a short hold. The bisque firing stays on the slow
    overnight schedule, so the kiln is free for the glaze firing by morning.

    ![Kiln chart](/Users/someone/shots/laptop-boot.png) [schedule](https://example.com/laptop/boot)

    ```card
    {"title": "Laptop boot decoy card"}
    ```
    """)

func weighted(_ query: MemoryQuery) -> [(word: String, weight: Double)] { query.terms.map { ($0.word, $0.weight) } }

let vague = MemoryQuery(message: "Will that make it faster?", previous: kilnTurn)
let previousWords = vague.terms.filter { $0.weight < 1 }.map(\.word)
check(vague.terms.first == .init(word: "faster", weight: 1), "the message's own words lead, at full weight: \(vague.terms)")
check(previousWords.count <= MemoryQuery.previousTermLimit && previousWords.prefix(3).contains("kiln")
      && previousWords.contains("schedule") && previousWords.contains("glaze"),
      "the previous exchange adds its topic words at a lower weight: \(previousWords)")
for noise in ["laptop", "boot", "decoy", "card", "checking", "users", "someone", "https", "example"] {
    check(!vague.words.contains(noise), "\(noise) isn't conversation text: \(vague.words)")
}
check(try followIndex.search(terms: ["faster"], now: now).first?.file == "laptop-boot.md",
      "the message alone finds an unrelated note")
check(try followIndex.search(weighted: weighted(vague), now: now).first?.file == "kiln-schedule.md",
      "with the previous exchange, a vague follow-up finds its topic")
let newTopic = MemoryQuery(message: "How often should the raised garden beds be watered?", previous: kilnTurn)
check(try followIndex.search(weighted: weighted(newTopic), now: now).first?.file == "garden.md",
      "a message that changes the subject finds its own topic first")
check(MemoryQuery(message: "Will that make it faster?").terms == [.init(word: "faster", weight: 1)],
      "without a previous exchange the query is the message alone")
check(MemoryQuery(message: "Kiln kiln schedule", previous: kilnTurn).terms.filter { $0.word == "kiln" }.count == 1,
      "a word in the message isn't added again from the previous exchange")

// Blocks Cantrip adds around a message never enter the query.
let wrapped = """
Context - selected earlier turns only (not the full transcript):
User: earlier laptop question
New message:
(Context: this message comes from a paired device that isn't sharing its location. Use the Mac's location.)

What about the kiln?

(Persistent memory — three layers, all in /vault:
CORE — laptop boot notes
RETRIEVED — memory snippets auto-matched to this query (verify before relying on them):
— from laptop-boot.md:
laptop boot faster)
"""
check(MemoryQuery(message: wrapped).words == ["kiln"], "only the message's own words: \(MemoryQuery(message: wrapped).words)")
let retrievedReply = ConversationTurn(user: "What's next?", assistant: "Sure.\n\nRETRIEVED — memory snippets auto-matched:\n— from laptop-boot.md:\nlaptop boot")
check(!MemoryQuery(message: "and then?", previous: retrievedReply).words.contains("laptop"),
      "RETRIEVED snippets in an earlier turn are skipped")
followIndex.close()

// Removing it deletes the database files; an unusable path fails to open (callers fall back).
MemorySearchIndex.remove(at: dbURL)
check(!FileManager.default.fileExists(atPath: dbURL.path) && !FileManager.default.fileExists(atPath: dbURL.path + "-wal"),
      "remove deletes the index")
let blocked = base.appendingPathComponent("blocked.sqlite")
try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
check((try? MemorySearchIndex(url: blocked)) == nil, "an index that can't open throws")

print("Memory search index tests passed")
