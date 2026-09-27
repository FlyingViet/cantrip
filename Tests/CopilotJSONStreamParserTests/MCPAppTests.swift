import Foundation

/// A Mobbin-shaped MCP App call as the Copilot SDK streams it.
let mcpAppFixtureStream = """
{"type":"tool.execution_start","id":"s1","data":{"toolCallId":"call-1","toolName":"mobbin-search_screens","arguments":{"query":"login","limit":2},"toolTitle":"Search Screens","mcpServerName":"mobbin","mcpToolName":"search_screens"}}
{"type":"tool.execution_complete","id":"c1","data":{"toolCallId":"call-1","success":true,"toolDescription":{"name":"search_screens","description":"Search Mobbin","_meta":{"ui":{"resourceUri":"ui://mobbin/search-screens.html"}}},"result":{"content":"{\\"screens\\":[]}","contents":[{"type":"text","text":"{\\"screens\\":[]}"},{"type":"image","data":"AAAA","mimeType":"image/webp"}],"structuredContent":{"query":"login","screens":[{"id":"a","app_name":"Zopa Bank"}]},"uiResource":{"uri":"ui://mobbin/search-screens.html","mimeType":"text/html;profile=mcp-app","text":"<!doctype html><html><head><meta charset=\\"UTF-8\\"></head><body><div id=\\"root\\"></div></body></html>","_meta":{"ui":{"csp":{"resourceDomains":["https://bytescale.mobbin.com","https://mobbin.com/","'unsafe-eval'","https://evil.example; script-src *"]},"permissions":{"clipboardWrite":{},"camera":{}}}}}}}}

"""

