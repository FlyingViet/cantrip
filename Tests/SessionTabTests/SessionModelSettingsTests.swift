import Foundation
import JavaScriptCore

extension SessionTabTests {
    @MainActor
    static func testSessionModelSettings() async throws {
        let settings = AppSettings.shared
        let oldBackend = settings.backend
        let oldModel = settings.copilotModel, oldEffort = settings.copilotEffort
        let oldTier = settings.copilotContextTier, oldCatalog = settings.copilotModelCatalog
        defer {
            settings.backend = oldBackend
            settings.copilotModel = oldModel
            settings.copilotEffort = oldEffort
            settings.copilotContextTier = oldTier
            settings.copilotModelCatalog = oldCatalog
        }
        let catalog = [
            CopilotModelInfo(id: "model-a", contextWindow: 1_050_000, reasoningEfforts: ["low", "high"],
                             contextTiers: ["default", "long_context"],
                             defaultContextPromptTokens: 272_000, longContextPromptTokens: 1_050_000),
            CopilotModelInfo(id: "model-b", reasoningEfforts: [], contextTiers: ["default"])
        ]
        settings.refreshCopilotModels { _, completion in completion(.success(catalog)) }
        try await waitForJournalTest { !settings.copilotRefreshInFlight }
        settings.backend = .copilot
        settings.copilotModel = "model-a"
        settings.copilotEffort = "low"
        settings.copilotContextTier = "default"
        let manager = SessionManager(), backend = CopilotBackend()
        let chat = ChatSession(copilotBackend: backend)
        manager.sessions.append(chat)
        let other = manager.newSession()
        let selected = SessionModelSelection(model: "model-a", effort: "high", contextTier: "long_context")
        let originalRevision = chat.modelSettingsRevision
        let originalDefaults = chat.defaultModelSelection
        try chat.updateModelSettings(selected, revision: originalRevision)
        precondition(chat.modelSelection == selected && other.modelSelection == originalDefaults)
        precondition(settings.copilotEffort == "low" && settings.copilotContextTier == "default")
        precondition(backend.modelOverride == selected.model && backend.effortOverride == selected.effort
                     && backend.contextTierOverride == selected.contextTier)
        precondition(ChatSession(id: chat.id).modelSelection == selected, "Per-tab overrides must survive relaunch")
        precondition(SessionManager().sessions.contains { $0.id == chat.id }, "Empty configured tabs must restore")
        do {
            try chat.updateModelSettings(nil, revision: originalRevision)
            preconditionFailure("Stale writes must not overwrite settings")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        for invalid in [
            SessionModelSelection(model: "unknown", effort: "", contextTier: ""),
            SessionModelSelection(model: "model-b", effort: "high", contextTier: "default"),
            SessionModelSelection(model: "model-b", effort: "", contextTier: "long_context"),
            SessionModelSelection(model: "model-a", effort: "invented", contextTier: "default")
        ] {
            do {
                try chat.updateModelSettings(invalid, revision: chat.modelSettingsRevision)
                preconditionFailure("Unsupported settings must not apply")
            } catch let error as SessionModelSettingsError { precondition(error.status == 400) }
            precondition(chat.modelSelection == selected)
        }
        chat.isStreaming = true
        chat.submitRemote("Keep this queued", mode: .queue)
        for busy in [true, false] {
            chat.isStreaming = busy
            do {
                try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision)
                preconditionFailure("Active or queued work must prevent changes")
            } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        }
        chat.removeQueued(at: 0)
        chat.councilMode = true
        do {
            try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision)
            preconditionFailure("Council configuration is separate")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        chat.councilMode = false
        // Claude Code and Codex tabs have their own settings; Copilot Remote and Local don't.
        settings.backend = .claudeCode
        precondition(chat.modelSettingsUnavailableReason == nil && chat.ownModelSelection == nil,
                     "Claude Code keeps a separate, unset selection")
        settings.backend = .codex
        precondition(chat.modelSettingsUnavailableReason == nil && chat.ownModelSelection == nil,
                     "Codex keeps a separate, unset selection")
        settings.backend = .copilotRemote
        precondition(chat.modelSettingsUnavailableReason != nil)
        settings.backend = .copilot

        let historyURL = SessionManager.chatsDir.appendingPathComponent("\(chat.id).json")
        let history = try JSONEncoder().encode((0..<60).map { ChatMessage(role: .user, text: "History \($0)") })
        try history.write(to: historyURL)
        try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision)
        let retainedHistory = try Data(contentsOf: historyURL)
        precondition(retainedHistory == history, "Settings must not rewrite or trim history")
        precondition(backend.modelOverride == nil && backend.effortOverride == nil && backend.contextTierOverride == nil)
        let inheritedRevision = chat.modelSettingsRevision
        settings.copilotEffort = "high"
        precondition(chat.modelSettingsRevision != inheritedRevision && chat.modelSelection.effort == "high")
        settings.copilotEffort = "low"

        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ method: String = "GET", id: UUID? = nil, body: [String: Any]? = nil,
                     authenticated: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(id ?? chat.id)/model-settings")!)
            request.httpMethod = method
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let unauthorized = try await request(authenticated: false)
        precondition(unauthorized.0 == 401)
        let loaded = try await request()
        precondition(loaded.0 == 200 && loaded.1["usesDefaults"] as? Bool == true)
        precondition((loaded.1["models"] as? [[String: Any]])?.count == 5, "the three tiers, then the two models")
        let body: [String: Any] = ["revision": loaded.1["revision"]!, "usesDefaults": false,
                                   "model": "model-a", "effort": "high", "contextTier": "long_context"]
        for invalid in [
            [:], ["usesDefaults": 1, "revision": chat.modelSettingsRevision],
            ["usesDefaults": true, "revision": chat.modelSettingsRevision, "model": "model-a"],
            ["usesDefaults": false, "revision": chat.modelSettingsRevision, "model": false]
        ] as [[String: Any]] {
            let rejected = try await request("POST", body: invalid)
            precondition(rejected.0 == 400 && chat.tabMetadata.modelSettings == nil)
        }
        let applied = try await request("POST", body: body)
        precondition(applied.0 == 200 && chat.modelSelection == selected)
        let stale = try await request("POST", body: body)
        precondition(stale.0 == 409)
        let wrongMethod = try await request("DELETE")
        precondition(wrongMethod.0 == 405)

