import Foundation
import Network
import Darwin

private final class RequestLogCapture {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

extension SessionTabTests {
    @MainActor
    static func testRemoteRequestIsolation() async throws {
        let manager = SessionManager()
        let encoder = DispatchQueue(label: "cantrip.test.remote-encoder")
        let logs = RequestLogCapture()
        let server = RemoteControlServer(manager: manager, encodingQueue: encoder,
                                         requestLog: logs.append)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func request(_ path: String, authenticated: Bool = false, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        let ready = request("api/v1/ready", authenticated: true)
        let health = request("health")
        let (_, unauthorized) = try await client.data(for: request("api/v1/ready"))
        precondition((unauthorized as! HTTPURLResponse).statusCode == 401)
        let (_, method) = try await client.data(for: request("api/v1/ready", authenticated: true, method: "POST"))
        precondition((method as! HTTPURLResponse).statusCode == 405)
        let (readyBody, readyResponse) = try await client.data(for: ready)
        let payload = try JSONSerialization.jsonObject(with: readyBody) as! [String: Any]
        precondition((readyResponse as! HTTPURLResponse).statusCode == 200)
        precondition(payload["status"] as? String == "ready" && payload["sessions"] is [[String: Any]])
        precondition((readyResponse as! HTTPURLResponse).value(forHTTPHeaderField: "X-Cantrip-Request-ID") != nil)

        let enteredMain = DispatchSemaphore(value: 0)
        let releaseMain = DispatchSemaphore(value: 0)
        let mainBlock = Task { @MainActor in
            enteredMain.signal()
            precondition(releaseMain.wait(timeout: .now() + 8) == .success)
        }
        let mainProbe = Task.detached {
            precondition(enteredMain.wait(timeout: .now() + 3) == .success)
            defer { releaseMain.signal() }
            let started = Date()
            let (data, response) = try await client.data(for: health)
            precondition(Date().timeIntervalSince(started) < 0.5,
                         "liveness must not wait for MainActor")
            precondition((response as! HTTPURLResponse).statusCode == 200)
            precondition(String(decoding: data, as: UTF8.self) == #"{"status":"ok"}"#)
            var timedReady = ready
            timedReady.timeoutInterval = 1.2
            do {
                _ = try await client.data(for: timedReady)
                preconditionFailure("readiness must exercise the blocked MainActor")
            } catch let error as URLError {
                precondition(error.code == .timedOut)
            }
        }
        try await mainProbe.value
        await mainBlock.value

        let enteredEncoder = DispatchSemaphore(value: 0)
        let releaseEncoder = DispatchSemaphore(value: 0)
        encoder.async {
            enteredEncoder.signal()
            precondition(releaseEncoder.wait(timeout: .now() + 8) == .success)
        }
        let encodingProbe = Task.detached {
            precondition(enteredEncoder.wait(timeout: .now() + 3) == .success)
            defer { releaseEncoder.signal() }
            let started = Date()
            let (_, response) = try await client.data(for: health)
            precondition(Date().timeIntervalSince(started) < 0.5,
                         "liveness must not wait for shared JSON encoding")
            precondition((response as! HTTPURLResponse).statusCode == 200)
            var timedReady = ready
            timedReady.timeoutInterval = 1.2
            do {
                _ = try await client.data(for: timedReady)
                preconditionFailure("readiness must exercise the blocked JSON queue")
            } catch let error as URLError {
                precondition(error.code == .timedOut)
            }
        }
        try await encodingProbe.value
        _ = try await client.data(for: ready)
        let lines = logs.snapshot()
        precondition(lines.contains { $0.contains("outcome=slow phase=main_wait") })
        precondition(lines.contains { $0.contains("outcome=slow phase=encode_wait") })
        precondition(lines.contains { $0.contains("snapshot_ms=") && $0.contains("send_ms=") })
        precondition(lines.filter { $0.contains("route=health") }.allSatisfy {
            $0.contains("main_wait_ms=0.00") && $0.contains("encode_wait_ms=0.00")
        })
        precondition(!lines.contains { $0.contains(token) || $0.contains(manager.active.id.uuidString) })

        let privateLog = RequestLogCapture()
        let trace = RemoteRequestTrace(log: privateLog.append)
        trace.identify(HTTPRequest(method: "SECRET_METHOD", path: "/api/v1/sessions/SECRET_ID/SECRET_TEXT",
                                   headers: ["authorization": "Bearer SECRET_TOKEN"],
                                   body: Data("SECRET_BODY".utf8)))
        trace.report(outcome: "sent", terminal: true)
        trace.report(outcome: "duplicate", terminal: true)
        precondition(privateLog.snapshot().count == 1)
        precondition(!privateLog.snapshot()[0].contains("SECRET"))
        try await testResponseWriteFailures()
    }

    static func testResponseWriteFailures() async throws {
        for resetPeer in [false, true] {
            let queue = DispatchQueue(label: "cantrip.test.slow-reader")
            let logs = RequestLogCapture()
            let ready = DispatchSemaphore(value: 0)
            let accepted = DispatchSemaphore(value: 0)
            let listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { socket in
                let connection = RemoteRequestConnection(socket: socket, queue: queue, sendTimeout: 0.3,
                                                         log: logs.append)
                connection.start()
                connection.send(Data(repeating: 65, count: 32 * 1024 * 1024), status: 200,
                                bodyBytes: 32 * 1024 * 1024)
                accepted.signal()
            }
            listener.start(queue: queue)
            defer { listener.cancel() }
            try await Task.detached {
                precondition(ready.wait(timeout: .now() + 3) == .success)
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                precondition(fd >= 0)
                var receiveBuffer: Int32 = 1024
                precondition(setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
                                       socklen_t(MemoryLayout<Int32>.size)) == 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = listener.port!.rawValue.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                precondition(connected == 0)
                precondition(accepted.wait(timeout: .now() + 3) == .success)
                if resetPeer {
                    var reset = linger(l_onoff: 1, l_linger: 0)
                    precondition(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset,
                                           socklen_t(MemoryLayout<linger>.size)) == 0)
                    close(fd)
                }
                try await Task.sleep(nanoseconds: 800_000_000)
                if !resetPeer { close(fd) }
            }.value
            let lines = logs.snapshot()
            precondition(lines.count == 1, "socket failures must complete exactly once")
            if resetPeer {
                precondition(lines[0].contains("error_posix_"), "peer reset must log its numeric error")
            } else {
                precondition(lines[0].contains("outcome=send_timeout"), "slow readers need a bounded send")
            }
        }
    }
}
