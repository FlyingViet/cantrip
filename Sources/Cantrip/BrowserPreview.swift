import Foundation
import ImageIO

/// Live view of an agent-controlled Chrome for remote clients.
///
/// The agent-Chrome MCP server (named `agent_chrome`; `browser` before OpenAI models refused that
/// namespace) records the tab it last worked in to
/// `~/.local/share/agent-browser/active.json` (`targetId`, `url`, `title`, `tool`,
/// `updatedAt`). Clients show a live card under replies whose tool calls used that
/// server (`activity.browser` in history) and ask `/api/v1/browser/frame` for pictures,
/// which `BrowserPreviewCapture` streams from the tab through Chrome DevTools on 127.0.0.1
/// (`browserPreviewCDPPort`, default 9333). View only: nothing here clicks, types or navigates. Frames are
/// held in memory, never written to transcripts, journals or model context.
/// Browser-internal pages (extension popups such as a password manager, chrome://,
/// devtools) are never captured. `browserPreviewEnabled` (default on) turns it off.
enum BrowserPreview {
    /// The server's names in tool calls: `agent_chrome` now, and `browser` in older history, or as
    /// `browser_mcp` when Cantrip renames a server called `browser` (`MCPBackendConfig.exportName`).
    static let serverNames = ["agent_chrome", "browser", "browser_mcp"]
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
        serverNames.contains { name.hasPrefix($0 + "-") || name.hasPrefix("mcp__\($0)__") }
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

    /// `GET /api/v1/browser/frame?width=N[&after=SEQ]`: a JPEG of the agent's tab (base64 in JSON).
    /// `seq` grows with each new picture; a client that passes it back as `after` gets the next
    /// one as soon as the page changes (or the same picture after `waitSeconds`).
    struct Frame: Encodable {
        let data: Data
        let width: Int
        let height: Int
        let url: String
        let title: String
        let active: Bool
        let capturedAt: String
        let seq: Int
    }

    /// How long a request with `after` waits for a newer picture.
    static let waitSeconds: TimeInterval = 8
    /// The stream from Chrome stops this long after the last request.
    static let idleSeconds: TimeInterval = 10
    /// Chrome sends at most one frame per this interval (about ten a second).
    static let frameInterval: TimeInterval = 0.1

    /// The stream's width: the widest any client asked for recently.
    static func streamWidth(for widths: [Int]) -> Int {
        clampedWidth(widths.max())
    }

    /// Whether a client that asked for `requested` pixels gets a smaller copy of the frame.
    static func shouldScale(frameWidth: Int, requested: Int) -> Bool {
        Double(requested) < Double(frameWidth) * 0.85
    }

    static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The JPEG at most `width` pixels wide, keeping its shape; the original when it's already narrower.
    static func scaledJPEG(_ data: Data, width: Int, quality: Double = 0.72) -> (data: Data, width: Int, height: Int)? {
        guard let size = jpegSize(data), width > 0 else { return nil }
        guard size.width > width else { return (data, size.width, size.height) }
        let longest = (Double(max(size.width, size.height)) * Double(width) / Double(size.width)).rounded()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(longest),
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }

    struct PreviewError: Error {
        let status: Int
        let message: String
    }
}

