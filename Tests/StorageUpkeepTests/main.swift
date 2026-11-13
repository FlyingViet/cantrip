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

// Build output in a worktree that stays: a dirty branch with a commit nowhere else.
let wip = worktree("wip-worktree", ["-b", "wip"])
write("wip\n", to: wip.appendingPathComponent("wip.txt"))
git(["add", "."], in: wip)
git(["commit", "-q", "-m", "wip work"], in: wip)
write("draft\n", to: wip.appendingPathComponent("draft.txt"))
write("dependency\n", to: wip.appendingPathComponent("node_modules/pkg/index.js"))
// An open tab works in this one: nothing in it is touched.
let tabOpen = worktree("tab-open-worktree")
write("dependency\n", to: tabOpen.appendingPathComponent("node_modules/pkg/index.js"))

// Submodules: the project embeds a library from its own remote.
let libRemote = root.appendingPathComponent("lib.git")
git(["init", "-q", "--bare", libRemote.path])
let libSeed = root.appendingPathComponent("lib-seed")
git(["init", "-q", libSeed.path])
write("lib\n", to: libSeed.appendingPathComponent("lib.txt"))
git(["add", "."], in: libSeed)
git(["commit", "-q", "-m", "lib"], in: libSeed)
git(["remote", "add", "origin", libRemote.path], in: libSeed)
git(["push", "-q", "origin", "main"], in: libSeed)
let allowFiles = ["-c", "protocol.file.allow=always"]
git(allowFiles + ["submodule", "--quiet", "add", libRemote.path, "lib"], in: project)
git(["commit", "-q", "-m", "add lib"], in: project)
git(["push", "-q", "origin", "main"], in: project)
// Clean and pushed with its submodule checked out: git won't remove it, so the folder goes and its record is pruned.
let withSubmodule = worktree("submodule-worktree")
git(allowFiles + ["submodule", "--quiet", "update", "--init"], in: withSubmodule)
// Its submodule holds a commit nowhere else (and the worktree a commit recording it).
let subUnpushed = worktree("submodule-unpushed-worktree")
git(allowFiles + ["submodule", "--quiet", "update", "--init"], in: subUnpushed)
write("local\n", to: subUnpushed.appendingPathComponent("lib/local.txt"))
git(["add", "."], in: subUnpushed.appendingPathComponent("lib"))
git(["commit", "-q", "-m", "local lib work"], in: subUnpushed.appendingPathComponent("lib"))
git(["add", "lib"], in: subUnpushed)
git(["commit", "-q", "-m", "bump lib"], in: subUnpushed)
// A worktree of the submodule's own repository (proj/.git/modules/lib), where child tabs keep theirs.
let moduleWorktree = cache.appendingPathComponent("worktrees/lib-worktree")
git(["worktree", "add", "-q", "--detach", moduleWorktree.path], in: project.appendingPathComponent("lib"))

write(#"{"version":1,"backfilled":true,"sessions":{"\#(UUID().uuidString)":["\#(referenced.lastPathComponent)","\#(tabWorktreeSession.lastPathComponent)"]}}"#,
      to: cache.appendingPathComponent("session-output-folders.json"))

