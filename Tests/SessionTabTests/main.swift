import Foundation
import ImageIO
import JavaScriptCore
import UniformTypeIdentifiers

@main
struct SessionTabTests {
    @MainActor
    static func main() async throws {
        // Exec a fresh process so Foundation resolves every data path under the
        // temporary home before any app singleton or UserDefaults is created.
        guard ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil else {
            if ProcessInfo.processInfo.environment["CANTRIP_QUOTA_LIVE_TEST"] == "1" {
                let result = await withCheckedContinuation { continuation in
                    QuotaFetcher.fetchCopilotQuota { continuation.resume(returning: $0) }
                }
                let account = try result.get()
                precondition(!account.buckets.isEmpty)
                print("Live Copilot account: \(account.primary?.summary ?? "No primary allowance")")
            }
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
        try testNativeTabDragging()
        try await testTabReordering()
        try testPromptPaging()
        try await testPromptPreparation()
        try await testCopilotUsage()
        try await testRemoteRequestIsolation()
        try await testRemoteHistory()
        try await testJournalDelivery()
        try await testHostProtection(manager: manager)
        print("Session tab persistence, protection, privacy, and web controls passed")
    }

    static func testPromptPaging() throws {
        let text = String(repeating: "A long prompt 👩🏽‍💻 cafe\u{301}\n", count: 50_000)
        let prompt = PromptText(text)
        precondition(prompt.isLong && prompt.preview.count == PromptText.previewLimit)
        var restored = ""
        var start = text.startIndex
        while start < text.endIndex {
            let page = prompt.page(from: start)
            precondition(page.text.count <= PromptText.pageLimit && page.end > start)
            restored += page.text
            start = page.end
        }
        precondition(restored == text, "Paging must preserve every Unicode character")
        precondition(!PromptText(String(repeating: "x", count: 1_200)).isLong)
        precondition(PromptText(String(repeating: "x", count: 1_201)).isLong)

        let context = JSContext()!
        context.exceptionHandler = { _, error in
            fatalError("Prompt JavaScript failed: \(error?.toString() ?? "")")
        }
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let from = source.range(of: "    function promptSlice")!
        let to = source.range(of: "    function render(session,", range: from.upperBound..<source.endIndex)!
        context.evaluateScript("""
        const elements={};
        function node(){return {textContent:"",children:[],append(...items){this.children.push(...items)},
          addEventListener(){},showModal(){},close(){}}}
        const $=id=>elements[id]||(elements[id]=node()),document={createElement:node};
        \(source[from.lowerBound..<to.lowerBound])
        const longText="x".repeat(1199)+"👩🏽‍💻"+"\\n**plain text**".repeat(100000);
        const parent=node();appendPrompt(parent,longText);
        if(parent.children[0].textContent.length>1200||parent.children.length!==2)throw Error("Unbounded preview");
        parent.children[1].onclick();
        let restored=$("promptPage").textContent;
        while(!$("promptNext").disabled){$("promptNext").onclick();if($("promptPage").textContent.length>4000)throw Error("Unbounded page");restored+=$("promptPage").textContent}
        if(restored!==longText)throw Error("Prompt data lost");
        """)
    }

    @MainActor
    static func testPromptPreparation() async throws {
        let settings = AppSettings.shared
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vault = home.appendingPathComponent("prompt-fixture")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let note = String(repeating: "swift actor network\n\n", count: 10_000)
        try note.write(to: vault.appendingPathComponent("fixture.md"), atomically: true, encoding: .utf8)
        settings.memoryPath = vault.path
        settings.memoryEnabled = true
        settings.backend = .copilot
        settings.copilotPath = "/usr/bin/false"
        settings.attachScreen = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false
        settings.shareLocation = false

        let text = String(repeating: "swift actor network ", count: 50_000) + "End."
        let chat = ChatSession()
        let start = Date()
        chat.submitRemote(text)
        precondition(Date().timeIntervalSince(start) < 0.5, "Submission must yield before memory retrieval")
        precondition(chat.statusText == "Preparing context..." && chat.isStreaming)
        precondition(chat.messages.first?.text == text)
        chat.submitRemote("Additional details", mode: .inject)
        precondition(chat.queued.first?.text == "Additional details")
        chat.cancel()
        let countAfterCancel = chat.messages.count

        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { return }
                ticks += 1
            }
        }
        let block = await MemoryStore.contextBlock(
            query: text, path: vault.path, isPrivate: true, isLocal: false
        )
        heartbeat.cancel()
        precondition(ticks > 0, "Main actor must remain responsive during memory preparation")
        precondition(block.contains("fixture.md") && block.contains("READ-ONLY"))
        precondition(!chat.isStreaming && chat.messages.count == countAfterCancel,
                     "Cancelled preparation must not start a backend or append late events")
        precondition(chat.queued.isEmpty)
        precondition(MemoryStore.score("swift swift network", terms: ["swift", "network"]) == 3)
    }

    @MainActor
    static func testHostProtection(manager: SessionManager) async throws {
        let chat = manager.newSession()
        try chat.updateTab(name: "Host tab", isLocked: true)
        var quotaCalls = 0
        let usage = UsageTracker(quotaLoader: { completion in
            quotaCalls += 1
            completion(.failure(CopilotQuotaError.authentication))
        })
        let server = RemoteControlServer(manager: manager, usage: usage)
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
        let (page, pageResponse) = try await URLSession.shared.data(from: base)
        precondition((pageResponse as! HTTPURLResponse).statusCode == 200)
        try await testRemoteTabScrolling(html: String(decoding: page, as: UTF8.self), baseURL: base)
        let buildsPath = "api/v1/github/builds"
        let unauthorizedBuilds = try await request(buildsPath, method: "GET", authenticated: false)
        precondition(unauthorizedBuilds.0 == 401)
        try await expectStatus(405, buildsPath)
        let builds = try await request(buildsPath, method: "GET")
        precondition(builds.0 == 200 && builds.1["isRefreshing"] is Bool)
        precondition(builds.1["repositories"] is [Any])
        let usagePath = "api/v1/copilot/usage"
        let unauthorizedUsage = try await request(usagePath, method: "GET", authenticated: false)
        precondition(unauthorizedUsage.0 == 401 && quotaCalls == 0)
        try await expectStatus(405, usagePath)
        precondition(quotaCalls == 0)
        let quota = try await request(usagePath, method: "GET")
        precondition(quota.0 == 200 && quota.1["isRefreshing"] as? Bool == true)
        let failedQuota = try await request(usagePath, method: "GET")
        precondition(failedQuota.1["error"] as? String == CopilotQuotaError.authentication.localizedDescription)
        precondition(failedQuota.1["account"] == nil && quotaCalls == 1)
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
        let longPrompt = String(repeating: "Long prompt 👩🏽‍💻\n", count: 30_000) + "End."
        chat.isStreaming = true
        let upload = try JSONSerialization.data(withJSONObject: ["text": longPrompt, "mode": "queue"])
        let accepted = try await request(path + "/messages", body: String(decoding: upload, as: UTF8.self))
        precondition(accepted.0 == 202 && chat.queued.last?.text == longPrompt)
        let queued = (accepted.1["session"] as! [String: Any])["queued"] as! [[String: Any]]
        precondition(queued.last?["text"] as? String == longPrompt,
                     "Long prompts must round-trip intact through the live server")
        precondition(queued.last?["displayText"] == nil && queued.last?["images"] == nil,
                     "Do not double the payload of ordinary long prompts")
        let health = try await request("health", method: "GET", authenticated: false)
        precondition(health.0 == 200)
        let pixels = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let imageData = NSMutableData()
        let imageDestination = CGImageDestinationCreateWithData(imageData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(imageDestination, pixels.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(imageDestination))
        let imageUpload = try JSONSerialization.data(withJSONObject: [
            "text": "Look at this", "mode": "queue",
            "images": [["data": (imageData as Data).base64EncodedString()]],
        ])
        let imageAccepted = try await request(path + "/messages", body: String(decoding: imageUpload, as: UTF8.self))
        precondition(imageAccepted.0 == 202)
        let imageQueue = (imageAccepted.1["session"] as! [String: Any])["queued"] as! [[String: Any]]
        let queuedImage = imageQueue.last!
        precondition(queuedImage["displayText"] as? String == "Look at this")
        precondition((queuedImage["text"] as! String).contains("(Attached image: "))
        let imageID = (queuedImage["images"] as! [[String: String]])[0]["id"]!
        let imagePath = path + "/attachments/" + imageID
        let unauthorizedImage = try await request(imagePath, method: "GET", authenticated: false)
        precondition(unauthorizedImage.0 == 401)
        try await expectStatus(405, imagePath)
        let fullImage = try await request(imagePath, method: "GET")
        precondition(fullImage.0 == 200 && fullImage.1["data"] as? String == (imageData as Data).base64EncodedString())
        let thumbnail = try await request(imagePath + "/thumbnail", method: "GET")
        let thumbnailData = Data(base64Encoded: thumbnail.1["data"] as! String)!
        let source = CGImageSourceCreateWithData(thumbnailData as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        chat.messages.append(ChatMessage(role: .user, text: chat.queued.last!.text))
        let imageDetail = try await request(path, method: "GET").1["session"] as! [String: Any]
        let imageMessage = (imageDetail["messages"] as! [[String: Any]]).last!
        precondition(imageMessage["displayText"] as? String == "Look at this")
        precondition((imageMessage["images"] as! [[String: String]])[0]["id"] == imageID)
        chat.isPrivate = true
        let privateImage = try await request(imagePath, method: "GET")
        precondition(privateImage.0 == 404)
        chat.isPrivate = false
        let wrongSession = try await request("api/v1/sessions/\(manager.sessions[0].id)/attachments/" + imageID, method: "GET")
        precondition(wrongSession.0 == 404)
        let missingImage = try await request(path + "/attachments/\(UUID())/image-1.jpg", method: "GET")
        precondition(missingImage.0 == 404)
        chat.cancel()
        let retainedImage = try await request(imagePath, method: "GET")
        precondition(retainedImage.0 == 200, "Transcript attachments survive queue draining")
        chat.messages.removeAll()
        let removedImage = try await request(imagePath, method: "GET")
        precondition(removedImage.0 == 404, "Orphan files cannot be fetched without a live transcript or queue reference")
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
        let start = source.range(of: "    let editingTab")!
        let end = source.range(of: "    function safeURL", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in
            fatalError("Tab JavaScript failed: \(error?.toString() ?? "")")
        }
        context.evaluateScript("""
        const elements={};
        function node(){return {children:[],value:"",checked:false,disabled:false,
          classList:{toggle(){}},
          append(...items){this.children.push(...items)},replaceChildren(){this.children=[]},
          setAttribute(){},addEventListener(){},showModal(){this.open=true},close(){this.open=false},focus(){},select(){}}}
        const $=id=>elements[id]||(elements[id]=node());
        const document={createElement:node};let selected="a",renderedPayload="",calls=[];
        let sessionItems=[],movingTab=false,tabOrderRevision=0,token="test",sidebarLayout=false;
        function refresh(){return Promise.resolve()}
        function closeSession(id){calls.push({close:id})}
        function api(path,options){calls.push({path,body:JSON.parse(options.body)});return Promise.resolve({})}
        \(source[start.lowerBound..<end.lowerBound])
        const tab={id:"a",title:"Automatic",customTitle:"",isLocked:true,supportsTabMetadata:true};
        """)
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
    }
}
