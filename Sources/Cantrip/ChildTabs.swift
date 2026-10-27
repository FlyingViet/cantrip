import Foundation
import Combine

/// A child tab: a queued request from a parent tab run in parallel in its own tab and, when the
/// parent's work is a git repository, its own worktree and branch. Its result merges back into
/// the parent's branch and shows in the parent as one card (`ChatMessage.childResult`), which is
/// all that reaches the parent's model: one line once it settles. Docs: sessions-and-council.md.
struct ChildTab: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case working, needsInput, finished, merging, merged, conflict, unmerged, noChanges, failed, stopped, discarded
        /// Run in the parent instead: the request went back to the front of its queue.
        case requeued

        var isRunning: Bool { self == .working || self == .needsInput }
        /// Done for good: the tab is archived and nothing is left to merge.
        var isSettled: Bool { self == .merged || self == .noChanges || self == .discarded || self == .requeued }
        /// How it ended, or a question for the user: the parent's card moves to the end.
        var isOutcome: Bool { !isRunning && self != .finished && self != .merging }
    }

    struct FileChange: Codable, Equatable {
        let path: String
        let added: Int
        let removed: Int
    }

    let id: UUID
    let parentID: UUID
    let queueItemID: UUID
    var title: String
    /// The queued request, as written.
    let prompt: String
    var parentTitle: String
    /// The repository the child works in (nil: no repository, nothing to merge).
    var repoRoot: String?
    var worktree: String?
    var branch: String?
    /// The parent checkout's branch when the child started; the merge goes there.
    var baseBranch: String?
    var baseCommit: String?
    var touches: [String] = []
    var state: State = .working
    var summary = ""
    /// The child's replies (a few paragraphs) for the card's expanded thread.
    var replies: [String] = []
    var files: [FileChange] = []
    var mergeCommit: String?
    var conflictFiles: [String] = []
    var conflictExcerpt: String?
    /// Files that merged cleanly beside a conflict.
    var cleanFileCount = 0
    /// Why a merge is waiting or stopped, in plain words.
    var note: String?
    /// The parent was asked to resolve a conflict (its next idle point checks the branch).
    var resolveRequested = false
    /// The parent's model has been told how this child ended (one line, once).
    var contextDelivered = false
    /// The outcome the parent's model last heard about (optional: older records lack it). A later
    /// outcome (stopped, then merged) is told again.
    var reportedState: State?
    /// Started by auto-fork rather than Run in Child Tab (optional: older records lack it).
    var autoStarted: Bool?
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
    var repoName: String? { repoRoot.map { ($0 as NSString).lastPathComponent } }

    /// What the card offers in this state (`POST …/children/{id}/{action}`).
    var actions: [String] {
        switch state {
        case .working, .needsInput: return ["open", "requeue", "discard"]
        case .finished: return note == nil ? ["open"] : ["retry", "open"]
        case .merging: return ["open"]
        case .merged, .noChanges, .discarded, .requeued: return ["open"]
        case .conflict: return ["resolve", "keepParent", "keepChild", "leave", "open"]
        case .unmerged: return ["retry", "discard", "open"]
        case .failed, .stopped: return branch == nil ? ["open", "discard"] : ["merge", "discard", "open"]
        }
    }

    var statusLine: String {
        let base = baseBranch ?? "the parent's branch"
        switch state {
        case .working: return "Working"
        case .needsInput: return "Needs your answer"
        case .finished: return note ?? "Done; merges into \(base) when the parent tab is idle"
        case .merging: return resolveRequested ? "The parent tab is resolving the merge" : "Merging into \(base)"
        case .merged:
            return "Merged into \(base) · \(files.count) \(files.count == 1 ? "file" : "files") +\(added) −\(removed)"
        case .conflict:
            return "Merge conflict · \(conflictFiles.count) of \(conflictFiles.count + cleanFileCount) files"
        case .unmerged: return note ?? "Not merged"
        case .noChanges: return repoRoot == nil ? "Done · no repository to merge" : "Done · no code changes"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .discarded: return "Discarded"
        case .requeued: return "Moved back to \(parentTitle)'s queue"
        }
    }

    static let autoStartedNote = "Started automatically: it doesn't depend on the current task."

    /// What the card says: the child's summary, or while an auto-started child works, why it started.
    var displaySummary: String {
        summary.isEmpty && state.isRunning && autoStarted == true ? Self.autoStartedNote : summary
    }

    /// The card as text, for transcripts and clients that don't draw it.
    var fallbackText: String {
        var text = "Child tab “\(title)”: \(statusLine)."
        if !summary.isEmpty { text += "\n\n\(summary)" }
        return text
    }

    /// The one line the parent's model gets once the child settles.
    var contextLine: String {
        let files = self.files.prefix(6).map(\.path).joined(separator: ", ")
        var line = "[Child tab “\(title)” (\(prompt.prefix(120))…): \(statusLine)."
        if !summary.isEmpty { line += " \(summary.prefix(400))" }
        if !files.isEmpty { line += " Files: \(files)." }
        return line + "]"
    }

    /// States the parent's model hears about with every message while they last.
    var isLive: Bool { [.working, .needsInput, .finished, .merging, .conflict].contains(state) }

    /// An outcome the parent's model hasn't heard about yet (told once, as `contextLine`).
    var needsReport: Bool {
        guard !isLive, state != .requeued, reportedState != state else { return false }
        // Records from before `reportedState` only knew whether they had been told.
        return !(reportedState == nil && contextDelivered)
    }

    /// The parent's live line for this child: its state, what it's doing or asking, and the files
    /// it has touched so far. Nil once it has an outcome (`contextLine` tells that once).
    func liveStatusLine(activity: String? = nil, question: String? = nil, touched: [String] = []) -> String? {
        guard isLive else { return nil }
        let base = baseBranch ?? "your branch"
        func clean(_ text: String, _ limit: Int) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        var line = "- “\(clean(title, 60))” (\(id.uuidString)): "
        switch state {
        case .working:
            line += "working"
            if let activity, !activity.isEmpty { line += " · now: \(clean(activity, 80))" }
        case .needsInput:
            line += "needs the user's answer"
            if let question, !question.isEmpty { line += ": \(clean(question, 160))" }
        case .finished:
            line += note.map { "done; \(clean($0, 160))" }
                ?? "done, waiting to merge into \(base) (Cantrip merges it when this tab is idle)"
        case .merging:
            line += resolveRequested ? "you were asked to resolve its merge conflict" : "merging into \(base)"
        case .conflict:
            let files = conflictFiles.prefix(4).joined(separator: ", ")
            line += "merge conflict in \(files.isEmpty ? "some files" : files); the user picks how to merge on its card"
        default:
            return nil
        }
        let paths = touched.isEmpty ? files.map(\.path) : touched
        if !paths.isEmpty {
            let shown = paths.prefix(5).joined(separator: ", ")
            line += " · files so far: \(shown)" + (paths.count > 5 ? " (+\(paths.count - 5) more)" : "")
        }
        return line
    }

    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "id": id.uuidString, "parentID": parentID.uuidString, "title": title, "prompt": prompt,
            "parentTitle": parentTitle, "state": state.rawValue, "statusLine": statusLine,
            "summary": displaySummary, "replies": replies, "autoStarted": autoStarted == true,
            "files": files.map { ["path": $0.path, "added": $0.added, "removed": $0.removed] },
            "added": added, "removed": removed, "conflictFiles": conflictFiles,
            "cleanFileCount": cleanFileCount, "actions": actions,
            "createdAt": createdAt.timeIntervalSince1970, "updatedAt": updatedAt.timeIntervalSince1970,
        ]
        result["repoName"] = repoName
        result["branch"] = branch
        result["baseBranch"] = baseBranch
        result["mergeCommit"] = mergeCommit.map { String($0.prefix(9)) }
        result["conflictExcerpt"] = conflictExcerpt
        result["note"] = note
        result["finishedAt"] = finishedAt?.timeIntervalSince1970
        return result
    }
}

