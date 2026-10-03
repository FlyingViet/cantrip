import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

@MainActor
private final class GeneratedImagePageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
}

extension SessionTabTests {
    @MainActor
    static func testRemoteGeneratedImages() async throws {
        let manager = SessionManager()
        let chat = manager.active
        let messageID = UUID()
        let source = RemoteGeneratedImages.sourceRoot.appendingPathComponent("generated-test.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        try (output as Data).write(to: source)
        let markdown = "## Preview\n\n![Landscape](\(source.path))\n\nAfter the image."
        var message = ChatMessage(role: .assistant, text: markdown)
        message.id = messageID
        chat.messages = [ChatMessage(role: .user, text: "Show a preview"), message]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func request(_ suffix: String, sessionID: UUID? = nil, auth: Bool = true,
                     method: String = "GET") async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string:
                "http://127.0.0.1:\(port)/api/v1/sessions/\(sessionID ?? chat.id)\(suffix)")!)
            request.httpMethod = method
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let reference = RemoteGeneratedImages.presentation(markdown, messageID: messageID).images[0]
        for suffix in ["", "?history=recent", "/messages/\(messageID)"] {
            let result = try await request(suffix)
            precondition(result.0 == 200)
            let snapshot: [String: Any]
            if suffix.hasPrefix("/messages/") { snapshot = result.1["message"] as! [String: Any] }
            else {
                snapshot = ((result.1["session"] as! [String: Any])["messages"] as! [[String: Any]]).last!
            }
            precondition(snapshot["text"] as? String == markdown, "Never rewrite durable agent text")
            precondition((snapshot["displayText"] as? String)?.contains(reference.markdownURL) == true)
            precondition((snapshot["images"] as! [[String: String]]) == [reference.snapshot])
        }
        let path = "/" + reference.id
        let unauthorized = try await request(path, auth: false)
        precondition(unauthorized.0 == 401)
        let wrongMethod = try await request(path, method: "POST")
        precondition(wrongMethod.0 == 405)
        let full = try await request(path)
        precondition(full.0 == 200)
        let bytes = Data(base64Encoded: full.1["data"] as! String)!
        precondition(CGImageSourceCreateWithData(bytes as CFData, nil) != nil)
        let thumbnail = try await request(path + "/thumbnail")
        precondition(thumbnail.0 == 200)
        try await checkBrowserImages(chat: chat, reply: message, markdown: markdown, port: port, token: token)
        chat.messages = [ChatMessage(role: .user, text: "Show a preview"), message]
        let other = manager.newSession()
        let foreign = try await request(path, sessionID: other.id)
        precondition(foreign.0 == 404)
        let privateLocal = manager.sessions.first(where: \.isLocalPrivate)!
        privateLocal.messages = [message]
        let localImage = try await request(path, sessionID: privateLocal.id)
        precondition(localImage.0 == 404, "Private Local must not expose file references emitted by its model")
        let localDetail = try await request("", sessionID: privateLocal.id)
        let localSnapshot = ((localDetail.1["session"] as! [String: Any])["messages"] as! [[String: Any]]).last!
        precondition(localSnapshot["displayText"] == nil && localSnapshot["images"] == nil)
        chat.isPrivate = true
        let hidden = try await request(path)
        precondition(hidden.0 == 404)
        chat.isPrivate = false
        chat.messages = [ChatMessage(role: .user, text: markdown)]
        let userOnly = try await request(path)
        precondition(userOnly.0 == 404, "User-supplied paths must not authorize generated previews")
        chat.messages = [message]
        try FileManager.default.removeItem(at: source)
        let retained = try await request(path)
        precondition(retained.0 == 200 && retained.1["data"] as? String == full.1["data"] as? String)
        chat.messages = []
        let removed = try await request(path)
        precondition(removed.0 == 404, "Cached files still require a current assistant-message reference")
        precondition(message.text == markdown)
        try await checkSessionFilesFolder(manager: manager, request: { try await request($0, sessionID: $1, auth: $2, method: $3) },
                                          port: port, token: token)
        print("Generated previews: paired reads, message ownership, history, privacy, durable images and browser previews/viewer passed")
    }

    /// A tab's own Copilot files folder (and its subfolders) previews remotely; another tab
    /// quoting the same path gets nothing, and links open the full-size viewer.
    @MainActor
    private static func checkSessionFilesFolder(
        manager: SessionManager,
        request: (String, UUID?, Bool, String) async throws -> (Int, [String: Any]),
        port: Int, token: String
    ) async throws {
        let owner = manager.newSession(), other = manager.newSession()
        let cli = UUID().uuidString.lowercased()
        let files = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state/\(cli)/files/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let image = files.appendingPathComponent("niteharts header.png")
        let context = CGContext(data: nil, width: 943, height: 2048, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.1, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 943, height: 2048))
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        try (png as Data).write(to: image)
        let markdown = "Here it is:\n\n![Niteharts header](\(image.absoluteString))\n\n"
            + "[Open the full-size preview](\(image.absoluteString))"
        var reply = ChatMessage(role: .assistant, text: markdown)
        let replyID = UUID()
        reply.id = replyID
        for chat in [owner, other] { chat.messages = [ChatMessage(role: .user, text: "Show me"), reply] }

        func snapshot(_ id: UUID) async throws -> [String: Any] {
            let result = try await request("", id, true, "GET")
            precondition(result.0 == 200)
            return ((result.1["session"] as! [String: Any])["messages"] as! [[String: Any]]).last!
        }
        let unrecorded = try await snapshot(owner.id)
        precondition(unrecorded["images"] == nil, "unrecorded folders are not previewable")
        SessionOutputFolders.shared.record(cli, for: owner.id)
        let owned = try await snapshot(owner.id)
        let images = owned["images"] as! [[String: String]]
        precondition(images.count == 1 && images[0]["altText"] == "Niteharts header", "\(owned)")
        let previewURL = "cantrip-preview://image/\(images[0]["id"]!)"
        precondition(owned["displayText"] as? String == "Here it is:\n\n![Niteharts header](\(previewURL))\n\n"
                     + "[Open the full-size preview](\(previewURL))", "image and link share the preview")
        let path = "/" + images[0]["id"]!
        let full = try await request(path, owner.id, true, "GET")
        precondition(full.0 == 200)
        let size = CGImageSourceCopyPropertiesAtIndex(
            CGImageSourceCreateWithData(Data(base64Encoded: full.1["data"] as! String)! as CFData, nil)!, 0, nil
        )! as NSDictionary
        precondition(size[kCGImagePropertyPixelHeight] as? Int == 2048)
        let foreign = try await snapshot(other.id)
        precondition(foreign["images"] == nil && foreign["displayText"] == nil,
                     "another tab quoting the same folder gets no preview")
        let denied = try await request(path, other.id, true, "GET")
        precondition(denied.0 == 404, "another tab cannot read the owner's preview")
        try await checkBrowserPreviewLink(chat: owner, port: port, token: token)
        try await checkQuestionImages(owner: owner, other: other, image: image, request: request,
                                      port: port, token: token)
        manager.close(owner.id)
        precondition(SessionOutputFolders.shared.roots(for: owner.id).count == 1, "closing a tab keeps history previews")
        owner.deleteTranscript()
        precondition(SessionOutputFolders.shared.roots(for: owner.id).isEmpty, "deleting a tab forgets its folders")
        try? FileManager.default.removeItem(at: files.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// "Copilot needs your answer" questions preview images from the tab's files folder in the
    /// pending request (chat card and composer panel), and the answered copy keeps the same IDs.
    @MainActor
    private static func checkQuestionImages(
        owner: ChatSession, other: ChatSession, image: URL,
        request: (String, UUID?, Bool, String) async throws -> (Int, [String: Any]),
        port: Int, token: String
    ) async throws {
        let detail = "The audit is done.\n\n**Light — before**\n![Calendar before, light mode](\(image.path))\n\n"
            + "Should I ship it?"
        let question = InputRequestSnapshot(
            id: UUID(), kind: .question, source: "Copilot", title: "Copilot needs your answer", detail: detail,
            choices: ["Ship", "Hold"], expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970
        )
        owner.pendingInputs = [question]
        other.pendingInputs = [question]
        func pending(_ id: UUID) async throws -> [String: Any] {
            let result = try await request("", id, true, "GET")
            precondition(result.0 == 200)
            return ((result.1["session"] as! [String: Any])["pendingInputs"] as! [[String: Any]])[0]
        }
        let owned = try await pending(owner.id)
        let images = owned["images"] as? [[String: String]] ?? []
        let imageID = images.first?["id"] ?? ""
        precondition(images.count == 1 && images[0]["altText"] == "Calendar before, light mode"
                     && imageID.hasPrefix("previews/\(question.id.uuidString)/") && owned["detail"] as? String == detail
                     && owned["displayText"] as? String == "The audit is done.\n\n**Light — before**\n\n"
                        + "![Calendar before, light mode](cantrip-preview://image/\(imageID))\n\nShould I ship it?",
                     "a pending question previews its tab's images as their own blocks: \(owned)")
        let listing = try await request("/input", owner.id, true, "GET")
        let listed = (listing.1["requests"] as? [[String: Any]])?.first
        precondition((listed?["images"] as? [[String: String]]) == images
                     && listed?["displayText"] as? String == owned["displayText"] as? String,
                     "the input listing used by older clients carries the same previews")
        let thumbnail = try await request("/\(imageID)/thumbnail", owner.id, true, "GET")
        precondition(thumbnail.0 == 200, "the question's preview is served by its own tab")
        let foreign = try await pending(other.id)
        precondition(foreign["images"] == nil && foreign["displayText"] == nil,
                     "another tab's question naming the same folder gets no previews")
        let denied = try await request("/\(imageID)", other.id, true, "GET")
        precondition(denied.0 == 404, "another tab cannot read the question's preview")
        owner.pendingInputs = [InputRequestSnapshot(
            id: question.id, kind: .approval, source: "Copilot", title: "Allow shell?", detail: detail,
            expiresAt: question.expiresAt
        )]
        let approval = try await pending(owner.id)
        let approvalImage = try await request("/\(imageID)", owner.id, true, "GET")
        precondition(approval["images"] == nil && approvalImage.0 == 404,
                     "approvals stay verbatim: their details are commands, not replies")
        owner.pendingInputs = [question]
        other.pendingInputs = []
        try await checkBrowserQuestionImages(chat: owner, port: port, token: token)
        owner.pendingInputs = []
        let answeredBefore = try await request("/\(imageID)", owner.id, true, "GET")
        precondition(answeredBefore.0 == 404, "a question no longer waiting authorizes nothing")
        owner.recordInputConversation(question, answer: "Ship")
        let echo = owner.messages.first { $0.id == question.id }
        let echoed = try await request("/\(imageID)/thumbnail", owner.id, true, "GET")
        precondition(echo?.role == .assistant && echo?.text == "Copilot needs your answer\n\n\(detail)"
                     && echoed.0 == 200 && echoed.1["data"] as? String == thumbnail.1["data"] as? String,
                     "the answered question's transcript copy keeps the request's preview IDs")
        owner.messages.removeAll { $0.id == question.id || $0.role == .user && $0.text == "Ship" || $0.text.isEmpty }
    }

    /// Browser and Mac Remote: the chat card renders the question as Markdown with its images
    /// in a compact row, never as raw paths or "Image on the Mac" notes.
    @MainActor
    private static func checkBrowserQuestionImages(chat: ChatSession, port: Int, token: String) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = GeneratedImagePageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let json = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`),wait=ms=>new Promise(r=>setTimeout(r,ms));render(data.session);
        const card=()=>document.querySelector('.input-card'),thumb=()=>card()?.querySelector('.input-images .mac-image img');
        for(let i=0;i<60&&!thumb()?.naturalWidth;i++)await wait(100);
        const detail=card()?.querySelector('.input-detail'),button=card()?.querySelector('.input-images .mac-image');
        const box=button?.getBoundingClientRect(),choices=[...(card()?.querySelectorAll('button.control')||[])].map(b=>b.textContent);
        button?.click();for(let i=0;i<60&&$("imageFull").naturalHeight!==2048;i++)await wait(100);
        const result={strong:detail?.querySelector('strong')?.textContent||'',text:detail?.textContent||'',
          caption:card()?.querySelector('.input-image figcaption')?.textContent||'',
          thumb:thumb()?.naturalWidth||0,height:Math.round(box?.height||0),label:button?.getAttribute('aria-label')||'',choices,
          open:$("imageViewer").open,full:$("imageFull").naturalHeight,title:$("imageViewerTitle").textContent};
        $("imageDone").click();return JSON.stringify(result);
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page) as? String ?? "{}"
        let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        let text = result["text"] as? String ?? ""
        precondition(text == "The audit is done.Should I ship it?" && result["strong"] as? String == ""
                     && result["caption"] as? String == "Light — before",
                     "the question renders as Markdown, and the label above the image captions it: \(result)")
        precondition(result["thumb"] as? Int ?? 0 > 0 && (1...130).contains(result["height"] as? Int ?? 0)
                     && result["label"] as? String == "Light — before. Open full size."
                     && (result["choices"] as? [String])?.starts(with: ["Ship", "Hold"]) == true,
                     "its image is a compact thumbnail ahead of the answers: \(result)")
        precondition(result["open"] as? Bool == true && result["full"] as? Int == 2048
                     && result["title"] as? String == "Light — before",
                     "the thumbnail opens the full-size viewer: \(result)")
        if let directory = ProcessInfo.processInfo.environment["CANTRIP_TEST_SNAPSHOT_DIR"] {
            _ = try await webView.evaluateJavaScript("document.querySelector('.input-card').scrollIntoView({block:'end'})")
            try await Task.sleep(for: .milliseconds(300))
            let snapshot = try await webView.takeSnapshot(configuration: nil)
            if let tiff = snapshot.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("web-question-card.png"))
            }
        }
    }

    /// Browser and Mac Remote: a link to a Mac image opens the full-size viewer.
    @MainActor
    private static func checkBrowserPreviewLink(chat: ChatSession, port: Int, token: String) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = GeneratedImagePageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 700), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let json = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`),wait=ms=>new Promise(r=>setTimeout(r,ms));render(data.session);
        const link=document.querySelector('#messages .preview-link'),anchors=[...document.querySelectorAll('#messages a')].map(a=>a.href);
        link?.click();for(let i=0;i<60&&$("imageFull").naturalHeight!==2048;i++)await wait(100);
        const result={text:link?.textContent||'',popup:link?.getAttribute('aria-haspopup')||'',anchors,open:$("imageViewer").open,
          height:$("imageFull").naturalHeight,title:$("imageViewerTitle").textContent};
        $("imageDone").click();return JSON.stringify(result);
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page) as? String ?? "{}"
        let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        precondition(result["text"] as? String == "Open the full-size preview" && result["popup"] as? String == "dialog"
                     && (result["anchors"] as? [String])?.isEmpty == true, "the link renders as a viewer button: \(result)")
        precondition(result["open"] as? Bool == true && result["height"] as? Int == 2048
                     && result["title"] as? String == "Niteharts header", "the link opens the full-size viewer: \(result)")
    }

    /// The browser (and Mac Remote tab) Remote shows previews and uploads inline
    /// from paired reads, never as broken local-path <img> requests.
    @MainActor
    private static func checkBrowserImages(chat: ChatSession, reply: ChatMessage, markdown: String,
                                           port: Int, token: String) async throws {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let uploads = RemoteImageAttachments.storageRoot.appendingPathComponent(chat.id.uuidString)
        defer { try? FileManager.default.removeItem(at: uploads) }
        let prompt = try RemoteImageAttachments.preparePrompt(
            "Compare with this", images: [RemoteImageUpload(data: jpeg as Data)], sessionID: chat.id)
        var withOtherImage = reply
        withOtherImage.text = markdown + "\n\n![Elsewhere](~/.cache/Cantrip/nested/other.png)"
        chat.messages = [ChatMessage(role: .user, text: prompt), withOtherImage]

        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = GeneratedImagePageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 700), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        // Load over HTTP so the page's real Content-Security-Policy applies to the images.
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        _ = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`);window.imageSession=data.session;render(data.session);
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page)
        func state() async throws -> [String: Any] {
            let json = try await webView.evaluateJavaScript("""
            (()=>{const preview=document.querySelector('#messages .mac-image.preview img'),upload=document.querySelector('#messages .mac-image.attachment img');
            return JSON.stringify({preview:preview?.naturalWidth||0,source:(preview?.getAttribute('src')||'').slice(0,23),upload:upload?.naturalWidth||0,
              local:[...document.querySelectorAll('#messages img')].filter(img=>!img.src.startsWith('data:image/jpeg;base64,')).length,
              unavailable:document.querySelector('#messages .image-unavailable')?.textContent||'',
              prompt:document.querySelector('#messages .message.user .prompt-preview')?.textContent||'',
              label:document.querySelector('#messages .mac-image.preview')?.getAttribute('aria-label')||'',
              failed:[...document.querySelectorAll('#messages .mac-image.failed')].map(el=>el.textContent)})})()
            """) as? String ?? "{}"
            return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        }
        var page: [String: Any] = [:]
        for _ in 0..<100 {
            page = try await state()
            if page["preview"] as? Int ?? 0 > 0, page["upload"] as? Int ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(page["preview"] as? Int == RemoteGeneratedImages.thumbnailDimension
                     && page["source"] as? String == "data:image/jpeg;base64,", "inline preview thumbnail: \(page)")
        precondition(page["upload"] as? Int == 320, "uploaded image thumbnail: \(page)")
        precondition(page["local"] as? Int == 0 && page["unavailable"] as? String == "Image on the Mac: Elsewhere",
                     "unserved Mac paths show their description instead of a broken image: \(page)")
        precondition(page["prompt"] as? String == "Compare with this", "upload markers stay out of the prompt: \(page)")
        precondition(page["label"] as? String == "Landscape. Open full size.", "\(page)")

        let viewer = try await webView.callAsyncJavaScript("""
        const wait=ms=>new Promise(r=>setTimeout(r,ms)),button=document.querySelector('#messages .mac-image.preview'),img=button.querySelector('img');
        button.click();for(let i=0;i<60&&$("imageFull").naturalWidth!==1600;i++)await wait(100);
        const opened={open:$("imageViewer").open,width:$("imageFull").naturalWidth,title:$("imageViewerTitle").textContent,focus:document.activeElement?.id};
        $("imageDone").click();
        const next=structuredClone(window.imageSession);next.status="Re-render fixture";render(next);
        return JSON.stringify({...opened,closed:!$("imageViewer").open,kept:document.querySelector('#messages .mac-image.preview img')===img});
        """, contentWorld: .page) as? String ?? "{}"
        let result = try JSONSerialization.jsonObject(with: Data(viewer.utf8)) as? [String: Any] ?? [:]
        precondition(result["open"] as? Bool == true && result["width"] as? Int == 1600
                     && result["title"] as? String == "Landscape" && result["focus"] as? String == "imageDone",
                     "the viewer opens the full-size image: \(result)")
        precondition(result["closed"] as? Bool == true && result["kept"] as? Bool == true,
                     "Done closes it, and re-renders keep the loaded preview element: \(result)")
    }
}
