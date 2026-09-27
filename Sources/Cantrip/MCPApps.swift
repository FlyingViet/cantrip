import Foundation

/// An MCP App (SEP-1865) view returned with a tool result, such as Mobbin's
/// screen gallery. Cantrip renders the HTML inline in a sandboxed web view and
/// hands it the call's input and result after the view's handshake.
struct MCPAppPayload: Codable, Equatable, Identifiable {
    /// The tool call ID, unique per rendered view.
    let id: String
    let serverName: String
    let toolName: String
    var title: String?
    let resourceURI: String
    let html: String
    var csp: MCPAppCSP
    /// Declared sandbox permissions Cantrip grants (clipboard writes only).
    var permissions: [String]
    var prefersBorder: Bool?
    /// JSON object text of the tool call arguments.
    var toolInput: String
    /// JSON object text of the MCP `CallToolResult`.
    var toolResult: String
    /// JSON object text of the tool definition (`name`, `inputSchema`, `_meta`).
    var tool: String

    static let maxHTMLBytes = 1 << 20
    /// Base64 image/audio blocks beyond this are left out of the replayed result.
    static let maxBinaryResultBytes = 256 * 1024

    /// Builds the view from a Copilot `tool.execution_complete` event's data and
    /// the matching `tool.execution_start` data. Nil unless the result carries a
    /// `ui://` HTML resource.
    static func copilot(callID: String, start: [String: Any]?,
                        complete: [String: Any]) -> MCPAppPayload? {
        guard let result = complete["result"] as? [String: Any],
              let resource = result["uiResource"] as? [String: Any],
              let uri = resource["uri"] as? String, uri.lowercased().hasPrefix("ui://"),
              let mimeType = resource["mimeType"] as? String,
              mimeType.lowercased().hasPrefix("text/html") else { return nil }
        let html: String
        if let text = resource["text"] as? String {
            html = text
        } else if let blob = resource["blob"] as? String, let data = Data(base64Encoded: blob),
                  let text = String(data: data, encoding: .utf8) {
            html = text
        } else {
            return nil
        }
        guard !html.isEmpty, html.utf8.count <= maxHTMLBytes else { return nil }

        let meta = (resource["_meta"] as? [String: Any])?["ui"] as? [String: Any]
        let description = complete["toolDescription"] as? [String: Any]
            ?? start?["toolDescription"] as? [String: Any]
        let toolName = start?["mcpToolName"] as? String ?? description?["name"] as? String
            ?? start?["toolName"] as? String ?? "tool"
        let title = start?["toolTitle"] as? String ?? description?["title"] as? String
        var tool: [String: Any] = ["name": toolName, "inputSchema": ["type": "object"]]
        if let text = description?["description"] as? String { tool["description"] = text }
        if let title { tool["title"] = title }
        if let toolMeta = description?["_meta"] as? [String: Any],
           JSONSerialization.isValidJSONObject(toolMeta) { tool["_meta"] = toolMeta }
        let arguments = start?["arguments"] as? [String: Any] ?? [:]
        let permissions = (meta?["permissions"] as? [String: Any] ?? [:]).keys
            .filter { $0 == "clipboardWrite" }.sorted()

        return MCPAppPayload(
            id: callID, serverName: start?["mcpServerName"] as? String ?? "",
            toolName: toolName, title: title, resourceURI: uri, html: html,
            csp: MCPAppCSP(metadata: meta?["csp"]), permissions: permissions,
            prefersBorder: meta?["prefersBorder"] as? Bool,
            toolInput: MCPAppJSON.text(JSONSerialization.isValidJSONObject(arguments) ? arguments : [:]),
            toolResult: MCPAppJSON.text(callToolResult(result, success: complete["success"] as? Bool ?? true)),
            tool: MCPAppJSON.text(tool)
        )
    }

    /// Copilot's result in MCP `CallToolResult` shape: native content blocks,
    /// structured content, and the error flag.
    static func callToolResult(_ result: [String: Any], success: Bool) -> [String: Any] {
        var content: [[String: Any]] = []
        if let blocks = result["contents"] as? [[String: Any]] {
            var binaryBytes = 0
            for block in blocks where JSONSerialization.isValidJSONObject(block) {
                if let data = block["data"] as? String
                    ?? (block["resource"] as? [String: Any])?["blob"] as? String {
                    binaryBytes += data.utf8.count
                    if binaryBytes > maxBinaryResultBytes { continue }
                }
                content.append(block)
            }
        } else if let text = result["content"] as? String {
            content = [["type": "text", "text": text]]
        }
        var call: [String: Any] = ["content": content]
        if let structured = result["structuredContent"] as? [String: Any],
           JSONSerialization.isValidJSONObject(structured) {
            call["structuredContent"] = structured
        }
        if !success { call["isError"] = true }
        return call
    }
}

