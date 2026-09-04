import Foundation
import MarkdownUI
import Security
import SwiftUI
import UIKit

enum CantripRemoteConnectionState: Equatable {
    case disconnected
    case connected
}

enum CantripDeliveryMode: String, CaseIterable, Identifiable {
    case queue
    case interrupt
    case inject

    var id: String { rawValue }

    var title: String {
        switch self {
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

private enum CantripRemoteError: LocalizedError {
    case invalidURL(String)
    case missingToken
    case keychain(String)
    case authentication
    case transport(String)
    case http(Int, String)
    case decoding
    case invalidResponse

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

private struct CantripRemoteAPI {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
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

    func send(_ text: String, mode: CantripDeliveryMode, sessionID: String) async throws
        -> CantripRemoteSession {
        let body = try JSONEncoder().encode(MessageBody(text: text, mode: mode.rawValue))
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

    private struct MessageBody: Encodable {
        let text: String
        let mode: String
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        let url = try endpoint(path: path)
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
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
            (data, response) = try await Self.session.data(for: request)
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

    private func endpoint(path: String) throws -> URL {
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
    @Published private(set) var transcriptRevision = 0

    var isConnected: Bool { connectionState == .connected }
    var isConfigured: Bool { baseURL != nil && token != nil }

    var endpointHost: String {
        guard let baseURL else { return "Not configured" }
        if let port = baseURL.port {
            return "\(baseURL.host ?? baseURL.absoluteString):\(port)"
        }
        return baseURL.host ?? baseURL.absoluteString
    }

    private static let endpointKey = "cantrip.remote.base-url"
    private static let staleInterval: Duration = .seconds(5)
    private static let pollInterval: Duration = .milliseconds(1500)

    private var baseURL: URL?
    private var token: String?
    private var appIsActive = false
    private var pollingTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var lastAuthenticatedAt: Date?
    private var configurationGeneration = 0
    private let requestGate = CantripRequestGate()

    init() {
        let storedURL = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        configuredURL = storedURL
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
            startPolling()
        } else {
            stopPolling()
        }
    }

    func configure(url rawURL: String, pairingToken rawToken: String) async -> Bool {
        do {
            guard let normalized = try Self.normalizedBaseURL(rawURL) else {
                throw CantripRemoteError.invalidURL("Enter the Tailscale Serve HTTPS URL.")
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
            baseURL = normalized
            token = effectiveToken
            configuredURL = normalized.absoluteString
            hasStoredToken = true
            UserDefaults.standard.set(configuredURL, forKey: Self.endpointKey)
            errorMessage = nil
            if appIsActive { startPolling() }
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
            configurationGeneration += 1
            UserDefaults.standard.removeObject(forKey: Self.endpointKey)
            baseURL = nil
            token = nil
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
        do {
            let detail = try await performAuthenticated { api in
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
    func send(_ text: String, mode: CantripDeliveryMode) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID = selectedSessionID else { return false }
        guard let session = await mutate({ api in
            try await api.send(trimmed, mode: mode, sessionID: sessionID)
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
    func resume() async -> Bool {
        await sessionAction("resume")
    }

    @discardableResult
    func newConversation() async -> Bool {
        await sessionAction("new-conversation")
    }

    private func sessionAction(_ action: String) async -> Bool {
        guard let sessionID = selectedSessionID else { return false }
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
            return nil
        }
    }

    private func refresh() async {
        guard appIsActive, isConfigured, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedID = selectedSessionID
        do {
            let result = try await performAuthenticated { api in
                let listed = try await api.sessions()
                let chosenID = requestedID.flatMap { id in
                    listed.contains(where: { $0.id == id }) ? id : nil
                } ?? listed.first?.id
                let detail: CantripRemoteSession?
                if let chosenID {
                    detail = try await api.session(id: chosenID)
                } else {
                    detail = nil
                }
                return (listed, chosenID, detail)
            }

            sessions = result.0
            if selectedSessionID == requestedID || selectedSessionID == nil {
                selectedSessionID = result.1
                if let detail = result.2 {
                    apply(detail)
                } else if result.1 == nil {
                    selectedSession = nil
                    transcriptRevision += 1
                }
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            markDisconnected()
            errorMessage = error.localizedDescription
        }
    }

    private func performAuthenticated<T>(
        _ operation: @escaping (CantripRemoteAPI) async throws -> T
    ) async throws -> T {
        guard let baseURL, let token else {
            throw CantripRemoteError.missingToken
        }
        let generation = configurationGeneration
        let api = CantripRemoteAPI(baseURL: baseURL, token: token)
        let result = try await requestGate.withLock {
            try await operation(api)
        }
        try Task.checkCancellation()
        guard generation == configurationGeneration else {
            throw CancellationError()
        }
        markAuthenticatedSuccess()
        return result
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

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        staleTask?.cancel()
        staleTask = nil
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
    @State private var deliveryMode: CantripDeliveryMode = .queue

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
                .disabled(session.isStreaming || model.isMutating)
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
                .pickerStyle(.segmented)
                .accessibilityLabel("Prompt delivery mode")
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
                    Markdown(message.text)
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
                Text("Use the HTTPS address from Tailscale Serve and the pairing token from Cantrip's Remote control daemon settings.")
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

    var body: some View {
        Section {
            TextField("https://mac-mini.your-tailnet.ts.net", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField(model.hasStoredToken ? "Stored token (leave blank to keep)" : "Pairing token",
                        text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(saved ? "Saved" : "Save and Connect") {
                saving = true
                saved = false
                Task {
                    saved = await model.configure(url: url, pairingToken: token)
                    if saved {
                        url = model.configuredURL
                        token = ""
                    }
                    saving = false
                }
            }
            .disabled(
                saving
                    || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            if allowsClearing, model.isConfigured {
                Button("Clear Remote Connection", role: .destructive) {
                    model.clearConfiguration()
                    url = ""
                    token = ""
                    saved = false
                }
            }
        } header: {
            Text("Cantrip Remote")
        } footer: {
            Text("The URL is stored in app preferences. The pairing token is stored only in Keychain. HTTPS is required except for local development on a loopback address.")
        }
        .onAppear {
            url = model.configuredURL
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
