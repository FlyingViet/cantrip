import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// MARK: Tool names from each backend

expect(BrowserPreview.isBrowserTool("browser-click"), "Copilot naming")
expect(BrowserPreview.isBrowserTool("mcp__browser__page_read"), "Claude / Cantrip MCP naming")
expect(!BrowserPreview.isBrowserTool("browsers-click"), "other server with a similar prefix")
expect(!BrowserPreview.isBrowserTool("mcp__personal__mail_search"), "other MCP server")
expect(!BrowserPreview.isBrowserTool("bash"), "built-in tool")

// MARK: Private pages are never shown

for url in ["chrome-extension://abc/popup/index.html", "CHROME://settings", "devtools://devtools/x", "file:///etc/hosts",
            "view-source:https://example.com", "chrome-untrusted://print"] {
    expect(BrowserPreview.isPrivate(url: url), "private: \(url)")
}
for url in ["https://example.com", "data:text/html,hi", "about:blank"] {
    expect(!BrowserPreview.isPrivate(url: url), "shown: \(url)")
}

// MARK: Width limits

expect(BrowserPreview.clampedWidth(nil) == 720, "default width")
expect(BrowserPreview.clampedWidth(10) == 240, "minimum width")
expect(BrowserPreview.clampedWidth(99_999) == 1920, "maximum width")

// MARK: State file and activity window

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("active.json")
    expect(BrowserPreview.readState(from: file) == nil, "missing file")
    try Data("not json".utf8).write(to: file)
    expect(BrowserPreview.readState(from: file) == nil, "invalid JSON")
    let now = Date(timeIntervalSince1970: 1_793_300_000)
    let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
    try Data(#"{"targetId":"T1","url":"https://example.com/","title":"Example","tool":"click","updatedAt":"\#(stamp)","policy":"allow"}"#.utf8).write(to: file)
    let state = BrowserPreview.readState(from: file)
    expect(state?.targetId == "T1" && state?.title == "Example", "parsed state: \(String(describing: state))")
    expect(BrowserPreview.isActive(state, now: now), "30 s ago is active")
    expect(!BrowserPreview.isActive(state, now: now.addingTimeInterval(200)), "230 s ago is idle")
    expect(!BrowserPreview.isActive(nil, now: now), "no state is idle")
    var old = state
    old?.updatedAt = nil
    expect(!BrowserPreview.isActive(old, now: now), "no timestamp is idle")
} catch {
    expect(false, "state file test threw \(error)")
}

if failures > 0 {
    fputs("\(failures) browser preview test(s) failed\n", stderr)
    exit(1)
}
print("BrowserPreviewTests passed")
