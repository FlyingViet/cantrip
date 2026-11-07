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
check(blackScreen.first?.file == "2026-01-03.md" && blackScreen.first?.text.contains("never draws its root view") == true,
      "the conversation around a pasted log is still found: \(blackScreen.map(\.text))")

// 3. Recent entries win ties, and the older copy isn't repeated.
let lantern = try index.search(terms: ["lantern", "supplier", "settle"], now: now)
check(lantern.first?.file == "2026-01-09.md", "the newer of two equal entries wins: \(lantern.map(\.file))")
check(!lantern.contains { $0.file == "2026-01-02.md" }, "a near-identical older entry isn't returned too: \(lantern.map(\.file))")
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
check(try index.search(terms: ["lantern"], now: now).map(\.file) == ["2026-01-02.md"], "and its entries with it")

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

// Removing it deletes the database files; an unusable path fails to open (callers fall back).
MemorySearchIndex.remove(at: dbURL)
check(!FileManager.default.fileExists(atPath: dbURL.path) && !FileManager.default.fileExists(atPath: dbURL.path + "-wal"),
      "remove deletes the index")
let blocked = base.appendingPathComponent("blocked.sqlite")
try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
check((try? MemorySearchIndex(url: blocked)) == nil, "an index that can't open throws")

print("Memory search index tests passed")
