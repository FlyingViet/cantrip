import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try condition() { return }
    } catch {
        fputs("ERROR: \(error)\n", stderr)
    }
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

private func rejects(_ value: Any, _ message: String, exists: @escaping (String) -> Bool = { _ in true }) {
    do {
        _ = try RemoteMacContext.parse(value, captureDirectory: directory, fileExists: exists)
        expect(false, message)
    } catch is RemoteMacContext.Invalid {
    } catch {
        expect(false, "\(message): unexpected error \(error)")
    }
}

private let directory = URL(fileURLWithPath: "/Users/someone/.cache/Cantrip", isDirectory: true)
private let shot = directory.appendingPathComponent("screen-1762140000-d1.jpg").path

// Absent or null: no context.
expect(try RemoteMacContext.parse(nil, captureDirectory: directory) == nil, "nil is no context")
expect(try RemoteMacContext.parse(NSNull(), captureDirectory: directory) == nil, "null is no context")

// Selection and screenshots.
do {
    let parsed = try RemoteMacContext.parse([
        "selection": ["text": "let x = 1", "appName": "Xcode"],
        "screenshots": [["path": shot, "index": 1, "isMain": true]],
    ], captureDirectory: directory, fileExists: { $0 == shot })
    expect(parsed?.selection == .init(text: "let x = 1", appName: "Xcode"), "selection parsed")
    expect(parsed?.screenshots == [.init(path: shot, index: 1, isMain: true)], "screenshot parsed")
} catch {
    expect(false, "valid context: \(error)")
}

// An empty object is a panel message with nothing staged.
expect(try RemoteMacContext.parse([String: Any](), captureDirectory: directory) == RemoteMacContext(),
       "empty context")

// Blank selections are dropped; a blank app name gets a stand-in.
expect(try RemoteMacContext.parse(["selection": ["text": "  \n", "appName": "Notes"]],
                                  captureDirectory: directory)?.selection == nil, "blank selection dropped")
expect(try RemoteMacContext.parse(["selection": ["text": "hi", "appName": " "]],
                                  captureDirectory: directory)?.selection?.appName == "the frontmost app",
       "blank app name")

// Shape errors.
rejects("text", "a string")
rejects(["selection": ["text": "x", "appName": "A"], "extra": true], "unknown keys")
rejects(["selection": ["text": "x"]], "selection without appName")
rejects(["selection": ["text": 1, "appName": "A"]], "non-string text")
rejects(["selection": ["text": String(repeating: "a", count: RemoteMacContext.maximumSelectionCharacters + 1),
                       "appName": "A"]], "selection too long")
rejects(["screenshots": "x"], "screenshots not a list")
rejects(["screenshots": Array(repeating: ["path": shot, "index": 1, "isMain": true],
                              count: RemoteMacContext.maximumScreenshots + 1)], "too many screenshots")
rejects(["screenshots": [["path": shot, "index": 0, "isMain": true]]], "index 0")
rejects(["screenshots": [["path": shot, "index": true, "isMain": true]]], "boolean index")
rejects(["screenshots": [["path": shot, "index": 1, "isMain": 1]]], "numeric isMain")
rejects(["screenshots": [["path": shot, "index": 1]]], "missing isMain")

// Only Cantrip's own screenshot files.
rejects(["screenshots": [["path": "/etc/passwd", "index": 1, "isMain": true]]], "outside the capture folder")
rejects(["screenshots": [["path": directory.appendingPathComponent("secrets.json").path, "index": 1,
                          "isMain": true]]], "not a screenshot name")
rejects(["screenshots": [["path": directory.appendingPathComponent("../screen-1-d1.jpg").path, "index": 1,
                          "isMain": true]]], "escapes the folder")
rejects(["screenshots": [["path": directory.appendingPathComponent("sub/screen-1-d1.jpg").path, "index": 1,
                          "isMain": true]]], "a subfolder")
rejects(["screenshots": [["path": shot, "index": 1, "isMain": true]]], "a missing file", exists: { _ in false })

expect(RemoteMacContext.isCaptureName("screen-1762140000-d2.jpg"), "capture name")
for name in ["screen--d1.jpg", "screen-12-d.jpg", "screen-12-x1.jpg", "screen-12-d1.png", "screen-1a-d1.jpg",
             "screen-12-d1-2.jpg", "xscreen-12-d1.jpg", "screen-12-d123.jpg"] {
    expect(!RemoteMacContext.isCaptureName(name), "not a capture name: \(name)")
}

if failures > 0 {
    fputs("\(failures) mac context test(s) failed\n", stderr)
    exit(1)
}
print("mac context tests passed")
