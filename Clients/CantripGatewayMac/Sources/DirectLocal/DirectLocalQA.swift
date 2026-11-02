#if DEBUG
import AppKit
import SwiftUI

/// Debug-only QA driver for direct local mode, so the real UI can be exercised and captured on a
/// Mac where screenshots and UI scripting aren't available (e.g. over SSH). Launch arguments:
///   -DirectLocalQA YES            open Local Model at launch (skips the speech prompt)
///   -DirectLocalQAURL <url>       open Settings, Load Models with this server, pick a model, Save
///   -DirectLocalQAModel <name>    the model to pick (default: the first listed)
///   -DirectLocalQATools <a,b>     turn on these MCP servers (loading their tools) when saving settings
///   -DirectLocalQAToolNames <x,y> with -DirectLocalQATools: only these tools on
///   -DirectLocalQAApprove <once|always|deny>  answer tool approvals as the transcript buttons do
///   -DirectLocalQAExpandTools <a,b>  open these servers' tool lists in settings
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
            var answered = Set<UUID>()
            for _ in 0..<1200 where chat.isReplying {
                if let id = chat.awaitingApproval, !answered.contains(id),
                   let answer = defaults.string(forKey: "DirectLocalQAApprove") {
                    answered.insert(id)
                    snapshot("3-approval-\(answered.count)")
                    let call = chat.messages.last?.toolCalls.first { $0.id == id }
                    log("approval \(answer): \(call?.label ?? "?") \(call?.arguments ?? "")")
                    chat.respond(to: id, with: answer == "always" ? .always : answer == "deny" ? .deny : .once)
                }
                await pause(0.5)
            }
            await pause(1)
            let reply = chat.messages.last
            for call in reply?.toolCalls ?? [] {
                log("tool \(call.label) \(call.state.rawValue) args \(call.arguments) -> \(call.result?.prefix(200) ?? "")")
            }
            log("reply: \(reply?.displayText.prefix(600) ?? "") error: \(reply?.error ?? "none")")
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
        if let servers = defaults.string(forKey: "DirectLocalQATools") {
            let names = Set(servers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let only = defaults.string(forKey: "DirectLocalQAToolNames")
                .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            view.chat.refreshMCPServers()
            for server in view.chat.mcpServers where names.contains(server.name) {
                await view.chat.loadTools(for: server)
                let tools = view.chat.cachedTools(for: server) ?? []
                log("\(server.name): \(tools.count) tools, error: \(view.chat.toolErrors[server.name] ?? "none")")
                view.setTools(server.name, on: true, only: only, all: tools.map(\.name))
            }
            await pause(1)
            snapshot("2-settings-tools")
            scrollSheetsToBottom()
            await pause(1)
            snapshot("2-settings-tools-bottom")
        }
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

    /// Shows the end of the settings form (the tools section) for the next snapshot.
    private static func scrollSheetsToBottom() {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for window in NSApp.windows where window.sheetParent != nil {
            guard let root = window.contentView else { continue }
            for scrollView in scrollViews(in: root) {
                guard let document = scrollView.documentView else { continue }
                let y = document.isFlipped ? max(0, document.bounds.height - scrollView.contentView.bounds.height) : 0
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
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
