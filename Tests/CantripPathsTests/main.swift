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

// MARK: Source and release installs find their helper scripts

do {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("cantrip-install-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    func executable(_ url: URL) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    let checkout = root.appendingPathComponent("src")
    let sourceApp = checkout.appendingPathComponent("Cantrip.app")
    try? fileManager.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
    fileManager.createFile(atPath: checkout.appendingPathComponent("Makefile").path, contents: Data())
    executable(checkout.appendingPathComponent("Scripts/cantrip-mcp"))
    executable(sourceApp.appendingPathComponent("Contents/Resources/bin/cantrip-mcp"))
    executable(sourceApp.appendingPathComponent("Contents/Resources/bin/mail-refresh"))
    expect(CantripInstall.checkout(for: sourceApp)?.standardizedFileURL == checkout.standardizedFileURL, "a source install's checkout")
    expect(!CantripInstall.isRelease(sourceApp), "an app beside its checkout isn't a release")
    expect(CantripInstall.script("cantrip-mcp", app: sourceApp) == checkout.appendingPathComponent("Scripts/cantrip-mcp").path,
           "a source install runs the checkout's script")
    expect(CantripInstall.script("mail-refresh", app: sourceApp)
           == sourceApp.appendingPathComponent("Contents/Resources/bin/mail-refresh").path,
           "a script missing from the checkout falls back to the app's copy")

    let releaseApp = root.appendingPathComponent("Applications/Cantrip.app")
    executable(releaseApp.appendingPathComponent("Contents/Resources/bin/cantrip-mcp"))
    expect(CantripInstall.checkout(for: releaseApp) == nil, "a release install has no checkout")
    expect(CantripInstall.isRelease(releaseApp), "an app without a checkout is a release")
    expect(CantripInstall.script("cantrip-mcp", app: releaseApp)
           == releaseApp.appendingPathComponent("Contents/Resources/bin/cantrip-mcp").path,
           "a release install runs its own copy")
    let home = root.appendingPathComponent("home")
    expect(CantripInstall.script("messages-send", app: releaseApp, home: home)
           == home.appendingPathComponent("Coding/Cantrip/Scripts/messages-send").path,
           "a script found nowhere falls back to the usual checkout")
    expect(!CantripInstall.isRelease(root.appendingPathComponent("Cantrip")), "a bare binary isn't a release")

    // The command-line tool: ~/.local/bin/cantrip links to this app's CLI.
    executable(releaseApp.appendingPathComponent("Contents/Resources/bin/cantrip"))
    let cli = releaseApp.appendingPathComponent("Contents/Resources/bin/cantrip").path
    let link = home.appendingPathComponent(".local/bin/cantrip")
    let zshrc = home.appendingPathComponent(".zshrc")
    expect(CantripInstall.commandLineTool(app: releaseApp, home: home) == .missing, "no link yet")
    expect((try? CantripInstall.installCommandLineTool(app: releaseApp, home: home)) != nil, "installs")
    expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == cli, "the link points at the app's CLI")
    expect(CantripInstall.commandLineTool(app: releaseApp, home: home) == .installed, "reads as installed")
    let profile = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
    expect(profile.contains("export PATH=\"$HOME/.local/bin:$PATH\""), "PATH gets ~/.local/bin: \(profile)")
    _ = try? CantripInstall.installCommandLineTool(app: releaseApp, home: home)
    expect((try? String(contentsOf: zshrc, encoding: .utf8)) == profile, "PATH is added once")

    try? fileManager.removeItem(at: link)
    try? fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "/gone/Coding/Cantrip/Scripts/cantrip")
    if case .otherCantrip = CantripInstall.commandLineTool(app: releaseApp, home: home) {} else {
        expect(false, "a link to another checkout's CLI is another Cantrip")
    }
    _ = try? CantripInstall.installCommandLineTool(app: releaseApp, home: home)
    expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == cli, "installing replaces another Cantrip's link")

    try? fileManager.removeItem(at: link)
    fileManager.createFile(atPath: link.path, contents: Data("other".utf8))
    expect(CantripInstall.commandLineTool(app: releaseApp, home: home) == .blocked, "a real file isn't Cantrip's")
    expect((try? CantripInstall.installCommandLineTool(app: releaseApp, home: home)) == nil, "installing refuses to replace it")
    expect((try? String(contentsOf: link, encoding: .utf8)) == "other", "the other program stays")
    expect(Set(CantripInstall.bundledScripts) == ["cantrip", "cantrip-mcp", "mcp-on-demand", "messages-send", "mail-refresh"],
           "the bundled scripts match the Makefile's BUNDLED_SCRIPTS")
}

if failures == 0 {
    print("Cantrip paths and per-tab key tests passed")
} else {
    exit(1)
}
