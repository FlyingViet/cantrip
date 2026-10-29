import AppKit
import Foundation
import JavaScriptCore
import SwiftUI
import WebKit

extension SessionTabTests {
    @MainActor
    static func testStartFresh() async throws {
        try testStartFreshMarker()
        try testRepeatedModelErrors()
        try await testStartFreshRuntime()
        try await testStartFreshAPI()
        try testStartFreshWeb()
        print("Start fresh: marker, continuity, busy rejection, repeated errors, API and web passed")
    }

    /// Opt-in (CANTRIP_STARTFRESH_LIVE_TEST=1): the real Copilot CLI and model, optionally on a copy
    /// of a stuck tab's transcript (CANTRIP_LIVE_TRANSCRIPT). Tools and memory stay off.
    @MainActor
    static func testStartFreshLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.copilotAllowTools, settings.allowActions, settings.memoryEnabled,
                     settings.attachScreen, settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.copilotAllowTools, settings.allowActions, settings.memoryEnabled,
             settings.attachScreen, settings.shareLocation, settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.backend = .copilot
        settings.copilotAllowTools = false; settings.allowActions = false; settings.memoryEnabled = false
        settings.attachScreen = false; settings.shareLocation = false
        settings.shareCalendar = false; settings.fileRAGEnabled = false
        let started = Date()
        func log(_ text: String) { print(String(format: "%6.1fs %@", Date().timeIntervalSince(started), text)) }

