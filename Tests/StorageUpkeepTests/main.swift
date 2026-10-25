import Darwin
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let fm = FileManager.default
private let root = URL(fileURLWithPath: StorageUpkeep.resolved(fm.temporaryDirectory.path))
    .appendingPathComponent("cantrip-storage-upkeep-tests-\(UUID().uuidString)")
private let home = root.appendingPathComponent("home")
private let sessionRoot = home.appendingPathComponent(".copilot/session-state")
private let cache = home.appendingPathComponent(".cache/Cantrip")
private let coding = home.appendingPathComponent("Coding")
private let vault = root.appendingPathComponent("memory")
/// Fixtures are made now; the cleanup runs as if 30 days had passed.
private let realNow = Date()
private let testNow = realNow.addingTimeInterval(30 * 86_400)
/// Inside the 14-day session and 3-day worktree windows of `testNow`.
private let recently = realNow.addingTimeInterval(29 * 86_400)
defer { try? fm.removeItem(at: root) }

@discardableResult
private func git(_ arguments: [String], in directory: URL? = nil, date: Date? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                         "-c", "init.defaultBranch=main", "-c", "advice.detachedHead=false"]
        + (directory.map { ["-C", $0.path] } ?? []) + arguments
    var environment = ProcessInfo.processInfo.environment
    if let date {
        environment["GIT_AUTHOR_DATE"] = "@\(Int(date.timeIntervalSince1970)) +0000"
        environment["GIT_COMMITTER_DATE"] = "@\(Int(date.timeIntervalSince1970)) +0000"
    }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        failures += 1
        fputs("FAIL: git \(arguments.joined(separator: " ")): \(output)\n", stderr)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func write(_ text: String, to url: URL, modified: Date? = nil) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
    if let modified { try! fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

private func session(_ setup: (URL) -> Void = { _ in }) -> URL {
    let folder = sessionRoot.appendingPathComponent(UUID().uuidString.lowercased())
    write("id: x\ncwd: /tmp\nclient_name: test\nname: fixture\n", to: folder.appendingPathComponent("workspace.yaml"))
    write("{}\n", to: folder.appendingPathComponent("events.jsonl"))
    try! fm.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
    setup(folder)
    return folder
}

private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

private func deadPID() -> pid_t {
    var pid: pid_t = 99_999
    while kill(pid, 0) == 0 || errno != ESRCH { pid -= 1 }
    return pid
}

// MARK: - Pure helpers

do {
    let entries = StorageUpkeep.parseWorktrees("""
    worktree /repo
    HEAD aaa
    branch refs/heads/main

    worktree /tmp/wt
    HEAD bbb
    detached
    locked agent busy

    worktree /gone
    HEAD ccc
    branch refs/heads/old
    prunable gitdir file points to non-existent location

    """)
    expect(entries.count == 3, "porcelain lists three worktrees")
    expect(entries[1].branch == nil && entries[1].locked && entries[1].head == "bbb", "detached, locked entry parsed")
    expect(entries[2].prunable && entries[2].branch == "refs/heads/old", "prunable entry parsed")

    write("Kit in session 9fd0ee72 files/qa; commit a9fd5a0; id 1F936B2B-800D-4B7B-8D27-E80BFA2875E4; deadbeef1",
          to: vault.appendingPathComponent("notes.md"))
    write("session 12345678 should be ignored outside notes", to: vault.appendingPathComponent("data.txt"))
    let tokens = StorageUpkeep.noteTokens(vault) ?? []
    expect(tokens.contains("9fd0ee72") && tokens.contains("1f936b2b"), "notes name sessions by 8-character prefix")
    expect(!tokens.contains("a9fd5a0") && !tokens.contains("deadbeef") && !tokens.contains("12345678"),
           "7-digit hashes, longer words and non-Markdown files don't count")

    expect(StorageUpkeep.isUnder("/tmp/x/wt", [URL(fileURLWithPath: "/private/tmp")]), "/tmp matches /private/tmp")
    expect(!StorageUpkeep.isUnder("/private/tmpfoo/wt", [URL(fileURLWithPath: "/private/tmp")]), "prefix needs a separator")

    var report = StorageUpkeep.Report(startedAt: realNow, finishedAt: realNow, dryRun: false, sessionRetentionDays: 14)
    expect(report.summary == "Nothing needed cleaning up.", "empty summary")
    report.sessionsRemoved = 2
    report.sessionBytesRemoved = 2_000_000
    report.worktreesRemoved = [StorageUpkeep.Worktree(path: "/a", repository: "/r", bytes: 1_000_000)]
    expect(report.summary.hasPrefix("Removed 2 unused sessions (") && report.summary.contains("and 1 worktree ("),
           "summary names both: \(report.summary)")
}

// MARK: - Fixtures

let remote = root.appendingPathComponent("remote.git")
git(["init", "-q", "--bare", remote.path])
let project = coding.appendingPathComponent("proj")
git(["init", "-q", project.path])
write("node_modules/\n", to: project.appendingPathComponent(".gitignore"))
write("hello\n", to: project.appendingPathComponent("README.md"))
git(["add", "."], in: project)
git(["commit", "-q", "-m", "first"], in: project)
git(["remote", "add", "origin", remote.path], in: project)
git(["push", "-q", "origin", "main"], in: project)

func worktree(_ name: String, _ arguments: [String] = ["--detach"], under base: URL = cache) -> URL {
    let path = base.appendingPathComponent(name)
    git(["worktree", "add", "-q"] + arguments + [path.path], in: project)
    return path
}

let detachedSaved = worktree("saved-worktree")
let branchWithCommits = worktree("feature-worktree", ["-b", "feature"])
write("feature\n", to: branchWithCommits.appendingPathComponent("feature.txt"))
git(["add", "."], in: branchWithCommits)
git(["commit", "-q", "-m", "feature work"], in: branchWithCommits)
let dirty = worktree("dirty-worktree")
write("draft\n", to: dirty.appendingPathComponent("draft.txt"))
let detachedUnique = worktree("unique-worktree")
write("only here\n", to: detachedUnique.appendingPathComponent("unique.txt"))
git(["add", "."], in: detachedUnique)
git(["commit", "-q", "-m", "detached work"], in: detachedUnique)
let locked = worktree("locked-worktree")
git(["worktree", "lock", locked.path], in: project)
let touched = worktree("touched-worktree")
try! fm.setAttributes([.modificationDate: recently], ofItemAtPath: touched.appendingPathComponent("README.md").path)
let committed = worktree("committed-worktree", ["-b", "recent"])
write("recent\n", to: committed.appendingPathComponent("recent.txt"))
git(["add", "."], in: committed)
git(["commit", "-q", "-m", "recent work"], in: committed, date: recently)
let withIgnored = worktree("ignored-worktree")
write("dependency\n", to: withIgnored.appendingPathComponent("node_modules/pkg/index.js"))
let busy = worktree("busy-worktree")
let outside = worktree("proj-review", under: coding)
let missing = worktree("missing-worktree")
try! fm.removeItem(at: missing)

// Sessions.
let old = session { write("output\n", to: $0.appendingPathComponent("files/out.txt")) }
let recent = session { write("new\n", to: $0.appendingPathComponent("files/new.txt"), modified: recently) }
let referenced = session()
let linked = session()
write(#"[{"role":"assistant","text":"![shot](\/Users\/me\/.copilot\/session-state\/\#(linked.lastPathComponent)\/files\/a.png)"}]"#,
      to: cache.appendingPathComponent("chats/\(UUID().uuidString).json"))
let noted = session()
write("QA kit: session \(noted.lastPathComponent.prefix(8)) files/qa\n", to: vault.appendingPathComponent("tools.md"))
let liveLock = session { write("\(getpid())", to: $0.appendingPathComponent("inuse.\(getpid()).lock")) }
let deadLock = session { write("1", to: $0.appendingPathComponent("inuse.\(deadPID()).lock")) }
let dirtyRepo = session { folder in
    let repo = folder.appendingPathComponent("files/scratch")
    git(["init", "-q", repo.path])
    write("notes\n", to: repo.appendingPathComponent("todo.txt"))
}
let pushedClone = session { git(["clone", "-q", remote.path, $0.appendingPathComponent("files/clone").path]) }
let unpushedClone = session { folder in
    let clone = folder.appendingPathComponent("files/clone")
    git(["clone", "-q", remote.path, clone.path])
    write("local\n", to: clone.appendingPathComponent("local.txt"))
    git(["add", "."], in: clone)
    git(["commit", "-q", "-m", "local only"], in: clone)
}
let stashed = session { folder in
    let clone = folder.appendingPathComponent("files/clone")
    git(["clone", "-q", remote.path, clone.path])
    write("changed\n", to: clone.appendingPathComponent("README.md"))
    git(["stash", "-q"], in: clone)
}
let readOnly = session { folder in
    let module = folder.appendingPathComponent("files/go/pkg/mod/example@v1")
    write("package x\n", to: module.appendingPathComponent("x.go"))
    chmod(module.appendingPathComponent("x.go").path, 0o444)
    chmod(module.path, 0o555)
}
let processCwd = session { write("x\n", to: $0.appendingPathComponent("files/work/a.txt")) }
let worktreeHost = session { folder in
    let base = folder.appendingPathComponent("files/base")
    git(["clone", "-q", remote.path, base.path])
    git(["worktree", "add", "-q", "--detach", root.appendingPathComponent("elsewhere/wt").path], in: base)
}
let generated = session { folder in
    let package = folder.appendingPathComponent("files/app/node_modules/pkg")
    git(["init", "-q", package.path])
    write("x\n", to: package.appendingPathComponent("untracked.js"))
}
let sessionWorktree = session {
    git(["worktree", "add", "-q", "--detach", $0.appendingPathComponent("files/wt").path], in: project)
}
// Unborn HEAD: a new orphan branch hides `main`, whose commit exists nowhere else.
let orphanBranch = session { folder in
    let repo = folder.appendingPathComponent("files/orphan")
    git(["init", "-q", repo.path])
    write("only copy\n", to: repo.appendingPathComponent("a.txt"))
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "only copy"], in: repo)
    git(["switch", "-q", "--orphan", "docs"], in: repo)
}
// A clone in a folder that happens to be called "checkouts" is real work.
let checkoutsFolder = session { folder in
    let repo = folder.appendingPathComponent("files/checkouts/myrepo")
    git(["clone", "-q", remote.path, repo.path])
    write("draft\n", to: repo.appendingPathComponent("draft.txt"))
}
// A bare repository used as a local remote holds the only copy of what was pushed to it.
let bareRemote = session { folder in
    let bare = folder.appendingPathComponent("files/origin.git")
    git(["init", "-q", "--bare", bare.path])
    git(["push", "-q", bare.path, "main"], in: project)
}
// A tab's session keeps its worktree, however long it sits idle.
let tabWorktreeSession = session {
    git(["worktree", "add", "-q", "--detach", $0.appendingPathComponent("files/tab-wt").path], in: project)
}
let notASession = sessionRoot.appendingPathComponent("notes")
write("keep\n", to: notASession.appendingPathComponent("a.txt"))
let uppercase = sessionRoot.appendingPathComponent(UUID().uuidString)
write("keep\n", to: uppercase.appendingPathComponent("a.txt"))

