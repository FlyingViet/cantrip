import Foundation

private final class MCPAppBackendFixture: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    @MainActor
    static func testMCPAppTranscripts() async throws {
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"hi"}]"#
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: Data(legacy.utf8))
        precondition(decoded.first?.apps.isEmpty == true, "transcripts from before MCP Apps must load")
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        precondition(!encoded.contains("\"apps\""), "messages without views should not grow an apps key")

        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let backend = MCPAppBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Find login screens")
        try await waitForJournalTest { backend.requests.count == 1 }
        let app = MCPAppPayload(
            id: "call-1", serverName: "mobbin", toolName: "search_screens", title: "Search Screens",
            resourceURI: "ui://mobbin/search-screens.html", html: "<p>gallery</p>",
            csp: MCPAppCSP(resourceDomains: ["https://mobbin.com"]), permissions: [], prefersBorder: nil,
            toolInput: #"{"query":"login"}"#, toolResult: #"{"content":[]}"#, tool: #"{"name":"search_screens"}"#)
        var step = ToolActivityFactory.start(id: "call-1", toolName: "mobbin-search_screens", arguments: [:])
        backend.sink?(.activity(step))
        step.state = .succeeded
        step.app = app
        backend.sink?(.activity(step))
        backend.sink?(.activity(step))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.messages.last?.apps == [app], "a completed view should attach once to its reply")

        // A gallery-only reply is not an empty husk: it survives a relaunch.
        let restored = ChatSession(id: chat.id, copilotBackend: MCPAppBackendFixture())
        precondition(restored.messages.contains { $0.role == .assistant && $0.apps == [app] },
                     "views should persist with the transcript")

        // The view's model context rides along with the next prompt only.
        chat.setMCPAppContext(app, text: "User picked Zopa Bank")
        chat.submit("Use that one")
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("Context from the mobbin app view")
                     && backend.requests[1].prompt.contains("User picked Zopa Bank"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        chat.submit("Anything else?")
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(!backend.requests[2].prompt.contains("Zopa Bank"), "view context is consumed once")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Approved view messages are literal prompts, never local commands.
        chat.submitMCPAppMessage("!touch /tmp/cantrip-mcp-app-should-not-exist", from: app)
        try await waitForJournalTest { backend.requests.count == 4 }
        precondition(backend.requests[3].prompt.contains("[From the mobbin view] !touch"),
                     "view messages must reach the model, not the shell")
        precondition(!FileManager.default.fileExists(atPath: "/tmp/cantrip-mcp-app-should-not-exist"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Context from a view never leaks into a new conversation.
        chat.setMCPAppContext(app, text: "STALE_VIEW_CONTEXT")
        chat.newConversation()
        chat.submit("Fresh start")
        try await waitForJournalTest { backend.requests.count == 5 }
        precondition(!backend.requests[4].prompt.contains("STALE_VIEW_CONTEXT"))

        // With views turned off, new ones are not attached.
        settings.copilotMCPApps = false
        defer { settings.copilotMCPApps = true }
        var offStep = ToolActivityFactory.start(id: "call-2", toolName: "mobbin-search_screens", arguments: [:])
        offStep.state = .succeeded
        offStep.app = MCPAppPayload(
            id: "call-2", serverName: "mobbin", toolName: "search_screens", title: nil,
            resourceURI: "ui://mobbin/search-screens.html", html: "<p>off</p>", csp: MCPAppCSP(),
            permissions: [], prefersBorder: nil, toolInput: "{}", toolResult: "{}", tool: "{}")
        backend.sink?(.activity(offStep))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        precondition(!chat.messages.contains { $0.apps.contains { $0.id == "call-2" } },
                     "views must not attach while the setting is off")

        var unavailable: Error?
        chat.mcpAppRequest(app, method: "tools/call", params: [:]) { result in
            if case .failure(let error) = result { unavailable = error }
        }
        precondition(unavailable is MCPAppRequestError, "non-SDK backends cannot proxy view requests")
    }
}

import AppKit
import WebKit

@MainActor
private final class MCPAppPageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
}