        // Fast, Standard and Deep lead every client's model list; a tier saves by its name and runs
        // the backend's model for it, and an edit to the tier map reaches the tab's next run.
        let tierIDs = ((applied.1["models"] as? [[String: Any]]) ?? []).prefix(3).compactMap { $0["id"] as? String }
        precondition(tierIDs == ["fast", "standard", "deep"], "\(tierIDs)")
        let savedTiers = settings.modelTiers
        defer { settings.modelTiers = savedTiers }
        settings.modelTiers.set([ModelTierChoice(model: "model-a", effort: "high")], for: .deep, on: .copilot)
        let tierBody: [String: Any] = ["usesDefaults": false, "model": "Deep", "effort": "", "contextTier": ""]
        let tiered = try await request("POST", body: tierBody.merging(["revision": chat.modelSettingsRevision]) { $1 })
        precondition(tiered.0 == 200 && chat.modelSelection == SessionModelSelection(model: "deep", effort: "", contextTier: "")
                     && chat.runTier == .deep, "\(tiered)")
        precondition(backend.modelOverride == "model-a" && backend.effortOverride == "high" && backend.contextTierOverride == "")
        let deepOption = (tiered.1["tiers"] as? [[String: Any]])?.last
        precondition(deepOption?["id"] as? String == "deep" && deepOption?["model"] as? String == "model-a"
                     && deepOption?["effort"] as? String == "high")
        precondition((tiered.1["models"] as? [[String: Any]])?[2]["reasoningEfforts"] as? [String] == ["low", "high"],
                     "A tier offers its model's efforts")
        settings.modelTiers.set([ModelTierChoice(model: "model-b")], for: .deep, on: .copilot)
        precondition(chat.modelSettingsRevision == tiered.1["revision"] as? String, "A tier edit doesn't make an open form stale")
        try chat.updateModelSettings(chat.modelSelection, revision: chat.modelSettingsRevision)
        precondition(backend.modelOverride == "model-b" && backend.effortOverride == "")
        let tierWindow = try await request("POST", body: tierBody.merging(["revision": chat.modelSettingsRevision,
                                                                           "contextTier": "long_context"]) { $1 })
        precondition(tierWindow.0 == 400)
        try chat.updateModelSettings(selected, revision: chat.modelSettingsRevision)
        precondition(backend.modelOverride == "model-a" && chat.runTier == nil)
        chat.isStreaming = true
        let busy = try await request("POST", body: ["revision": chat.modelSettingsRevision, "usesDefaults": true])
        precondition(busy.0 == 409 && chat.modelSelection == selected)
        chat.isStreaming = false
        chat.isPrivate = true
        let hidden = try await request()
        precondition(hidden.0 == 404 && SessionTabMetadata.load(id: chat.id).modelSettings == nil)
        let absent = try await request(id: UUID())
        precondition(absent.0 == 404)
        chat.isPrivate = false
        try testModelSettingsWeb()
        try await testModelSettingsRuntime()
        try await testSubagentSessionConfiguration()
        print("Per-tab model settings: persistence, isolation, validation, API and web passed")
    }

    @MainActor
    private static func testSubagentSessionConfiguration() async throws {
        let settings = AppSettings.shared
        let allow = settings.copilotAllowSubagents, memory = settings.memoryEnabled
        let screen = settings.attachScreen, location = settings.shareLocation
        let calendar = settings.shareCalendar, files = settings.fileRAGEnabled
        defer {
            settings.copilotAllowSubagents = allow; settings.memoryEnabled = memory
            settings.attachScreen = screen; settings.shareLocation = location
            settings.shareCalendar = calendar; settings.fileRAGEnabled = files
        }
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        // A subagent's idle must not end the turn; the root reply arrives afterwards.
        let fakeSDK = #"""
        export const RuntimeConnection={forStdio:value=>value};
        export class CopilotClient {
          async start() {} async stop() {} async forceStop() {}
          async createSession(config) { return {
            sessionId:'3f2c1e8a-5b7d-4c9e-8a1f-0d2b4c6e8f10',
            async abort() {}, async destroy() {},
            async send(options) {
              config.onEvent({type:'session.idle',agentId:'child',data:{}});
              setTimeout(() => {
                config.onEvent({type:'assistant.message_delta',id:'event-'+Math.random(),data:{messageId:'message',
                  deltaContent:JSON.stringify({excluded:config.excludedTools||null,
                    guidance:config.systemMessage?.content||'',mode:config.systemMessage?.mode||'',
                    childStreaming:config.includeSubAgentStreamingEvents,prompt:options.prompt})}});
                config.onEvent({type:'session.idle',data:{}});
              }, 100);
              return 'native-message';
            }
          }; }
        }
        """#
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript,
            with: "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        )
        let chat = ChatSession(copilotBackend: CopilotBackend(bridgeScript: script))
        defer { chat.cancel() }

        settings.copilotAllowSubagents = true
        chat.submitRemote("Allowed subagents fixture")
        try await waitForJournalTest { !chat.isStreaming }
        let allowed = try JSONSerialization.jsonObject(with: Data(chat.messages.last!.text.utf8)) as! [String: Any]
        precondition(allowed["excluded"] is NSNull, "Allowed subagents keep their tools")
        precondition(allowed["mode"] as? String == "append"
                     && allowed["guidance"] as? String
                        == CopilotBackend.previewGuidance + "\n\n" + ReplyVisibility.guidance
                            + "\n\n" + SimulatorPool.agentGuidance(command: TabInsight.command)
                            + "\n\n" + CopilotBackend.subagentGuidance,
                     "Preview, reply-visibility and subagent guidance belong in the appended system message")
        try await waitForJournalTest { !SessionOutputFolders.shared.roots(for: chat.id).isEmpty }
        precondition(SessionOutputFolders.shared.roots(for: chat.id).map(\.path) == [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".copilot/session-state/3f2c1e8a-5b7d-4c9e-8a1f-0d2b4c6e8f10/files").path
        ], "The tab records the CLI session whose files folder it may preview")
        precondition(allowed["childStreaming"] as? Bool == false, "Subagent deltas are not streamed to Cantrip")
        precondition((allowed["prompt"] as? String)?.contains("avoid spawning subagents") == false,
                     "Prompts must not carry a per-turn subagent suffix")

        settings.copilotAllowSubagents = false
        chat.submitRemote("Disabled subagents fixture")
        try await waitForJournalTest { !chat.isStreaming }
        let disabled = try JSONSerialization.jsonObject(with: Data(chat.messages.last!.text.utf8)) as! [String: Any]
        precondition(disabled["excluded"] as? [String] == ["task", "read_agent", "write_agent", "list_agents"],
                     "Disabling subagents removes their tools")
        precondition(disabled["guidance"] as? String
                        == CopilotBackend.previewGuidance + "\n\n" + ReplyVisibility.guidance
                            + "\n\n" + SimulatorPool.agentGuidance(command: TabInsight.command),
                     "Disabled subagents get no delegation guidance, but keep reply visibility")
        precondition((disabled["prompt"] as? String)?.contains("Allowed subagents fixture") == true,
                     "Changing the subagent setting must carry recent conversation context")
    }

    @MainActor
    private static func testModelSettingsRuntime() async throws {
        let settings = AppSettings.shared
        let memory = settings.memoryEnabled, screen = settings.attachScreen
        let location = settings.shareLocation, calendar = settings.shareCalendar, files = settings.fileRAGEnabled
        defer {
            settings.memoryEnabled = memory; settings.attachScreen = screen
            settings.shareLocation = location; settings.shareCalendar = calendar; settings.fileRAGEnabled = files
        }
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        let fakeSDK = #"""
        export const RuntimeConnection={forStdio:value=>value};
        export class CopilotClient {
          async start() {} async stop() {} async forceStop() {}
          async createSession(config) { return {
            async abort() {}, async destroy() {},
            async send(options) {
              config.onEvent({type:'assistant.message_delta',id:'event',data:{messageId:'message',
                deltaContent:JSON.stringify({model:config.model,effort:config.reasoningEffort||'',
                  contextTier:config.contextTier,prompt:options.prompt})}});
              config.onEvent({type:'session.idle',data:{}});
              return 'native-message';
            }
          }; }
        }
        """#
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript,
            with: "function resolveCopilotRuntime(){return {sdk:'\(sdkURL)',runtime:'fixture'}}"
        )
        let backend = CopilotBackend(bridgeScript: script)
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submitRemote("First model fixture")
        try await waitForJournalTest { !chat.isStreaming }
        let first = try JSONSerialization.jsonObject(with: Data(chat.messages.last!.text.utf8)) as! [String: Any]
        precondition(first["model"] as? String == "model-a" && first["effort"] as? String == "low")
        let change = SessionModelSelection(model: "model-b", effort: "", contextTier: "default")
        try chat.updateModelSettings(change, revision: chat.modelSettingsRevision)
        chat.submitRemote("Second model fixture")
        try await waitForJournalTest { !chat.isStreaming }
        let second = try JSONSerialization.jsonObject(with: Data(chat.messages.last!.text.utf8)) as! [String: Any]
        precondition(second["model"] as? String == "model-b" && second["effort"] as? String == ""
                     && second["contextTier"] as? String == "default")
        precondition((second["prompt"] as? String)?.contains("First model fixture") == true,
                     "A changed runtime must receive recent conversation context")
        precondition(chat.messages.filter { $0.role == .user }.count == 2, "Changing models must not clear the tab")
        try chat.updateModelSettings(nil, revision: chat.modelSettingsRevision)
        chat.submitRemote("Restored defaults")
        try await waitForJournalTest { !chat.isStreaming }
        let restored = try JSONSerialization.jsonObject(with: Data(chat.messages.last!.text.utf8)) as! [String: Any]
        precondition(restored["model"] as? String == "model-a" && restored["effort"] as? String == "low")
    }

    @MainActor
    private static func testModelSettingsWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    let modelEditorState")!
        let end = source.range(of: "    let editingTab", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error!.toString()) }
        context.evaluateScript("""
        const elements={};const $=id=>elements[id]||(elements[id]={value:"",checked:false,disabled:false,textContent:"",
          children:[],replaceChildren(...items){this.children=items},append(item){this.children.push(item)},
          classList:{hidden:true,toggle(name,on){this.hidden=on}},addEventListener(){},showModal(){},close(){}});
        function Option(label,value){this.label=label;this.value=value}
        let fallbackCalls=[];const fallback={backends:[],backend:"",primary:"Claude Code",revision:"fallback-a",
          choices:[{id:"Copilot",label:"Copilot"},{id:"Codex",label:"Codex"}],limited:[{backend:"Claude Code",until:"2026-10-28T12:00:00Z",untilLabel:"5:00 AM"}]};
        const document={createElement(){return {children:[],attributes:{},append(...items){this.children.push(...items)},setAttribute(name,value){this.attributes[name]=value}}}};
        function setTimeout(callback){callback()}let token="fixture",selected="tab-a",calls=[],sessionItems=[];
        const response={selection:{model:"model-a",effort:"low",contextTier:"default"},
          defaults:{model:"model-a",effort:"low",contextTier:"default"},revision:"revision-a",usesDefaults:true,
          models:[{id:"model-a",reasoningEfforts:["low","high"],contextTiers:["default","long_context"],contextWindow:1050000,longContextPromptTokens:1050000},
                  {id:"model-b",reasoningEfforts:[],contextTiers:["default"]}],isRefreshing:false};
        let tierCalls=[];const tiers={tiers:["fast","standard","deep"],revision:"tiers-a",backends:[{id:"Copilot",label:"Copilot",
          models:[{id:"model-a",label:"model-a",efforts:["low","high"],price:"10 in · 50 out credits per 1M tokens"},{id:"model-b",label:"model-b",efforts:[]}],
          cells:[{tier:"fast",label:"Fast",choices:[{model:"model-b",effort:""}],isDefault:true,model:"model-b",effort:""},
                 {tier:"standard",label:"Standard",choices:[{model:"model-a",effort:"low"}],isDefault:true,model:"model-a",effort:"low"},
                 {tier:"deep",label:"Deep",choices:[{model:"model-a",effort:"high"},{model:"gone-1",effort:""}],isDefault:false,
                  model:"model-a",effort:"high",note:"gone-1 isn't offered"}]}]};
        function api(path,options){const body=options?JSON.parse(options.body):null;
          if(path==="/api/v1/model-tiers"){tierCalls.push(body);return Promise.resolve(body?{...tiers,revision:`tiers-${tierCalls.length}`}:tiers)}
          if(path==="/api/v1/usage-fallback"){fallbackCalls.push(body);
            if(body?.entries)return Promise.resolve({...fallbackState,entries:body.entries,backends:body.entries.map(item=>item.backend),revision:`pm-${fallbackCalls.length}`});
            return Promise.resolve(body?{...fallback,backends:body.backends,backend:body.backends[0]??"",limited:[],revision:`fallback-${fallbackCalls.length}`}:fallback)}
          calls.push({path,body});return Promise.resolve(response)}
        function refresh(){return Promise.resolve()}
        \(source[start.lowerBound..<end.lowerBound])
        editModelSettings({id:"tab-a",title:"Fixture"});
        """)
        precondition(context.evaluateScript("modelEditorState.data.revision")!.toString() == "revision-a")
        context.evaluateScript("""
        $("modelDefaults").checked=false;$("modelDefaults").onchange();
        $("modelEffort").value="high";$("modelEffort").onchange();
        $("modelContext").value="long_context";$("modelContext").onchange();
        selected="tab-b";$("modelForm").onsubmit({preventDefault(){}});
        """)
        precondition(context.evaluateScript("calls[1].path")!.toString() == "/api/v1/sessions/tab-a/model-settings")
        precondition(context.evaluateScript("calls[1].body.effort==='high' && calls[1].body.contextTier==='long_context'")!.toBool())
        precondition(context.evaluateScript("modelTokens(1050000)")!.toString() == "1.05M")
        // The Mac-wide fallbacks load with the sheet, name the limited backend and save on change.
        precondition(context.evaluateScript("""
        !$("fallbackBox").classList.hidden && $("fallbackAdd").children.length===3 && $("fallbackList").children.length===0
          && $("fallbackStatus").textContent==="At its usage limit: Claude Code until 5:00 AM." && !$("fallbackReset").classList.hidden
        """)!.toBool(), "The fallback section shows the choices and the limited backend")
        context.evaluateScript("""
        $("fallbackAdd").value="Copilot";$("fallbackAdd").onchange();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls.length===2 && fallbackCalls[1].backends.join()==="Copilot" && fallbackCalls[1].revision==="fallback-a"
          && fallbackState.revision==="fallback-2" && $("fallbackReset").classList.hidden
          && $("fallbackList").children.length===1 && $("fallbackAdd").children.length===2
        """)!.toBool(), "Adding a backend posts the chain with the loaded revision")
        // A second backup chains after the first; the arrows reorder and Remove drops one.
        context.evaluateScript("""
        $("fallbackAdd").value="Codex";$("fallbackAdd").onchange();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls[2].backends.join()==="Copilot,Codex" && fallbackCalls[2].revision==="fallback-2" && $("fallbackAdd").disabled
          && $("fallbackList").children[1].children[0].textContent==="Codex" && $("fallbackList").children[1].children[2].disabled
        """)!.toBool(), "Backups chain in the order they're added")
        context.evaluateScript("""
        $("fallbackList").children[1].children[1].onclick();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls[3].backends.join()==="Codex,Copilot" && $("fallbackList").children[0].children[0].textContent==="Codex"
          && $("fallbackList").children[0].children[1].attributes["aria-label"]==="Try Codex earlier"
        """)!.toBool(), "Moving a backup up posts the new order")
        context.evaluateScript("""
        $("fallbackList").children[0].children[3].onclick();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls[4].backends.join()==="Copilot" && $("fallbackList").children.length===1
        """)!.toBool(), "Remove drops that backup and keeps the rest")
        // A Mac with per-model backups: entries by position, and the Mac's own backend again with another model.
        context.evaluateScript("""
        fallbackState={backends:["Antigravity","Claude Code"],backend:"Antigravity",primary:"Antigravity",revision:"pm-0",
          entries:[{backend:"Antigravity",model:"flash",effort:"",label:"Antigravity · Flash"},
                   {backend:"Claude Code",model:"",effort:"",label:"Claude Code",limitedUntil:"2026-10-28T13:00:00Z",limitedUntilLabel:"6:00 AM"}],
          choices:[{id:"Claude Code",label:"Claude Code",models:[{id:"opus",label:"Opus",efforts:["high"]},{id:"sonnet",label:"Sonnet",efforts:[]}],
                    defaultModel:"Opus",defaultModelID:"opus"}],
          primaryChoice:{id:"Antigravity",label:"Antigravity · Argon",models:[{id:"argon",label:"Argon",efforts:[]},{id:"flash",label:"Flash",efforts:[]},
                         {id:"gpt",label:"GPT",efforts:[]}],defaultModel:"Argon",defaultModelID:"argon"},
          limited:[],limitedModels:[{backend:"Antigravity",scope:"argon",label:"Gemini 4 Argon",until:"2026-10-28T14:00:00Z",untilLabel:"7:00 AM"}]};
        fallbackCalls=[];renderFallback();
        """)
        precondition(context.evaluateScript("""
        $("fallbackList").children.length===2 && $("fallbackList").children[1].children[0].textContent==="Claude Code (at its limit until 6:00 AM)"
          && $("fallbackStatus").textContent.includes("Antigravity Gemini 4 Argon until 7:00 AM") && !$("fallbackReset").classList.hidden
          && $("fallbackAdd").children.map(option=>option.label).slice(1).join()==="Claude Code with another model,Antigravity with another model"
          && $("fallbackList").children[0].children[1].children.map(option=>option.value).join()==="flash,gpt"
        """)!.toBool(), "Rows show their own limits; models another entry runs (and the Mac's own) aren't offered again")
        context.evaluateScript("""
        $("fallbackAdd").value="Antigravity";$("fallbackAdd").onchange();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls.length===1 && fallbackCalls[0].revision==="pm-0" && fallbackCalls[0].entries.length===3
          && fallbackCalls[0].entries[2].backend==="Antigravity" && fallbackCalls[0].entries[2].model==="gpt"
          && $("fallbackList").children.length===3
        """)!.toBool(), "Adding the Mac's own backend again posts entries with a free model")
        context.evaluateScript("""
        $("fallbackList").children[2].children[2].onclick();
        """)
        precondition(context.evaluateScript("""
        fallbackCalls[1].entries.map(item=>item.backend+":"+item.model).join()==="Antigravity:flash,Antigravity:gpt,Claude Code:"
        """)!.toBool(), "Moving a row moves that entry, not every entry of its backend")
        context.evaluateScript("""
        editModelSettings({id:"tab-a",title:"Fixture"});
        """)
        context.evaluateScript("""
        $("modelDefaults").checked=false;$("modelDefaults").onchange();
        $("modelChoice").value="model-b";$("modelChoice").onchange();
        """)
        precondition(context.evaluateScript("modelEditorState.draft.effort==='' && modelEditorState.draft.contextTier==='default'")!.toBool())
        context.evaluateScript("""
        modelEditorState.draft.effort="high";renderModelSettings();
        """)
        precondition(context.evaluateScript("$('modelSave').disabled")!.toBool())

        // The Mac-wide tier map: each tier's models in order with Copilot's prices, saved per cell.
        precondition(context.evaluateScript("""
        !$("tierBox").classList.hidden && $("tierBackend").value==="Copilot" && $("tierCells").children.length===3
          && $("tierCells").children[2].children[0].textContent==="Deep: runs model-a · high"
          && $("tierCells").children[2].children[1].children[1].children[0].children[0].label==="gone-1 (not offered now)"
          && $("tierCells").children[1].children[1].children[0].children[0].children.map(option=>option.label).join("|")
             ==="model-a — 10 in · 50 out credits per 1M tokens|model-b"
          && $("tierCells").children[2].children[4].textContent==="Now: gone-1 isn't offered."
        """)!.toBool(), "The tier section lists each tier's models in order, with prices and what it runs now")
        context.evaluateScript("""
        fallbackCalls=[];tierCalls=[];const deepFirst=$("tierCells").children[2].children[1].children[0];
        deepFirst.children[1].value="low";deepFirst.children[1].onchange();
        """)
        precondition(context.evaluateScript("""
        tierCalls.length===1 && tierCalls[0].revision==="tiers-a" && tierCalls[0].backend==="Copilot" && tierCalls[0].tier==="deep"
          && tierCalls[0].choices.map(item=>item.model+"/"+item.effort).join()==="model-a/low,gone-1/" && tierState.revision==="tiers-1"
          && fallbackCalls.length===1
        """)!.toBool(), "Changing an effort posts that cell with the loaded revision, and the backups reload")
        context.evaluateScript("""
        $("tierCells").children[2].children[1].children[1].children[3].onclick();
        """)
        context.evaluateScript("""
        $("tierCells").children[2].children[3].onclick();
        """)
        precondition(context.evaluateScript("""
        tierCalls.length===3 && tierCalls[1].choices.map(item=>item.model).join()==="model-a"
          && tierCalls[2].reset===true && tierCalls[2].tier==="deep" && tierCalls[2].revision==="tiers-2"
        """)!.toBool(), "Remove drops a model from the tier and Reset returns the cell to its defaults")
    }
}
