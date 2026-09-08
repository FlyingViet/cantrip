import Foundation
import Network

enum RemoteRoute: Hashable {
    case lan(NWEndpoint)
    case fallback(URL)

    var isLAN: Bool {
        if case .lan = self { return true }
        return false
    }
}

enum RemoteRouteError: LocalizedError {
    case unavailable
    case transport(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "No healthy route to Cantrip is available. Retrying shortly."
        case .transport(let message): return "Could not reach Cantrip. \(message)"
        case .invalidResponse: return "Cantrip returned an invalid response."
        }
    }
}

struct RemoteHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    var data: Data {
        let header = """
        HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' https: data:; frame-ancestors 'none'\r
        Connection: close\r
        \r

        """
        return Data(header.utf8) + body
    }

    static func parse(_ data: Data) throws -> RemoteHTTPResponse? {
        guard data.count <= 32 << 20 else { throw RemoteRouteError.invalidResponse }
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 64 << 10 else { throw RemoteRouteError.invalidResponse }
            return nil
        }
        guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw RemoteRouteError.invalidResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw RemoteRouteError.invalidResponse
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                fields[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let length = fields["content-length"].flatMap(Int.init),
              length >= 0, length <= (32 << 20) - range.upperBound else {
            throw RemoteRouteError.invalidResponse
        }
        guard data.count - range.upperBound >= length else { return nil }
        return RemoteHTTPResponse(
            status: status,
            contentType: fields["content-type"] ?? "application/octet-stream",
            body: data.subdata(in: range.upperBound..<(range.upperBound + length))
        )
    }
}

actor RemoteRouteClient {
    typealias Sender = (RemoteRoute, HTTPRequest) async throws -> RemoteHTTPResponse
    private var routes: [RemoteRoute] = []
    private(set) var preferred: RemoteRoute?
    private var retryAfter: [RemoteRoute: Date] = [:]
    private(set) var probeTask: Task<Void, Never>?
    private var stopped = false
    private let token: String
    private let send: Sender
    private let now: () -> Date
    private let onRouteChanged: (RemoteRoute) -> Void

    init(
        token: String,
        now: @escaping () -> Date = Date.init,
        send: Sender? = nil,
        onRouteChanged: @escaping (RemoteRoute) -> Void = { _ in }
    ) {
        self.token = token
        self.now = now
        self.send = send ?? { route, request in
            try await Self.send(route: route, request: request, token: token)
        }
        self.onRouteChanged = onRouteChanged
    }

    func update(endpoints: [NWEndpoint], fallback: URL?) {
        routes = endpoints.map(RemoteRoute.lan) + (fallback.map { [.fallback($0)] } ?? [])
        if let preferred, !routes.contains(preferred) { self.preferred = nil }
    }

    func stop() {
        stopped = true
        probeTask?.cancel()
        probeTask = nil
    }

    func request(_ request: HTTPRequest) async throws -> RemoteHTTPResponse {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        var candidates = routes.filter { (retryAfter[$0] ?? .distantPast) <= now() }
        if let preferred, let index = candidates.firstIndex(of: preferred) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        // Only reads may be replayed. A failed POST may already have changed the host.
        if request.method != "GET" { candidates = Array(candidates.prefix(1)) }
        var lastError: Error = RemoteRouteError.unavailable
        for route in candidates {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            guard routes.contains(route) else { continue }
            let previousPreferred = preferred
            do {
                let response = try await send(route, request)
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                if [502, 503, 504].contains(response.status) {
                    failed(route)
                    if request.method != "GET" { return response }
                    lastError = RemoteRouteError.transport("HTTP \(response.status)")
                    continue
                }
                if (200..<300).contains(response.status) {
                    retryAfter[route] = nil
                    if routes.contains(route), preferred == previousPreferred {
                        preferred = route
                        onRouteChanged(route)
                    }
                    recoverLAN()
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteRouteError {
                failed(route)
                lastError = error
                if request.method != "GET" { throw error }
            }
        }
        throw lastError
    }

    private func failed(_ route: RemoteRoute) {
        retryAfter[route] = now().addingTimeInterval(route.isLAN ? 30 : 3)
        if preferred == route { preferred = nil }
    }

    private func recoverLAN() {
        guard probeTask == nil, preferred?.isLAN != true,
              let route = routes.first(where: {
                  $0.isLAN && (retryAfter[$0] ?? .distantPast) <= now()
              }) else { return }
        probeTask = Task { [weak self] in
            await self?.probe(route)
        }
    }

    private func probe(_ route: RemoteRoute) async {
        defer { probeTask = nil }
        do {
            let response = try await send(route, HTTPRequest(
                method: "GET", path: "/api/v1/sessions",
                headers: ["authorization": "Bearer \(token)"], body: Data()
            ))
            try Task.checkCancellation()
            guard !stopped, routes.contains(route) else { return }
            guard response.status == 200,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  object["sessions"] is [Any] else {
                NSLog("Cantrip LAN recovery probe rejected HTTP %ld or an invalid session response; backing off.", response.status)
                failed(route)
                return
            }
            retryAfter[route] = nil
            preferred = route
            onRouteChanged(route)
        } catch is CancellationError {
            return
        } catch {
            NSLog("Cantrip LAN recovery probe failed; backing off: %@", error.localizedDescription)
            failed(route)
        }
    }

    private static func send(
        route: RemoteRoute, request: HTTPRequest, token: String
    ) async throws -> RemoteHTTPResponse {
        switch route {
        case .lan(let endpoint):
            return try await RemoteLANRequest(endpoint: endpoint, token: token, request: request).run()
        case .fallback(let baseURL):
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw RemoteRouteError.invalidResponse
            }
            components.path = request.path
            components.query = nil
            components.fragment = nil
            guard let url = components.url else { throw RemoteRouteError.invalidResponse }
            var forwarded = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: request.body.count > 256 * 1024 ? 60 : 12
            )
            forwarded.httpMethod = request.method
            if !request.body.isEmpty { forwarded.httpBody = request.body }
            for name in ["authorization", "content-type", "accept"] {
                forwarded.setValue(request.headers[name], forHTTPHeaderField: name)
            }
            do {
                let (data, response) = try await fallbackSession.data(for: forwarded)
                guard let response = response as? HTTPURLResponse, data.count <= 32 << 20 else {
                    throw RemoteRouteError.invalidResponse
                }
                return RemoteHTTPResponse(
                    status: response.statusCode,
                    contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    body: data
                )
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw RemoteRouteError.transport(error.localizedDescription)
            }
        }
    }

    private static let fallbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: RemoteNoRedirectDelegate(), delegateQueue: nil)
    }()
}

