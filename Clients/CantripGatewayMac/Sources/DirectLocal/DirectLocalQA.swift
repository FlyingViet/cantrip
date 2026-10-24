#if DEBUG
import AppKit
import SwiftUI

/// Debug-only QA driver for direct local mode, so the real UI can be exercised and captured on a
/// Mac where screenshots and UI scripting aren't available (e.g. over SSH). Launch arguments:
///   -DirectLocalQA YES            open Local Model at launch (skips the speech prompt)
///   -DirectLocalQAURL <url>       open Settings, Load Models with this server, pick a model, Save
///   -DirectLocalQAModel <name>    the model to pick (default: the first listed)
///   -DirectLocalQAPrompt <text>   send this message through the composer path and wait for the reply
///   -DirectLocalQASnapshots <dir> write PNGs of the app's own windows at each step
///   -DirectLocalQAHidden YES      keep the windows nearly transparent while it runs
///   -DirectLocalQAQuit YES        quit when done
@MainActor
enum DirectLocalQA {
    private static let defaults = UserDefaults.standard
    static var isActive: Bool { defaults.bool(forKey: "DirectLocalQA") }
    private static var settingsDone = false

    static func run(chat: DirectLocalChat, navigation: MacHomeNavigation) async {
        guard isActive else { return }
        log("start; saved \(chat.messages.count) messages, configured \(chat.isConfigured)")
        await pause(1)
        hideIfRequested()
        navigation.showDirectLocal()
        await pause(1.5)
        snapshot("1-open")
        if defaults.string(forKey: "DirectLocalQAURL") != nil {
            navigation.showingDirectLocalSettings = true
            for _ in 0..<120 where !settingsDone { await pause(0.5) }
            navigation.showingDirectLocalSettings = false
            await pause(1)
        }
        if let prompt = defaults.string(forKey: "DirectLocalQAPrompt"), chat.isConfigured {
            log("sending: \(prompt)")
            chat.send(prompt)
            await pause(1)
            snapshot("3-streaming")
            for _ in 0..<600 where chat.isReplying { await pause(0.5) }
            await pause(1)
            let reply = chat.messages.last
            log("reply: \(reply?.content.prefix(300) ?? "") error: \(reply?.error ?? "none")")
            snapshot("4-reply")
        }
        log("done; \(chat.messages.count) messages saved at \(DirectLocalStore().conversationURL.path)")
        if defaults.bool(forKey: "DirectLocalQAQuit") { NSApp.terminate(nil) }
    }

    /// Called from the settings sheet's `.task`: the same Load Models and Save as the buttons.
    static func settingsAppeared(_ view: MacDirectLocalSettingsView) async {
        guard isActive, !settingsDone, let url = defaults.string(forKey: "DirectLocalQAURL") else { return }
        hideIfRequested()
        view.setServer(url)
        await pause(0.5)
        await view.loadModels()
        if let model = defaults.string(forKey: "DirectLocalQAModel") { view.select(model) }
        await pause(1)
        log("models: \(view.chat.installedModels) error: \(view.chat.modelsError ?? "none")")
        snapshot("2-settings-models")
        view.save()
        settingsDone = true
    }

    static func snapshot(_ name: String) {
        guard let directory = defaults.string(forKey: "DirectLocalQASnapshots") else { return }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(index).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        log("snapshot \(name)")
    }

    private static func hideIfRequested() {
        guard defaults.bool(forKey: "DirectLocalQAHidden") else { return }
        for window in NSApp.windows { window.alphaValue = 0.02 }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("DirectLocalQA: \(text)\n".utf8))
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        hideIfRequested()
    }
}
#endif
