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
    var onRouteChanged: ((RemoteRoute) -> Void)?
    var onPageFailure: ((String) -> Void)?

    private let client: RemoteRouteClient
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-lan-bridge")
    private var listener: NWListener?
    private var requests: [UUID: RemoteLANProxyRequest] = [:]

    init(token: String) {
        client = RemoteRouteClient(token: token)
    }

    func update(endpoints: [NWEndpoint], fallback: URL?) async {
        await client.update(endpoints: endpoints, fallback: fallback)
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
            Task { await self.client.stop() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let request = RemoteLANProxyRequest(
            localConnection: connection,
            client: client,
            queue: queue,
            onRouteChanged: { [weak self] route in
                DispatchQueue.main.async { self?.onRouteChanged?(route) }
            },
            onPageFailure: { [weak self] message in
                DispatchQueue.main.async { self?.onPageFailure?(message) }
            }
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

// Mutable request state is confined to the bridge's serial queue.
private final class RemoteLANProxyRequest: @unchecked Sendable {
    private let localConnection: NWConnection
    private let client: RemoteRouteClient
    private let queue: DispatchQueue
    private let completion: () -> Void
    private let onRouteChanged: (RemoteRoute) -> Void
    private let onPageFailure: (String) -> Void
    private var task: Task<Void, Never>?
    private var requestBuffer = Data()
    private var finished = false

    private let maximumRequestBytes = 1 << 20

    init(
        localConnection: NWConnection,
        client: RemoteRouteClient,
        queue: DispatchQueue,
        onRouteChanged: @escaping (RemoteRoute) -> Void,
        onPageFailure: @escaping (String) -> Void,
        completion: @escaping () -> Void
    ) {
        self.localConnection = localConnection
        self.client = client
        self.queue = queue
        self.onRouteChanged = onRouteChanged
        self.onPageFailure = onPageFailure
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
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.finished, self.task == nil else { return }
            self.sendError(status: 408, reason: "The local request timed out.")
        }
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
            } else if let request = HTTPRequest.parse(self.requestBuffer) {
                self.forward(request)
            } else if !HTTPRequest.needsMoreData(self.requestBuffer) {
                self.sendError(status: 400, reason: "Bad Request")
            } else if isComplete || error != nil {
                self.sendError(status: 400, reason: "Bad Request")
            } else {
                self.receiveRequest()
            }
        }
    }

    private func forward(_ request: HTTPRequest) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.request(request)
                let route = await self.client.preferred
                self.queue.async {
                    guard !self.finished else { return }
                    if let route { self.onRouteChanged(route) }
                    self.sendResponse(response.data)
                }
            } catch is CancellationError {
                self.queue.async { self.finish() }
            } catch {
                let message = error.localizedDescription
                    + (request.method == "GET" ? "" : " The request may have reached Cantrip. Check the session before sending again.")
                self.queue.async {
                    guard !self.finished else { return }
                    if request.method == "GET", request.path == "/" { self.onPageFailure(message) }
                    self.sendError(status: 502, reason: message)
                }
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
        do {
            let body = try JSONSerialization.data(withJSONObject: ["error": reason])
            sendResponse(RemoteHTTPResponse(status: status, contentType: "application/json", body: body).data)
        } catch {
            onPageFailure("Could not report the connection failure: \(error.localizedDescription)")
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        localConnection.stateUpdateHandler = nil
        localConnection.cancel()
        task?.cancel()
        task = nil
        completion()
    }
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
