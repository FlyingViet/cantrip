import Foundation

private var failures = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func best(
    _ query: String,
    from candidates: [(name: String, isRunning: Bool)]
) -> String? {
    guard let index = AppSearchMatcher.bestMatchIndex(
        query: query,
        candidates: candidates
    ) else { return nil }
    return candidates[index].name
}

private func testAppSearchRanking() {
    expect(
        best("chrome", from: [
            ("Chromium", false),
            ("Google Chrome", false),
        ]) == "Google Chrome",
        "an exact word should beat another app's prefix"
    )
    expect(
        best("saf", from: [
            ("Safari Technology Preview", false),
            ("Safari", true),
        ]) == "Safari",
        "running apps should win within the same match tier"
    )
    expect(
        best("code", from: [
            ("Xcode", false),
            ("Visual Studio Code", false),
        ]) == "Visual Studio Code",
        "an exact word should beat a substring"
    )
    expect(
        best("chrme", from: [
            ("Google Chrome", false),
            ("Chromium", false),
        ]) == "Google Chrome",
        "a small in-order typo should fuzzy match"
    )
    expect(
        best("rhc", from: [("Google Chrome", false)]) == nil,
        "out-of-order characters should not match"
    )
    expect(
        best("gcrm", from: [("Google Chrome", false)]) == nil,
        "widely scattered characters should not create broad matches"
    )
    expect(
        best("c", from: [("Google Chrome", false)]) == nil,
        "one-character queries should not match"
    )
    expect(
        best("CHROME", from: [("Google Chrome", false)]) == "Google Chrome",
        "matching should be case-insensitive"
    )
}

testAppSearchRanking()

if failures > 0 {
    fputs("\(failures) feature test(s) failed\n", stderr)
    exit(1)
}
print("All 8 feature tests passed")
