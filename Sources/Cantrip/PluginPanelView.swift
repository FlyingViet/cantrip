import SwiftUI
import WebKit

/// Renders a plugin's HTML dashboard in a side pane. The page gets a small
/// bridge injected as `window.cantrip`:
///   cantrip.sendPrompt(text) — submit a query to the active session
///   cantrip.log(text)        — write to Cantrip.log (debugging)
/// Network access from the page is unrestricted (fetch to a Home Assistant
/// box, a local API, the internet) — which is exactly why plugins require
/// explicit approval before they run.
struct PluginPanelView: NSViewRepresentable {
    let plugin: Plugin
    /// Bumped by the pane's reload button to force a fresh load.
    let reloadToken: Int
    let onPrompt: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrompt: onPrompt, pluginRoot: plugin.directory)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cantrip")
        // Main frame ONLY: an embedded remote iframe must never get the
        // bridge — sendPrompt drives the agent, which may have actions
        // enabled. The handler double-checks the sender's origin too.
        controller.addUserScript(WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        config.userContentController = controller
        // file:// pages need this to fetch http(s) endpoints (CORS origin
        // is null for local files). Key is unofficial but long-stable.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // blend with the panel
        context.coordinator.load(plugin, into: webView, token: reloadToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPrompt = onPrompt
        context.coordinator.load(plugin, into: webView, token: reloadToken)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "cantrip")
    }

    private static let bridgeJS = """
    window.cantrip = {
        sendPrompt: function (text) {
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: "prompt", text: String(text) });
        },
        log: function (text) {
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: "log", text: String(text) });
        }
    };
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onPrompt: (String) -> Void
        private let pluginRoot: URL
        private var loadedKey: String?

        init(onPrompt: @escaping (String) -> Void, pluginRoot: URL) {
            self.onPrompt = onPrompt
            self.pluginRoot = pluginRoot
        }

        /// (Re)load only when the plugin or reload token changes — SwiftUI
        /// calls updateNSView on every render and a reload each time would
        /// wipe the page's state.
        func load(_ plugin: Plugin, into webView: WKWebView, token: Int) {
            guard let url = plugin.panelURL else { return }
            let key = "\(plugin.id)|\(plugin.manifestHash)|\(token)"
            guard key != loadedKey else { return }
            loadedKey = key
            webView.loadFileURL(url, allowingReadAccessTo: plugin.directory)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // Belt & suspenders with forMainFrameOnly: only the plugin's
            // own file may talk to the bridge — never remote content.
            let root = pluginRoot.standardizedFileURL.resolvingSymlinksInPath().path
            // frameInfo.request.url can be nil in odd navigation states;
            // the webView's committed main-frame URL is the safe fallback
            // (an iframe can't spoof it).
            guard message.frameInfo.isMainFrame,
                  let sender = message.frameInfo.request.url ?? message.webView?.url,
                  sender.isFileURL,
                  sender.standardizedFileURL.resolvingSymlinksInPath().path
                      .hasPrefix(root + "/")
            else { return }
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let text = body["text"] as? String else { return }
            switch type {
            case "prompt":
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onPrompt(trimmed)
            case "log":
                Log.write("plugin: \(String(text.prefix(500)))")
            default:
                break
            }
        }
    }
}
