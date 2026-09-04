import Foundation
import Network

/// Authenticated HTTP control plane for the live sessions owned by the app.
/// The listener is deliberately loopback-only; Tailscale Serve adds HTTPS
/// and tailnet reachability without exposing a LAN service.
final class RemoteControlServer {
    var onError: ((String?) -> Void)?

    private weak var manager: SessionManager?
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-control")
    private var listener: NWListener?
    private var activePort: Int?
    private var token = ""
    private let maximumRequestBytes = 1 << 20

    init(manager: SessionManager) {
        self.manager = manager
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
        if listener != nil, activePort == port, self.token == token { return }
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
        } catch {
            onError?("Remote control daemon failed: \(error.localizedDescription)")
            Log.write("remote-control: listener failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        activePort = nil
        token = ""
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.count > self.maximumRequestBytes {
                self.sendError(413, "request too large", on: connection)
                return
            }
            if let request = HTTPRequest.parse(next) {
                Task { @MainActor [weak self] in
                    self?.route(request, on: connection)
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
    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "GET", request.path == "/" {
            send(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.webApp.utf8),
                on: connection
            )
            return
        }
        if request.method == "GET", request.path == "/health" {
            sendJSON(["status": "ok"], on: connection)
            return
        }
        guard request.path == "/api/v1/sessions"
                || request.path.hasPrefix("/api/v1/sessions/") else {
            sendError(404, "not found", on: connection)
            return
        }
        guard authorized(request.headers["authorization"]) else {
            sendError(401, "invalid pairing token", on: connection)
            return
        }
        guard let manager else {
            sendError(503, "session manager unavailable", on: connection)
            return
        }

        if request.path == "/api/v1/sessions" {
            switch request.method {
            case "GET":
                let sessions = manager.sessions
                    .filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false) }
                sendJSON(["sessions": sessions], on: connection)
            case "POST":
                let session = manager.newSession()
                sendJSON(["session": snapshot(session)], status: 201, on: connection)
            default:
                sendError(405, "method not allowed", on: connection)
            }
            return
        }

        let tail = String(request.path.dropFirst("/api/v1/sessions/".count))
        let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
        guard let rawID = parts.first,
              let id = UUID(uuidString: String(rawID)),
              let session = manager.sessions.first(where: { $0.id == id && !$0.isPrivate })
        else {
            sendError(404, "session not found", on: connection)
            return
        }

        if parts.count == 1, request.method == "GET" {
            sendJSON(["session": snapshot(session)], on: connection)
            return
        }
        guard request.method == "POST", parts.count == 2 else {
            sendError(405, "method not allowed", on: connection)
            return
        }

        switch parts[1] {
        case "messages":
            guard let body = request.json,
                  let text = body["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                sendError(400, "message text is required", on: connection)
                return
            }
            let mode = body["mode"] as? String ?? "queue"
            guard ["queue", "interrupt", "inject"].contains(mode) else {
                sendError(400, "mode must be queue, interrupt, or inject", on: connection)
                return
            }
            session.submitRemote(
                text,
                interrupt: mode == "interrupt",
                inject: mode == "inject"
            )
            sendJSON(["session": snapshot(session)], status: 202, on: connection)
        case "cancel":
            session.cancel()
            sendJSON(["session": snapshot(session)], on: connection)
        case "resume":
            guard session.canResume, !session.isStreaming else {
                sendError(409, "session is not resumable", on: connection)
                return
            }
            session.resumeInterrupted()
            sendJSON(["session": snapshot(session)], status: 202, on: connection)
        case "new-conversation":
            guard !session.isStreaming else {
                sendError(409, "stop the running session before resetting it", on: connection)
                return
            }
            session.newConversation()
            sendJSON(["session": snapshot(session)], on: connection)
        default:
            sendError(404, "action not found", on: connection)
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
        includeMessages: Bool = true
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.title,
            "workdir": session.workdir,
            "isStreaming": session.isStreaming,
            "canResume": session.canResume,
            "councilMode": session.councilMode,
            "queuedCount": session.queued.count,
        ]
        if let status = session.statusText { result["status"] = status }
        if includeMessages {
            result["messages"] = session.messages.map { message in
                var object: [String: Any] = [
                    "id": message.id.uuidString,
                    "role": message.role.rawValue,
                    "text": message.text,
                    "thinking": message.thinking,
                    "activities": message.activities.map(activitySnapshot),
                ]
                if let author = message.author { object["author"] = author }
                return object
            }
        }
        return result
    }