/// Handshakes like an MCP App, checks isolation, then reports success by height.
private let mcpAppProbeHTML = #"""
<!doctype html><html><head><meta charset="utf-8"></head><body><script>
let stage=0;const post=m=>parent.postMessage({jsonrpc:"2.0",...m},"*");
let leaked=false;try{leaked=!!(localStorage.getItem("cantripToken")||parent.localStorage.getItem("cantripToken"))}catch(e){}
let parentDOM=false;try{parentDOM=!!parent.document.body}catch(e){}
addEventListener("message",e=>{const m=e.data||{};
  if(m.id===1&&m.result){stage=m.result.hostInfo?.name==="Cantrip Remote"&&m.result.hostContext?.toolInfo?.tool?.name==="search_screens"?1:-1;post({method:"ui/notifications/initialized",params:{}})}
  else if(m.method==="ui/notifications/tool-input"){if(m.params?.arguments?.query!=="login")stage=-1}
  else if(m.method==="ui/notifications/tool-result"){if(m.params?.structuredContent?.screens?.length!==2)stage=-1;post({id:2,method:"tools/call",params:{name:"search_screens",arguments:{}}})}
  else if(m.id===2){const ok=stage===1&&m.error?.code===-32000&&!leaked&&!parentDOM;post({method:"ui/notifications/size-changed",params:{width:300,height:ok?222:99}})}
});
post({id:1,method:"ui/initialize",params:{protocolVersion:"2026-01-26",appInfo:{name:"probe",version:"1"},appCapabilities:{}}});
</script></body></html>
"""#

extension SessionTabTests {
    @MainActor
    static func testMCPAppRemote() async throws {
        let settings = AppSettings.shared
        settings.copilotMCPApps = true
        let backend = MCPAppBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        chat.submit("Find login screens")
        try await waitForJournalTest { backend.requests.count == 1 }
        let app = MCPAppPayload(
            id: "call_remote", serverName: "mobbin", toolName: "search_screens", title: "Search Screens",
            resourceURI: "ui://mobbin/search-screens.html", html: mcpAppProbeHTML,
            csp: MCPAppCSP(resourceDomains: ["https://mobbin.com"]), permissions: ["clipboardWrite"], prefersBorder: nil,
            toolInput: #"{"query":"login"}"#, toolResult: #"{"content":[],"structuredContent":{"screens":[1,2]}}"#,
            tool: #"{"inputSchema":{"type":"object"},"name":"search_screens"}"#)
        var step = ToolActivityFactory.start(id: app.id, toolName: "mobbin-search_screens", arguments: [:])
        step.state = .succeeded
        step.app = app
        backend.sink?(.activity(step))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET", body: String? = nil,
                  auth: Bool = true) async throws -> (Int, [String: Any], HTTPURLResponse) {
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], http)
        }
        let appPath = "api/v1/sessions/\(chat.id)/apps/\(app.id)"

        let session = try await call("api/v1/sessions/\(chat.id)")
        let messages = (session.1["session"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let summary = messages.compactMap { $0["apps"] as? [[String: Any]] }.first?.first
        precondition(summary?["id"] as? String == app.id && summary?["title"] as? String == "Search Screens"
                     && summary?["html"] == nil, "snapshots carry summaries, not payloads")
        let payload = try await call(appPath)
        precondition(payload.0 == 200 && payload.1["html"] as? String == mcpAppProbeHTML)
        let unpaired = try await call(appPath, auth: false), missing = try await call("api/v1/sessions/\(chat.id)/apps/missing")
        precondition(unpaired.0 == 401 && missing.0 == 404, "payloads require pairing and a current view")

        let view = try await call(appPath + "/view", method: "POST")
        let viewURL = view.1["url"] as? String ?? ""
        precondition(viewURL.hasPrefix("/mcp-app/"), "\(view)")
        var document = URLRequest(url: URL(string: viewURL, relativeTo: base)!)
        let (html, documentResponse) = try await client.data(for: document)
        let csp = (documentResponse as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        precondition(String(decoding: html, as: UTF8.self).contains("Content-Security-Policy"))
        precondition(csp.contains("sandbox allow-scripts allow-forms") && csp.contains("frame-ancestors 'self'")
                     && csp.contains("https://mobbin.com") && !csp.contains("allow-same-origin"), csp)
        document.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, reused) = try await client.data(for: document)
        precondition((reused as! HTTPURLResponse).statusCode == 404, "view addresses are single-use")

        let badRequest = try await call(appPath + "/request", method: "POST", body: #"{"method":"sampling/createMessage"}"#)
        precondition(badRequest.0 == 400)
        let proxied = try await call(appPath + "/request", method: "POST",
                                     body: #"{"method":"tools/call","params":{"name":"search_screens"}}"#)
        precondition(proxied.0 == 502 && (proxied.1["error"] as? String)?.contains("session") == true,
                     "proxy failures are reported, not hidden: \(proxied)")

        let message = try await call(appPath + "/message", method: "POST", body: #"{"text":"!echo    hi"}"#)
        precondition(message.1["text"] as? String == "!echo hi")
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("[From the mobbin view] !echo hi"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        _ = try await call(appPath + "/context", method: "POST", body: #"{"text":"Remote picked Zopa"}"#)
        chat.submit("Use it")
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(backend.requests[2].prompt.contains("Remote picked Zopa"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // The browser Remote renders the view sandboxed and keeps it across re-renders.
        let (page, _) = try await client.data(from: base)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = MCPAppPageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: base)
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        _ = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`);window.mcpSession=data.session;render(data.session);
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page)
        var height = ""
        for _ in 0..<120 {
            height = try await webView.evaluateJavaScript(
                "document.querySelector('#messages .mcp-app iframe')?.style.height || ''") as? String ?? ""
            if height == "222px" || height == "99px" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(height == "222px", "the probe view should handshake, proxy, and stay isolated (height \(height))")
        let stable = try await webView.callAsyncJavaScript("""
        const frame=document.querySelector('#messages .mcp-app iframe');
        const next=structuredClone(window.mcpSession);next.status="Re-render fixture";next.messages=[...next.messages,{id:"extra",role:"assistant",text:"More text",thinking:"",activities:[]}];
        render(next);
        const state=[...mcpApps.values()][0];
        return frame.isConnected&&document.querySelector('#messages .mcp-app iframe')===frame&&state.loads===1
          &&document.querySelectorAll('#messages .mcp-app').length===1&&frame.getAttribute("sandbox")==="allow-scripts allow-forms";
        """, contentWorld: .page) as? Bool
        precondition(stable == true, "gallery frames must survive transcript re-renders without reloading")

        settings.copilotMCPApps = false
        defer { settings.copilotMCPApps = true }
        let turnedOff = try await call(appPath)
        precondition(turnedOff.0 == 404, "views are unavailable while turned off")
        let hidden = try await call("api/v1/sessions/\(chat.id)")
        let hiddenMessages = (hidden.1["session"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        precondition(!hiddenMessages.contains { $0["apps"] != nil }, "snapshots omit views while turned off")
        print("MCP App views: transcripts, context, remote payloads, one-time sandboxed views, proxy and browser rendering passed")
    }
}
