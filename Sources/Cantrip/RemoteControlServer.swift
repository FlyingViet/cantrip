import Foundation
import Network

/// Authenticated HTTP control plane for the live sessions owned by the app.
/// Loopback HTTP remains available for Tailscale Serve. A separate Bonjour
/// listener uses forward-secret TLS with the pairing token as a PSK for LAN use.
final class RemoteControlServer {
    var onError: ((String?) -> Void)?

    private weak var manager: SessionManager?
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-control")
    private var listener: NWListener?
    private var lanListener: NWListener?
    private var activePort: Int?
    private var token = ""
    private let maximumRequestBytes = RemoteImageAttachments.maximumRequestBytes

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
              let sessionIndex = manager.sessions.firstIndex(where: {
                  $0.id == id && !$0.isPrivate
              })
        else {
            sendError(404, "session not found", on: connection)
            return
        }
        let session = manager.sessions[sessionIndex]

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
        case "close":
            manager.close(sessionIndex)
            let replacementIndex = min(sessionIndex, manager.sessions.count - 1)
            sendJSON(["session": snapshot(manager.sessions[replacementIndex])], on: connection)
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
            "supportsImageAttachments": session.supportsRemoteImages,
            "supportsAutoDelivery": true,
        ]
        if let status = session.statusText { result["status"] = status }
        if let status = session.deliveryStatus { result["deliveryStatus"] = status }
        if includeMessages {
            result["queued"] = session.queued.map { prompt in
                [
                    "id": prompt.id.uuidString,
                    "text": prompt.text,
                ]
            }
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
        Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' https: data:; frame-ancestors 'none'\r
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
    @media(max-width:620px){.prompt-row{padding-inline:12px}.tools{padding-inline:10px}.connection-label{display:none}.session-tab{max-width:145px}.session-select{max-width:115px}#messages{padding:14px 12px 22px}}
    </style></head><body>
    <section id="pair"><h2>Pair Cantrip Remote</h2><p class="muted">Paste the token from Cantrip Settings. It stays in this browser only.</p>
    <div id="pairControls"><input id="token" class="grow" type="password" placeholder="Pairing token" autocomplete="off"><button id="pairButton" class="control primary">Connect</button></div><p id="pairError" class="muted"></p></section>
    <main id="app" class="hidden"><header class="workspace">
    <div class="prompt-row"><input id="draft" type="text" placeholder="How can I help you?" autocomplete="off"><button id="resume" class="control quiet hidden">Resume</button><button id="stop" class="round danger hidden" title="Stop" aria-label="Stop">■</button><button id="send" class="round primary" title="Send" aria-label="Send">↑</button></div>
    <div class="tools"><nav id="sessions"></nav><button id="newSession" class="round" title="New remote session" aria-label="New remote session">+</button><span class="tools-spacer"></span>
    <select id="mode" aria-label="Delivery override"><option value="auto">Auto</option><option value="queue">Queue</option><option value="interrupt">Redirect</option><option value="inject">Inject</option></select>
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
    function renderSessions(items){const nav=$("sessions");nav.replaceChildren();for(const item of items){const tab=document.createElement("span");tab.className=`session-tab ${item.id===selected?"active":""}`;
      const button=document.createElement("button");button.className="session-select";button.textContent=item.title;button.title=item.title;button.onclick=()=>{selected=item.id;renderedPayload="";refresh()};
      const close=document.createElement("button");close.className="session-close";close.textContent="×";close.title=`Close ${item.title}`;close.setAttribute("aria-label",`Close ${item.title}`);close.onclick=event=>{event.stopPropagation();closeSession(item.id)};tab.append(button,close);nav.append(tab)}}
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
    function render(session){const box=$("messages"),sessionID=session?.id||null,payload=JSON.stringify(session);if(sessionID===renderedSession&&payload===renderedPayload)return;
      const root=document.scrollingElement||document.documentElement,sameSession=sessionID===renderedSession,shouldFollow=followOutput||!sameSession,previousTop=root.scrollTop;renderedSession=sessionID;renderedPayload=payload;suppressScroll=true;box.replaceChildren();$("resume").classList.toggle("hidden",!session?.canResume);$("stop").classList.toggle("hidden",!session?.isStreaming);
      if(!session){const empty=document.createElement("div");empty.className="empty";empty.textContent="No open sessions.";box.append(empty)}
      else{for(const message of session.messages){const activities=message.activities||[];if(!message.text&&!message.thinking&&!activities.length)continue;const row=document.createElement("article");row.className=`message ${message.role}`;
          if(message.author){const author=document.createElement("span");author.className="author";author.textContent=message.author;row.append(author)}
          appendThinking(row,message.thinking,message.id);if(message.text)appendProse(row,message.text);appendActivities(row,activities,message.id);box.append(row)}
        if(session.deliveryStatus){const note=document.createElement("div");note.className="run-status";note.textContent=session.deliveryStatus;box.append(note)}
        if(session.isStreaming||session.queuedCount){const status=document.createElement("div");status.className="run-status";if(session.isStreaming){const spinner=document.createElement("span");spinner.className="spinner";status.append(spinner)}const label=document.createElement("span");label.textContent=session.isStreaming?(session.status||"Working…"):`${session.queuedCount} queued`;status.append(label);box.append(status)}}
      requestAnimationFrame(()=>{root.scrollTop=shouldFollow?root.scrollHeight:Math.min(previousTop,Math.max(0,root.scrollHeight-root.clientHeight));followOutput=shouldFollow;suppressScroll=false})}
    async function action(name,body){if(!selected)return;await api(`/api/v1/sessions/${selected}/${name}`,{method:"POST",body:body?JSON.stringify(body):undefined});await refresh()}
    async function closeSession(id){try{const data=await api(`/api/v1/sessions/${id}/close`,{method:"POST"});if(selected===id)selected=data.session.id;renderedPayload="";await refresh()}
      catch(error){connection(false);const label=document.querySelector(".connection-label");if(label)label.textContent=`Close failed: ${error.message}`}}
    $("pairButton").onclick=async()=>{token=$("token").value.trim();try{await api("/api/v1/sessions");localStorage.cantripToken=token;connection(true);pair(false);refresh();timer=setInterval(refresh,1500)}
      catch(error){$("pairError").textContent=error.message}};
    $("send").onclick=async()=>{const text=$("draft").value.trim();if(!text)return;$("send").disabled=true;try{await action("messages",{text,mode:$("mode").value});if($("draft").value.trim()===text)$("draft").value="";$("mode").value="auto"}catch(error){const label=document.querySelector(".connection-label");if(label)label.textContent=`Send failed: ${error.message}. Check the session before resending.`}finally{$("send").disabled=false}};
    $("draft").onkeydown=event=>{if(event.key==="Enter"&&!event.shiftKey){event.preventDefault();$("send").click()}};
    $("stop").onclick=()=>action("cancel");$("resume").onclick=()=>action("resume");$("newSession").onclick=async()=>{const data=await api("/api/v1/sessions",{method:"POST"});selected=data.session.id;refresh()};
    $("forget").onclick=()=>{localStorage.removeItem("cantripToken");token="";connection(false);pair(true);window.webkit?.messageHandlers?.cantripRemoteUnpair?.postMessage(null)};if(token){pair(false);refresh();timer=setInterval(refresh,1500)}else pair(true);
    </script></body></html>
    """
}
