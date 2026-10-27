import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let home = "/Users/example"
private let local = "\(home)/.local/bin"

private func path(_ inherited: String?) -> String {
    ToolPath.value(inherited: inherited, home: home)
}

// MARK: App launches keep today's PATH

do {
    let launchd = "/usr/bin:/bin:/usr/sbin:/sbin"
    let result = path(launchd)
    expect(result == "\(local):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
           "a Finder or launchd launch puts the tool folders ahead of the system folders: \(result)")
    expect(path(nil) == "\(local):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
           "no inherited PATH falls back to the system folders: \(path(nil))")
    expect(path("") == path(nil), "an empty PATH is treated like a missing one")

    let shellLike = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
    expect(path(shellLike) == "\(local):\(shellLike)",
           "a missing ~/.local/bin still goes ahead of Homebrew: \(path(shellLike))")
}

// MARK: A terminal's order is respected

do {
    let nvm = "/Users/example/.nvm/versions/node/v22/bin"
    let noHomebrew = path("\(nvm):/usr/bin:/bin")
    expect(noHomebrew == "\(nvm):\(local):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
           "the caller's node stays ahead of Homebrew's: \(noHomebrew)")

    let withHomebrew = path("\(nvm):/opt/homebrew/bin:/usr/bin:/bin")
    expect(withHomebrew == "\(nvm):\(local):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
           "folders the caller already has keep their place: \(withHomebrew)")

    let homebrewLast = path("/usr/bin:/bin:/opt/homebrew/bin")
    expect(homebrewLast == "\(local):/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
           "a caller that puts Homebrew after the system folders keeps it there: \(homebrewLast)")
}

// MARK: No duplicates, no empty entries

do {
    let once = path("/usr/bin:/bin")
    expect(path(once) == once, "applying it again changes nothing")
    let duplicated = path("/usr/bin:/opt/homebrew/bin:/usr/bin::/bin:/opt/homebrew/bin")
    let entries = duplicated.split(separator: ":", omittingEmptySubsequences: false)
    expect(Set(entries).count == entries.count, "duplicates are dropped: \(duplicated)")
    expect(!entries.contains(""), "empty entries (the current folder) are dropped: \(duplicated)")
    expect(duplicated == "\(local):/usr/local/bin:/usr/bin:/opt/homebrew/bin:/bin",
           "the first occurrence of each folder keeps its place: \(duplicated)")
}

// MARK: Environment

do {
    let environment = ToolPath.environment(["PATH": "/usr/bin:/bin", "NO_COLOR": "1"], home: home)
    expect(environment["PATH"] == path("/usr/bin:/bin"), "environment() sets PATH")
    expect(environment["NO_COLOR"] == "1" && environment.count == 2, "environment() keeps the other variables")
}

// MARK: Finding a CLI

final class ShellLookups: @unchecked Sendable {
    var names: [String] = []
    var answer: String?
}

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("cantrip-tool-locator-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: root) }
    func install(_ path: String, executable: Bool = true) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: executable ? 0o755 : 0o644])
    }
    let tool = "cantrip-test-tool-\(UUID().uuidString.prefix(8))"
    let shell = ShellLookups()
    let locator = ToolLocator(home: root, inheritedPATH: "/usr/bin:/bin") { name in
        shell.names.append(name); return shell.answer
    }

    install("\(root)/extra/\(tool)")
    install("\(root)/.local/bin/\(tool)")
    expect(locator.path(for: tool, extraFolders: ["~/extra"]) == "\(root)/.local/bin/\(tool)",
           "~/.local/bin comes before a tool's own install folder")
    expect(shell.names.isEmpty, "a CLI in a known folder doesn't start a login shell")

    try? fm.removeItem(atPath: "\(root)/.local/bin/\(tool)")
    expect(locator.path(for: tool, extraFolders: ["~/extra"]) == "\(root)/extra/\(tool)",
           "a remembered path that's gone is looked up again")

    let renamed = tool + "-renamed"
    install("\(root)/.local/bin/\(renamed)")
    expect(locator.path(for: tool, configured: renamed) == "\(root)/.local/bin/\(renamed)",
           "a configured bare name is looked up instead of the default name")
    install("\(root)/configured/\(tool)")
    expect(locator.path(for: tool, configured: " \(root)/configured/\(tool) ") == "\(root)/configured/\(tool)",
           "a configured executable path wins")
    install("\(root)/plain/\(tool)", executable: false)
    expect(locator.path(for: tool, configured: "\(root)/plain/\(tool)") == nil,
           "a configured path that isn't executable isn't returned")

    let missing = tool + "-missing"
    expect(locator.path(for: missing) == nil && shell.names == [missing], "a miss asks the login shell once")
    shell.answer = "\(root)/shell/\(missing)"
    expect(locator.path(for: missing) == nil, "a login-shell answer that isn't executable is rejected")
    install("\(root)/shell/\(missing)")
    expect(locator.path(for: missing) == "\(root)/shell/\(missing)",
           "a CLI installed after a miss is found: misses aren't remembered")
    let asked = shell.names.count
    expect(locator.path(for: missing) == "\(root)/shell/\(missing)" && shell.names.count == asked,
           "a found path is remembered")
    shell.answer = "\(missing): not found"
    expect(locator.path(for: missing + "-other") == nil, "a login-shell message that isn't a path is rejected")
    expect(locator.path(for: "-rf") == nil && locator.path(for: "") == nil, "option-like and empty names are refused")

    let quiet = ShellLookups()
    let unasked = tool + "-unasked"
    let noShell = ToolLocator(home: root, inheritedPATH: "/usr/bin:/bin") { name in
        quiet.names.append(name); return nil
    }
    expect(noShell.path(for: unasked, askLoginShell: false) == nil && quiet.names.isEmpty,
           "askLoginShell: false never starts a login shell")
    expect(noShell.copilotCommand(configured: "") == "copilot" || noShell.copilotCommand(configured: "").hasPrefix("/"),
           "copilotCommand falls back to the bare name when nothing is found")
    expect(noShell.copilotCommand(configured: " \(unasked) ") == unasked,
           "copilotCommand falls back to the configured name, trimmed")
    install("\(root)/.npm-global/bin/\(unasked)")
    expect(noShell.copilotCommand(configured: unasked) == "\(root)/.npm-global/bin/\(unasked)",
           "copilotCommand returns the located path, including Copilot's own install folder")

    let terminalOrder = tool + "-terminal"
    install("\(root)/nvm/bin/\(terminalOrder)")
    install("\(root)/.local/bin/\(terminalOrder)")
    let fromTerminal = ToolLocator(home: root, inheritedPATH: "\(root)/nvm/bin:/usr/bin:/bin") { _ in nil }
    expect(fromTerminal.path(for: terminalOrder) == "\(root)/nvm/bin/\(terminalOrder)",
           "a terminal's PATH order is respected, like the PATH tools get")
    let fromFinder = ToolLocator(home: root, inheritedPATH: "/usr/bin:/bin") { _ in nil }
    expect(fromFinder.path(for: terminalOrder) == "\(root)/.local/bin/\(terminalOrder)",
           "an app launch searches ~/.local/bin first")

    expect(ToolLocator.loginShellPath("sh") == "/bin/sh", "the real login shell finds sh")
    expect(ToolLocator.loginShellPath("cantrip-no-such-tool-\(UUID().uuidString.prefix(8))") == nil,
           "the real login shell reports a missing tool as nil")
}

if failures == 0 {
    print("Tool PATH and lookup tests passed")
} else {
    exit(1)
}