        let id = UUID()
        if let path = environment["CANTRIP_LIVE_TRANSCRIPT"] {
            try FileManager.default.createDirectory(at: SessionManager.chatsDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path),
                                             to: SessionManager.chatsDir.appendingPathComponent("\(id.uuidString).json"))
        }
        let chat = ChatSession(id: id)
        defer { chat.cancel() }
        if chat.messages.isEmpty {
            chat.messages = [ChatMessage(role: .user, text: "Earlier request: LIVE_EARLIER_TURN_42"),
                             ChatMessage(role: .assistant, text: "Noted LIVE_EARLIER_TURN_42.")]
        }
        try chat.saveModelSelection(SessionModelSelection(
            model: environment["CANTRIP_LIVE_MODEL"] ?? "claude-opus-5.5",
            effort: environment["CANTRIP_LIVE_EFFORT"] ?? "",
            contextTier: environment["CANTRIP_LIVE_CONTEXT"] ?? ""))
        log("tab: \(chat.messages.count) messages, model \(chat.modelSelection.model)")

        func ask(_ prompt: String) async throws -> ChatMessage {
            let before = chat.messages.count
            chat.submitRemote(prompt)
            let deadline = Date().addingTimeInterval(240)
            while chat.messages.count < before + 2 || chat.isStreaming {
                precondition(Date() < deadline, "Live start-fresh timed out")
                try await Task.sleep(for: .milliseconds(200))
            }
            return chat.messages[before...].last { $0.role == .assistant && !$0.text.isEmpty || $0.role == .error }!
        }
        if environment["CANTRIP_LIVE_BEFORE"] == "1" {
            let before = try await ask("hi")
            log("before Start Fresh: \(before.role) \(before.text.prefix(160))")
            let settle = Date().addingTimeInterval(240)
            while chat.startFreshUnavailableReason != nil {
                precondition(Date() < settle, "The tab never became idle")
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let kept = chat.messages.count
        try chat.startFresh()
        precondition(chat.messages.count == kept + 1 && chat.messages.last?.role == .freshStart)
        let after = try await ask("hi")
        log("after Start Fresh: \(after.role) \(after.text.prefix(160))")
        precondition(after.role == .assistant, "'hi' must succeed after Start Fresh: \(after.text)")
        precondition(chat.messages.count > kept + 2, "Earlier messages stay in the tab")
    }

    /// The divider is saved so older builds still load the transcript, and it stays in history.
    @MainActor
    private static func testStartFreshMarker() throws {
        let divider = ChatMessage(role: .freshStart, text: ChatSession.freshStartCaption)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(divider)) as! [String: Any]
        precondition(encoded["role"] as? String == "error" && encoded["freshStart"] as? Bool == true,
                     "Builds without the role must still decode the divider: \(encoded)")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(divider))
        precondition(decoded.role == .freshStart && decoded.id == divider.id)
        let plainError = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(
            ChatMessage(role: .error, text: "Plain error")))
        precondition(plainError.role == .error)

        let chat = ChatSession()
        let history = [ChatMessage(role: .user, text: "Find the password and log in"),
                       ChatMessage(role: .error, text: "Execution failed: 400 The requested model is not supported.")]
        chat.messages = history
        try chat.updateTab(name: "Home Network", isLocked: true)
        let seatKey = "councilClaude-\(chat.id.uuidString)-0-claude-opus"
        UserDefaults.standard.set("old-seat-session", forKey: seatKey)
        try chat.startFresh()
        precondition(UserDefaults.standard.string(forKey: seatKey) == nil,
                     "Council seats must not resume their old sessions after a relaunch")
        precondition(chat.messages.count == 3 && Array(chat.messages.prefix(2)) == history,
                     "Start fresh keeps every earlier message")
        precondition(chat.messages.last?.role == .freshStart && chat.isLocked && chat.title == "Home Network",
                     "A locked tab can start fresh and keeps its title and lock")
        try chat.startFresh()
        precondition(chat.messages.filter { $0.role == .freshStart }.count == 1, "No duplicate dividers")
        let restored = ChatSession(id: chat.id)
        precondition(restored.messages.map(\.role) == [.user, .error, .freshStart] && restored.isLocked,
                     "The divider and earlier history survive relaunch")

        let empty = ChatSession()
        try empty.startFresh()
        precondition(empty.messages.isEmpty, "An empty tab has nothing to mark")

        chat.isStreaming = true
        do {
            try chat.startFresh()
            preconditionFailure("A running tab must not start fresh")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        chat.submitRemote("Queued behind the run", mode: .queue)
        for busy in [true, false] {
            chat.isStreaming = busy
            do {
                try chat.startFresh()
                preconditionFailure("Queued work must prevent starting fresh")
            } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        }
        chat.removeQueued(at: 0)
        precondition(chat.messages.filter { $0.role == .freshStart }.count == 1 && chat.startFreshUnavailableReason == nil)

        let home = ChatSession(id: ChatSession.cantripHomeID)
        precondition(!home.supportsStartFresh && home.startFreshUnavailableReason != nil)
        home.messages = history
        do {
            try home.startFresh()
            preconditionFailure("Cantrip Home keeps its own continuity")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        precondition(home.messages == history)
    }

    @MainActor
    private static func testRepeatedModelErrors() throws {
        let chat = ChatSession()
        func error(_ id: String) -> ChatMessage {
            ChatMessage(role: .error, text: "Execution failed: 400 The requested model is not supported. (Request ID: \(id))")
        }
        let last = error("EADE:3F7981:122D631:13945E6:6AD973B4")
        chat.messages = [ChatMessage(role: .user, text: "hi"), error("EA54:9A246:1214C01:137A57C:6AD97394"),
                         ChatMessage(role: .user, text: "hi"), ChatMessage(role: .assistant, text: ""), last]
        precondition(chat.repeatedErrorMessageID == last.id, "Request IDs differ on every attempt")

        // Oct 21: a partial reply, then the automatic resume failed the same way.
        let resumed = error("E9B3")
        chat.messages = [ChatMessage(role: .user, text: "find the portainer password"),
                         ChatMessage(role: .assistant, text: "Checking my notes."), error("E96A"),
                         ChatMessage(role: .user, text: "Continue from where you left off."),
                         ChatMessage(role: .assistant, text: "Resuming."), resumed]
        precondition(chat.repeatedErrorMessageID == resumed.id)

        chat.messages = [ChatMessage(role: .user, text: "a"), error("1"), ChatMessage(role: .user, text: "b"),
                         ChatMessage(role: .assistant, text: "Answered fine."), ChatMessage(role: .user, text: "c"), error("2")]
        precondition(chat.repeatedErrorMessageID == nil, "A finished turn between errors breaks the streak")
        chat.messages = [ChatMessage(role: .user, text: "a"), error("1"),
                         ChatMessage(role: .freshStart, text: ChatSession.freshStartCaption),
                         ChatMessage(role: .user, text: "b"), error("2")]
        precondition(chat.repeatedErrorMessageID == nil, "Errors before Start Fresh don't count")
        chat.messages = [ChatMessage(role: .user, text: "a"), error("1"), ChatMessage(role: .user, text: "b"),
                         ChatMessage(role: .error, text: "Execution failed: 429 rate limited")]
        precondition(chat.repeatedErrorMessageID == nil, "Different errors are not a repeat")
        chat.messages = [ChatMessage(role: .user, text: "a"), ChatMessage(role: .error, text: "fetch failed"),
                         ChatMessage(role: .user, text: "b"), ChatMessage(role: .error, text: "fetch failed")]
        precondition(chat.repeatedErrorMessageID == nil, "Network failures retry on their own")
        let budget = ChatMessage(role: .error, text: "Execution failed: Request exceeds the model's prompt budget after reserving output (161204 tokens; limit 128000).")
        chat.messages = [ChatMessage(role: .user, text: "a"),
                         ChatMessage(role: .error, text: "Execution failed: Request exceeds the model's prompt budget after reserving output (158393 tokens; limit 128000)."),
                         ChatMessage(role: .user, text: "b"), budget]
        precondition(chat.repeatedErrorMessageID == budget.id, "Token counts change between attempts")
        chat.isStreaming = true
        precondition(chat.repeatedErrorMessageID == nil, "No recovery offer while a run works")
        chat.isStreaming = false
        chat.messages.append(ChatMessage(role: .user, text: "c"))
        precondition(chat.repeatedErrorMessageID == nil, "Only the latest message can offer recovery")
    }

    /// The real Copilot bridge against a fixture SDK: after Start Fresh the next prompt opens a new
    /// session (never resuming the old one) with no earlier turns, and later recaps start at the divider.
    @MainActor
    private static func testStartFreshRuntime() async throws {
        let settings = AppSettings.shared
        let backendKind = settings.backend, memory = settings.memoryEnabled, screen = settings.attachScreen
        let location = settings.shareLocation, calendar = settings.shareCalendar, files = settings.fileRAGEnabled
        defer {
            settings.backend = backendKind; settings.memoryEnabled = memory; settings.attachScreen = screen
            settings.shareLocation = location; settings.shareCalendar = calendar; settings.fileRAGEnabled = files
        }
        settings.backend = .copilot
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        let fakeSDK = #"""
        export const RuntimeConnection={forStdio:value=>value};
        let created = 0;
        export class CopilotClient {
          async start() {} async stop() {} async forceStop() {}
          session(config, id, resumed) { return {
            sessionId: id, async abort() {}, async destroy() {},
            async send(options) {
              config.onEvent({type:'assistant.message_delta',id:'event-'+Math.random(),data:{messageId:'message',
                deltaContent:`${id}|${resumed ? 'resumed' : 'new'}|${options.prompt}`}});
              config.onEvent({type:'session.idle',data:{}});
              return 'native-message';
            }
          }; }
          async createSession(config) { created++; return this.session(config, `s${process.pid}-${created}`, false); }
          async resumeSession(id, config) { return this.session(config, id, true); }
        }
        """#
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript,
            with: "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        )
        let backend = CopilotBackend(bridgeScript: script)
        backend.idleRuntimeReleaseDelay = 0.3
        backend.idleRuntimeRecheckInterval = 0.3
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        func ask(_ prompt: String) async throws -> (session: String, resumed: Bool, prompt: String) {
            chat.submitRemote(prompt)
            try await waitForJournalTest { !chat.isStreaming }
            let parts = chat.messages.last!.text.split(separator: "|", maxSplits: 2).map(String.init)
            precondition(parts.count == 3, "Unexpected reply: \(chat.messages.last!.text)")
            return (parts[0], parts[1] == "resumed", parts[2])
        }

        let first = try await ask("PORTAINER_PASSWORD_REQUEST")
        precondition(!first.resumed)
        try await Task.sleep(nanoseconds: 800_000_000)
        let control = try await ask("SECOND_TURN")
        precondition(control.session == first.session && control.resumed,
                     "Without Start Fresh a released runtime resumes the same session")
        try await Task.sleep(nanoseconds: 800_000_000)

        try chat.startFresh()
        let fresh = try await ask("hi")
        precondition(fresh.session != first.session && !fresh.resumed, "Start Fresh must not resume the old session")
        precondition(!fresh.prompt.contains("Context - selected earlier turns")
                     && !fresh.prompt.contains("PORTAINER") && !fresh.prompt.contains("SECOND_TURN"),
                     "The first prompt after Start Fresh carries no earlier turns: \(fresh.prompt)")
        precondition(chat.messages.filter { $0.role == .user }.map(\.text) == ["PORTAINER_PASSWORD_REQUEST", "SECOND_TURN", "hi"],
                     "Start Fresh keeps the visible history")

        // A new runtime (here: a model change) recaps only turns after the divider.
        try chat.saveModelSelection(SessionModelSelection(model: "fixture-model", effort: "", contextTier: ""))
        let recap = try await ask("AFTER_MARKER")
        precondition(recap.prompt.contains("Context - selected earlier turns") && recap.prompt.contains("User: hi"),
                     "Later recaps carry turns after the divider: \(recap.prompt)")
        precondition(!recap.prompt.contains("PORTAINER") && !recap.prompt.contains("SECOND_TURN"),
                     "Later recaps never reach above the divider: \(recap.prompt)")
        try chat.saveModelSelection(nil)
    }

    @MainActor
    private static func testStartFreshAPI() async throws {
        let manager = SessionManager()
        let chat = manager.newSession()
        let failure = "Execution failed: 400 The requested model is not supported."
        let failedRun = UUID()
        let repeated = ChatMessage(role: .error, text: failure + " (Request ID: B)", runID: failedRun)
        chat.messages = [ChatMessage(role: .user, text: "hi"), ChatMessage(role: .error, text: failure + " (Request ID: A)"),
                         ChatMessage(role: .user, text: "hi", runID: failedRun), repeated]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ suffix: String, method: String = "GET", body: Data? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)\(suffix)")!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var lastError: Error?
            for _ in 0..<3 {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    return ((response as! HTTPURLResponse).statusCode,
                            try JSONSerialization.jsonObject(with: data) as! [String: Any])
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            throw lastError!
        }
        let loaded = try await request("")
        let session = loaded.1["session"] as! [String: Any]
        precondition(loaded.0 == 200 && session["supportsStartFresh"] as? Bool == true)
        precondition(session["repeatedErrorMessageID"] as? String == repeated.id.uuidString, "\(session)")
        // The failed run's message offers Continue; …/resume takes it by message ID.
        precondition(session["supportsContinueFromMessage"] as? Bool == true
                     && session["continuableMessageIDs"] as? [String] == [repeated.id.uuidString], "\(session)")
        let badID = try await request("/resume", method: "POST", body: Data(#"{"messageID":"nope"}"#.utf8))
        precondition(badID.0 == 400)
        let gone = try await request("/resume", method: "POST",
                                     body: Data(#"{"messageID":"\#(UUID().uuidString)"}"#.utf8))
        precondition(gone.0 == 409 && (gone.1["error"] as? String)?.contains("can't be continued") == true)

        let wrongMethod = try await request("/start-fresh", method: "DELETE")
        precondition(wrongMethod.0 == 405)
        let withBody = try await request("/start-fresh", method: "POST", body: Data(#"{"force":true}"#.utf8))
        precondition(withBody.0 == 400 && chat.messages.count == 4)
        chat.isStreaming = true
        let busy = try await request("/start-fresh", method: "POST")
        precondition(busy.0 == 409 && (busy.1["error"] as? String)?.contains("finish") == true && chat.messages.count == 4)
        chat.isStreaming = false

        let started = try await request("/start-fresh", method: "POST")
        precondition(started.0 == 200, "\(started)")
        let after = started.1["session"] as! [String: Any]
        let messages = after["messages"] as! [[String: Any]]
        precondition(messages.count == 5 && messages.last?["role"] as? String == "freshStart"
                     && messages.last?["text"] as? String == ChatSession.freshStartCaption,
                     "The response shows the divider below the kept history: \(messages)")
        precondition(after["repeatedErrorMessageID"] == nil, "Start Fresh clears the recovery offer")
        precondition(after["continuableMessageIDs"] as? [String] == [], "Runs above the divider don't continue")
        let again = try await request("/start-fresh", method: "POST", body: Data("{}".utf8))
        precondition(again.0 == 200 && chat.messages.count == 5, "Repeating Start Fresh adds nothing")

        // The browser / Mac Remote page: the repeated error offers both actions, and the tab menu's
        // Start Fresh shows the divider under the kept history.
        let stuck = manager.newSession()
        stuck.messages = [ChatMessage(role: .user, text: "for portainer hoangnas can you find the user and password"),
                          ChatMessage(role: .assistant, text: "Checking my notes and saved secrets for the login."),
                          ChatMessage(role: .error, text: failure + " (Request ID: E96A)"),
                          ChatMessage(role: .user, text: "hi"), ChatMessage(role: .error, text: failure + " (Request ID: EA54)")]
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let (page, _) = try await URLSession.shared.data(from: base)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = StartFreshPageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 560), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: base)
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let before = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;await refresh();
        return {actions:[...document.querySelectorAll('#messages .message.error .error-actions button')].map(b=>b.textContent),
          errors:document.querySelectorAll('#messages .message.error').length};
        """, arguments: ["pairing": token, "sessionID": stuck.id.uuidString], contentWorld: .page) as? [String: Any]
        precondition(before?["actions"] as? [String] == ["Start Fresh", "Change Model"] && before?["errors"] as? Int == 2,
                     "Only the repeated error offers recovery: \(String(describing: before))")
        try await snapshotStartFresh(webView: webView, name: "web-repeated-error")
        let menu = try await webView.callAsyncJavaScript("""
        editTab(sessionItems.find(s=>s.id===sessionID));
        const shown=!$('tabStartFresh').classList.contains('hidden')&&!$('tabStartFresh').disabled;
        await $('tabStartFresh').onclick();
        return {shown,open:$('tabEditor').open,divider:document.querySelector('#messages .fresh-start')?.textContent,
          prompts:[...document.querySelectorAll('#messages .message.user')].map(row=>row.textContent),
          actions:document.querySelectorAll('#messages .error-actions').length,
          last:document.querySelector('#messages').lastElementChild?.className};
        """, arguments: ["sessionID": stuck.id.uuidString], contentWorld: .page) as? [String: Any]
        precondition(menu?["shown"] as? Bool == true && menu?["open"] as? Bool == false
                     && menu?["divider"] as? String == ChatSession.freshStartCaption
                     && (menu?["prompts"] as? [String])?.count == 2 && menu?["actions"] as? Int == 0,
                     "The tab menu's Start Fresh shows the divider below the kept history: \(String(describing: menu))")
        precondition(stuck.messages.count == 6 && stuck.messages.last?.role == .freshStart)
        try await snapshotStartFresh(webView: webView, name: "web-after")
    }

    /// Writes PNGs for review when CANTRIP_SNAPSHOT_DIR is set: the page, then the Mac rows.
    @MainActor
    private static func snapshotStartFresh(webView: WKWebView, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        func write(_ image: NSImage?, _ file: String) throws {
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
        let recovery = MessageRow.ErrorRecovery(changeModelTitle: "Change Model", isDisabled: false,
                                                startFresh: {}, changeModel: {})
        for dark in [false, true] {
            webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(300))
            try write(try await webView.takeSnapshot(configuration: nil), "\(name)-\(dark ? "dark" : "light").png")
            guard name == "web-after" else { continue }
            let content = VStack(alignment: .leading, spacing: 12) {
                MessageRow(message: ChatMessage(role: .user, text: "hi"))
                MessageRow(message: ChatMessage(role: .error, text: "Execution failed: 400 The requested model is not supported."),
                           errorRecovery: recovery)
                MessageRow(message: ChatMessage(role: .freshStart, text: ChatSession.freshStartCaption))
                MessageRow(message: ChatMessage(role: .user, text: "hi"))
                MessageRow(message: ChatMessage(role: .assistant, text: "Hi! What can I help you with?"))
            }
            .padding(16)
            .frame(width: 520, alignment: .leading)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            try write(renderer.nsImage, "mac-rows-\(dark ? "dark" : "light").png")
        }
    }

    @MainActor
    private static func testStartFreshWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        func slice(from start: String, to end: String) -> Substring {
            let from = source.range(of: start)!
            let to = source.range(of: end, range: from.upperBound..<source.endIndex)!
            return source[from.lowerBound..<to.lowerBound]
        }
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError("Start Fresh JavaScript failed: \(error!.toString()!)") }
        context.evaluateScript("""
        const node=()=>({children:[],dataset:{},classList:{values:new Set(),toggle(name,on){on?this.values.add(name):this.values.delete(name)},
            add(name){this.values.add(name)},remove(name){this.values.delete(name)},contains(name){return this.values.has(name)}},
          append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items},setAttribute(){},close(){},showModal(){},focus(){},select(){}});
        const elements={};const $=id=>elements[id]||(elements[id]=node());const document={createElement:node};
        let calls=[],renderedPayload="x",refreshed=0,opened=null,editingTab=null,tabSaving=false,movingTab=false,sessionItems=[],sidebarLayout=false,tabSections=[],sectionsSupported=false;
        function api(path,options){calls.push({path,method:options?.method});return Promise.resolve({})}
        function refresh(){refreshed++;return Promise.resolve()}
        function editModelSettings(item){opened=item}
        function updateTabMoveControls(){}
        \(slice(from: "    function freshStartDivider", to: "    function handoffResultCard"))
        \(slice(from: "    function editTab(item)", to: "    function updateTabMoveControls"))
        \(slice(from: "    $(\"tabStartFresh\").onclick", to: "    $(\"tabMacAccess\").onclick"))
        const divider=freshStartDivider({id:"m1",role:"freshStart",text:"Started fresh"});
        const row=node();appendErrorRecovery(row,{id:"tab-a",isLocalPrivate:false,isStreaming:false,queuedCount:0});
        const busyRow=node();appendErrorRecovery(busyRow,{id:"tab-a",isStreaming:true,queuedCount:0});
        editTab({id:"tab-b",title:"Home Network",supportsStartFresh:true,isStreaming:false,queuedCount:0});
        """)
        precondition(context.evaluateScript("divider.className==='fresh-start' && divider.textContent==='Started fresh' && divider.dataset.messageId==='m1'")!.toBool())
        precondition(context.evaluateScript("row.children[1].children.map(b=>b.textContent).join()")!.toString() == "Start Fresh,Change Model")
        precondition(context.evaluateScript("busyRow.children[1].children.every(b=>b.disabled)")!.toBool(), "Busy tabs can't start fresh")
        precondition(context.evaluateScript("!$('tabStartFresh').classList.values.has('hidden') && !$('tabStartFresh').disabled")!.toBool())
        context.evaluateScript("row.children[1].children[1].onclick()")
        precondition(context.evaluateScript("opened.id")!.toString() == "tab-a", "Change Model opens the tab's model settings")
        context.evaluateScript("$('tabStartFresh').onclick()")
        context.evaluateScript("row.children[1].children[0].onclick()")
        let deadline = Date().addingTimeInterval(2)
        while context.evaluateScript("refreshed")!.toInt32() < 2, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(context.evaluateScript("calls.map(c=>c.method+' '+c.path).join()")!.toString()
                     == "POST /api/v1/sessions/tab-b/start-fresh,POST /api/v1/sessions/tab-a/start-fresh",
                     context.evaluateScript("JSON.stringify(calls)")!.toString())
        precondition(context.evaluateScript("editingTab===null && renderedPayload===''")!.toBool())
        context.evaluateScript("editTab({id:'home',title:'Old host'})")
        precondition(context.evaluateScript("$('tabStartFresh').classList.values.has('hidden')")!.toBool(),
                     "Hosts without Start Fresh hide the action")
    }
}

private final class StartFreshPageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
}