enum ChildTabError: LocalizedError, Equatable {
    case notAllowed(String)
    case limit(String)
    case unavailable
    case git(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let reason), .limit(let reason), .git(let reason): return reason
        case .unavailable: return "That child tab is no longer available. Refresh and try again."
        }
    }

    var status: Int {
        switch self {
        case .unavailable: return 404
        case .limit: return 409
        case .notAllowed, .git: return 409
        }
    }
}

/// Every child tab, by ID, in `~/.cache/Cantrip/child-tabs.json`. Records stay after the child
/// is archived so the parent's card keeps working.
@MainActor
final class ChildTabStore: ObservableObject {
    static let shared = ChildTabStore()
    static let maximumRecords = 500

    @Published private(set) var records: [UUID: ChildTab] = [:]
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? CantripPaths.cache("child-tabs.json")
        if let data = try? Data(contentsOf: self.url),
           let list = try? JSONDecoder().decode([ChildTab].self, from: data) {
            records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }

    func record(_ id: UUID) -> ChildTab? { records[id] }

    /// A child that still runs or waits on its merge (settled children are ordinary archived tabs).
    func isActiveChild(_ id: UUID) -> Bool { records[id].map { !$0.state.isSettled } ?? false }

    func children(of parentID: UUID) -> [ChildTab] {
        records.values.filter { $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
    }

    var running: [ChildTab] { records.values.filter(\.state.isRunning) }

    func upsert(_ record: ChildTab) {
        var record = record
        record.updatedAt = Date()
        records[record.id] = record
        save()
    }

    func remove(_ id: UUID) {
        records[id] = nil
        save()
    }

    private func save() {
        // Oldest settled records go first once the file grows.
        var list = records.values.sorted { $0.createdAt < $1.createdAt }
        while list.count > Self.maximumRecords, let index = list.firstIndex(where: \.state.isSettled) {
            records[list.remove(at: index).id] = nil
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: url, options: .atomic)
        } catch {
            Log.write("child-tabs: could not save records: \(error.localizedDescription)")
        }
    }
}

