import CryptoKit
import Foundation
import MarkdownUI
import Network
import Security
import SwiftUI
import UIKit

enum CantripRemoteConnectionState: Equatable {
    case disconnected
    case connected
}

enum CantripDeliveryMode: String, CaseIterable, Identifiable {
    case auto
    case queue
    case interrupt
    case inject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .queue: return "Queue"
        case .interrupt: return "Redirect"
        case .inject: return "Inject"
        }
    }
}

struct CantripRemoteActivity: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let toolName: String
    let state: String
}

struct CantripRemoteMessage: Decodable, Equatable, Identifiable {
    let id: String
    let role: String
    let text: String
    let thinking: String
    let author: String?
    let activities: [CantripRemoteActivity]
}

struct CantripRemoteQueuedPrompt: Decodable, Equatable, Identifiable {
    let id: String
    let text: String
}

struct CantripRemoteSession: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let workdir: String
    let isStreaming: Bool
    let canResume: Bool
    let councilMode: Bool
    let queuedCount: Int
    let status: String?
    let messages: [CantripRemoteMessage]?
    let supportsImageAttachments: Bool?
    let queued: [CantripRemoteQueuedPrompt]?
    var supportsAutoDelivery: Bool? = nil
    var deliveryStatus: String? = nil
    var supportsQueueRemoval: Bool? = nil
    var customTitle: String? = nil
    var isLocked: Bool? = nil
    var supportsTabMetadata: Bool? = nil

    var transcript: [CantripRemoteMessage] { messages ?? [] }
}

private struct CantripSessionsResponse: Decodable {
    let sessions: [CantripRemoteSession]
}

private struct CantripSessionResponse: Decodable {
    let session: CantripRemoteSession
}

private struct CantripErrorResponse: Decodable {
    let error: String
}

enum CantripRemoteError: LocalizedError {
    case invalidURL(String)
    case missingToken
    case keychain(String)
    case authentication
    case transport(String)
    case http(Int, String)
    case decoding
    case invalidResponse
    case imagesUnsupported
    case autoDeliveryUnsupported
    case queueRemovalUnsupported
    case tabMetadataUnsupported

    static func isRouteFailure(_ error: Error) -> Bool {
        switch error {
        case CantripRemoteError.transport, CantripRemoteError.invalidResponse:
            return true
        case CantripRemoteError.http(let status, _):
            return [502, 503, 504].contains(status)
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return message
        case .missingToken:
            return "Enter the Cantrip pairing token."
        case .keychain(let message):
            return message
        case .authentication:
            return "Cantrip rejected the pairing token. Open Remote settings and enter the current token."
        case .transport(let message):
            return "Could not reach Cantrip. \(message)"
        case .http(let status, let message):
            return "Cantrip returned HTTP \(status): \(message)"
        case .decoding:
            return "Cantrip returned data this app could not read. Update both apps and try again."
        case .invalidResponse:
            return "Cantrip returned an invalid HTTP response."
        case .imagesUnsupported:
            return "Image attachments require an updated Cantrip host using Claude, Copilot, or Codex. Your images have not been sent."
        case .autoDeliveryUnsupported:
            return "Update and reopen Cantrip on your Mac for Auto sending, or choose Queue, Redirect, or Inject. Your message has not been sent."
        case .queueRemovalUnsupported:
            return "Update and reopen Cantrip on your Mac to remove queued messages from AgentGateway."
        case .tabMetadataUnsupported:
            return "Update and reopen Cantrip on your Mac to rename or lock its tabs."
        }
    }
}

private enum CantripRemoteCredentials {
    private static let account = "cantrip.remote.pairing-token"
    private static let service = "AgentGateway"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be updated in Keychain (error \(updateStatus))."
            )
        }

        var item = query
        item.merge(update) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be saved in Keychain (error \(addStatus))."
            )
        }
    }

    static func removeToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CantripRemoteError.keychain(
                "The pairing token could not be removed from Keychain (error \(status))."
            )
        }
    }
}

private actor CantripRequestGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum CantripTransport: Hashable {
    case lan(NWEndpoint)
    case remote(URL)
}

private enum CantripLANProtocol {
    static let serviceType = "_cantrip-remote._tcp"

