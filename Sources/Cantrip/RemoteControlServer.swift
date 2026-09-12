import Foundation
import Network
import CryptoKit

/// Authenticated HTTP control plane for the live sessions owned by the app.
/// Loopback HTTP remains available for Tailscale Serve. A separate Bonjour
/// listener uses forward-secret TLS with the pairing token as a PSK for LAN use.
final class RemoteControlServer {
    var onError: ((String?) -> Void)?

    private weak var manager: SessionManager?
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-control")
    private let encodingQueue: DispatchQueue
    private let detailEncodingQueue = DispatchQueue(label: "cantrip.remote-details", qos: .utility)
    private let requestLog: (String) -> Void
    private let sendTimeout: TimeInterval
    private static let healthBody = Data(#"{"status":"ok"}"#.utf8)
    private var listener: NWListener?
    private var lanListener: NWListener?
    private var activePort: Int?
    private var token = ""
    private let buildMonitor: GitHubBuildMonitor
    private let usage: UsageTracker
    private let maximumRequestBytes = RemoteImageAttachments.maximumRequestBytes

    init(manager: SessionManager, buildMonitor: GitHubBuildMonitor = GitHubBuildMonitor(),
         usage: UsageTracker = .shared,
         encodingQueue: DispatchQueue = DispatchQueue(label: "cantrip.remote-encoding", qos: .userInitiated),
         sendTimeout: TimeInterval = 15,
         requestLog: @escaping (String) -> Void = Log.write) {
        self.manager = manager
        self.buildMonitor = buildMonitor
        self.usage = usage
        self.encodingQueue = encodingQueue
        self.sendTimeout = sendTimeout
        self.requestLog = requestLog
    }

    func start(port: Int, token: String) {
        guard (1...65535).contains(port) else {
            onError?("Remote control port must be between 1 and 65535.")
            stop()
            return
        }
        guard !token.isEmpty else {
            onError?("Remote control pairing token is unavailable.")
            stop()
            return
        }
        if listener != nil, lanListener != nil, activePort == port, self.token == token {
            return
        }
        stop()

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.onError?(nil)
                    Log.write("remote-control: listening at http://127.0.0.1:\(port)")
                case .failed(let error):
                    self.onError?("Remote control daemon failed: \(error.localizedDescription)")
                    Log.write("remote-control: listener failed: \(error.localizedDescription)")
                    self.stop()
                default:
                    break
                }
            }
            self.listener = listener
            activePort = port
            self.token = token
            listener.start(queue: queue)
            startLANListener(token: token)
        } catch {
            onError?("Remote control daemon failed: \(error.localizedDescription)")
            Log.write("remote-control: listener failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        lanListener?.stateUpdateHandler = nil
        lanListener?.cancel()
        lanListener = nil
        activePort = nil
        token = ""
    }

    private func startLANListener(token: String) {
        do {
            let listener = try NWListener(using: RemoteLANProtocol.parameters(token: token))
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Cantrip",
                type: RemoteLANProtocol.serviceType,
                txtRecord: NWTXTRecord([
                    "id": RemoteLANProtocol.tokenFingerprint(token),
                    "v": "1",
                ])
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.lanListener === listener else { return }
                switch state {
                case .ready:
                    self.onError?(nil)
                    if let port = listener.port {
                        Log.write("remote-control: encrypted LAN service ready on port \(port)")
                    }
                case .failed(let error):
                    self.onError?(
                        "Direct local-network control failed: \(error.localizedDescription)"
                    )
                    Log.write("remote-control: LAN listener failed: \(error.localizedDescription)")
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    self.lanListener = nil
                default:
                    break
                }
            }
            lanListener = listener
            listener.start(queue: queue)
        } catch {
            onError?("Direct local-network control failed: \(error.localizedDescription)")
            Log.write("remote-control: LAN listener failed: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let request = RemoteRequestConnection(socket: connection, queue: queue,
                                              sendTimeout: sendTimeout, log: requestLog)
        request.start()
        receiveRequest(on: request, buffer: Data())
    }

    private func receiveRequest(on connection: RemoteRequestConnection, buffer: Data) {
        connection.socket.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.socket.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.count > self.maximumRequestBytes {
                self.sendError(413, "request too large", on: connection)
                return
            }
            if let request = HTTPRequest.parse(next) {
                connection.trace.identify(request)
                connection.trace.enter(.parse)
                if request.method == "GET", request.path == "/health" {
                    self.send(status: 200, contentType: "application/json; charset=utf-8",
                              body: Self.healthBody, on: connection)
                    return
                }
                let json = authorized(request.headers["authorization"]) ? request.json : nil
                connection.trace.enter(.mainWait)
                Task { @MainActor [weak self] in
                    connection.trace.enter(.handler)
                    self?.route(request, json: json, on: connection)
                }
            } else if !HTTPRequest.needsMoreData(next) {
                self.sendError(400, "malformed request", on: connection)
            } else if isComplete || error != nil {
                self.sendError(400, "incomplete request", on: connection)
            } else {
                self.receiveRequest(on: connection, buffer: next)
            }
        }
    }

    @MainActor
    private func route(_ request: HTTPRequest, json: [String: Any]?, on connection: RemoteRequestConnection) {
        if request.method == "GET", request.path == "/" {
            send(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.webApp.utf8),
                on: connection
            )
            return
        }
        guard request.path == "/api/v1/sessions"
                || request.path == "/api/v1/ready"
                || request.path.hasPrefix("/api/v1/sessions/")
                || request.path == "/api/v1/github/builds"
                || request.path == "/api/v1/copilot/usage" else {
            sendError(404, "not found", on: connection)
            return
        }
        guard authorized(request.headers["authorization"]) else {
            sendError(401, "invalid pairing token", on: connection)
            return
        }
        if request.path == "/api/v1/copilot/usage" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            usage.refreshQuotas()
            let snapshot = usage.copilotUsage
            sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
            return
        }
        if request.path == "/api/v1/github/builds" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            Task {
                let snapshot = await buildMonitor.snapshot()
                sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
            }
            return
        }
        guard let manager else {
            sendError(503, "session manager unavailable", on: connection)
            return
        }

        if request.path == "/api/v1/ready" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let sessions = manager.sessions.filter { !$0.isPrivate }
                .map { snapshot($0, includeMessages: false, on: connection) }
            sendJSON(["status": "ready", "sessions": sessions], on: connection)
            return
        }
        if request.path == "/api/v1/sessions" {
            switch request.method {
            case "GET":
                let sessions = manager.sessions
                    .filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false, on: connection) }
                sendJSON(["sessions": sessions], on: connection)
            case "POST":
                let session = manager.newSession()
                sendSession(session, status: 201, on: connection)
            default:
                sendError(405, "method not allowed", on: connection)
            }
            return
        }

        let tail = String(request.path.dropFirst("/api/v1/sessions/".count))
        let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
        guard let rawID = parts.first,
              let id = UUID(uuidString: String(rawID)),
              let sessionIndex = manager.sessions.firstIndex(where: {
                  $0.id == id && !$0.isPrivate
              })
        else {
            sendError(404, "session not found", on: connection)
            return
        }
        let session = manager.sessions[sessionIndex]

        if parts.count == 3, parts[1] == "messages", request.method == "GET" {
            guard let messageID = UUID(uuidString: String(parts[2])),
                  let message = session.messages.first(where: { $0.id == messageID }) else {
                sendError(404, "message no longer available", on: connection)
                return
            }
            let object = messageSnapshot(message, sessionID: id, compact: false)
            sendEncoded(on: connection, queue: detailEncodingQueue) {
                try JSONSerialization.data(withJSONObject: ["message": object], options: [.sortedKeys])
            }
            return
        }
        if parts.count == 2, parts[1] == "move" {
            guard request.method == "POST" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard let json, Set(json.keys) == ["targetID", "placement"],
                  let rawTarget = json["targetID"] as? String,
                  let targetID = UUID(uuidString: rawTarget),
                  let placement = json["placement"] as? String,
                  ["before", "after"].contains(placement) else {
                sendError(400, "targetID must be a UUID and placement must be before or after", on: connection)
                return
            }
            guard manager.sessions.contains(where: { $0.id == targetID && !$0.isPrivate }) else {
                sendError(404, "session not found", on: connection)
                return
            }
            do {
                try manager.moveSession(id, relativeTo: targetID, after: placement == "after")
                let sessions = manager.sessions.filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false, on: connection) }
                sendJSON(["sessions": sessions], on: connection)
            } catch {
                sendError(409, error.localizedDescription, on: connection)
            }
            return
        }

        if parts.count >= 2, parts[1] == "attachments" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard parts.count == 4 || (parts.count == 5 && parts[4] == "thumbnail") else {
                sendError(404, "image not found", on: connection)
                return
            }
            let imageID = "\(parts[2])/\(parts[3])"
            let prompts = session.messages.filter { $0.role == .user }.map(\.text)
                + session.queued.map(\.text)
            guard RemoteImageAttachments.validID(imageID),
                  prompts.contains(where: {
                      RemoteImageAttachments.presentation($0, sessionID: id).imageIDs.contains(imageID)
                  }) else {
                sendError(404, "image not found in this session", on: connection)
                return
            }
            let thumbnail = parts.count == 5
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try RemoteImageAttachments.read(id: imageID, sessionID: id, thumbnail: thumbnail)
                    }.value
                    guard manager.sessions.contains(where: { $0.id == id && !$0.isPrivate }) else {
                        sendError(404, "session not found", on: connection)
                        return
                    }
                    sendJSON(["data": data.base64EncodedString()], on: connection)
                } catch {
                    Log.write("remote-control: attachment read failed: \(error.localizedDescription)")
                    sendError(404, "The attached image is no longer available on the Mac.", on: connection)
                }
            }
            return
        }
        if parts.count == 1, request.method == "GET" {
            if connection.trace.usesPagedHistory {
                let summary = snapshot(session, includeMessages: false, on: connection)
                if request.query("before") == nil,
                   request.query("revision") == summary["historyRevision"] as? String {
                    sendJSON(["unchanged": true], on: connection)
                    return
                }
                var end = session.messages.endIndex
                if let before = request.query("before") {
                    guard let cursor = UUID(uuidString: before),
                          let index = session.messages.firstIndex(where: { $0.id == cursor }) else {
                        sendError(409, "History changed. Refresh the conversation before loading older messages.", on: connection)
                        return
                    }
                    end = index
                }
                do {
                    sendJSON(["session": try pagedSnapshot(session, summary: summary, end: end)], on: connection)
                } catch {
                    sendError(500, "Could not encode conversation history.", on: connection)
                }
                return
            }
            sendJSON(["session": snapshot(session, on: connection)], on: connection)
            return
        }
        if parts.count == 3, parts[1] == "queue", request.method == "DELETE" {
            guard let promptID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "queued message ID must be a UUID", on: connection)
                return
            }
            guard let index = session.queued.firstIndex(where: { $0.id == promptID }) else {
                sendError(409, "This message is no longer queued. It may have started or been removed on another device.", on: connection)
                return
            }
            // Resolve and remove on the main actor without yielding to queue draining.
            session.removeQueued(at: index)
            sendSession(session, on: connection)
            return
        }
        guard request.method == "POST", parts.count == 2 else {
            sendError(405, "method not allowed", on: connection)
            return
        }

        switch parts[1] {
        case "metadata":
            guard let body = json,
                  !body.isEmpty,
                  Set(body.keys).isSubset(of: ["customTitle", "isLocked"]),
                  body["customTitle"] == nil || body["customTitle"] is String,
                  body["isLocked"] == nil || (body["isLocked"] as? NSNumber).map({
                      CFGetTypeID($0) == CFBooleanGetTypeID()
                  }) == true else {
                sendError(400, "Provide customTitle (string) and/or isLocked (boolean).", on: connection)
                return
            }
            do {
                try session.updateTab(name: body["customTitle"] as? String,
                                      isLocked: body["isLocked"] as? Bool)
                sendSession(session, on: connection)
            } catch let error as SessionTabError {
                sendError(400, error.localizedDescription, on: connection)
            } catch {
                Log.write("remote-control: tab metadata storage failed: \(error.localizedDescription)")
                sendError(500, "Could not save the tab on the Mac.", on: connection)
            }
        case "messages":
            guard let body = json,
                  let text = body["text"] as? String
            else {
                sendError(400, "message text is required", on: connection)
                return
            }
            guard let rawMode = (body["mode"] ?? "auto") as? String,
                  let mode = MessageDeliveryMode(rawValue: rawMode) else {
                sendError(400, "mode must be auto, queue, interrupt, or inject", on: connection)
                return
            }
            do {
                let images = try RemoteImageAttachments.decode(body["images"])
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !images.isEmpty else {
                    sendError(400, "message text or images are required", on: connection)
                    return
                }
                guard images.isEmpty || session.supportsRemoteImages else {
                    sendError(409, "The selected Cantrip backend does not support image attachments.", on: connection)
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard images.isEmpty || (!trimmed.hasPrefix("!") && !trimmed.hasPrefix("/")) else {
                    sendError(400, "Attach images to an agent prompt, not a shell or slash command.", on: connection)
                    return
                }
                let prompt = try RemoteImageAttachments.preparePrompt(
                    text, images: images, sessionID: session.id
                )
                session.submitRemote(prompt, mode: mode)
            } catch let error as RemoteImageAttachmentError {
                sendError(400, error.localizedDescription, on: connection)
                return
            } catch {
                Log.write("remote-control: image storage failed: \(error.localizedDescription)")
                sendError(500, "Could not save the attached images on the Mac.", on: connection)
                return
            }
            sendSession(session, status: 202, on: connection)
        case "cancel":
            session.cancel()
            sendSession(session, on: connection)
        case "resume":
            guard session.canResume, !session.isStreaming else {
                sendError(409, "session is not resumable", on: connection)
                return
            }
            session.resumeInterrupted()
            sendSession(session, status: 202, on: connection)
        case "new-conversation":
            guard !session.isLocked else {
                sendError(409, SessionTabError.locked.localizedDescription, on: connection)
                return
            }
            guard !session.isStreaming else {
                sendError(409, "stop the running session before resetting it", on: connection)
                return
            }
            session.newConversation()
            sendSession(session, on: connection)
        case "close":
            guard !session.isLocked else {
                sendError(409, SessionTabError.locked.localizedDescription, on: connection)
                return
            }
            manager.close(sessionIndex)
            let candidate = manager.sessions[min(sessionIndex, manager.sessions.count - 1)]
            let replacement = candidate.isPrivate
                ? manager.sessions.first(where: { !$0.isPrivate }) ?? manager.newSession()
                : candidate
            sendSession(replacement, afterJournal: session, on: connection)
        default:
            sendError(404, "action not found", on: connection)
        }
    }

    @MainActor
    private func sendSession(_ session: ChatSession, status: Int = 200,
                             afterJournal journalSession: ChatSession? = nil,
                             on connection: RemoteRequestConnection) {
        connection.trace.enter(.journalWait)
        Task {
            do {
                try await (journalSession ?? session).flushJournal()
                guard !session.isPrivate else {
                    sendError(404, "session not found", on: connection)
                    return
                }
                if connection.trace.usesPagedHistory {
                    let summary = snapshot(session, includeMessages: false, on: connection)
                    sendJSON(["session": try pagedSnapshot(session, summary: summary,
                                                          end: session.messages.endIndex)],
                             status: status, on: connection)
                } else {
                    sendJSON(["session": snapshot(session, on: connection)], status: status, on: connection)
                }
            } catch {
                requestLog("remote-request: id=\(connection.trace.id) outcome=journal_error")
                sendError(500, "The action may have applied, but run history could not be saved. Check the session before retrying.", on: connection)
            }
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let candidate = String(header.dropFirst("Bearer ".count))
        let lhs = Array(candidate.utf8)
        let rhs = Array(token.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    @MainActor
    private func snapshot(
        _ session: ChatSession,
        includeMessages: Bool = true,
        on connection: RemoteRequestConnection
    ) -> [String: Any] {
        connection.trace.enter(.snapshot)
        defer { connection.trace.enter(.handler) }
        var result: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.title,
            "customTitle": session.tabMetadata.customTitle ?? "",
            "isLocked": session.isLocked,
            "supportsTabMetadata": true,
            "supportsTabReordering": true,
            "workdir": session.workdir,
            "isStreaming": session.isStreaming,
            "canResume": session.canResume,
            "councilMode": session.councilMode,
            "queuedCount": session.queued.count,
            "supportsImageAttachments": session.supportsRemoteImages,
            "supportsAutoDelivery": true,
            "supportsQueueRemoval": true,
            "supportsPagedHistory": true,
        ]
        if let status = session.statusText { result["status"] = status }
        if let status = session.deliveryStatus { result["deliveryStatus"] = status }
        // Hash only small metadata and mutation tokens, never the full transcript.
        var hasher = SHA256()
        for key in result.keys.sorted() {
            let value = String(describing: result[key]!)
            hasher.update(data: Data("\(key.utf8.count):\(key)\(value.utf8.count):\(value)".utf8))
        }
        hasher.update(data: Data(session.remoteMessageRevision.uuidString.utf8))
        hasher.update(data: Data(session.remoteQueueRevision.uuidString.utf8))
        result["historyRevision"] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if includeMessages {
            result["queued"] = session.queued.map { prompt in
                let presentation = RemoteImageAttachments.presentation(prompt.text, sessionID: session.id)
                var object: [String: Any] = [
                    "id": prompt.id.uuidString,
                    "text": prompt.text,
                ]
                if !presentation.imageIDs.isEmpty {
                    object["displayText"] = presentation.text
                    object["images"] = presentation.imageIDs.map { ["id": $0] }
                }
                return object
            }
            result["messages"] = session.messages.map {
                messageSnapshot($0, sessionID: session.id, compact: false)
            }
        }
        return result
    }

    private func messageSnapshot(_ message: ChatMessage, sessionID: UUID, compact: Bool) -> [String: Any] {
        var object = RemoteHistory.message(message, compact: compact)
        if message.role == .user {
            let presentation = RemoteImageAttachments.presentation(message.text, sessionID: sessionID)
            if !presentation.imageIDs.isEmpty {
                object["displayText"] = compact
                    ? RemoteHistory.preview(presentation.text, bytes: 16 * 1024) : presentation.text
                object["images"] = presentation.imageIDs.map { ["id": $0] }
            }
        }
        return object
    }

    @MainActor
    private func pagedSnapshot(_ session: ChatSession, summary: [String: Any], end: Int) throws -> [String: Any] {
        var result = summary
        var messages: [[String: Any]] = []
        var bytes = 0
        var start = end
        for index in (max(0, end - RemoteHistory.pageSize)..<end).reversed() {
            let message = messageSnapshot(session.messages[index], sessionID: session.id, compact: true)
            let size = try JSONSerialization.data(withJSONObject: message).count
            if !messages.isEmpty, bytes + size > RemoteHistory.pageBytes { break }
            messages.insert(message, at: 0)
            bytes += size
            start = index
        }
        result["messages"] = messages
        result["historyStartID"] = session.messages.first?.id.uuidString ?? "empty"
        result["hasOlderMessages"] = start > 0
        result["queued"] = session.queued.map { prompt -> [String: Any] in
            let presentation = RemoteImageAttachments.presentation(prompt.text, sessionID: session.id)
            return [
                "id": prompt.id.uuidString,
                "text": prompt.text,
                "displayText": presentation.text,
                "images": presentation.imageIDs.map { ["id": $0] },
            ]
        }
        return result
    }

    private func sendJSON(
        _ object: [String: Any],
        status: Int = 200,
        on connection: RemoteRequestConnection
    ) {
        // Only the immutable snapshot is captured; encoding large transcripts
        // must not monopolize the main actor or the socket receive queue.
        sendEncoded(status: status, on: connection) {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    private func sendEncoded(status: Int = 200, on connection: RemoteRequestConnection,
                             queue: DispatchQueue? = nil,
                             encode: @escaping () throws -> Data) {
        connection.trace.enter(.encodeWait)
        (queue ?? encodingQueue).async {
            connection.trace.enter(.encode)
            do {
                let data = try encode()
                self.send(
                    status: status,
                    contentType: "application/json; charset=utf-8",
                    body: data,
                    on: connection
                )
            } catch {
                self.requestLog("remote-request: id=\(connection.trace.id) outcome=encoding_error")
                self.send(status: 500, contentType: "application/json; charset=utf-8",
                          body: Data(#"{"error":"response serialization failed"}"#.utf8),
                          on: connection)
            }
        }
    }

    private func sendError(_ status: Int, _ message: String, on connection: RemoteRequestConnection) {
        sendJSON(["error": message], status: status, on: connection)
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        on connection: RemoteRequestConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        X-Cantrip-Request-ID: \(connection.trace.id)\r
        Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' https: data:; frame-ancestors 'none'\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(response, status: status, bodyBytes: body.count)
    }
}

private extension RemoteControlServer {
    static let webApp = """
    <!doctype html>
    <html lang="en" data-cantrip-connected="false"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="dark light"><title>Cantrip Remote</title>
    <style>
    :root{color-scheme:light dark;--chrome:rgba(240,240,242,.72);--surface:rgba(0,0,0,.045);--surface-2:rgba(0,0,0,.075);--line:rgba(0,0,0,.12);--text:rgba(20,20,24,.92);--secondary:rgba(20,20,24,.62);--tertiary:rgba(20,20,24,.42);--accent:#4169d8;--green:#28a745;--orange:#d97900;--red:#dc3545}
    @media(prefers-color-scheme:dark){:root{--chrome:rgba(44,45,50,.72);--surface:rgba(255,255,255,.045);--surface-2:rgba(255,255,255,.09);--line:rgba(255,255,255,.11);--text:rgba(255,255,255,.92);--secondary:rgba(255,255,255,.62);--tertiary:rgba(255,255,255,.38);--accent:#6b8cff;--green:#35c759;--orange:#ff9f0a;--red:#ff453a}}
    *{box-sizing:border-box}html,body{min-height:100%;background:transparent}body{margin:0;color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    button,select,input,textarea{font:inherit;color:inherit}button{cursor:pointer}.hidden{display:none!important}.grow{flex:1;min-width:0}.muted{color:var(--secondary);font-size:12px}
    #app{min-height:100vh}.workspace{position:sticky;top:0;z-index:4;background:var(--chrome);border-bottom:1px solid var(--line);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}
    .prompt-row{display:flex;align-items:center;gap:10px;padding:14px 16px 2px}.prompt-row input{flex:1;min-width:0;height:28px;padding:0;border:0;outline:0;background:transparent;font-size:20px;font-weight:300;line-height:28px}.prompt-row input::placeholder{color:var(--tertiary)}
    .tools{display:flex;align-items:center;gap:8px;min-height:32px;padding:2px 14px 8px}.tools-spacer{flex:1;min-width:8px}.connection{display:flex;align-items:center;gap:5px;color:var(--tertiary);font-size:11px}.connection-dot{width:6px;height:6px;border-radius:50%;background:var(--tertiary)}[data-cantrip-connected=true] .connection-dot{background:var(--green)}
    .control{min-height:27px;padding:4px 9px;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.control:hover{background:var(--surface-2)}.control.primary{border-color:var(--accent);background:var(--accent);color:white}.control:disabled{opacity:.45;cursor:default}.quiet{border:0;background:transparent;color:var(--secondary);font-size:12px}.quiet:hover{background:var(--surface)}
    .round{display:grid;place-items:center;flex:none;width:27px;height:27px;padding:0;border:0;border-radius:50%;background:var(--surface-2);font-size:17px;font-weight:600;line-height:1}.round:hover{filter:brightness(1.12)}.round.primary{background:var(--accent);color:white}.round.danger{color:var(--red);font-size:12px}
    #sessions{display:flex;gap:5px;min-width:0;overflow-x:auto;scrollbar-width:none}#sessions::-webkit-scrollbar{display:none}.session-tab{display:flex;align-items:center;flex:none;max-width:210px;border-radius:999px;color:var(--secondary)}.session-tab:hover{background:var(--surface);color:var(--text)}.session-tab.active{background:var(--surface-2);color:var(--text)}.session-select{min-width:0;max-width:180px;padding:4px 4px 4px 9px;border:0;background:transparent;color:inherit;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.session-close{display:grid;place-items:center;flex:none;width:22px;height:22px;padding:0 3px 1px 0;border:0;border-radius:50%;background:transparent;color:var(--tertiary);font-size:15px;line-height:1;opacity:.45}.session-tab:hover .session-close,.session-tab.active .session-close,.session-close:focus-visible{opacity:1}.session-close:hover{color:var(--red)}
    select{height:27px;max-width:90px;padding:0 5px;border:0;border-radius:6px;outline:0;background:transparent;color:var(--secondary);font-size:12px}select:hover,select:focus{background:var(--surface)}
    #messages{width:100%;min-height:calc(100vh - 88px);margin:0;padding:16px;display:flex;flex-direction:column;gap:12px}
    .message{width:100%;overflow-wrap:anywhere}.message.user{color:var(--secondary);font-size:13px;font-weight:600;line-height:1.4}.message.assistant{color:var(--text);line-height:1.5}.message.error{color:var(--orange);padding-left:21px;position:relative}.message.error:before{content:"!";position:absolute;left:3px;font-weight:800}.author{display:block;margin-bottom:5px;color:var(--tertiary);font-size:11px;font-weight:600}
    .prose p{margin:0 0 8px}.prose p:last-child{margin-bottom:0}.prose h1,.prose h2,.prose h3{margin:12px 0 6px;line-height:1.25}.prose h1:first-child,.prose h2:first-child,.prose h3:first-child{margin-top:0}.prose h1{font-size:17px}.prose h2{font-size:15px}.prose h3{font-size:13.5px}.prose ul,.prose ol{margin:4px 0 8px;padding-left:22px}.prose li{margin:3px 0}.prose blockquote{margin:7px 0;padding-left:10px;border-left:3px solid rgba(107,140,255,.55);color:var(--secondary)}.prose a{color:var(--accent);text-decoration:none}.prose a:hover{text-decoration:underline}.prose code{padding:1px 4px;border-radius:4px;background:var(--surface-2);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}.prose pre{margin:8px 0;padding:8px;border:0;border-radius:6px;background:var(--surface-2);overflow:auto}.prose pre code{padding:0;background:transparent;white-space:pre}.prose hr{margin:10px 0;border:0;border-top:1px solid var(--line)}.prose table{display:block;width:max-content;max-width:100%;margin:8px 0;border-collapse:collapse;border-radius:8px;background:var(--surface);overflow-x:auto;font-size:13px}.prose th,.prose td{padding:6px 10px;border:0;text-align:left;vertical-align:top}.prose th{font-weight:600;border-bottom:1px solid var(--line)}.prose img{display:block;max-width:min(100%,440px);max-height:280px;margin:8px 0;border-radius:8px;object-fit:contain}
    details{min-width:0}summary{list-style:none;cursor:pointer}summary::-webkit-details-marker{display:none}.disclosure{margin-top:7px;color:var(--secondary)}.disclosure>summary{display:flex;align-items:center;gap:7px;width:max-content;max-width:100%;font-size:12px}.disclosure>summary:before{content:"›";width:12px;color:var(--tertiary);font-size:17px;line-height:12px;transition:transform .12s}.disclosure[open]>summary:before{transform:rotate(90deg)}.disclosure-body{margin:7px 0 2px 18px;padding-left:10px;border-left:2px solid rgba(107,140,255,.22)}
    .steps{margin-top:8px}.status-icon{display:inline-grid;place-items:center;width:14px;height:14px;border-radius:50%;font-size:10px;font-weight:800;color:var(--tertiary)}.status-icon.succeeded{color:var(--green)}.status-icon.failed{color:var(--red)}.status-icon.cancelled{color:var(--secondary)}.status-icon.running{color:var(--accent);animation:pulse 1.1s ease-in-out infinite}@keyframes pulse{50%{opacity:.35}}
    .step{margin:5px 0;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.step>summary,.step-static{display:flex;align-items:center;gap:7px;padding:7px 9px;font-size:12px}.step>summary:after{content:"›";margin-left:auto;color:var(--tertiary);font-size:16px;transition:transform .12s}.step[open]>summary:after{transform:rotate(90deg)}.step-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tool-name{margin-left:auto;color:var(--tertiary);font:10px ui-monospace,SFMono-Regular,Menlo,monospace}.step>summary .tool-name{margin-left:8px}.step-details{display:grid;gap:8px;padding:0 9px 9px 30px}.detail-label{margin-bottom:4px;color:var(--secondary);font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}.step-details pre{max-height:180px;margin:0;padding:8px;border-radius:5px;background:var(--surface);overflow:auto;white-space:pre-wrap;word-break:break-word;color:var(--secondary);font:11px ui-monospace,SFMono-Regular,Menlo,monospace}
    .run-status{display:flex;align-items:center;gap:7px;color:var(--secondary);font-size:13px}.spinner{width:12px;height:12px;border:1.5px solid rgba(255,255,255,.2);border-top-color:var(--secondary);border-radius:50%;animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.empty{margin:auto;color:var(--tertiary)}
    #pair{width:min(calc(100% - 32px),430px);margin:18vh auto 0;padding:22px;border:1px solid var(--line);border-radius:14px;background:var(--surface);box-shadow:0 18px 50px rgba(0,0,0,.2)}#pair h2{margin:0 0 7px;font-size:18px}#pair p{line-height:1.45}#pairControls{display:flex;gap:7px;margin-top:15px}#pair input{min-width:0;padding:9px 10px;border:1px solid var(--line);border-radius:8px;outline:0;background:var(--surface)}#pair input:focus{border-color:var(--accent)}
    #tabEditor{width:min(calc(100% - 32px),380px);padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}#tabEditor::backdrop{background:rgba(0,0,0,.35)}#tabEditor form{display:grid;gap:12px}#tabName{width:100%;padding:8px;background:var(--surface);border:1px solid var(--line);border-radius:7px}.tab-actions{display:flex;justify-content:flex-end;gap:8px}#tabError,#actionError{color:var(--orange);font-size:12px}#actionError:not(:empty){padding:8px 14px}.session-close:disabled{opacity:.65;cursor:default}.session-menu{border:0;background:transparent;color:var(--secondary);padding:2px 5px}
    .prompt-preview{white-space:pre-wrap}.prompt-preview.clipped{max-height:11.2em;overflow:hidden}#promptReader{width:min(calc(100% - 24px),680px);border:1px solid var(--line);border-radius:12px;background:Canvas;color:var(--text)}#promptReader::backdrop{background:rgba(0,0,0,.35)}#promptPage{height:55vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}
    @media(max-width:620px){.prompt-row{padding-inline:12px}.tools{padding-inline:10px}.connection-label{display:none}.session-tab{max-width:145px}.session-select{max-width:115px}#messages{padding:14px 12px 22px}}
    .remote-sidebar{--sidebar-width:clamp(136px,30vw,240px)}.remote-sidebar #app{padding-left:var(--sidebar-width)}
    #sessionSidebar{position:fixed;inset:0 auto 0 0;z-index:5;display:flex;flex-direction:column;width:var(--sidebar-width);background:var(--chrome);border-right:1px solid var(--line)}
    #sessionSidebarHeader{display:flex;align-items:center;justify-content:space-between;gap:8px;flex:none;padding:12px;font-size:13px}
    .remote-sidebar #sessions{flex:1;min-height:0;flex-direction:column;gap:4px;padding:0 8px 8px;overflow-x:hidden;overflow-y:auto;overscroll-behavior-y:contain;scrollbar-width:thin}
    .remote-sidebar #sessions::-webkit-scrollbar{display:initial;width:6px}.remote-sidebar #sessions::-webkit-scrollbar-thumb{background:var(--line);border-radius:3px}
    .remote-sidebar .session-tab{width:100%;max-width:none;min-height:40px;border-radius:8px}.remote-sidebar .session-tab.active{background:var(--surface-2);box-shadow:inset 3px 0 var(--accent)}
    .remote-sidebar .session-select{flex:1;max-width:none;padding:9px 6px 9px 9px;text-align:left;white-space:normal;overflow-wrap:anywhere;line-height:1.35}
    .remote-sidebar .session-close{opacity:1}.remote-sidebar .session-menu{flex:none}.remote-sidebar .tools,.remote-sidebar .prompt-row{flex-wrap:wrap}.remote-sidebar .prompt-row input{flex:1 1 80px}
    .session-name{font-weight:600}.session-status{display:block;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--secondary);font-size:11px;font-weight:400}
    .brain-indicator{display:inline-block;flex:none;width:16px;height:16px;margin-right:4px;vertical-align:-3px;color:var(--tertiary);visibility:hidden}
    [data-streaming=true] .brain-indicator{visibility:visible;color:var(--accent);animation:pulse 1.1s ease-in-out infinite}
    #sessionProgress{min-width:0;padding:0 14px 9px;font-size:12px}#sessionProgress .brain-indicator{margin:0}#sessionProgressText{display:-webkit-box;min-width:0;overflow:hidden;overflow-wrap:anywhere;-webkit-line-clamp:2;-webkit-box-orient:vertical;line-height:1.35}
    [data-cantrip-connected=false] .brain-indicator,[data-cantrip-connected=false].remote-sidebar .status-icon.running{animation:none;color:var(--tertiary)}
    @media(prefers-reduced-motion:reduce){.brain-indicator,.spinner,.status-icon.running{animation:none}}
    .session-tab[draggable=true]{cursor:grab}.session-tab.drop-target{outline:2px solid var(--accent);outline-offset:-2px}
    </style></head><body>
    <section id="pair"><h2>Pair Cantrip Remote</h2><p class="muted">Paste the token from Cantrip Settings. It stays in this browser only.</p>
    <div id="pairControls"><input id="token" class="grow" type="password" placeholder="Pairing token" autocomplete="off"><button id="pairButton" class="control primary">Connect</button></div><p id="pairError" class="muted"></p></section>
    <main id="app" class="hidden"><aside id="sessionSidebar" class="hidden" aria-labelledby="sessionSidebarTitle"><div id="sessionSidebarHeader"><strong id="sessionSidebarTitle">Tabs</strong></div></aside><header class="workspace">
    <div class="prompt-row"><input id="draft" type="text" placeholder="How can I help you?" autocomplete="off"><button id="resume" class="control quiet hidden">Resume</button><button id="stop" class="round danger hidden" title="Stop" aria-label="Stop">■</button><button id="send" class="round primary" title="Send" aria-label="Send">↑</button></div>
    <div class="tools"><nav id="sessions" aria-label="Remote sessions"></nav><button id="newSession" class="round" title="New remote session" aria-label="New remote session">+</button><span class="tools-spacer"></span>
    <select id="mode" aria-label="Delivery override"><option value="auto">Auto</option><option value="queue">Queue</option><option value="interrupt">Redirect</option><option value="inject">Inject</option></select>
    <span class="connection"><span class="connection-dot"></span><span class="connection-label">Connected</span></span><button id="forget" class="control quiet">Unpair</button></div>
    <div id="sessionProgress" class="run-status hidden" role="status" aria-live="polite" aria-atomic="true"><span id="sessionProgressText"></span></div></header>
    <div id="actionError" role="alert"></div><div id="historyError" role="alert"></div><button id="olderMessages" class="control hidden">Load older messages</button><section id="messages"></section></main>
    <dialog id="tabEditor" aria-labelledby="tabEditorTitle"><form id="tabForm">
    <strong id="tabEditorTitle">Tab settings</strong><label>Tab name<input id="tabName" autocomplete="off"></label>
    <span class="muted">Up to 80 characters. Leave blank for the automatic name.</span>
    <label><input id="tabLocked" type="checkbox"> Lock tab against closing or clearing</label>
    <div id="tabMoveControls" class="tab-actions hidden"><button id="tabMoveEarlier" type="button" class="control">Move earlier</button><button id="tabMoveLater" type="button" class="control">Move later</button></div>
    <div id="tabError" role="alert"></div><div class="tab-actions"><button id="tabCancel" type="button" class="control">Cancel</button><button id="tabSave" type="submit" class="control primary">Save</button></div>
    </form></dialog>
    <dialog id="promptReader" aria-labelledby="promptTitle"><strong id="promptTitle">Full prompt</strong>
    <pre id="promptPage"></pre><div class="tab-actions"><button id="promptPrevious" class="control">Previous</button><span id="promptNumber"></span><button id="promptNext" class="control">Next</button><button id="promptDownload" class="control">Download all</button><button id="promptDone" class="control">Done</button></div></dialog>
    <script>
    const $=id=>document.getElementById(id);let token=localStorage.cantripToken||"",selected=null,timer=null,renderedSession=null,renderedPayload="",followOutput=true,suppressScroll=false;const expanded=new Set();
    // The native Mac embed exposes this bridge; ordinary browsers keep the top tab strip.
    const sidebarLayout=Boolean(window.webkit?.messageHandlers?.cantripRemoteUnpair);
    if(sidebarLayout){document.documentElement.classList.add("remote-sidebar");$("sessionSidebar").classList.remove("hidden");$("sessionSidebar").append($("sessions"));$("sessionSidebarHeader").append($("newSession"));$("sessionProgress").prepend(brainIndicator())}
    function connection(active){document.documentElement.dataset.cantripConnected=active?"true":"false";const label=document.querySelector(".connection-label");if(label)label.textContent=active?"Connected":"Reconnecting…";updateProgressConnection()}
    function brainIndicator(){const icon=document.createElementNS("http://www.w3.org/2000/svg","svg");icon.setAttribute("class","brain-indicator");icon.setAttribute("viewBox","0 0 24 24");icon.setAttribute("aria-hidden","true");icon.setAttribute("focusable","false");
      const path=document.createElementNS(icon.namespaceURI,"path");path.setAttribute("d","M12 5C12 1 6 1 6 5C3 5 2 8 4 10C1 12 2 16 5 17C4 21 10 23 12 19C14 23 20 21 19 17C22 16 23 12 20 10C22 8 21 5 18 5C18 1 12 1 12 5V19M6 5C6 8 9 7 9 10M4 10C7 10 8 12 6 14M5 17C8 16 10 17 10 19M18 5C18 8 15 7 15 10M20 10C17 10 16 12 18 14M19 17C16 16 14 17 14 19");path.setAttribute("fill","none");path.setAttribute("stroke","currentColor");path.setAttribute("stroke-width","1.5");path.setAttribute("stroke-linecap","round");path.setAttribute("stroke-linejoin","round");icon.append(path);return icon}
    function setText(node,text){if(node.textContent!==text)node.textContent=text}
    function progressSummary(session){const parts=[session.isStreaming?(session.status||"Working…"):(session.canResume?"Paused":"Ready")];if(session.queuedCount>0)parts.push(`${session.queuedCount} queued`);return parts.join(" · ")}
    function updateProgressConnection(){if(!sidebarLayout)return;const connected=document.documentElement.dataset.cantripConnected==="true";
      for(const button of $("sessions").querySelectorAll(".session-select")){const summary=connected?button.dataset.status:`Last known: ${button.dataset.status}`;setText(button.querySelector(".session-status"),summary);button.title=`${button.dataset.title} — ${summary}${button.dataset.locked==="true"?" · Locked":""}`;button.setAttribute("aria-label",button.title)}
      const progress=$("sessionProgress");if(!progress.classList.contains("hidden")){const summary=connected?progress.dataset.status:`Reconnecting… Last known: ${progress.dataset.status}`;setText($("sessionProgressText"),summary);progress.title=summary}}
    function renderProgress(session){if(!sidebarLayout)return;const progress=$("sessionProgress");progress.classList.toggle("hidden",!session);progress.dataset.streaming=String(Boolean(session?.isStreaming));progress.dataset.status=session?progressSummary(session):"";if(!session)setText($("sessionProgressText"),"");updateProgressConnection()}
    function atBottom(){const root=document.scrollingElement||document.documentElement;return root.scrollHeight-root.clientHeight-root.scrollTop<=4}
    addEventListener("wheel",event=>{if(event.deltaY<0&&!event.target.closest("#sessions"))followOutput=false},{passive:true});
    addEventListener("scroll",()=>{if(!suppressScroll)followOutput=atBottom()},{passive:true});
    async function api(path,options={}){options.headers={...(options.headers||{}),Authorization:`Bearer ${token}`};if(options.body)options.headers["Content-Type"]="application/json";
      path+=(path.includes("?")?"&":"?")+"history=recent";
      const controller=(!options.method||options.method==="GET")?new AbortController():null;
      const deadline=controller?setTimeout(()=>controller.abort(),path.includes("/messages/")?20000:8000):null;if(controller)options.signal=controller.signal;
      try{const response=await fetch(path,options);const data=await response.json();if(!response.ok){const error=new Error(data.error||`HTTP ${response.status}`);error.status=response.status;throw error}return data}finally{if(deadline!==null)clearTimeout(deadline)}}
    function pair(show){$("pair").classList.toggle("hidden",!show);$("app").classList.toggle("hidden",show);if(show){connection(false);if(timer){clearInterval(timer);timer=null}}}
    let refreshTask=null,refreshRequested=false,sessionItems=[],draggedTabID=null,movingTab=false,tabOrderRevision=0,loadingHistory=false;
    const historyCache=new Map(),expandedHistory=new Set();
    function cacheSession(session,merge=true){const previous=historyCache.get(session.id);
      if(previous?.historyStartID!==session.historyStartID)expandedHistory.delete(session.id);
      if(merge&&session.historyStartID&&previous?.historyStartID===session.historyStartID){
        const overlap=previous.messages.findIndex(m=>m.id===session.messages[0]?.id);
        if(overlap>=0)session={...session,messages:[...previous.messages.slice(0,overlap),...session.messages],hasOlderMessages:previous.hasOlderMessages}}
      if(!expandedHistory.has(session.id)&&session.supportsPagedHistory&&session.messages.length>120)session={...session,messages:session.messages.slice(-120),hasOlderMessages:true};
      historyCache.delete(session.id);historyCache.set(session.id,session);while(historyCache.size>5){const id=historyCache.keys().next().value;historyCache.delete(id);expandedHistory.delete(id)}return session}
    function scheduleRefresh(){if(timer)clearTimeout(timer);timer=null;if(!token||document.hidden)return;
      const busy=sessionItems.some(s=>s.isStreaming||s.queuedCount)||$("historyError").textContent||document.documentElement.dataset.cantripConnected!=="true";
      timer=setTimeout(refresh,busy?1500:5000)}
    function refresh(){refreshRequested=true;if(refreshTask)return refreshTask;
      refreshTask=(async()=>{while(refreshRequested&&token){refreshRequested=false;const requestedID=selected,requestToken=token,orderRevision=tabOrderRevision;
        let listedSuccessfully=false,requestSelection=requestedID;
        try{const listed=await api("/api/v1/sessions");if(token!==requestToken||orderRevision!==tabOrderRevision)continue;connection(true);listedSuccessfully=true;
          for(const id of historyCache.keys())if(!listed.sessions.some(s=>s.id===id)){historyCache.delete(id);expandedHistory.delete(id)}
          if(selected!==requestedID){refreshRequested=true;continue}
          if(!selected||!listed.sessions.some(s=>s.id===selected))selected=listed.sessions[0]?.id||null;
          requestSelection=selected;
          renderSessions(listed.sessions);const detailID=selected;if(detailID){const cached=historyCache.get(detailID),summary=listed.sessions.find(s=>s.id===detailID);
            if(cached)render(cached);else if(renderedSession!==detailID)render(null);
            if(!cached?.historyRevision||cached.historyRevision!==summary.historyRevision){
              const suffix=cached?.historyRevision?`?revision=${encodeURIComponent(cached.historyRevision)}`:"";
              const data=await api(`/api/v1/sessions/${detailID}${suffix}`);if(token!==requestToken||orderRevision!==tabOrderRevision)continue;if(selected!==detailID){refreshRequested=true;continue}
              if(data.session)render(cacheSession(data.session));else if(!data.unchanged||!cached)throw new Error("Invalid conversation update")}
          }else render(null);$("historyError").textContent=""}
        catch(error){if(token!==requestToken||selected!==requestSelection)continue;
          if(!listedSuccessfully||error.status===401)connection(false);
          $("historyError").textContent=`${listedSuccessfully?"Could not update this conversation":"Could not refresh tabs"}: ${error.message}. Retrying...`;
          if(error.status===401){refreshRequested=false;pair(true)}}}
      })().finally(()=>{refreshTask=null;scheduleRefresh()});return refreshTask}
    async function loadOlderMessages(){const current=historyCache.get(selected),before=current?.messages[0]?.id;if(loadingHistory||!current?.hasOlderMessages||!before)return;
      const requestToken=token,orderRevision=tabOrderRevision;loadingHistory=true;$("olderMessages").disabled=true;$("olderMessages").textContent="Loading older messages...";
      try{const data=await api(`/api/v1/sessions/${current.id}?before=${encodeURIComponent(before)}`),latest=historyCache.get(current.id);
        if(token!==requestToken||selected!==current.id||orderRevision!==tabOrderRevision||latest?.historyStartID!==data.session.historyStartID||latest?.messages[0]?.id!==before)return;
        const ids=new Set(latest.messages.map(m=>m.id)),page=data.session;expandedHistory.add(current.id);
        render(cacheSession({...latest,messages:[...page.messages.filter(m=>!ids.has(m.id)),...latest.messages],hasOlderMessages:page.hasOlderMessages},false),true);$("historyError").textContent=""}
      catch(error){if(token===requestToken&&selected===current.id)$("historyError").textContent=`Could not load older messages: ${error.message}. Try again.`}
      finally{loadingHistory=false;$("olderMessages").disabled=false;$("olderMessages").textContent="Load older messages"}}
    $("olderMessages").onclick=loadOlderMessages;
    document.addEventListener("visibilitychange",()=>{if(document.hidden){if(timer)clearTimeout(timer);timer=null}else if(token)refresh()});
    function renderSessions(items){const nav=$("sessions"),previousLeft=nav.scrollLeft,previousTop=nav.scrollTop,selectionChanged=nav.dataset.selected!==(selected||"");
      if(draggedTabID||movingTab)return;sessionItems=items;
      // Keep existing controls mounted so polling does not interrupt scrolling or keyboard focus.
      const existing=new Map(Array.from(nav.children,tab=>[tab.dataset.sessionId,tab])),ids=new Set(items.map(item=>item.id));
      for(const tab of Array.from(nav.children))if(!ids.has(tab.dataset.sessionId))tab.remove();
      for(const [index,item] of items.entries()){let tab=existing.get(item.id);
        if(!tab){tab=document.createElement("span");tab.dataset.sessionId=item.id;
          const button=document.createElement("button");button.className="session-select";
          if(sidebarLayout){const title=document.createElement("span"),status=document.createElement("span");title.className="session-name";status.className="session-status";button.append(brainIndicator(),title,status)}
          const close=document.createElement("button");close.className="session-close";tab.append(button,close)}
        tab.className=`session-tab ${item.id===selected?"active":""}`;
        tab.draggable=Boolean(item.supportsTabReordering);
        tab.ondragstart=event=>{if(movingTab||!item.supportsTabReordering){event.preventDefault();return}draggedTabID=item.id;event.dataTransfer.effectAllowed="move";event.dataTransfer.setData("text/plain",`cantrip-tab:${item.id}`)};
        tab.ondragend=()=>{draggedTabID=null;for(const row of nav.children)row.classList.remove("drop-target");refresh()};
        tab.ondragover=event=>{if(draggedTabID&&draggedTabID!==item.id&&item.supportsTabReordering&&!movingTab){event.preventDefault();event.dataTransfer.dropEffect="move";tab.classList.add("drop-target")}};
        tab.ondragleave=()=>tab.classList.remove("drop-target");
        tab.ondrop=event=>{event.preventDefault();tab.classList.remove("drop-target");const id=draggedTabID;draggedTabID=null;
          const source=sessionItems.findIndex(s=>s.id===id),target=sessionItems.findIndex(s=>s.id===item.id);
          if(id&&id!==item.id&&source>=0&&target>=0&&item.supportsTabReordering)moveTab(id,item.id,source<target)};
        tab.onkeydown=event=>{if(!event.altKey||!item.supportsTabReordering)return;const earlier=sidebarLayout?"ArrowUp":"ArrowLeft",later=sidebarLayout?"ArrowDown":"ArrowRight";
          if(event.key===earlier||event.key===later){event.preventDefault();moveTabBy(item.id,event.key===earlier?-1:1)}};
        const button=tab.children[0];if(sidebarLayout){setText(button.querySelector(".session-name"),item.title);tab.dataset.streaming=String(Boolean(item.isStreaming));button.dataset.title=item.title;button.dataset.status=progressSummary(item);button.dataset.locked=String(Boolean(item.isLocked))}else{button.textContent=item.title;button.title=item.title}
        button.setAttribute("aria-current",item.id===selected?"true":"false");button.onclick=()=>{selected=item.id;renderedPayload="";renderProgress(item);refresh()};
        const close=tab.children[1];close.textContent=item.isLocked?"🔒":"×";close.disabled=Boolean(item.isLocked);close.title=item.isLocked?"Locked - unlock in tab settings":`Close ${item.title}`;close.setAttribute("aria-label",close.title);close.onclick=event=>{event.stopPropagation();closeSession(item.id)};
        let menu=tab.children[2];if(item.supportsTabMetadata){if(!menu){menu=document.createElement("button");menu.className="session-menu";menu.textContent="…";tab.append(menu)}
          menu.title=`Settings for ${item.title}${item.supportsTabReordering?" - drag tabs to reorder":""}`;menu.setAttribute("aria-label",menu.title);menu.onclick=()=>editTab(item)}else if(menu)menu.remove();
        if(nav.children[index]!==tab)nav.insertBefore(tab,nav.children[index]||null)}
      renderProgress(items.find(item=>item.id===selected));if(nav.scrollLeft!==previousLeft)nav.scrollLeft=previousLeft;if(nav.scrollTop!==previousTop)nav.scrollTop=previousTop;nav.dataset.selected=selected||"";
      if(selectionChanged){const active=nav.querySelector(".active");if(active){const bounds=active.getBoundingClientRect(),viewport=nav.getBoundingClientRect();
        if(sidebarLayout){if(bounds.top<viewport.top||bounds.height>viewport.height)nav.scrollTop+=bounds.top-viewport.top;
          else if(bounds.bottom>viewport.bottom)nav.scrollTop+=bounds.bottom-viewport.bottom}
        else if(bounds.left<viewport.left||bounds.width>viewport.width)nav.scrollLeft+=bounds.left-viewport.left;
        else if(bounds.right>viewport.right)nav.scrollLeft+=bounds.right-viewport.right}}}
    $("sessions").addEventListener("wheel",event=>{const nav=$("sessions");
      if(sidebarLayout||event.ctrlKey||event.shiftKey||Math.abs(event.deltaX)>=Math.abs(event.deltaY)||nav.scrollWidth<=nav.clientWidth)return;
      event.preventDefault();const unit=event.deltaMode===1?16:event.deltaMode===2?nav.clientWidth:1;nav.scrollLeft+=event.deltaY*unit
    },{passive:false});
    let editingTab=null,tabSaving=false;
    function editTab(item){editingTab=item;$("tabName").value=item.customTitle||item.title;$("tabLocked").checked=Boolean(item.isLocked);$("tabError").textContent="";updateTabMoveControls();$("tabEditor").showModal();$("tabName").focus();$("tabName").select()}
    function updateTabMoveControls(){const index=sessionItems.findIndex(s=>s.id===editingTab?.id);
      $("tabMoveControls").classList.toggle("hidden",!editingTab?.supportsTabReordering);
      $("tabMoveEarlier").textContent=sidebarLayout?"Move up":"Move left";$("tabMoveLater").textContent=sidebarLayout?"Move down":"Move right";
      $("tabMoveEarlier").disabled=movingTab||tabSaving||index<=0;$("tabMoveLater").disabled=movingTab||tabSaving||index<0||index>=sessionItems.length-1}
    $("tabMoveEarlier").onclick=()=>{if(editingTab)moveTabBy(editingTab.id,-1)};
    $("tabMoveLater").onclick=()=>{if(editingTab)moveTabBy(editingTab.id,1)};
    $("tabCancel").onclick=()=>{$("tabEditor").close();editingTab=null};
    $("tabEditor").addEventListener("cancel",event=>{if(tabSaving||movingTab)event.preventDefault()});
    $("tabForm").onsubmit=async event=>{event.preventDefault();if(!editingTab||tabSaving||movingTab)return;const item=editingTab,body={};
      if($("tabName").value!==(item.customTitle||item.title))body.customTitle=$("tabName").value;
      if($("tabLocked").checked!==Boolean(item.isLocked))body.isLocked=$("tabLocked").checked;
      if(!Object.keys(body).length){$("tabEditor").close();return}tabSaving=true;$("tabSave").disabled=true;$("tabCancel").disabled=true;updateTabMoveControls();
      try{await api(`/api/v1/sessions/${item.id}/metadata`,{method:"POST",body:JSON.stringify(body)});$("tabEditor").close();editingTab=null;await refresh()}
      catch(error){$("tabError").textContent=`${error.message} Refresh the session if the result is uncertain.`}
      finally{tabSaving=false;$("tabSave").disabled=false;$("tabCancel").disabled=false;updateTabMoveControls()}};
    function moveTabBy(id,offset){const index=sessionItems.findIndex(s=>s.id===id),target=sessionItems[index+offset];if(index>=0&&target)moveTab(id,target.id,offset>0)}
    async function moveTab(id,targetID,after){if(movingTab||tabSaving)return;movingTab=true;tabOrderRevision++;const requestToken=token;
      $("actionError").textContent="";$("tabError").textContent="";$("tabSave").disabled=true;$("tabCancel").disabled=true;updateTabMoveControls();
      try{const data=await api(`/api/v1/sessions/${id}/move`,{method:"POST",body:JSON.stringify({targetID,placement:after?"after":"before"})});
        if(token===requestToken){movingTab=false;renderSessions(data.sessions)}}
      catch(error){if(token===requestToken){const message=`${error.message} Refresh the tabs before trying again; the move may have reached Cantrip.`;$("actionError").textContent=message;$("tabError").textContent=message}}
      finally{movingTab=false;$("tabSave").disabled=false;$("tabCancel").disabled=false;updateTabMoveControls();refresh()}}
    function safeURL(raw,image=false){try{const url=new URL(raw,location.href);if(url.protocol==="https:"||url.protocol==="http:"||(!image&&url.protocol==="mailto:"))return url.href}catch{}return null}
    function appendInline(parent,source){source=source.replace(/<br\\s*\\/?\\s*>/gi,"\\n");let cursor=0,plain="";
      const flush=()=>{if(plain){parent.append(document.createTextNode(plain));plain=""}};
      const paired=(marker,tag)=>{const end=source.indexOf(marker,cursor+marker.length);if(end<0)return false;flush();const node=document.createElement(tag);appendInline(node,source.slice(cursor+marker.length,end));parent.append(node);cursor=end+marker.length;return true};
      while(cursor<source.length){if(source[cursor]==="\\\\"&&cursor+1<source.length){plain+=source[cursor+1];cursor+=2;continue}
        if(source[cursor]==="`"){const end=source.indexOf("`",cursor+1);if(end>=0){flush();const code=document.createElement("code");code.textContent=source.slice(cursor+1,end);parent.append(code);cursor=end+1;continue}}
        const image=source.slice(cursor).match(/^!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+["'][^"']*["'])?\\)/),imageURL=image&&safeURL(image[2],true);if(imageURL){flush();const img=document.createElement("img");img.alt=image[1];img.src=imageURL;img.loading="lazy";parent.append(img);cursor+=image[0].length;continue}
        const link=source.slice(cursor).match(/^\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+["'][^"']*["'])?\\)/),linkURL=link&&safeURL(link[2]);if(linkURL){flush();const anchor=document.createElement("a");anchor.href=linkURL;anchor.target="_blank";anchor.rel="noopener noreferrer";appendInline(anchor,link[1]);parent.append(anchor);cursor+=link[0].length;continue}
        const auto=source.slice(cursor).match(/^<(https?:\\/\\/[^ >]+|mailto:[^ >]+)>/),autoURL=auto&&safeURL(auto[1]);if(autoURL){flush();const anchor=document.createElement("a");anchor.href=autoURL;anchor.target="_blank";anchor.rel="noopener noreferrer";anchor.textContent=auto[1];parent.append(anchor);cursor+=auto[0].length;continue}
        if(source.startsWith("**",cursor)&&paired("**","strong"))continue;if(source.startsWith("__",cursor)&&paired("__","strong"))continue;if(source.startsWith("~~",cursor)&&paired("~~","del"))continue;
        if(source[cursor]==="*"&&paired("*","em"))continue;if(source[cursor]==="_"&&paired("_","em"))continue;
        if(source[cursor]==="\\n"){flush();parent.append(document.createElement("br"));cursor++;continue}plain+=source[cursor++]}
      flush()}
    function listLine(line){const match=line.match(/^(\\s*)([-*+]|\\d+[.)])\\s+(.+)$/);return match?{indent:Math.floor(match[1].length/2),ordered:/^\\d/.test(match[2]),start:parseInt(match[2],10)||1,text:match[3]}:null}
    function tableCells(line){let text=line.trim();if(text.startsWith("|"))text=text.slice(1);if(text.endsWith("|"))text=text.slice(0,-1);return text.split("|").map(cell=>cell.trim())}
    function appendProse(parent,source){const prose=document.createElement("div");prose.className="prose";const lines=source.split("\\n");let index=0,paragraph=[];
      const flush=()=>{if(!paragraph.length)return;const p=document.createElement("p");appendInline(p,paragraph.join(" "));prose.append(p);paragraph=[]};
      while(index<lines.length){const line=lines[index],trimmed=line.trim();if(!trimmed){flush();index++;continue}
        if(trimmed.startsWith("```")){flush();index++;const codeLines=[];while(index<lines.length&&!lines[index].trim().startsWith("```"))codeLines.push(lines[index++]);if(index<lines.length)index++;const pre=document.createElement("pre"),code=document.createElement("code");code.textContent=codeLines.join("\\n");pre.append(code);prose.append(pre);continue}
        const heading=trimmed.match(/^(#{1,6})\\s+(.+)$/);if(heading){flush();const level=Math.min(3,heading[1].length),node=document.createElement(`h${level}`);appendInline(node,heading[2]);prose.append(node);index++;continue}
        if(/^(---+|\\*\\*\\*+|___+)$/.test(trimmed)){flush();prose.append(document.createElement("hr"));index++;continue}
        if(trimmed.startsWith(">")){flush();const quoted=[];while(index<lines.length&&lines[index].trim().startsWith(">"))quoted.push(lines[index++].trim().replace(/^>\\s?/,""));const quote=document.createElement("blockquote");appendProse(quote,quoted.join("\\n"));prose.append(quote);continue}
        if(trimmed.includes("|")&&index+1<lines.length&&/^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?\\s*$/.test(lines[index+1])){flush();const table=document.createElement("table"),head=document.createElement("thead"),headRow=document.createElement("tr");for(const cell of tableCells(line)){const th=document.createElement("th");appendInline(th,cell);headRow.append(th)}head.append(headRow);table.append(head);index+=2;const body=document.createElement("tbody");while(index<lines.length&&lines[index].includes("|")&&lines[index].trim()){const row=document.createElement("tr");for(const cell of tableCells(lines[index++])){const td=document.createElement("td");appendInline(td,cell);row.append(td)}body.append(row)}table.append(body);prose.append(table);continue}
        const item=listLine(line);if(item){flush();const list=document.createElement(item.ordered?"ol":"ul");if(item.ordered)list.start=item.start;while(index<lines.length){const next=listLine(lines[index]);if(!next||next.ordered!==item.ordered)break;const li=document.createElement("li");li.style.marginLeft=`${next.indent*16}px`;appendInline(li,next.text);list.append(li);index++}prose.append(list);continue}
        paragraph.push(trimmed);index++}flush();parent.append(prose)}
    function statusIcon(state){const icon=document.createElement("span");icon.className=`status-icon ${state}`;icon.textContent=state==="running"?"•":state==="succeeded"?"✓":state==="failed"?"×":"–";return icon}
    function remember(details,key){details.open=expanded.has(key);details.addEventListener("toggle",()=>{if(details.open)expanded.add(key);else expanded.delete(key)});return details}
    function appendDetail(parent,label,value){if(!value)return;const section=document.createElement("section"),title=document.createElement("div"),content=document.createElement("pre");title.className="detail-label";title.textContent=label;content.textContent=value;section.append(title,content);parent.append(section)}
    function appendActivity(parent,activity,messageID){const hasDetails=Boolean(activity.input||activity.output),row=document.createElement(hasDetails?"details":"div");row.className="step";
      const head=document.createElement(hasDetails?"summary":"div");if(!hasDetails)head.className="step-static";head.append(statusIcon(activity.state));const title=document.createElement("span");title.className="step-title";title.textContent=activity.title||activity.toolName;const tool=document.createElement("span");tool.className="tool-name";tool.textContent=activity.toolName;head.append(title,tool);row.append(head);
      if(hasDetails){remember(row,`activity:${messageID}:${activity.id}`);const body=document.createElement("div");body.className="step-details";appendDetail(body,"Input",activity.input);appendDetail(body,"Output",activity.output);row.append(body)}parent.append(row)}
    function appendActivities(parent,activities,messageID){if(!activities.length)return;const disclosure=remember(document.createElement("details"),`steps:${messageID}`);disclosure.className="disclosure steps";
      const states=activities.map(item=>item.state),state=states.includes("running")?"running":states.includes("failed")?"failed":states.includes("cancelled")?"cancelled":"succeeded";const summary=document.createElement("summary");summary.append(statusIcon(state));
      const label=document.createElement("span");const noun=activities.length===1?"step":"steps";label.textContent=state==="running"?`Working · ${activities.length} ${noun}`:`${activities.length} ${noun}`;summary.append(label);disclosure.append(summary);
      const body=document.createElement("div");body.className="disclosure-body";for(const activity of activities)appendActivity(body,activity,messageID);disclosure.append(body);parent.append(disclosure)}
    function appendThinking(parent,text,messageID){if(!text)return;const details=remember(document.createElement("details"),`thinking:${messageID}`);details.className="disclosure";const summary=document.createElement("summary");const label=document.createElement("span");label.textContent="Reasoning";summary.append(label);const body=document.createElement("div");body.className="disclosure-body prose";body.textContent=text;details.append(summary,body);parent.append(details)}
    function promptSlice(text,start,limit){let end=Math.min(text.length,start+limit);if(end<text.length&&text.charCodeAt(end-1)>=0xD800&&text.charCodeAt(end-1)<=0xDBFF)end--;return {text:text.slice(start,end),end}}
    function appendPrompt(parent,text){const preview=document.createElement("div"),page=promptSlice(text,0,1200),long=page.end<text.length;preview.className=`prompt-preview${long?" clipped":""}`;preview.textContent=page.text;parent.append(preview);
      if(long){const button=document.createElement("button");button.className="control quiet";button.textContent="Read full prompt";button.onclick=()=>readPrompt(text);parent.append(button)}}
    let readingPrompt="",promptStarts=[0],promptEnd=0;
    function renderPromptPage(){const page=promptSlice(readingPrompt,promptStarts[promptStarts.length-1],4000);promptEnd=page.end;$("promptPage").textContent=page.text;$("promptPage").scrollTop=0;$("promptNumber").textContent=`Page ${promptStarts.length}`;$("promptPrevious").disabled=promptStarts.length===1;$("promptNext").disabled=promptEnd===readingPrompt.length}
    function readPrompt(text){readingPrompt=text;promptStarts=[0];$("promptTitle").textContent="Full prompt";renderPromptPage();$("promptReader").showModal()}
    $("promptPrevious").onclick=()=>{if(promptStarts.length>1){promptStarts.pop();renderPromptPage()}};
    $("promptNext").onclick=()=>{if(promptEnd<readingPrompt.length){promptStarts.push(promptEnd);renderPromptPage()}};
    $("promptDownload").onclick=()=>{const url=URL.createObjectURL(new Blob([readingPrompt],{type:"text/plain;charset=utf-8"})),link=document.createElement("a");link.href=url;link.download="cantrip-prompt.txt";link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
    $("promptDone").onclick=()=>$("promptReader").close();
    $("promptReader").addEventListener("close",()=>{readingPrompt="";promptStarts=[0];$("promptPage").textContent=""});
    function render(session,prepend=false){const root=document.scrollingElement||document.documentElement,previousTop=root.scrollTop,previousHeight=root.scrollHeight;
      renderProgress(session);$("olderMessages").classList.toggle("hidden",!session?.hasOlderMessages);const box=$("messages"),sessionID=session?.id||null,payload=JSON.stringify(session);if(sessionID===renderedSession&&payload===renderedPayload)return;
      const sameSession=sessionID===renderedSession,shouldFollow=!prepend&&(followOutput||!sameSession);renderedSession=sessionID;renderedPayload=payload;suppressScroll=true;box.replaceChildren();$("resume").classList.toggle("hidden",!session?.canResume);$("stop").classList.toggle("hidden",!session?.isStreaming);
      if(!session){const empty=document.createElement("div");empty.className="empty";empty.textContent="No open sessions.";box.append(empty)}
      else{for(const message of session.messages){const activities=message.activities||[];if(!message.text&&!message.thinking&&!activities.length)continue;const row=document.createElement("article");row.className=`message ${message.role}`;
          if(message.author){const author=document.createElement("span");author.className="author";author.textContent=message.author;row.append(author)}
          appendThinking(row,message.thinking,message.id);if(message.text){if(message.role==="user")appendPrompt(row,message.text);else appendProse(row,message.text)}appendActivities(row,activities,message.id);
          if(message.isPreview){const button=document.createElement("button");button.className="control quiet";button.textContent="Load full message and details";button.onclick=async()=>{
            const requestToken=token;button.disabled=true;try{const data=await api(`/api/v1/sessions/${session.id}/messages/${message.id}`);if(token!==requestToken||selected!==session.id)return;
              const full=data.message,parts=[full.text];if(full.thinking)parts.push("Reasoning\\n"+full.thinking);for(const step of full.activities||[])parts.push([step.title,step.input,step.output].filter(Boolean).join("\\n"));readPrompt(parts.join("\\n\\n"));$("promptTitle").textContent="Message details"}
            catch(error){if(token===requestToken)$("historyError").textContent=`Could not load message details: ${error.message}`}finally{button.disabled=false}};row.append(button)}box.append(row)}
        if(session.deliveryStatus){const note=document.createElement("div");note.className="run-status";note.textContent=session.deliveryStatus;box.append(note)}
        if(!sidebarLayout&&(session.isStreaming||session.queuedCount)){const status=document.createElement("div");status.className="run-status";if(session.isStreaming){const spinner=document.createElement("span");spinner.className="spinner";status.append(spinner)}const label=document.createElement("span");label.textContent=session.isStreaming?(session.status||"Working…"):`${session.queuedCount} queued`;status.append(label);box.append(status)}}
      requestAnimationFrame(()=>{root.scrollTop=shouldFollow?root.scrollHeight:Math.min(previousTop+(prepend?root.scrollHeight-previousHeight:0),Math.max(0,root.scrollHeight-root.clientHeight));followOutput=shouldFollow;suppressScroll=false})}
    async function action(name,body){if(!selected)return;await api(`/api/v1/sessions/${selected}/${name}`,{method:"POST",body:body?JSON.stringify(body):undefined});await refresh()}
    async function closeSession(id){$("actionError").textContent="";try{const data=await api(`/api/v1/sessions/${id}/close`,{method:"POST"});if(selected===id)selected=data.session.id;renderedPayload="";await refresh()}
      catch(error){$("actionError").textContent=`Close failed: ${error.message}`}}
    $("pairButton").onclick=async()=>{historyCache.clear();expandedHistory.clear();token=$("token").value.trim();try{await api("/api/v1/sessions");localStorage.cantripToken=token;connection(true);pair(false);refresh()}
      catch(error){$("pairError").textContent=error.message}};
    $("send").onclick=async()=>{const text=$("draft").value.trim();if(!text)return;$("send").disabled=true;try{await action("messages",{text,mode:$("mode").value});if($("draft").value.trim()===text)$("draft").value="";$("mode").value="auto"}catch(error){const label=document.querySelector(".connection-label");if(label)label.textContent=`Send failed: ${error.message}. Check the session before resending.`}finally{$("send").disabled=false}};
    $("draft").onkeydown=event=>{if(event.key==="Enter"&&!event.shiftKey){event.preventDefault();$("send").click()}};
    $("stop").onclick=()=>action("cancel");$("resume").onclick=()=>action("resume");$("newSession").onclick=async()=>{const data=await api("/api/v1/sessions",{method:"POST"});selected=data.session.id;refresh()};
    $("forget").onclick=()=>{localStorage.removeItem("cantripToken");historyCache.clear();expandedHistory.clear();token="";connection(false);pair(true);window.webkit?.messageHandlers?.cantripRemoteUnpair?.postMessage(null)};if(token){pair(false);refresh()}else pair(true);
    </script></body></html>
    """
}
