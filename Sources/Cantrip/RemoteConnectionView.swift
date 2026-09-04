import SwiftUI
import WebKit

struct RemoteConnectionView: View {
    @ObservedObject var connection: RemoteConnection
    @ObservedObject private var metrics = PanelMetrics.shared

    var body: some View {
        VStack(spacing: 0) {
            if !connection.hasConfiguration {
                setupView
            } else {
                browserView
            }
        }
        .onAppear { connection.activate() }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect to another Cantrip", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            Text("Enter the pairing token from the other Mac. Cantrip connects directly when both Macs are on the same local network; a Tailscale Serve URL is an optional fallback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(
                connection.hasStoredPairingToken
                    ? "Pairing token saved in Keychain"
                    : "Pairing token",
                text: $connection.pairingToken
            )
            .textFieldStyle(.roundedBorder)

            TextField(
                "Optional: https://mac-mini.your-tailnet.ts.net",
                text: $connection.address
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { connection.connect() }

            HStack {
                Spacer()
                Button("Connect") { connection.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connection.canConnect)
            }

            if let error = connection.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    private var browserView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(connection.isLoading
                                     ? Color.orange
                                     : connection.isConnected
                                        ? Color.green
                                        : Color.secondary)
                    .symbolEffect(.pulse, isActive: connection.isLoading)

                Text(connection.endpointLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if let error = connection.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                Button(action: connection.reload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Reload remote Cantrip")

                Button("Change server", action: connection.changeServer)
                    .buttonStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            if connection.endpoint != nil {
                RemoteWebView(webView: connection.webView)
                    .frame(height: max(340, metrics.transcriptMaxHeight))
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching for the paired Cantrip on your local network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            }
        }
    }
}

@MainActor
final class RemoteConnection: NSObject, ObservableObject, WKNavigationDelegate,
    WKScriptMessageHandler {
    @Published var address: String
    @Published var pairingToken = ""
    @Published private(set) var endpoint: URL?
    @Published private(set) var hasStoredPairingToken: Bool
    @Published private(set) var isUsingLocalNetwork = false
    @Published private(set) var isLoading = false
    @Published private(set) var isConnected = false
    @Published private(set) var errorMessage: String?

    var hasConfiguration: Bool {
        fallbackURL != nil || hasStoredPairingToken
    }

    var canConnect: Bool {
        !pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasStoredPairingToken
            || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var endpointLabel: String {
        if isUsingLocalNetwork { return "Local network" }
        return endpoint?.host ?? fallbackURL?.host ?? "Remote Cantrip"
    }

    let webView: WKWebView

    private let defaults = UserDefaults.standard
    private let endpointKey = "remoteClientEndpoint"
    private let lanBrowser = RemoteLANBrowser()
    private var fallbackURL: URL?
    private var lanEndpoints: [NWEndpoint] = []
    private var activeLANEndpoint: NWEndpoint?
    private var lanBridge: RemoteLANBridge?
    private var bridgeGeneration = 0
    private var scriptMessageHandler: WeakScriptMessageHandler?
    private var active = false
    private var connectionStatusTimer: Timer?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let storedAddress = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        address = storedAddress
        fallbackURL = Self.validatedURL(storedAddress)
        endpoint = nil
        hasStoredPairingToken = RemoteClientCredentials.load() != nil

        super.init()
        let scriptMessageHandler = WeakScriptMessageHandler(delegate: self)
        self.scriptMessageHandler = scriptMessageHandler
        webView.configuration.userContentController.add(
            scriptMessageHandler,
            name: "cantripRemoteUnpair"
        )
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        installPairingTokenScript(RemoteClientCredentials.load())
    }

    func activate() {
        active = true
        startLANDiscovery()
        guard let endpoint else {
            if let fallbackURL {
                useFallback(fallbackURL)
            } else {
                stopConnectionStatusPolling()
                isConnected = false
            }
            return
        }
        if webView.url == nil || webView.url?.absoluteString == "about:blank" {
            load(endpoint)
        } else {
            startConnectionStatusPolling()
        }
    }

    func connect() {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = Self.validatedURL(trimmedAddress)
        guard trimmedAddress.isEmpty || url != nil else {
            errorMessage = "Use an HTTPS fallback URL, or HTTP only for localhost."
            return
        }

        let enteredToken = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedToken = RemoteClientCredentials.load()
        guard !enteredToken.isEmpty || storedToken != nil || url != nil else {
            errorMessage = "Enter the pairing token from the other Cantrip."
            return
        }
        if !enteredToken.isEmpty {
            let status = RemoteClientCredentials.store(enteredToken)
            guard status == errSecSuccess else {
                errorMessage = "Could not save the pairing token in Keychain (OSStatus \(status))."
                return
            }
        }

        pairingToken = ""
        hasStoredPairingToken = RemoteClientCredentials.load() != nil
        fallbackURL = url
        address = url?.absoluteString ?? ""
        if address.isEmpty {
            defaults.removeObject(forKey: endpointKey)
        } else {
            defaults.set(address, forKey: endpointKey)
        }
        installPairingTokenScript(RemoteClientCredentials.load())
        errorMessage = nil
        resetLANConnection()
        stopConnectionStatusPolling()
        webView.stopLoading()
        endpoint = nil
        isLoading = false
        isConnected = false
        if active {
            startLANDiscovery()
            if let url { useFallback(url) }
        }
    }

    func reload() {
        guard let endpoint else { return }
        errorMessage = nil
        load(endpoint)
    }

    func changeServer() {
        lanBrowser.stop()
        resetLANConnection()
        stopConnectionStatusPolling()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        _ = RemoteClientCredentials.remove()
        installPairingTokenScript(nil)
        hasStoredPairingToken = false
        pairingToken = ""
        address = ""
        fallbackURL = nil
        endpoint = nil
        defaults.removeObject(forKey: endpointKey)
        isLoading = false
        isConnected = false
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stopConnectionStatusPolling()
        isLoading = true
        isConnected = false
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        guard sameOrigin(webView.url, endpoint) else {
            stopConnectionStatusPolling()
            isConnected = false
            return
        }
        startConnectionStatusPolling()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cantripRemoteUnpair" else { return }
        clearNativePairing()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if target.absoluteString == "about:blank" || sameOrigin(target, endpoint) {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated,
                  ["http", "https", "mailto"].contains(target.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(target)
            decisionHandler(.cancel)
        } else {
            errorMessage = "Blocked navigation outside the paired Cantrip host."
            decisionHandler(.cancel)
        }
    }

    private func load(_ url: URL) {
        stopConnectionStatusPolling()
        isLoading = true
        isConnected = false
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        ))
    }

    private func report(_ error: Error) {
        stopConnectionStatusPolling()
        isLoading = false
        isConnected = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription
    }

    private func startConnectionStatusPolling() {
        stopConnectionStatusPolling()
        refreshConnectionStatus()
        connectionStatusTimer = Timer.scheduledTimer(
            withTimeInterval: 1.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectionStatus()
            }
        }
    }

