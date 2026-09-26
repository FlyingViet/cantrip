import CryptoKit
import Foundation
import ImageIO
import JavaScriptCore
import UniformTypeIdentifiers

private final class InputBackendFixture: Backend {
    var events: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        events = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    @MainActor
    static func testRemoteInput() async throws {
        let settings = AppSettings.shared
        let original = settings.backend, memory = settings.memoryEnabled
        settings.backend = .copilot; settings.memoryEnabled = false
        defer { settings.backend = original; settings.memoryEnabled = memory }
        let backend = InputBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        chat.submitRemote("Input lifecycle fixture")
        try await waitForJournalTest { backend.events != nil }
        var answers: [InputRequestAnswer] = [], alerts = 0
        chat.onInputNeeded = { _ in alerts += 1 }
        let request = BackendInputRequest(kind: .approval, source: "fixture", title: "Allow write?",
            detail: "Write fixture.txt") { answers.append($0) }
        backend.events?(.inputRequired(request))
        try await waitForJournalTest { chat.pendingInputs.count == 1 }
        precondition(alerts == 1 && chat.isStreaming)
        chat.submitRemote("Another message", mode: .auto)
        precondition(chat.queued.count == 1 && request.isPending)
        do { try chat.respondToInput(id: request.snapshot.id, answer: .init(decision: .submit, text: "yes")); preconditionFailure() }
        catch InputRequestError.invalidAnswer {}
        try chat.respondToInput(id: request.snapshot.id, answer: .init(decision: .approve))
        do { try chat.respondToInput(id: request.snapshot.id, answer: .init(decision: .approve)); preconditionFailure() }
        catch InputRequestError.unavailable {}
        precondition(answers.count == 1 && answers[0].decision == .approve && chat.pendingInputs.isEmpty)
        let secret = BackendInputRequest(kind: .secret, source: "/usr/bin/ssh", title: "Password", detail: "user@fixture") { answers.append($0) }
        chat.receiveInput(secret)
        try chat.respondToInput(id: secret.snapshot.id, answer: .init(decision: .submit, text: "fixture-secret-not-history"))
        try await chat.flushJournal()
        let journal = try String(contentsOf: RunJournal.defaultDirectory.appendingPathComponent("\(chat.id).jsonl"), encoding: .utf8)
        precondition(!journal.contains("fixture-secret-not-history"))
        precondition(!chat.messages.contains { $0.text.contains("fixture-secret-not-history") })
        let queueCount = chat.queued.count
        let question = BackendInputRequest(kind: .question, source: "fixture", title: "Show the error",
            detail: "Include a screenshot.", allowsFreeform: true) { answers.append($0) }
        chat.receiveInput(question)
        chat.attachments = ["/tmp/question-fixture.png"]
        chat.submit("Here is the screenshot", mode: .auto)
        precondition(!question.isPending && chat.queued.count == queueCount && chat.attachments.isEmpty)
        precondition(answers.last?.text?.contains("/tmp/question-fixture.png") == true)
        precondition(chat.messages.contains { $0.role == .user && $0.text.contains("Here is the screenshot") })
        try await chat.flushJournal()
        let questionJournal = try String(contentsOf: RunJournal.defaultDirectory.appendingPathComponent("\(chat.id).jsonl"), encoding: .utf8)
        precondition(questionJournal.contains("Here is the screenshot") && !questionJournal.contains("fixture-secret-not-history"))
        do { try chat.respondInChat(id: question.snapshot.id, text: "late reply"); preconditionFailure() }
        catch InputRequestError.unavailable {}
        precondition(chat.queued.count == queueCount, "A stale reply must never turn into a queued task")
        let choice = BackendInputRequest(kind: .question, source: "fixture", title: "Choose",
            detail: "", choices: ["A", "B"]) { answers.append($0) }
        chat.receiveInput(choice)
        chat.attachments = ["/tmp/retained-fixture.png"]
        do { try chat.submitInputReply("C", id: choice.snapshot.id); preconditionFailure() }
        catch InputRequestError.invalidAnswer {}
        precondition(choice.isPending && chat.attachments == ["/tmp/retained-fixture.png"])
        chat.attachments = []
        chat.submit("B")
        precondition(!choice.isPending && answers.last?.text == "B")
        let stopped = BackendInputRequest(kind: .question, source: "fixture", title: "Choose",
            detail: "Which?", choices: ["A", "B"]) { answers.append($0) }
        chat.receiveInput(stopped)
        chat.cancel()
        precondition(!stopped.isPending && chat.pendingInputs.isEmpty && answers.last?.decision == .cancel)
        chat.isStreaming = true
        let expired = BackendInputRequest(kind: .approval, source: "fixture", title: "Expired",
            detail: "", lifetime: 0.03) { answers.append($0) }
        chat.receiveInput(expired)
        try await waitForJournalTest { chat.pendingInputs.isEmpty }
        precondition(!expired.isPending)
        try await testInputAPI(chat)
        chat.cancel()
        try await testInputBridge()
        try await testClaudeInput()
        try await testAskpass()
        try await testDeviceLogin()
        try await testInputPush()
        try testInputWeb()
        print("Remote input: lifecycle, single-use replies, expiry, Stop, secret isolation, API, SDK bridge, real askpass and APNs passed")
    }

