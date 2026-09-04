import SwiftUI
import WebKit

struct RemoteConnectionView: View {
    @ObservedObject var connection: RemoteConnection
    @ObservedObject private var metrics = PanelMetrics.shared

    var body: some View {
        VStack(spacing: 0) {
            if connection.endpoint == nil {
                setupView
            } else {
                browserView
            }
        }
        .onAppear { connection.activate() }
        .onDisappear { connection.deactivate() }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect to another Cantrip", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            Text("Enter the HTTPS address shown by `tailscale serve status` on the host Mac. Pairing happens inside the remote client and stays private to that host.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("https://mac-mini.your-tailnet.ts.net", text: $connection.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connection.connect() }

                Button("Connect") { connection.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.address.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)
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
                    .foregroundStyle(connection.isLoading || connection.errorMessage != nil
                                     ? Color.orange : Color.green)
                    .symbolEffect(.pulse, isActive: connection.isLoading)

                Text(connection.endpoint?.host ?? "Remote Cantrip")
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

            RemoteWebView(webView: connection.webView)
                .frame(height: max(340, metrics.transcriptMaxHeight))
        }
    }
}

@MainActor
final class RemoteConnection: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address: String
    @Published private(set) var endpoint: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let webView: WKWebView

    private let defaults = UserDefaults.standard
    private let endpointKey = "remoteClientEndpoint"
    private var active = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)

        let storedAddress = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        address = storedAddress
        endpoint = Self.validatedURL(storedAddress)

        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func activate() {
        active = true
        guard let endpoint else { return }
        load(endpoint)
    }

    func deactivate() {
        active = false
        isLoading = false
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func connect() {
        guard let url = Self.validatedURL(address) else {
            errorMessage = "Use an HTTPS URL, or HTTP only for localhost."
            return
        }
        address = url.absoluteString
        endpoint = url
        defaults.set(address, forKey: endpointKey)
        errorMessage = nil
        if active { load(url) }
    }

    func reload() {
        guard let endpoint else { return }
        errorMessage = nil
        load(endpoint)
    }

    func changeServer() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        endpoint = nil
        defaults.removeObject(forKey: endpointKey)
        isLoading = false
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
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
        } else {
            errorMessage = "Blocked navigation outside the paired Cantrip host."
            decisionHandler(.cancel)
        }
    }

    private func load(_ url: URL) {
        isLoading = true
        webView.load(URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        ))
    }

    private func report(_ error: Error) {
        isLoading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription
    }

    private func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
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

    static func dismantleNSView(_ webView: WKWebView, coordinator: Void) {
        webView.stopLoading()
    }
}
