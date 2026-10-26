import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

private final class RemoteFilePageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
}

extension SessionTabTests {
    static func fileDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func tinyJPEG() -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The listener binds asynchronously; wait until it answers instead of sleeping a fixed time.
    static func waitForRemoteServer(port: Int, client: URLSession) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<100 {
            if (try? await client.data(from: url)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        preconditionFailure("Remote server on \(port) never answered")
    }

    @MainActor
    static func testRemoteFiles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("file-tests-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Names never escape or hide inside the upload folder.
        precondition(RemoteFileAttachments.storedName("../../etc/passwd") == "etcpasswd")
        precondition(RemoteFileAttachments.storedName(".hidden.pdf") == "hidden.pdf")
        precondition(RemoteFileAttachments.storedName("  \n ") == "file")
        precondition(RemoteFileAttachments.storedName("upload.json") == "file-upload.json")
        precondition(RemoteFileAttachments.storedName(" UPLOAD.Json") == "file-UPLOAD.Json",
                     "No case variant may alias the manifest on a case-insensitive volume")
        let long = RemoteFileAttachments.storedName(String(repeating: "a", count: 300) + ".pdf")
        precondition(long.count == 120 && long.hasSuffix(".pdf"), long)

        // Resumable, verified chunks, like videos.
        let pdf = Data("%PDF-1.4\n".utf8) + Data(repeating: 7, count: 3 * RemoteFileAttachments.chunkBytes / 2)
        let info = RemoteFileUpload(totalBytes: pdf.count, name: "Q3 report.pdf", sha256: fileDigest(pdf),
                                    receivedBytes: 0)
        let store = RemoteFileAttachments(root: root)
        let session = UUID(), upload = UUID(), split = RemoteFileAttachments.chunkBytes
        let first = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                            upload: info, data: Data(pdf.prefix(split)))
        precondition(first.receivedBytes == split)
        let replay = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                             upload: info, data: Data(pdf.prefix(split)))
        precondition(replay == first, "A lost reply can be retried without appending twice")
        do {
            _ = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                         upload: info, data: Data(repeating: 1, count: split))
            preconditionFailure("Different bytes cannot replace a confirmed chunk")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        do {
            _ = try await store.claim(sessionID: session, uploadID: upload)
            preconditionFailure("Incomplete files cannot be sent")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        let restarted = RemoteFileAttachments(root: root)
        let resumed = try await restarted.status(sessionID: session, uploadID: upload)
        precondition(resumed.receivedBytes == split, "The durable offset survives a host restart")
        _ = try await restarted.receive(sessionID: session, uploadID: upload, offset: split,
                                        upload: info, data: Data(pdf.dropFirst(split)))
        let line = try await restarted.claim(sessionID: session, uploadID: upload)
        let saved = root.appendingPathComponent("\(session)/\(upload)/Q3 report.pdf")
        precondition(line == "(Attached file: \(saved.path) - read this file; it is part of my request.)", line)
        let savedBytes = try Data(contentsOf: saved)
        precondition(savedBytes == pdf, "The agent reads the exact original bytes")
        let again = try await restarted.claim(sessionID: session, uploadID: upload)
        precondition(again == line, "Claims are repeatable")
        do {
            _ = try await restarted.claim(sessionID: UUID(), uploadID: upload)
            preconditionFailure("Uploads are scoped to their owning session")
        } catch let error as RemoteVideoError { precondition(error.status == 404) }

        let corrupt = UUID()
        _ = try await store.receive(sessionID: session, uploadID: corrupt, offset: 0, upload: RemoteFileUpload(
            totalBytes: 4, name: "notes.txt", sha256: String(repeating: "0", count: 64), receivedBytes: 0
        ), data: Data("abcd".utf8))
        do {
            _ = try await store.claim(sessionID: session, uploadID: corrupt)
            preconditionFailure("Complete uploads still need their SHA-256 to match")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        for bad in [
            RemoteFileUpload(totalBytes: RemoteFileAttachments.maximumBytes + 1, name: "big.zip",
                             sha256: fileDigest(pdf), receivedBytes: 0),
            RemoteFileUpload(totalBytes: 4, name: "", sha256: fileDigest(pdf), receivedBytes: 0),
            RemoteFileUpload(totalBytes: 4, name: "bad\nname.txt", sha256: fileDigest(pdf), receivedBytes: 0),
        ] {
            do {
                _ = try await store.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: bad, data: Data("abcd".utf8))
                preconditionFailure("Reject invalid upload metadata: \(bad)")
            } catch let error as RemoteVideoError { precondition(error.status == 400) }
        }
        // Real names carry format characters (emoji joiners, RTL marks); they upload and claim.
        for name in ["Upload.JSON", "dev 👩\u{200D}💻 notes.txt", "\u{200F}חוזה.pdf"] {
            let bytes = Data(name.utf8), id = UUID()
            _ = try await store.receive(sessionID: session, uploadID: id, offset: 0, upload: RemoteFileUpload(
                totalBytes: bytes.count, name: name, sha256: fileDigest(bytes), receivedBytes: 0
            ), data: bytes)
            let claimed = try await store.claim(sessionID: session, uploadID: id)
            precondition(claimed.contains("/\(id)/\(RemoteFileAttachments.storedName(name)) - read"), claimed)
        }
        let linked = root.appendingPathComponent("\(session)/\(UUID())")
        try fm.createSymbolicLink(at: linked, withDestinationURL: fm.temporaryDirectory)
        do {
            _ = try await store.status(sessionID: session, uploadID: UUID(uuidString: linked.lastPathComponent)!)
            preconditionFailure("Never follow substituted upload directories")
        } catch let error as RemoteVideoError { precondition(error.status == 404) }

        // Unsent uploads share a budget; image folders (no manifest) never count or expire here.
        let quotaRoot = root.appendingPathComponent("quota")
        let quota = RemoteFileAttachments(root: quotaRoot)
        let imagePrompt = try RemoteImageAttachments.preparePrompt("look", images: RemoteImageAttachments.decode(
            [["data": tinyJPEG().base64EncodedString()]]), sessionID: session, root: quotaRoot)
        let imageID = RemoteImageAttachments.presentation(imagePrompt, sessionID: session, root: quotaRoot).imageIDs[0]
        let full = RemoteFileUpload(totalBytes: RemoteFileAttachments.maximumBytes, name: "big.bin",
                                    sha256: fileDigest(pdf), receivedBytes: 0)
        let pendingIDs = (0..<5).map { _ in UUID() }
        for id in pendingIDs {
            _ = try await quota.receive(sessionID: session, uploadID: id, offset: 0, upload: full, data: Data([0]))
        }
        do {
            _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: full, data: Data([0]))
            preconditionFailure("Unfinished uploads must be bounded")
        } catch let error as RemoteVideoError { precondition(error.status == 413) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                             ofItemAtPath: quotaRoot.appendingPathComponent("\(session)/\(pendingIDs[0])/upload.json").path)
        _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: full, data: Data([0]))
        precondition(!fm.fileExists(atPath: quotaRoot.appendingPathComponent("\(session)/\(pendingIDs[0])").path),
                     "Expired unsent uploads release their reservation")
        precondition((try? RemoteImageAttachments.read(id: imageID, sessionID: session, thumbnail: false, root: quotaRoot)) != nil,
                     "Image attachments in the same folder are left alone")

        // Clients see a readable line instead of the Mac path; images still become thumbnails.
        let prompt = try RemoteImageAttachments.preparePrompt(
            RemoteFileAttachments.prompt("", video: nil, files: [line], imageCount: 1),
            images: RemoteImageAttachments.decode([["data": tinyJPEG().base64EncodedString()]]),
            sessionID: session, root: root
        )
        let shown = RemoteImageAttachments.presentation(prompt, sessionID: session, root: root)
        precondition(shown.text == "Please look at the attached images and files.\n\n📎 Q3 report.pdf"
                     && shown.imageIDs.count == 1 && shown.fileNames == ["Q3 report.pdf"], shown.text)
        let foreign = "(Attached file: /etc/passwd - read this file; it is part of my request.)"
        precondition(!RemoteImageAttachments.presentation(foreign, sessionID: session, root: root).replacesText,
                     "Only our own upload folders are presented as attachments")
        precondition(RemoteFileAttachments.prompt("", video: nil, files: [line], imageCount: 0)
                     .hasPrefix("Please look at the attached file.\n\n"))
        precondition(RemoteFileAttachments.prompt("Summarize", video: "V", files: [line, line], imageCount: 0)
                     == "Summarize\n\nV\n\n\(line)\n\n\(line)")

        try await testRemoteFileMessages()
        try await testHandoffCardsOnWeb()
        print("Remote files: verified resumable uploads, sanitized names, shared budget, readable prompts, and mixed sends passed")
    }

    /// A message may carry images, a video and files together, and files reach the agent's prompt.
    @MainActor
    private static func testRemoteFileMessages() async throws {
        let fm = FileManager.default
        let settings = AppSettings.shared, oldBackend = settings.backend
        settings.backend = .copilot
        defer { settings.backend = oldBackend }
        let manager = SessionManager()
        manager.active.isStreaming = true
        let sessionID = manager.active.id
        defer {
            manager.active.isStreaming = false
            for root in [RemoteFileAttachments.storageRoot, RemoteVideoAttachments.storageRoot] {
                try? fm.removeItem(at: root.appendingPathComponent(sessionID.uuidString))
            }
        }
        let server = RemoteControlServer(manager: manager), port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await waitForRemoteServer(port: port, client: client)
        func request(_ suffix: String, method: String = "GET", body: Data? = nil,
                     query: [String: String] = [:], auth: Bool = true) async throws -> (Int, [String: Any]) {
            var url = URLComponents(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(sessionID)\(suffix)")!
            url.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!, timeoutInterval: 30)
            request.httpMethod = method; request.httpBody = body
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let (_, detail) = try await request("")
        let capabilities = detail["session"] as! [String: Any]
        precondition(capabilities["supportsFileAttachments"] as? Bool == true
                     && capabilities["supportsMixedAttachments"] as? Bool == true)

        let pdf = Data("%PDF-1.4 tiny".utf8), fileID = UUID()
        let query = ["offset": "0", "totalBytes": String(pdf.count), "name": "Lease.pdf", "sha256": fileDigest(pdf)]
        let (unauthorized, _) = try await request("/files/\(fileID)", method: "PUT", body: pdf, query: query, auth: false)
        precondition(unauthorized == 401)
        let (stored, upload) = try await request("/files/\(fileID)", method: "PUT", body: pdf, query: query)
        precondition(stored == 200 && (upload["upload"] as? [String: Any])?["receivedBytes"] as? Int == pdf.count
                     && manager.active.queued.isEmpty, "Uploading never sends a prompt")
        let (status, _) = try await request("/files/\(fileID)")
        precondition(status == 200)

        let videoBytes = try await videoFixture(at: fm.temporaryDirectory.appendingPathComponent("mixed-\(UUID()).mp4"))
        let videoID = UUID()
        let (videoStored, _) = try await request("/videos/\(videoID)", method: "PUT", body: videoBytes, query: [
            "offset": "0", "totalBytes": String(videoBytes.count), "format": "mp4", "name": "clip.mp4",
            "sha256": fileDigest(videoBytes),
        ])
        let (prepared, _) = try await request("/videos/\(videoID)/prepare", method: "POST")
        precondition(videoStored == 200 && prepared == 200)

        let tooMany = try JSONSerialization.data(withJSONObject: [
            "text": "x", "mode": "queue", "fileIDs": (0...RemoteFileAttachments.maximumCount).map { _ in UUID().uuidString },
        ])
        let tooManyStatus = try await request("/messages", method: "POST", body: tooMany).0
        precondition(tooManyStatus == 400)
        let command = try JSONSerialization.data(withJSONObject: ["text": "!ls", "mode": "queue", "fileIDs": [fileID.uuidString]])
        let commandStatus = try await request("/messages", method: "POST", body: command).0
        precondition(commandStatus == 400)
        let unknown = try JSONSerialization.data(withJSONObject: ["text": "x", "mode": "queue", "fileIDs": [UUID().uuidString]])
        let unknownStatus = try await request("/messages", method: "POST", body: unknown).0
        precondition(unknownStatus == 404 && manager.active.queued.isEmpty)

        let body = try JSONSerialization.data(withJSONObject: [
            "text": "What's in these?", "mode": "queue", "videoID": videoID.uuidString,
            "fileIDs": [fileID.uuidString], "images": [["data": tinyJPEG().base64EncodedString()]],
        ])
        let (sent, snapshot) = try await request("/messages", method: "POST", body: body)
        precondition(sent == 202 && manager.active.queued.count == 1, "mixed send: \(sent) \(snapshot)")
        let prompt = manager.active.queued[0].text
        let saved = RemoteFileAttachments.storageRoot.appendingPathComponent("\(sessionID)/\(fileID)/Lease.pdf")
        precondition(prompt.hasPrefix("What's in these?\n\nVideo attachment: \"clip.mp4\"")
                     && prompt.contains("(Attached file: \(saved.path) - read this file; it is part of my request.)")
                     && (try? Data(contentsOf: saved)) == pdf, prompt)
        let queued = ((snapshot["session"] as! [String: Any])["queued"] as! [[String: Any]])[0]
        precondition((queued["images"] as? [[String: Any]])?.count == 5, "four video frames and the photo")
        precondition((queued["displayText"] as? String)?.contains("📎 Lease.pdf") == true
                     && (queued["displayText"] as? String)?.contains(saved.path) == false)
        manager.active.isPrivate = true
        let privateStatus = try await request("/files/\(fileID)").0
        precondition(privateStatus == 404, "Private tabs never expose uploads")
        manager.active.isPrivate = false
    }

    /// The browser shows one card per handoff: once the tab reports back, its result card replaces
    /// the original card under Home's reply, and later states update that one card.
    @MainActor
    private static func testHandoffCardsOnWeb() async throws {
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager), port = Int.random(in: 49152...65535)
        server.start(port: port, token: UUID().uuidString)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await waitForRemoteServer(port: port, client: client)
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let (page, _) = try await client.data(from: base)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = RemoteFilePageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 700), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: base)
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let delegation = UUID().uuidString, other = UUID().uuidString, tab = UUID().uuidString
        let rendered = try await webView.callAsyncJavaScript("""
        const now=Date.now()/1000;
        const handoff=(id,status)=>({id,tabID:tab,tabTitle:"DropKart",summary:"Delete DropKart",prompt:"p",status,startedAt:now-120});
        const session=(state)=>({id:"s",title:"Home",messages:[
          {id:"u1",role:"user",text:"Delete it",thinking:"",activities:[]},
          {id:"a1",role:"assistant",text:"The DropKart tab is taking it.",thinking:"",activities:[],
           delegations:[handoff(delegation,"running"),handoff(other,"running")]},
          {id:"u2",role:"user",text:"See (Attached file: x)",displayText:"See\\n\\n📎 Lease.pdf",thinking:"",activities:[]},
          ...(state?[{id:"r1",role:"handoff",text:"**Handoff update**",thinking:"",activities:[],handoffResult:{delegationID:delegation,
            tabID:tab,tabTitle:"DropKart",summary:"Delete DropKart",state,detail:state==="completed"?"Deleted.":"",
            startedAt:now-120,updatedAt:now,finishedAt:state==="completed"?now:undefined}}]:[])]});
        const read=()=>({cards:[...document.querySelectorAll('#messages .handoff-card')].map(card=>(card.classList.contains('result')?'R:':'D:')+card.querySelector('strong').textContent),
          prompts:[...document.querySelectorAll('#messages .message.user')].map(row=>row.textContent)});
        render(session(null));const before=read();
        render(session("working"));const working=read();
        render(session("completed"));const done=read();
        // A handoff whose request moved into a child tab says so on both cards.
        const childTab=(state)=>({id:"s",title:"Home",messages:[{id:"a2",role:"assistant",text:"Handed off.",thinking:"",activities:[],
          delegations:[{...handoff(other,state),tabTitle:"Add a docs page",childTab:{parentTabID:tab,parentTabTitle:"DropKart",state:"working"}}]},
          ...(state==="completed"?[{id:"r2",role:"handoff",text:"**Done**",thinking:"",activities:[],handoffResult:{delegationID:other,tabID:tab,tabTitle:"Add a docs page",
           parentTabTitle:"DropKart",summary:"Docs",state:"completed",detail:"Added.\\n\\nChild tab of DropKart · Merged into main",startedAt:now-120,updatedAt:now,finishedAt:now}}]:[])]});
        render(childTab("running"));const inChild=read();
        render(childTab("completed"));const inChildDone=read();
        return {before,working,done,inChild,inChildDone};
        """, arguments: ["delegation": delegation, "other": other, "tab": tab], contentWorld: .page) as? [String: Any]
        func cards(_ key: String) -> [String] { ((rendered?[key] as? [String: Any])?["cards"] as? [String]) ?? [] }
        precondition(cards("before") == ["D:Working in tab", "D:Working in tab"], "\(String(describing: rendered))")
        precondition(cards("working") == ["D:Working in tab", "R:Working in tab"],
                     "the answered handoff keeps one card, and it never says 'again': \(String(describing: rendered))")
        precondition(cards("done") == ["D:Working in tab", "R:Done in tab"], "\(String(describing: rendered))")
        precondition(cards("inChild") == ["D:Working in child tab"] && cards("inChildDone") == ["R:Done in child tab"],
                     "\(String(describing: rendered))")
        let prompts = (rendered?["before"] as? [String: Any])?["prompts"] as? [String] ?? []
        precondition(prompts.contains { $0.contains("📎 Lease.pdf") && !$0.contains("Attached file") },
                     "file prompts show their readable line: \(prompts)")
    }
}
