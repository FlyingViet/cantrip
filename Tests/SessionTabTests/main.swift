import Foundation
import JavaScriptCore

@main
struct SessionTabTests {
    @MainActor
    static func main() async throws {
        // Exec a fresh process so Foundation resolves every data path under the
        // temporary home before any app singleton or UserDefaults is created.
        guard ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil else {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cantrip-tab-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["HOME"] = home.path
            environment["CANTRIP_TAB_TEST_HOME"] = home.path
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        }
        let home = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"]!
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
        precondition(SessionManager.chatsDir.path.hasPrefix(home + "/"))

        var metadata = SessionTabMetadata()
        try metadata.rename("  Work\n  tab  ")
        precondition(metadata.customTitle == "Work tab")
        do {
            try metadata.rename(String(repeating: "a", count: 81))
            preconditionFailure("Oversized names must fail")
        } catch SessionTabError.nameTooLong {}
        precondition(metadata.customTitle == "Work tab")
        try metadata.rename(" \n ")
        precondition(metadata.customTitle == nil)
        try metadata.rename(String(repeating: "a", count: 80))
        precondition(metadata.customTitle?.count == 80)

        let manager = SessionManager()
        let chat = manager.active
        chat.messages = [ChatMessage(role: .user, text: "Original prompt")]
        try chat.updateTab(name: "My project", isLocked: true)
        let restored = ChatSession(id: chat.id)
        precondition(restored.title == "My project" && restored.isLocked)
        precondition(restored.messages == chat.messages)
        chat.isStreaming = true
        manager.closeSelectedTab()
        precondition(manager.sessions.first?.id == chat.id && chat.isStreaming)
        precondition(manager.tabActionError != nil)
        chat.newConversation()
        precondition(chat.messages.count == 1 && chat.isStreaming)
        precondition(chat.tabActionError != nil)
        chat.isStreaming = false
        try chat.updateTab(isLocked: false)
        manager.closeSelectedTab()
        precondition(!manager.sessions.contains { $0.id == chat.id })
        precondition(manager.archivedSessions().first?.title == "My project")
        try chat.updateTab(isLocked: true)
        manager.deleteArchived(chat.id)
        precondition(manager.archivedSessions().contains { $0.id == chat.id })
        manager.restore(chat.id)
        precondition(manager.active.title == "My project" && manager.active.isLocked)
        try manager.active.updateTab(name: "", isLocked: false)
        precondition(manager.active.title == "Original prompt")

        let empty = manager.newSession()
        try empty.updateTab(name: "Empty saved tab", isLocked: true)
        let afterRelaunch = SessionManager()
        precondition(afterRelaunch.sessions.contains {
            $0.id == empty.id && $0.title == "Empty saved tab" && $0.isLocked
        })
        empty.isPrivate = true
        try empty.updateTab(name: "Secret name")
        precondition(SessionTabMetadata.load(id: empty.id).customTitle == nil)
        precondition(!FileManager.default.fileExists(
            atPath: SessionManager.chatsDir.appendingPathComponent("\(empty.id).json").path
        ))
        precondition(empty.title == "Secret name" && empty.isLocked)
        empty.isPrivate = false
        precondition(ChatSession(id: empty.id).title == "Secret name")

        let historyID = UUID()
        let historyURL = SessionManager.chatsDir.appendingPathComponent("\(historyID).json")
        let history = (0..<50).map { ChatMessage(role: .user, text: "Message \($0)") }
        let historyData = try JSONEncoder().encode(history)
        try historyData.write(to: historyURL)
        let historyChat = ChatSession(id: historyID)
        try historyChat.updateTab(name: "Long conversation", isLocked: true)
        let preservedHistory = try Data(contentsOf: historyURL)
        precondition(preservedHistory == historyData, "Metadata changes must not truncate existing transcripts")

        try testWebTabControls()
        try await testHostProtection(manager: manager)
        print("Session tab persistence, protection, privacy, and web controls passed")
    }

