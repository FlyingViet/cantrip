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
    .appendingPathComponent("cantrip-build-cache-tests-\(UUID().uuidString)")
private let now = Date()
private let longAgo = now.addingTimeInterval(-30 * 86_400)
private let yesterday = now.addingTimeInterval(-86_400 - 60)
defer { try? fm.removeItem(at: root) }

@discardableResult
private func git(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                         "-c", "init.defaultBranch=main", "-C", directory.path] + arguments
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

private func write(_ text: String, to url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

/// Sets the modification date of `url` and everything inside it.
private func age(_ url: URL, _ date: Date) {
    if let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let item as URL in walker { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: item.path) }
    }
    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

private func derivedData(_ url: URL, workspace: String, accessed: Date? = nil) {
    write("log", to: url.appendingPathComponent("Logs/Build/a.xcactivitylog"))
    write("o", to: url.appendingPathComponent("Build/Products/Debug/app"))
    write("{}", to: url.appendingPathComponent("SourcePackages/workspace-state.json"))
    var plist: [String: Any] = ["WorkspacePath": workspace]
    if let accessed { plist["LastAccessedDate"] = accessed }
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("info.plist"))
}

private func packageClones(_ url: URL) {
    write("x", to: url.appendingPathComponent("checkouts/swift-collections/Package.swift"))
    write("x", to: url.appendingPathComponent("repositories/swift-collections-1234/HEAD"))
    write("{}", to: url.appendingPathComponent("workspace-state.json"))
}

private let idle = StorageUpkeep.ProcessSnapshot(workingDirectories: [], commandLines: [])

/// An npm lockfile pinning `packages` (name: version), and the hidden lockfile npm writes into
/// node_modules when it installs `installed`.
private func npmLock(_ packages: [String: String]) -> String {
    let entries = packages.map { "\"node_modules/\($0.key)\": {\"version\": \"\($0.value)\"}" }.joined(separator: ", ")
    return "{\"lockfileVersion\": 3, \"packages\": {\"\": {\"name\": \"x\"}\(entries.isEmpty ? "" : ", " + entries)}}"
}

private func npmInstall(_ folder: URL, _ installed: [String: String]) {
    let entries = installed.map { "\"node_modules/\($0.key)\": {\"version\": \"\($0.value)\"}" }.joined(separator: ", ")
    write("{\"packages\": {\(entries)}}", to: folder.appendingPathComponent("node_modules/.package-lock.json"))
}

// MARK: - Seeding a worktree

