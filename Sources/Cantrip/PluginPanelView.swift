import SwiftUI
import WebKit
import AppKit

/// Renders a plugin's HTML dashboard in a side pane. The page gets a small
/// bridge injected as `window.cantrip`:
///   cantrip.sendPrompt(text) — submit a query to the active session
///   cantrip.log(text)        — write to Cantrip.log (debugging)
///   cantrip.openURL(url)      — open an HTTP(S) URL in the default browser
///   cantrip.requestData(name) — read an approved native data source
///   cantrip.runAction(name)   — run an approved fixed Cantrip action
/// Network access from the page is unrestricted (fetch to a Home Assistant
/// box, a local API, the internet) — which is exactly why plugins require
/// explicit approval before they run.
struct PluginPanelView: NSViewRepresentable {
    let plugin: Plugin
    /// Bumped by the pane's reload button to force a fresh load.
    let reloadToken: Int
    let onPrompt: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrompt: onPrompt, plugin: plugin)
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
        webView.uiDelegate = context.coordinator
        context.coordinator.load(plugin, into: webView, token: reloadToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPrompt = onPrompt
        context.coordinator.load(plugin, into: webView, token: reloadToken)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.uiDelegate = nil
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "cantrip")
    }

    private static let bridgeJS = """
    (function () {
    var nextRequestID = 1;
    var pendingRequests = new Map();
    window.__cantripResolve = function (id, envelope) {
        var pending = pendingRequests.get(id);
        if (!pending) return;
        pendingRequests.delete(id);
        if (envelope.ok) pending.resolve(envelope.value);
        else pending.reject(new Error(envelope.error || "Cantrip request failed"));
    };
    function request(type, name) {
        return new Promise(function (resolve, reject) {
            var id = nextRequestID++;
            pendingRequests.set(id, { resolve: resolve, reject: reject });
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: type, name: String(name), id: id });
        });
    }
    window.cantrip = {
        sendPrompt: function (text) {
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: "prompt", text: String(text) });
        },
        log: function (text) {
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: "log", text: String(text) });
        },
        openURL: function (url) {
            window.webkit.messageHandlers.cantrip.postMessage(
                { type: "openURL", text: String(url) });
        },
        requestData: function (name) {
            return request("requestData", name);
        },
        runAction: function (name) {
            return request("runAction", name);
        }
    };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        var onPrompt: (String) -> Void
        private let pluginRoot: URL
        private let allowedCapabilities: Set<String>
        private let dataSources: [String: PluginManifest.DataSourceSpec]
        private var loadedKey: String?

        init(onPrompt: @escaping (String) -> Void, plugin: Plugin) {
            self.onPrompt = onPrompt
            self.pluginRoot = plugin.directory
            self.allowedCapabilities = Set(plugin.manifest.panel?.capabilities ?? [])
            self.dataSources = plugin.manifest.dataSources ?? [:]
        }

        /// (Re)load only when the plugin or reload token changes — SwiftUI
        /// calls updateNSView on every render and a reload each time would
        /// wipe the page's state.
        func load(_ plugin: Plugin, into webView: WKWebView, token: Int) {
            guard let url = plugin.panelURL else { return }
            let key = "\(plugin.id)|\(plugin.manifestHash)|\(plugin.contentRevision)|\(token)"
            guard key != loadedKey else { return }
            loadedKey = key
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            let readRoot = plugin.directory.standardizedFileURL.resolvingSymlinksInPath()
            webView.loadFileRequest(request, allowingReadAccessTo: readRoot)
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
                  let type = body["type"] as? String else { return }
            switch type {
            case "prompt":
                guard let text = body["text"] as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onPrompt(trimmed)
            case "log":
                guard let text = body["text"] as? String else { return }
                Log.write("plugin: \(String(text.prefix(500)))")
            case "openURL":
                guard let text = body["text"] as? String else { return }
                guard let url = URL(string: text),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      url.host != nil,
                      url.user == nil,
                      url.password == nil
                else {
                    Log.write("plugin: blocked invalid openURL request")
                    return
                }
                if !NSWorkspace.shared.open(url) {
                    Log.write("plugin: failed to open \(url.absoluteString)")
                }
            case "requestData":
                guard let id = body["id"] as? Int,
                      let name = body["name"] as? String else { return }
                requestData(name, id: id, webView: message.webView)
            case "runAction":
                guard let id = body["id"] as? Int,
                      let name = body["name"] as? String else { return }
                runAction(name, id: id, webView: message.webView)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            guard frame.isMainFrame else {
                completionHandler(false)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(message.prefix(500))
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    completionHandler(response == .alertFirstButtonReturn)
                }
            } else {
                completionHandler(alert.runModal() == .alertFirstButtonReturn)
            }
        }

        private func requestData(_ name: String, id: Int, webView: WKWebView?) {
            if name == "dailyBriefing"
                || name == "dailyBriefing.calendar"
                || name == "dailyBriefing.calendar.refresh"
                || name == "dailyBriefing.mail"
                || name == "dailyBriefing.mail.refresh"
                || name == "dailyBriefing.messages"
                || name == "dailyBriefing.messages.refresh" {
                guard allowedCapabilities.contains("dailyBriefing") else {
                    respond(
                        id: id,
                        error: "Plugin has not declared the dailyBriefing capability",
                        in: webView
                    )
                    return
                }
                let forceRefresh = name.hasSuffix(".refresh")
                switch name {
                case "dailyBriefing":
                    PluginPanelData.dailyBriefing { [weak self, weak webView] result in
                        self?.respond(id: id, result: result, in: webView)
                    }
                case "dailyBriefing.calendar", "dailyBriefing.calendar.refresh":
                    PluginPanelData.dailyBriefingCalendar(
                        forceRefresh: forceRefresh
                    ) { [weak self, weak webView] result in
                        self?.respond(id: id, result: result, in: webView)
                    }
                case "dailyBriefing.mail", "dailyBriefing.mail.refresh":
                    PluginPanelData.dailyBriefingMail(
                        forceRefresh: forceRefresh
                    ) { [weak self, weak webView] result in
                        self?.respond(id: id, result: result, in: webView)
                    }
                case "dailyBriefing.messages", "dailyBriefing.messages.refresh":
                    PluginPanelData.dailyBriefingMessages(
                        forceRefresh: forceRefresh
                    ) { [weak self, weak webView] result in
                        self?.respond(id: id, result: result, in: webView)
                    }
                default:
                    break
                }
                return
            }
            if allowedCapabilities.contains(name) {
                switch name {
                case "cantripStatus":
                    PluginPanelData.cantripStatus { [weak self, weak webView] result in
                        self?.respond(id: id, result: result, in: webView)
                    }
                default:
                    respond(id: id, error: "Unknown data capability: \(name)", in: webView)
                }
                return
            }
            guard let source = dataSources[name] else {
                respond(id: id, error: "Plugin has not declared the \(name) data source",
                        in: webView)
                return
            }
            PluginPanelData.pluginDataSource(
                source,
                pluginRoot: pluginRoot
            ) { [weak self, weak webView] result in
                self?.respond(id: id, result: result, in: webView)
            }
        }

        private func runAction(_ name: String, id: Int, webView: WKWebView?) {
            guard allowedCapabilities.contains("cantripActions") else {
                respond(id: id, error: "Plugin has not declared the cantripActions capability",
                        in: webView)
                return
            }
            let repo = PluginPanelData.repoURL
            switch name {
            case "update":
                onPrompt("!" + UpdateChecker.shared.updateCommand)
            case "build":
                onPrompt("! make -C '\(repo.path)' app")
            case "relaunch":
                onPrompt("! make -C '\(repo.path)' run")
            case "openRepo":
                guard NSWorkspace.shared.open(repo) else {
                    respond(id: id, error: "Could not open the Cantrip repository", in: webView)
                    return
                }
            case "openLog":
                guard NSWorkspace.shared.open(PluginPanelData.logURL) else {
                    respond(id: id, error: "Could not open Cantrip.log", in: webView)
                    return
                }
            default:
                respond(id: id, error: "Unknown Cantrip action: \(name)", in: webView)
                return
            }
            respond(id: id, value: ["started": true, "action": name], in: webView)
        }

        private func respond(id: Int, result: Result<[String: Any], Error>,
                             in webView: WKWebView?) {
            switch result {
            case .success(let value):
                respond(id: id, value: value, in: webView)
            case .failure(let error):
                respond(id: id, error: error.localizedDescription, in: webView)
            }
        }

        private func respond(id: Int, value: [String: Any], in webView: WKWebView?) {
            evaluateResponse(id: id, envelope: ["ok": true, "value": value], in: webView)
        }

        private func respond(id: Int, error: String, in webView: WKWebView?) {
            evaluateResponse(id: id, envelope: ["ok": false, "error": error], in: webView)
        }

        private func evaluateResponse(id: Int, envelope: [String: Any],
                                      in webView: WKWebView?) {
            guard let webView,
                  JSONSerialization.isValidJSONObject(envelope),
                  let data = try? JSONSerialization.data(withJSONObject: envelope),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                webView.evaluateJavaScript("window.__cantripResolve(\(id), \(json));") {
                    _, error in
                    if let error {
                        Log.write("plugin: response delivery failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
