import Foundation

/// Readable form of the Makefile's CantripBuildIdentity: `git describe
/// --always --dirty`, plus a diff checksum when the tree was dirty.
/// "v1.0-98-g956add7" reads as release 1.0, build 98 (commits since the
/// tag), commit 956add7.
struct CantripBuildVersion: Equatable {
    let identity: String
    let release: String?
    let buildNumber: Int?
    let commit: String?
    let hasLocalChanges: Bool
    private let tag: String?

    init(identity: String) {
        self.identity = identity
        var base = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        var dirty = false
        if let marker = base.range(of: "-dirty", options: .backwards),
           base[marker.upperBound...].allSatisfy({ $0 == "-" || $0.isNumber }) {
            base = String(base[..<marker.lowerBound])
            dirty = true
        }
        hasLocalChanges = dirty

        var tag: String?
        var buildNumber: Int?
        var commit: String?
        let parts = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, let last = parts.last, last.hasPrefix("g"),
           Self.isCommit(String(last.dropFirst())), let count = Int(parts[parts.count - 2]) {
            tag = parts.dropLast(2).joined(separator: "-")
            buildNumber = count
            commit = String(last.dropFirst())
        } else if Self.isCommit(base) {
            commit = base
        } else if !base.isEmpty, base != "development", base != "unknown" {
            tag = base
            buildNumber = 0
        }
        self.tag = tag
        self.buildNumber = buildNumber
        self.commit = commit
        if let tag {
            release = tag.hasPrefix("v") && tag.dropFirst().first?.isNumber == true
                ? String(tag.dropFirst()) : tag
        } else {
            release = nil
        }
    }

    /// "1.0 (98)", matching how Apple shows version (build).
    var title: String {
        if let release, let buildNumber, buildNumber > 0 { return "\(release) (\(buildNumber))" }
        if let release { return release }
        if let commit { return commit }
        return identity == "development" || identity.isEmpty ? "Development build" : identity
    }

    /// What git can resolve for comparisons; nil for unstamped builds.
    var gitRevision: String? { commit ?? tag }

    private static func isCommit(_ text: String) -> Bool {
        text.count >= 4 && text.count <= 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

enum CantripUpdateState: Equatable {
    case checking
    case upToDate(unpushedCommits: Int)
    /// A staged build already includes everything on GitHub.
    case staged
    case available(commits: Int)
    /// The source checkout has changes that no build includes yet.
    case rebuildNeeded
    case unknown(String)
}

struct CantripVersionReport: Equatable {
    var running: CantripBuildVersion
    var runningDate: Date?
    var staged: CantripBuildVersion?
    var stagedDate: Date?
    var source: CantripBuildVersion?
    var latest: CantripBuildVersion?
    var latestSubject: String?
    var latestDate: Date?
    /// GitHub commits missing from the running build.
    var runningBehind: Int?
    /// Commits in the running build that are not on GitHub.
    var runningAhead: Int?
    var stagedBehind: Int?
    var repositoryAvailable = true
    var fetchFailed = false
    var checkedAt: Date?

    init(runningIdentity: String, runningDate: String?) {
        running = CantripBuildVersion(identity: runningIdentity)
        self.runningDate = runningDate.flatMap(Self.parseDate)
    }

    func state(checking: Bool) -> CantripUpdateState {
        guard repositoryAvailable else {
            return .unknown("Updates are checked from Cantrip's source checkout, which wasn't found.")
        }
        guard running.gitRevision != nil else {
            return .unknown("This build has no version stamp. Build it with make app to compare it with GitHub.")
        }
        guard latest != nil else {
            if checking { return .checking }
            return .unknown(fetchFailed ? "Couldn't reach GitHub." : "Not checked yet.")
        }
        guard let behind = runningBehind else {
            return checking ? .checking : .unknown("Couldn't compare this build with GitHub.")
        }
        if behind > 0 {
            return staged != nil && stagedBehind == 0 ? .staged : .available(commits: behind)
        }
        if let source, source.identity != running.identity, source.identity != staged?.identity {
            return .rebuildNeeded
        }
        return .upToDate(unpushedCommits: runningAhead ?? 0)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
