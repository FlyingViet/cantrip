import SwiftUI
import WebKit
import AppKit

/// Chat-session hooks an inline MCP App view may use.
struct MCPAppActions {
    var serverRequest: (MCPAppPayload, String, [String: Any],
                        @escaping (Result<[String: Any], Error>) -> Void) -> Void
    var sendMessage: (MCPAppPayload, String) -> Void
    var updateContext: (MCPAppPayload, String?) -> Void
}

/// An MCP App view (e.g. a Mobbin gallery) inline in the transcript, labelled
/// with its server so the sandboxed content's origin stays clear.
struct MCPAppInlineView: View {
    let app: MCPAppPayload
    let actions: MCPAppActions?
    @State private var height: CGFloat

    init(app: MCPAppPayload, actions: MCPAppActions?) {
        self.app = app
        self.actions = actions
        _height = State(initialValue: MCPAppHeights.value(for: app.id) ?? 150)
    }

    private var label: String {
        let server = app.serverName.isEmpty ? "MCP app" : app.serverName
        return [server, app.title ?? app.toolName].joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: "rectangle.stack")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Interactive view from the \(app.serverName) MCP server, shown in a sandbox")
            MCPAppWebView(app: app, actions: actions, height: $height)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if app.prefersBorder == true {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)
                    }
                }
                .accessibilityLabel("Interactive view: \(label)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Last reported heights, so recreated views (tab switches) keep their size.
enum MCPAppHeights {
    private static var heights: [String: CGFloat] = [:]
    static func value(for id: String) -> CGFloat? { heights[id] }
    static func set(_ height: CGFloat, for id: String) {
        if heights.count > 200 { heights.removeAll() }
        heights[id] = height
    }
}

/// Vertical wheel/trackpad gestures go to the transcript unless the view has
/// to scroll itself, so a gallery never traps transcript scrolling; horizontal
/// gestures stay with the view.
final class MCPAppScrollForwardingWebView: WKWebView {
    var scrollsVertically = false
    var onAppearanceChange: (() -> Void)?
    private var routesToParent = false

    override func scrollWheel(with event: NSEvent) {
        let startsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if startsGesture {
            routesToParent = !scrollsVertically
                && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        }
        if routesToParent, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Serves the trusted wrapper page and the view document, each on its own
/// origin, with the view's CSP as a response header.
final class MCPAppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cantrip-mcp-app"
    let wrapperHost: String
    let viewHost: String
    private let wrapper: Data
    private let view: Data
    private let viewPolicy: String

    init(token: String, app: MCPAppPayload) {
        wrapperHost = "host-\(token)"
        viewHost = "view-\(token)"
        viewPolicy = app.csp.policy
        view = Data(MCPAppDocument.viewHTML(app).utf8)
        let title = "Interactive view from \(app.serverName.isEmpty ? "an MCP server" : app.serverName)"
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let allow = app.permissions.contains("clipboardWrite") ? " allow=\"clipboard-write\"" : ""
        wrapper = Data("""
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;height:100%;overflow:hidden;background:transparent}
        iframe{display:block;border:0;width:100%;height:100%;background:transparent}
        </style></head><body><iframe id="view" title="\(title)" src="\(Self.scheme)://\(viewHost)/" \
        sandbox="allow-scripts allow-same-origin allow-forms"\(allow) referrerpolicy="no-referrer"></iframe></body></html>
        """.utf8)
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme,
              url.path.isEmpty || url.path == "/" else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let body: Data, policy: String
        switch url.host {
        case wrapperHost:
            body = wrapper
            policy = "default-src 'none'; style-src 'unsafe-inline'; frame-src \(Self.scheme)://\(viewHost)"
        case viewHost:
            body = view
            policy = viewPolicy
        default:
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": policy,
            "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
        ]) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct MCPAppWebView: NSViewRepresentable {
    let app: MCPAppPayload
    let actions: MCPAppActions?
    @Binding var height: CGFloat

    static let maxHeight: CGFloat = 560
    /// One ephemeral store: views share an HTTP cache but never persist data.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> MCPAppScrollForwardingWebView {
        context.coordinator.actions = actions
        context.coordinator.height = $height
        return context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: MCPAppScrollForwardingWebView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.height = $height
    }

    static func dismantleNSView(_ webView: MCPAppScrollForwardingWebView, coordinator: Coordinator) {
        coordinator.tearDown(webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let app: MCPAppPayload
        var actions: MCPAppActions?
        var height: Binding<CGFloat>?
        private let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        private weak var webView: MCPAppScrollForwardingWebView?
        private var host: MCPAppHost!
        private var frameObserver: NSObjectProtocol?
        private var reportedWidth: Double?
        private static let handlerName = "cantripMcpApp"

        private var wrapperHost: String { "host-\(token)" }
        private var viewHost: String { "view-\(token)" }

        init(app: MCPAppPayload) {
            self.app = app
            super.init()
            host = MCPAppHost(app: app, environment: { [weak self] in self?.environment() ?? .init() },
                              deliver: { [weak self] in self?.deliver($0) },
                              openLink: { NSWorkspace.shared.open($0) })
            host.serverRequest = { [weak self] method, params, completion in
                guard let self, let actions = self.actions else {
                    completion(.failure(MCPAppRequestError.sessionUnavailable))
                    return
                }
                actions.serverRequest(self.app, method, params, completion)
            }
            host.sendMessage = { [weak self] text, completion in
                self?.confirmMessage(text, completion: completion) ?? completion(false)
            }
            host.updateModelContext = { [weak self] text in
                guard let self else { return }
                self.actions?.updateContext(self.app, text)
            }
            host.sizeChanged = { [weak self] _, height in
                if let height { self?.contentHeightChanged(CGFloat(height)) }
            }
            host.log = { Log.write("mcp-app: \($0)") }
        }

        func makeWebView() -> MCPAppScrollForwardingWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = MCPAppWebView.dataStore
            config.setURLSchemeHandler(MCPAppSchemeHandler(token: token, app: app),
                                       forURLScheme: MCPAppSchemeHandler.scheme)
            let controller = WKUserContentController()
            controller.add(MCPAppWeakMessageHandler(self), name: Self.handlerName)
            controller.addUserScript(WKUserScript(source: relayScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
            config.userContentController = controller
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.mediaTypesRequiringUserActionForPlayback = .all

            let webView = MCPAppScrollForwardingWebView(frame: .zero, configuration: config)
            webView.setValue(false, forKey: "drawsBackground")
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = false
            webView.allowsMagnification = false
            webView.onAppearanceChange = { [weak self] in
                guard let self else { return }
                self.host.hostContextChanged(["theme": self.environment().theme])
            }
            webView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: webView, queue: .main
            ) { [weak self] _ in self?.widthChanged() }
            self.webView = webView
            Log.write("mcp-app: rendering \(app.resourceURI) from \(app.serverName); csp \(app.csp.policy)")
            if let url = URL(string: "\(MCPAppSchemeHandler.scheme)://\(wrapperHost)/") {
                webView.load(URLRequest(url: url))
            }
            return webView
        }

        func tearDown(_ webView: WKWebView) {
            host.teardown(reason: "Cantrip removed the view")
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            frameObserver = nil
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        }

        /// Relays JSON-RPC between the view iframe and Cantrip. Runs only in the
        /// wrapper page; the view (another origin) cannot reach this bridge, and
        /// only the view's own origin is heard or addressed, even if it navigates.
        private var relayScript: String {
            """
            (function () {
              if (location.protocol !== "\(MCPAppSchemeHandler.scheme):" || location.host !== "\(wrapperHost)") return;
              var handler = window.webkit.messageHandlers.\(Self.handlerName);
              function frame() { return document.getElementById("view"); }
              var viewOrigin = "\(MCPAppSchemeHandler.scheme)://\(viewHost)";
              window.addEventListener("message", function (event) {
                var view = frame();
                if (!view || event.source !== view.contentWindow || event.origin !== viewOrigin) return;
                try { handler.postMessage(JSON.stringify(event.data)); } catch (error) {}
              });
              window.__cantripMcpAppDeliver = function (json) {
                var view = frame();
                if (view && view.contentWindow) view.contentWindow.postMessage(JSON.parse(json), viewOrigin);
              };
            })();
            """
        }

        private func environment() -> MCPAppHost.Environment {
            var env = MCPAppHost.Environment()
            let appearance = webView?.effectiveAppearance ?? NSApp.effectiveAppearance
            env.theme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
            if let width = webView?.bounds.width, width > 0 {
                env.width = Double(width)
                reportedWidth = Double(width)
            }
            env.maxHeight = Double(MCPAppWebView.maxHeight)
            env.hostVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            return env
        }

        private func deliver(_ json: String) {
            webView?.callAsyncJavaScript("window.__cantripMcpAppDeliver(json)", arguments: ["json": json],
                                         in: nil, in: .page) { result in
                if case .failure(let error) = result {
                    Log.write("mcp-app: delivery failed: \(error.localizedDescription)")
                }
            }
        }

        private func widthChanged() {
            guard let width = webView?.bounds.width, width > 0, host.isInitialized else { return }
            if let reportedWidth, abs(reportedWidth - Double(width)) < 1 { return }
            reportedWidth = Double(width)
            host.hostContextChanged(["containerDimensions": [
                "width": Double(width), "maxHeight": Double(MCPAppWebView.maxHeight)]])
        }

        private func contentHeightChanged(_ reported: CGFloat) {
            guard reported.isFinite, reported > 0 else { return }
            let clamped = min(max(reported.rounded(.up), 48), MCPAppWebView.maxHeight)
            webView?.scrollsVertically = reported > MCPAppWebView.maxHeight + 1
            MCPAppHeights.set(clamped, for: app.id)
            DispatchQueue.main.async { [weak self] in
                guard let binding = self?.height, abs(binding.wrappedValue - clamped) >= 1 else { return }
                binding.wrappedValue = clamped
            }
        }

        /// `ui/message` drives the agent, so the user approves each one.
        private func confirmMessage(_ text: String, completion: @escaping (Bool) -> Void) {
            let server = app.serverName.isEmpty ? "An MCP app" : app.serverName
            let alert = NSAlert()
            alert.messageText = "Send a message from \(server)?"
            alert.informativeText = "The \(server) view wants to send this to the model as your next message:"
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            if let textView = scroll.documentView as? NSTextView {
                textView.string = text
                textView.isEditable = false
                textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                textView.setAccessibilityLabel("Message from \(server)")
            }
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            let finish: (Bool) -> Void = { [weak self] accepted in
                guard let self else { completion(false); return }
                if accepted { self.actions?.sendMessage(self.app, text) }
                completion(accepted && self.actions != nil)
            }
            alert.presentKeepingPanelOpen(on: webView?.window) {
                finish($0 == .alertFirstButtonReturn)
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, origin.protocol == MCPAppSchemeHandler.scheme,
                  origin.host == wrapperHost, let text = message.body as? String else { return }
            host.receive(text)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.scheme == MCPAppSchemeHandler.scheme, url.host == wrapperHost || url.host == viewHost {
                decisionHandler(.allow)
                return
            }
            if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" {
                decisionHandler(.allow)
                return
            }
            // Frames nested in the view may load its declared frame domains; the
            // wrapper and the view frame itself never leave Cantrip's origins.
            if let target = navigationAction.targetFrame, !target.isMainFrame,
               target.request.url?.host != viewHost, app.csp.allowsFrame(url) {
                decisionHandler(.allow)
                return
            }
            // Views must not navigate away; a clicked web link opens in the browser.
            if navigationAction.navigationType == .linkActivated,
               let external = MCPAppHost.externalURL(url.absoluteString) {
                NSWorkspace.shared.open(external)
            }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Log.write("mcp-app: web content process ended; reloading \(app.resourceURI)")
            host = MCPAppHost(app: host.app, environment: host.environment,
                              deliver: host.deliver, openLink: host.openLink)
                .copyingHandlers(from: host)
            webView.reload()
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}

private extension MCPAppHost {
    /// A fresh protocol state (after a web-process crash) with the same hooks.
    func copyingHandlers(from other: MCPAppHost) -> MCPAppHost {
        sendMessage = other.sendMessage
        updateModelContext = other.updateModelContext
        serverRequest = other.serverRequest
        sizeChanged = other.sizeChanged
        log = other.log
        return self
    }
}

/// WKUserContentController retains handlers; this breaks the cycle.
private final class MCPAppWeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
