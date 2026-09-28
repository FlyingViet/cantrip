import Foundation

/// Returns failure messages; empty when every version-display case passes.
func cantripVersionFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    let tagged = CantripBuildVersion(identity: "v1.0-98-g956add7")
    expect(tagged.title == "1.0 (98)", "tagged builds read as version (build), got \(tagged.title)")
    expect(tagged.commit == "956add7" && !tagged.hasLocalChanges, "tagged builds keep their commit")
    expect(tagged.gitRevision == "956add7", "comparisons use the build's commit")

    let dirty = CantripBuildVersion(identity: "v1.0-99-gce346ce-dirty-1234567890")
    expect(dirty.title == "1.0 (99)" && dirty.commit == "ce346ce", "dirty builds parse like clean ones")
    expect(dirty.hasLocalChanges, "the diff checksum marks local changes")
    expect(CantripBuildVersion(identity: "v1.0-99-gce346ce-dirty").hasLocalChanges,
           "a bare -dirty suffix marks local changes")

    let onTag = CantripBuildVersion(identity: "v1.0")
    expect(onTag.title == "1.0" && onTag.gitRevision == "v1.0", "a build on a tag compares by the tag")
    let hyphenTag = CantripBuildVersion(identity: "v2.0-beta-3-gabcdef0")
    expect(hyphenTag.title == "2.0-beta (3)", "hyphenated tags stay whole, got \(hyphenTag.title)")
    let bare = CantripBuildVersion(identity: "956add7")
    expect(bare.title == "956add7" && bare.commit == "956add7", "untagged repos show the commit")
    let development = CantripBuildVersion(identity: "development")
    expect(development.title == "Development build" && development.gitRevision == nil,
           "unstamped builds can't be compared")

    expect(CantripVersionReport.parseDate("2026-09-27T19:46:29Z") != nil, "Makefile build dates parse")
    expect(CantripVersionReport.parseDate("2026-09-27T18:57:41-07:00") != nil, "git commit dates parse")

    var report = CantripVersionReport(runningIdentity: "v1.0-98-g956add7", runningDate: "2026-09-27T19:46:29Z")
    expect(report.runningDate != nil, "the running build date is parsed")
    expect(report.state(checking: true) == .checking, "the first check shows progress")
    expect(report.state(checking: false) == .unknown("Not checked yet."), "no check yet is unknown")
    report.fetchFailed = true
    expect(report.state(checking: false) == .unknown("Couldn't reach GitHub."), "offline without a known latest")
    report.fetchFailed = false

    report.latest = CantripBuildVersion(identity: "v1.0-99-gce346ce")
    report.runningBehind = 1
    report.runningAhead = 0
    expect(report.state(checking: false) == .available(commits: 1), "newer GitHub commits are an update")

    report.staged = CantripBuildVersion(identity: "v1.0-99-gce346ce")
    report.stagedBehind = 0
    expect(report.state(checking: false) == .staged, "a staged build with the latest commit waits for restart")
    report.stagedBehind = 2
    expect(report.state(checking: false) == .available(commits: 1), "an older staged build still needs an update")

    report.staged = nil
    report.stagedBehind = nil
    report.runningBehind = 0
    expect(report.state(checking: false) == .upToDate(unpushedCommits: 0), "matching GitHub is up to date")
    report.runningAhead = 2
    expect(report.state(checking: false) == .upToDate(unpushedCommits: 2), "unpushed commits are still up to date")

    report.runningAhead = 0
    report.source = CantripBuildVersion(identity: "v1.0-98-g956add7-dirty-42")
    expect(report.state(checking: false) == .rebuildNeeded, "unbuilt source changes need a rebuild")
    report.staged = CantripBuildVersion(identity: "v1.0-98-g956add7-dirty-42")
    expect(report.state(checking: false) == .upToDate(unpushedCommits: 0),
           "a staged build of the source changes needs only a restart")

    var local = CantripVersionReport(runningIdentity: "development", runningDate: "unknown")
    expect(local.runningDate == nil, "unknown build dates are omitted")
    local.latest = report.latest
    if case .unknown = local.state(checking: false) {} else {
        failures.append("development builds can't be compared with GitHub")
    }
    var outside = CantripVersionReport(runningIdentity: "v1.0-98-g956add7", runningDate: nil)
    outside.repositoryAvailable = false
    if case .unknown = outside.state(checking: false) {} else {
        failures.append("an app outside its checkout can't check for updates")
    }
    return failures
}