/// Streams the agent's tab from Chrome while a client is watching and hands every client the
/// newest picture.
///
/// Chrome's screencast (`Page.startScreencast`) sends a frame only when the page repaints and
/// scales it without touching the window. A clipped, scaled `Page.captureScreenshot` (what this
/// used before) makes Chrome re-render the real window at the screenshot's size for every
/// capture, so the agent's Chrome flashed a few times a second while anyone watched. A tab in
/// the background paints nothing, so while the tab is hidden (or the stream has gone quiet) a
/// plain full-tab screenshot fills in; with no clip it doesn't disturb the window either.
/// The stream stops `idleSeconds` after the last request.
actor BrowserPreviewCapture {
    static let shared = BrowserPreviewCapture()

    private struct Shot {
        let seq: Int
        let data: Data
        let width: Int
        let height: Int
        let at: Date
    }

    private struct Target: Decodable {
        let id: String
        let type: String
        let url: String
        let title: String
        let webSocketDebuggerUrl: String?
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// DevTools' page list, reread at most twice a second.
    private var targets: (at: Date, list: [Target])?

    // The stream: one DevTools connection to the agent's tab.
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var opening = false
    private var streamTarget: String?
    private var streamURL: String?
    private var streamWidth = 0
    private var streamStarted = Date.distantPast
    private var hidden = false
    private var nextID = 0
    private var replies: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextAck = Date.distantPast

    // Pictures.
    private var seq = 0
    private var latest: Shot?
    private var scaled: [Int: Shot] = [:]
    private var lastScreencast: Data?
    private var lastStill: Data?
    private var lastStillAt = Date.distantPast
    private var stillRunning = false

    // Who's watching.
    private var widths: [(at: Date, width: Int)] = []
    private var lastRequest = Date.distantPast
    private var waiting = 0
    private var idleWatch: Task<Void, Never>?

    /// Whether a stream from Chrome is open, and its width (for tests).
    var isStreaming: Bool { socket != nil }
    var streamingWidth: Int { streamWidth }

    /// The newest picture of the agent's tab. With `after` (the `seq` a client already has), waits
    /// up to `waitSeconds` for a newer one, then returns the newest it has.
    func frame(width requested: Int?, after: Int? = nil) async throws -> BrowserPreview.Frame {
        guard BrowserPreview.isEnabled else {
            stopStream()
            throw BrowserPreview.PreviewError(status: 403, message: "Browser preview is turned off on the Mac.")
        }
        let width = BrowserPreview.clampedWidth(requested)
        let start = Date()
        lastRequest = start
        widths.append((start, width))
        waiting += 1
        defer {
            waiting -= 1
            lastRequest = Date()
            scheduleIdleStop()
        }
        let deadline = start.addingTimeInterval(after == nil ? 2 : BrowserPreview.waitSeconds)
        while true {
            let state = BrowserPreview.readState()
            let target = try await currentTarget(state)
            let recent = Date()
            widths.removeAll { recent.timeIntervalSince($0.at) >= BrowserPreview.idleSeconds }
            try await ensureStream(target, width: BrowserPreview.streamWidth(for: widths.map(\.width) + [width]))
            let now = Date()
            if let shot = latest, shot.seq > (after ?? 0) || now >= deadline {
                return response(shot, width: width, target: target, state: state)
            }
            if now >= deadline {
                throw BrowserPreview.PreviewError(status: 503, message: "The agent browser didn't return a frame.")
            }
            if needsStill(now) {
                await captureStill()
            } else {
                try await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func response(_ shot: Shot, width: Int, target: Target, state: BrowserPreview.State?) -> BrowserPreview.Frame {
        var picture = shot
        if BrowserPreview.shouldScale(frameWidth: shot.width, requested: width) {
            if let cached = scaled[width], cached.seq == shot.seq {
                picture = cached
            } else if let small = BrowserPreview.scaledJPEG(shot.data, width: width) {
                picture = Shot(seq: shot.seq, data: small.data, width: small.width, height: small.height, at: shot.at)
                scaled[width] = picture
            }
        }
        return BrowserPreview.Frame(
            data: picture.data, width: picture.width, height: picture.height, url: target.url, title: target.title,
            active: BrowserPreview.isActive(state), capturedAt: ISO8601DateFormatter().string(from: shot.at), seq: shot.seq
        )
    }

    // MARK: - Target

    private func currentTarget(_ state: BrowserPreview.State?) async throws -> Target {
        let list = try await pages()
        guard let target = list.first(where: { $0.id == state?.targetId }) ?? list.first else {
            throw BrowserPreview.PreviewError(status: 404, message: "The agent browser has no open tab.")
        }
        let navigatedPrivate = target.id == streamTarget && BrowserPreview.isPrivate(url: streamURL ?? "")
        if BrowserPreview.isPrivate(url: target.url) || navigatedPrivate
            || state?.policy == "block" && target.id == state?.targetId {
            throw BrowserPreview.PreviewError(status: 403, message: "This page is private and isn't shown in the preview.")
        }
        return target
    }

    private func pages() async throws -> [Target] {
        if let targets, Date().timeIntervalSince(targets.at) < 0.5 { return targets.list }
        guard let url = URL(string: "http://127.0.0.1:\(BrowserPreview.port)/json/list") else {
            throw BrowserPreview.PreviewError(status: 500, message: "Bad DevTools port.")
        }
        do {
            let (data, _) = try await session.data(from: url)
            let list = try JSONDecoder().decode([Target].self, from: data)
                .filter { $0.type == "page" && $0.webSocketDebuggerUrl != nil }
            targets = (Date(), list)
            return list
        } catch {
            targets = nil
            stopStream()
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't running.")
        }
    }

    // MARK: - Stream

    private func ensureStream(_ target: Target, width: Int) async throws {
        while opening { try await Task.sleep(for: .milliseconds(20)) }
        if socket != nil, streamTarget == target.id {
            // A wider view opened, or the last one closed a while ago: ask Chrome for that size.
            guard width > streamWidth || BrowserPreview.shouldScale(frameWidth: streamWidth, requested: width) else { return }
            opening = true
            defer { opening = false }
            do { try await startScreencast(width: width) } catch {
                stopStream()
                throw error
            }
            return
        }
        opening = true
        defer { opening = false }
        stopStream()
        guard let address = target.webSocketDebuggerUrl.flatMap(URL.init(string:)),
              address.host == "127.0.0.1" || address.host == "localhost" else {
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't reachable.")
        }
        let socket = session.webSocketTask(with: address)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        self.socket = socket
        streamTarget = target.id
        streamURL = target.url
        streamStarted = Date()
        let generation = self.generation
        Task { await self.read(socket, generation: generation) }
        do {
            _ = try await call("Page.enable")
            try await startScreencast(width: width)
        } catch {
            stopStream()
            throw error as? BrowserPreview.PreviewError
                ?? BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't reachable.")
        }
    }

    private func startScreencast(width: Int) async throws {
        if streamWidth > 0 {
            _ = try? await call("Page.stopScreencast")
            // The next picture is the new size.
            latest = nil
            scaled = [:]
            lastStill = nil
        }
        streamWidth = width
        lastScreencast = nil
        _ = try await call("Page.startScreencast", [
            "format": "jpeg", "quality": 70, "maxWidth": width, "maxHeight": 4096, "everyNthFrame": 1,
        ])
    }

    private func stopStream() {
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        streamTarget = nil
        streamURL = nil
        streamWidth = 0
        hidden = false
        latest = nil
        scaled = [:]
        lastScreencast = nil
        lastStill = nil
        lastStillAt = .distantPast
        nextAck = .distantPast
        let pending = replies
        replies = [:]
        for reply in pending.values {
            reply.resume(throwing: BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't reachable."))
        }
    }

    /// One watcher while the stream runs: stops it `idleSeconds` after the last request.
    private func scheduleIdleStop() {
        guard idleWatch == nil else { return }
        idleWatch = Task {
            while socket != nil {
                try? await Task.sleep(for: .seconds(1))
                if waiting == 0, Date().timeIntervalSince(lastRequest) >= BrowserPreview.idleSeconds {
                    stopStream()
                }
            }
            idleWatch = nil
        }
    }

    private func read(_ socket: URLSessionWebSocketTask, generation: Int) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch { break }
            guard generation == self.generation else { return }
            switch message {
            case .string(let text): handle(Data(text.utf8))
            case .data(let data): handle(data)
            @unknown default: continue
            }
        }
        if generation == self.generation { stopStream() }
    }

    private func handle(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            replies.removeValue(forKey: id)?.resume(returning: message)
            return
        }
        let params = object["params"] as? [String: Any] ?? [:]
        switch object["method"] as? String {
        case "Page.screencastFrame":
            if let sessionID = params["sessionId"] as? Int { acknowledge(sessionID) }
            guard let base64 = params["data"] as? String, let data = Data(base64Encoded: base64),
                  data != lastScreencast else { return }
            lastScreencast = data
            publish(data)
        case "Page.screencastVisibilityChanged":
            hidden = !(params["visible"] as? Bool ?? true)
        case "Page.frameNavigated":
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil, let url = frame["url"] as? String {
                streamURL = url
            }
        case "Inspector.detached", "Inspector.targetCrashed":
            stopStream()
        default:
            break
        }
    }

    /// Acknowledges a frame (Chrome sends the next one only after that), at most one per `frameInterval`.
    private func acknowledge(_ sessionID: Int) {
        let at = max(Date(), nextAck)
        nextAck = at.addingTimeInterval(BrowserPreview.frameInterval)
        let generation = self.generation
        Task {
            let delay = at.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard generation == self.generation, let socket else { return }
            nextID += 1
            let body = #"{"id":\#(nextID),"method":"Page.screencastFrameAck","params":{"sessionId":\#(sessionID)}}"#
            socket.send(.string(body)) { _ in }
        }
    }

    private func publish(_ data: Data) {
        guard let url = streamURL, !BrowserPreview.isPrivate(url: url), let size = BrowserPreview.jpegSize(data) else { return }
        seq += 1
        latest = Shot(seq: seq, data: data, width: size.width, height: size.height, at: Date())
        scaled = [:]
    }

    /// A tab in the background paints no screencast frames (Chrome says so with
    /// `Page.screencastVisibilityChanged`): take plain screenshots instead.
    private func needsStill(_ now: Date) -> Bool {
        guard socket != nil, !stillRunning, now.timeIntervalSince(lastStillAt) >= 0.4 else { return false }
        if hidden { return true }
        // No picture yet and none coming from the stream: don't keep the client waiting.
        return latest == nil && now.timeIntervalSince(streamStarted) >= 0.4
    }

    private func captureStill() async {
        stillRunning = true
        defer { stillRunning = false }
        lastStillAt = Date()
        let generation = self.generation
        guard let result = try? await call("Page.captureScreenshot", ["format": "jpeg", "quality": 70]),
              generation == self.generation,
              let base64 = result["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty,
              data != lastStill else { return }
        lastStill = data
        publish(BrowserPreview.scaledJPEG(data, width: streamWidth)?.data ?? data)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let socket else {
            throw BrowserPreview.PreviewError(status: 503, message: "The agent browser isn't reachable.")
        }
        nextID += 1
        let id = nextID
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let text = String(decoding: body, as: UTF8.self)
        let message: Data = try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            socket.send(.string(text)) { error in
                guard let error else { return }
                Task { await self.fail(id, error) }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                fail(id, BrowserPreview.PreviewError(status: 504, message: "The agent browser took too long to answer."))
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { return [:] }
        if let error = object["error"] as? [String: Any] {
            throw BrowserPreview.PreviewError(status: 503, message: "DevTools: \(error["message"] as? String ?? "error")")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func fail(_ id: Int, _ error: Error) {
        replies.removeValue(forKey: id)?.resume(throwing: error)
    }
}
