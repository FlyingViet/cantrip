import Darwin
import Foundation

extension SessionTabTests {
    @MainActor
    static func testRemoteMemory() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("memory-api-\(UUID())")
        let vault = home.appendingPathComponent("vault")
        try fm.createDirectory(at: vault.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try "# Facts\nSaved environment".write(to: vault.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "# Preferences\nSaved preferences".write(to: vault.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        for index in 0..<60 {
            try "Note content \(index)".write(to: vault.appendingPathComponent(String(format: "note-%02d.md", index)),
                                            atomically: true, encoding: .utf8)
        }
        for day in ["2026-09-13", "2026-09-14", "2026-09-15"] {
            try "Daily history".write(to: vault.appendingPathComponent("sessions/\(day).md"),
                                     atomically: true, encoding: .utf8)
        }
        let outside = home.appendingPathComponent("outside.md")
        try "OUTSIDE CONTENT".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: vault.appendingPathComponent("link.md"), withDestinationURL: outside)
        try fm.linkItem(at: outside, to: vault.appendingPathComponent("hardlink.md"))
        try fm.createDirectory(at: vault.appendingPathComponent("directory.md"), withIntermediateDirectories: false)
        try "Hidden".write(to: vault.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        precondition(mkfifo(vault.appendingPathComponent("pipe.md").path, 0o600) == 0)
        let settings = AppSettings.shared
        let oldPath = settings.memoryPath, oldEnabled = settings.memoryEnabled
        let oldUsage = UserDefaults.standard.dictionary(forKey: "memoryNoteUsage") as NSDictionary?
        settings.memoryPath = vault.path
        settings.memoryEnabled = false
        defer { settings.memoryPath = oldPath; settings.memoryEnabled = oldEnabled }
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ path: String = "/api/v1/memory", query: [String: String] = [:],
                     method: String = "GET", auth: Bool = true) async throws -> (Int, [String: Any]) {
            var url = URLComponents(string: "http://127.0.0.1:\(port)\(path)")!
            url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!)
            request.httpMethod = method
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        for path in ["/api/v1/memory", "/api/v1/memory/document"] {
            let (unauthorized, _) = try await request(path, auth: false)
            precondition(unauthorized == 401)
            for method in ["POST", "PUT", "DELETE"] {
                let (status, _) = try await request(path, method: method)
                precondition(status == 405, "Memory is strictly read-only")
            }
        }
        var cursor: String?
        var entries: [[String: Any]] = []
        repeat {
            let (status, result) = try await request(query: cursor.map { ["after": $0] } ?? [:])
            precondition(status == 200 && result["enabled"] as? Bool == false && result["exists"] as? Bool == true)
            let documents = result["documents"] as! [[String: Any]]
            precondition(documents.count <= RemoteMemory.catalogPageSize)
            entries += documents
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        precondition(entries.count == 65 && Set(entries.map { $0["id"] as! String }).count == 65)
        precondition(entries.prefix(2).allSatisfy { $0["category"] as? String == "core" })
        precondition(entries.first?["characterLimit"] as? Int == MemoryStore.memoryCap)
        precondition(entries.suffix(3).map { $0["id"] as! String } == [
            "sessions/2026-09-15.md", "sessions/2026-09-14.md", "sessions/2026-09-13.md"
        ])
        let (_, search) = try await request(query: ["q": "NOTE-05"])
        precondition((search["documents"] as! [[String: Any]]).map { $0["id"] as! String } == ["note-05.md"])
        let (staleCursor, _) = try await request(query: ["after": "missing.md"])
        precondition(staleCursor == 409)
        let (oversizedSearch, _) = try await request(query: ["q": String(repeating: "x", count: 201)])
        precondition(oversizedSearch == 400)

        let text = String(repeating: "x", count: RemoteMemory.documentPageBytes - 1)
            + String(repeating: "\u{1F680} cafe\u{301}\n", count: 6000)
        let file = vault.appendingPathComponent("large & useful.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        var offset = 0, restored = "", revision: String?
        repeat {
            var query = ["id": file.lastPathComponent, "offset": String(offset)]
            query["revision"] = revision
            let (status, result) = try await request("/api/v1/memory/document", query: query)
            precondition(status == 200 && result["offset"] as? Int == offset)
            let chunk = result["text"] as! String
            precondition(chunk.utf8.count <= RemoteMemory.documentPageBytes)
            restored += chunk
            revision = result["revision"] as? String
            guard let next = result["nextOffset"] as? Int else { break }
            precondition(next == restored.utf8.count && next > offset)
            offset = next
        } while true
        precondition(restored == text, "UTF-8 paging must recover every byte, without truncation or duplication")
        try "Changed".write(to: file, atomically: true, encoding: .utf8)
        let (changed, _) = try await request("/api/v1/memory/document",
                                            query: ["id": file.lastPathComponent, "offset": "1", "revision": revision!])
        precondition(changed == 409)
        for id in ["../outside.md", "/outside.md", "sessions/../MEMORY.md", ".hidden.md",
                   "link.md", "hardlink.md", "directory.md", "pipe.md", "missing.md", "MEMORY.md\0.md"] {
            let (status, result) = try await request("/api/v1/memory/document", query: ["id": id])
            precondition([400, 404].contains(status), "Invalid or non-regular memory file: \(id)")
            precondition(result["text"] == nil)
        }
        let (invalidOffset, _) = try await request("/api/v1/memory/document",
                                                  query: ["id": "MEMORY.md", "offset": "-1"])
        precondition(invalidOffset == 400)
        let (missingRevision, _) = try await request("/api/v1/memory/document",
                                                    query: ["id": "MEMORY.md", "offset": "1"])
        precondition(missingRevision == 400)
        try Data([0xFF]).write(to: vault.appendingPathComponent("invalid.md"))
        let (invalidText, _) = try await request("/api/v1/memory/document", query: ["id": "invalid.md"])
        precondition(invalidText == 422)
        try Data().write(to: vault.appendingPathComponent("empty.md"))
        let (emptyStatus, empty) = try await request("/api/v1/memory/document", query: ["id": "empty.md"])
        precondition(emptyStatus == 200 && empty["text"] as? String == "" && empty["nextOffset"] == nil)
        try fm.moveItem(at: vault.appendingPathComponent("sessions"), to: home.appendingPathComponent("sessions"))
        try fm.createSymbolicLink(at: vault.appendingPathComponent("sessions"), withDestinationURL: home.appendingPathComponent("sessions"))
        let (linkedSession, _) = try await request("/api/v1/memory/document", query: ["id": "sessions/2026-09-15.md"])
        precondition(linkedSession == 404)
        settings.memoryPath = ""
        let (unconfigured, _) = try await request()
        precondition(unconfigured == 503, "A missing configuration must not expose the working directory")
        settings.memoryPath = home.appendingPathComponent("not-created").path
        let (missingStatus, missing) = try await request()
        precondition(missingStatus == 200 && missing["exists"] as? Bool == false)
        precondition(!fm.fileExists(atPath: settings.memoryPath), "Browsing must not create or seed the vault")
        precondition(oldUsage == UserDefaults.standard.dictionary(forKey: "memoryNoteUsage") as NSDictionary?,
                     "Browsing must not record retrieval usage")
        print("Remote memory: paired read-only catalog, bounded UTF-8 pages, revisions, search, and file containment passed")
    }
}
