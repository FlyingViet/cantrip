import Foundation

extension SessionTabTests {
    /// A raw HTTP exchange, so the test sees Content-Encoding and the bytes actually sent.
    nonisolated static func rawHTTP(port: Int, target: String, token: String, acceptGzip: Bool,
                                    method: String = "GET", body: Data = Data(),
                                    headers: [String: String] = [:]) async -> (head: String, body: Data) {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            precondition(fd >= 0)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            // The listener can take a moment to come up on a busy machine.
            var connected: Int32 = -1
            for _ in 0..<30 where connected != 0 {
                connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if connected != 0 { usleep(100_000) }
            }
            precondition(connected == 0, "could not connect to the test server")
            let request = "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n"
                + (acceptGzip ? "Accept-Encoding: gzip, deflate\r\n" : "")
                + headers.map { "\($0.key): \($0.value)\r\n" }.joined()
                + (body.isEmpty ? "" : "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n")
                + "Connection: close\r\n\r\n"
            let bytes = Array(request.utf8) + Array(body)
            precondition(write(fd, bytes, bytes.count) == bytes.count)
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                response.append(contentsOf: buffer[0..<count])
            }
            let split = response.range(of: Data("\r\n\r\n".utf8))!
            return (String(decoding: response[..<split.lowerBound], as: UTF8.self),
                    Data(response[split.upperBound...]))
        }.value
    }

    @MainActor
    static func testRemoteCompression() async throws {
        let manager = SessionManager()
        let chat = ChatSession()
        manager.sessions = [chat]
        defer { chat.cancel() }
        chat.messages = (0..<20).map {
            ChatMessage(role: .assistant, text: "Reply \($0) " + String(repeating: "compressible text ", count: 200))
        }
        let homeWasEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = true
        defer { AppSettings.shared.cantripHomeEnabled = homeWasEnabled }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func field(_ head: String, _ name: String) -> String? {
            head.components(separatedBy: "\r\n").dropFirst()
                .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        func get(_ target: String, gzip: Bool = false) async -> (head: String, body: Data) {
            await rawHTTP(port: port, target: target, token: token, acceptGzip: gzip)
        }
        func json(_ data: Data) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        // Large JSON is compressed only for clients that ask, and decodes to the same response.
        let session = "/api/v1/sessions/\(chat.id)"
        let plain = await get(session)
        precondition(plain.head.hasPrefix("HTTP/1.1 200") && field(plain.head, "Content-Encoding") == nil)
        precondition(plain.body.count > HTTPCompression.minimumBytes)
        let compressed = await get(session, gzip: true)
        precondition(field(compressed.head, "Content-Encoding") == "gzip")
        precondition(field(compressed.head, "Vary") == "Accept-Encoding")
        precondition(field(compressed.head, "Content-Length") == String(compressed.body.count))
        precondition(compressed.body.count * 4 < plain.body.count, "repetitive transcripts shrink at least 4x")
        let decoded = try json(HTTPCompression.gunzip(compressed.body, limit: 32 << 20)!)
        precondition((decoded["session"] as? [String: Any])?["id"] as? String == chat.id.uuidString)
        precondition(((decoded["session"] as? [String: Any])?["messages"] as? [Any])?.count == 20)

        // Small bodies stay uncompressed.
        let small = await get("/health", gzip: true)
        precondition(small.head.hasPrefix("HTTP/1.1 200") && field(small.head, "Content-Encoding") == nil)

        // The web page is served from the main actor and compressed off it.
        let page = await get("/", gzip: true)
        let pagePlain = await get("/")
        precondition(field(page.head, "Content-Encoding") == "gzip")
        precondition(HTTPCompression.gunzip(page.body, limit: 8 << 20) == pagePlain.body)

        // Home lists answer "unchanged" for the client's current revision.
        for path in ["/api/v1/home/tasks", "/api/v1/home/artifacts"] {
            let full = try json(await get(path).body)
            let revision = try requireHome(full["revision"] as? String)
            precondition(full[path.hasSuffix("tasks") ? "tasks" : "artifacts"] is [Any])
            let same = try json(await get(path + "?revision=\(revision)").body)
            precondition(same["unchanged"] as? Bool == true && same["revision"] as? String == revision)
            precondition(same["tasks"] == nil && same["artifacts"] == nil, "unchanged replies carry no list")
            let stale = try json(await get(path + "?revision=\(UUID().uuidString)").body)
            precondition(stale["unchanged"] == nil && stale["revision"] as? String == revision)
        }
        let before = try requireHome(try json(await get("/api/v1/home/tasks").body)["revision"] as? String)
        let proposal = try JSONDecoder().decode(CantripHomeTaskProposal.self, from: Data(#"""
        {"title":"Compression check","prompt":"Report the compression check.","schedule":{"kind":"weekdays","summary":"Weekdays at 9 AM","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":[2,3,4,5,6],"hour":9,"minute":0}}
        """#.utf8))
        let task = try CantripHomeStore.shared.create(proposal)
        defer { try? CantripHomeStore.shared.delete(id: task.id) }
        let changed = try json(await get("/api/v1/home/tasks?revision=\(before)").body)
        precondition(changed["unchanged"] == nil && changed["revision"] as? String != before)
        precondition((changed["tasks"] as? [[String: Any]])?.contains { $0["title"] as? String == "Compression check" } == true,
                     "a saved change sends the full list to a client holding the old revision")

        // A rejected edit that still changed the Mac's copy must not read as unchanged.
        let shown = try requireHome(changed["revision"] as? String)
        let tasksBefore = CantripHomeStore.shared.tasks
        _ = await rawHTTP(port: port, target: "/api/v1/home/tasks/\(task.id)", token: token, acceptGzip: false,
                          method: "PATCH", body: Data(#"{"title":"Partial edit","prompt":""}"#.utf8))
        let afterRejected = try json(await get("/api/v1/home/tasks?revision=\(shown)").body)
        if CantripHomeStore.shared.tasks != tasksBefore {
            precondition(afterRejected["unchanged"] == nil, "any in-memory change moves the revision")
        } else {
            precondition(afterRejected["unchanged"] as? Bool == true)
        }
        precondition(CantripHomeStore.shared.revision.uuidString != shown || CantripHomeStore.shared.tasks == tasksBefore)
    }

    /// JSON reads carry a weak ETag of the body; sending it back as If-None-Match answers 304 with no
    /// body until the response changes. Browsers still get `no-store`, and clients that don't send the
    /// header always get the full response.
    @MainActor
    static func testRemoteEntityTags() async throws {
        let manager = SessionManager()
        let chat = ChatSession()
        manager.sessions = [chat]
        defer { chat.cancel() }
        chat.messages = (0..<12).map {
            ChatMessage(role: .assistant, text: "Reply \($0) " + String(repeating: "entity tag text ", count: 120))
        }
        let homeWasEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = true
        defer { AppSettings.shared.cantripHomeEnabled = homeWasEnabled }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func field(_ head: String, _ name: String) -> String? {
            head.components(separatedBy: "\r\n").dropFirst()
                .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        func get(_ target: String, gzip: Bool = false, ifNoneMatch: String? = nil,
                 method: String = "GET") async -> (head: String, body: Data) {
            await rawHTTP(port: port, target: target, token: token, acceptGzip: gzip, method: method,
                          headers: ifNoneMatch.map { ["If-None-Match": $0] } ?? [:])
        }

        for target in ["/api/v1/sessions?history=recent", "/api/v1/sessions/\(chat.id)?history=recent",
                       "/api/v1/home/tasks", "/api/v1/home?history=recent&recentExchanges=3"] {
            let full = await get(target, gzip: true)
            precondition(full.head.hasPrefix("HTTP/1.1 200"), "\(target): \(full.head)")
            let tag = try requireHome(field(full.head, "ETag"))
            precondition(tag.hasPrefix("W/\"") && tag.hasSuffix("\""), "a weak tag")
            precondition(field(full.head, "Cache-Control") == "no-store", "browsers still keep nothing")
            let plain = await get(target)
            precondition(field(plain.head, "ETag") == tag, "gzip and identity share the tag of the uncompressed body")

            let same = await get(target, gzip: true, ifNoneMatch: tag)
            precondition(same.head.hasPrefix("HTTP/1.1 304"), "\(target) unchanged: \(same.head)")
            precondition(same.body.isEmpty && field(same.head, "Content-Length") == "0")
            precondition(field(same.head, "ETag") == tag && field(same.head, "Content-Encoding") == nil)
            let listed = await get(target, ifNoneMatch: "W/\"0000\", " + tag)
            precondition(listed.head.hasPrefix("HTTP/1.1 304"), "any listed tag matches")
            let strong = await get(target, ifNoneMatch: String(tag.dropFirst(2)))
            precondition(strong.head.hasPrefix("HTTP/1.1 304"), "weak comparison ignores W/")
            let other = await get(target, ifNoneMatch: "W/\"0123456789abcdef0123456789abcdef\"")
            precondition(other.head.hasPrefix("HTTP/1.1 200") && other.body == plain.body, "another copy gets the body")
        }

        // A change answers the full response and a new tag.
        let target = "/api/v1/sessions/\(chat.id)?history=recent"
        let before = try requireHome(field(await get(target).head, "ETag"))
        chat.messages.append(ChatMessage(role: .assistant, text: "One more reply"))
        let after = await get(target, ifNoneMatch: before)
        precondition(after.head.hasPrefix("HTTP/1.1 200") && !after.body.isEmpty, "changed: \(after.head)")
        let changedTag = try requireHome(field(after.head, "ETag"))
        precondition(changedTag != before)

        // Only successful JSON reads are tagged: not errors, writes or the web page.
        let missing = await get("/api/v1/sessions/\(UUID().uuidString)", ifNoneMatch: "*")
        precondition(missing.head.hasPrefix("HTTP/1.1 404") && field(missing.head, "ETag") == nil)
        let page = await get("/")
        precondition(page.head.hasPrefix("HTTP/1.1 200") && field(page.head, "ETag") == nil)
        let written = await rawHTTP(port: port, target: "/api/v1/sessions/\(chat.id)/metadata", token: token,
                                    acceptGzip: false, method: "POST", body: Data(#"{"customTitle":"Tagged"}"#.utf8),
                                    headers: ["If-None-Match": "*"])
        precondition(!written.head.hasPrefix("HTTP/1.1 304") && field(written.head, "ETag") == nil, written.head)
        precondition(HTTPEntityTag.matches("*", "W/\"ab\"") && !HTTPEntityTag.matches(nil, "W/\"ab\""))
    }

    /// `steps=summary`: large tool steps come without their input and output (with `detailBytes`), small
    /// ones whole, and `…/messages/<id>/steps/<step>` answers one step in full. Clients that don't ask
    /// keep getting every step whole, and so does the full-message route.
    @MainActor
    static func testRemoteStepSummaries() async throws {
        let manager = SessionManager()
        let chat = ChatSession()
        manager.sessions = [chat]
        defer { chat.cancel() }
        var reply = ChatMessage(role: .assistant, text: "Checked everything.")
        reply.activities = (0..<60).map { n in
            ToolActivity(id: "toolu_big_\(n)", title: "Run check \(n)", toolName: "bash", state: .succeeded,
                         input: "{\"command\":\"make check-\(n)\"}", output: String(repeating: "line of output \(n)\n", count: 120),
                         fileChanges: [])
        } + [ToolActivity(id: "toolu_small", title: "pwd", toolName: "bash", state: .succeeded, input: "pwd",
                          output: "/tmp", fileChanges: [])]
        chat.messages = [ChatMessage(role: .user, text: "Run the checks"), reply]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func get(_ target: String) async throws -> (status: String, object: [String: Any], bytes: Int) {
            let response = await rawHTTP(port: port, target: target, token: token, acceptGzip: false)
            let object = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
            return (String(response.head.prefix(12)), object, response.body.count)
        }
        func steps(_ object: [String: Any]) -> [[String: Any]] {
            let messages = (object["session"] as? [String: Any])?["messages"] as? [[String: Any]]
            return messages?.last?["activities"] as? [[String: Any]] ?? []
        }
        let base = "/api/v1/sessions/\(chat.id)?history=recent&recentExchanges=3"
        let full = try await get(base)
        let summary = try await get(base + "&steps=summary")
        precondition(steps(full.object).count == 61 && steps(summary.object).count == 61)
        precondition(steps(full.object).allSatisfy { $0["output"] != nil && $0["detailBytes"] == nil },
                     "clients that don't ask get every step whole")
        let big = try requireHome(steps(summary.object).first)
        precondition(big["input"] == nil && big["output"] == nil, "a large step leaves its details out")
        precondition(big["title"] as? String == "Run check 0" && big["state"] as? String == "succeeded")
        precondition((big["detailBytes"] as? Int ?? 0) > 2_000, "and says how much it left out")
        let small = try requireHome(steps(summary.object).last)
        precondition(small["output"] as? String == "/tmp" && small["detailBytes"] == nil, "a small step stays whole")
        precondition(summary.bytes * 8 < full.bytes, "summaries are a fraction of the size: \(summary.bytes) vs \(full.bytes)")

        let messageID = try requireHome(((summary.object["session"] as? [String: Any])?["messages"] as? [[String: Any]])?.last?["id"] as? String)
        let one = try await get("/api/v1/sessions/\(chat.id)/messages/\(messageID)/steps/toolu_big_0")
        let step = try requireHome(one.object["step"] as? [String: Any])
        precondition(one.status.hasPrefix("HTTP/1.1 200") && (step["output"] as? String)?.hasPrefix("line of output 0") == true)
        precondition(step["input"] as? String == "{\"command\":\"make check-0\"}" && step["detailBytes"] == nil)
        let missing = try await get("/api/v1/sessions/\(chat.id)/messages/\(messageID)/steps/toolu_gone")
        precondition(missing.status.hasPrefix("HTTP/1.1 404"))
        let whole = try await get("/api/v1/sessions/\(chat.id)/messages/\(messageID)?steps=summary")
        let wholeSteps = (whole.object["message"] as? [String: Any])?["activities"] as? [[String: Any]] ?? []
        precondition(wholeSteps.count == 61 && wholeSteps.allSatisfy { $0["detailBytes"] == nil },
                     "the full-message route stays full")
    }
}