write(#"{"version":1,"backfilled":true,"sessions":{"\#(UUID().uuidString)":["\#(referenced.lastPathComponent)","\#(tabWorktreeSession.lastPathComponent)"]}}"#,
      to: cache.appendingPathComponent("session-output-folders.json"))

let configuration = StorageUpkeep.Configuration(
    sessionRoot: sessionRoot,
    outputFolders: cache.appendingPathComponent("session-output-folders.json"),
    transcriptFolders: [cache.appendingPathComponent("chats"), cache.appendingPathComponent("home")],
    memoryVault: vault,
    repositoryParents: [coding, home],
    worktreeSearchRoots: [cache],
    agentRoots: [sessionRoot, cache],
    stateDirectory: cache,
    sessionRetention: 14 * 86_400,
    now: testNow,
    processes: {
        StorageUpkeep.ProcessSnapshot(
            workingDirectories: [processCwd.appendingPathComponent("files/work").path],
            commandLines: ["tail -f \(busy.path)/README.md"]
        )
    }
)

let sessionsRemoved = [old, deadLock, pushedClone, readOnly, generated, sessionWorktree]
let sessionsKept = [recent, referenced, linked, noted, liveLock, dirtyRepo, unpushedClone, stashed, processCwd, worktreeHost,
                    orphanBranch, checkoutsFolder, bareRemote, tabWorktreeSession, notASession, uppercase]
