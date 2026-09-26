import CryptoKit
import Foundation
import MarkdownUI
import Network
import Security
import SwiftUI
import UIKit

enum CantripRemoteConnectionState: Equatable {
    case disconnected
    case reconnecting
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
    var input: String? = nil
    var output: String? = nil
}

struct CantripRemoteMessage: Decodable, Equatable, Identifiable {
    let id: String
    let role: String
    let text: String
    let thinking: String
    let author: String?
    let activities: [CantripRemoteActivity]
    var displayText: String? = nil
    var images: [ChatMessageImage]? = nil
    var isPreview: Bool? = nil
    var isLocalPrivate: Bool? = nil

    var presentedText: String { displayText ?? text }
}

struct CantripRemoteQueuedPrompt: Decodable, Equatable, Identifiable {
    let id: String
    let text: String
    var displayText: String? = nil
    var images: [ChatMessageImage]? = nil

    var presentedText: String { displayText ?? text }
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
    var messages: [CantripRemoteMessage]?
    let supportsImageAttachments: Bool?
    let queued: [CantripRemoteQueuedPrompt]?
    var supportsAutoDelivery: Bool? = nil
    var deliveryStatus: String? = nil
    var supportsQueueRemoval: Bool? = nil
    var customTitle: String? = nil
    var isLocked: Bool? = nil
    var supportsTabMetadata: Bool? = nil
    var supportsTabReordering: Bool? = nil
    var supportsPagedHistory: Bool? = nil
    var supportsVideoAttachments: Bool? = nil
    var historyRevision: String? = nil
    var historyStartID: String? = nil
    var hasOlderMessages: Bool? = nil
    var supportsModelSettings: Bool? = nil
    var modelSettingsRevision: String? = nil
    var isLocalPrivate: Bool? = nil
    var supportsPrivateLocalSettings: Bool? = nil
    var supportsInputRequests: Bool? = nil
    var pendingInputCount: Int? = nil
    var supportsChatInputReplies: Bool? = nil
    var pendingInputs: [CantripInputRequest]? = nil

    var transcript: [CantripRemoteMessage] { messages ?? [] }
}

private struct CantripSessionsResponse: Decodable {
    let sessions: [CantripRemoteSession]
}

private struct CantripSessionResponse: Decodable {
    let session: CantripRemoteSession
}

