import Foundation
import Network

extension SessionTabTests {
    /// The encrypted LAN listener can be pinned to a port, so clients reach it by a saved
    /// host:port (e.g. through a Tailscale subnet route) without Bonjour; a busy port falls back.
    @MainActor
    static func testRemoteLANPort() async throws {
        let manager = SessionManager()
        let token = UUID().uuidString
        let server = RemoteControlServer(manager: manager)
        server.advertisesLANService = false
        server.lanReclaimInterval = 0.5
        var statuses: [RemoteLANStatus?] = []
        server.onLANStatus = { status in DispatchQueue.main.async { statuses.append(status) } }
        func waitForStatus(_ condition: (RemoteLANStatus) -> Bool) async throws -> RemoteLANStatus {
            for _ in 0..<200 {
                if let last = statuses.last, let status = last, condition(status) { return status }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            preconditionFailure("LAN listener status never matched: \(statuses)")
        }

        let httpPort = Int.random(in: 49152...54000)
        let pinned = Int.random(in: 54001...58000)
        statuses.removeAll()
        server.start(port: httpPort, token: token, lanPort: pinned)
        defer { server.stop() }
        let status = try await waitForStatus { $0.port == pinned }
        precondition(!status.fellBack && status.requestedPort == pinned)
        let listed = try await lanRequest(port: pinned, token: token, path: "/api/v1/sessions")
        precondition(listed.status == 200 && listed.body.contains("\"sessions\""),
                     "A direct host:port reaches the pinned TLS-PSK listener with no Bonjour browse")
        do {
            _ = try await lanRequest(port: pinned, token: "not-the-pairing-token", path: "/api/v1/sessions")
            preconditionFailure("A different pairing token must fail the TLS-PSK handshake")
        } catch is LANRequestFailure {}
        precondition(RemoteLANStatusText.describe(status, pinnedPort: pinned, addresses: ["192.168.0.152"])
            .contains("192.168.0.152:\(pinned)"))

        // A new pairing token restarts everything; the pinned port is rebound once the old
        // socket closes, not abandoned for a dynamic one.
        let renewed = UUID().uuidString
        try await Task.sleep(nanoseconds: 100_000_000)
        statuses.removeAll()
        server.start(port: httpPort, token: renewed, lanPort: pinned)
        let rebound = try await waitForStatus { _ in true }
        precondition(rebound.port == pinned && !rebound.fellBack, "Token change kept the pinned port: \(rebound)")
        let reboundHealth = try await lanRequest(port: pinned, token: renewed, path: "/health")
        precondition(reboundHealth.status == 200)
        var loopbackUp = false
        for _ in 0..<40 where !loopbackUp {
            let health = URL(string: "http://127.0.0.1:\(httpPort)/health")!
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 { loopbackUp = true }
            else { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        precondition(loopbackUp, "The loopback HTTP listener survives a token change on the same port")

        // Another app holding the pinned port: fall back to a dynamic port and say so.
        let busy = Int.random(in: 58001...62000)
        let blocker = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(busy))!)
        blocker.newConnectionHandler = { $0.cancel() }
        blocker.start(queue: .main)
        defer { blocker.cancel() }
        for _ in 0..<40 where blocker.state != .ready { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(blocker.state == .ready, "Test blocker could not bind \(busy)")
        statuses.removeAll()
        server.start(port: httpPort, token: renewed, lanPort: busy)
        let fallback = try await waitForStatus { $0.requestedPort == busy }
        precondition(fallback.fellBack && fallback.port != busy, "A busy pinned port falls back")
        let viaFallback = try await lanRequest(port: fallback.port, token: renewed, path: "/health")
        precondition(viaFallback.status == 200, "The fallback listener still serves TLS-PSK")
        precondition(RemoteLANStatusText.describe(fallback, pinnedPort: busy, addresses: [])
            .contains("Port \(busy) is in use"))
        // The other app lets go: Cantrip moves back to the pinned port by itself.
        blocker.cancel()
        let reclaimed = try await waitForStatus { $0.port == busy }
        precondition(!reclaimed.fellBack)
        let reclaimedHealth = try await lanRequest(port: busy, token: renewed, path: "/health")
        precondition(reclaimedHealth.status == 200)

        // The loopback HTTP port can't double as the LAN port; it stays dynamic.
        statuses.removeAll()
        server.start(port: httpPort, token: renewed, lanPort: httpPort)
        let automatic = try await waitForStatus { $0.requestedPort == nil }
        precondition(automatic.port != httpPort && !automatic.fellBack)
        precondition(RemoteLANStatusText.describe(automatic, pinnedPort: 0, addresses: [])
            .contains("automatic"))
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(statuses.last == .some(nil), "Stopping clears the reported LAN port")

        // The Home window with Remote control off: loopback only, no encrypted LAN listener.
        try await Task.sleep(nanoseconds: 300_000_000)
        statuses.removeAll()
        let localOnly = Int.random(in: 58001...60000)
        server.start(port: localOnly, token: renewed, lanPort: pinned, servesLAN: false)
        var localUp = false
        for _ in 0..<40 where !localUp {
            let health = URL(string: "http://127.0.0.1:\(localOnly)/health")!
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 { localUp = true }
            else { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(localUp && !statuses.contains { $0 != nil }, "Loopback-only serves HTTP with no LAN listener: \(statuses)")
        do {
            _ = try await lanRequest(port: pinned, token: renewed, path: "/health")
            preconditionFailure("Loopback-only must not listen on the LAN port")
        } catch {}
        // Turning Remote control on later adds the LAN listener to the running server.
        server.start(port: localOnly, token: renewed, lanPort: pinned, servesLAN: true)
        let added = try await waitForStatus { $0.port == pinned }
        precondition(!added.fellBack, "The LAN listener joins the loopback server")
        server.start(port: localOnly, token: renewed, lanPort: pinned, servesLAN: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(statuses.last == .some(nil), "Turning Remote off again drops the LAN listener")
        server.stop()
        print("Remote LAN port: pinned TLS-PSK by host:port, token mismatch rejected, busy-port fallback, loopback-only passed")
    }

    struct LANRequestFailure: Error { let reason: String }

    /// One TLS-PSK HTTP request to 127.0.0.1:port, as a client with a saved direct address makes.
    static func lanRequest(port: Int, token: String, path: String) async throws -> (status: Int, body: String) {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: RemoteLANProtocol.parameters(token: token)
        )
        let queue = DispatchQueue(label: "lan-port-test")
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var buffer = Data()
            func finish(_ result: Result<(Int, String), Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result.map { (status: $0.0, body: $0.1) })
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if complete || error != nil {
                        let text = String(decoding: buffer, as: UTF8.self)
                        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
                        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
                        finish(status == 0 ? .failure(LANRequestFailure(reason: "no response"))
                               : .success((status, body)))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET \(path) HTTP/1.1\r\nHost: cantrip.local\r\n"
                        + "Authorization: Bearer \(token)\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(LANRequestFailure(reason: error.localizedDescription))) }
                        else { receive() }
                    })
                case .failed(let error), .waiting(let error):
                    finish(.failure(LANRequestFailure(reason: error.localizedDescription)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(.failure(LANRequestFailure(reason: "timed out"))) }
        }
    }
}
