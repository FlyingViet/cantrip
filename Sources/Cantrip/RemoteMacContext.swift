import Foundation

/// What the person at this Mac had in front of them when they asked from Cantrip's panel while the
/// background agents run the tabs (`ClientAppDelegate`): the text selected in the frontmost app and
/// the screenshots the app took as the panel opened. A message's `macContext`. Only Cantrip on this
/// Mac may send it (`LocalClientKey`); the message then runs like one typed into the panel, with the
/// Mac's own context (`ChatSession.submitFromMac`).
struct RemoteMacContext: Equatable {
    struct Selection: Equatable {
        let text: String
        let appName: String
    }

    struct Screenshot: Equatable {
        let path: String
        /// 1-based, the main display first (`DisplayCapture.index`).
        let index: Int
        let isMain: Bool
    }

    var selection: Selection?
    var screenshots: [Screenshot] = []

    struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let maximumSelectionCharacters = 100_000
    static let maximumAppNameCharacters = 200
    static let maximumScreenshots = 8

    /// Parses a message's `macContext` (nil when absent). Screenshots must be files `ScreenCapture`
    /// writes (`screen-<time>-d<n>.jpg`) in `captureDirectory`, so the field can't point the agent at
    /// any other file.
    static func parse(_ value: Any?, captureDirectory: URL,
                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws -> RemoteMacContext? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["selection", "screenshots"]) else {
            throw Invalid("macContext takes selection and screenshots.")
        }
        var context = RemoteMacContext()
        if let raw = object["selection"], !(raw is NSNull) {
            guard let selection = raw as? [String: Any], Set(selection.keys) == ["text", "appName"],
                  let text = selection["text"] as? String, let appName = selection["appName"] as? String else {
                throw Invalid("macContext.selection takes text and appName.")
            }
            guard text.count <= maximumSelectionCharacters, appName.count <= maximumAppNameCharacters else {
                throw Invalid("The selected text is too long to send.")
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                context.selection = Selection(text: text, appName: app.isEmpty ? "the frontmost app" : app)
            }
        }
        if let raw = object["screenshots"], !(raw is NSNull) {
            guard let list = raw as? [[String: Any]], list.count <= maximumScreenshots else {
                throw Invalid("macContext.screenshots takes up to \(maximumScreenshots) screenshots.")
            }
            let directory = captureDirectory.standardizedFileURL.path
            for item in list {
                guard Set(item.keys) == ["path", "index", "isMain"],
                      let path = item["path"] as? String,
                      let index = (item["index"] as? NSNumber).flatMap({ isBoolean($0) ? nil : $0.intValue }),
                      (1...16).contains(index),
                      let isMain = (item["isMain"] as? NSNumber).flatMap({ isBoolean($0) ? $0.boolValue : nil })
                else { throw Invalid("Each screenshot takes path, index (1-16) and isMain.") }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.deletingLastPathComponent().path == directory,
                      isCaptureName(url.lastPathComponent), fileExists(url.path) else {
                    throw Invalid("A screenshot isn't one Cantrip took on this Mac.")
                }
                context.screenshots.append(Screenshot(path: url.path, index: index, isMain: isMain))
            }
        }
        return context
    }

    /// `screen-<seconds>-d<display>.jpg`, as `ScreenCapture` names its files.
    static func isCaptureName(_ name: String) -> Bool {
        guard name.hasPrefix("screen-"), name.hasSuffix(".jpg") else { return false }
        let middle = name.dropFirst("screen-".count).dropLast(".jpg".count)
        let parts = middle.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let stamp = parts.first, !stamp.isEmpty, stamp.allSatisfy(\.isASCIIDigit),
              let display = parts.last, display.hasPrefix("d") else { return false }
        let digits = display.dropFirst()
        return !digits.isEmpty && digits.count <= 2 && digits.allSatisfy(\.isASCIIDigit)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
