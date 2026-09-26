import Foundation

/// Returns failure messages; empty when every pending-update case passes.
func pendingUpdateFailures() throws -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("cantrip-pending-update-tests-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let app = root.appendingPathComponent("Cantrip.app")
    let pending = PendingUpdate.pendingURL(for: app)
    let previous = PendingUpdate.previousURL(for: app)

    func makeBundle(_ url: URL, build: String, date: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.brian.agentspotlight",
                                  "CantripBuildIdentity": build, "CantripBuildDate": date]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(build.utf8).write(to: macOS.appendingPathComponent("Cantrip"))
    }
    func build(_ url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CantripBuildIdentity"] as? String
    }
    func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
    let valid: (URL) -> String? = { _ in nil }
    let idle: () -> Bool = { false }

    expect(pending.lastPathComponent == ".Cantrip.app.pending", "pending build should sit beside the app")
    try makeBundle(app, build: "old", date: "2026-09-26T15:44:57Z")
    expect(PendingUpdate.install(app: app, validate: valid, otherInstanceRunning: idle) == .none,
           "launch without a staged build should do nothing")
    expect(PendingUpdate.nextLaunchBundle(for: app) == app, "without a staged build the app itself launches next")

    // A running process keeps its executable identity until the file is replaced.
    let executable = app.appendingPathComponent("Contents/MacOS/Cantrip").path
    PendingUpdate.recordLaunchedExecutable(executable)
    expect(!PendingUpdate.launchedExecutableReplaced(executable), "untouched app files are not a restart problem")

    try makeBundle(pending, build: "new", date: "2026-09-26T19:00:00Z")
    expect(PendingUpdate.nextLaunchBundle(for: app) == pending, "a staged build is what the next launch installs")
    expect(!PendingUpdate.launchedExecutableReplaced(executable), "staging must leave the running app's files alone")

    var checks = 0
    let deferred = PendingUpdate.install(app: app, validate: valid, otherInstanceRunning: { checks += 1; return true },
                                         waitTimeout: 0.05, pollInterval: 0.01)
    if case .deferred = deferred {} else { failures.append("a live instance should defer installation") }
    expect(checks > 1, "installation should wait for a quitting instance before giving up")
    expect(build(app) == "old" && build(pending) == "new", "a deferred install must not move either bundle")

    var running = 3
    let installed = PendingUpdate.install(app: app, validate: valid,
                                          otherInstanceRunning: { running -= 1; return running > 0 },
                                          waitTimeout: 5, pollInterval: 0.01)
    expect(installed == .installed, "a valid newer build should install once the old instance exits")
    expect(build(app) == "new", "the app path should hold the staged build")
    expect(!exists(pending) && !exists(previous), "installation should leave no pending or previous bundle")
    expect(PendingUpdate.launchedExecutableReplaced(executable), "a replaced executable should require reopening")

    try makeBundle(pending, build: "broken", date: "2026-09-26T20:00:00Z")
    let invalid = PendingUpdate.install(app: app, validate: { _ in "invalid code signature" }, otherInstanceRunning: idle)
    if case .discarded = invalid {} else { failures.append("an invalid staged build should be discarded") }
    expect(build(app) == "new" && !exists(pending), "an invalid build must never replace the app")

    try makeBundle(pending, build: "older", date: "2026-09-26T18:00:00Z")
    let older = PendingUpdate.install(app: app, validate: valid, otherInstanceRunning: idle)
    if case .discarded = older {} else { failures.append("a staged build older than the app should be discarded") }
    expect(build(app) == "new" && !exists(pending), "an older build must never replace the app")

    try fileManager.removeItem(at: app)
    try makeBundle(pending, build: "fresh", date: "2026-09-26T21:00:00Z")
    expect(PendingUpdate.install(app: app, validate: valid, otherInstanceRunning: idle) == .installed,
           "a staged build should install when the app bundle is missing")
    expect(build(app) == "fresh" && !exists(pending), "the staged build should become the app")

    let plain = root.appendingPathComponent("Plain.app")
    try makeBundle(plain, build: "plain", date: "2026-09-26T21:00:00Z")
    expect(PendingUpdate.signatureProblem(in: plain, bundleIdentifier: "com.brian.agentspotlight") != nil,
           "an unsigned bundle should fail signature validation")
    expect(PendingUpdate.signatureProblem(in: plain, bundleIdentifier: "com.example.other")?
        .contains("does not match") == true, "another app's bundle identifier should be rejected")
    return failures
}