do {
    let repo = root.appendingPathComponent("repo")
    write("node_modules/\n!vendor/node_modules/\nPods/\n.spm/\n*.xcodeproj\nbuild/\n", to: repo.appendingPathComponent(".gitignore"))
    write(npmLock(["left-pad": "1.0.0"]), to: repo.appendingPathComponent("package-lock.json"))
    write("{}", to: repo.appendingPathComponent("app/package.json"))
    write(npmLock(["dep": "1.0.0"]), to: repo.appendingPathComponent("app/package-lock.json"))
    write("PODS: []", to: repo.appendingPathComponent("ios/Podfile.lock"))
    write(npmLock([:]), to: repo.appendingPathComponent("vendor/package-lock.json"))
    git(["init", "-q"], in: repo)
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "init"], in: repo)

    let worktree = root.appendingPathComponent("worktree")
    git(["worktree", "add", "-q", "--detach", worktree.path], in: repo)

    // Installed in the main checkout only.
    write("module.exports = 1", to: repo.appendingPathComponent("node_modules/left-pad/index.js"))
    npmInstall(repo, ["left-pad": "1.0.0"])
    write("x", to: repo.appendingPathComponent("app/node_modules/dep/index.js"))
    write("PODS: []", to: repo.appendingPathComponent("ios/Pods/Manifest.lock"))
    packageClones(repo.appendingPathComponent(".spm"))
    write("{\"pins\": []}", to: repo.appendingPathComponent("App.xcodeproj/\(BuildCaches.projectPins)"))
    write("x", to: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
    // Not ignored: never cloned (it would end up in the child's commit).
    write("x", to: repo.appendingPathComponent("vendor/node_modules/x.js"))
    npmInstall(repo.appendingPathComponent("vendor"), [:])
    // Inside a build folder: not searched.
    write("x", to: repo.appendingPathComponent("build/node_modules/x.js"))

    // The worktree's app lockfile differs (the child's branch changed dependencies).
    write(npmLock(["dep": "2.0.0"]), to: worktree.appendingPathComponent("app/package-lock.json"))

    let candidates = BuildCaches.candidates(in: repo).map(\.path).sorted()
    expect(candidates == [".spm", "App.xcodeproj/\(BuildCaches.projectPins)", "app/node_modules", "ios/Pods",
                          "node_modules", "vendor/node_modules"],
           "dependency folders found: \(candidates)")

    let preview = BuildCaches.seed(worktree: worktree.path, from: [repo.path], dryRun: true)
    expect(!exists(worktree.appendingPathComponent("node_modules")) && preview.seeded.count == 4,
           "a dry run clones nothing: \(preview.seeded)")

    let result = BuildCaches.seed(worktree: worktree.path, from: [repo.path])
    expect(result.seeded.sorted() == [".spm", "App.xcodeproj/\(BuildCaches.projectPins)", "ios/Pods", "node_modules"],
           "matching lockfiles and SwiftPM folders are cloned: \(result.seeded)")
    let skipped = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.path, $0.reason) })
    expect(skipped["app/node_modules"] == "package-lock.json differs", "a changed lockfile skips: \(skipped)")
    expect(skipped["vendor/node_modules"] == "git doesn't ignore it", "an unignored folder skips: \(skipped)")
    expect((try? String(contentsOf: worktree.appendingPathComponent("node_modules/left-pad/index.js"), encoding: .utf8))
           == "module.exports = 1", "the clone has the files")
    expect(exists(worktree.appendingPathComponent(".spm/checkouts/swift-collections/Package.swift")), "SwiftPM clones cloned")
    expect(exists(worktree.appendingPathComponent("App.xcodeproj/\(BuildCaches.projectPins)"))
           && !exists(worktree.appendingPathComponent("App.xcodeproj/project.pbxproj")),
           "only the pins of a generated project are cloned")
    let status = git(["status", "--porcelain", "--untracked-files=all"], in: worktree)
    expect(status == "M app/package-lock.json", "seeding adds nothing git sees: \(status)")

    // A change in the clone doesn't reach the source (copy-on-write).
    write("changed", to: worktree.appendingPathComponent("node_modules/left-pad/index.js"))
    expect((try? String(contentsOf: repo.appendingPathComponent("node_modules/left-pad/index.js"), encoding: .utf8))
           == "module.exports = 1", "the source keeps its files")

    let again = BuildCaches.seed(worktree: worktree.path, from: [repo.path])
    expect(again.seeded.isEmpty && Dictionary(uniqueKeysWithValues: again.skipped.map { ($0.path, $0.reason) })["node_modules"]
           == "the worktree already has it", "existing folders are never replaced")
    expect(BuildCaches.checkouts(of: worktree.path).map(StorageUpkeep.resolved)
           == [repo.path, worktree.path].map(StorageUpkeep.resolved), "a repository's checkouts, the main one first")
}

// MARK: - Seeding from the checkout whose install is current

do {
    let repo = root.appendingPathComponent("stale-repo")
    write("node_modules/\nPods/\n", to: repo.appendingPathComponent(".gitignore"))
    write(npmLock(["a": "2.0.0", "fsevents": "1.0.0"]).replacingOccurrences(
        of: "\"node_modules/fsevents\": {\"version\": \"1.0.0\"}",
        with: "\"node_modules/fsevents\": {\"version\": \"1.0.0\", \"optional\": true}"),
          to: repo.appendingPathComponent("package-lock.json"))
    write("PODS: [A]", to: repo.appendingPathComponent("ios/Podfile.lock"))
    write("diff", to: repo.appendingPathComponent("patches/a+2.0.0.patch"))
    git(["init", "-q"], in: repo)
    git(["add", "."], in: repo)
    git(["commit", "-q", "-m", "init"], in: repo)
    let fresh = root.appendingPathComponent("stale-repo-fresh")
    git(["worktree", "add", "-q", "--detach", fresh.path], in: repo)
    let target = root.appendingPathComponent("stale-repo-target")
    git(["worktree", "add", "-q", "--detach", target.path], in: repo)

    // The main checkout installed before its lockfile moved to a 2.0.0; the other worktree is current
    // (the optional package for another platform isn't installed, as npm leaves it out).
    write("main", to: repo.appendingPathComponent("node_modules/a/marker"))
    npmInstall(repo, ["a": "1.0.0"])
    write("fresh", to: fresh.appendingPathComponent("node_modules/a/marker"))
    npmInstall(fresh, ["a": "2.0.0"])
    write("PODS: []", to: repo.appendingPathComponent("ios/Pods/Manifest.lock"))
    write("PODS: [A]", to: fresh.appendingPathComponent("ios/Pods/Manifest.lock"))

    let stale = BuildCaches.seed(worktree: target.path, from: [repo.path], dryRun: true)
    let reasons = Dictionary(uniqueKeysWithValues: stale.skipped.map { ($0.path, $0.reason) })
    expect(stale.seeded.isEmpty && reasons["node_modules"]?.contains("isn't installed from its package-lock.json") == true
           && reasons["ios/Pods"]?.contains("Podfile.lock") == true, "a stale install isn't cloned: \(reasons)")

    let result = BuildCaches.seed(worktree: target.path, from: [repo.path, fresh.path])
    expect(result.seeded.sorted() == ["ios/Pods", "node_modules"] && result.skipped.isEmpty,
           "the current install is cloned instead: \(result.seeded) \(result.skipped.map(\.reason))")
    expect((try? String(contentsOf: target.appendingPathComponent("node_modules/a/marker"), encoding: .utf8)) == "fresh",
           "it comes from the current checkout")

    // Changed patches would leave the clone's packages patched differently.
    let patched = root.appendingPathComponent("stale-repo-patched")
    git(["worktree", "add", "-q", "--detach", patched.path], in: repo)
    write("other diff", to: patched.appendingPathComponent("patches/a+2.0.0.patch"))
    let reason = BuildCaches.seed(worktree: patched.path, from: [fresh.path], dryRun: true).skipped
        .first { $0.path == "node_modules" }?.reason
    expect(reason == "patches/ differs", "different patches skip: \(reason ?? "nil")")
}

