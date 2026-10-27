import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// MARK: Cache paths

do {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    expect(CantripPaths.cache.path == home + "/.cache/Cantrip", "the cache folder: \(CantripPaths.cache.path)")
    expect(CantripPaths.cache.hasDirectoryPath, "the cache folder is a directory URL")
    expect(CantripPaths.cache("notifications/state.json").path == home + "/.cache/Cantrip/notifications/state.json",
           "a nested file: \(CantripPaths.cache("notifications/state.json").path)")
    expect(!CantripPaths.cache("host.lock").hasDirectoryPath, "files aren't directory URLs")
    expect(CantripPaths.cache("worktrees", isDirectory: true).hasDirectoryPath, "folders can be directory URLs")
}

// MARK: Per-tab keys keep their saved names

do {
    let id = UUID(uuidString: "6A1F0C3E-2B7D-4E59-9A44-0D5C1E2F3A4B")!
    let tag = id.uuidString
    expect(TabDefaults.workdir(id) == "workdir-\(tag)", "workdir key")
    expect(TabDefaults.claudeSession(id) == "claudeSessionID-\(tag)", "Claude session key")
    expect(TabDefaults.codexSession(id) == "codexSessionID-\(tag)", "Codex session key")
    expect(TabDefaults.lastRunOutcome(id) == "lastRunOutcome-\(tag)", "last run outcome key")
    expect(TabDefaults.councilClaude(id, seat: 2, model: "opus") == "councilClaude-\(tag)-2-opus", "council Claude key")
    expect(TabDefaults.councilCodex(id, seat: 0, model: "") == "councilCodex-\(tag)-0-", "council Codex key")
}

// MARK: Removing a tab removes all of its keys and only its keys

do {
    let suite = "cantrip-tab-defaults-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = UUID(), other = UUID()
    let mine = [TabDefaults.workdir(id), TabDefaults.claudeSession(id), TabDefaults.codexSession(id),
                TabDefaults.lastRunOutcome(id), TabDefaults.councilClaude(id, seat: 0, model: "a"),
                TabDefaults.councilClaude(id, seat: 3, model: "b"), TabDefaults.councilCodex(id, seat: 1, model: "c")]
    let theirs = [TabDefaults.workdir(other), TabDefaults.councilClaude(other, seat: 0, model: "a"), "workdir-elsewhere"]
    for key in mine + theirs { defaults.set("value", forKey: key) }
    TabDefaults.removeAll(for: id, in: defaults)
    expect(mine.allSatisfy { defaults.object(forKey: $0) == nil },
           "every key of the removed tab is gone: \(mine.filter { defaults.object(forKey: $0) != nil })")
    expect(theirs.allSatisfy { defaults.string(forKey: $0) == "value" }, "other tabs' keys stay")

    for key in mine { defaults.set("value", forKey: key) }
    TabDefaults.removeCouncilSeats(for: id, in: defaults)
    expect(mine.filter { $0.hasPrefix("council") }.allSatisfy { defaults.object(forKey: $0) == nil },
           "a new conversation forgets the council seats")
    expect(mine.filter { !$0.hasPrefix("council") }.allSatisfy { defaults.string(forKey: $0) == "value" },
           "a new conversation keeps the tab's other keys")
}

if failures == 0 {
    print("Cantrip paths and per-tab key tests passed")
} else {
    exit(1)
}