    @MainActor
    static func testHostProtection(manager: SessionManager) async throws {
        let chat = manager.newSession()
        try chat.updateTab(name: "Host tab", isLocked: true)
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        func request(_ path: String, method: String = "POST", body: String? = nil,
                     authenticated: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.timeoutInterval = 3
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = body.map { Data($0.utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        func expectStatus(_ expected: Int, _ path: String, body: String? = nil,
                          authenticated: Bool = true) async throws {
            let response = try await request(path, body: body, authenticated: authenticated)
            precondition(response.0 == expected, "\(path): expected \(expected), got \(response.0)")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let path = "api/v1/sessions/\(chat.id)"
        try await expectStatus(409, path + "/close")
        try await expectStatus(409, path + "/new-conversation")
        precondition(manager.sessions.contains { $0.id == chat.id })
        try await expectStatus(401, path + "/metadata", body: #"{"isLocked":false}"#, authenticated: false)
        for body in [#"{"isLocked":1}"#, #"{"isLocked":"false"}"#,
                     #"{"customTitle":null}"#, #"{"unknown":true}"#,
                     #"{"customTitle":"Changed","isLocked":null}"#] {
            try await expectStatus(400, path + "/metadata", body: body)
            precondition(chat.title == "Host tab" && chat.isLocked)
        }
        try await expectStatus(200, path + "/metadata", body: #"{"customTitle":"Renamed"}"#)
        precondition(chat.title == "Renamed" && chat.isLocked)
        let detail = try await request(path, method: "GET").1["session"] as! [String: Any]
        precondition(detail["isLocked"] as? Bool == true && detail["customTitle"] as? String == "Renamed")
        precondition(detail["supportsTabMetadata"] as? Bool == true)
        try await expectStatus(200, path + "/metadata", body: #"{"isLocked":false}"#)
        for other in manager.sessions where other.id != chat.id { other.isPrivate = true }
        try await expectStatus(200, path + "/close")
        precondition(!manager.sessions.contains { $0.id == chat.id })
        precondition(manager.sessions.contains { !$0.isPrivate },
                     "Closing the last public session must not return a private replacement")
    }

    @MainActor
    static func testWebTabControls() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    function renderSessions")!
        let end = source.range(of: "    function safeURL", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in
            fatalError("Tab JavaScript failed: \(error?.toString() ?? "")")
        }
        context.evaluateScript("""
        const elements={};
        function node(){return {children:[],value:"",checked:false,disabled:false,
          append(...items){this.children.push(...items)},replaceChildren(){this.children=[]},
          setAttribute(){},addEventListener(){},showModal(){this.open=true},close(){this.open=false},focus(){},select(){}}}
        const $=id=>elements[id]||(elements[id]=node());
        const document={createElement:node};let selected="a",renderedPayload="",calls=[];
        function refresh(){return Promise.resolve()}
        function closeSession(id){calls.push({close:id})}
        function api(path,options){calls.push({path,body:JSON.parse(options.body)});return Promise.resolve({})}
        \(source[start.lowerBound..<end.lowerBound])
        const tab={id:"a",title:"Automatic",customTitle:"",isLocked:true,supportsTabMetadata:true};
        renderSessions([tab]);
        """)
        precondition(context.evaluateScript("$('sessions').children[0].children[1].disabled")!.toBool())
        context.evaluateScript("""
        editTab(tab);$("tabName").value="My project";$("tabForm").onsubmit({preventDefault(){}});
        """)
        precondition(context.evaluateScript("calls[0].path")!.toString() == "/api/v1/sessions/a/metadata")
        precondition(context.evaluateScript("calls[0].body.customTitle")!.toString() == "My project")
        precondition(context.evaluateScript("!('isLocked' in calls[0].body)")!.toBool())
        context.evaluateScript("""
        editTab(tab);$("tabLocked").checked=false;$("tabForm").onsubmit({preventDefault(){}});
        """)
        precondition(context.evaluateScript("calls[1].body.isLocked === false && !('customTitle' in calls[1].body)")!.toBool())
        context.evaluateScript("""
        renderSessions([{id:"legacy",title:"Old host"}]);
        """)
        precondition(context.evaluateScript("$('sessions').children[0].children.length === 2")!.toBool())
    }
}