// MARK: - Build root

do {
    let folder = root.appendingPathComponent("nas")
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    expect(BuildCaches.buildRoot(["CANTRIP_BUILD_ROOT": folder.path])?.path == folder.path, "a writable build root is used")
    expect(BuildCaches.buildRoot(["CANTRIP_BUILD_ROOT": "/Volumes/NotMounted-\(UUID().uuidString)"]) == nil,
           "an unmounted build root falls back to local")
    expect(BuildCaches.buildRoot([:]) == nil, "no build root without the variable")
}

// MARK: - Sweeping build folders

do {
    let home = root.appendingPathComponent("home")
    let agentCache = home.appendingPathComponent(".cache/Cantrip")
    let coding = home.appendingPathComponent("Coding")
    let xcode = home.appendingPathComponent("DerivedData")

    // Agents' ad hoc DerivedData: idle, recent, in use, and a QA kit beside one.
    let oldAgent = agentCache.appendingPathComponent("sw-dd")
    derivedData(oldAgent, workspace: coding.appendingPathComponent("app/App.xcodeproj").path)
    age(oldAgent, longAgo)
    let recentAgent = agentCache.appendingPathComponent("sw-dd2")
    derivedData(recentAgent, workspace: "/x/App.xcodeproj")
    age(recentAgent, longAgo)
    // Xcode records the last build even when the files are older.
    try! PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": "/x", "LastAccessedDate": now],
                                        format: .xml, options: 0).write(to: recentAgent.appendingPathComponent("info.plist"))
    try? fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: recentAgent.appendingPathComponent("info.plist").path)
    try? fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: recentAgent.path)
    let kit = agentCache.appendingPathComponent("qa-kit")
    write("struct Host {}", to: kit.appendingPathComponent("Host.swift"))
    derivedData(kit.appendingPathComponent("dd"), workspace: "/x")
    age(kit, longAgo)
    let busyAgent = agentCache.appendingPathComponent("busy-dd")
    derivedData(busyAgent, workspace: "/x")
    age(busyAgent, longAgo)
    // A child worktree's own build output goes with the worktree.
    let childWorktree = agentCache.appendingPathComponent("worktrees/ABC")
    write("gitdir: /x", to: childWorktree.appendingPathComponent(".git"))
    derivedData(childWorktree.appendingPathComponent("dd"), workspace: "/x")
    age(childWorktree, longAgo)

    // A checkout: ignored stale clones go, recent ones and tracked folders stay.
    let app = coding.appendingPathComponent("app")
    write(".spm/\nbuild/\n", to: app.appendingPathComponent(".gitignore"))
    write("x", to: app.appendingPathComponent("tracked-clones/keep.txt"))
    git(["init", "-q"], in: app)
    packageClones(app.appendingPathComponent("tracked-clones"))
    git(["add", "."], in: app)
    git(["commit", "-q", "-m", "init"], in: app)
    // A tracked folder shaped like clones (keep.txt makes it not one), plus one only checkouts/repositories.
    let staleSPM = app.appendingPathComponent(".spm")
    packageClones(staleSPM)
    age(staleSPM, longAgo)
    let staleBuild = app.appendingPathComponent("build/Debug")
    derivedData(staleBuild, workspace: app.appendingPathComponent("App.xcodeproj").path)
    age(app.appendingPathComponent("build"), longAgo)
    let liveBuild = app.appendingPathComponent("build/Release")
    derivedData(liveBuild, workspace: app.appendingPathComponent("App.xcodeproj").path)
    // A resolve that changed nothing: only git's read of a checkout's index shows the use.
    let usedSPM = app.appendingPathComponent("build/used-spm")
    packageClones(usedSPM)
    write("index", to: usedSPM.appendingPathComponent("checkouts/swift-collections/.git/index"))
    age(usedSPM, longAgo)
    var times = [timespec(tv_sec: time(nil), tv_nsec: 0), timespec(tv_sec: Int(longAgo.timeIntervalSince1970), tv_nsec: 0)]
    utimensat(AT_FDCWD, usedSPM.appendingPathComponent("checkouts/swift-collections/.git/index").path, &times, 0)
    let trackedClones = coding.appendingPathComponent("app/vendored")
    packageClones(trackedClones)
    git(["add", "-f", "vendored"], in: app)
    git(["commit", "-q", "-m", "vendored"], in: app)
    age(trackedClones, longAgo)

    // Xcode's DerivedData: a removed worktree's project, a live one, one on an unmounted volume.
    let orphan = xcode.appendingPathComponent("App-orphan")
    derivedData(orphan, workspace: root.appendingPathComponent("gone/App.xcodeproj").path)
    age(orphan, yesterday)
    let live = xcode.appendingPathComponent("App-live")
    derivedData(live, workspace: app.path)
    age(live, longAgo)
    let unmounted = xcode.appendingPathComponent("App-nas")
    derivedData(unmounted, workspace: "/Volumes/NotMounted-\(UUID().uuidString)/App.xcodeproj")
    age(unmounted, longAgo)

    var options = BuildCaches.SweepOptions(home: home, agentCache: agentCache, repositoryParents: [coding],
                                           buildRoots: [xcode], sharedCaches: [], now: now)
    options.git = "/usr/bin/git"
    let processes = StorageUpkeep.ProcessSnapshot(workingDirectories: [busyAgent.path], commandLines: [])

    let preview = BuildCaches.sweep(options, processes: processes, dryRun: true)
    let previewed = Set(preview.removed.map(\.path))
    let expected: Set<String> = [oldAgent.path, kit.appendingPathComponent("dd").path, staleSPM.path, staleBuild.path,
                                 orphan.path]
    expect(previewed == expected, "build folders to remove: \(previewed.sorted())")
    expect(exists(oldAgent) && exists(staleSPM), "a dry run removes nothing")

    let report = BuildCaches.sweep(options, processes: processes, dryRun: false)
    expect(Set(report.removed.map(\.path)) == expected && report.errors.isEmpty, "removed: \(report.removed.map(\.path))")
    expect(!exists(oldAgent) && !exists(staleSPM) && !exists(staleBuild) && !exists(orphan), "stale folders are gone")
    expect(exists(recentAgent), "a DerivedData Xcode used recently stays")
    expect(exists(kit.appendingPathComponent("Host.swift")), "a QA kit beside a DerivedData stays")
    expect(exists(busyAgent), "a DerivedData a process uses stays")
    expect(exists(childWorktree.appendingPathComponent("dd")), "a worktree's own build output stays")
    expect(exists(liveBuild), "a recent build stays")
    expect(exists(usedSPM), "SwiftPM clones a build read recently stay")
    expect(exists(trackedClones) && exists(app.appendingPathComponent("tracked-clones")), "tracked folders stay")
    expect(exists(live), "a DerivedData whose project exists stays")
    expect(exists(unmounted), "a DerivedData whose volume is unmounted stays")
    expect(report.bytesRemoved > 0 && report.count == expected.count, "the report counts removals")
}

