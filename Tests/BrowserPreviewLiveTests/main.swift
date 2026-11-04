import Foundation
import ImageIO

// Live test of BrowserPreviewCapture against a throwaway, headed Google Chrome (its own profile
// and DevTools port, never the agent's). Needs a logged-in display and Screen Recording for
// `screencapture`: it watches the real window to check that streaming never changes what the
// window shows. Run with `make test-browser-preview-live` (temporary HOME).

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    } else {
        print("ok: \(message)")
    }
}

guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else {
    fputs("Run through `make test-browser-preview-live` (it sets a temporary HOME).\n", stderr)
    exit(2)
}

let port = 9561
UserDefaults.standard.register(defaults: [BrowserPreview.portKey: port])
let window = (x: 0, y: 40, width: 1200, height: 800)
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("browser-preview-live-\(UUID().uuidString)")
let chrome = Process()
chrome.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
chrome.arguments = ["--user-data-dir=\(profile.path)", "--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1",
                    "--no-first-run", "--no-default-browser-check", "--window-size=\(window.width),\(window.height)",
                    "--window-position=\(window.x),\(window.y)", "about:blank"]
chrome.standardOutput = FileHandle.nullDevice
chrome.standardError = FileHandle.nullDevice
try chrome.run()

func finish() -> Never {
    chrome.terminate()
    chrome.waitUntilExit()
    try? FileManager.default.removeItem(at: profile)
    if failures > 0 {
        fputs("\(failures) live browser preview check(s) failed\n", stderr)
        exit(1)
    }
    print("BrowserPreviewLiveTests passed")
    exit(0)
}

struct Page: Decodable { let id: String; let type: String; let url: String; let webSocketDebuggerUrl: String? }

func pages() async -> [Page] {
    guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!) else { return [] }
    return ((try? JSONDecoder().decode([Page].self, from: data)) ?? []).filter { $0.type == "page" }
}

/// The test's own DevTools connection, used to set pages up (and to capture the old way once).
final class Driver: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    var id = 0
    init(_ page: Page) {
        socket = URLSession.shared.webSocketTask(with: URL(string: page.webSocketDebuggerUrl!)!)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
    }
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        id += 1
        let mine = id
        let body = try JSONSerialization.data(withJSONObject: ["id": mine, "method": method, "params": params])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        while true {
            guard case .string(let text) = try await socket.receive(),
                  let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["id"] as? Int == mine else { continue }
            return object["result"] as? [String: Any] ?? [:]
        }
    }
    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        return (result["result"] as? [String: Any])?["value"]
    }
}

func writeState(target: String, url: String, policy: String = "allow") throws {
    let file = BrowserPreview.stateFile
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    try Data(#"{"targetId":"\#(target)","url":"\#(url)","title":"Live test","tool":"click","updatedAt":"\#(stamp)","policy":"\#(policy)"}"#.utf8)
        .write(to: file)
}

/// Whether the window's lower-right page area shows the page's blue (not Chrome's gray backdrop,
/// which shows when the page is re-rendered at a screenshot's smaller size).
func windowShowsWholePage() -> Bool? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("bp-live-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-R\(window.x),\(window.y),\(window.width),\(window.height)", file.path]
    guard (try? shot.run()) != nil else { return nil }
    shot.waitUntilExit()
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let scale = Double(image.width) / Double(window.width)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let x = Double(window.width - 80) * scale, y = Double(window.height - 60) * scale
    context.draw(image, in: CGRect(x: -x, y: -(Double(image.height) - y), width: Double(image.width), height: Double(image.height)))
    return pixel[2] > 180 && pixel[0] < 90
}

actor Flag { var on = true; func stop() { on = false }; func value() -> Bool { on } }

/// Screenshots the window while `flag` is on: (screenshots, screenshots that didn't show the whole page).
func watchWindow(_ flag: Flag) async -> (Int, Int) {
    var shots = 0, disturbed = 0
    while await flag.value() {
        guard let whole = windowShowsWholePage() else { continue }
        shots += 1
        if !whole { disturbed += 1 }
    }
    return (shots, disturbed)
}

