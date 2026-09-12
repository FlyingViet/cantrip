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
    var historyRevision: String? = nil
    var historyStartID: String? = nil
    var hasOlderMessages: Bool? = nil

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
    case autoDeliveryUnsupported
    case queueRemovalUnsupported
    case tabMetadataUnsupported
    case tabReorderingUnsupported
    case githubBuildsUnsupported
    case copilotUsageUnsupported

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
        case .copilotUsageUnsupported:
            return "Update and reopen Cantrip on your Mac to view Copilot account usage."
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
        timeout = method == "GET" ? (CantripRemoteAPI.isHistoryRead(method: method, path: path) ? 20 : 2)
            : (payload.count > 256 * 1024 ? 60 : 12)
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

    static func isHistoryRead(method: String, path: String) -> Bool {
        let parts = (URLComponents(string: path)?.path ?? "").split(separator: "/")
        return method == "GET" && parts.starts(with: ["api", "v1", "sessions"])
            && (parts.count == 4 || (parts.count == 6 && parts[4] == "messages"))
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

    func githubBuilds() async throws -> CantripBuildSnapshot {
        do {
            return try await request(path: "/api/v1/github/builds")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.githubBuildsUnsupported
        }
    }

    func copilotUsage() async throws -> CopilotUsageSnapshot {
        do {
            return try await request(path: "/api/v1/copilot/usage")
        } catch CantripRemoteError.http(404, _) {
            throw CantripRemoteError.copilotUsageUnsupported
        }
    }

    func imageData(sessionID: String, imageID: String, thumbnail: Bool) async throws -> Data {
        guard UUID(uuidString: sessionID) != nil, ChatMessageImage.validRemoteID(imageID) else {
            throw CantripRemoteError.invalidResponse
        }
        struct ImageResponse: Decodable { let data: Data }
        let response: ImageResponse = try await request(
            path: "/api/v1/sessions/\(sessionID)/attachments/\(imageID)"
                + (thumbnail ? "/thumbnail" : "")
        )
        guard !response.data.isEmpty,
              response.data.count <= ImageAttachmentProcessor.maximumImageBytes else {
            throw ImageAttachmentError.invalidImage
        }
        return response.data
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

    func sessionUpdate(id: String, revision: String?) async throws -> CantripRemoteSession? {
        var path = "/api/v1/sessions/\(id)"
        if let revision {
            var components = URLComponents()
            components.path = path
            components.queryItems = [URLQueryItem(name: "revision", value: revision)]
            guard let target = components.string else { throw CantripRemoteError.invalidResponse }
            path = target
        }
        let response: CantripSessionUpdate = try await request(path: path)
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
        images: [ChatImageAttachment]
    ) async throws -> Data {
        guard images.count <= ImageAttachmentProcessor.maximumCount else {
            throw ImageAttachmentError.tooMany
        }
        // Confirm reachability and capabilities on the route that will receive the write.
        let host = try await session(id: sessionID)
        guard images.isEmpty || host.supportsImageAttachments == true else {
            throw CantripRemoteError.imagesUnsupported
        }
        guard mode != .auto || host.supportsAutoDelivery == true else {
            throw CantripRemoteError.autoDeliveryUnsupported
        }
        return try JSONEncoder().encode(CantripMessageBody(text: text, mode: mode, images: images))
    }

    fileprivate func sendMessage(_ body: Data, sessionID: String) async throws -> CantripRemoteSession {
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
            body: body
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
        guard var target = URLComponents(string: path), target.host == nil else {
            throw CantripRemoteError.invalidResponse
        }
        target.queryItems = (target.queryItems ?? []) + [URLQueryItem(name: "history", value: "recent")]
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
        let isImageUpload = (body?.count ?? 0) > 256 * 1024
        let isHistoryRead = Self.isHistoryRead(method: method, path: path)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: method == "GET" ? (isHistoryRead ? 20 : 3) : (isImageUpload ? 60 : 12)
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
            let session = urlSession ?? (method == "GET" && !isHistoryRead
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
    @Published private(set) var connectionState: CantripRemoteConnectionState = .disconnected
    @Published private(set) var configuredURL: String
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var sessions: [CantripRemoteSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedSession: CantripRemoteSession?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var isReorderingTabs = false
    @Published private(set) var stoppingSessionID: String?
    @Published private(set) var detailError: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var historyPrependRevision = 0
    private(set) var historyPrependAnchor: String?
    private var detailCache: [String: CantripRemoteSession] = [:]
    private var cacheOrder: [String] = []
    private var expandedHistory: Set<String> = []
    private var selectionRevision = 0
    private var selectingSessionID: String?
    private var mutationRevision = 0
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var isLocalNetworkAvailable = false
    @Published private(set) var tailscaleOnly: Bool
    @Published private(set) var usageIdentity = UUID()
    let servers: ServerProfiles
    @Published private(set) var selectedServerID: UUID?

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

    init(urlSession: URLSession? = nil, servers: ServerProfiles? = nil) {
        self.urlSession = urlSession
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
    }

    func removeServer(_ server: SavedServer) throws {
        guard !isMutating else {
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
        guard !isMutating else {
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
        guard !isMutating else {
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
        let image = try await Task.detached(priority: .userInitiated) {
            try ChatImageDecoder.decode(
                data, maximumDimension: thumbnail ? 320 : ImageAttachmentProcessor.maximumDimension
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

    func loadOlderMessages() async {
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
            latest.messages = page.transcript.filter { !existing.contains($0.id) } + latest.transcript
            latest.hasOlderMessages = page.hasOlderMessages
            expandedHistory.insert(current.id)
            historyPrependAnchor = before
            apply(latest, mergeHistory: false)
            historyPrependRevision += 1
            detailError = nil
        } catch is CancellationError {
            return
        } catch {
            guard selection == selectionRevision else { return }
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
        guard let session = await mutate(prepare: { api in
            try await api.prepareMessage(trimmed, mode: mode, sessionID: sessionID, images: images)
        }, { api, body in
            try await api.sendMessage(body, sessionID: sessionID)
        }) else { return false }
        guard selectedSessionID == sessionID else { return true }
        apply(session)
        return true
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
        guard !isMutating else { return nil }
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
        }
        if mergeHistory, let previous = detailCache[session.id],
           let start = session.historyStartID, start == previous.historyStartID,
           let first = session.transcript.first?.id,
           let overlap = previous.transcript.firstIndex(where: { $0.id == first }) {
            session.messages = Array(previous.transcript.prefix(overlap)) + session.transcript
            session.hasOlderMessages = previous.hasOlderMessages
        }
        if !expandedHistory.contains(session.id), session.supportsPagedHistory == true,
           session.transcript.count > 120 {
            session.messages = Array(session.transcript.suffix(120))
            session.hasOlderMessages = true
        }
        detailCache[session.id] = session
        cacheOrder.removeAll { $0 == session.id }
        cacheOrder.append(session.id)
        while cacheOrder.count > 5 {
            let removed = cacheOrder.removeFirst()
            detailCache.removeValue(forKey: removed)
            expandedHistory.remove(removed)
        }
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
        case CantripRemoteError.imagesUnsupported, CantripRemoteError.queueRemovalUnsupported,
             CantripRemoteError.autoDeliveryUnsupported, CantripRemoteError.tabMetadataUnsupported,
             CantripRemoteError.tabReorderingUnsupported,
             is ImageAttachmentError:
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
    @State private var draft = ""
    @State private var deliveryMode: CantripDeliveryMode = .auto
    @State private var renamingSession: CantripRemoteSession?
    @State private var showTabs = false
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
            .toolbar {
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Cantrip", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { submit() }
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
            guard followsBottom, !model.isLoadingHistory else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: model.historyPrependRevision) { _, _ in
            guard let anchor = model.historyPrependAnchor else { return }
            followsBottom = false
            scrollPosition.scrollTo(id: anchor, anchor: .top)
        }
    }
}

struct CantripHistoryControls: View {
    @ObservedObject var model: CantripRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedSession?.hasOlderMessages == true {
                Button {
                    Task { await model.loadOlderMessages() }
                } label: {
                    HStack {
                        if model.isLoadingHistory { ProgressView() }
                        Text(model.isLoadingHistory ? "Loading older messages..." : "Load older messages")
                    }
                }
                .disabled(model.isLoadingHistory || model.isMutating)
                .accessibilityIdentifier("cantrip.loadOlderMessages")
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
                    } else {
                        Markdown(message.text)
                    }
                }
                ChatImageGallery(
                    images: (message.images ?? []).map { $0.inSession(sessionID) }, remote: model
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