// MARK: - Shared caches

do {
    let home = root.appendingPathComponent("caches-home")
    let npx = home.appendingPathComponent(".npm/_npx")
    write(String(repeating: "x", count: 10_000), to: npx.appendingPathComponent("old/package.json"))
    age(npx.appendingPathComponent("old"), longAgo)
    write("x", to: npx.appendingPathComponent("new/package.json"))
    write("x", to: npx.appendingPathComponent("running/package.json"))
    age(npx.appendingPathComponent("running"), longAgo)

    let swiftpm = home.appendingPathComponent("swiftpm")
    for (name, date) in [("a", longAgo.addingTimeInterval(-86_400)), ("b", longAgo), ("c", now)] {
        let entry = swiftpm.appendingPathComponent("repositories/\(name)")
        write(String(repeating: "x", count: 200_000), to: entry.appendingPathComponent("pack"))
        age(entry, date)
    }
    let swiftpmBytes = StorageUpkeep.allocatedSize(swiftpm)

    let gradle = home.appendingPathComponent(".gradle")
    write("x", to: gradle.appendingPathComponent("caches/8.9/file-hashes/a.bin"))
    age(gradle.appendingPathComponent("caches/8.9"), longAgo)
    write("x", to: gradle.appendingPathComponent("caches/9.4.1/file-hashes/a.bin"))
    write("x", to: gradle.appendingPathComponent("caches/modules-2/a.bin"))
    age(gradle.appendingPathComponent("caches/modules-2"), longAgo)
    write("x", to: gradle.appendingPathComponent("wrapper/dists/gradle-8.9-bin/abc/gradle.zip"))
    write("x", to: gradle.appendingPathComponent("wrapper/dists/gradle-9.4.1-bin/abc/gradle.zip"))

    let npm = home.appendingPathComponent(".npm/_cacache")
    write(String(repeating: "x", count: 100_000), to: npm.appendingPathComponent("content-v2/a"))

    var ran: [[String]] = []
    let shared = [
        BuildCaches.SharedCache(name: "npx", path: npx, cap: nil, trim: .idleEntries(idle: 14 * 86_400), busyPattern: "(?!)"),
        // A cap of 300 kB: removing the oldest entry (a) is enough; c is recent anyway.
        BuildCaches.SharedCache(name: "SwiftPM", path: swiftpm, cap: swiftpmBytes - 150_000,
                                trim: .leastRecent(depth: 2, idle: 14 * 86_400), busyPattern: #"\bxcodebuild\b"#),
        BuildCaches.SharedCache(name: "Gradle", path: gradle, cap: nil, trim: .gradleVersions(idle: 14 * 86_400),
                                busyPattern: "GradleDaemon"),
        BuildCaches.SharedCache(name: "npm", path: npm, cap: 1_000, trim: .command("npm", ["cache", "verify"]),
                                busyPattern: #"\bnpm\s+(ci|install)\b"#),
    ]
    var options = BuildCaches.SweepOptions(home: home, agentCache: home.appendingPathComponent("none"),
                                           repositoryParents: [], buildRoots: [], sharedCaches: shared, now: now)
    options.run = { command, arguments in ran.append([command] + arguments); return true }

    let busy = StorageUpkeep.ProcessSnapshot(workingDirectories: [],
                                             commandLines: ["xcodebuild -scheme App build", "npm ci", "GradleDaemon 9.4.1",
                                                            "node \(npx.appendingPathComponent("running").path)/x.js"])
    let waiting = BuildCaches.sweep(options, processes: busy, dryRun: false)
    let byName = Dictionary(uniqueKeysWithValues: waiting.caches.map { ($0.name, $0) })
    expect(!exists(npx.appendingPathComponent("old")) && exists(npx.appendingPathComponent("new"))
           && exists(npx.appendingPathComponent("running")), "idle npx entries go, used ones stay")
    expect(exists(swiftpm.appendingPathComponent("repositories/a")) && byName["SwiftPM"]?.note != nil,
           "a cache in use by a build isn't trimmed: \(byName["SwiftPM"].debugDescription)")
    expect(exists(gradle.appendingPathComponent("caches/8.9")) && ran.isEmpty, "nothing trimmed while busy")

    let report = BuildCaches.sweep(options, processes: idle, dryRun: false)
    expect(!exists(swiftpm.appendingPathComponent("repositories/a")) && exists(swiftpm.appendingPathComponent("repositories/b"))
           && exists(swiftpm.appendingPathComponent("repositories/c")), "the least recent entries go until under the cap")
    expect(!exists(gradle.appendingPathComponent("caches/8.9")) && !exists(gradle.appendingPathComponent("wrapper/dists/gradle-8.9-bin"))
           && exists(gradle.appendingPathComponent("caches/9.4.1")) && exists(gradle.appendingPathComponent("caches/modules-2"))
           && exists(gradle.appendingPathComponent("wrapper/dists/gradle-9.4.1-bin")),
           "an unused Gradle version's caches and wrapper go, shared ones stay")
    expect(ran == [["npm", "cache", "verify"]], "the tool's own cleanup runs over its cap: \(ran)")
    let swiftpmSize = report.caches.first { $0.name == "SwiftPM" }
    expect(swiftpmSize.map { $0.bytesAfter < $0.bytes && $0.bytesAfter <= $0.cap! } == true, "sizes before and after")
}

if failures == 0 {
    print("Build cache tests passed")
} else {
    exit(1)
}