let worktreesRemoved = [detachedSaved, branchWithCommits, withIgnored, sessionWorktree.appendingPathComponent("files/wt")]
let expectedKept: [URL: String] = [
    dirty: "1 uncommitted file", detachedUnique: "detached commits on no branch", locked: "locked",
    touched: "changed in the last 3 days", committed: "committed to in the last 3 days",
    busy: "in use by a running process",
    tabWorktreeSession.appendingPathComponent("files/tab-wt"): "its session belongs to a tab or Home run",
]

// MARK: - Dry run

do {
    var lines: [String] = []
    guard let report = StorageUpkeep.perform(configuration, dryRun: true, log: { lines.append($0) }) else {
        fatalError("dry run should get the lock")
    }
    expect(report.dryRun && report.sessionsRemoved == sessionsRemoved.count,
           "dry run counts \(sessionsRemoved.count) sessions: \(report.sessionsRemoved) \(report.sessionsKept)")
    expect(report.worktreesRemoved.count == worktreesRemoved.count,
           "dry run counts \(worktreesRemoved.count) worktrees: \(report.worktreesRemoved.map(\.path))")
    expect((sessionsRemoved + worktreesRemoved).allSatisfy(exists), "a dry run deletes nothing")
    expect(git(["worktree", "list", "--porcelain"], in: project).contains("missing-worktree"),
           "a dry run prunes no worktree records")
    expect(!exists(cache.appendingPathComponent("storage-upkeep.json"))
           && !exists(cache.appendingPathComponent("storage-upkeep.log")), "a dry run saves no report or log")
    expect(lines.contains { $0.hasPrefix("session \(old.lastPathComponent) would remove") }, "dry run lists sessions")
    expect(report.summary.hasPrefix("Would remove "), "dry run summary: \(report.summary)")
}