    static func parameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let derivedKey = Data(SHA256.hash(data: Data(token.utf8)))
        let key = derivedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("cantrip-remote-v1".utf8).withUnsafeBytes {
            DispatchData(bytes: $0)
        }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            key as dispatch_data_t,
            identity as dispatch_data_t
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(
                rawValue: UInt16(TLS_DHE_PSK_WITH_AES_128_GCM_SHA256)
            )!
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class CantripLANBrowser {
    var onEndpointsChanged: (([NWEndpoint]) -> Void)?

    private let queue = DispatchQueue(label: "com.itzhoang.hermbot.cantrip-discovery")
    private var browser: NWBrowser?

    func start(token: String) {
        stop()
        let fingerprint = CantripLANProtocol.tokenFingerprint(token)
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: CantripLANProtocol.serviceType,
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

private struct CantripLANResponse {
    let statusCode: Int
    let body: Data
}

private final class CantripLANRequest: @unchecked Sendable {
    private let endpoint: NWEndpoint
    private let token: String
    private let requestData: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.itzhoang.hermbot.cantrip-request")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<CantripLANResponse, Error>?
    private var responseBuffer = Data()
    private var isCancelled = false
    private var isComplete = false
    private var isReady = false

    init(endpoint: NWEndpoint, token: String, method: String, path: String, body: Data?) {
        self.endpoint = endpoint
        self.token = token
        let payload = body ?? Data()
        timeout = method == "GET" ? 2 : (payload.count > 256 * 1024 ? 60 : 12)
        let header = """
        \(method) \(path) HTTP/1.1\r
        Host: cantrip.local\r
        Authorization: Bearer \(token)\r
        Accept: application/json\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var requestData = Data(header.utf8)
        requestData.append(payload)
        self.requestData = requestData
    }

    func run() async throws -> CantripLANResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.isCancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() {
        let connection = NWConnection(
            to: endpoint,
            using: CantripLANProtocol.parameters(token: token)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.sendRequest()
            case .failed(let error):
                self.finish(.failure(CantripRemoteError.transport(
                    error.localizedDescription
                )))
            case .cancelled where !self.isComplete:
                self.finish(.failure(
                    self.isCancelled
                        ? CancellationError()
                        : CantripRemoteError.transport("The local connection closed.")
                ))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isReady, !self.isComplete else { return }
            self.finish(.failure(CantripRemoteError.transport(
                "The local connection timed out."
            )))
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.isComplete else { return }
            self.finish(.failure(CantripRemoteError.transport(
                "The local connection timed out."
            )))
        }
    }

    private func sendRequest() {
        guard let connection else { return }
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(CantripRemoteError.transport(
                    error.localizedDescription
                )))
            } else {
                self.receiveResponse()
            }
        })
    }

    private func receiveResponse() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, complete, error in
            guard let self, !self.isComplete else { return }
            if let data {
                self.responseBuffer.append(data)
            }
            do {
                if let response = try self.parseResponse() {
                    self.finish(.success(response))
                } else if let error {
                    self.finish(.failure(CantripRemoteError.transport(
                        error.localizedDescription
                    )))
                } else if complete {
                    self.finish(.failure(CantripRemoteError.invalidResponse))
                } else {
                    self.receiveResponse()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func parseResponse() throws -> CantripLANResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = responseBuffer.range(of: separator) else {
            guard responseBuffer.count <= 64 * 1024 else {
                throw CantripRemoteError.invalidResponse
            }
            return nil
        }
        guard let header = String(
            data: responseBuffer[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            throw CantripRemoteError.invalidResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw CantripRemoteError.invalidResponse
        }
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "content-length"
            else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }.first
        guard let contentLength, contentLength >= 0, contentLength <= 32 * 1024 * 1024 else {
            throw CantripRemoteError.invalidResponse
        }
        let bodyStart = headerRange.upperBound
        guard responseBuffer.count - bodyStart >= contentLength else { return nil }
        let body = responseBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return CantripLANResponse(statusCode: statusCode, body: body)
    }

    private func finish(_ result: Result<CantripLANResponse, Error>) {
        guard !isComplete else { return }
        isComplete = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

struct CantripRemoteAPI {
    let transport: CantripTransport
    let token: String
    var urlSession: URLSession?

    private static let readSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func sessions() async throws -> [CantripRemoteSession] {
        let response: CantripSessionsResponse = try await request(path: "/api/v1/sessions")
        return response.sessions
    }

    func session(id: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)"
        )
        return response.session
    }

    func createSession() async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions",
            method: "POST"
        )
        return response.session
    }

    func send(
        _ text: String,
        mode: CantripDeliveryMode,
        sessionID: String,
        images: [ChatImageAttachment] = []
    ) async throws
        -> CantripRemoteSession {
        if !images.isEmpty || mode == .auto {
            guard images.count <= ImageAttachmentProcessor.maximumCount else {
                throw ImageAttachmentError.tooMany
            }
            // Check the same authenticated host used for the mutation. Older hosts
            // ignore unknown JSON fields, which would silently send only the text.
            let host = try await session(id: sessionID)
            guard images.isEmpty || host.supportsImageAttachments == true else {
                throw CantripRemoteError.imagesUnsupported
            }
            guard mode != .auto || host.supportsAutoDelivery == true else {
                throw CantripRemoteError.autoDeliveryUnsupported
            }
        }
        let body = try JSONEncoder().encode(CantripMessageBody(text: text, mode: mode, images: images))
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/messages",
            method: "POST",
            body: body
        )
        return response.session
    }

    func action(_ action: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/\(action)",
            method: "POST"
        )
        return response.session
    }

    func closeSession(id: String) async throws -> CantripRemoteSession {
        try await action("close", sessionID: id)
    }

    func updateTab(id: String, name: String? = nil, isLocked: Bool? = nil) async throws -> CantripRemoteSession {
        struct Body: Encodable {
            var customTitle: String?
            var isLocked: Bool?
        }
        var validatedName: String?
        if let name {
            var metadata = ChatTabMetadata()
            try metadata.rename(name)
            validatedName = metadata.customTitle ?? ""
        }
        let host = try await session(id: id)
        guard host.supportsTabMetadata == true else {
            throw CantripRemoteError.tabMetadataUnsupported
        }
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)/metadata",
            method: "POST",
            body: JSONEncoder().encode(Body(customTitle: validatedName, isLocked: isLocked))
        )
        return response.session
    }

    func removeQueuedPrompt(id: String, sessionID: String) async throws -> CantripRemoteSession {
        let host = try await session(id: sessionID)
        guard host.supportsQueueRemoval == true else {
            throw CantripRemoteError.queueRemovalUnsupported
        }
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/queue/\(id)",
            method: "DELETE"
        )
        return response.session
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        if case .lan(let endpoint) = transport {
            return try await requestLAN(
                endpoint: endpoint,
                path: path,
                method: method,
                body: body
            )
        }
        guard case .remote(let baseURL) = transport else {
            throw CantripRemoteError.invalidResponse
        }
        let url = try endpoint(path: path, baseURL: baseURL)
        let isImageUpload = (body?.count ?? 0) > 256 * 1024
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: method == "GET" ? 3 : (isImageUpload ? 60 : 12)
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            let session = urlSession ?? (method == "GET" ? Self.readSession : (isImageUpload ? Self.imageSession : Self.session))
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw CantripRemoteError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CantripRemoteError.invalidResponse
        }
        if http.statusCode == 401 {
            throw CantripRemoteError.authentication
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(CantripErrorResponse.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CantripRemoteError.http(http.statusCode, serverMessage)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CantripRemoteError.decoding
        }
    }

    private func requestLAN<Response: Decodable>(
        endpoint: NWEndpoint,
        path: String,
        method: String,
        body: Data?
    ) async throws -> Response {
        let response = try await CantripLANRequest(
            endpoint: endpoint,
            token: token,
            method: method,
            path: path,
            body: body
        ).run()
        if response.statusCode == 401 {
            throw CantripRemoteError.authentication
        }
        guard (200..<300).contains(response.statusCode) else {
            let serverMessage = (
                try? JSONDecoder().decode(CantripErrorResponse.self, from: response.body)
            )?.error ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CantripRemoteError.http(response.statusCode, serverMessage)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw CantripRemoteError.decoding
        }
    }

    private func endpoint(path: String, baseURL: URL) throws -> URL {
        guard path.hasPrefix("/"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw CantripRemoteError.invalidResponse }
        components.percentEncodedPath = path
        components.percentEncodedQuery = nil
        components.fragment = nil
        guard let url = components.url,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port
        else { throw CantripRemoteError.invalidResponse }
        return url
    }
}

@MainActor
final class CantripRemoteModel: ObservableObject {
    @Published private(set) var connectionState: CantripRemoteConnectionState = .disconnected
    @Published private(set) var configuredURL: String
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var sessions: [CantripRemoteSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedSession: CantripRemoteSession?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    private var mutationRevision = 0
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var isLocalNetworkAvailable = false
    @Published private(set) var tailscaleOnly: Bool

    var isConnected: Bool { connectionState == .connected }
    var hasConfiguration: Bool { baseURL != nil || token != nil }
    var isConfigured: Bool {
        token != nil && (baseURL != nil || (!tailscaleOnly && !lanEndpoints.isEmpty))
    }

    var endpointHost: String {
        if case .lan = activeTransport {
            return "Local network"
        }
        if activeTransport == nil, isLocalNetworkAvailable {
            return "Local network"
        }
        guard let baseURL else { return "Not configured" }
        if let port = baseURL.port {
            return "\(baseURL.host ?? baseURL.absoluteString):\(port)"
        }
        return baseURL.host ?? baseURL.absoluteString
    }

    private static let endpointKey = "cantrip.remote.base-url"
    private static let tailscaleOnlyKey = "cantrip.remote.tailscale-only"
    // Allow a bounded HTTPS-to-LAN failover plus the polling interval.
    private static let staleInterval: Duration = .seconds(10)
    private static let pollInterval: Duration = .milliseconds(1500)

    private var baseURL: URL?
    private var token: String?
    private var appIsActive = false
    private var pollingTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var lastAuthenticatedAt: Date?
    private var configurationGeneration = 0
    private var lanEndpoints: [NWEndpoint] = []
    private var activeTransport: CantripTransport?
    private let lanBrowser = CantripLANBrowser()
    private let requestGate = CantripRequestGate()
    private let router = CantripRemoteRouter()

    init() {
        let storedURL = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        configuredURL = storedURL
        tailscaleOnly = UserDefaults.standard.bool(forKey: Self.tailscaleOnlyKey)
        token = CantripRemoteCredentials.loadToken()
        hasStoredToken = token != nil
        do {
            baseURL = try Self.normalizedBaseURL(storedURL)
            if baseURL == nil, !storedURL.isEmpty {
                errorMessage = "The saved Remote URL is invalid. Open settings and save it again."
            }
        } catch {
            baseURL = nil
            if !storedURL.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        if active {
            startLANDiscovery()
            startPolling()
        } else {
            lanBrowser.stop()
            stopPolling()
        }
    }

    func configure(
        url rawURL: String,
        pairingToken rawToken: String,
        tailscaleOnly: Bool = false
    ) async -> Bool {
        do {
            let normalized = try Self.normalizedBaseURL(rawURL)
            guard !tailscaleOnly || normalized != nil else {
                throw CantripRemoteError.invalidURL("Enter a Tailscale URL to use Tailscale only.")
            }
            let enteredToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveToken = enteredToken.isEmpty ? token : enteredToken
            guard let effectiveToken, !effectiveToken.isEmpty else {
                throw CantripRemoteError.missingToken
            }
            if !enteredToken.isEmpty {
                try CantripRemoteCredentials.saveToken(enteredToken)
            }

            stopPolling()
            configurationGeneration += 1
            router.reset()
            baseURL = normalized
            self.tailscaleOnly = tailscaleOnly
            UserDefaults.standard.set(tailscaleOnly, forKey: Self.tailscaleOnlyKey)
            token = effectiveToken
            configuredURL = normalized?.absoluteString ?? ""
            hasStoredToken = true
            activeTransport = nil
            lanEndpoints = []
            isLocalNetworkAvailable = false
            if configuredURL.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.endpointKey)
            } else {
                UserDefaults.standard.set(configuredURL, forKey: Self.endpointKey)
            }
            errorMessage = nil
            if appIsActive {
                startLANDiscovery()
                startPolling()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            markDisconnected()
            return false
        }
    }

    func clearConfiguration() {
        do {
            try CantripRemoteCredentials.removeToken()
            stopPolling()
            lanBrowser.stop()
            configurationGeneration += 1
            router.reset()
            UserDefaults.standard.removeObject(forKey: Self.endpointKey)
            UserDefaults.standard.removeObject(forKey: Self.tailscaleOnlyKey)
            tailscaleOnly = false
            baseURL = nil
            token = nil
            activeTransport = nil
            lanEndpoints = []
            isLocalNetworkAvailable = false
            configuredURL = ""
            hasStoredToken = false
            sessions = []
            selectedSessionID = nil
            selectedSession = nil
            errorMessage = nil
            transcriptRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshNow() async {
        await refresh()
    }

    func selectSession(_ id: String) async {
        guard id != selectedSessionID || selectedSession?.id != id else { return }
        selectedSessionID = id
        selectedSession = nil
        transcriptRevision += 1
        do {
            let detail = try await performAuthenticated(allowFallback: true) { api in
                try await api.session(id: id)
            }
            guard selectedSessionID == id else { return }
            apply(detail)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            markDisconnected()
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createSession() async -> Bool {
        guard let session = await mutate({ api in
            try await api.createSession()
        }) else { return false }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        selectedSessionID = session.id
        apply(session)
        return true
    }

    @discardableResult
    func send(
        _ text: String,
        mode: CantripDeliveryMode,
        images: [ChatImageAttachment] = [],
        sessionID: String? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty,
              let sessionID = sessionID ?? selectedSessionID else { return false }
        guard let session = await mutate({ api in
            try await api.send(trimmed, mode: mode, sessionID: sessionID, images: images)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    @discardableResult
    func stop() async -> Bool {
        await sessionAction("cancel")
    }

    @discardableResult
    func removeQueuedPrompt(_ id: String, sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try removing the message again."
            return false
        }
        guard let session = await mutate({ api in
            try await api.removeQueuedPrompt(id: id, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    @discardableResult
    func resume() async -> Bool {
        await sessionAction("resume")
    }

    @discardableResult
    func newConversation() async -> Bool {
        await sessionAction("new-conversation")
    }

    @discardableResult
    func closeSession(_ id: String) async -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        guard sessions.first(where: { $0.id == id })?.isLocked != true else {
            errorMessage = ChatTabError.locked.localizedDescription
            return false
        }
        guard let replacement = await mutate({ api in
            try await api.closeSession(id: id)
        }) else { return false }

        sessions.removeAll { $0.id == id }
        if let index = sessions.firstIndex(where: { $0.id == replacement.id }) {
            sessions[index] = replacement
        } else {
            sessions.append(replacement)
        }

        if selectedSessionID == id {
            selectedSessionID = replacement.id
            apply(replacement)
        }
        return true
    }

    @discardableResult
    func updateTab(_ id: String, name: String? = nil, isLocked: Bool? = nil) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish before editing this tab."
            return false
        }
        guard let session = await mutate({ api in
            try await api.updateTab(id: id, name: name, isLocked: isLocked)
        }) else { return false }
        if selectedSessionID == id {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        }
        return true
    }

    private func sessionAction(_ action: String) async -> Bool {
        guard let sessionID = selectedSessionID else { return false }
        guard action != "new-conversation" || selectedSession?.isLocked != true else {
            errorMessage = ChatTabError.locked.localizedDescription
            return false
        }
        guard let session = await mutate({ api in
            try await api.action(action, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    private func mutate<T>(
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async -> T? {
        guard !isMutating else { return nil }
        mutationRevision += 1
        isMutating = true
        defer { isMutating = false }
        do {
            let result = try await performAuthenticated(operation)
            errorMessage = nil
            return result
        } catch is CancellationError {
            return nil
        } catch {
            if shouldDisconnect(for: error) {
                markDisconnected()
            }
            errorMessage = error.localizedDescription
            if CantripRemoteError.isRouteFailure(error) {
                errorMessage = "\(error.localizedDescription) The request may have reached Cantrip. Check the session before sending again."
            }
            return nil
        }
    }

    private func refresh() async {
        guard appIsActive, isConfigured, !isRefreshing, !isMutating else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedID = selectedSessionID
        let revision = mutationRevision
        do {
            let generation = configurationGeneration
            let listed = try await performAuthenticated(allowFallback: true) { api in
                try await api.sessions()
            }
            let chosenID = requestedID.flatMap { id in
                listed.contains(where: { $0.id == id }) ? id : nil
            } ?? listed.first?.id
            let detail: CantripRemoteSession?
            if let chosenID {
                detail = try await performAuthenticated(allowFallback: true) { api in
                    try await api.session(id: chosenID)
                }
            } else {
                detail = nil
            }
            guard generation == configurationGeneration else { throw CancellationError() }
            guard revision == mutationRevision else { return }

            sessions = listed
            if selectedSessionID == requestedID || selectedSessionID == nil {
                selectedSessionID = chosenID
                if let detail {
                    apply(detail)
                } else if chosenID == nil {
                    selectedSession = nil
                    transcriptRevision += 1
                }
            }
            errorMessage = nil
            recoverTailscale()
        } catch is CancellationError {
            return
        } catch {
            markDisconnected()
            errorMessage = error.localizedDescription
        }
    }

    private func performAuthenticated<T>(
        allowFallback: Bool = false,
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard let token else {
            throw CantripRemoteError.missingToken
        }
        let generation = configurationGeneration
        let result = try await requestGate.withLock {
            try await self.performRouted(
                generation: generation, token: token,
                allowFallback: allowFallback, operation: operation
            )
        }
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        activeTransport = router.preferred
        markAuthenticatedSuccess()
        return result
    }

    private func performRouted<T>(
        generation: Int,
        token: String,
        allowFallback: Bool,
        operation: (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard generation == configurationGeneration else { throw CancellationError() }
        updateRoutes()
        return try await router.perform(readOnly: allowFallback) { transport in
            let api = CantripRemoteAPI(transport: transport, token: token)
            return try await operation(api)
        }
    }

    private func updateRoutes() {
        router.available = (baseURL.map { [.remote($0)] } ?? [])
            + (tailscaleOnly ? [] : lanEndpoints.map(CantripTransport.lan))
    }

    private func recoverTailscale() {
        guard appIsActive, let token, !tailscaleOnly else { return }
        router.recoverTailscale { transport in
            _ = try await CantripRemoteAPI(transport: transport, token: token).sessions()
        }
    }

    private func apply(_ session: CantripRemoteSession) {
        if selectedSession != session {
            selectedSession = session
            transcriptRevision += 1
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
    }

    private func startPolling() {
        guard appIsActive, isConfigured, pollingTask == nil else {
            if !isConfigured { markDisconnected() }
            return
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func startLANDiscovery() {
        guard let token, !tailscaleOnly else {
            lanBrowser.stop()
            updateLANEndpoints([])
            return
        }
        updateLANEndpoints([])
        lanBrowser.onEndpointsChanged = { [weak self] endpoints in
            self?.updateLANEndpoints(endpoints)
        }
        lanBrowser.start(token: token)
    }

    private func updateLANEndpoints(_ endpoints: [NWEndpoint]) {
        guard endpoints != lanEndpoints else { return }
        lanEndpoints = endpoints
        isLocalNetworkAvailable = !endpoints.isEmpty
        updateRoutes()
        if case .lan(let endpoint) = activeTransport,
           !endpoints.contains(endpoint) {
            activeTransport = nil
            markDisconnected()
        }
        if appIsActive {
            startPolling()
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        staleTask?.cancel()
        staleTask = nil
        router.cancelProbe()
        markDisconnected()
    }

    private func markAuthenticatedSuccess() {
        guard appIsActive, pollingTask != nil else {
            markDisconnected()
            return
        }
        let completedAt = Date()
        lastAuthenticatedAt = completedAt
        connectionState = .connected
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.staleInterval)
            } catch {
                return
            }
            guard let self, self.lastAuthenticatedAt == completedAt else { return }
            self.markDisconnected()
        }
    }

    private func markDisconnected() {
        connectionState = .disconnected
    }

    private func shouldDisconnect(for error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case CantripRemoteError.http:
            return false
        case CantripRemoteError.imagesUnsupported, CantripRemoteError.queueRemovalUnsupported,
             is ImageAttachmentError:
            return false
        default:
            return true
        }
    }

    private static func normalizedBaseURL(_ rawValue: String) throws -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw CantripRemoteError.invalidURL("Enter a valid HTTPS URL.")
        }
        guard components.user == nil, components.password == nil else {
            throw CantripRemoteError.invalidURL("The Remote URL cannot contain a username or password.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw CantripRemoteError.invalidURL("The Remote URL cannot contain a query string or fragment.")
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw CantripRemoteError.invalidURL("Use the Cantrip server origin without an extra path.")
        }

        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw CantripRemoteError.invalidURL(
                "Use HTTPS. HTTP is allowed only for localhost, 127.0.0.1, or ::1 development."
            )
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw CantripRemoteError.invalidURL("Enter a valid HTTPS URL.")
        }
        return url
    }
}

struct CantripRemoteView: View {
    @EnvironmentObject private var model: CantripRemoteModel
    @State private var showSettings = false
    @State private var draft = ""
    @State private var deliveryMode: CantripDeliveryMode = .auto
    @State private var renamingSession: CantripRemoteSession?

    var body: some View {
        NavigationStack {
            Group {
                if model.isConfigured {
                    remoteContent
                } else {
                    CantripRemoteSetupView(model: model)
                }
            }
            .navigationTitle("Remote")
            .toolbar {
                if model.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.createSession() }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(model.isMutating)
                        .accessibilityLabel("Create remote session")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Remote settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                CantripRemoteSettingsSheet(model: model)
            }
            .sheet(item: $renamingSession) { session in
                CantripTabRenameSheet(model: model, session: session)
            }
        }
    }

    private var remoteContent: some View {
        VStack(spacing: 0) {
            connectionBanner
            Divider()
            sessionPicker
            Divider()
            if model.selectedSession != nil {
                sessionControls
                Divider()
                CantripRemoteTranscript(model: model)
                Divider()
                composer
            } else {
                ContentUnavailableView {
                    Label("No Remote Sessions", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Create a session in Cantrip or start one here.")
                } actions: {
                    Button("Create Session") {
                        Task { await model.createSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isMutating)
                }
            }
        }
    }

    private var connectionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "Connected" : "Disconnected")
                    .font(.caption.weight(.semibold))
                Text(model.endpointHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh Remote")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isConnected ? "Connected" : "Disconnected")

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var sessionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sessions) { session in
                    Button {
                        Task { await model.selectSession(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            if session.isLocked == true {
                                Image(systemName: "lock.fill").accessibilityLabel("Locked tab")
                            }
                            if session.isStreaming {
                                ProgressView().controlSize(.mini)
                            }
                            Text(session.title)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            session.id == model.selectedSessionID
                                ? Color.accentColor.opacity(0.24)
                                : Color(.secondarySystemBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        CantripTabActions(model: model, session: session,
                            onRename: { renamingSession = session },
                            onClose: { Task { await model.closeSession(session.id) } })
                    }
                    .accessibilityAction(named: "Close Session") {
                        Task { await model.closeSession(session.id) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var sessionControls: some View {
        HStack(spacing: 12) {
            if let session = model.selectedSession {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.status ?? (session.isStreaming ? "Working…" : "Ready"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if session.queuedCount > 0 {
                        Text("\(session.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.canResume {
                    Button("Resume") {
                        Task { await model.resume() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isMutating)
                }
                if session.isStreaming {
                    Button("Stop", role: .destructive) {
                        Task { await model.stop() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isMutating)
                }
                Button {
                    Task { await model.newConversation() }
                } label: {
                    Label("New", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(session.isStreaming || model.isMutating || session.isLocked == true)
                .accessibilityLabel("Start new conversation")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Delivery", selection: $deliveryMode) {
                    ForEach(CantripDeliveryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Delivery override")
                .disabled(model.isMutating)
                Spacer()
            }
            if let status = model.selectedSession?.deliveryStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Cantrip", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    model.isMutating
                        || model.selectedSessionID == nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("Send prompt")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        Task {
            if await model.send(prompt, mode: deliveryMode) {
                draft = ""
                deliveryMode = .auto
            }
        }
    }
}

private struct CantripRemoteTranscript: View {
    @ObservedObject var model: CantripRemoteModel
    @State private var followsBottom = true
    @State private var userIsScrolling = false
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.selectedSession?.transcript ?? []) { message in
                    CantripRemoteMessageBubble(message: message)
                        .id(message.id)
                }
                Color.clear
                    .frame(height: 1)
                    .id("remote-transcript-bottom")
            }
            .scrollTargetLayout()
            .padding()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 72
        } action: { _, isNearBottom in
            if userIsScrolling {
                followsBottom = isNearBottom
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            let endedUserScroll = newPhase == .idle
                && (oldPhase == .tracking
                    || oldPhase == .interacting
                    || oldPhase == .decelerating)
            userIsScrolling = newPhase == .tracking
                || newPhase == .interacting
                || newPhase == .decelerating
            if endedUserScroll {
                followsBottom = context.geometry.contentSize.height
                    - context.geometry.visibleRect.maxY < 72
            }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            followsBottom = true
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: model.transcriptRevision) { _, _ in
            guard followsBottom else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}

private struct CantripRemoteMessageBubble: View {
    let message: CantripRemoteMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.author ?? message.role.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !message.thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(message.thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .font(.caption)
                }
                if !message.text.isEmpty {
                    if message.role == "user" {
                        PromptTextView(text: message.text)
                    } else {
                        Markdown(message.text)
                    }
                }
                ForEach(message.activities) { activity in
                    Label {
                        Text("\(activity.toolName): \(activity.title)")
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: activity.state == "running"
                              ? "progress.indicator" : activityIcon(activity.state))
                    }
                    .font(.caption2)
                    .foregroundStyle(activity.state == "failed" ? .orange : .secondary)
                }
            }
            .padding(11)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 36) }
        }
    }

    private var background: Color {
        switch message.role {
        case "user": return Color.accentColor.opacity(0.24)
        case "error": return Color.red.opacity(0.16)
        default: return Color(.secondarySystemBackground)
        }
    }

    private func activityIcon(_ state: String) -> String {
        switch state {
        case "succeeded": return "checkmark.circle"
        case "failed": return "exclamationmark.triangle"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }
}

private struct CantripRemoteSetupView: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        Form {
            Section {
                Label("Connect to Cantrip", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Enter the pairing token from Cantrip. AgentGateway prefers your saved Tailscale Serve URL, even on the same local network. Direct LAN is used if Tailscale is unavailable or no URL is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            CantripRemoteSettingsSection(model: model, allowsClearing: false)
        }
    }
}

struct CantripRemoteSettingsSection: View {
    @ObservedObject var model: CantripRemoteModel
    let allowsClearing: Bool

    @State private var url = ""
    @State private var token = ""
    @State private var saving = false
    @State private var saved = false
    @State private var tailscaleOnly = false

    var body: some View {
        Section {
            TextField("Tailscale URL (optional, preferred when saved)", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField(model.hasStoredToken ? "Stored token (leave blank to keep)" : "Pairing token",
                        text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Tailscale only (skip local network)", isOn: $tailscaleOnly)
            Button(saved ? "Saved" : "Save and Connect") {
                saving = true
                saved = false
                Task {
                    saved = await model.configure(
                        url: url, pairingToken: token, tailscaleOnly: tailscaleOnly
                    )
                    if saved {
                        url = model.configuredURL
                        token = ""
                        tailscaleOnly = model.tailscaleOnly
                    }
                    saving = false
                }
            }
            .disabled(
                saving
                    || (!model.hasStoredToken
                        && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )

            if saving {
                ProgressView("Saving…")
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if allowsClearing, model.hasConfiguration {
                Button("Clear Remote Connection", role: .destructive) {
                    model.clearConfiguration()
                    url = ""
                    token = ""
                    tailscaleOnly = false
                    saved = false
                }
            }
        } header: {
            Text("Cantrip Remote")
        } footer: {
            Text("Automatic mode prefers Tailscale and uses LAN only when needed. It never probes or switches to LAN while Tailscale is working. After falling back to LAN, read-only probes restore Tailscale without blocking refreshes. Tailscale only requires a saved URL. The pairing token remains in Keychain.")
        }
        .onAppear {
            url = model.configuredURL
            tailscaleOnly = model.tailscaleOnly
        }
    }
}

private struct CantripRemoteSettingsSheet: View {
    @ObservedObject var model: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CantripRemoteSettingsSection(model: model, allowsClearing: true)
            }
            .navigationTitle("Remote Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

enum CantripRemoteTabIcon {
    static func image(connected: Bool) -> UIImage {
        let size = CGSize(width: 30, height: 26)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            let symbol = UIImage(
                systemName: "antenna.radiowaves.left.and.right",
                withConfiguration: symbolConfiguration
            )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 2, y: 4, width: 21, height: 19))

            let dotRect = CGRect(x: 21, y: 2, width: 7, height: 7)
            context.cgContext.setFillColor(
                (connected ? UIColor.systemGreen : UIColor.systemGray).cgColor
            )
            context.cgContext.fillEllipse(in: dotRect)
            context.cgContext.setStrokeColor(UIColor.systemBackground.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
