import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import WebKit

/// Chat-session hooks an inline MCP App view may use.
struct MCPAppActions {
    var serverRequest: (MCPAppPayload, String, [String: Any],
                        @escaping (Result<[String: Any], Error>) -> Void) -> Void
    var sendMessage: (MCPAppPayload, String, @escaping (Bool) -> Void) -> Void
    var updateContext: (MCPAppPayload, String?) -> Void
}

struct CantripMCPAppStack: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String?
    let apps: [CantripRemoteMCPAppSummary]

    var body: some View {
        if let sessionID, !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(apps) { app in
                    CantripMCPAppRemoteInlineView(remote: remote, sessionID: sessionID, summary: app)
                        .id(app.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private final class CantripMCPAppPayloadCache {
    static let shared = CantripMCPAppPayloadCache()

    private enum Entry {
        case loading(Task<MCPAppPayload, Error>)
        case loaded(MCPAppPayload)
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func payload(sessionID: String, appID: String,
                 load: @escaping () async throws -> MCPAppPayload) async throws -> MCPAppPayload {
        let key = Self.key(sessionID: sessionID, appID: appID)
        switch entries[key] {
        case .loaded(let payload):
            return payload
        case .loading(let task):
            return try await task.value
        case .none:
            let task = Task { try await load() }
            entries[key] = .loading(task)
            order.append(key)
            do {
                let payload = try await task.value
                entries[key] = .loaded(payload)
                pruneIfNeeded()
                return payload
            } catch {
                entries.removeValue(forKey: key)
                order.removeAll { $0 == key }
                throw error
            }
        }
    }

    func invalidate(sessionID: String, appID: String) {
        let key = Self.key(sessionID: sessionID, appID: appID)
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private static func key(sessionID: String, appID: String) -> String { "\(sessionID)\u{1f}\(appID)" }

    private func pruneIfNeeded() {
        while order.count > 80, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

private struct CantripMCPAppRemoteInlineView: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String
    let summary: CantripRemoteMCPAppSummary

    @State private var phase: Phase = .idle

    private enum Phase {
        case idle
        case loading
        case loaded(MCPAppPayload)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                MCPAppPlaceholder(summary: summary, isLoading: true, error: nil, retry: nil)
            case .loaded(let payload):
                MCPAppInlineView(app: payload, actions: actions(for: payload))
            case .failed(let message):
                MCPAppPlaceholder(summary: summary, isLoading: false, error: message) {
                    retry()
                }
            }
        }
        .task { await loadIfNeeded() }
    }

    private func retry() {
        CantripMCPAppPayloadCache.shared.invalidate(sessionID: sessionID, appID: summary.id)
        phase = .idle
        Task { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        if case .loaded = phase { return }
        if case .loading = phase { return }
        phase = .loading
        do {
            let payload = try await CantripMCPAppPayloadCache.shared.payload(
                sessionID: sessionID,
                appID: summary.id
            ) {
                try await remote.mcpAppPayload(sessionID: sessionID, appID: summary.id)
            }
            phase = .loaded(payload)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func actions(for payload: MCPAppPayload) -> MCPAppActions {
        MCPAppActions(
            serverRequest: { app, method, params, completion in
                Task {
                    do {
                        let result = try await remote.mcpAppServerRequest(
                            sessionID: sessionID,
                            appID: app.id,
                            method: method,
                            params: params
                        )
                        completion(.success(result))
                    } catch {
                        completion(.failure(error))
                    }
                }
            },
            sendMessage: { app, text, completion in
                Task {
                    do {
                        let accepted = try await remote.sendMCPAppMessage(
                            sessionID: sessionID,
                            appID: app.id,
                            text: text
                        )
                        completion(accepted)
                    } catch {
                        completion(false)
                    }
                }
            },
            updateContext: { app, text in
                Task {
                    try? await remote.updateMCPAppContext(sessionID: sessionID, appID: app.id, text: text)
                }
            }
        )
    }
}

private struct MCPAppPlaceholder: View {
    let summary: CantripRemoteMCPAppSummary
    let isLoading: Bool
    let error: String?
    let retry: (() -> Void)?

    private var height: CGFloat { MCPAppHeights.value(for: summary.id) ?? 150 }
    private var label: String {
        let server = summary.serverName.isEmpty ? "MCP app" : summary.serverName
        return [server, summary.displayTitle].joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MCPAppCaption(label: label)
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading interactive view")
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let retry {
                        Button("Retry", action: retry)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Retry interactive view")
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: min(height, 170))
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if summary.prefersBorder == true {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MCPAppCaption: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "rectangle.stack")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(label))
    }
}

/// An MCP App view (e.g. a Mobbin gallery) inline in the transcript, labelled
/// with its server so the sandboxed content's origin stays clear.
struct MCPAppInlineView: View {
    let app: MCPAppPayload
    let actions: MCPAppActions?
    @State private var height: CGFloat
    @State private var pendingMessage: PendingMessage?

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
        VStack(alignment: .leading, spacing: 6) {
            MCPAppCaption(label: label)
            MCPAppWebView(
                app: app,
                actions: actions,
                height: $height,
                confirmMessage: { text, completion in
                    if let pendingMessage { pendingMessage.completion(false) }
                    pendingMessage = PendingMessage(text: text, completion: completion)
                }
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if app.prefersBorder == true {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary)
                }
            }
            .accessibilityLabel("Interactive view: \(label)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Send a message from \(app.serverName.isEmpty ? "this view" : app.serverName)?",
               isPresented: Binding(get: { pendingMessage != nil }, set: { showing in
                   if !showing { cancelPendingMessage() }
               })) {
            Button("Send") { approvePendingMessage() }
            Button("Cancel", role: .cancel) { cancelPendingMessage() }
        } message: {
            Text(pendingMessage?.text ?? "")
        }
    }

    private func approvePendingMessage() {
        guard let pending = pendingMessage else { return }
        pendingMessage = nil
        guard let actions else {
            pending.completion(false)
            return
        }
        actions.sendMessage(app, pending.text, pending.completion)
    }

    private func cancelPendingMessage() {
        guard let pending = pendingMessage else { return }
        pendingMessage = nil
        pending.completion(false)
    }

    private final class PendingMessage: Identifiable {
        let id = UUID()
        let text: String
        let completion: (Bool) -> Void

        init(text: String, completion: @escaping (Bool) -> Void) {
            self.text = text
            self.completion = completion
        }
    }
}

/// Last reported heights, so recreated views (tab switches/scrolling) keep size.
@MainActor
enum MCPAppHeights {
    private static var heights: [String: CGFloat] = [:]

    static func value(for id: String) -> CGFloat? { heights[id] }

    static func set(_ height: CGFloat, for id: String) {
        if heights.count > 200 { heights.removeAll() }
        heights[id] = height
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
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let allow = app.permissions.contains("clipboardWrite") ? " allow=\"clipboard-write\"" : ""
        wrapper = Data("""
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>
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

final class MCPAppRenderingWebView: WKWebView {
    var onLayout: (() -> Void)?
    var onTraitChange: (() -> Void)?
    #if os(iOS)
    private var traitRegistration: UITraitChangeRegistration?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    func observeThemeChanges() {
        traitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (webView: MCPAppRenderingWebView, _) in
            webView.onTraitChange?()
        }
    }
    #else
    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onTraitChange?()
    }

    func observeThemeChanges() {}
    #endif
}

struct MCPAppWebView: UIViewRepresentable {
    let app: MCPAppPayload
    let actions: MCPAppActions?
    @Binding var height: CGFloat
    var confirmMessage: (String, @escaping (Bool) -> Void) -> Void

    static let maxHeight: CGFloat = 640
    /// One ephemeral store: views share an HTTP cache but never persist data.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator(app: app, confirmMessage: confirmMessage) }

    func makeUIView(context: Context) -> MCPAppRenderingWebView {
        context.coordinator.actions = actions
        context.coordinator.height = $height
        context.coordinator.confirmMessage = confirmMessage
        return context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: MCPAppRenderingWebView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.height = $height
        context.coordinator.confirmMessage = confirmMessage
        context.coordinator.themeChangedIfNeeded()
        context.coordinator.widthChanged()
    }

    static func dismantleUIView(_ webView: MCPAppRenderingWebView, coordinator: Coordinator) {
        coordinator.tearDown(webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let app: MCPAppPayload
        var actions: MCPAppActions?
        var height: Binding<CGFloat>?
        var confirmMessage: (String, @escaping (Bool) -> Void) -> Void
        private let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        private weak var webView: MCPAppRenderingWebView?
        private var host: MCPAppHost!
        private var reportedWidth: Double?
        private var reportedTheme: String?
        private static let handlerName = "cantripMcpApp"

        private var wrapperHost: String { "host-\(token)" }
        private var viewHost: String { "view-\(token)" }

        init(app: MCPAppPayload, confirmMessage: @escaping (String, @escaping (Bool) -> Void) -> Void) {
            self.app = app
            self.confirmMessage = confirmMessage
            super.init()
            host = makeHost()
        }

        private func makeHost() -> MCPAppHost {
            let host = MCPAppHost(app: app, environment: { [weak self] in self?.environment() ?? .init() },
                                  deliver: { [weak self] in self?.deliver($0) },
                                  openLink: { url in
                                      DispatchQueue.main.async { UIApplication.shared.open(url) }
                                      return true
                                  })
            host.serverRequest = { [weak self] method, params, completion in
                guard let self, let actions = self.actions else {
                    completion(.failure(MCPAppRequestError.sessionUnavailable))
                    return
                }
                actions.serverRequest(self.app, method, params, completion)
            }
            host.sendMessage = { [weak self] text, completion in
                self?.confirmMessage(text, completion) ?? completion(false)
            }
            host.updateModelContext = { [weak self] text in
                guard let self else { return }
                self.actions?.updateContext(self.app, text)
            }
            host.sizeChanged = { [weak self] _, height in
                if let height { self?.contentHeightChanged(CGFloat(height)) }
            }
            host.log = { print("[MCPApp] \($0)") }
            return host
        }

        func makeWebView() -> MCPAppRenderingWebView {
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

            let webView = MCPAppRenderingWebView(frame: .zero, configuration: config)
            #if os(iOS)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.scrollView.showsVerticalScrollIndicator = false
            #else
            webView.setValue(false, forKey: "drawsBackground")
            #endif
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = false
            webView.onLayout = { [weak self] in self?.widthChanged() }
            webView.onTraitChange = { [weak self] in self?.themeChangedIfNeeded() }
            webView.observeThemeChanges()
            self.webView = webView
            if let url = URL(string: "\(MCPAppSchemeHandler.scheme)://\(wrapperHost)/") {
                webView.load(URLRequest(url: url))
            }
            return webView
        }

        func tearDown(_ webView: WKWebView) {
            host.teardown(reason: "Cantrip Agent removed the view")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        }

        /// Relays JSON-RPC between the view iframe and Cantrip Agent. Runs only
        /// in the wrapper page; only the view's own origin is heard/addressed.
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
            env.theme = currentTheme
            if let width = webView?.bounds.width, width > 0 {
                env.width = Double(width)
                reportedWidth = Double(width)
            }
            env.maxHeight = Double(MCPAppWebView.maxHeight)
            env.hostVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            return env
        }

        private var currentTheme: String {
            webView?.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
        }

        private func deliver(_ json: String) {
            webView?.callAsyncJavaScript("window.__cantripMcpAppDeliver(json)", arguments: ["json": json],
                                         in: nil, in: .page) { result in
                if case .failure(let error) = result {
                    print("[MCPApp] delivery failed: \(error.localizedDescription)")
                }
            }
        }

        func widthChanged() {
            guard let width = webView?.bounds.width, width > 0, host.isInitialized else { return }
            if let reportedWidth, abs(reportedWidth - Double(width)) < 1 { return }
            reportedWidth = Double(width)
            host.hostContextChanged(["containerDimensions": [
                "width": Double(width), "maxHeight": Double(MCPAppWebView.maxHeight)]])
        }

        func themeChangedIfNeeded() {
            let theme = currentTheme
            guard theme != reportedTheme else { return }
            reportedTheme = theme
            host.hostContextChanged(["theme": theme])
        }

        private func contentHeightChanged(_ reported: CGFloat) {
            guard reported.isFinite, reported > 0 else { return }
            let clamped = min(max(reported.rounded(.up), 48), MCPAppWebView.maxHeight)
            #if os(iOS)
            webView?.scrollView.isScrollEnabled = reported > MCPAppWebView.maxHeight + 1
            webView?.scrollView.bounces = false
            #endif
            MCPAppHeights.set(clamped, for: app.id)
            DispatchQueue.main.async { [weak self] in
                guard let binding = self?.height, abs(binding.wrappedValue - clamped) >= 1 else { return }
                binding.wrappedValue = clamped
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
                UIApplication.shared.open(external)
            }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            host = makeHost().copyingHandlers(from: host)
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
