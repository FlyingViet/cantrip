import Foundation

extension SessionTabTests {
    @MainActor
    static func testTabReordering() async throws {
        let manager = SessionManager()
        let first = manager.newSession()
        let middle = manager.newSession()
        let last = manager.newSession()
        for chat in [first, middle, last] { try chat.updateTab(name: "Duplicate title") }
        try middle.updateTab(isLocked: true)
        manager.select(manager.sessions.firstIndex(where: { $0.id == middle.id })!)
        let original = manager.sessions.map(\.id)
        middle.isStreaming = true
        middle.submitRemote("Keep queued work", mode: .queue)
        let queued = middle.queued
        try manager.moveSession(last.id, relativeTo: first.id, after: false)
        precondition(Array(manager.sessions.suffix(3)).map(\.id) == [last.id, first.id, middle.id])
        precondition(manager.active === middle && middle.isStreaming && middle.queued == queued)
        manager.selectRemote()
        try manager.moveSession(middle.id, relativeTo: last.id, after: false)
        precondition(manager.showingRemote && manager.active === middle && middle.isLocked)
        try manager.moveSession(last.id, relativeTo: first.id, after: true)
        precondition(Array(manager.sessions.suffix(3)).map(\.id) == [middle.id, first.id, last.id])
        try manager.moveSession(middle.id, relativeTo: first.id, after: true)
        precondition(manager.sessions.map(\.id) == original && manager.active === middle)
        let noChange = manager.sessions.map(\.id)
        try manager.moveSession(middle.id, relativeTo: middle.id, after: false)
        do {
            try manager.moveSession(UUID(), relativeTo: first.id, after: false)
            preconditionFailure("A closed source must not be moved")
        } catch SessionTabError.unavailable {}
        do {
            try manager.moveSession(first.id, relativeTo: UUID(), after: false)
            preconditionFailure("A closed destination must not be used")
        } catch SessionTabError.unavailable {}
        precondition(manager.sessions.map(\.id) == noChange)
        middle.isStreaming = false
        middle.cancel()

        try manager.moveSession(last.id, relativeTo: first.id, after: false)
        let restored = SessionManager()
        precondition(restored.sessions.map(\.id) == manager.sessions.map(\.id))
        precondition(restored.active.id == middle.id && restored.active.isLocked)

        let privateTab = manager.newSession()
        privateTab.isPrivate = true
        manager.select(manager.sessions.firstIndex(where: { $0.id == middle.id })!)
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func request(_ id: UUID, method: String = "POST", body: [String: Any]? = nil,
                     authenticated: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(id)/move")!)
            request.httpMethod = method
            request.timeoutInterval = 3
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let body: [String: Any] = ["targetID": last.id.uuidString, "placement": "before"]
        let beforeErrors = manager.sessions.map(\.id)
        let unauthorized = try await request(middle.id, body: body, authenticated: false)
        precondition(unauthorized.0 == 401)
        let wrongMethod = try await request(middle.id, method: "GET")
        precondition(wrongMethod.0 == 405)
        for invalid in [
            [:], ["targetID": last.id.uuidString], ["targetID": NSNull(), "placement": "before"],
            ["targetID": "not-a-uuid", "placement": "before"],
            ["targetID": last.id.uuidString, "placement": true],
            ["targetID": last.id.uuidString, "placement": "sideways"],
            ["targetID": last.id.uuidString, "placement": "before", "unknown": true]
        ] as [[String: Any]] {
            let rejected = try await request(middle.id, body: invalid)
            precondition(rejected.0 == 400)
        }
        for hidden in [privateTab.id, UUID()] {
            let source = try await request(hidden, body: body)
            let target = try await request(middle.id, body: ["targetID": hidden.uuidString, "placement": "after"])
            precondition(source.0 == 404 && target.0 == 404)
        }
        precondition(manager.sessions.map(\.id) == beforeErrors, "Rejected moves must be atomic")
        let moved = try await request(middle.id, body: body)
        precondition(moved.0 == 200)
        let listed = moved.1["sessions"] as! [[String: Any]]
        precondition(listed.map { $0["id"] as! String } == manager.sessions.filter { !$0.isPrivate }.map(\.id.uuidString))
        precondition(listed.allSatisfy { $0["supportsTabReordering"] as? Bool == true && $0["messages"] == nil })
        precondition(manager.active === middle && manager.sessions.last === privateTab)
        let responseOrder = manager.sessions.map(\.id)
        let repeated = try await request(middle.id, body: body)
        precondition(repeated.0 == 200 && manager.sessions.map(\.id) == responseOrder)
        let added = manager.newSession()
        let reverse = try await request(middle.id, body: ["targetID": first.id.uuidString, "placement": "after"])
        precondition(reverse.0 == 200 && manager.sessions.last === added,
                     "Relative moves must preserve tabs added since the client snapshot")
        manager.select(middle.id)
        manager.close(last.id)
        precondition(manager.active === middle && !manager.sessions.contains(where: { $0.id == last.id }),
                     "Closing a reordered tab by ID must retain the other selected conversation")
        manager.select(first.id)
        precondition(manager.active === first)
        manager.close(UUID())
        precondition(manager.tabActionError != nil && manager.active === first)
    }
}