    private func activitySnapshot(_ activity: ToolActivity) -> [String: Any] {
        var object: [String: Any] = [
            "id": activity.id,
            "title": activity.title,
            "toolName": activity.toolName,
            "state": activityState(activity.state),
        ]
        if let input = activity.input { object["input"] = input }
        if let output = activity.output { object["output"] = output }
        return object
    }

    private func activityState(_ state: ToolActivityState) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        status: Int = 200,
        on connection: NWConnection
    ) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            sendError(500, "response serialization failed", on: connection)
            return
        }
        send(
            status: status,
            contentType: "application/json; charset=utf-8",
            body: data,
            on: connection
        )
    }

    private func sendError(_ status: Int, _ message: String, on connection: NWConnection) {
        sendJSON(["error": message], status: status, on: connection)
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        on connection: NWConnection
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
        Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? {
        guard !body.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
              )
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard requestParts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0 else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let target = String(requestParts[1])
        guard let components = URLComponents(string: target) else { return nil }
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: components.path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    static func needsMoreData(_ data: Data) -> Bool {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else { return true }
        guard let headerText = String(
            data: data[..<headerRange.lowerBound],
            encoding: .utf8
        ) else { return false }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let raw = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(raw), parsed >= 0 else { return false }
            contentLength = parsed
        }
        return data.count < headerRange.upperBound + contentLength
    }
}

