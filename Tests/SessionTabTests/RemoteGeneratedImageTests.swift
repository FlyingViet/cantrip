import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        print("Generated previews: paired reads, message ownership, history, privacy and durable images passed")
    }
}