var first: Page?
for _ in 0..<50 where first == nil {
    try await Task.sleep(for: .milliseconds(200))
    first = await pages().first
}
guard let tab = first else {
    expect(false, "Chrome started")
    finish()
}
let driver = Driver(tab)
let html = #"<!doctype html><body style="margin:0;background:#2080ff"><h1 id=n style="font:90px system-ui;color:white;margin:40px">0</h1><script>let i=0;window.timer=setInterval(()=>n.textContent=++i,100)</script>"#
try await driver.call("Page.navigate", ["url": "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!])
try await Task.sleep(for: .milliseconds(1200))
try writeState(target: tab.id, url: "data:text/html,live")
let capture = BrowserPreviewCapture()

// First picture.
var started = Date()
var frame = try await capture.frame(width: 600)
let firstLatency = Date().timeIntervalSince(started)
expect(firstLatency < 1.5, "first frame in \(Int(firstLatency * 1000)) ms")
expect(frame.width <= 600 && frame.width >= 500, "first frame \(frame.width)x\(frame.height) for a 600 request")

// Streaming a changing page: frames arrive as the page changes, and the window never changes.
let streaming = Flag()
let watcher = Task.detached { await watchWindow(streaming) }
started = Date()
var seqs: Set<Int> = [frame.seq]
var waits: [TimeInterval] = []
while Date().timeIntervalSince(started) < 4 {
    let asked = Date()
    frame = try await capture.frame(width: 600, after: frame.seq)
    waits.append(Date().timeIntervalSince(asked))
    seqs.insert(frame.seq)
}
await streaming.stop()
let (shots, disturbed) = await watcher.value
let fps = Double(seqs.count - 1) / 4
expect(fps >= 5, String(format: "changing page streams at %.1f frames/s", fps))
expect((waits.max() ?? 9) < 1, "longest wait for a changed page \(Int((waits.max() ?? 9) * 1000)) ms")
expect(shots >= 5 && disturbed == 0, "window undisturbed while streaming (\(disturbed) of \(shots) screenshots changed)")

// Control: the old clipped, scaled screenshot does disturb the window (so the check above can see it).
let oldWay = Flag()
let metrics = try await driver.call("Page.getLayoutMetrics")
let viewport = metrics["cssVisualViewport"] as? [String: Any] ?? [:]
let cssWidth = viewport["clientWidth"] as? Double ?? 1200, cssHeight = viewport["clientHeight"] as? Double ?? 700
let oldWatcher = Task.detached { await watchWindow(oldWay) }
let oldStart = Date()
while Date().timeIntervalSince(oldStart) < 3 {
    try await driver.call("Page.captureScreenshot", ["format": "jpeg", "quality": 62, "fromSurface": true,
                                                     "clip": ["x": 0, "y": 0, "width": cssWidth, "height": cssHeight, "scale": 0.5]])
}
await oldWay.stop()
let (oldShots, oldDisturbed) = await oldWatcher.value
expect(oldDisturbed > 0, "control: the old capture changed \(oldDisturbed) of \(oldShots) screenshots")

// A static page: a waiting request gets no new picture and returns the same one after waitSeconds.
_ = try await driver.evaluate("clearInterval(window.timer)")
try await Task.sleep(for: .milliseconds(500))
frame = try await capture.frame(width: 600)
let still = frame.seq
started = Date()
frame = try await capture.frame(width: 600, after: still)
let waited = Date().timeIntervalSince(started)
expect(frame.seq == still, "static page: no new picture (seq \(still) -> \(frame.seq))")
expect(abs(waited - BrowserPreview.waitSeconds) < 1.5, "static page: request waited \(String(format: "%.1f", waited)) s")

// Sizes: a wider view widens the stream; a narrower request gets a scaled copy.
frame = try await capture.frame(width: 1200)
expect(frame.width > 1000, "wide request gets \(frame.width) px")
frame = try await capture.frame(width: 400)
expect(frame.width <= 400 && frame.width >= 380, "narrow request gets \(frame.width) px")

// Once the wide view's requests are 10 s old, the stream narrows again; with no requests it stops.
started = Date()
while Date().timeIntervalSince(started) < BrowserPreview.idleSeconds + 1 {
    frame = try await capture.frame(width: 600, after: frame.seq)
}
let narrowed = await capture.streamingWidth
expect(narrowed == 600, "stream narrows after the wide view closes (\(narrowed) px)")
try await Task.sleep(for: .seconds(BrowserPreview.idleSeconds + 2))
let stillStreaming = await capture.isStreaming
expect(!stillStreaming, "stream stops when nobody is watching")
started = Date()
frame = try await capture.frame(width: 600)
let restarted = await capture.isStreaming
expect(restarted && Date().timeIntervalSince(started) < 1.5, "stream restarts on the next request")

// A background tab still updates (plain screenshots) and stays in the background.
_ = try await driver.evaluate("window.timer=setInterval(()=>n.textContent=++i,100)")
var newTab = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json/new?about:blank")!)
newTab.httpMethod = "PUT"
_ = try await URLSession.shared.data(for: newTab)
try await Task.sleep(for: .milliseconds(800))
let hiddenBefore = try await driver.evaluate("document.visibilityState") as? String
expect(hiddenBefore == "hidden", "agent's tab is in the background")
frame = try await capture.frame(width: 600)
started = Date()
seqs = [frame.seq]
while Date().timeIntervalSince(started) < 3 {
    frame = try await capture.frame(width: 600, after: frame.seq)
    seqs.insert(frame.seq)
}
expect(seqs.count - 1 >= 4, "background tab: \(seqs.count - 1) new pictures in 3 s")
let hiddenAfter = try await driver.evaluate("document.visibilityState") as? String
expect(hiddenAfter == "hidden", "background tab wasn't brought forward")

// Switching tabs follows active.json.
if let second = await pages().first(where: { $0.id != tab.id }) {
    try writeState(target: second.id, url: "about:blank")
    frame = try await capture.frame(width: 600)
    expect(frame.url == "about:blank", "follows the agent to its new tab (\(frame.url))")

    // Private pages are never shown.
    let secondDriver = Driver(second)
    try await secondDriver.call("Page.navigate", ["url": "chrome://version"])
    try await Task.sleep(for: .milliseconds(900))
    do {
        _ = try await capture.frame(width: 600)
        expect(false, "chrome:// page refused")
    } catch let error as BrowserPreview.PreviewError {
        expect(error.status == 403, "chrome:// page refused (\(error.status))")
    }
} else {
    expect(false, "second tab opened")
}

// A page the agent's policy blocks is never shown.
try writeState(target: tab.id, url: "data:text/html,live", policy: "block")
do {
    _ = try await capture.frame(width: 600)
    expect(false, "blocked page refused")
} catch let error as BrowserPreview.PreviewError {
    expect(error.status == 403, "blocked page refused (\(error.status))")
}

finish()