    @MainActor
    private static func testInputAPI(_ chat: ChatSession) async throws {
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        var answer: InputRequestAnswer?
        let pending = BackendInputRequest(kind: .secret, source: "verified program", title: "Credential",
                                          detail: "fixture") { answer = $0 }
        chat.receiveInput(pending)
        func call(_ suffix: String = "", method: String = "GET", auth: Bool = true, body: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)/input\(suffix)")!)
            request.httpMethod = method
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = body.map { Data($0.utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let unauth = try await call(auth: false)
        let loaded = try await call()
        precondition(unauth.0 == 401 && loaded.0 == 200)
        let bad = try await call("/\(pending.snapshot.id)", method: "POST", body: #"{"decision":"submit","text":true}"#)
        precondition(bad.0 == 400 && pending.isPending)
        let body = #"{"decision":"submit","text":"secret-api-fixture"}"#
        let sent = try await call("/\(pending.snapshot.id)", method: "POST", body: body)
        let replay = try await call("/\(pending.snapshot.id)", method: "POST", body: body)
        precondition(sent.0 == 200 && replay.0 == 409 && answer?.text == "secret-api-fixture")
        precondition(!String(data: sent.1, encoding: .utf8)!.contains("secret-api-fixture"))
        func sendChat(_ requestID: UUID, text: String, images: [[String: String]] = []) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)/messages")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text, "mode": "auto", "inputRequestID": requestID.uuidString, "images": images
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let pixels = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let imageData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(imageData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixels.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let question = BackendInputRequest(kind: .question, source: "fixture", title: "What failed?",
            detail: "Attach the error", allowsFreeform: true) { answer = $0 }
        chat.receiveInput(question)
        let queued = chat.queued.count
        let reply = try await sendChat(question.snapshot.id, text: "Error screenshot",
                                      images: [["data": (imageData as Data).base64EncodedString()]])
        precondition(reply.0 == 202 && answer?.text?.contains("remote-attachments") == true)
        precondition(chat.queued.count == queued && !question.isPending)
        let snapshot = reply.1["session"] as! [String: Any]
        precondition(snapshot["supportsChatInputReplies"] as? Bool == true)
        let messages = snapshot["messages"] as! [[String: Any]]
        precondition(messages.contains { $0["role"] as? String == "user" && $0["images"] != nil })
        let duplicate = try await sendChat(question.snapshot.id, text: "stale response")
        precondition(duplicate.0 == 409 && chat.queued.count == queued)
        let password = BackendInputRequest(kind: .secret, source: "fixture", title: "Password", detail: "") { answer = $0 }
        chat.receiveInput(password)
        let wrongChannel = try await sendChat(password.snapshot.id, text: "must-not-be-stored")
        precondition(wrongChannel.0 == 400 && password.isPending)
        precondition(!chat.messages.contains { $0.text.contains("must-not-be-stored") })
        password.cancel()
        chat.isPrivate = true
        let hidden = try await call()
        precondition(hidden.0 == 404)
        chat.isPrivate = false
    }

    @MainActor
    private static func testInputWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    let inputState")!
        let end = source.range(of: "    let desktopState", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error!.toString()) }
        context.evaluateScript("""
        function node(){return {children:[],dataset:{},style:{},value:"",append(...items){this.children.push(...items)},
          replaceChildren(){this.children=[]},setAttribute(){},addEventListener(){},querySelectorAll(){return []},focus(){this.focused=true},
          showModal(){this.open=true},close(){this.open=false}}}
        const elements={};const $=id=>elements[id]||(elements[id]=node());const document={createElement:node};
        let token="fixture",selected="tab",renderedPayload="",calls=[];function clearTimeout(){}function setTimeout(){return 1}
        function safeURL(value){return value}function refresh(){return Promise.resolve()}
        const question={id:"question",kind:"question",title:"Which?",detail:"Explain in chat",choices:["A","B"],allowsFreeform:true,expiresAt:9999999999};
        const secret={id:"secret",kind:"secret",title:"Password",detail:"Verified program",choices:[],expiresAt:9999999999};
        function api(path,options){calls.push({path,body:options?JSON.parse(options.body):null});return Promise.resolve({requests:[question,secret]})}
        \(source[start.lowerBound..<end.lowerBound])
        const inline=node();appendChatInputs(inline,{id:"tab",pendingInputs:[question,secret]});
        """)
        precondition(context.evaluateScript("!$('inputEditor').open && inline.children.length===2 && chatInputReply.id==='question'")!.toBool())
        context.evaluateScript("showInputs()")
        precondition(context.evaluateScript("$('inputCards').children.length===1 && $('inputCards').children[0].dataset.id==='secret'")!.toBool())
        context.evaluateScript("respondChatInput({sessionID:'tab',token},question,{decision:'submit',text:'A'})")
        precondition(context.evaluateScript("calls.some(c=>c.path==='/api/v1/sessions/tab/input/question' && c.body.text==='A')")!.toBool())
    }

    @MainActor
    private static func testInputBridge() async throws {
        let settings = AppSettings.shared, oldActions = AppSettings.shared.allowActions, tools = AppSettings.shared.copilotAllowTools
        settings.allowActions = false; settings.copilotAllowTools = true
        defer { settings.allowActions = oldActions; settings.copilotAllowTools = tools }
        let sdk = #"""
        export const RuntimeConnection={forStdio:value=>value};
        export class CopilotClient{
          async start(){} async forceStop(){}
          async createSession(config){return {async abort(){},async send(){
            const permission=await config.onPermissionRequest({kind:'shell',fullCommandText:'echo fixture'});
            if(permission.kind!=='approve-once')throw Error('permission denied');
            const response=await config.onUserInputRequest({question:'Which target?',choices:['A','B'],allowFreeform:false});
            config.onEvent({type:'assistant.message_delta',id:'message',data:{messageId:'answer',deltaContent:response.answer}});
            config.onEvent({type:'session.idle',data:{}});return 'message';
          }}}
        }
        """#
        let url = "data:text/javascript;base64," + Data(sdk.utf8).base64EncodedString()
        let script = CopilotSessionBridge.script.replacingOccurrences(of: CopilotRuntime.discoveryScript,
            with: "function resolveCopilotRuntime(){return {sdk:'\(url)',runtime:'fixture'}}")
        let backend = CopilotBackend(bridgeScript: script)
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submitRemote("Interactive bridge fixture")
        try await waitForJournalTest { chat.pendingInputs.first?.kind == .approval }
        try chat.respondToInput(id: chat.pendingInputs[0].id, answer: .init(decision: .approve))
        try await waitForJournalTest { chat.pendingInputs.first?.kind == .question }
        let id = chat.pendingInputs[0].id
        do { try chat.respondToInput(id: id, answer: .init(decision: .submit, text: "C")); preconditionFailure() }
        catch InputRequestError.invalidAnswer {}
        try chat.respondToInput(id: id, answer: .init(decision: .submit, text: "B"))
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.messages.last?.text == "B", "Input responses must bypass a blocked SDK send queue")
    }

    @MainActor
    private static func testAskpass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("askpass-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("fixture-key")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        create.arguments = ["-q", "-t", "ed25519", "-N", "fixture-passphrase", "-f", key.path]
        try create.run()
        create.waitUntilExit()
        precondition(create.terminationStatus == 0)
        let process = Process(), output = Pipe(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", key.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostics
        var request: BackendInputRequest?
        let broker = try RemoteAskpass(process: process) { value in
            Task { @MainActor in request = value }
        }
        defer { broker.stop() }
        process.environment = ProcessInfo.processInfo.environment.merging(broker.environment) { _, new in new }
        try process.run()
        try await waitForJournalTest { request != nil || !process.isRunning }
        if request == nil, !process.isRunning {
            print("Askpass fixture exit \(process.terminationStatus): \(String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
            let logs = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Cantrip.log"), encoding: .utf8)
            print(logs.split(separator: "\n").filter { $0.contains("askpass:") }.suffix(6).joined(separator: "\n"))
        }
        precondition(request?.snapshot.kind == .secret, "Real OpenSSH must invoke the process-bound askpass helper")
        try request!.respond(.init(decision: .submit, text: "fixture-passphrase"))
        try await waitForJournalTest { !process.isRunning }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        precondition(process.terminationStatus == 0 && text.hasPrefix("ssh-ed25519 ") && !text.contains("fixture-passphrase"))
        precondition(RemoteAskpass.trustedRequester(helper: getpid(), root: getpid()) == nil,
                     "Arbitrary local/model helper invocations cannot impersonate OS credential requesters")
        let untrusted = Process()
        untrusted.executableURL = Bundle.main.executableURL
        untrusted.arguments = ["--cantrip-askpass", "Fake password request"]
        untrusted.standardOutput = FileHandle.nullDevice
        untrusted.standardError = FileHandle.nullDevice
        var unexpected = false
        let rejected = try RemoteAskpass(process: untrusted) { _ in unexpected = true }
        defer { rejected.stop() }
        untrusted.environment = ProcessInfo.processInfo.environment.merging(rejected.environment) { _, new in new }
        try untrusted.run()
        try await waitForJournalTest { !untrusted.isRunning }
        precondition(!unexpected && untrusted.terminationStatus != 0)
    }

    @MainActor
    private static func testClaudeInput() async throws {
        let settings = AppSettings.shared
        let path = settings.claudePath, actions = settings.allowActions, backend = settings.backend
        defer { settings.claudePath = path; settings.allowActions = actions; settings.backend = backend }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("claude-fixture")
        try Data(#"""
        #!/usr/bin/env node
        const readline=require('readline');let stage=0;
        const emit=x=>process.stdout.write(JSON.stringify(x)+'\n');
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const value=JSON.parse(line);
          if(value.type==='user'){emit({type:'control_request',request_id:'permission',request:{subtype:'can_use_tool',tool_name:'Bash',input:{command:'echo test'}}})}
          else if(value.type==='control_response'){
            if(value.response.response.behavior!=='allow')process.exit(2);
            if(stage++===0)emit({type:'control_request',request_id:'question',request:{subtype:'can_use_tool',tool_name:'AskUserQuestion',
              input:{questions:[{question:'Which environment?',options:[{label:'Preview'},{label:'Production'}]}]}}});
            else {
              if(value.response.response.updatedInput.answers['Which environment?']!=='Preview')process.exit(3);
              emit({type:'stream_event',event:{type:'content_block_delta',delta:{type:'text_delta',text:'Claude input accepted'}}});
              emit({type:'result',is_error:false});
            }
          }
        });
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        settings.claudePath = script.path; settings.allowActions = false; settings.backend = .claudeCode
        let chat = ChatSession()
        defer { chat.cancel() }
        chat.submitRemote("Claude control fixture")
        try await waitForJournalTest { chat.pendingInputs.first?.kind == .approval }
        try chat.respondToInput(id: chat.pendingInputs[0].id, answer: .init(decision: .approve))
        try await waitForJournalTest { chat.pendingInputs.first?.kind == .question }
        try chat.respondToInput(id: chat.pendingInputs[0].id, answer: .init(decision: .submit, text: "Preview"))
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.messages.last?.text == "Claude input accepted")
    }

    @MainActor
    private static func testDeviceLogin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("device-login-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("gh-fixture")
        try Data("#!/bin/sh\nprintf '! First copy your one-time code: ABCD-1234\\n'\nsleep 1\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let login = RemoteDeviceLogin(executable: script)
        defer { login.cancel() }
        var request: BackendInputRequest?, done = false, output = ""
        login.start(workdir: directory.path) { event in
            Task { @MainActor in
                switch event {
                case .inputRequired(let value): request = value
                case .textDelta(let text): output += text
                case .done: done = true
                default: break
                }
            }
        }
        try await waitForJournalTest { request != nil }
        precondition(request?.snapshot.code == "ABCD-1234" && request?.snapshot.url == "https://github.com/login/device")
        try request!.respond(.init(decision: .approve))
        precondition(!done, "A click must not pretend OAuth succeeded")
        try await waitForJournalTest { done }
        precondition(!output.contains("ABCD-1234"))
    }

    @MainActor
    private static func testInputPush() async throws {
        let configuration = RemotePushConfiguration(keyID: "TESTKEY123", teamID: "TESTTEAM12", key: P256.Signing.PrivateKey())
        let subscriber = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
            deviceToken: String(repeating: "a", count: 64), environment: "development", inputNeeded: true)
        let event = RemoteCompletion(id: UUID(), sessionID: UUID(), title: "must-not-appear",
            summary: "secret-detail-must-not-appear", completedAt: Date(), kind: "input", expiresAt: Date().addingTimeInterval(60))
        let request = try RemoteNotifications.request(deliveryID: UUID(), completion: event,
            registration: subscriber, fingerprint: "paired", authorization: "fixture")
        let text = String(data: request.httpBody!, encoding: .utf8)!
        precondition(text.contains("needs your input") && !text.contains("must-not-appear"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("input-push-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        actor Count {
            var count = 0
            func sent(_ request: URLRequest) -> (Data, HTTPURLResponse) {
                count += 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let count = Count()
        let push = RemoteNotifications(file: directory.appendingPathComponent("state.json"),
            configuration: { configuration }, send: { await count.sent($0) })
        await push.activate(fingerprint: "paired")
        var legacy = subscriber; legacy.inputNeeded = nil
        try await push.register(legacy, fingerprint: "paired")
        await push.enqueueInput(id: UUID(), sessionID: UUID(), expiresAt: Date().addingTimeInterval(30))
        try await Task.sleep(for: .milliseconds(50))
        let before = await count.count
        precondition(before == 0, "Input alerts require explicit registration capability")
        try await push.register(subscriber, fingerprint: "paired")
        await push.enqueueInput(id: event.id, sessionID: event.sessionID, expiresAt: Date().addingTimeInterval(30))
        try await Task.sleep(for: .milliseconds(100))
        await push.enqueueInput(id: event.id, sessionID: event.sessionID, expiresAt: Date().addingTimeInterval(30))
        let after = await count.count
        precondition(after == 1)
        await push.resolveInput(event.id)
        let stored = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        precondition(!stored.contains("must-not-appear"))
        await push.activate(fingerprint: nil)
    }
}
