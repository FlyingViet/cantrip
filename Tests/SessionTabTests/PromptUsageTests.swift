import AppKit
import Foundation
import SwiftUI
import WebKit

private final class PromptUsageBackendFixture: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

private final class PromptUsagePageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
}

private func requireUsage<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { preconditionFailure("missing value at line \(line)") }
    return value
}

extension SessionTabTests {
    @MainActor
    static func testPromptUsage() async throws {
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi"}]"#
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: Data(legacy.utf8))
        precondition(decoded.first?.promptUsage == nil, "transcripts from before prompt usage must load")
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        precondition(!encoded.contains("promptUsage"), "prompts without usage should not grow a key")

        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let backend = PromptUsageBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop(); chat.cancel() }

        chat.submit("How big is this prompt?")
        try await waitForJournalTest { backend.requests.count == 1 }
        backend.sink?(.context(BackendContextUsage(messageCharacters: 7_400)))
        backend.sink?(.context(BackendContextUsage(tokens: 38_210, limit: 200_000, systemTokens: 12_000,
                                                   toolTokens: 11_118, conversationTokens: 15_092)))
        backend.sink?(.usage(BackendUsage(backend: "copilot", costUSD: 0, inputTokens: 38_000, outputTokens: 900,
                                          cachedInputTokens: 30_000)))
        backend.sink?(.context(BackendContextUsage(tokens: 41_500, limit: 200_000, systemTokens: 12_000,
                                                   toolTokens: 11_118, conversationTokens: 18_382)))
        backend.sink?(.usage(BackendUsage(backend: "copilot", costUSD: 0, inputTokens: 41_400, outputTokens: 300,
                                          cachedInputTokens: 38_000)))
        // A message sent into the running turn doesn't replace the prompt's size.
        backend.sink?(.context(BackendContextUsage(messageCharacters: 40)))
        try await waitForJournalTest { chat.messages.first?.promptUsage?.modelCalls == 2 }
        let usage = try requireUsage(chat.messages.first { $0.role == .user }?.promptUsage)
        precondition(usage.contextTokens == 38_210 && usage.latestContextTokens == 41_500 && usage.contextLimit == 200_000
                     && usage.systemTokens == 12_000 && usage.toolTokens == 11_118 && usage.conversationTokens == 15_092,
                     "the prompt keeps the context it was sent with: \(usage)")
        precondition(usage.messageTokens == 1_850 && usage.addedTokens == 1_844,
                     "the message estimate separates what Cantrip added: \(usage)")
        precondition(usage.inputTokens == 79_400 && usage.cachedInputTokens == 68_000 && usage.outputTokens == 1_200,
                     "run totals add every call: \(usage)")
        precondition(usage.summary == "38.2k tokens of context · 19% of 200k", usage.summary)
        precondition(chat.messages.filter { $0.role != .user }.allSatisfy { $0.promptUsage == nil },
                     "only the prompt carries usage")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        let restored = ChatSession(id: chat.id, copilotBackend: PromptUsageBackendFixture())
        precondition(restored.messages.first { $0.role == .user }?.promptUsage == usage,
                     "prompt usage should persist with the transcript: \(restored.messages.map { ($0.role, $0.promptUsage as Any) }) vs \(usage)")

        // Remote clients get the same fields.
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "api/v1/sessions/\(chat.id)", relativeTo: base)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await client.data(for: request)
        let session = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["session"] as? [String: Any]
        let messages = session?["messages"] as? [[String: Any]] ?? []
        let remote = try requireUsage(messages.first { $0["role"] as? String == "user" }?["promptUsage"] as? [String: Any])
        precondition(remote["contextTokens"] as? Int == 38_210 && remote["contextLimit"] as? Int == 200_000
                     && remote["systemTokens"] as? Int == 12_000 && remote["toolTokens"] as? Int == 11_118
                     && remote["conversationTokens"] as? Int == 15_092 && remote["messageTokens"] as? Int == 1_850
                     && remote["addedTokens"] as? Int == 1_844 && remote["latestContextTokens"] as? Int == 41_500
                     && remote["modelCalls"] as? Int == 2 && remote["inputTokens"] as? Int == 79_400
                     && remote["cachedInputTokens"] as? Int == 68_000 && remote["outputTokens"] as? Int == 1_200,
                     "remote snapshot: \(remote)")
        precondition(messages.filter { $0["role"] as? String != "user" }.allSatisfy { $0["promptUsage"] == nil })

        // The browser shows the line under the prompt, with details on expand.
        let (page, _) = try await client.data(from: base)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = PromptUsagePageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 520), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: base)
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let rendered = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`);render(data.session);
        const usage=document.querySelector('#messages .message.user .prompt-usage');
        usage.open=true;
        return {summary:usage.querySelector('summary').textContent,
          rows:[...usage.querySelectorAll('dt')].map((term,i)=>term.textContent+'='+usage.querySelectorAll('dd')[i].textContent),
          titles:[...usage.querySelectorAll('.usage-title')].map(title=>title.textContent),
          count:document.querySelectorAll('#messages .prompt-usage').length};
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page) as? [String: Any]
        let rows = rendered?["rows"] as? [String] ?? []
        precondition(rendered?["summary"] as? String == "38.2k tokens of context · 19% of 200k"
                     && rendered?["count"] as? Int == 1
                     && rendered?["titles"] as? [String] == ["When sent", "This run"]
                     && rows.contains("Total=38,210 of 200,000") && rows.contains("Tool definitions=11,118")
                     && rows.contains("This message=≈ 1,850") && rows.contains("Added by Cantrip=≈ 1,844")
                     && rows.contains("Input tokens=79,400 (86% cached)") && rows.contains("Latest context=41,500"),
                     "the browser should render the prompt's usage: \(String(describing: rendered))")
        try await snapshotPromptUsage(webView: webView, usage: usage)
    }

    /// Writes PNGs for review when CANTRIP_SNAPSHOT_DIR is set.
    @MainActor
    private static func snapshotPromptUsage(webView: WKWebView, usage: PromptUsage) async throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        func write(_ image: NSImage?, _ name: String) throws {
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        for dark in [false, true] {
            webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(300))
            try write(try await webView.takeSnapshot(configuration: nil), "prompt-usage-web-\(dark ? "dark" : "light").png")
            let content = VStack(alignment: .leading, spacing: 12) {
                Text("How big is this prompt?").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                PromptUsageLine(usage: usage)
                Divider()
                PromptUsageDetails(usage: usage).frame(width: 300)
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            try write(renderer.nsImage, "prompt-usage-mac-\(dark ? "dark" : "light").png")
        }
    }
}
