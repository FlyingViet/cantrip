import Foundation
import Network

/// Only fixed route labels and numeric metadata enter the diagnostic log.
final class RemoteRequestTrace {
    enum Phase: String {
        case receive, parse, mainWait = "main_wait", handler, snapshot
        case journalWait = "journal_wait"
        case encodeWait = "encode_wait", encode, sendWait = "send_wait", send
    }

    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var changed = DispatchTime.now().uptimeNanoseconds
    private var phase = Phase.receive
    private var durations: [Phase: Double] = [:]
    private var route = "unparsed"
    private var method = "unknown"
    private var finished = false
    private var status = 0
    private var bytes = 0
    let id = UUID().uuidString
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = Log.write) {
        self.log = log
    }

    func identify(_ request: HTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        method = ["GET", "POST", "DELETE"].contains(request.method) ? request.method : "other"
        switch request.path {
        case "/": route = "web"
        case "/health": route = "health"
        case "/api/v1/ready": route = "ready"
        case "/api/v1/sessions": route = "sessions"
        case "/api/v1/copilot/usage": route = "usage"
        case "/api/v1/github/builds": route = "builds"
        default:
            route = request.path.hasPrefix("/api/v1/sessions/") ? "session" : "unknown"
        }
    }

    func enter(_ next: Phase) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        accrue()
        phase = next
    }

    func response(status: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.bytes = bytes
    }

    func report(outcome: String, terminal: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        accrue()
        finished = terminal
        let timings = [Phase.receive, .parse, .mainWait, .handler, .snapshot, .journalWait,
                       .encodeWait, .encode, .sendWait, .send].map {
            "\($0.rawValue)_ms=\(String(format: "%.2f", durations[$0, default: 0]))"
        }.joined(separator: " ")
        let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let line = "remote-request: id=\(id) method=\(method) route=\(route) "
            + "outcome=\(outcome) phase=\(phase.rawValue) status=\(status) bytes=\(bytes) "
            + "total_ms=\(String(format: "%.2f", total)) \(timings)"
        lock.unlock()
        log(line)
    }

    private func accrue() {
        let now = DispatchTime.now().uptimeNanoseconds
        durations[phase, default: 0] += Double(now - changed) / 1_000_000
        changed = now
    }

    static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix_\(code.rawValue)"
        case .dns(let code): return "dns_\(code)"
        case .tls(let code): return "tls_\(code)"
        default: return "network_unknown"
        }
    }
}

/// Socket lifecycle is confined to the listener queue, not MainActor.
final class RemoteRequestConnection {
    let socket: NWConnection
    let trace: RemoteRequestTrace
    private let queue: DispatchQueue
    private let sendTimeout: TimeInterval
    private var watchdog: DispatchSourceTimer?
    private var sendDeadline: DispatchWorkItem?
    private var finished = false

    init(socket: NWConnection, queue: DispatchQueue, sendTimeout: TimeInterval = 15,
         log: @escaping (String) -> Void = Log.write) {
        self.socket = socket
        self.queue = queue
        self.sendTimeout = sendTimeout
        trace = RemoteRequestTrace(log: log)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.trace.report(outcome: "slow", terminal: false)
        }
        watchdog = timer
        timer.resume()
        socket.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.finish("connection_error_\(RemoteRequestTrace.errorCode(error))")
            }
        }
        socket.start(queue: queue)
    }

    func send(_ response: Data, status: Int, bodyBytes: Int) {
        trace.response(status: status, bytes: bodyBytes)
        trace.enter(.sendWait)
        queue.async { [self] in
            guard !self.finished else { return }
            self.trace.enter(.send)
            let deadline = DispatchWorkItem { [weak self] in
                self?.finish("send_timeout")
            }
            self.sendDeadline = deadline
            self.queue.asyncAfter(deadline: .now() + self.sendTimeout, execute: deadline)
            self.socket.send(content: response, completion: .contentProcessed { error in
                self.finish(error.map { "send_error_\(RemoteRequestTrace.errorCode($0))" } ?? "sent")
            })
        }
    }

    private func finish(_ outcome: String) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        sendDeadline?.cancel()
        sendDeadline = nil
        trace.report(outcome: outcome, terminal: true)
        socket.stateUpdateHandler = nil
        socket.cancel()
    }

    deinit {
        watchdog?.cancel()
        sendDeadline?.cancel()
    }
}