/// The git side of a child tab. Synchronous and thread-safe; callers keep it off the main actor
/// except for the quick reads used while forking.
enum ChildTabGit {
    static var git = "/usr/bin/git"
    static let branchPrefix = "cantrip/child/"
    static let lockReason = "Cantrip child tab"

    @discardableResult
    static func run(_ directory: String, _ arguments: [String], timeout: TimeInterval = 90) -> StorageUpkeep.Git.Result? {
        StorageUpkeep.Git.run(git, ["-C", directory] + arguments, timeout: timeout)
    }

    static func toplevel(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let result = run(path, ["rev-parse", "--show-toplevel"], timeout: 10), result.succeeded,
              !result.output.isEmpty else { return nil }
        return result.output
    }

    static func currentBranch(_ repo: String) -> String? {
        guard let result = run(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"], timeout: 10),
              result.succeeded, !result.output.isEmpty else { return nil }
        return result.output
    }

    static func head(_ repo: String) -> String? {
        guard let result = run(repo, ["rev-parse", "HEAD"], timeout: 10), result.succeeded,
              !result.output.isEmpty else { return nil }
        return result.output
    }

    static func branchExists(_ repo: String, _ branch: String) -> Bool {
        run(repo, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: 10)?.succeeded == true
    }

    /// Uncommitted paths (staged, unstaged and untracked), repo-relative. Name-only commands:
    /// `run` trims its output, which would cut `git status --porcelain`'s leading status column.
    static func changedFiles(_ repo: String, limit: Int = 40) -> [String] {
        var paths: [String] = []
        for arguments in [["diff", "--name-only", "HEAD"], ["ls-files", "--others", "--exclude-standard"]] {
            guard let result = run(repo, arguments, timeout: 15), result.succeeded else { continue }
            for line in result.output.split(separator: "\n") where !paths.contains(String(line)) {
                paths.append(String(line))
            }
        }
        return Array(paths.prefix(limit))
    }

    /// A short, safe branch name for `title`.
    static func branchName(title: String, id: UUID) -> String {
        let words = title.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let slug = String(words).split(separator: " ").prefix(5).joined(separator: "-")
        return branchPrefix + (slug.isEmpty ? "task" : String(slug.prefix(40))) + "-" + id.uuidString.prefix(6).lowercased()
    }

    /// Creates `branch` at the repository's HEAD, checked out in a locked worktree at `path`.
    static func createWorktree(repo: String, branch: String, path: String) throws -> (baseCommit: String, baseBranch: String?) {
        guard let base = head(repo) else { throw ChildTabError.git("This repository has no commits yet, so a child tab can't branch from it.") }
        let baseBranch = currentBranch(repo)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard let added = run(repo, ["worktree", "add", "-b", branch, path, base], timeout: 180) else {
            throw ChildTabError.git("Git didn't finish creating the child tab's worktree.")
        }
        guard added.succeeded else { throw ChildTabError.git("Git couldn't create the worktree: \(added.error.prefix(300))") }
        // Storage cleanup never removes a locked worktree.
        run(repo, ["worktree", "lock", "--reason", lockReason, path], timeout: 15)
        return (base, baseBranch)
    }

    enum Leftovers: Equatable {
        case none, committed
        /// Uncommitted work is still there (signing prompt unanswered, a hook, a full disk…).
        case failed(String)
    }

    /// Whether the worktree has uncommitted changes (ignored files don't count).
    static func isDirty(_ worktree: String) -> Bool {
        guard FileManager.default.fileExists(atPath: worktree) else { return false }
        guard let status = run(worktree, ["status", "--porcelain"], timeout: 30), status.succeeded else { return true }
        return !status.output.isEmpty
    }

    /// Commits whatever the child left uncommitted in its worktree.
    @discardableResult
    static func commitLeftovers(worktree: String, title: String) -> Leftovers {
        guard isDirty(worktree) else { return .none }
        guard let added = run(worktree, ["add", "-A"], timeout: 60), added.succeeded else {
            return .failed("git add didn't finish")
        }
        let message = ["commit", "--no-verify", "-q", "-m", title, "-m", "Child tab work, committed by Cantrip."]
        var result = run(worktree, message, timeout: 60)
        if result?.succeeded != true {
            // A repository without an identity still gets the commit.
            result = run(worktree, ["-c", "user.name=Cantrip", "-c", "user.email=cantrip@localhost"] + message, timeout: 60)
        }
        if result?.succeeded == true, !isDirty(worktree) { return .committed }
        let reason = result.map { ($0.error.isEmpty ? $0.output : $0.error).trimmingCharacters(in: .whitespacesAndNewlines) }
        return .failed(String((reason?.isEmpty == false ? reason! : "git commit didn't finish").prefix(200)))
    }

    /// A merge, rebase, cherry-pick or revert someone left unfinished in `repo`'s checkout.
    static func operationInProgress(_ repo: String) -> String? {
        let markers: [(String, String)] = [("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick"),
                                           ("REVERT_HEAD", "a revert"), ("rebase-merge", "a rebase"),
                                           ("rebase-apply", "a rebase")]
        for (marker, name) in markers {
            guard let path = run(repo, ["rev-parse", "--git-path", marker], timeout: 10)?.output, !path.isEmpty else { continue }
            let absolute = path.hasPrefix("/") ? path : (repo as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: absolute) { return name }
        }
        return nil
    }

    static func commitsAhead(repo: String, base: String, branch: String) -> Int {
        Int(run(repo, ["rev-list", "--count", "\(base)..\(branch)"], timeout: 30)?.output ?? "") ?? 0
    }

    static func numstat(repo: String, base: String, branch: String) -> [ChildTab.FileChange] {
        guard let result = run(repo, ["diff", "--numstat", "\(base)...\(branch)"], timeout: 60), result.succeeded else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return .init(path: String(fields[2]), added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0)
        }
    }