// MARK: - Unreadable protections stop the sweep

do {
    var missingVault = configuration
    missingVault.memoryVault = root.appendingPathComponent("unmounted-vault")
    let report = StorageUpkeep.perform(missingVault, dryRun: true)
    expect(report?.sessionsRemoved == 0 && report?.worktreesRemoved.isEmpty == true
           && report?.errors.first?.contains("memory folder") == true,
           "a vault that can't be read stops the cleanup: \(report?.errors ?? [])")

    let link = root.appendingPathComponent("vault-link")
    try! fm.createSymbolicLink(at: link, withDestinationURL: vault)
    var linkedVault = configuration
    linkedVault.memoryVault = link
    let viaLink = StorageUpkeep.perform(linkedVault, dryRun: true)
    expect(viaLink?.sessionsKept["note"] == 1 && viaLink?.errors.isEmpty == true, "a symlinked vault is followed")

    let records = cache.appendingPathComponent("session-output-folders.json")
    let saved = try! Data(contentsOf: records)
    try! Data("not json".utf8).write(to: records)
    let unreadable = StorageUpkeep.perform(configuration, dryRun: true)
    expect(unreadable?.sessionsRemoved == 0 && unreadable?.errors.isEmpty == false,
           "an unreadable tab record stops the cleanup")
    try! saved.write(to: records)
}

// MARK: - Real run

