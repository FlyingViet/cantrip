import Foundation
import ImageIO

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// MARK: Tool names from each backend

expect(BrowserPreview.isBrowserTool("agent_chrome-click"), "Copilot naming")
expect(BrowserPreview.isBrowserTool("mcp__agent_chrome__page_read"), "Claude / Cantrip MCP naming")
expect(BrowserPreview.isBrowserTool("browser_mcp-screenshot"), "a server called browser, as Cantrip exports it")
expect(!BrowserPreview.isBrowserTool("agent_chromecast-play"), "other server with a similar prefix")
expect(BrowserPreview.isBrowserTool("browser-click"), "legacy Copilot naming in older history")
expect(BrowserPreview.isBrowserTool("mcp__browser__page_read"), "legacy Claude naming in older history")
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

// MARK: Stream width and scaling

expect(BrowserPreview.streamWidth(for: []) == 720, "no requests: default width")
expect(BrowserPreview.streamWidth(for: [560, 1600, 960]) == 1600, "widest recent request")
expect(BrowserPreview.streamWidth(for: [5_000]) == 1920, "clamped")
expect(!BrowserPreview.shouldScale(frameWidth: 1440, requested: 1440), "same width")
expect(!BrowserPreview.shouldScale(frameWidth: 1440, requested: 1300), "close enough: no re-encode")
expect(BrowserPreview.shouldScale(frameWidth: 1440, requested: 960), "card on a wide stream")

private func jpeg(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

do {
    let wide = jpeg(width: 1440, height: 1000)
    let size = BrowserPreview.jpegSize(wide)
    expect(size?.width == 1440 && size?.height == 1000, "JPEG size: \(String(describing: size))")
    expect(BrowserPreview.jpegSize(Data("not a jpeg".utf8)) == nil, "not a JPEG")
    let small = BrowserPreview.scaledJPEG(wide, width: 960)
    expect(small?.width == 960 && small?.height == 667, "scaled keeps the shape: \(String(describing: small.map { ($0.width, $0.height) }))")
    expect(small.flatMap { BrowserPreview.jpegSize($0.data) }?.width == 960, "scaled data is a 960-wide JPEG")
    let tall = BrowserPreview.scaledJPEG(jpeg(width: 800, height: 1600), width: 400)
    expect(tall?.width == 400 && tall?.height == 800, "portrait scales by width: \(String(describing: tall.map { ($0.width, $0.height) }))")
    let same = BrowserPreview.scaledJPEG(wide, width: 1920)
    expect(same?.data == wide && same?.width == 1440, "never scaled up")
}

// MARK: Frame JSON

do {
    let frame = BrowserPreview.Frame(data: Data([1, 2, 3]), width: 10, height: 5, url: "https://example.com", title: "Example",
                                     active: true, capturedAt: "2026-11-03T20:00:00Z", seq: 42)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any]
    expect(object?["seq"] as? Int == 42, "seq in the JSON")
    expect(object?["data"] as? String == "AQID", "data is base64")
} catch {
    expect(false, "frame JSON threw \(error)")
}

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
