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

if failures == 0 {
    print("Tool PATH tests passed")
} else {
    exit(1)
}