do {
    // Another cleanup holds the lock: this one doesn't run.
    let lockPath = cache.appendingPathComponent("storage-upkeep.lock").path
    let held = open(lockPath, O_CREAT | O_RDWR, 0o600)
    flock(held, LOCK_EX)
    expect(StorageUpkeep.perform(configuration, dryRun: false) == nil, "a second cleanup doesn't run at the same time")
    flock(held, LOCK_UN)
    close(held)

    guard let report = StorageUpkeep.perform(configuration, dryRun: false) else { fatalError("lock released") }
    for folder in sessionsRemoved { expect(!exists(folder), "removed \(folder.lastPathComponent)") }
    for folder in sessionsKept { expect(exists(folder), "kept \(folder.lastPathComponent)") }
    expect(report.sessionsRemoved == sessionsRemoved.count, "removed \(sessionsRemoved.count) sessions: \(report.sessionsRemoved)")
    expect(report.sessionBytesRemoved > 0, "removed bytes are measured")
    let kept = report.sessionsKept
    expect(kept["recent"] == 1 && kept["tab"] == 3 && kept["note"] == 1 && kept["inUse"] == 2 && kept["unsavedWork"] == 7,
           "kept sessions by reason: \(kept)")

    for path in worktreesRemoved { expect(!exists(path), "removed worktree \(path.lastPathComponent)") }
    expect(report.worktreesRemoved.count == worktreesRemoved.count, "report lists the removed worktrees")
    expect(git(["rev-parse", "--verify", "-q", "feature"], in: project).count == 40,
           "a removed worktree's branch and commits stay in the repository")
    for (path, reason) in expectedKept {
        expect(exists(path), "kept worktree \(path.lastPathComponent)")
        let entry = report.worktreesKept.first { StorageUpkeep.resolved($0.path) == StorageUpkeep.resolved(path.path) }
        expect(entry?.reason == reason, "\(path.lastPathComponent) kept because \(reason): \(entry?.reason ?? "not listed")")
    }
    expect(exists(outside) && !report.worktreesKept.contains { $0.path.hasSuffix("proj-review") },
           "worktrees outside agent folders are never considered")
    expect(!git(["worktree", "list", "--porcelain"], in: project).contains("missing-worktree"),
           "a missing agent worktree's record is pruned")
    expect(report.prunedRepositories.count == 1, "one repository pruned: \(report.prunedRepositories)")
    expect(report.errors.isEmpty, "no errors: \(report.errors)")

    let saved = StorageUpkeep.lastReport(in: cache)
    expect(saved?.sessionsRemoved == report.sessionsRemoved && saved?.dryRun == false, "the report is saved")
    let log = (try? String(contentsOf: cache.appendingPathComponent("storage-upkeep.log"), encoding: .utf8)) ?? ""
    expect(log.contains("session \(old.lastPathComponent) removed") && log.contains("test in /tmp: fixture"),
           "each removal is logged with what made it")
    expect(log.contains("feature-worktree removed") && log.contains("branch feature"), "worktree removals are logged")

    let again = StorageUpkeep.perform(configuration, dryRun: false)
    expect(again?.sessionsRemoved == 0 && again?.worktreesRemoved.isEmpty == true, "a second run removes nothing")
}

// MARK: - Same-run removal with the real clock

do {
    // A session whose only content is an idle, saved worktree goes in the same run as the worktree:
    // removing the worktree must not make the session look recently used.
    let base = root.appendingPathComponent("clock")
    let sessions = base.appendingPathComponent("session-state")
    let repo = base.appendingPathComponent("repo")
    let monthAgo = realNow.addingTimeInterval(-30 * 86_400)
    git(["init", "-q", repo.path])
    write("x\n", to: repo.appendingPathComponent("a.txt"))
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "old"], in: repo, date: monthAgo)
    let id = UUID().uuidString.lowercased()
    let folder = sessions.appendingPathComponent(id)
    try! fm.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
    git(["worktree", "add", "-q", "--detach", folder.appendingPathComponent("files/wt").path], in: repo)
    // Age everything, deepest first so setting a child doesn't refresh its parent.
    let items = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) + [folder]
    for item in items.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
        try? fm.setAttributes([.modificationDate: monthAgo], ofItemAtPath: item.path)
    }
    let clock = StorageUpkeep.Configuration(
        sessionRoot: sessions, outputFolders: base.appendingPathComponent("none.json"), memoryVault: nil,
        repositoryParents: [base], worktreeSearchRoots: [], agentRoots: [sessions], stateDirectory: base,
        sessionRetention: 14 * 86_400, processes: { StorageUpkeep.ProcessSnapshot(workingDirectories: [], commandLines: []) }
    )
    let report = StorageUpkeep.perform(clock, dryRun: false)
    expect(report?.worktreesRemoved.count == 1 && report?.sessionsRemoved == 1 && !exists(folder),
           "worktree and its session go together: \(report?.sessionsKept ?? [:]) \(report?.worktreesKept ?? [])")
}

// MARK: - Live process inventory

do {
    let snapshot = StorageUpkeep.ProcessSnapshot.current()
    expect(!snapshot.commandLines.isEmpty && !snapshot.workingDirectories.isEmpty, "running processes are listed")
    expect(snapshot.isAlive(getppid()) && !snapshot.isAlive(deadPID()), "process liveness")
}

if failures == 0 {
    print("Storage upkeep tests passed")
} else {
    exit(1)
}