private extension RemoteControlServer {
    static let webApp = """
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="dark"><title>Cantrip Remote</title>
    <style>
    *{box-sizing:border-box}body{margin:0;background:#101114;color:#eee;font:15px system-ui}
    header{position:sticky;top:0;background:#181a1f;padding:10px;display:flex;gap:8px;align-items:center;border-bottom:1px solid #333}
    button,select,input,textarea{font:inherit;color:inherit;background:#252830;border:1px solid #444;border-radius:9px;padding:9px}
    button{cursor:pointer}button.primary{background:#3267d6;border-color:#4c7bea}#sessions{display:flex;gap:7px;overflow:auto;padding:10px;border-bottom:1px solid #292b31}
    #sessions button.active{background:#365fba}.grow{flex:1}.muted{color:#9da3af;font-size:12px}
    #messages{padding:12px;display:flex;flex-direction:column;gap:10px;min-height:calc(100vh - 190px)}
    .message{max-width:88%;padding:11px;border-radius:13px;white-space:pre-wrap;overflow-wrap:anywhere;background:#24272e}
    .user{align-self:flex-end;background:#234d8d}.error{background:#682b32}.meta{font-size:11px;color:#aeb5c3;margin-bottom:5px}
    .activity{font-size:12px;color:#aeb5c3;margin-top:5px}.composer{position:sticky;bottom:0;background:#181a1f;padding:10px;display:flex;gap:7px;border-top:1px solid #333}
    textarea{resize:none;min-height:42px;max-height:120px}.hidden{display:none!important}#pair{max-width:430px;margin:20vh auto;padding:20px}
    </style></head><body>
    <section id="pair"><h2>Pair Cantrip Remote</h2><p class="muted">Paste the token copied from Cantrip settings. It stays in this browser only.</p>
    <input id="token" class="grow" type="password" placeholder="Pairing token"><button id="pairButton" class="primary">Connect</button><p id="pairError" class="muted"></p></section>
    <main id="app" class="hidden"><header><strong>Cantrip</strong><span id="status" class="muted grow"></span>
    <button id="newSession">New</button><button id="forget">Unpair</button></header><nav id="sessions"></nav><section id="messages"></section>
    <div class="composer"><select id="mode"><option value="queue">Queue</option><option value="interrupt">Redirect</option><option value="inject">Inject</option></select>
    <textarea id="draft" class="grow" placeholder="Message Cantrip"></textarea><button id="resume" class="hidden">Resume</button><button id="stop">Stop</button><button id="send" class="primary">Send</button></div></main>
    <script>
    const $=id=>document.getElementById(id);let token=localStorage.cantripToken||"",selected=null,timer=null;
    async function api(path,options={}){options.headers={...(options.headers||{}),Authorization:`Bearer ${token}`};if(options.body)options.headers["Content-Type"]="application/json";
      const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||`HTTP ${response.status}`);return data}
    function pair(show){$("pair").classList.toggle("hidden",!show);$("app").classList.toggle("hidden",show);if(show&&timer){clearInterval(timer);timer=null}}
    async function refresh(){try{const listed=await api("/api/v1/sessions");if(!selected||!listed.sessions.some(s=>s.id===selected))selected=listed.sessions[0]?.id||null;
      renderSessions(listed.sessions);if(selected){const data=await api(`/api/v1/sessions/${selected}`);render(data.session)}else render(null)}
      catch(error){$("status").textContent=error.message;if(error.message.includes("token"))pair(true)}}
    function renderSessions(items){const nav=$("sessions");nav.replaceChildren();for(const item of items){const button=document.createElement("button");button.textContent=item.title;
      button.className=item.id===selected?"active":"";button.onclick=()=>{selected=item.id;refresh()};nav.append(button)}}
    function render(session){const box=$("messages");box.replaceChildren();if(!session){box.textContent="No open sessions.";return}
      $("status").textContent=session.isStreaming?(session.status||"Working…"):`${session.queuedCount||0} queued`;$("resume").classList.toggle("hidden",!session.canResume);
      for(const message of session.messages){const row=document.createElement("article");row.className=`message ${message.role}`;
        const meta=document.createElement("div");meta.className="meta";meta.textContent=message.author||message.role;row.append(meta);
        const text=document.createElement("div");text.textContent=message.text;row.append(text);
        for(const activity of message.activities||[]){const a=document.createElement("div");a.className="activity";a.textContent=`${activity.state==="running"?"◌":"✓"} ${activity.toolName}: ${activity.title}`;row.append(a)}
        box.append(row)}window.scrollTo({top:document.body.scrollHeight})}
    async function action(name,body){if(!selected)return;await api(`/api/v1/sessions/${selected}/${name}`,{method:"POST",body:body?JSON.stringify(body):undefined});await refresh()}
    $("pairButton").onclick=async()=>{token=$("token").value.trim();try{await api("/api/v1/sessions");localStorage.cantripToken=token;pair(false);refresh();timer=setInterval(refresh,1500)}
      catch(error){$("pairError").textContent=error.message}};
    $("send").onclick=()=>{const text=$("draft").value.trim();if(text){$("draft").value="";action("messages",{text,mode:$("mode").value})}};
    $("draft").onkeydown=event=>{if(event.key==="Enter"&&!event.shiftKey){event.preventDefault();$("send").click()}};
    $("stop").onclick=()=>action("cancel");$("resume").onclick=()=>action("resume");$("newSession").onclick=async()=>{const data=await api("/api/v1/sessions",{method:"POST"});selected=data.session.id;refresh()};
    $("forget").onclick=()=>{localStorage.removeItem("cantripToken");token="";pair(true)};if(token){pair(false);refresh();timer=setInterval(refresh,1500)}else pair(true);
    </script></body></html>
    """
}
