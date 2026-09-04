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
    <html lang="en" data-cantrip-connected="false"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="dark light"><title>Cantrip Remote</title>
    <style>
    :root{color-scheme:light dark;--bg:#f0f0f2;--chrome:rgba(240,240,242,.92);--surface:rgba(0,0,0,.045);--surface-2:rgba(0,0,0,.075);--line:rgba(0,0,0,.12);--text:#202025;--secondary:#62626a;--tertiary:#8a8a92;--accent:#4169d8;--green:#28a745;--orange:#d97900;--red:#dc3545}
    @media(prefers-color-scheme:dark){:root{--bg:#24252a;--chrome:rgba(36,37,42,.92);--surface:rgba(255,255,255,.045);--surface-2:rgba(255,255,255,.09);--line:rgba(255,255,255,.11);--text:#f2f2f4;--secondary:#a8a8b0;--tertiary:#777780;--accent:#6b8cff;--green:#35c759;--orange:#ff9f0a;--red:#ff453a}}
    *{box-sizing:border-box}html,body{min-height:100%}html{background:var(--bg)}body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    button,select,input,textarea{font:inherit;color:inherit}button{cursor:pointer}.hidden{display:none!important}.grow{flex:1;min-width:0}.muted{color:var(--secondary);font-size:12px}
    #app{min-height:100vh}.workspace{position:sticky;top:0;z-index:4;background:var(--chrome);border-bottom:1px solid var(--line);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}
    .prompt-row{display:flex;align-items:center;gap:10px;padding:12px 16px 4px}.prompt-row textarea{flex:1;min-width:0;min-height:34px;max-height:104px;padding:2px 0;border:0;outline:0;background:transparent;resize:none;font-size:20px;font-weight:300;line-height:1.4}.prompt-row textarea::placeholder{color:var(--tertiary)}
    .tools{display:flex;align-items:center;gap:8px;min-height:32px;padding:2px 14px 8px}.tools-spacer{flex:1;min-width:8px}.connection{display:flex;align-items:center;gap:5px;color:var(--tertiary);font-size:11px}.connection-dot{width:6px;height:6px;border-radius:50%;background:var(--tertiary)}[data-cantrip-connected=true] .connection-dot{background:var(--green)}
    .control{min-height:27px;padding:4px 9px;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.control:hover{background:var(--surface-2)}.control.primary{border-color:var(--accent);background:var(--accent);color:white}.control:disabled{opacity:.45;cursor:default}.quiet{border:0;background:transparent;color:var(--secondary);font-size:12px}.quiet:hover{background:var(--surface)}
    .round{display:grid;place-items:center;flex:none;width:27px;height:27px;padding:0;border:0;border-radius:50%;background:var(--surface-2);font-size:17px;font-weight:600;line-height:1}.round:hover{filter:brightness(1.12)}.round.primary{background:var(--accent);color:white}.round.danger{color:var(--red);font-size:12px}
    #sessions{display:flex;gap:5px;min-width:0;overflow-x:auto;scrollbar-width:none}#sessions::-webkit-scrollbar{display:none}#sessions button{flex:none;max-width:190px;padding:4px 9px;border:0;border-radius:999px;background:transparent;color:var(--secondary);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}#sessions button:hover{background:var(--surface);color:var(--text)}#sessions button.active{background:var(--surface-2);color:var(--text)}
    select{height:27px;max-width:90px;padding:0 5px;border:0;border-radius:6px;outline:0;background:transparent;color:var(--secondary);font-size:12px}select:hover,select:focus{background:var(--surface)}
    #messages{width:100%;min-height:calc(100vh - 88px);margin:0;padding:16px;display:flex;flex-direction:column;gap:12px}
    .message{width:100%;overflow-wrap:anywhere}.message.user{color:var(--secondary);font-weight:600;line-height:1.45}.message.assistant{color:var(--text);line-height:1.55}.message.error{color:var(--orange);padding-left:21px;position:relative}.message.error:before{content:"!";position:absolute;left:3px;font-weight:800}.author{display:block;margin-bottom:5px;color:var(--tertiary);font-size:11px;font-weight:600}
    .prose{white-space:pre-wrap}.prose p{margin:0 0 9px}.prose p:last-child{margin-bottom:0}.prose h1,.prose h2,.prose h3{margin:13px 0 7px;line-height:1.25}.prose h1{font-size:19px}.prose h2{font-size:17px}.prose h3{font-size:15px}.prose ul,.prose ol{margin:5px 0 9px;padding-left:22px}.prose li{margin:3px 0}.prose blockquote{margin:7px 0;padding-left:10px;border-left:2px solid rgba(107,140,255,.5);color:var(--secondary)}.prose code{padding:1px 4px;border-radius:4px;background:var(--surface-2);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}.prose pre{margin:8px 0;padding:10px 11px;border:1px solid var(--line);border-radius:7px;background:var(--surface);overflow:auto}.prose pre code{padding:0;background:transparent;white-space:pre}
    details{min-width:0}summary{list-style:none;cursor:pointer}summary::-webkit-details-marker{display:none}.disclosure{margin-top:7px;color:var(--secondary)}.disclosure>summary{display:flex;align-items:center;gap:7px;width:max-content;max-width:100%;font-size:12px}.disclosure>summary:before{content:"›";width:12px;color:var(--tertiary);font-size:17px;line-height:12px;transition:transform .12s}.disclosure[open]>summary:before{transform:rotate(90deg)}.disclosure-body{margin:7px 0 2px 18px;padding-left:10px;border-left:2px solid rgba(107,140,255,.22)}
    .steps{margin-top:8px}.status-icon{display:inline-grid;place-items:center;width:14px;height:14px;border-radius:50%;font-size:10px;font-weight:800;color:var(--tertiary)}.status-icon.succeeded{color:var(--green)}.status-icon.failed{color:var(--red)}.status-icon.cancelled{color:var(--secondary)}.status-icon.running{color:var(--accent);animation:pulse 1.1s ease-in-out infinite}@keyframes pulse{50%{opacity:.35}}
    .step{margin:5px 0;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.step>summary,.step-static{display:flex;align-items:center;gap:7px;padding:7px 9px;font-size:12px}.step>summary:after{content:"›";margin-left:auto;color:var(--tertiary);font-size:16px;transition:transform .12s}.step[open]>summary:after{transform:rotate(90deg)}.step-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tool-name{margin-left:auto;color:var(--tertiary);font:10px ui-monospace,SFMono-Regular,Menlo,monospace}.step>summary .tool-name{margin-left:8px}.step-details{display:grid;gap:8px;padding:0 9px 9px 30px}.detail-label{margin-bottom:4px;color:var(--secondary);font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}.step-details pre{max-height:180px;margin:0;padding:8px;border-radius:5px;background:var(--surface);overflow:auto;white-space:pre-wrap;word-break:break-word;color:var(--secondary);font:11px ui-monospace,SFMono-Regular,Menlo,monospace}
    .run-status{display:flex;align-items:center;gap:7px;color:var(--secondary);font-size:13px}.spinner{width:12px;height:12px;border:1.5px solid rgba(255,255,255,.2);border-top-color:var(--secondary);border-radius:50%;animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.empty{margin:auto;color:var(--tertiary)}
    #pair{width:min(calc(100% - 32px),430px);margin:18vh auto 0;padding:22px;border:1px solid var(--line);border-radius:14px;background:var(--surface);box-shadow:0 18px 50px rgba(0,0,0,.2)}#pair h2{margin:0 0 7px;font-size:18px}#pair p{line-height:1.45}#pairControls{display:flex;gap:7px;margin-top:15px}#pair input{min-width:0;padding:9px 10px;border:1px solid var(--line);border-radius:8px;outline:0;background:var(--surface)}#pair input:focus{border-color:var(--accent)}
    @media(max-width:620px){.prompt-row{padding-inline:12px}.tools{padding-inline:10px}.connection-label{display:none}#sessions button{max-width:120px}#messages{padding:14px 12px 22px}}
    </style></head><body>
    <section id="pair"><h2>Pair Cantrip Remote</h2><p class="muted">Paste the token from Cantrip Settings. It stays in this browser only.</p>
    <div id="pairControls"><input id="token" class="grow" type="password" placeholder="Pairing token" autocomplete="off"><button id="pairButton" class="control primary">Connect</button></div><p id="pairError" class="muted"></p></section>
    <main id="app" class="hidden"><header class="workspace">
    <div class="prompt-row"><textarea id="draft" placeholder="How can I help you?"></textarea><button id="resume" class="control quiet hidden">Resume</button><button id="stop" class="round danger hidden" title="Stop" aria-label="Stop">■</button><button id="send" class="round primary" title="Send" aria-label="Send">↑</button></div>
    <div class="tools"><nav id="sessions"></nav><button id="newSession" class="round" title="New remote session" aria-label="New remote session">+</button><span class="tools-spacer"></span>
    <select id="mode" aria-label="Delivery mode"><option value="queue">Queue</option><option value="interrupt">Redirect</option><option value="inject">Inject</option></select>
    <span class="connection"><span class="connection-dot"></span><span class="connection-label">Connected</span></span><button id="forget" class="control quiet">Unpair</button></div></header>
    <section id="messages"></section></main>
    <script>
    const $=id=>document.getElementById(id);let token=localStorage.cantripToken||"",selected=null,timer=null,renderedSession=null,renderedPayload="",followOutput=true,suppressScroll=false;const expanded=new Set();
    function connection(active){document.documentElement.dataset.cantripConnected=active?"true":"false";const label=document.querySelector(".connection-label");if(label)label.textContent=active?"Connected":"Reconnecting…"}
    function atBottom(){const root=document.scrollingElement||document.documentElement;return root.scrollHeight-root.clientHeight-root.scrollTop<=4}
    addEventListener("wheel",event=>{if(event.deltaY<0)followOutput=false},{passive:true});
    addEventListener("scroll",()=>{if(!suppressScroll)followOutput=atBottom()},{passive:true});
    async function api(path,options={}){options.headers={...(options.headers||{}),Authorization:`Bearer ${token}`};if(options.body)options.headers["Content-Type"]="application/json";
      const response=await fetch(path,options);const data=await response.json();if(!response.ok)throw new Error(data.error||`HTTP ${response.status}`);return data}
    function pair(show){$("pair").classList.toggle("hidden",!show);$("app").classList.toggle("hidden",show);if(show){connection(false);if(timer){clearInterval(timer);timer=null}}}
    async function refresh(){try{const listed=await api("/api/v1/sessions");if(!selected||!listed.sessions.some(s=>s.id===selected))selected=listed.sessions[0]?.id||null;
      renderSessions(listed.sessions);if(selected){const data=await api(`/api/v1/sessions/${selected}`);render(data.session)}else render(null);connection(true)}
      catch(error){connection(false);if(error.message.includes("token"))pair(true)}}
    function renderSessions(items){const nav=$("sessions");nav.replaceChildren();for(const item of items){const button=document.createElement("button");button.textContent=item.title;
      button.className=item.id===selected?"active":"";button.onclick=()=>{selected=item.id;renderedPayload="";refresh()};nav.append(button)}}
    function appendInline(parent,text){let cursor=0;while(cursor<text.length){const code=text.indexOf("`",cursor),bold=text.indexOf("**",cursor);let start=-1,marker="",tag="";
      if(code>=0&&(bold<0||code<bold)){start=code;marker="`";tag="code"}else if(bold>=0){start=bold;marker="**";tag="strong"}
      if(start<0){parent.append(document.createTextNode(text.slice(cursor)));break}if(start>cursor)parent.append(document.createTextNode(text.slice(cursor,start)));
      const end=text.indexOf(marker,start+marker.length);if(end<0){parent.append(document.createTextNode(text.slice(start)));break}
      const node=document.createElement(tag);node.textContent=text.slice(start+marker.length,end);parent.append(node);cursor=end+marker.length}}
    function numberedLine(line){const dot=line.indexOf(". ");if(dot<1)return null;const value=Number(line.slice(0,dot));return Number.isInteger(value)&&value>0?line.slice(dot+2):null}
    function appendProse(parent,source){const prose=document.createElement("div");prose.className="prose";const chunks=source.split("```");
      for(let chunkIndex=0;chunkIndex<chunks.length;chunkIndex++){const chunk=chunks[chunkIndex];if(chunkIndex%2){const firstBreak=chunk.indexOf("\\n"),code=document.createElement("code"),pre=document.createElement("pre");code.textContent=firstBreak>=0?chunk.slice(firstBreak+1):chunk;pre.append(code);prose.append(pre);continue}
        const lines=chunk.split("\\n");let paragraph=[];const flush=()=>{if(!paragraph.length)return;const p=document.createElement("p");paragraph.forEach((line,index)=>{if(index)p.append(document.createElement("br"));appendInline(p,line)});prose.append(p);paragraph=[]};
        for(let index=0;index<lines.length;){const line=lines[index];if(!line.trim()){flush();index++;continue}
          const heading=line.startsWith("### ")?3:line.startsWith("## ")?2:line.startsWith("# ")?1:0;if(heading){flush();const h=document.createElement(`h${heading}`);appendInline(h,line.slice(heading+1));prose.append(h);index++;continue}
          if(line.startsWith("- ")||line.startsWith("* ")){flush();const list=document.createElement("ul");while(index<lines.length&&(lines[index].startsWith("- ")||lines[index].startsWith("* "))){const li=document.createElement("li");appendInline(li,lines[index].slice(2));list.append(li);index++}prose.append(list);continue}
          if(numberedLine(line)!==null){flush();const list=document.createElement("ol");while(index<lines.length&&numberedLine(lines[index])!==null){const li=document.createElement("li");appendInline(li,numberedLine(lines[index]));list.append(li);index++}prose.append(list);continue}
          if(line.startsWith("> ")){flush();const quote=document.createElement("blockquote");appendInline(quote,line.slice(2));prose.append(quote);index++;continue}
          paragraph.push(line);index++}flush()}parent.append(prose)}
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
    function render(session){const box=$("messages"),sessionID=session?.id||null,payload=JSON.stringify(session);if(sessionID===renderedSession&&payload===renderedPayload)return;
      const root=document.scrollingElement||document.documentElement,sameSession=sessionID===renderedSession,shouldFollow=followOutput||!sameSession,previousTop=root.scrollTop;renderedSession=sessionID;renderedPayload=payload;suppressScroll=true;box.replaceChildren();$("resume").classList.toggle("hidden",!session?.canResume);$("stop").classList.toggle("hidden",!session?.isStreaming);
      if(!session){const empty=document.createElement("div");empty.className="empty";empty.textContent="No open sessions.";box.append(empty)}
      else{for(const message of session.messages){const activities=message.activities||[];if(!message.text&&!message.thinking&&!activities.length)continue;const row=document.createElement("article");row.className=`message ${message.role}`;
          if(message.author){const author=document.createElement("span");author.className="author";author.textContent=message.author;row.append(author)}
          appendThinking(row,message.thinking,message.id);if(message.text)appendProse(row,message.text);appendActivities(row,activities,message.id);box.append(row)}
        if(session.isStreaming||session.queuedCount){const status=document.createElement("div");status.className="run-status";if(session.isStreaming){const spinner=document.createElement("span");spinner.className="spinner";status.append(spinner)}const label=document.createElement("span");label.textContent=session.isStreaming?(session.status||"Working…"):`${session.queuedCount} queued`;status.append(label);box.append(status)}}
      requestAnimationFrame(()=>{root.scrollTop=shouldFollow?root.scrollHeight:Math.min(previousTop,Math.max(0,root.scrollHeight-root.clientHeight));followOutput=shouldFollow;suppressScroll=false})}
    async function action(name,body){if(!selected)return;await api(`/api/v1/sessions/${selected}/${name}`,{method:"POST",body:body?JSON.stringify(body):undefined});await refresh()}
    $("pairButton").onclick=async()=>{token=$("token").value.trim();try{await api("/api/v1/sessions");localStorage.cantripToken=token;connection(true);pair(false);refresh();timer=setInterval(refresh,1500)}
      catch(error){$("pairError").textContent=error.message}};
    $("send").onclick=()=>{const text=$("draft").value.trim();if(text){$("draft").value="";action("messages",{text,mode:$("mode").value})}};
    $("draft").onkeydown=event=>{if(event.key==="Enter"&&!event.shiftKey){event.preventDefault();$("send").click()}};
    $("stop").onclick=()=>action("cancel");$("resume").onclick=()=>action("resume");$("newSession").onclick=async()=>{const data=await api("/api/v1/sessions",{method:"POST"});selected=data.session.id;refresh()};
    $("forget").onclick=()=>{localStorage.removeItem("cantripToken");token="";connection(false);pair(true)};if(token){pair(false);refresh();timer=setInterval(refresh,1500)}else pair(true);
    </script></body></html>
    """
}