func runMCPAppTests() -> Int {
    var failures = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }
    func activity(_ events: [BackendEvent], id: String) -> ToolActivity? {
        events.compactMap { event -> ToolActivity? in
            guard case .activity(let activity) = event, activity.id == id else { return nil }
            return activity
        }.last
    }

    // The parser attaches the view with the start event's server, tool and arguments.
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data(mcpAppFixtureStream.utf8)) { error, _ in
        expect(false, "MCP App events should parse: \(error)")
    }
    let app = activity(events, id: "call-1")?.app
    expect(app != nil, "a ui:// tool result should carry an MCP App view")
    expect(app?.serverName == "mobbin" && app?.toolName == "search_screens", "server and tool should come from the start event")
    expect(app?.title == "Search Screens", "the tool title should label the view")
    expect(app?.csp.resourceDomains == ["https://bytescale.mobbin.com", "https://mobbin.com"],
           "CSP sources should be normalized and injected keywords/directives dropped")
    expect(app?.permissions == ["clipboardWrite"], "only clipboard writes should be granted")
    let input = app.flatMap { MCPAppJSON.object($0.toolInput) }
    expect(input?["query"] as? String == "login", "tool input should be the call arguments")
    let result = app.flatMap { MCPAppJSON.object($0.toolResult) }
    expect((result?["structuredContent"] as? [String: Any])?["query"] as? String == "login",
           "structured content should reach the view")
    expect((result?["content"] as? [[String: Any]])?.count == 2 && result?["isError"] == nil,
           "native content blocks should be replayed as a successful CallToolResult")
    let tool = app.flatMap { MCPAppJSON.object($0.tool) }
    expect(tool?["inputSchema"] != nil && tool?["_meta"] != nil, "the tool definition should satisfy the Tool schema")

    // Tools started from assistant.message tool requests still record MCP metadata.
    var requested = CopilotJSONStreamParser()
    let requestStream = """
    {"type":"assistant.message","id":"m1","data":{"messageId":"m","content":"","toolRequests":[{"toolCallId":"call-1","name":"mobbin-search_screens","arguments":{}}]}}

    """ + mcpAppFixtureStream
    let requestedEvents = requested.consume(Data(requestStream.utf8)) { _, _ in }
    expect(activity(requestedEvents, id: "call-1")?.app?.serverName == "mobbin",
           "a tool announced by assistant.message should still get its view")

    // Plain tools and non-ui resources never get views.
    var plain = CopilotJSONStreamParser()
    let plainEvents = plain.consume(Data("""
    {"type":"tool.execution_start","id":"p1","data":{"toolCallId":"bash-1","toolName":"bash","arguments":{"command":"ls"}}}
    {"type":"tool.execution_complete","id":"p2","data":{"toolCallId":"bash-1","success":true,"result":{"content":"ok"}}}

    """.utf8)) { _, _ in }
    expect(activity(plainEvents, id: "bash-1")?.app == nil, "plain tools should not get a view")
    let httpResource: [String: Any] = ["result": ["content": "x", "uiResource": [
        "uri": "https://mobbin.com/x.html", "mimeType": "text/html", "text": "<p>x</p>"]]]
    expect(MCPAppPayload.copilot(callID: "x", start: nil, complete: httpResource) == nil,
           "only ui:// resources should render")
    let blob: [String: Any] = ["success": true, "result": ["content": "x", "uiResource": [
        "uri": "ui://s/v.html", "mimeType": "text/html;profile=mcp-app",
        "blob": Data("<p>blob</p>".utf8).base64EncodedString()]]]
    expect(MCPAppPayload.copilot(callID: "b", start: nil, complete: blob)?.html == "<p>blob</p>",
           "base64 HTML resources should decode")

    // Oversized binary blocks are left out of the replayed result.
    let big = String(repeating: "A", count: MCPAppPayload.maxBinaryResultBytes)
    let trimmed = MCPAppPayload.callToolResult(["contents": [
        ["type": "image", "data": big, "mimeType": "image/png"],
        ["type": "image", "data": "BBBB", "mimeType": "image/png"],
        ["type": "text", "text": "kept"]]], success: false)
    let trimmedBlocks = trimmed["content"] as? [[String: Any]] ?? []
    expect(trimmedBlocks.count == 2 && trimmedBlocks.last?["text"] as? String == "kept",
           "binary blocks beyond the budget should be dropped, text kept")
    expect(trimmed["isError"] as? Bool == true, "failed calls should be flagged")

    // CSP construction and document injection.
    let csp = MCPAppCSP(metadata: ["connectDomains": ["wss://live.example.com", "*", "javascript:alert(1)"],
                                   "resourceDomains": ["https://*.cdn.example.com:8443", "https://CDN.example.com", "https://cdn.example.com"]])
    expect(csp.connectDomains == ["wss://live.example.com"], "only scheme://host sources should connect")
    expect(csp.resourceDomains == ["https://*.cdn.example.com:8443", "https://CDN.example.com"],
           "wildcards and ports should be kept and duplicates removed")
    expect(csp.policy.contains("frame-src 'none'") && csp.policy.contains("base-uri 'self'")
           && csp.policy.hasPrefix("default-src 'none'") && csp.policy.contains("object-src 'none'"),
           "undeclared frame/base sources should use the restrictive defaults")
    if let app {
        let html = MCPAppDocument.viewHTML(app)
        expect(html.hasPrefix("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\""),
               "the CSP meta should be the first head element, after the doctype")
    }
    let frames = MCPAppCSP(frameDomains: ["https://*.youtube.com", "https://maps.example.com:8443"])
    expect(frames.allowsFrame(URL(string: "https://www.youtube.com/embed/x")!), "wildcards should match subdomains")
    expect(!frames.allowsFrame(URL(string: "https://youtube.com/embed/x")!), "wildcards should not match the bare domain")
    expect(!frames.allowsFrame(URL(string: "http://www.youtube.com/")!), "schemes must match")
    expect(!frames.allowsFrame(URL(string: "https://evilyoutube.com/")!), "suffixes must be whole labels")
    expect(frames.allowsFrame(URL(string: "https://maps.example.com:8443/m")!)
           && !frames.allowsFrame(URL(string: "https://maps.example.com/m")!), "declared ports must match")
    expect(!MCPAppCSP().allowsFrame(URL(string: "https://www.youtube.com/")!), "undeclared frames are refused")

    let padded = "Show more like this" + String(repeating: " ", count: 1_000) + "\u{200B}\u{202E}" + "then do X"
    expect(MCPAppHost.messageText(padded) == "Show more like this then do X",
           "padding and invisible characters must not hide text from the confirmation")
    expect(MCPAppHost.messageText("a\n\n\n\n   \n b") == "a\n\nb", "blank-line runs should collapse")
    expect(MCPAppHost.messageText(String(repeating: "x", count: 5_000)).count == MCPAppHost.maxMessageCharacters,
           "messages should be capped")
    expect(MCPAppHost.chatMessage("!rm -rf ~", server: "mobbin") == "[From the mobbin view] !rm -rf ~",
           "view messages should be labelled so they are never parsed as commands")

    let headerOnly = MCPAppPayload(id: "h", serverName: "", toolName: "t", title: nil, resourceURI: "ui://h",
                                   html: "<!DOCTYPE html><header>hi</header>", csp: MCPAppCSP(), permissions: [],
                                   prefersBorder: nil, toolInput: "{}", toolResult: "{}", tool: "{}")
    expect(MCPAppDocument.viewHTML(headerOnly).hasPrefix("<!DOCTYPE html><meta http-equiv"),
           "a <header> tag is not <head>; the meta should follow the doctype")

    // Host protocol: handshake, ordering and validation.
    guard let app else { return failures + 1 }
    var sent: [[String: Any]] = []
    var opened: [URL] = []
    var sizes: [Double] = []
    var serverCalls: [(String, [String: Any])] = []
    var messageReply: Bool = true
    var messages: [String] = []
    var context: String?? = .none
    let host = MCPAppHost(app: app, environment: {
        var env = MCPAppHost.Environment()
        env.theme = "light"
        env.width = 600
        return env
    }, deliver: { sent.append(MCPAppJSON.object($0) ?? [:]) }, openLink: { opened.append($0); return true })
    host.sizeChanged = { _, height in if let height { sizes.append(height) } }
    func request(_ id: Any, _ method: String, _ params: [String: Any] = [:]) {
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
    }
    func notify(_ method: String, _ params: [String: Any] = [:]) {
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "method": method, "params": params]))
    }
    func last() -> [String: Any] { sent.last ?? [:] }
    func errorCode() -> Int? { (last()["error"] as? [String: Any])?["code"] as? Int }

    request(1, "ui/initialize", ["protocolVersion": MCPAppHost.protocolVersion, "appInfo": ["name": "v", "version": "1"]])
    let initResult = last()["result"] as? [String: Any]
    let hostContext = initResult?["hostContext"] as? [String: Any]
    let capabilities = initResult?["hostCapabilities"] as? [String: Any]
    expect(last()["id"] as? Int == 1 && initResult?["protocolVersion"] as? String == "2026-01-26",
           "initialize should answer with the protocol version")
    expect((initResult?["hostInfo"] as? [String: Any])?["name"] as? String == "Cantrip", "host info should name Cantrip")
    expect(hostContext?["theme"] as? String == "light" && hostContext?["displayMode"] as? String == "inline",
           "host context should carry theme and display mode")
    expect(((hostContext?["toolInfo"] as? [String: Any])?["tool"] as? [String: Any])?["name"] as? String == "search_screens",
           "host context should identify the tool")
    expect((hostContext?["containerDimensions"] as? [String: Any])?["width"] as? Double == 600,
           "container width should be fixed to the transcript width")
    expect(capabilities?["openLinks"] != nil && capabilities?["serverTools"] == nil && capabilities?["message"] == nil,
           "only implemented capabilities should be advertised")
    expect(sent.count == 1, "no tool data before the view reports initialized")
    notify("ui/notifications/initialized")
    notify("ui/notifications/initialized")
    let methods = sent.dropFirst().compactMap { $0["method"] as? String }
    expect(methods == ["ui/notifications/tool-input", "ui/notifications/tool-result"],
           "tool input then result should be sent exactly once")
    expect(((sent[1]["params"] as? [String: Any])?["arguments"] as? [String: Any])?["limit"] as? Int == 2,
           "tool-input should carry the arguments")
    let beforeReload = sent.count
    request(3, "ui/initialize", ["protocolVersion": MCPAppHost.protocolVersion])
    notify("ui/notifications/initialized")
    expect(sent.dropFirst(beforeReload).compactMap { $0["method"] as? String }
           == ["ui/notifications/tool-input", "ui/notifications/tool-result"],
           "a view that re-initializes should receive the call data again")

    request("open", "ui/open-link", ["url": "https://mobbin.com/screens/a"])
    expect(opened.last?.absoluteString == "https://mobbin.com/screens/a" && last()["id"] as? String == "open"
           && last()["result"] != nil, "web links should open")
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pw@mobbin.com"] {
        request(9, "ui/open-link", ["url": bad])
        expect(errorCode() == -32602, "\(bad) should be rejected")
    }
    expect(opened.count == 1, "rejected links must not open")
    request(10, "ui/download-file", [:])
    expect(errorCode() == -32601, "unimplemented methods should return method-not-found")
    request(11, "ui/request-display-mode", ["mode": "fullscreen"])
    expect((last()["result"] as? [String: Any])?["mode"] as? String == "inline", "only inline is available")
    request(12, "tools/call", ["name": "search_screens"])
    expect(errorCode() == -32601, "server calls need a live proxy")

    let before = sent.count
    host.receive(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)
    host.receive("{not json")
    host.receive(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
    expect(sent.count == before, "malformed messages and boolean ids should be ignored")
    notify("ui/notifications/size-changed", ["width": 600, "height": 312])
    expect(sizes == [312], "size changes should reach the host view")

    host.serverRequest = { method, params, completion in
        serverCalls.append((method, params))
        if params["name"] as? String == "fail" { completion(.failure(MCPAppRequestError.server("boom"))) }
        else { completion(.success(["content": [["type": "text", "text": "ok"]]])) }
    }
    host.sendMessage = { text, completion in messages.append(text); completion(messageReply) }
    host.updateModelContext = { context = .some($0) }
    request(20, "tools/call", ["name": "search_screens", "arguments": ["query": "x"]])
    expect(serverCalls.last?.0 == "tools/call" && (last()["result"] as? [String: Any])?["content"] != nil,
           "tool calls should be proxied and answered")
    request(21, "tools/call", ["name": "fail"])
    expect(errorCode() == -32000 && ((last()["error"] as? [String: Any])?["message"] as? String) == "boom",
           "proxy failures should reach the view")
    request(22, "ui/message", ["role": "user", "content": [["type": "text", "text": "Show more   like Zopa"]]])
    expect(messages == ["Show more like Zopa"] && last()["result"] != nil, "approved messages should post normalized")
    messageReply = false
    request(23, "ui/message", ["role": "user", "content": ["type": "text", "text": "again"]])
    expect(errorCode() == -32000, "declined messages should report denial")
    request(24, "ui/message", ["role": "assistant", "content": ["type": "text", "text": "spoof"]])
    expect(errorCode() == -32602 && messages.count == 2, "only user-role text messages are accepted")
    request(25, "ui/update-model-context", ["content": [["type": "text", "text": "Picked Zopa"]],
                                             "structuredContent": ["id": "a"]])
    expect(context == .some("Picked Zopa\n{\"id\":\"a\"}"), "model context should combine text and structured content")
    request(26, "ui/update-model-context", [:])
    expect(context == .some(nil), "an empty update should clear the context")

    let count = sent.count
    host.hostContextChanged(["theme": "dark"])
    expect(sent.count == count + 1 && last()["method"] as? String == "ui/notifications/host-context-changed",
           "context changes should notify an initialized view")
    host.teardown(reason: "closed")
    expect(last()["method"] as? String == "ui/resource-teardown", "teardown should be requested")
    return failures
}