private struct CantripSessionUpdate: Decodable {
    let session: CantripRemoteSession?
    let unchanged: Bool?
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
    case notSent(String)
    case http(Int, String)
    case decoding
    case invalidResponse
    case imagesUnsupported
    case videosUnsupported
    case autoDeliveryUnsupported
    case queueRemovalUnsupported
    case tabMetadataUnsupported
    case tabReorderingUnsupported
    case githubBuildsUnsupported
    case memoryUnsupported
    case maintenanceUnsupported
    case copilotUsageUnsupported
    case modelSettingsUnsupported
    case privateLocalUnsupported

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
        case .notSent(let message):
            return "\(message) The request was not sent. Check the connection and try again."
        case .http(let status, let message):
            return "Cantrip returned HTTP \(status): \(message)"
        case .decoding:
            return "Cantrip returned data this app could not read. Update both apps and try again."
        case .invalidResponse:
            return "Cantrip returned an invalid HTTP response."
        case .imagesUnsupported:
            return "Image attachments require an updated Cantrip host using Claude, Copilot, or Codex. Your images have not been sent."
        case .videosUnsupported:
            return "Video analysis requires an updated Cantrip host using Claude, Copilot, or Codex. Your video has not been sent."
        case .autoDeliveryUnsupported:
            return "Update and reopen Cantrip on your Mac for Auto sending, or choose Queue, Redirect, or Inject. Your message has not been sent."
        case .queueRemovalUnsupported:
            return "Update and reopen Cantrip on your Mac to remove queued messages from AgentGateway."
        case .tabMetadataUnsupported:
            return "Update and reopen Cantrip on your Mac to rename or lock its tabs."
        case .tabReorderingUnsupported:
            return "Update and reopen Cantrip on your Mac to reorder its tabs."
        case .githubBuildsUnsupported:
            return "Update and reopen Cantrip on your Mac to view GitHub builds."
        case .memoryUnsupported:
            return "Update and reopen Cantrip on your Mac to view its saved memory."
        case .maintenanceUnsupported:
            return "Update and reopen Cantrip on the Mac once to enable remote updates and rebuilds."
        case .copilotUsageUnsupported:
            return "Update and reopen Cantrip on your Mac to view Copilot account usage."
        case .modelSettingsUnsupported:
            return "Update and reopen Cantrip on your Mac to change a tab's model, effort and context window."
        case .privateLocalUnsupported:
            return "Update and reopen Cantrip on the Mac to use the saved Private Local tab. No cloud tab will be used instead."
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
        timeout = method == "GET" ? (CantripRemoteAPI.isContentRead(method: method, path: path) ? 20 : 2)
            : (payload.count > 256 * 1024 || path.contains("/videos/") ? 60 : 12)
        let header = """
        \(method) \(path) HTTP/1.1\r
        Host: cantrip.local\r
        Authorization: Bearer \(token)\r
        Accept: application/json\r
        Content-Type: \(method == "PUT" && path.contains("/videos/") ? "application/octet-stream" : "application/json")\r
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

private enum CantripHistoryWindow {
    static let recentExchanges = 3
}

struct CantripRemoteAPI {
    let transport: CantripTransport
    let token: String
    var urlSession: URLSession?

    static func isContentRead(method: String, path: String) -> Bool {
        let parts = (URLComponents(string: path)?.path ?? "").split(separator: "/")
        return method == "GET" && (
            parts == ["api", "v1", "maintenance"]
                || parts == ["api", "v1", "memory"] || parts == ["api", "v1", "memory", "document"]
                || (parts.starts(with: ["api", "v1", "sessions"])
                    && (parts.count == 4 || (parts.count == 6 && parts[4] == "messages")))
        )
    }

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

    func completionNotifications(method: String = "GET", body: Data? = nil) async throws -> CantripPushStatus {
        do {
            return try await request(path: "/api/v1/notifications", method: method, body: body)
        } catch CantripRemoteError.http(404, _) {
            throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to enable completion alerts.")
        }
    }

    func githubBuilds() async throws -> CantripBuildSnapshot {
        do {
            return try await request(path: "/api/v1/github/builds")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.githubBuildsUnsupported
        }
    }

    func maintenance(_ action: CantripMaintenanceRequest? = nil) async throws -> CantripMaintenanceSnapshot {
        do {
            return try await request(path: "/api/v1/maintenance",
                method: action == nil ? "GET" : "POST",
                body: try action.map { try JSONEncoder().encode($0) })
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.maintenanceUnsupported
        }
    }

    func copilotUsage() async throws -> CopilotUsageSnapshot {
        do {
            return try await request(path: "/api/v1/copilot/usage")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.copilotUsageUnsupported
        }
    }

    func memoryCatalog(query: String, after: String?) async throws -> CantripMemoryCatalog {
        var target = URLComponents()
        target.path = "/api/v1/memory"
        target.queryItems = [URLQueryItem(name: "q", value: query)]
        if let after { target.queryItems?.append(URLQueryItem(name: "after", value: after)) }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        do {
            return try await request(path: path)
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.memoryUnsupported
        }
    }

    func memoryDocument(id: String, offset: Int, revision: String?) async throws -> CantripMemoryPage {
        var target = URLComponents()
        target.path = "/api/v1/memory/document"
        target.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "offset", value: String(offset))]
        if let revision { target.queryItems?.append(URLQueryItem(name: "revision", value: revision)) }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        let page: CantripMemoryPage = try await request(path: path)
        guard page.document.id == id, page.offset == offset,
              page.nextOffset.map({ $0 > offset && $0 <= page.document.bytes }) ?? true,
              revision == nil || revision == page.revision else { throw CantripRemoteError.invalidResponse }
        return page
    }

    func imageData(sessionID: String, imageID: String, thumbnail: Bool) async throws -> Data {
        guard UUID(uuidString: sessionID) != nil, ChatMessageImage.validRemoteID(imageID) else {
            throw CantripRemoteError.invalidResponse
        }
        struct ImageResponse: Decodable { let data: Data }
        let isPreview = ChatMessageImage.validPreviewID(imageID)
        let response: ImageResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/" + (isPreview ? imageID : "attachments/\(imageID)")
                + (thumbnail ? "/thumbnail" : "")
        )
        guard !response.data.isEmpty,
              response.data.count <= (isPreview ? GeneratedImagePreview.maximumImageBytes
                                               : ImageAttachmentProcessor.maximumImageBytes) else {
            throw ImageAttachmentError.invalidImage
        }
        return response.data
    }

    func session(id: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)", includeRecentExchanges: true
        )
        return response.session
    }

    func createSession() async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions",
            method: "POST", includeRecentExchanges: true
        )
        return response.session
    }

    func sessionUpdate(id: String, revision: String?) async throws -> CantripRemoteSession? {
        var path = "/api/v1/sessions/\(id)"
        if let revision {
            var components = URLComponents()
            components.path = path
            components.queryItems = [URLQueryItem(name: "revision", value: revision)]
            guard let target = components.string else { throw CantripRemoteError.invalidResponse }
            path = target
        }
        let response: CantripSessionUpdate = try await request(path: path, includeRecentExchanges: true)
        if let session = response.session { return session }
        guard response.unchanged == true, revision != nil else {
            throw CantripRemoteError.invalidResponse
        }
        return nil
    }

    func olderMessages(id: String, before: String) async throws -> CantripRemoteSession {
        guard UUID(uuidString: before) != nil else { throw CantripRemoteError.invalidResponse }
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)?before=\(before)"
        )
        return response.session
    }

    func fullMessage(sessionID: String, messageID: String) async throws -> CantripRemoteMessage {
        guard UUID(uuidString: sessionID) != nil, UUID(uuidString: messageID) != nil else {
            throw CantripRemoteError.invalidResponse
        }
        struct Response: Decodable { let message: CantripRemoteMessage }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/messages/\(messageID)")
        return response.message
    }

    func send(
        _ text: String,
        mode: CantripDeliveryMode,
        sessionID: String,
        images: [ChatImageAttachment] = []
    ) async throws
        -> CantripRemoteSession {
        let body = try await prepareMessage(text, mode: mode, sessionID: sessionID, images: images)
        return try await sendMessage(body, sessionID: sessionID)
    }

    fileprivate func prepareMessage(
        _ text: String, mode: CantripDeliveryMode, sessionID: String,
        images: [ChatImageAttachment], videoID: String? = nil, inputRequestID: UUID? = nil
    ) async throws -> Data {
        guard images.count <= ImageAttachmentProcessor.maximumCount else {
            throw ImageAttachmentError.tooMany
        }
        // Confirm reachability and capabilities on the route that will receive the write.
        let host = try await session(id: sessionID)
        if let inputRequestID {
            guard mode == .auto, host.supportsChatInputReplies == true else {
                throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to send chat replies with attachments.")
            }
            guard host.pendingInputs?.contains(where: {
                $0.id == inputRequestID && $0.kind == "question" && $0.expiresAt > Date().timeIntervalSince1970
            }) == true else {
                throw CantripRemoteError.http(409, "This question was already answered, cancelled or expired. Your reply was not queued.")
            }
        }
        guard images.isEmpty || host.supportsImageAttachments == true else {
            throw CantripRemoteError.imagesUnsupported
        }
        guard videoID == nil || host.supportsVideoAttachments == true else {
            throw CantripRemoteError.videosUnsupported
        }
        guard videoID == nil || images.isEmpty else { throw VideoAttachmentError.mixedAttachments }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard videoID == nil || (!trimmed.hasPrefix("/") && !trimmed.hasPrefix("!")) else {
            throw VideoAttachmentError.command
        }
        guard mode != .auto || host.supportsAutoDelivery == true else {
            throw CantripRemoteError.autoDeliveryUnsupported
        }
        return try JSONEncoder().encode(CantripMessageBody(text: text, mode: mode, images: images,
                                                         videoID: videoID, inputRequestID: inputRequestID))
    }

    func videoStatus(sessionID: String, uploadID: UUID) async throws -> CantripVideoUploadStatus? {
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        do {
            let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/videos/\(uploadID)")
            return response.upload
        } catch CantripRemoteError.http(404, _) { return nil }
    }

    func uploadVideoChunk(_ data: Data, video: ChatVideoAttachment, sessionID: String,
                          offset: Int) async throws -> CantripVideoUploadStatus {
        var target = URLComponents()
        target.path = "/api/v1/sessions/\(sessionID)/videos/\(video.id)"
        target.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "totalBytes", value: String(video.bytes)),
            URLQueryItem(name: "format", value: video.format),
            URLQueryItem(name: "name", value: video.name),
            URLQueryItem(name: "sha256", value: video.sha256),
        ]
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
        struct Response: Decodable { let upload: CantripVideoUploadStatus }
        let response: Response = try await request(path: path, method: "PUT", body: data)
        return response.upload
    }

    func prepareVideo(sessionID: String, uploadID: UUID) async throws {
        struct Response: Decodable { let ready: Bool }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/videos/\(uploadID)/prepare",
                                                   method: "POST")
        guard response.ready else { throw CantripRemoteError.invalidResponse }
    }

    fileprivate func sendMessage(_ body: Data, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/messages",
            method: "POST",
            body: body, includeRecentExchanges: true
        )
        return response.session
    }

    func action(_ action: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/\(action)",
            method: "POST", includeRecentExchanges: true
        )
        return response.session
    }

    func closeSession(id: String) async throws -> CantripRemoteSession {
        try await action("close", sessionID: id)
    }

    func modelSettings(id: String, refreshModels: Bool = false) async throws -> CantripModelSettings {
        do {
            return try await request(path: "/api/v1/sessions/\(id)/model-settings"
                                     + (refreshModels ? "?refresh=true" : ""))
        } catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            let host = try await session(id: id)
            guard host.supportsModelSettings == true else { throw CantripRemoteError.modelSettingsUnsupported }
            throw CantripRemoteError.http(status, "This tab's model settings are no longer available.")
        }
    }

    func privateLocalSettings(id: String) async throws -> CantripPrivateLocalSettings {
        do {
            return try await request(path: "/api/v1/sessions/\(id)/private-settings")
        } catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            throw CantripRemoteError.privateLocalUnsupported
        }
    }

    func inputRequests(sessionID: String) async throws -> [CantripInputRequest] {
        struct Response: Decodable { let requests: [CantripInputRequest] }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/input")
        return response.requests
    }

    func macAccess() async throws -> CantripMacAccess {
        do { return try await request(path: "/api/v1/mac-access") }
        catch CantripRemoteError.http(let status, _) where status == 404 || status == 405 {
            throw ServerConfigurationError(message: "Update and reopen Cantrip on the Mac to enable Mac Permissions & View Mac.")
        }
    }

    func openMacSettings(_ permission: String) async throws {
        struct Response: Decodable { let opened: Bool }
        let response: Response = try await request(path: "/api/v1/mac-access", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["permission": permission]))
        guard response.opened else { throw CantripRemoteError.invalidResponse }
    }

    func startDesktop(control: Bool) async throws -> CantripDesktopLease {
        try await request(path: "/api/v1/desktop/start", method: "POST",
                          body: JSONSerialization.data(withJSONObject: ["control": control]))
    }

    func desktopFrame(lease: CantripDesktopLease, displayID: UInt32) async throws -> CantripDesktopFrame {
        try await request(path: "/api/v1/desktop/frame", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token, "displayID": displayID]))
    }

    func desktopInput(lease: CantripDesktopLease, sequence: Int, encrypted: String) async throws {
        struct Response: Decodable { let accepted: Bool }
        let response: Response = try await request(path: "/api/v1/desktop/input", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token,
                                                         "sequence": sequence, "encrypted": encrypted]))
        guard response.accepted else { throw CantripRemoteError.invalidResponse }
    }

    func stopDesktop(lease: CantripDesktopLease) async throws {
        struct Response: Decodable { let stopped: Bool }
        let response: Response = try await request(path: "/api/v1/desktop/stop", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["id": lease.id.uuidString, "token": lease.token]))
        guard response.stopped else { throw CantripRemoteError.invalidResponse }
    }

    fileprivate func prepareInput(sessionID: String, id: UUID, answer: CantripInputAnswer,
                                  questionOnly: Bool = false) async throws -> Data {
        let current = try await inputRequests(sessionID: sessionID)
        guard current.contains(where: {
            $0.id == id && $0.expiresAt > Date().timeIntervalSince1970 && (!questionOnly || $0.kind == "question")
        }) else {
            throw CantripRemoteError.http(409, "This request was already answered, cancelled or expired.")
        }
        return try JSONEncoder().encode(answer)
    }

    fileprivate func respondToInput(sessionID: String, id: UUID, body: Data) async throws -> Bool {
        struct Response: Decodable { let accepted: Bool }
        let response: Response = try await request(path: "/api/v1/sessions/\(sessionID)/input/\(id)",
                                                   method: "POST", body: body)
        return response.accepted
    }

    func privateLocalModels(id: String, baseURL: String) async throws -> [String] {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "baseURL", value: baseURL)]
        struct Response: Decodable { let models: [String] }
        let response: Response = try await request(path: "/api/v1/sessions/\(id)/private-models?\(query.percentEncodedQuery ?? "")")
        return response.models
    }

    fileprivate func preparePrivateLocalSettings(id: String, change: CantripPrivateLocalChange) async throws -> Data {
        let current = try await privateLocalSettings(id: id)
        guard current.revision == change.revision else {
            throw CantripRemoteError.http(409, "Private Local settings changed on another device. Reload before saving.")
        }
        if let reason = current.unavailableReason { throw CantripRemoteError.http(409, reason) }
        return try JSONEncoder().encode(change)
    }

    fileprivate func updatePrivateLocalSettings(id: String, body: Data) async throws -> CantripPrivateLocalSettings {
        try await request(path: "/api/v1/sessions/\(id)/private-settings", method: "POST", body: body)
    }

    fileprivate func prepareModelSettings(id: String, change: CantripModelSettingsChange) async throws -> Data {
        let current = try await modelSettings(id: id)
        guard current.revision == change.revision else {
            throw CantripRemoteError.http(409, "Model settings changed on another device. Reload before saving.")
        }
        if let reason = current.unavailableReason { throw CantripRemoteError.http(409, reason) }
        return try JSONEncoder().encode(change)
    }

    fileprivate func updateModelSettings(id: String, body: Data) async throws -> CantripModelSettings {
        try await request(path: "/api/v1/sessions/\(id)/model-settings", method: "POST", body: body)
    }

    func updateTab(id: String, name: String? = nil, isLocked: Bool? = nil) async throws -> CantripRemoteSession {
        let body = try await prepareTabUpdate(id: id, name: name, isLocked: isLocked)
        return try await updateTab(id: id, body: body)
    }

    fileprivate func prepareTabUpdate(id: String, name: String?, isLocked: Bool?) async throws -> Data {
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
        return try JSONEncoder().encode(Body(customTitle: validatedName, isLocked: isLocked))
    }

    fileprivate func updateTab(id: String, body: Data) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(id)/metadata",
            method: "POST",
            body: body, includeRecentExchanges: true
        )
        return response.session
    }

    fileprivate func prepareTabMove(id: String, targetID: String, after: Bool) async throws -> Data {
        let host = try await session(id: id)
        guard host.supportsTabReordering == true else {
            throw CantripRemoteError.tabReorderingUnsupported
        }
        struct Body: Encodable {
            let targetID: String
            let placement: String
        }
        return try JSONEncoder().encode(Body(targetID: targetID, placement: after ? "after" : "before"))
    }

    fileprivate func moveTab(id: String, body: Data) async throws -> [CantripRemoteSession] {
        let response: CantripSessionsResponse = try await request(
            path: "/api/v1/sessions/\(id)/move", method: "POST", body: body
        )
        return response.sessions
    }

    func removeQueuedPrompt(id: String, sessionID: String) async throws -> CantripRemoteSession {
        try await prepareQueueRemoval(sessionID: sessionID)
        return try await deleteQueuedPrompt(id: id, sessionID: sessionID)
    }

    fileprivate func prepareQueueRemoval(sessionID: String) async throws {
        let host = try await session(id: sessionID)
        guard host.supportsQueueRemoval == true else {
            throw CantripRemoteError.queueRemovalUnsupported
        }
    }

    fileprivate func deleteQueuedPrompt(id: String, sessionID: String) async throws -> CantripRemoteSession {
        let response: CantripSessionResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/queue/\(id)",
            method: "DELETE", includeRecentExchanges: true
        )
        return response.session
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        includeRecentExchanges: Bool = false
    ) async throws -> Response {
        try Task.checkCancellation()
        guard var target = URLComponents(string: path), target.host == nil else {
            throw CantripRemoteError.invalidResponse
        }
        target.queryItems = (target.queryItems ?? []) + [URLQueryItem(name: "history", value: "recent")]
        if includeRecentExchanges {
            target.queryItems?.append(URLQueryItem(name: "recentExchanges",
                                                  value: String(CantripHistoryWindow.recentExchanges)))
        }
        guard let path = target.string else { throw CantripRemoteError.invalidResponse }
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
        let isImageUpload = (body?.count ?? 0) > 256 * 1024 || (method != "GET" && path.contains("/videos/"))
        let isContentRead = Self.isContentRead(method: method, path: path)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: method == "GET" ? (isContentRead ? 20 : 3) : (isImageUpload ? 60 : 12)
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(method == "PUT" && path.contains("/videos/") ? "application/octet-stream" : "application/json",
                             forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            let session = urlSession ?? (method == "GET" && !isContentRead
                ? Self.readSession : (isImageUpload ? Self.imageSession : Self.session))
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
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let target = URLComponents(string: path), target.host == nil
        else { throw CantripRemoteError.invalidResponse }
        components.percentEncodedPath = target.percentEncodedPath
        components.percentEncodedQuery = target.percentEncodedQuery
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
    @Published var modelSettingsSession: CantripRemoteSession?
    @Published var inputRequestsSession: CantripRemoteSession?
    @Published var inputContext: CantripInputContext?
    @Published var inputReplyID: UUID?
    @Published var showingMacAccess = false
    @Published private(set) var connectionState: CantripRemoteConnectionState = .disconnected
    @Published private(set) var configuredURL: String
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var sessions: [CantripRemoteSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedSession: CantripRemoteSession?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var videoUploadProgress: VideoUploadProgress?
    private var videoUploadTask: Task<Void, Error>?
    var isUploadingVideo: Bool { videoUploadTask != nil }
    @Published private(set) var isReorderingTabs = false
    @Published private(set) var stoppingSessionID: String?
    @Published private(set) var detailError: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyPrependRevision = 0
    private(set) var historyPrependAnchor: String?
    private var detailCache: [String: CantripRemoteSession] = [:]
    private var cacheOrder: [String] = []
    private var expandedHistory: Set<String> = []
    private var automaticHistoryRemaining: [String: Int] = [:]
    private static let automaticHistoryLimit = 10
    var canAutomaticallyLoadHistory: Bool {
        guard let session = selectedSession, session.hasOlderMessages == true else { return false }
        return (automaticHistoryRemaining[session.id] ?? 0) > 0
    }
    private var selectionRevision = 0
    private var selectingSessionID: String?
    private var mutationRevision = 0
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var isLocalNetworkAvailable = false
    @Published private(set) var tailscaleOnly: Bool
    @Published private(set) var usageIdentity = UUID()
    let servers: ServerProfiles
    @Published private(set) var selectedServerID: UUID?
    @Published private(set) var notificationStatus: String?
    @Published private(set) var isUpdatingNotifications = false
    @Published private(set) var notificationNavigationID = UUID()
    private var notificationRegistrationTask: Task<Void, Never>?
    private let completionAlerts: CantripNotifications
    private var notificationRegistrationSucceeded = false
    private var notificationRegistrationAttempt: Date?

    var isConnected: Bool { connectionState == .connected }
    var connectionLabel: String {
        switch connectionState {
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .disconnected: return "Disconnected"
        }
    }
    var pollDelay: Duration {
        sessions.contains(where: { $0.isStreaming || $0.queuedCount > 0 })
            || detailError != nil || !isConnected ? Self.pollInterval : .seconds(5)
    }
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
    private var detailRefreshTask: Task<Void, Never>?
    private var detailRefreshKey: String?
    private var detailRefreshID = UUID()
    private var staleTask: Task<Void, Never>?
    private var lastAuthenticatedAt: Date?
    private var configurationGeneration = 0
    private var lanEndpoints: [NWEndpoint] = []
    private var activeTransport: CantripTransport?
    private let lanBrowser = CantripLANBrowser()
    private let requestGate = CantripRequestGate()
    private let router = CantripRemoteRouter()
    private let urlSession: URLSession?
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 12 << 20
        return cache
    }()

    private let authorizeSensitiveAction: (String) async throws -> Void

    init(urlSession: URLSession? = nil, servers: ServerProfiles? = nil,
         completionAlerts: CantripNotifications? = nil,
         authorizeSensitiveAction: @escaping (String) async throws -> Void = CantripBiometrics.authorize) {
        self.urlSession = urlSession
        self.authorizeSensitiveAction = authorizeSensitiveAction
        self.completionAlerts = completionAlerts ?? .shared
        self.servers = servers ?? ServerProfiles(kind: .cantrip)
        let storedURL = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        configuredURL = storedURL
        tailscaleOnly = UserDefaults.standard.bool(forKey: Self.tailscaleOnlyKey)
        token = CantripRemoteCredentials.loadToken()
        hasStoredToken = token != nil
        do {
            if !self.servers.hasSavedState, let token {
                try self.servers.migrate(url: storedURL, credential: token, tailscaleOnly: tailscaleOnly)
            }
            if let server = self.servers.selected {
                token = try self.servers.credential(for: server)
                configuredURL = server.url
                tailscaleOnly = server.tailscaleOnly
                selectedServerID = server.id
            } else if self.servers.hasSavedState {
                configuredURL = ""
                token = nil
                tailscaleOnly = false
            }
            if let issue = self.servers.loadIssue {
                throw ServerConfigurationError(message: issue)
            }
            hasStoredToken = token != nil
            baseURL = try Self.normalizedBaseURL(configuredURL)
            if baseURL == nil, !configuredURL.isEmpty {
                errorMessage = "The saved Remote URL is invalid. Open settings and save it again."
            }
        } catch {
            baseURL = nil
            token = nil
            hasStoredToken = false
            errorMessage = error.localizedDescription
        }
    }

    func addServer(_ draft: ServerDraft) throws {
        try servers.add(draft)
    }

    func selectServer(_ server: SavedServer) async throws {
        guard selectedServerID != server.id else { return }
        let credential = try servers.credential(for: server)
        guard await configure(
            url: server.url, pairingToken: credential, tailscaleOnly: server.tailscaleOnly
        ) else {
            throw ServerConfigurationError(message: errorMessage ?? "Could not select the server.")
        }
        try servers.select(server)
        selectedServerID = server.id
        notificationStatus = nil
        refreshCompletionNotificationRegistration(force: true)
    }

    func removeServer(_ server: SavedServer) throws {
        guard !isUpdatingNotifications else {
            throw ServerConfigurationError(message: "Wait for notification settings to finish updating.")
        }
        guard !completionAlerts.hasSubscription(serverID: server.id) else {
            throw ServerConfigurationError(message: "Select this Mac and turn off its completion alerts before removing it.")
        }
        guard !isMutating, !isUploadingVideo else {
            throw ServerConfigurationError(message: "Wait for the current request to finish before removing a server.")
        }
        if selectedServerID == server.id {
            guard clearConfiguration() else {
                throw ServerConfigurationError(message: errorMessage ?? "Could not disconnect the server.")
            }
        }
        try servers.remove(server)
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        if active {
            startLANDiscovery()
            startPolling()
            refreshCompletionNotificationRegistration(force: true)
        } else {
            videoUploadTask?.cancel()
            lanBrowser.stop()
            stopPolling()
        }
    }

    func completionNotificationStatus() async throws -> CantripPushStatus {
        try await performAuthenticated(allowFallback: true) { try await $0.completionNotifications() }
    }

    func setCompletionNotifications(enabled: Bool) async throws {
        guard !isUpdatingNotifications else {
            throw ServerConfigurationError(message: "Wait for notification settings to finish updating.")
        }
        guard let serverID = selectedServerID, let token else {
            throw ServerConfigurationError(message: "Save and select a Cantrip server first.")
        }
        isUpdatingNotifications = true
        defer { isUpdatingNotifications = false }
        let identity = usageIdentity
        let notifications = completionAlerts
        var body: [String: Any] = ["installationID": notifications.installationID.uuidString,
                                      "serverID": serverID.uuidString]
        if enabled {
            let status = try await completionNotificationStatus()
            guard status.configured else { throw ServerConfigurationError(message: status.message) }
            body["deviceToken"] = try await notifications.register()
            guard let environment = Bundle.main.object(forInfoDictionaryKey: "CantripPushEnvironment") as? String,
                  ["development", "production"].contains(environment) else {
                throw ServerConfigurationError(message: "This build has no valid Apple push environment.")
            }
            body["environment"] = environment
            body["inputNeeded"] = true
        }
        guard usageIdentity == identity, selectedServerID == serverID else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: body)
        if enabled {
            notifications.prepareRegistration(serverID: serverID, fingerprint: CantripLANProtocol.tokenFingerprint(token))
        }
        // Registration/removal are idempotent, so an uncertain response can
        // safely retry over the other authenticated route.
        _ = try await performAuthenticated(allowFallback: true) {
            try await $0.completionNotifications(method: enabled ? "POST" : "DELETE", body: data)
        }
        guard usageIdentity == identity, selectedServerID == serverID else { throw CancellationError() }
        notifications.save(serverID: serverID, fingerprint: enabled ? CantripLANProtocol.tokenFingerprint(token) : nil)
        notificationStatus = nil
        notificationRegistrationSucceeded = enabled
    }

    func refreshCompletionNotificationRegistration(force: Bool = false) {
        if force {
            notificationRegistrationSucceeded = false
            notificationRegistrationAttempt = nil
        }
        guard appIsActive, isConfigured, !isUpdatingNotifications, notificationRegistrationTask == nil,
              !notificationRegistrationSucceeded,
              notificationRegistrationAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              completionAlerts.hasSubscription(serverID: selectedServerID) else { return }
        notificationRegistrationAttempt = Date()
        let identity = usageIdentity
        notificationRegistrationTask = Task { [weak self] in
            guard let self else { return }
            defer { notificationRegistrationTask = nil }
            do { try await setCompletionNotifications(enabled: true) }
            catch is CancellationError {}
            catch {
                if usageIdentity == identity { notificationStatus = error.localizedDescription }
            }
        }
    }

    func openCompletionNotification(_ target: CantripNotificationTarget) async {
        do {
            await notificationRegistrationTask?.value
            guard let server = servers.servers.first(where: { $0.id == target.serverID }),
                  CantripLANProtocol.tokenFingerprint(try servers.credential(for: server)) == target.fingerprint else {
                throw ServerConfigurationError(message: "This notification belongs to a removed or re-paired Cantrip server.")
            }
            try await selectServer(server)
            guard !isMutating, !isUploadingVideo else {
                throw ServerConfigurationError(message: "Finish the current upload or request before opening this notification.")
            }
            await selectSession(target.sessionID.uuidString)
            if target.kind == "input" {
                showingMacAccess = false
                inputRequestsSession = nil
            }
            if target.kind == "macAttention" {
                inputRequestsSession = nil
                showingMacAccess = true
            }
            notificationNavigationID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configure(
        url rawURL: String,
        pairingToken rawToken: String,
        tailscaleOnly: Bool = false
    ) async -> Bool {
        guard !isMutating, !isUploadingVideo, !isUpdatingNotifications else {
            errorMessage = "Wait for the current request to finish before switching servers."
            return false
        }
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
            lanBrowser.stop()
            configurationGeneration += 1
            usageIdentity = UUID()
            imageCache.removeAllObjects()
            resetHistory()
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
            sessions = []
            selectedSessionID = nil
            selectedSession = nil
            transcriptRevision += 1
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

    @discardableResult
    func clearConfiguration() -> Bool {
        guard !isMutating, !isUploadingVideo, !isUpdatingNotifications else {
            errorMessage = "Wait for the current request to finish before disconnecting."
            return false
        }
        do {
            try CantripRemoteCredentials.removeToken()
            stopPolling()
            lanBrowser.stop()
            configurationGeneration += 1
            usageIdentity = UUID()
            imageCache.removeAllObjects()
            resetHistory()
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
            selectedServerID = nil
            errorMessage = nil
            transcriptRevision += 1
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshNow() async {
        await refresh()
        await detailRefreshTask?.value
    }

    func githubBuilds() async throws -> CantripBuildSnapshot {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view GitHub builds.")
        }
        return try await performAuthenticated(allowFallback: true) { api in
            try await api.githubBuilds()
        }
    }

    func memoryCatalog(query: String, after: String?) async throws -> CantripMemoryCatalog {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view its saved memory.")
        }
        return try await performHistoryRead { try await $0.memoryCatalog(query: query, after: after) }
    }

    func maintenanceStatus() async throws -> CantripMaintenanceSnapshot {
        try await performHistoryRead { try await $0.maintenance() }
    }

    func startMaintenance(_ request: CantripMaintenanceRequest) async throws -> CantripMaintenanceSnapshot {
        guard let token else { throw CantripRemoteError.missingToken }
        let generation = configurationGeneration
        updateRoutes()
        let reader = router.independentReader()
        let result = try await reader.performMutation { transport in
            try await CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession).maintenance()
        } operation: { transport, _ in
            guard generation == self.configurationGeneration else { throw CancellationError() }
            return try await CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession).maintenance(request)
        }
        guard generation == configurationGeneration else { throw CancellationError() }
        return result
    }

    func memoryDocument(id: String, offset: Int, revision: String?) async throws -> CantripMemoryPage {
        try await performHistoryRead { try await $0.memoryDocument(id: id, offset: offset, revision: revision) }
    }

    func copilotUsage() async throws -> CopilotUsageSnapshot {
        guard isConfigured else {
            throw CantripRemoteError.transport("Configure Cantrip Remote in Settings and connect to your Mac to view Copilot usage.")
        }
        return try await performAuthenticated(allowFallback: true) { api in
            try await api.copilotUsage()
        }
    }

    func image(sessionID: String, imageID: String, thumbnail: Bool) async throws -> UIImage {
        let identity = usageIdentity
        let key = "\(usageIdentity)/\(sessionID)/\(imageID)/\(thumbnail)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let data = try await performAuthenticated(allowFallback: true) { api in
            try await api.imageData(sessionID: sessionID, imageID: imageID, thumbnail: thumbnail)
        }
        let isPreview = ChatMessageImage.validPreviewID(imageID)
        let image = try await Task.detached(priority: .userInitiated) {
            try ChatImageDecoder.decode(
                data, maximumDimension: isPreview
                    ? (thumbnail ? GeneratedImagePreview.thumbnailDimension : GeneratedImagePreview.maximumDimension)
                    : (thumbnail ? 320 : ImageAttachmentProcessor.maximumDimension),
                maximumBytes: isPreview ? GeneratedImagePreview.maximumImageBytes : ImageAttachmentProcessor.maximumImageBytes
            )
        }.value
        try Task.checkCancellation()
        guard identity == usageIdentity else { throw CancellationError() }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        imageCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    func selectSession(_ id: String) async {
        guard id != selectedSessionID || selectedSession?.id != id else { return }
        cancelDetailRefresh()
        selectionRevision += 1
        let selection = selectionRevision
        let revision = mutationRevision
        selectingSessionID = id
        defer {
            if selection == selectionRevision { selectingSessionID = nil }
        }
        selectedSessionID = id
        selectedSession = detailCache[id]
        detailError = nil
        transcriptRevision += 1
        do {
            let detail = try await performHistoryRead { api in
                try await api.session(id: id)
            }
            guard selectedSessionID == id, selection == selectionRevision,
                  revision == mutationRevision else { return }
            apply(detail)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard selectedSessionID == id, selection == selectionRevision else { return }
            detailError = "Could not update this conversation. \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            handleReadFailure(error, detailOnly: true)
        }
    }

    func loadOlderMessages(automatically: Bool = false) async {
        guard !automatically || canAutomaticallyLoadHistory else { return }
        guard !isLoadingHistory, !isMutating,
              let current = selectedSession, current.hasOlderMessages == true,
              let before = current.transcript.first?.id else { return }
        let revision = mutationRevision
        let selection = selectionRevision
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let page = try await performHistoryRead { api in
                try await api.olderMessages(id: current.id, before: before)
            }
            guard revision == mutationRevision, selection == selectionRevision,
                  var latest = selectedSession, latest.id == current.id,
                  page.id == current.id,
                  latest.historyStartID == page.historyStartID,
                  latest.transcript.first?.id == before else { return }
            let existing = Set(latest.transcript.map(\.id))
            let received = page.transcript.filter { !existing.contains($0.id) }
            guard !received.isEmpty || page.hasOlderMessages == false else {
                throw CantripRemoteError.invalidResponse
            }
            let added = automatically
                ? Self.historySuffix(received, groups: automaticHistoryRemaining[current.id] ?? 0)
                : received
            latest.messages = added + latest.transcript
            latest.hasOlderMessages = added.count < received.count || page.hasOlderMessages == true
            automaticHistoryRemaining[current.id] = automatically
                ? max(0, (automaticHistoryRemaining[current.id] ?? 0)
                      - max(1, added.filter { $0.role == "user" }.count))
                : 0
            expandedHistory.insert(current.id)
            historyPrependAnchor = before
            apply(latest, mergeHistory: false)
            historyPrependRevision += 1
            detailError = nil
        } catch is CancellationError {
            return
        } catch {
            guard selection == selectionRevision else { return }
            automaticHistoryRemaining[current.id] = 0
            detailError = "Could not load older messages. \(error.localizedDescription)"
            handleReadFailure(error, detailOnly: true)
        }
    }

    func fullMessage(sessionID: String, messageID: String) async throws -> CantripRemoteMessage {
        try await performHistoryRead { api in
            try await api.fullMessage(sessionID: sessionID, messageID: messageID)
        }
    }

    private func performHistoryRead<T>(
        _ operation: (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard let token else { throw CantripRemoteError.missingToken }
        let generation = configurationGeneration
        updateRoutes()
        // Large history downloads must not hold the polling/mutation request gate.
        let reader = router.independentReader()
        let result = try await reader.perform(readOnly: true) { transport in
            try await operation(CantripRemoteAPI(transport: transport, token: token, urlSession: urlSession))
        }
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        return result
    }

    func modelSettings(id: String, refreshModels: Bool = false) async throws -> CantripModelSettings {
        try await performHistoryRead { try await $0.modelSettings(id: id, refreshModels: refreshModels) }
    }

    func updateModelSettings(id: String, change: CantripModelSettingsChange, identity: UUID) async -> Bool {
        guard identity == usageIdentity else {
            errorMessage = "The connected Mac changed. Reopen model settings before saving."
            return false
        }
        let result = await mutate(prepare: { api in
            try await api.prepareModelSettings(id: id, change: change)
        }, { api, body in
            try await api.updateModelSettings(id: id, body: body)
        })
        return result != nil
    }

    func privateLocalSettings(id: String) async throws -> CantripPrivateLocalSettings {
        try await performHistoryRead { try await $0.privateLocalSettings(id: id) }
    }

    func privateLocalModels(id: String, baseURL: String) async throws -> [String] {
        try await performHistoryRead { try await $0.privateLocalModels(id: id, baseURL: baseURL) }
    }

    func inputRequests(sessionID: String) async throws -> [CantripInputRequest] {
        try await performHistoryRead { try await $0.inputRequests(sessionID: sessionID) }
    }

    func showInputRequests(sessionID: String) async {
        await selectSession(sessionID)
        inputRequestsSession = nil
        notificationNavigationID = UUID()
    }

    func macAccess() async throws -> CantripMacAccess {
        try await performHistoryRead { try await $0.macAccess() }
    }

    func openMacSettings(_ permission: String, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        let result: Bool? = await mutate(prepare: { api in _ = try await api.macAccess() }, { api, _ in
            try await api.openMacSettings(permission)
            return true
        })
        guard result == true else { throw ServerConfigurationError(message: errorMessage ?? "Settings could not be opened.") }
    }

    func startDesktop(control: Bool, identity: UUID) async throws -> CantripDesktopLease {
        guard usageIdentity == identity else { throw CancellationError() }
        try await authorizeSensitiveAction(control ? "Allow viewing and controlling your Mac for five minutes." : "Allow viewing your Mac screen for five minutes.")
        try Task.checkCancellation()
        guard usageIdentity == identity else { throw CancellationError() }
        let result = await mutate(prepare: { api in
            let status = try await api.macAccess()
            guard status.desktopEnabled else { throw ServerConfigurationError(message: "Enable View Mac in Cantrip settings on the Mac first.") }
        }, { api, _ in try await api.startDesktop(control: control) })
        guard let result else { throw ServerConfigurationError(message: errorMessage ?? "View Mac could not start. It may have reached the Mac; check before retrying.") }
        return result
    }

    func desktopFrame(lease: CantripDesktopLease, displayID: UInt32, identity: UUID) async throws -> CantripDesktopFrame {
        guard usageIdentity == identity else { throw CancellationError() }
        return try await performHistoryRead { try await $0.desktopFrame(lease: lease, displayID: displayID) }
    }

    func desktopInput(lease: CantripDesktopLease, sequence: Int, encrypted: String, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        let result: Bool? = await mutate(prepare: { api in _ = try await api.macAccess() }, { api, _ in
            try await api.desktopInput(lease: lease, sequence: sequence, encrypted: encrypted)
            return true
        })
        guard result == true else { throw ServerConfigurationError(message: errorMessage ?? "Desktop input could not be confirmed.") }
    }

    func stopDesktop(lease: CantripDesktopLease, identity: UUID) async throws {
        guard usageIdentity == identity else { throw CancellationError() }
        // Stop is idempotent in effect, but still never replay keyboard/pointer commands.
        try await performHistoryRead { try await $0.stopDesktop(lease: lease) }
    }

    func respondToInput(sessionID: String, id: UUID, answer: CantripInputAnswer, identity: UUID,
                        questionOnly: Bool = false) async -> Bool {
        guard usageIdentity == identity else {
            errorMessage = "The connected Mac changed. Reopen the input request before responding."
            return false
        }
        if !questionOnly && (answer.decision == "approve" || answer.decision == "submit") {
            do {
                try await authorizeSensitiveAction("Confirm your response to the pending Cantrip request.")
                try Task.checkCancellation()
                guard usageIdentity == identity else { throw CancellationError() }
            } catch is CancellationError {
                errorMessage = "Authentication was cancelled or the connected Mac changed. Nothing was sent."
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        let accepted = await mutate(prepare: { api in
            try await api.prepareInput(sessionID: sessionID, id: id, answer: answer, questionOnly: questionOnly)
        }, { api, data in
            try await api.respondToInput(sessionID: sessionID, id: id, body: data)
        })
        return accepted == true
    }

    func updatePrivateLocalSettings(id: String, change: CantripPrivateLocalChange, identity: UUID) async -> Bool {
        guard identity == usageIdentity else {
            errorMessage = "The connected Mac changed. Reopen Private Local settings before saving."
            return false
        }
        let result = await mutate(prepare: { api in
            try await api.preparePrivateLocalSettings(id: id, change: change)
        }, { api, body in
            try await api.updatePrivateLocalSettings(id: id, body: body)
        })
        return result != nil
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
        video: ChatVideoAttachment? = nil,
        sessionID: String? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || video != nil,
              let sessionID = sessionID ?? selectedSessionID else { return false }
        let question = mode == .auto && sessionID == selectedSessionID ? chatInputRequest : nil
        if let question, selectedSession?.supportsChatInputReplies != true {
            guard images.isEmpty, video == nil else {
                errorMessage = "Update and reopen Cantrip on the Mac to attach files to this chat reply."
                return false
            }
            return await respondToInput(sessionID: sessionID, id: question.id,
                answer: .init(decision: "submit", text: trimmed), identity: usageIdentity, questionOnly: true)
        }
        if let video {
            guard await uploadVideo(video, text: trimmed, mode: mode, images: images, sessionID: sessionID) else { return false }
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareMessage(trimmed, mode: mode, sessionID: sessionID, images: images,
                                         videoID: video?.id.uuidString, inputRequestID: question?.id)
        }, { api, body in
            try await api.sendMessage(body, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
    }

    func cancelVideoUpload() { videoUploadTask?.cancel() }

    private func uploadVideo(_ video: ChatVideoAttachment, text: String, mode: CantripDeliveryMode,
                             images: [ChatImageAttachment], sessionID: String) async -> Bool {
        guard !isMutating, !isUploadingVideo else {
            errorMessage = "Wait for the current request to finish."
            return false
        }
        let generation = configurationGeneration
        videoUploadProgress = VideoUploadProgress(fraction: 0, isPreparing: false)
        let task = Task {
            _ = try await self.performHistoryRead {
                try await $0.prepareMessage(text, mode: mode, sessionID: sessionID, images: images, videoID: video.id.uuidString)
            }
            var offset = 0
            if let status = try await self.performHistoryRead({ try await $0.videoStatus(sessionID: sessionID, uploadID: video.id) }) {
                guard status.totalBytes == video.bytes, status.sha256 == video.sha256,
                      (0...video.bytes).contains(status.receivedBytes) else { throw CantripRemoteError.invalidResponse }
                offset = status.receivedBytes
            }
            while offset < video.bytes {
                try Task.checkCancellation()
                let start = offset
                let data = try await Task.detached(priority: .userInitiated) {
                    try VideoAttachmentProcessor.chunk(video, offset: start)
                }.value
                // Chunk PUTs verify repeated bytes, and preparation is idempotent.
                // Only these transfers may fail over/retry; the final prompt never does.
                let status = try await self.performHistoryRead {
                    try await $0.uploadVideoChunk(data, video: video, sessionID: sessionID, offset: start)
                }
                guard status.totalBytes == video.bytes, status.sha256 == video.sha256,
                      status.receivedBytes >= start + data.count, status.receivedBytes <= video.bytes else {
                    throw CantripRemoteError.invalidResponse
                }
                offset = status.receivedBytes
                self.videoUploadProgress = VideoUploadProgress(fraction: Double(offset) / Double(video.bytes), isPreparing: false)
            }
            self.videoUploadProgress = VideoUploadProgress(fraction: 1, isPreparing: true)
            try await self.performHistoryRead { try await $0.prepareVideo(sessionID: sessionID, uploadID: video.id) }
            try Task.checkCancellation()
            guard generation == self.configurationGeneration else { throw CancellationError() }
        }
        videoUploadTask = task
        defer { videoUploadTask = nil; videoUploadProgress = nil }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            return true
        } catch is CancellationError {
            errorMessage = "Video upload cancelled. No prompt was sent; your draft has been kept."
            return false
        } catch {
            errorMessage = "Video was not sent. \(error.localizedDescription) Retry to resume the upload."
            return false
        }
    }

    @discardableResult
    func stop(sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try stopping again."
            return false
        }
        stoppingSessionID = sessionID
        defer { stoppingSessionID = nil }
        return await sessionAction("cancel", sessionID: sessionID)
    }

    @discardableResult
    func removeQueuedPrompt(_ id: String, sessionID: String) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish, then try removing the message again."
            return false
        }
        guard let session = await mutate(prepare: { api in
            try await api.prepareQueueRemoval(sessionID: sessionID)
        }, { api, _ in
            try await api.deleteQueuedPrompt(id: id, sessionID: sessionID)
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
        guard let replacement = await mutate(sessionID: id, { api in
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
        guard let session = await mutate(prepare: { api in
            try await api.prepareTabUpdate(id: id, name: name, isLocked: isLocked)
        }, { api, body in
            try await api.updateTab(id: id, body: body)
        }) else { return false }
        if selectedSessionID == id {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        }
        return true
    }

    private func sessionAction(_ action: String, sessionID: String? = nil) async -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID else { return false }
        guard action != "new-conversation" || selectedSession?.isLocked != true else {
            errorMessage = ChatTabError.locked.localizedDescription
            return false
        }
        guard let session = await mutate(sessionID: sessionID, { api in
            try await api.action(action, sessionID: sessionID)
        }) else { return false }
        if selectedSessionID == sessionID {
            apply(session)
        } else if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = session
        }
        return true
    }

    @discardableResult
    func moveTab(_ id: String, relativeTo targetID: String, after: Bool) async -> Bool {
        guard !isMutating else {
            errorMessage = "Wait for the current request to finish before reordering tabs."
            return false
        }
        guard let source = sessions.firstIndex(where: { $0.id == id }),
              let target = sessions.firstIndex(where: { $0.id == targetID }) else {
            errorMessage = "A tab is no longer open. Refresh the tabs and try again."
            return false
        }
        guard id != targetID else { return true }
        let previousOrder = sessions
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        var preview = sessions
        let moved = preview.remove(at: source)
        preview.insert(moved, at: target - (source < target ? 1 : 0) + (after ? 1 : 0))
        sessions = preview
        guard let reordered = await mutate(prepare: { api in
            try await api.prepareTabMove(id: id, targetID: targetID, after: after)
        }, { api, body in
            try await api.moveTab(id: id, body: body)
        }) else {
            sessions = previousOrder
            return false
        }
        // A list response has no transcript. Keep the selected detail and draft mounted.
        sessions = reordered
        return true
    }

    @discardableResult
    func moveTab(_ id: String, offset: Int) async -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset), sessions.indices.contains(index + offset) else {
            errorMessage = "The tab cannot move farther in that direction. Refresh the tabs and try again."
            return false
        }
        return await moveTab(id, relativeTo: sessions[index + offset].id, after: offset > 0)
    }

    private func mutate<T>(
        sessionID: String? = nil,
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async -> T? {
        await mutate(prepare: { api in
            if let sessionID {
                _ = try await api.session(id: sessionID)
            } else {
                _ = try await api.sessions()
            }
        }, { api, _ in
            try await operation(api)
        })
    }

    private func mutate<Prepared, T>(
        prepare: @escaping (CantripRemoteAPI) async throws -> Prepared,
        _ operation: @escaping (CantripRemoteAPI, Prepared) async throws -> T
    ) async -> T? {
        guard !isMutating, !isUploadingVideo else {
            errorMessage = "Wait for the current request to finish."
            return nil
        }
        mutationRevision += 1
        isMutating = true
        defer { isMutating = false }
        do {
            guard let token else { throw CantripRemoteError.missingToken }
            let generation = configurationGeneration
            let result = try await requestGate.withLock {
                guard generation == self.configurationGeneration else { throw CancellationError() }
                self.updateRoutes()
                return try await self.router.performMutation(prepare: { transport in
                    try await prepare(CantripRemoteAPI(
                        transport: transport, token: token, urlSession: self.urlSession
                    ))
                }, operation: { transport, prepared in
                    try await operation(CantripRemoteAPI(
                        transport: transport, token: token, urlSession: self.urlSession
                    ), prepared)
                })
            }
            try Task.checkCancellation()
            guard generation == configurationGeneration else { throw CancellationError() }
            activeTransport = router.preferred
            markAuthenticatedSuccess()
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
        let selection = selectionRevision
        do {
            let generation = configurationGeneration
            let listed = try await performAuthenticated(allowFallback: true) { api in
                try await api.sessions()
            }
            guard generation == configurationGeneration else { throw CancellationError() }
            guard revision == mutationRevision else { return }
            sessions = listed
            errorMessage = nil
            let publicIDs = Set(listed.map(\.id))
            detailCache = detailCache.filter { publicIDs.contains($0.key) }
            cacheOrder.removeAll { !publicIDs.contains($0) }
            expandedHistory.formIntersection(publicIDs)
            automaticHistoryRemaining = automaticHistoryRemaining.filter { publicIDs.contains($0.key) }
            guard selection == selectionRevision else { return }
            let chosenID = requestedID.flatMap { id in
                listed.contains(where: { $0.id == id }) ? id : nil
            } ?? listed.first?.id
            selectedSessionID = chosenID
            if selectedSession?.id != chosenID {
                selectedSession = chosenID.flatMap { detailCache[$0] }
                transcriptRevision += 1
            }
            if let chosenID, selectingSessionID == chosenID {
                recoverTailscale()
                return
            }
            if let chosenID {
                let cachedRevision = selectedSession?.historyRevision
                let listedRevision = listed.first { $0.id == chosenID }?.historyRevision
                if let cachedRevision, cachedRevision == listedRevision {
                    detailError = nil
                } else {
                    let key = "\(generation):\(revision):\(selection):\(chosenID)"
                    if detailRefreshKey != key {
                        cancelDetailRefresh()
                        detailRefreshKey = key
                        let requestID = detailRefreshID
                        detailRefreshTask = Task { [weak self] in
                            guard let self else { return }
                            defer {
                                if self.detailRefreshID == requestID {
                                    self.detailRefreshTask = nil
                                    self.detailRefreshKey = nil
                                }
                            }
                            do {
                                let detail = try await self.performHistoryRead { api in
                                    try await api.sessionUpdate(id: chosenID, revision: cachedRevision)
                                }
                                guard !Task.isCancelled, generation == self.configurationGeneration,
                                      revision == self.mutationRevision, selection == self.selectionRevision,
                                      self.selectedSessionID == chosenID else { return }
                                if let detail { self.apply(detail) }
                                self.detailError = nil
                            } catch is CancellationError {
                                return
                            } catch {
                                guard self.detailRefreshID == requestID,
                                      generation == self.configurationGeneration,
                                      revision == self.mutationRevision, selection == self.selectionRevision,
                                      self.selectedSessionID == chosenID else { return }
                                self.detailError = "Could not update this conversation. \(error.localizedDescription)"
                                self.handleReadFailure(error, detailOnly: true)
                            }
                        }
                    }
                }
            } else {
                cancelDetailRefresh()
                detailError = nil
            }
            recoverTailscale()
        } catch is CancellationError {
            return
        } catch {
            guard revision == mutationRevision, selection == selectionRevision else { return }
            errorMessage = error.localizedDescription
            handleReadFailure(error, detailOnly: false)
        }
    }

    private func cancelDetailRefresh() {
        detailRefreshTask?.cancel()
        detailRefreshTask = nil
        detailRefreshKey = nil
        detailRefreshID = UUID()
    }

    private func performAuthenticated<T>(
        allowFallback: Bool,
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
            let api = CantripRemoteAPI(transport: transport, token: token, urlSession: self.urlSession)
            return try await operation(api)
        }
    }

    private func updateRoutes() {
        router.available = (baseURL.map { [.remote($0)] } ?? [])
            + (tailscaleOnly ? [] : lanEndpoints.map(CantripTransport.lan))
    }

    private func recoverTailscale() {
        guard appIsActive, let token, !tailscaleOnly else { return }
        router.recoverTailscale { [urlSession] transport in
            _ = try await CantripRemoteAPI(
                transport: transport, token: token, urlSession: urlSession
            ).sessions()
        }
    }

    private func apply(_ incoming: CantripRemoteSession, mergeHistory: Bool = true) {
        var session = incoming
        if detailCache[session.id]?.historyStartID != session.historyStartID {
            expandedHistory.remove(session.id)
            automaticHistoryRemaining.removeValue(forKey: session.id)
        }
        if mergeHistory, let previous = detailCache[session.id],
           let start = session.historyStartID, start == previous.historyStartID,
           let first = session.transcript.first?.id,
           let overlap = previous.transcript.firstIndex(where: { $0.id == first }) {
            session.messages = Array(previous.transcript.prefix(overlap)) + session.transcript
            session.hasOlderMessages = previous.hasOlderMessages
        }
        if !expandedHistory.contains(session.id), session.supportsPagedHistory == true {
            let bounded = Self.historySuffix(session.transcript, groups: CantripHistoryWindow.recentExchanges)
            if bounded.count < session.transcript.count {
                session.messages = bounded
                session.hasOlderMessages = true
            }
        }
        if !expandedHistory.contains(session.id), session.supportsPagedHistory == true,
           session.transcript.count > 120, !session.transcript.contains(where: { $0.role == "user" }) {
            session.messages = Array(session.transcript.suffix(120))
            session.hasOlderMessages = true
        }
        if !expandedHistory.contains(session.id) {
            let pastGroups = max(0, session.transcript.filter { $0.role == "user" }.count - 1)
            automaticHistoryRemaining[session.id] = min(
                automaticHistoryRemaining[session.id] ?? Self.automaticHistoryLimit,
                max(0, Self.automaticHistoryLimit - pastGroups)
            )
        }
        detailCache[session.id] = session
        cacheOrder.removeAll { $0 == session.id }
        cacheOrder.append(session.id)
        while cacheOrder.count > 5 {
            let removed = cacheOrder.removeFirst()
            detailCache.removeValue(forKey: removed)
            expandedHistory.remove(removed)
            automaticHistoryRemaining.removeValue(forKey: removed)
        }
        if selectedSession != session {
            selectedSession = session
            transcriptRevision += 1
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
    }

    private static func historySuffix(_ messages: [CantripRemoteMessage], groups: Int) -> [CantripRemoteMessage] {
        guard groups > 0 else { return [] }
        let prompts = messages.indices.filter { messages[$0].role == "user" }
        guard prompts.count > groups else { return messages }
        return Array(messages[prompts[prompts.count - groups]...])
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
                    try await Task.sleep(for: self.pollDelay)
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
            guard let self, self.token == token else { return }
            self.updateLANEndpoints(endpoints)
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
        cancelDetailRefresh()
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
        refreshCompletionNotificationRegistration()
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

    private func resetHistory() {
        cancelDetailRefresh()
        detailCache.removeAll()
        cacheOrder.removeAll()
        expandedHistory.removeAll()
        automaticHistoryRemaining.removeAll()
        detailError = nil
        selectionRevision += 1
        selectingSessionID = nil
        historyPrependAnchor = nil
    }

    private func handleReadFailure(_ error: Error, detailOnly: Bool) {
        if case CantripRemoteError.authentication = error {
            markDisconnected()
        } else if !detailOnly, CantripRemoteError.isRouteFailure(error) {
            connectionState = .reconnecting
        }
    }

    private func shouldDisconnect(for error: Error) -> Bool {
        if CantripRemoteError.isRouteFailure(error) { return true }
        switch error {
        case is CancellationError:
            return false
        case CantripRemoteError.http:
            return false
        case CantripRemoteError.imagesUnsupported, CantripRemoteError.videosUnsupported, CantripRemoteError.queueRemovalUnsupported,
             CantripRemoteError.autoDeliveryUnsupported, CantripRemoteError.tabMetadataUnsupported,
             CantripRemoteError.tabReorderingUnsupported,
             is ImageAttachmentError, is VideoAttachmentError:
            return false
        default:
            return true
        }
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL? {
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
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
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
    @State private var showCantripMaintenance = false
    @State private var draft = ""
    @State private var deliveryMode: CantripDeliveryMode = .auto
    @State private var renamingSession: CantripRemoteSession?
    @State private var showTabs = false
    @State private var chatAvailableHeight: CGFloat = 600
    @FocusState private var composerFocused: Bool

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
            .modifier(ChatNavigationActions(
                showsHorizontalBar: true,
                leading: {
                    ChatTabsButton(isEnabled: model.isConfigured && !model.isMutating) {
                        showTabs = true
                    }
                }, refresh: {}, settings: {
                    ChatSettingsButton { showSettings = true }
                }, trailing: {
                    Menu {
                        CantripMacMenuActions(remote: model, showingMaintenance: $showCantripMaintenance) {
                            composerFocused = false
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        ChatMenuIcon()
                    }
                    .accessibilityLabel("Remote menu")
                }
            ))
            .sheet(isPresented: $showSettings) {
                CantripRemoteSettingsSheet(model: model)
            }
            .sheet(item: $renamingSession) { session in
                CantripTabRenameSheet(model: model, session: session)
            }
            .sheet(item: $model.modelSettingsSession) { session in
                CantripSessionSettingsView(model: model, session: session, identity: model.usageIdentity)
            }
            .sheet(item: $model.inputRequestsSession) { session in
                CantripInputRequestsView(model: model, session: session)
            }
            .sheet(isPresented: $model.showingMacAccess) {
                NavigationStack { CantripMacAccessView(remote: model) }
            }
            .sheet(isPresented: $showCantripMaintenance) {
                CantripMaintenanceSheet(remote: model)
            }
        }
        .cantripTabDrawer(
            isPresented: $showTabs,
            isEnabled: model.isConfigured && (!model.isMutating || model.isReorderingTabs)
        ) {
            CantripSessionDrawer(
                model: model,
                onDismiss: { showTabs = false },
                onSelect: { id in Task { await model.selectSession(id) } },
                onCreate: { Task { await model.createSession() } },
                onRename: { renamingSession = $0 },
                onClose: { id in Task { await model.closeSession(id) } }
            )
        }
        .onChange(of: showTabs) { _, showing in
            if showing { composerFocused = false }
        }
        .modifier(ChatDisplayObserver())
    }

    private var remoteContent: some View {
        VStack(spacing: 0) {
            connectionBanner
            CantripDetailNotice(model: model)
                .padding(.horizontal)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            chatAvailableHeight = $0
        }
    }

    private var connectionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(model.connectionLabel)
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
            .accessibilityLabel(model.connectionLabel)

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
        CantripSessionBar(
            sessions: model.sessions,
            selectedSessionID: model.selectedSessionID,
            deliveryMode: $deliveryMode,
            isMutating: model.isMutating
        ) {
            showTabs = true
        } actions: {
            if let session = model.selectedSession {
                sessionActions(session)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sessionActions(_ session: CantripRemoteSession) -> some View {
        CantripTabActions(model: model, session: session,
            onRename: { renamingSession = session },
            onClose: { Task { await model.closeSession(session.id) } })
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
            if let status = model.selectedSession?.deliveryStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ChatComposer {
                EmptyView()
            } message: {
                TextField(CantripInputComposer.placeholder(for: model.chatInputRequest, mode: deliveryMode),
                          text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.isMutating || !composerAcceptsText)
                    .submitLabel(.send)
                    .onSubmit { submit() }
            } trailing: {
                CantripStopButton(
                    session: model.selectedSession,
                    isConnected: model.isConnected,
                    isMutating: model.isMutating,
                    isStopping: model.stoppingSessionID != nil
                        && model.stoppingSessionID == model.selectedSessionID,
                    iconOnly: true
                ) { id in
                    Task { await model.stop(sessionID: id) }
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(
                    model.isMutating
                        || !composerAcceptsText
                        || model.selectedSessionID == nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel(deliveryMode == .auto && model.chatInputRequest != nil ? "Send reply" : "Send prompt")
            } accessory: {
                CantripInputComposer(
                    model: model, deliveryMode: deliveryMode,
                    maxHeight: min(320, max(72, chatAvailableHeight * 0.45))
                )
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var composerAcceptsText: Bool {
        CantripInputComposer.acceptsText(for: model.chatInputRequest, mode: deliveryMode)
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, composerAcceptsText, !model.isMutating else { return }
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
                CantripHistoryControls(model: model)
                ForEach(model.selectedSession?.transcript ?? []) { message in
                    CantripRemoteMessageBubble(
                        message: message, model: model, sessionID: model.selectedSession?.id ?? ""
                    )
                        .id(message.id)
                    if message.isPreview == true {
                        CantripMessageDetailsButton(model: model, message: message,
                                                    sessionID: model.selectedSession?.id ?? "")
                    }
                }
                CantripInputTranscript(model: model)
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
        .onUpwardHistoryScroll {
            Task { await model.loadOlderMessages(automatically: true) }
        }
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
            guard followsBottom, !model.isLoadingHistory else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onScrollGeometryChange(for: HistoryScrollGeometry.self) { geometry in
            HistoryScrollGeometry(geometry, prependRevision: model.historyPrependRevision)
        } action: { previous, current in
            guard previous.prependRevision != current.prependRevision,
                  model.historyPrependAnchor != nil else { return }
            followsBottom = false
            scrollPosition.scrollTo(y: max(0, previous.offset + current.height - previous.height))
        }
    }
}

struct CantripHistoryControls: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedSession?.hasOlderMessages == true {
                if model.canAutomaticallyLoadHistory {
                    HStack {
                        if model.isLoadingHistory { ProgressView() }
                        Text(model.isLoadingHistory ? "Loading older messages..." : "Scroll up for older messages")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAction(named: Text("Load older messages")) {
                        Task { await model.loadOlderMessages(automatically: true) }
                    }
                } else {
                    Button {
                        Task { await model.loadOlderMessages() }
                    } label: {
                        HStack {
                            if model.isLoadingHistory { ProgressView() }
                            Text(model.isLoadingHistory ? "Loading older messages..." : "Load more messages")
                        }
                    }
                    .disabled(model.isLoadingHistory || model.isMutating)
                    .accessibilityIdentifier("cantrip.loadOlderMessages")
                }
            }
        }
    }
}

struct CantripDetailNotice: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        if let error = model.detailError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("Retry conversation") { Task { await model.refreshNow() } }
                    .font(.caption)
                    .disabled(model.isRefreshing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CantripMessageDetailsButton: View {
    @ObservedObject var model: CantripRemoteModel
    let message: CantripRemoteMessage
    let sessionID: String
    @State private var presented = false

    var body: some View {
        Button("Load full message and details") { presented = true }
            .font(.caption)
            .sheet(isPresented: $presented) {
                CantripMessageDetails(model: model, sessionID: sessionID, messageID: message.id)
            }
            .onChange(of: model.usageIdentity) { _, _ in presented = false }
    }
}

private struct CantripMessageDetails: View {
    @ObservedObject var model: CantripRemoteModel
    let sessionID: String
    let messageID: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: CantripRemoteMessage?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if let message {
                    CantripRemoteMessageBubble(message: message, model: model, sessionID: sessionID)
                        .padding()
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error)
                        Button("Retry") { attempt += 1 }
                    }.padding()
                } else {
                    ProgressView("Loading full message...").padding()
                }
            }
            .navigationTitle("Message details")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: attempt) {
                error = nil
                do {
                    message = try await model.fullMessage(sessionID: sessionID, messageID: messageID)
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct CantripRemoteMessageBubble: View {
    let message: CantripRemoteMessage
    @ObservedObject var model: CantripRemoteModel
    let sessionID: String

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
                if !message.presentedText.isEmpty {
                    if message.role == "user" {
                        PromptTextView(text: message.presentedText)
                    } else if message.isLocalPrivate == true {
                        Text(verbatim: message.presentedText)
                    } else {
                        ChatAssistantText(
                            text: message.presentedText,
                            images: (message.images ?? []).map { $0.inSession(sessionID) }, remote: model
                        )
                    }
                }
                ChatImageGallery(
                    images: (message.images ?? []).filter { !ChatMessageImage.validPreviewID($0.id) }
                        .map { $0.inSession(sessionID) }, remote: model
                )
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
                    if activity.input != nil || activity.output != nil {
                        DisclosureGroup("Tool details") {
                            if let input = activity.input { PromptTextView(text: input) }
                            if let output = activity.output { PromptTextView(text: output) }
                        }
                        .font(.caption)
                    }
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
            CantripRemoteSettingsSection(model: model)
        }
    }
}

struct CantripRemoteSettingsSection: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        ServerSettingsSections(
            servers: model.servers,
            canChangeSelection: !model.isMutating,
            add: { try model.addServer($0) },
            select: { try await model.selectServer($0) },
            remove: model.removeServer
        )
        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CantripRemoteSettingsSheet: View {
    @ObservedObject var model: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CantripRemoteSettingsSection(model: model)
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