    private func stopConnectionStatusPolling() {
        connectionStatusTimer?.invalidate()
        connectionStatusTimer = nil
    }

    private func refreshConnectionStatus() {
        webView.evaluateJavaScript(
            "document.documentElement.dataset.cantripConnected === 'true'"
        ) { [weak self] value, error in
            DispatchQueue.main.async {
                self?.isConnected = error == nil
                    && ((value as? NSNumber)?.boolValue ?? false)
            }
        }
    }

    private func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    private func startLANDiscovery() {
        guard active, let token = RemoteClientCredentials.load(), !token.isEmpty else {
            lanBrowser.stop()
            lanEndpoints = []
            return
        }
        lanBrowser.onEndpointsChanged = { [weak self] endpoints in
            self?.updateLANEndpoints(endpoints)
        }
        lanBrowser.start(token: token)
    }

    private func updateLANEndpoints(_ endpoints: [NWEndpoint]) {
        guard endpoints != lanEndpoints else { return }
        lanEndpoints = endpoints
        guard let preferred = endpoints.first,
              let token = RemoteClientCredentials.load()
        else {
            if activeLANEndpoint != nil {
                resetLANConnection()
                if let fallbackURL {
                    useFallback(fallbackURL)
                } else {
                    endpoint = nil
                    isLoading = false
                    isConnected = false
                    errorMessage = "The paired Cantrip left the local network, and no fallback URL is configured."
                }
            }
            return
        }
        guard preferred != activeLANEndpoint else { return }
        connectToLAN(preferred, token: token)
    }

    private func connectToLAN(_ lanEndpoint: NWEndpoint, token: String) {
        bridgeGeneration += 1
        let generation = bridgeGeneration
        lanBridge?.stop()
        let bridge = RemoteLANBridge(endpoint: lanEndpoint, token: token)
        bridge.onReady = { [weak self, weak bridge] url in
            guard let self, let bridge,
                  self.bridgeGeneration == generation,
                  self.lanBridge === bridge
            else { return }
            self.activeLANEndpoint = lanEndpoint
            self.isUsingLocalNetwork = true
            self.endpoint = url
            self.errorMessage = nil
            self.load(url)
        }
        bridge.onFailure = { [weak self, weak bridge] message in
            guard let self, let bridge,
                  self.bridgeGeneration == generation,
                  self.lanBridge === bridge
            else { return }
            self.resetLANConnection()
            if let fallbackURL = self.fallbackURL {
                self.useFallback(fallbackURL)
            } else {
                self.endpoint = nil
                self.isLoading = false
                self.isConnected = false
                self.errorMessage = "Could not open the local Cantrip bridge. \(message)"
            }
        }
        lanBridge = bridge
        bridge.start()
    }

    private func useFallback(_ url: URL) {
        activeLANEndpoint = nil
        isUsingLocalNetwork = false
        endpoint = url
        load(url)
    }

    private func resetLANConnection() {
        bridgeGeneration += 1
        lanBridge?.stop()
        lanBridge = nil
        lanEndpoints = []
        activeLANEndpoint = nil
        isUsingLocalNetwork = false
    }

    private func clearNativePairing() {
        let status = RemoteClientCredentials.remove()
        guard status == errSecSuccess else {
            errorMessage = "Could not remove the pairing token from Keychain (OSStatus \(status))."
            return
        }
        installPairingTokenScript(nil)
        hasStoredPairingToken = false
        lanBrowser.stop()
        resetLANConnection()
        if let fallbackURL {
            useFallback(fallbackURL)
        } else {
            stopConnectionStatusPolling()
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            endpoint = nil
            isLoading = false
            isConnected = false
        }
    }

    private func installPairingTokenScript(_ token: String?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard let token,
              let encoded = try? JSONEncoder().encode(token),
              let literal = String(data: encoded, encoding: .utf8)
        else { return }
        controller.addUserScript(WKUserScript(
            source: "localStorage.setItem('cantripToken', \(literal));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private static func validatedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }

        components.scheme = scheme
        components.host = host
        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }
}

private struct RemoteWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