/// Network origins a view declared in `_meta.ui.csp`. Only plain
/// `scheme://host[:port]` sources survive, so a declaration can never add a
/// CSP keyword or directive.
struct MCPAppCSP: Codable, Equatable {
    var connectDomains: [String] = []
    var resourceDomains: [String] = []
    var frameDomains: [String] = []
    var baseUriDomains: [String] = []

    init(connectDomains: [String] = [], resourceDomains: [String] = [],
         frameDomains: [String] = [], baseUriDomains: [String] = []) {
        self.connectDomains = connectDomains
        self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains
        self.baseUriDomains = baseUriDomains
    }

    init(metadata: Any?) {
        let declared = metadata as? [String: Any]
        self.init(connectDomains: Self.sources(declared?["connectDomains"]),
                  resourceDomains: Self.sources(declared?["resourceDomains"]),
                  frameDomains: Self.sources(declared?["frameDomains"]),
                  baseUriDomains: Self.sources(declared?["baseUriDomains"]))
    }

    private static let sourcePattern =
        #"^(https|http|wss|ws)://(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]{1,5})?$"#

    static func sources(_ raw: Any?) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for case var source as String in list.prefix(32) {
            source = source.trimmingCharacters(in: .whitespaces)
            if source.hasSuffix("/") { source.removeLast() }
            guard source.range(of: sourcePattern, options: .regularExpression) != nil,
                  seen.insert(source.lowercased()).inserted else { continue }
            result.append(source)
        }
        return result
    }

    /// The spec's policy: restrictive defaults widened only by declared origins.
    var policy: String {
        func directive(_ name: String, _ base: [String], _ extra: [String]) -> String {
            ([name] + base + extra).joined(separator: " ")
        }
        return [
            "default-src 'none'",
            directive("script-src", ["'self'", "'unsafe-inline'"], resourceDomains),
            directive("style-src", ["'self'", "'unsafe-inline'"], resourceDomains),
            directive("connect-src", ["'self'"], connectDomains),
            directive("img-src", ["'self'", "data:", "blob:"], resourceDomains),
            directive("font-src", ["'self'", "data:"], resourceDomains),
            directive("media-src", ["'self'", "data:", "blob:"], resourceDomains),
            directive("frame-src", frameDomains.isEmpty ? ["'none'"] : [], frameDomains),
            "object-src 'none'",
            directive("base-uri", baseUriDomains.isEmpty ? ["'self'"] : [], baseUriDomains),
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// Whether a nested frame inside the view may load `url`, matching the
    /// declared `frameDomains` the way CSP host sources do.
    func allowsFrame(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443]
        let port = url.port ?? defaultPorts[scheme]
        return frameDomains.contains { source in
            guard let parts = source.lowercased().range(of: "://").map({
                (String(source.lowercased()[..<$0.lowerBound]), String(source.lowercased()[$0.upperBound...]))
            }), parts.0 == scheme else { return false }
            var sourceHost = parts.1
            var sourcePort = defaultPorts[scheme]
            if let colon = sourceHost.lastIndex(of: ":") {
                sourcePort = Int(sourceHost[sourceHost.index(after: colon)...])
                sourceHost = String(sourceHost[..<colon])
            }
            guard port == sourcePort else { return false }
            if sourceHost.hasPrefix("*.") { return host.hasSuffix(String(sourceHost.dropFirst(1))) }
            return host == sourceHost
        }
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [:]
        if !connectDomains.isEmpty { result["connectDomains"] = connectDomains }
        if !resourceDomains.isEmpty { result["resourceDomains"] = resourceDomains }
        if !frameDomains.isEmpty { result["frameDomains"] = frameDomains }
        if !baseUriDomains.isEmpty { result["baseUriDomains"] = baseUriDomains }
        return result
    }
}

enum MCPAppJSON {
    static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum MCPAppDocument {
    /// The view's HTML with its CSP as the first `<head>` element, so the
    /// policy applies even where response headers are not enforced.
    static func viewHTML(_ app: MCPAppPayload) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(app.csp.policy)\">"
        var html = app.html
        for pattern in [#"<head(\s[^>]*)?>"#, #"<html(\s[^>]*)?>"#, #"<!doctype[^>]*>"#] {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: meta, at: range.upperBound)
                return html
            }
        }
        return meta + html
    }
}