    static func isMerged(repo: String, branch: String) -> Bool {
        run(repo, ["merge-base", "--is-ancestor", branch, "HEAD"], timeout: 30)?.succeeded == true
    }

    enum MergeCheck: Equatable {
        case clean
        case conflict(files: [String], excerpt: String?)
        case failed(String)
    }

    /// Whether `branch` merges into HEAD cleanly, without touching the checkout (`merge-tree`).
    static func checkMerge(repo: String, branch: String, parentLabel: String = "parent") -> MergeCheck {
        guard let result = run(repo, ["merge-tree", "--write-tree", "--name-only", "HEAD", branch], timeout: 120) else {
            return .failed("Git didn't finish checking the merge.")
        }
        if result.succeeded { return .clean }
        guard result.status == 1 else { return .failed(result.error.isEmpty ? result.output : result.error) }
        // Tree ID, the conflicted paths, a blank line, then git's messages.
        let lines = result.output.components(separatedBy: "\n")
        let tree = lines.first ?? ""
        let files = Array(lines.dropFirst().prefix { !$0.isEmpty })
        let excerpt = files.first.flatMap { file in
            run(repo, ["cat-file", "-p", "\(tree):\(file)"], timeout: 30).flatMap { $0.succeeded ? $0.output : nil }
                .flatMap { conflictExcerpt($0, parentLabel: parentLabel) }
        }
        return .conflict(files: files, excerpt: excerpt)
    }