let configuration = StorageUpkeep.Configuration(
    sessionRoot: sessionRoot,
    outputFolders: cache.appendingPathComponent("session-output-folders.json"),
    transcriptFolders: [cache.appendingPathComponent("chats"), cache.appendingPathComponent("home")],
    memoryVault: vault,
    repositoryParents: [coding, home],
    worktreeSearchRoots: [cache, cache.appendingPathComponent("worktrees")],
    agentRoots: [sessionRoot, cache],
    stateDirectory: cache,
    sessionRetention: 14 * 86_400,
    protectedPaths: [tabOpen.path],
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
let worktreesRemoved = [detachedSaved, branchWithCommits, withIgnored, sessionWorktree.appendingPathComponent("files/wt"),
                        withSubmodule, moduleWorktree]
let expectedKept: [URL: String] = [
    dirty: "1 uncommitted file", detachedUnique: "detached commits on no branch", locked: "locked",
    touched: "changed in the last day", committed: "committed to in the last 3 days",
    busy: "in use by a running process", wip: "1 uncommitted file",
    tabOpen: "an open tab or a child tab in progress works in it",
    subUnpushed: "submodule lib has uncommitted or unpushed work",
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
    expect(exists(wip.appendingPathComponent("node_modules")) && report.worktreeOutputRemoved?.count == 1,
           "a dry run lists build output without removing it: \(report.worktreeOutputRemoved?.map(\.path) ?? [])")
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
    // A worktree that stays loses only its build output.
    expect(!exists(wip.appendingPathComponent("node_modules")), "an idle dirty worktree's build output goes")
    expect(exists(wip.appendingPathComponent("wip.txt")) && exists(wip.appendingPathComponent("draft.txt"))
           && git(["rev-parse", "--verify", "-q", "wip"], in: project).count == 40,
           "its committed, uncommitted and unpushed work stays")
    expect(report.worktreeOutputRemoved?.map(\.path) == [wip.appendingPathComponent("node_modules").path],
           "only that worktree's output went: \(report.worktreeOutputRemoved?.map(\.path) ?? [])")
    expect(exists(tabOpen.appendingPathComponent("node_modules")), "an open tab's worktree keeps its build output")
    expect(!git(["worktree", "list", "--porcelain"], in: project).contains("submodule-worktree/")
           && !git(["worktree", "list", "--porcelain"], in: project).contains("submodule-worktree\n"),
           "the worktree with a submodule is removed and its record pruned")
    expect(!git(["worktree", "list", "--porcelain"], in: project.appendingPathComponent("lib")).contains("lib-worktree"),
           "a worktree of the submodule's own repository is removed")
    expect(exists(subUnpushed.appendingPathComponent("lib/local.txt")), "a submodule's unpushed commit keeps its worktree")
    let categories = report.bytesByCategory ?? [:]
    expect((categories["worktrees"] ?? 0) > 0 && (categories["worktreeBuildOutput"] ?? 0) > 0
           && (categories["sessions"] ?? 0) > 0, "bytes freed per kind: \(categories)")
    expect(report.summary.contains("build output folder"), "the summary names build output: \(report.summary)")
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
    expect(saved?.bytesByCategory == report.bytesByCategory && saved?.worktreeOutputRemoved?.count == 1,
           "the saved report has bytes per kind and the build output removed")
    let log = (try? String(contentsOf: cache.appendingPathComponent("storage-upkeep.log"), encoding: .utf8)) ?? ""
    expect(log.contains("session \(old.lastPathComponent) removed") && log.contains("test in /tmp: fixture"),
           "each removal is logged with what made it")
    expect(log.contains("feature-worktree removed") && log.contains("branch feature"), "worktree removals are logged")

    let again = StorageUpkeep.perform(configuration, dryRun: false)
    expect(again?.sessionsRemoved == 0 && again?.worktreesRemoved.isEmpty == true, "a second run removes nothing")
}

// MARK: - Screenshots in kept sessions' transcripts

do {
    let base = root.appendingPathComponent("transcripts")
    let sessions = base.appendingPathComponent("session-state")
    let monthAgo = realNow.addingTimeInterval(-30 * 86_400)
    let image = String(repeating: "QUJD", count: 5_000)
    let userLine = #"{"type":"user.message","data":{"content":"look at \/tmp\/a.png"},"id":"e0"}"#
    let assetLine = #"{"type":"session.binary_asset","data":{"assetId":"sha256:abc","type":"image","mimeType":"image/jpeg","byteLength":15000,"data":"\#(image)","description":"Image file at path /tmp/a.png"},"id":"e1","timestamp":"2026-10-01T00:00:00.000Z","parentId":"p0"}"#
    let toolLine = #"{"type":"tool.execution_complete","data":{"assetId":"sha256:abc"},"id":"e2","parentId":"e1"}"#
    let transcript = [userLine, assetLine, toolLine].joined(separator: "\n") + "\n"
    func shotSession(age: Date, setup: (URL) -> Void = { _ in }) -> URL {
        let folder = sessions.appendingPathComponent(UUID().uuidString.lowercased())
        write("id: x\ncwd: /tmp\nclient_name: test\nname: shots\n", to: folder.appendingPathComponent("workspace.yaml"))
        write(transcript, to: folder.appendingPathComponent("events.jsonl"))
        setup(folder)
        let items = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) + [folder]
        for item in items.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try? fm.setAttributes([.modificationDate: age], ofItemAtPath: item.path)
        }
        return folder
    }
    func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
    let idleTab = shotSession(age: monthAgo)
    let recentTab = shotSession(age: realNow)
    let busyTab = shotSession(age: monthAgo) { write("\(getpid())", to: $0.appendingPathComponent("inuse.\(getpid()).lock")) }
    let outputs = base.appendingPathComponent("outputs.json")
    let ids = [idleTab, recentTab, busyTab].map { "\"\($0.lastPathComponent)\"" }.joined(separator: ",")
    write(#"{"version":1,"backfilled":true,"sessions":{"TAB":[\#(ids)]}}"#, to: outputs)
    let shots = StorageUpkeep.Configuration(
        sessionRoot: sessions, outputFolders: outputs, memoryVault: nil, repositoryParents: [], worktreeSearchRoots: [],
        agentRoots: [sessions], stateDirectory: base, sessionRetention: 14 * 86_400, now: realNow,
        processes: { StorageUpkeep.ProcessSnapshot(workingDirectories: [], commandLines: []) }
    )
    let events = idleTab.appendingPathComponent("events.jsonl")

    let dry = StorageUpkeep.perform(shots, dryRun: true)
    expect(dry?.transcriptImagesTrimmed == 1 && (try? String(contentsOf: events, encoding: .utf8)) == transcript,
           "a dry run counts the screenshot without changing the transcript: \(dry?.transcriptImagesTrimmed ?? 0)")
    expect(!exists(base.appendingPathComponent(StorageUpkeep.transcriptCheckFile)), "a dry run saves no check record")

    var lines: [String] = []
    let report = StorageUpkeep.perform(shots, dryRun: false, log: { lines.append($0) })
    expect(report?.sessionsKept["tab"] == 3 && report?.sessionsRemoved == 0, "tab sessions stay: \(report?.sessionsKept ?? [:])")
    expect(report?.transcriptImagesTrimmed == 1 && report?.transcriptsTrimmed == 1 && (report?.transcriptBytesTrimmed ?? 0) > 15_000,
           "only the idle, unused session's screenshot goes: \(report?.transcriptImagesTrimmed ?? 0)")
    expect((report?.bytesByCategory?["transcriptImages"] ?? 0) > 0
           && report?.summary.contains("1 screenshot from 1 kept session's transcript") == true,
           "reported by kind and in the summary: \(report?.summary ?? "")")
    expect(lines.contains { $0.hasPrefix("session \(idleTab.lastPathComponent) trimmed 1 screenshot") }, "the trim is logged")
    let after = ((try? String(contentsOf: events, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    expect(after.count == 3 && after[0] == userLine && after[2] == toolLine, "other events are untouched")
    let asset = after.count == 3 ? (try? JSONSerialization.jsonObject(with: Data(after[1].utf8))) as? [String: Any] : nil
    let payload = asset?["data"] as? [String: Any]
    expect(payload?["data"] as? String == StorageUpkeep.transcriptPlaceholder && payload?["mimeType"] as? String == "image/png"
           && payload?["assetId"] as? String == "sha256:abc" && asset?["id"] as? String == "e1"
           && asset?["parentId"] as? String == "p0"
           && (payload?["description"] as? String)?.hasSuffix(StorageUpkeep.transcriptPlaceholderNote) == true,
           "the image becomes the placeholder and the event keeps its ids: \(payload ?? [:])")
    expect(abs(modified(events).timeIntervalSince(monthAgo)) < 1 && abs(modified(idleTab).timeIntervalSince(monthAgo)) < 1,
           "the transcript and its folder keep their dates")
    for folder in [recentTab, busyTab] {
        expect((try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8)) == transcript,
               "a recent or in-use session's transcript is left alone")
    }
    expect(!((try? fm.contentsOfDirectory(atPath: idleTab.path)) ?? []).contains { $0.contains("trim-") },
           "no partial file is left behind")
    let again = StorageUpkeep.perform(shots, dryRun: false)
    let record = (try? String(contentsOf: base.appendingPathComponent(StorageUpkeep.transcriptCheckFile), encoding: .utf8)) ?? ""
    expect(again?.transcriptImagesTrimmed == nil && record.contains(idleTab.lastPathComponent),
           "a second run trims nothing and remembers the checked transcript")
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

// MARK: - Low disk

do {
    let base = root.appendingPathComponent("low-disk")
    let sessions = base.appendingPathComponent("session-state")
    let state = base.appendingPathComponent("cache")
    try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    write(String(repeating: "x", count: 200_000), to: state.appendingPathComponent("worktrees/big-worktree/file.bin"))
    var low = StorageUpkeep.Configuration(
        sessionRoot: sessions, outputFolders: base.appendingPathComponent("none.json"), memoryVault: nil,
        repositoryParents: [], worktreeSearchRoots: [], agentRoots: [sessions], stateDirectory: state,
        sessionRetention: 14 * 86_400, now: realNow,
        processes: { StorageUpkeep.ProcessSnapshot(workingDirectories: [], commandLines: []) }
    )
    let gigabyte = StorageUpkeep.LowDiskGuard.gigabyte
    var guardState = StorageUpkeep.LowDiskGuard()
    var free = 30 * gigabyte
    var alerts: [(title: String, body: String)] = []
    func check() -> StorageUpkeep.Report? {
        StorageUpkeep.lowDiskRun(low, guard: &guardState, free: { free }, alert: { alerts.append(($0, $1)) })
    }
    expect(check() == nil && alerts.isEmpty, "plenty of space: no cleanup")
    free = 10 * gigabyte
    let first = check()
    expect(first?.lowDisk == true && alerts.count == 1, "low space runs a cleanup and alerts once: \(alerts)")
    expect(alerts.first?.title.hasPrefix("Only ") == true && alerts.first?.title.hasSuffix(" free on the Mac") == true
           && alerts.first?.body.contains("big-worktree") == true, "the alert names what's largest: \(alerts)")
    expect(StorageUpkeep.lastReport(in: state)?.lowDisk == true, "the saved report says low space started it")
    expect(check() == nil && alerts.count == 1, "no second cleanup within the hour")
    low.now = realNow.addingTimeInterval(2 * 3_600)
    expect(check() != nil && alerts.count == 1, "a later cleanup while space stays low doesn't alert again")
    free = 25 * gigabyte
    low.now = realNow.addingTimeInterval(4 * 3_600)
    expect(check() == nil && !guardState.alerted, "space recovered: the alert is armed again")
    free = 18 * gigabyte
    low.now = realNow.addingTimeInterval(6 * 3_600)
    expect(check() != nil && alerts.count == 1, "under 20 GB cleans up; 18 GB left isn't low enough to alert")
    free = 9 * gigabyte
    low.now = realNow.addingTimeInterval(8 * 3_600)
    expect(check() != nil && alerts.count == 2, "low again after recovering: one new alert")
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