enum MCPAppRequestError: LocalizedError {
    case sessionUnavailable
    case timedOut
    case invalidRequest
    case server(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "This tab's Copilot session is not running. Send a message in this tab, then try again."
        case .timedOut: return "The MCP server did not respond in time."
        case .invalidRequest: return "Invalid MCP App request."
        case .server(let message): return message
        }
    }
}

/// Host side of the MCP Apps postMessage JSON-RPC protocol for one view.
/// Transport-agnostic: `deliver` sends JSON text to the view and `receive`
/// takes JSON text from it. Callers use it from one thread.
final class MCPAppHost {
    static let protocolVersion = "2026-01-26"
    static let maxMessageBytes = 4 << 20

    struct Environment {
        var theme = "dark"
        var width: Double?
        var maxHeight: Double = 560
        var locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        var timeZone = TimeZone.current.identifier
        var hostVersion = "1.0"
    }

    typealias ServerRequest = (String, [String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void

    let app: MCPAppPayload
    var environment: () -> Environment
    var deliver: (String) -> Void
    var openLink: (URL) -> Bool
    /// Asks the user before posting the view's message to the chat.
    var sendMessage: ((String, @escaping (Bool) -> Void) -> Void)?
    var updateModelContext: ((String?) -> Void)?
    var serverRequest: ServerRequest?
    var sizeChanged: (Double?, Double?) -> Void = { _, _ in }
    var log: (String) -> Void = { _ in }
    private(set) var isInitialized = false
    private var sentToolData = false
    private var nextRequestID = 1

    init(app: MCPAppPayload, environment: @escaping () -> Environment,
         deliver: @escaping (String) -> Void, openLink: @escaping (URL) -> Bool) {
        self.app = app
        self.environment = environment
        self.deliver = deliver
        self.openLink = openLink
    }

    func receive(_ text: String) {
        guard text.utf8.count <= Self.maxMessageBytes,
              let message = MCPAppJSON.object(text),
              message["jsonrpc"] as? String == "2.0" else {
            log("dropped a malformed message")
            return
        }
        guard let method = message["method"] as? String else { return } // responses to host requests
        let params = message["params"] as? [String: Any] ?? [:]
        if let id = message["id"] {
            guard id is String || (id is NSNumber && !Self.isBoolean(id)) else { return }
            handleRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method, params)
        }
    }

    /// Partial host context update (theme, width). Sent only after the handshake.
    func hostContextChanged(_ changes: [String: Any]) {
        guard isInitialized, !changes.isEmpty else { return }
        notify("ui/notifications/host-context-changed", changes)
    }

    func teardown(reason: String) {
        guard isInitialized else { return }
        let id = nextRequestID
        nextRequestID += 1
        send(["jsonrpc": "2.0", "id": id, "method": "ui/resource-teardown", "params": ["reason": reason]])
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "ui/initialize":
            // A view that reloads itself starts over and needs the call data again.
            isInitialized = false
            sentToolData = false
            respond(id, initializeResult())
        case "ping":
            respond(id, [:])
        case "ui/open-link":
            guard let raw = params["url"] as? String, let url = Self.externalURL(raw) else {
                fail(id, -32602, "Invalid URL")
                return
            }
            if openLink(url) { respond(id, [:]) } else { fail(id, -32000, "Cantrip could not open the link") }
        case "ui/request-display-mode":
            respond(id, ["mode": "inline"])
        case "ui/message":
            guard let sendMessage else { fail(id, -32601, "Method not found: \(method)"); return }
            guard (params["role"] as? String ?? "user") == "user",
                  let text = Self.text(params["content"]) else {
                fail(id, -32602, "Invalid message format")
                return
            }
            sendMessage(Self.messageText(text)) { [weak self] accepted in
                if accepted { self?.respond(id, [:]) } else { self?.fail(id, -32000, "Message sending denied") }
            }
        case "ui/update-model-context":
            guard let updateModelContext else { fail(id, -32601, "Method not found: \(method)"); return }
            updateModelContext(Self.contextText(params))
            respond(id, [:])
        case "tools/call", "tools/list", "resources/read":
            guard let serverRequest, !app.serverName.isEmpty,
                  JSONSerialization.isValidJSONObject(params) else {
                fail(id, -32601, "Cantrip cannot reach this view's MCP server")
                return
            }
            let target = method == "tools/call" ? " \(params["name"] as? String ?? "?")"
                : method == "resources/read" ? " \(params["uri"] as? String ?? "?")" : ""
            log("\(app.serverName) view requested \(method)\(target)")
            serverRequest(method, params) { [weak self] result in
                switch result {
                case .success(let value): self?.respond(id, value)
                case .failure(let error): self?.fail(id, -32000, error.localizedDescription)
                }
            }
        default:
            fail(id, -32601, "Method not found: \(method)")
        }
    }

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "ui/notifications/initialized":
            isInitialized = true
            sendToolData()
        case "ui/notifications/size-changed":
            sizeChanged((params["width"] as? NSNumber)?.doubleValue,
                        (params["height"] as? NSNumber)?.doubleValue)
        case "notifications/message":
            let level = params["level"] as? String ?? "info"
            let data = params["data"].map { $0 as? String ?? MCPAppJSON.text(["data": $0]) } ?? ""
            log("\(app.serverName) view \(level): \(data.prefix(500))")
        default:
            break
        }
    }

    private func sendToolData() {
        guard !sentToolData else { return }
        sentToolData = true
        notify("ui/notifications/tool-input", ["arguments": MCPAppJSON.object(app.toolInput) ?? [:]])
        notify("ui/notifications/tool-result", MCPAppJSON.object(app.toolResult) ?? ["content": []])
    }

    private func initializeResult() -> [String: Any] {
        let env = environment()
        var sandbox: [String: Any] = ["csp": app.csp.dictionary]
        if !app.permissions.isEmpty {
            sandbox["permissions"] = Dictionary(uniqueKeysWithValues: app.permissions.map { ($0, [String: Any]()) })
        }
        var capabilities: [String: Any] = ["openLinks": [:], "logging": [:], "sandbox": sandbox]
        if serverRequest != nil, !app.serverName.isEmpty {
            capabilities["serverTools"] = [:]
            capabilities["serverResources"] = [:]
        }
        if sendMessage != nil { capabilities["message"] = ["text": [:]] }
        if updateModelContext != nil {
            capabilities["updateModelContext"] = ["text": [:], "structuredContent": [:]]
        }
        var dimensions: [String: Any] = ["maxHeight": env.maxHeight]
        if let width = env.width { dimensions["width"] = width }
        var context: [String: Any] = [
            "theme": env.theme, "displayMode": "inline", "availableDisplayModes": ["inline"],
            "containerDimensions": dimensions, "locale": env.locale, "timeZone": env.timeZone,
            "userAgent": "Cantrip/\(env.hostVersion)", "platform": "desktop",
            "deviceCapabilities": ["touch": false, "hover": true],
            "styles": ["variables": Self.styleVariables],
        ]
        if let tool = MCPAppJSON.object(app.tool) { context["toolInfo"] = ["tool": tool] }
        return [
            "protocolVersion": Self.protocolVersion,
            "hostInfo": ["name": "Cantrip", "version": env.hostVersion],
            "hostCapabilities": capabilities,
            "hostContext": context,
        ]
    }

    private func respond(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func fail(_ id: Any, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        deliver(MCPAppJSON.text(message))
    }

    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Plain http(s) links only, without embedded credentials.
    static func externalURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Text blocks from a content block or block array.
    static func text(_ content: Any?) -> String? {
        let blocks = content as? [[String: Any]] ?? (content as? [String: Any]).map { [$0] } ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static let maxMessageCharacters = 2_000

    /// What the user approves is exactly what is sent: invisible format
    /// characters are removed, whitespace runs that could push text out of the
    /// confirmation are collapsed, and the length is capped.
    static func messageText(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\p{Cf}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\S\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n[\s]*\n\s*"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(maxMessageCharacters))
    }

    /// The chat prompt for an approved view message, labelled with its source.
    /// The label also keeps the text from being read as a `!` or `/` command.
    static func chatMessage(_ text: String, server: String) -> String {
        "[From the \(server.isEmpty ? "MCP app" : server) view] \(text)"
    }

    /// Model context as prompt text; nil clears it.
    static func contextText(_ params: [String: Any]) -> String? {
        var parts: [String] = []
        if let text = text(params["content"]) { parts.append(text) }
        if let structured = params["structuredContent"] as? [String: Any], !structured.isEmpty {
            parts.append(MCPAppJSON.text(structured))
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : String(joined.prefix(8_000))
    }

    static let styleVariables: [String: String] = [
        "--font-sans": "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif",
        "--font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
        "--color-background-primary": "light-dark(#ffffff, #1f1f21)",
        "--color-background-secondary": "light-dark(#f5f5f7, #2a2a2d)",
        "--color-text-primary": "light-dark(#1d1d1f, #f5f5f7)",
        "--color-text-secondary": "light-dark(#6e6e73, #a1a1a6)",
        "--color-border-primary": "light-dark(#d2d2d7, #3a3a3d)",
        "--color-border-secondary": "light-dark(#e5e5ea, #2f2f32)",
        "--color-ring-primary": "light-dark(#0071e3, #0a84ff)",
    ]
}