    /// The first conflict in `text`, as a few lines: context, the parent's side (labeled with its
    /// branch), the child's side.
    static func conflictExcerpt(_ text: String, parentLabel: String = "parent") -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("<<<<<<<") }) else { return nil }
        let label = String(parentLabel.prefix(16))
        let width = max(label.count, "child".count)
        func pad(_ text: String) -> String { text + String(repeating: " ", count: width - text.count) }
        var out = lines[max(0, start - 1)..<start].map {
            String(repeating: " ", count: width + 3) + $0.trimmingCharacters(in: .whitespaces)
        }
        var side = "parent"
        var shown = 0
        for line in lines[(start + 1)...] {
            if line.hasPrefix(">>>>>>>") { break }
            if line.hasPrefix("|||||||") { side = "base"; continue }
            if line.hasPrefix("=======") { side = "child"; continue }
            guard side != "base" else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            out.append(pad(side == "parent" ? label : "child") + " + " + String(trimmed.prefix(110)))
            shown += 1
            if shown >= 8 { out.append("…"); break }
        }
        return out.joined(separator: "\n")
    }

    enum MergeOutcome: Equatable {
        case merged(commit: String)
        /// Uncommitted changes in the parent's checkout overlap the merge.
        case blockedByLocalChanges(String)
        /// Someone's merge, rebase or the like is unfinished in the checkout; it's left alone.
        case busy(String)
        case conflict
        case failed(String)
    }

    /// `git merge --no-ff` into the checkout; a half-done merge of its own is aborted. It never
    /// starts while another merge, rebase, cherry-pick or revert is unfinished there.
    static func merge(repo: String, branch: String, message: String, option: String? = nil) -> MergeOutcome {
        if let operation = operationInProgress(repo) { return .busy(operation) }
        var arguments = ["merge", "--no-ff", "--no-edit", "-m", message]
        if let option { arguments += ["-X", option] }
        arguments.append(branch)
        guard var result = run(repo, arguments, timeout: 300) else { return .failed("Git didn't finish the merge.") }
        var text = result.error + "\n" + result.output
        func abortIfMerging() {
            if run(repo, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], timeout: 10)?.succeeded == true {
                run(repo, ["merge", "--abort"], timeout: 60)
            }
        }
        if !result.succeeded, text.contains("Please tell me who you are") || text.contains("auto-detect email") {
            // A repository without an identity still gets the merge commit.
            abortIfMerging()
            guard let retried = run(repo, ["-c", "user.name=Cantrip", "-c", "user.email=cantrip@localhost"] + arguments,
                                    timeout: 300) else { return .failed("Git didn't finish the merge.") }
            result = retried
            text = result.error + "\n" + result.output
        }
        if result.succeeded, let commit = head(repo) { return .merged(commit: commit) }
        abortIfMerging()
        if text.contains("would be overwritten") || text.contains("Please commit your changes or stash them") {
            return .blockedByLocalChanges(text)
        }
        if text.contains("CONFLICT") { return .conflict }
        return .failed(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }

    /// Removes the worktree and the branch. Without `force` (Discard), a worktree with uncommitted
    /// changes stays, locked, with its branch; false then.
    @discardableResult
    static func cleanup(repo: String, worktree: String?, branch: String?, force: Bool) -> Bool {
        if let worktree, FileManager.default.fileExists(atPath: worktree) {
            if !force, isDirty(worktree) { return false }
            run(repo, ["worktree", "unlock", worktree], timeout: 15)
            if run(repo, ["worktree", "remove", worktree], timeout: 120)?.succeeded != true {
                guard force else {
                    run(repo, ["worktree", "lock", "--reason", lockReason, worktree], timeout: 15)
                    return false
                }
                run(repo, ["worktree", "remove", "--force", worktree], timeout: 120)
            }
        }
        if worktree != nil { run(repo, ["worktree", "prune"], timeout: 30) }
        if let branch, branch.hasPrefix(branchPrefix) {
            run(repo, ["branch", force ? "-D" : "-d", branch], timeout: 30)
        }
        return true
    }
}

