import Foundation

/// Live view of an agent-controlled Chrome for remote clients.
///
/// A browser MCP server (named `browser`) records the tab it last worked in to
/// `~/.local/share/agent-browser/active.json` (`targetId`, `url`, `title`, `tool`,
/// `updatedAt`). Clients show a live card under replies whose tool calls used that
/// server (`activity.browser` in history) and poll `/api/v1/browser/frame`, which
/// captures the tab through Chrome DevTools on 127.0.0.1 (`browserPreviewCDPPort`,
/// default 9333). View only: nothing here clicks, types or navigates. Frames are
/// held in memory, never written to transcripts, journals or model context.
/// Browser-internal pages (extension popups such as a password manager, chrome://,
/// devtools) are never captured. `browserPreviewEnabled` (default on) turns it off.
enum BrowserPreview {
    static let serverName = "browser"
    static let enabledKey = "browserPreviewEnabled"
    static let portKey = "browserPreviewCDPPort"
    /// A tab counts as in use for this long after the agent's last browser tool call.
    static let activeSeconds: TimeInterval = 120

    static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/agent-browser/active.json")
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var port: Int {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(value) ? value : 9333
    }

    /// Copilot names MCP tools `<server>-<tool>`; Claude Code and Cantrip's own
    /// MCP client use `mcp__<server>__<tool>`.
    static func isBrowserTool(_ name: String) -> Bool {
        name.hasPrefix(serverName + "-") || name.hasPrefix("mcp__\(serverName)__")
    }

    /// Pages that must never be shown: password-manager popups and other extension
    /// pages, Chrome's own pages, devtools and local files.
    static func isPrivate(url: String) -> Bool {
        let lower = url.lowercased()
        return ["chrome-extension:", "chrome:", "chrome-untrusted:", "devtools:", "file:", "view-source:"]
            .contains { lower.hasPrefix($0) }
    }

    static func clampedWidth(_ requested: Int?) -> Int {
        min(max(requested ?? 720, 240), 1920)
    }

    struct State: Codable, Equatable {
        var targetId: String?
        var url: String
        var title: String
        var tool: String?
        var updatedAt: String?
        var policy: String?
    }

    static func readState(from file: URL = stateFile) -> State? {
        guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func isActive(_ state: State?, now: Date = Date()) -> Bool {
        guard let stamp = state?.updatedAt, let date = ISO8601DateFormatter().date(from: stamp) else { return false }
        return now.timeIntervalSince(date) <= activeSeconds && now.timeIntervalSince(date) >= -60
    }

    /// `GET /api/v1/browser`
    struct Status: Encodable {
        let enabled: Bool
        let active: Bool
        let url: String?
        let title: String?
        let tool: String?
        let updatedAt: String?
        let hidden: Bool
    }

    static func status(now: Date = Date()) -> Status {
        let state = readState()
        let hidden = state.map { isPrivate(url: $0.url) || $0.policy == "block" } ?? false
        return Status(
            enabled: isEnabled, active: isEnabled && isActive(state, now: now),
            url: hidden ? nil : state?.url, title: hidden ? nil : state?.title,
            tool: state?.tool, updatedAt: state?.updatedAt, hidden: hidden
        )
    }

    /// `GET /api/v1/browser/frame?width=N`: a JPEG of the agent's tab (base64 in JSON).
    struct Frame: Encodable {
        let data: Data
        let width: Int
        let height: Int
        let url: String
        let title: String
        let active: Bool
        let capturedAt: String
    }

    struct PreviewError: Error {
        let status: Int
        let message: String
    }
}

/// Captures frames over Chrome DevTools, sharing one capture between clients that
/// ask within 250 ms of each other.
actor BrowserPreviewCapture {
    static let shared = BrowserPreviewCapture()

    private var cached: (width: Int, at: Date, frame: BrowserPreview.Frame)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    func frame(width requested: Int?) async throws -> BrowserPreview.Frame {
        guard BrowserPreview.isEnabled else {
            throw BrowserPreview.PreviewError(status: 403, message: "Browser preview is turned off on the Mac.")
        }
        let width = BrowserPreview.clampedWidth(requested)
        if let cached, cached.width == width, Date().timeIntervalSince(cached.at) < 0.25 {
            return cached.frame
        }
        let state = BrowserPreview.readState()
        let targets = try await pages()
        guard let target = targets.first(where: { $0.id == state?.targetId }) ?? targets.first else {
            throw BrowserPreview.PreviewError(status: 404, message: "The agent browser has no open tab.")
        }
        if BrowserPreview.isPrivate(url: target.url) || state?.policy == "block" && target.id == state?.targetId {
            throw BrowserPreview.PreviewError(status: 403, message: "This page is private and isn't shown in the preview.")
        }
        let shot = try await capture(target, width: width)
        let frame = BrowserPreview.Frame(
            data: shot.data, width: shot.width, height: shot.height, url: target.url, title: target.title,
            active: BrowserPreview.isActive(state), capturedAt: ISO8601DateFormatter().string(from: Date())
        )
        cached = (width, Date(), frame)
        return frame
    }

    private struct Target: Decodable {
        let id: String
        let type: String
        let url: String
        let title: String
        let webSocketDebuggerUrl: String?
    }

    private func pages() async throws -> [Target] {
        guard let url = URL(string: "http://127.0.0.1:\(BrowserPreview.port)/json/list") else {
            throw BrowserPreview.PreviewError(status: 500, message: "Bad DevTools port.")
        }
        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode([Target].self, from: data)
                .filter { $0.type == "page" && $0.webSocketDebuggerUrl != nil }
        } catch {
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't running.")
        }
    }

    private func capture(_ target: Target, width: Int) async throws -> (data: Data, width: Int, height: Int) {
        guard let ws = target.webSocketDebuggerUrl.flatMap(URL.init(string:)), ws.host == "127.0.0.1" || ws.host == "localhost" else {
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't reachable.")
        }
        let socket = session.webSocketTask(with: ws)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let metrics = try await call(socket, id: 1, method: "Page.getLayoutMetrics", params: [:])
        let viewport = (metrics["cssVisualViewport"] as? [String: Any]) ?? (metrics["cssLayoutViewport"] as? [String: Any]) ?? [:]
        let cssWidth = (viewport["clientWidth"] as? Double) ?? 1280
        let cssHeight = (viewport["clientHeight"] as? Double) ?? 800
        let scale = min(1, Double(width) / max(cssWidth, 1))
        let result = try await call(socket, id: 2, method: "Page.captureScreenshot", params: [
            "format": "jpeg", "quality": 62, "fromSurface": true,
            "clip": ["x": (viewport["pageX"] as? Double) ?? 0, "y": (viewport["pageY"] as? Double) ?? 0,
                     "width": cssWidth, "height": cssHeight, "scale": scale],
        ])
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser didn't return a frame.")
        }
        return (data, Int((cssWidth * scale).rounded()), Int((cssHeight * scale).rounded()))
    }

    private func call(_ socket: URLSessionWebSocketTask, id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw BrowserPreview.PreviewError(status: 503, message: "DevTools: \(error["message"] as? String ?? "error")")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw BrowserPreview.PreviewError(status: 504, message: "The agent browser took too long to answer.")
    }
}
