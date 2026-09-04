import Foundation
import Network
import Security

final class RemoteLANBrowser {
    var onEndpointsChanged: (([NWEndpoint]) -> Void)?

    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-discovery")
    private var browser: NWBrowser?

    func start(token: String) {
        stop()
        let fingerprint = RemoteLANProtocol.tokenFingerprint(token)
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: RemoteLANProtocol.serviceType,
                domain: nil
            ),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let endpoints = results.compactMap { result -> NWEndpoint? in
                guard case .bonjour(let record) = result.metadata,
                      record["v"] == "1",
                      record["id"] == fingerprint
                else { return nil }
                return result.endpoint
            }
            .sorted { $0.debugDescription < $1.debugDescription }
            DispatchQueue.main.async { [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                self.onEndpointsChanged?(endpoints)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .failed = state {
                DispatchQueue.main.async { [weak self, weak browser] in
                    guard let self, let browser, self.browser === browser else { return }
                    self.onEndpointsChanged?([])
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }
}

final class RemoteLANBridge {
    var onReady: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?

    private let endpoint: NWEndpoint
    private let token: String
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-lan-bridge")
    private var listener: NWListener?
    private var requests: [UUID: RemoteLANProxyRequest] = [:]

    init(endpoint: NWEndpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: 0)!
                )
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                        else {
                            self.fail("Could not create the local Cantrip bridge address.")
                            return
                        }
                        DispatchQueue.main.async { [weak self, weak listener] in
                            guard let self, let listener, self.listener === listener else { return }
                            self.onReady?(url)
                        }
                    case .failed(let error):
                        self.fail(error.localizedDescription)
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            let active = Array(self.requests.values)
            self.requests.removeAll()
            active.forEach { $0.cancel() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let request = RemoteLANProxyRequest(
            localConnection: connection,
            remoteEndpoint: endpoint,
            token: token,
            queue: queue
        ) { [weak self] in
            self?.requests.removeValue(forKey: id)
        }
        requests[id] = request
        request.start()
    }

    private func fail(_ message: String) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let active = Array(requests.values)
        requests.removeAll()
        active.forEach { $0.cancel() }
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }
}

private final class RemoteLANProxyRequest {
    private let localConnection: NWConnection
    private let remoteEndpoint: NWEndpoint
    private let token: String
    private let queue: DispatchQueue
    private let completion: () -> Void
    private var remoteConnection: NWConnection?
    private var requestBuffer = Data()
    private var responseBuffer = Data()
    private var finished = false

    private let maximumRequestBytes = 1 << 20
    private let maximumResponseBytes = 32 << 20

    init(
        localConnection: NWConnection,
        remoteEndpoint: NWEndpoint,
        token: String,
        queue: DispatchQueue,
        completion: @escaping () -> Void
    ) {
        self.localConnection = localConnection
        self.remoteEndpoint = remoteEndpoint
        self.token = token
        self.queue = queue
        self.completion = completion
    }

    func start() {
        localConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveRequest()
            case .failed:
                self.finish()
            case .cancelled where !self.finished:
                self.finish()
            default:
                break
            }
        }
        localConnection.start(queue: queue)
    }

    func cancel() {
        finish()
    }

    private func receiveRequest() {
        localConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.requestBuffer.append(data) }
            if self.requestBuffer.count > self.maximumRequestBytes {
                self.sendError(status: 413, reason: "Payload Too Large")
            } else if HTTPRequest.parse(self.requestBuffer) != nil {
                self.connectToRemote()
            } else if !HTTPRequest.needsMoreData(self.requestBuffer) {
                self.sendError(status: 400, reason: "Bad Request")
            } else if isComplete || error != nil {
                self.sendError(status: 400, reason: "Bad Request")
            } else {
                self.receiveRequest()
            }
        }
    }

    private func connectToRemote() {
        let connection = NWConnection(
            to: remoteEndpoint,
            using: RemoteLANProtocol.parameters(token: token)
        )
        remoteConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.remoteConnection === connection else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed:
                self.sendError(status: 502, reason: "Bad Gateway")
            case .cancelled where !self.finished:
                self.sendError(status: 502, reason: "Bad Gateway")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest() {
        remoteConnection?.send(
            content: requestBuffer,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                if error == nil {
                    self.receiveResponse()
                } else {
                    self.sendError(status: 502, reason: "Bad Gateway")
                }
            }
        )
    }

    private func receiveResponse() {
        remoteConnection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.responseBuffer.append(data) }
            do {
                if self.responseBuffer.count > self.maximumResponseBytes {
                    self.sendError(status: 502, reason: "Bad Gateway")
                } else if let length = try Self.completeResponseLength(self.responseBuffer) {
                    self.sendResponse(self.responseBuffer.prefix(length))
                } else if isComplete || error != nil {
                    self.sendError(status: 502, reason: "Bad Gateway")
                } else {
                    self.receiveResponse()
                }
            } catch {
                self.sendError(status: 502, reason: "Bad Gateway")
            }
        }
    }

    private func sendResponse(_ response: Data.SubSequence) {
        localConnection.send(
            content: Data(response),
            completion: .contentProcessed { [weak self] _ in
                self?.finish()
            }
        )
    }

    private func sendError(status: Int, reason: String) {
        let body = Data("\(reason)\n".utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        localConnection.send(
            content: response,
            completion: .contentProcessed { [weak self] _ in
                self?.finish()
            }
        )
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        localConnection.stateUpdateHandler = nil
        localConnection.cancel()
        remoteConnection?.stateUpdateHandler = nil
        remoteConnection?.cancel()
        remoteConnection = nil
        completion()
    }

    private static func completeResponseLength(_ data: Data) throws -> Int? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else {
            guard data.count <= 64 * 1024 else { throw RemoteLANBridgeParseError.invalid }
            return nil
        }
        guard let header = String(
            data: data[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            throw RemoteLANBridgeParseError.invalid
        }
        let contentLength = header.components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "content-length"
                else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first
        guard let contentLength,
              contentLength >= 0,
              contentLength <= 32 << 20,
              headerRange.upperBound <= (32 << 20) - contentLength
        else {
            throw RemoteLANBridgeParseError.invalid
        }
        let completeLength = headerRange.upperBound + contentLength
        return data.count >= completeLength ? completeLength : nil
    }
}

private enum RemoteLANBridgeParseError: Error {
    case invalid
}

enum RemoteClientCredentials {
    private static let service = "com.brian.agentspotlight.remote-client"
    private static let account = "pairing-token"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ token: String) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var item = baseQuery
        for (key, value) in attributes { item[key] = value }
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() -> OSStatus {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