/// Auto-fork (Phase 3): whether a queued message the planner rated independent starts in a child
/// tab on its own. The planner's judgment is checked against what is known for sure: the message's
/// likely files must not be ones the parent has uncommitted or just edited, or that a running child
/// tab expects to change, and there must be a repository for the child's own branch.
enum ChildTabAutoFork {
    enum Verdict: Equatable {
        case fork
        /// It stays queued; the reason replaces the plan chip's text.
        case stay(String)
    }

    static func verdict(touches: [String], hasRepository: Bool, changedFiles: [String],
                        activity: [String], childTouches: [String]) -> Verdict {
        guard hasRepository else { return .stay("Independent; outside a repository it waits for Run in Child Tab") }
        let wanted = touches.compactMap { touch -> (shown: String, key: String)? in
            let key = normalized(touch)
            return key.isEmpty ? nil : (touch, key)
        }
        guard !wanted.isEmpty else { return .stay("Independent; its files are unclear, so it waits for Run in Child Tab") }
        let changed = changedFiles.map(normalized)
        if let hit = wanted.first(where: { touch in
            changed.contains { overlaps(touch.key, $0) } || activity.contains { mentions($0, touch.key) }
        }) {
            return .stay("Runs after the current task: it also changes \(display(hit.shown))")
        }
        let children = childTouches.map(normalized).filter { !$0.isEmpty }
        if let hit = wanted.first(where: { touch in children.contains { overlaps(touch.key, $0) } }) {
            return .stay("Runs after the current task: a child tab is changing \(display(hit.shown))")
        }
        return .fork
    }

    static func normalized(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The same file or folder: equal, one a path suffix of the other, one inside the other, or the
    /// same file name.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a) || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
            return true
        }
        let nameA = (a as NSString).lastPathComponent, nameB = (b as NSString).lastPathComponent
        return isFileName(nameA) && nameA == nameB
    }

    /// An edited path or a command from the parent's current work names the file.
    static func mentions(_ text: String, _ touch: String) -> Bool {
        let text = normalized(text)
        if !text.contains(" ") { return overlaps(text, touch) }
        let name = (touch as NSString).lastPathComponent
        return isFileName(name) && name.count >= 5 && text.contains(name)
    }

    private static func isFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 6
    }

    private static func display(_ touch: String) -> String {
        var touch = touch.trimmingCharacters(in: .whitespacesAndNewlines)
        while touch.hasSuffix("/") { touch.removeLast() }
        let name = (touch as NSString).lastPathComponent
        return name.isEmpty ? touch : name
    }
}