private final class RemoteNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class RemoteLANRequest: @unchecked Sendable {
    private let endpoint: NWEndpoint
    private let token: String
    private let request: HTTPRequest
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-request")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<RemoteHTTPResponse, Error>?
    private var buffer = Data()
    private var finished = false
    private var cancelled = false
    private var connected = false

    init(endpoint: NWEndpoint, token: String, request: HTTPRequest) {
        self.endpoint = endpoint
        self.token = token
        self.request = request
    }

    func run() async throws -> RemoteHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start() {
        let connection = NWConnection(to: endpoint, using: RemoteLANProtocol.parameters(token: token))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.connected = true
                var components = URLComponents()
                components.path = self.request.path
                var header = "\(self.request.method) \(components.percentEncodedPath) HTTP/1.1\r\nHost: cantrip.local\r\n"
                for name in ["authorization", "content-type", "accept"] {
                    if let value = self.request.headers[name] { header += "\(name): \(value)\r\n" }
                }
                header += "Content-Length: \(self.request.body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + self.request.body, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished else { return }
                    if let error {
                        self.finish(.failure(RemoteRouteError.transport(error.localizedDescription)))
                    } else {
                        self.receive()
                    }
                })
            case .failed(let error):
                self.finish(.failure(RemoteRouteError.transport(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.connected else { return }
            self.finish(.failure(RemoteRouteError.transport("The local connection timed out.")))
        }
        let timeout: TimeInterval = request.method == "GET" ? 2 : (request.body.count > 256 * 1024 ? 60 : 12)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(RemoteRouteError.transport("The local connection timed out.")))
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            do {
                if let response = try RemoteHTTPResponse.parse(self.buffer) {
                    self.finish(.success(response))
                } else if let error {
                    self.finish(.failure(RemoteRouteError.transport(error.localizedDescription)))
                } else if complete {
                    self.finish(.failure(RemoteRouteError.invalidResponse))
                } else {
                    self.receive()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<RemoteHTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
