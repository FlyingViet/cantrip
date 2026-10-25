import Foundation
import Network
import CryptoKit
import Combine

/// Authenticated HTTP control plane for the live sessions owned by the app.
/// Loopback HTTP remains available for Tailscale Serve. A separate Bonjour
/// listener uses forward-secret TLS with the pairing token as a PSK for LAN use.
final class RemoteControlServer {
    var onError: ((String?) -> Void)?
    /// The encrypted LAN listener's actual port, and whether a pinned port had to fall back.
    var onLANStatus: ((RemoteLANStatus?) -> Void)?
    /// Bonjour advertisement of the encrypted LAN listener. Tests turn it off to prove that
    /// clients reach it through a direct host:port.
    var advertisesLANService = true

    private weak var manager: SessionManager?
    private let queue = DispatchQueue(label: "com.brian.cantrip.remote-control")
    private let encodingQueue: DispatchQueue
    private let detailEncodingQueue = DispatchQueue(label: "cantrip.remote-details", qos: .utility)
    private let memoryQueue = DispatchQueue(label: "cantrip.remote-memory", qos: .utility)
    /// Serial, so a request that arrives while the vocabulary is being gathered reuses its result.
    private let vocabularyQueue = DispatchQueue(label: "cantrip.remote-voice-vocabulary", qos: .utility)
    private let voiceVocabulary: VoiceVocabularyService
    private let requestLog: (String) -> Void
    private let sendTimeout: TimeInterval
    private static let healthBody = Data(#"{"status":"ok"}"#.utf8)
    private var listener: NWListener?
    private var lanListener: NWListener?
    private var activePort: Int?
    private var activeLANPort: Int?
    /// Bumped whenever the LAN listener is replaced on purpose, cancelling scheduled retries.
    private var lanGeneration = 0
    /// A busy pinned port is retried this often before falling back (an old listener, or the
    /// previous Cantrip process after an update, may still be releasing it)...
    var lanPinnedRetries = 12
    var lanPinnedRetryDelay: TimeInterval = 0.25
    /// ...and after a fallback, the pinned port is reclaimed once it is free again.
    var lanReclaimInterval: TimeInterval = 30
    private var token = ""
    private let buildMonitor: GitHubBuildMonitor
    private let usage: UsageTracker
    private let notifications: RemoteNotifications
    private let liveStatus: RemoteLiveStatus
    private let generatedImages = RemoteGeneratedImages.Store()
    private var maintenance: RemoteMaintenance?
    /// Single-use MCP App view addresses (main actor), valid for a minute.
    private var mcpAppViewTokens: [String: (sessionID: UUID, appID: String, expires: Date)] = [:]
    private let desktopOverride: RemoteDesktop?
    private let notificationLifecycleLock = NSLock()
    private var notificationLifecycleTask: Task<Void, Never>?
    private let liveStatusLifecycleLock = NSLock()
    private var liveStatusLifecycleTask: Task<Void, Never>?
    private var liveStatusObservation: AnyCancellable?
    private let maximumRequestBytes = RemoteImageAttachments.maximumRequestBytes

    init(manager: SessionManager, buildMonitor: GitHubBuildMonitor = GitHubBuildMonitor(),
         usage: UsageTracker = .shared,
         notifications: RemoteNotifications = RemoteNotifications(),
         liveStatus: RemoteLiveStatus = RemoteLiveStatus(),
         maintenance: RemoteMaintenance? = nil,
         desktop: RemoteDesktop? = nil,
         voiceVocabulary: VoiceVocabularyService? = nil,
         encodingQueue: DispatchQueue = DispatchQueue(label: "cantrip.remote-encoding", qos: .userInitiated),
         sendTimeout: TimeInterval = 15,
         requestLog: @escaping (String) -> Void = Log.write) {
        self.manager = manager
        self.buildMonitor = buildMonitor
        self.usage = usage
        self.notifications = notifications
        self.liveStatus = liveStatus
        self.maintenance = maintenance
        desktopOverride = desktop
        self.voiceVocabulary = voiceVocabulary ?? VoiceVocabularyService(log: requestLog)
        self.encodingQueue = encodingQueue
        self.sendTimeout = sendTimeout
        self.requestLog = requestLog
    }

    /// `lanPort` pins the encrypted LAN listener (for direct addresses such as a Tailscale
    /// subnet route to this Mac); nil, or a port that is busy, uses a dynamic port.
    func start(port: Int, token: String, lanPort: Int? = nil) {
        let lanPort = lanPort.flatMap { (1...65535).contains($0) && $0 != port ? $0 : nil }
        guard (1...65535).contains(port) else {
            onError?("Remote control port must be between 1 and 65535.")
            stop()
            return
        }
        guard !token.isEmpty else {
            onError?("Remote control pairing token is unavailable.")
            stop()
            return
        }
        if listener != nil, lanListener != nil, activePort == port, self.token == token,
           activeLANPort == lanPort {
            return
        }
        // Only the LAN port changed: keep the loopback listener, whose port can't be rebound
        // until the old socket finishes closing on the listener queue.
        if listener != nil, activePort == port, self.token == token {
            cancelLANListener()
            activeLANPort = lanPort
            onLANStatus?(nil)
            startLANListener(token: token, pinnedPort: lanPort)
            return
        }
        stop()

        do {
            try startHTTPListener(port: port)
            activePort = port
            activeLANPort = lanPort
            self.token = token
            updateNotificationActivation(fingerprint: RemoteLANProtocol.tokenFingerprint(token))
            updateLiveStatusActivation(fingerprint: RemoteLANProtocol.tokenFingerprint(token))
            startLANListener(token: token, pinnedPort: lanPort)
        } catch {
            onError?("Remote control daemon failed: \(error.localizedDescription)")
            Log.write("remote-control: listener failed: \(error.localizedDescription)")
        }
    }

    /// The loopback HTTP listener. Restarting on the same port (e.g. a new pairing token) can find
    /// the old socket still closing, so a port conflict is retried briefly before giving up.
    private func startHTTPListener(port: Int, attempt: Int = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.onError?(nil)
                Log.write("remote-control: listening at http://127.0.0.1:\(port)")
            case .failed(let error) where Self.isPortConflict(error) && attempt + 1 < self.lanPinnedRetries:
                listener.stateUpdateHandler = nil
                listener.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + self.lanPinnedRetryDelay) { [weak self] in
                    guard let self, self.listener === listener, self.activePort == port else { return }
                    do {
                        try self.startHTTPListener(port: port, attempt: attempt + 1)
                    } catch {
                        self.onError?("Remote control daemon failed: \(error.localizedDescription)")
                        self.stop()
                    }
                }
            case .failed(let error):
                self.onError?("Remote control daemon failed: \(error.localizedDescription)")
                Log.write("remote-control: listener failed: \(error.localizedDescription)")
                self.stop()
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        let desktop = desktopOverride
        Task { @MainActor in (desktop ?? RemoteDesktop.shared).stop() }
        updateNotificationActivation(fingerprint: nil)
        updateLiveStatusActivation(fingerprint: nil)
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        cancelLANListener()
        activePort = nil
        activeLANPort = nil
        token = ""
        onLANStatus?(nil)
    }

    @MainActor
    func notifyCompletion(for session: ChatSession) {
        guard !token.isEmpty, !session.isPrivate, !session.isStreaming, session.queued.isEmpty,
              let completion = session.remoteCompletion else { return }
        notificationLifecycleLock.lock()
        let activation = notificationLifecycleTask
        notificationLifecycleLock.unlock()
        Task {
            await activation?.value
            await notifications.enqueue(completion)
        }
    }

    /// Pushes a notice that isn't a session's own completion, such as a Home handoff.
    @MainActor
    func notify(_ completion: RemoteCompletion) {
        guard !token.isEmpty else { return }
        notificationLifecycleLock.lock()
        let activation = notificationLifecycleTask
        notificationLifecycleLock.unlock()
        Task {
            await activation?.value
            await notifications.enqueue(completion)
        }
    }

    @MainActor
    func notifyInput(for session: ChatSession, request: InputRequestSnapshot) {
        guard !token.isEmpty, !session.isPrivate, !session.isLocalPrivate else { return }
        notificationLifecycleLock.lock()
        let activation = notificationLifecycleTask
        notificationLifecycleLock.unlock()
        Task {
            await activation?.value
            guard session.pendingInputs.contains(where: { $0.id == request.id }) else { return }
            await notifications.enqueueInput(id: request.id, sessionID: session.id,
                                            expiresAt: Date(timeIntervalSince1970: request.expiresAt),
                                            homeRun: session.isCantripHomeRun)
            if !session.pendingInputs.contains(where: { $0.id == request.id }) {
                await notifications.resolveInput(request.id)
            }
        }
    }

    func resolveInputNotification(_ id: UUID) {
        Task { await notifications.resolveInput(id) }
    }

    @MainActor
    func notifyMacAttention(sessionID: UUID, issueID: UUID) {
        guard !token.isEmpty else { return }
        notificationLifecycleLock.lock()
        let activation = notificationLifecycleTask
        notificationLifecycleLock.unlock()
        Task {
            await activation?.value
            guard MacAttention.shared.issues.contains(where: { $0.id == issueID }),
                  manager?.sessions.contains(where: { $0.id == sessionID && !$0.isPrivate && !$0.isLocalPrivate }) == true else { return }
            await notifications.enqueueInput(id: issueID, sessionID: sessionID,
                expiresAt: Date().addingTimeInterval(600), kind: "macAttention")
            if !MacAttention.shared.issues.contains(where: { $0.id == issueID }) {
                await notifications.resolveInput(issueID)
            }
        }
    }

    @MainActor
    private func handleMacAccess(_ request: HTTPRequest, on connection: RemoteRequestConnection) {
        guard request.body.count <= 24000 else { sendError(413, "Mac access request is too large.", on: connection); return }
        let desktop = desktopOverride ?? RemoteDesktop.shared
        do {
            if request.path == "/api/v1/mac-access" {
                if request.method == "GET" {
                    let snapshot = desktop.snapshot()
                    sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
                } else if request.method == "POST" {
                    guard let json = request.json, Set(json.keys) == ["permission"],
                          let raw = json["permission"] as? String, let permission = MacPermission(rawValue: raw) else {
                        throw SessionModelSettingsError(400, "Choose a supported settings pane.")
                    }
                    try MacAttention.shared.openSettings(permission)
                    sendJSON(["opened": true], on: connection)
                } else { throw SessionModelSettingsError(405, "method not allowed") }
                return
            }
            guard request.method == "POST", let json = request.json else {
                throw SessionModelSettingsError(405, "Use an explicit Mac access action.")
            }
            if request.path == "/api/v1/desktop/start" {
                struct Start: Decodable { let control: Bool }
                guard Set(json.keys) == ["control"] else { throw SessionModelSettingsError(400, "Provide control only.") }
                let action = try JSONDecoder().decode(Start.self, from: request.body)
                let lease = try desktop.start(control: action.control)
                sendEncoded(on: connection) { try JSONEncoder().encode(lease) }
                return
            }
            struct Action: Decodable {
                let id: UUID
                let token: String
                let displayID: UInt32?
                let sequence: Int?
                let encrypted: String?
            }
            let action = try JSONDecoder().decode(Action.self, from: request.body)
            switch request.path {
            case "/api/v1/desktop/stop":
                guard Set(json.keys) == ["id", "token"] else { throw SessionModelSettingsError(400, "Unexpected stop fields.") }
                try desktop.stop(id: action.id, token: action.token)
                sendJSON(["stopped": true], on: connection)
            case "/api/v1/desktop/frame":
                guard Set(json.keys) == ["id", "token", "displayID"], let displayID = action.displayID else {
                    throw SessionModelSettingsError(400, "Choose a display.")
                }
                let pairingToken = token
                Task {
                    do {
                        let frame = try await desktop.frame(id: action.id, token: action.token, displayID: displayID)
                        guard self.token == pairingToken, !self.token.isEmpty else {
                            sendError(401, "Pairing changed during capture.", on: connection)
                            return
                        }
                        sendEncoded(on: connection) { try JSONEncoder().encode(frame) }
                    } catch let error as SessionModelSettingsError {
                        sendError(error.status, error.message, on: connection)
                    } catch {
                        sendError(503, "The Mac cannot capture this screen. Protected dialogs or a locked session may require local interaction.", on: connection)
                    }
                }
            case "/api/v1/desktop/input":
                guard Set(json.keys) == ["id", "token", "sequence", "encrypted"],
                      let sequence = action.sequence, let encrypted = action.encrypted else {
                    throw SessionModelSettingsError(400, "Provide the encrypted input and sequence.")
                }
                try desktop.input(id: action.id, token: action.token, sequence: sequence, encrypted: encrypted)
                sendJSON(["accepted": true], on: connection)
            default: throw SessionModelSettingsError(404, "Mac access action not found.")
            }
        } catch let error as SessionModelSettingsError {
            sendError(error.status, error.message, on: connection)
        } catch {
            sendError(400, "Invalid Mac access request.", on: connection)
        }
    }

    private func updateNotificationActivation(fingerprint: String?) {
        notificationLifecycleLock.lock()
        defer { notificationLifecycleLock.unlock() }
        let previous = notificationLifecycleTask
        notificationLifecycleTask = Task {
            await previous?.value
            await notifications.activate(fingerprint: fingerprint)
        }
    }

    private func updateLiveStatusActivation(fingerprint: String?) {
        liveStatusLifecycleLock.lock()
        let previous = liveStatusLifecycleTask
        liveStatusLifecycleTask = Task {
            await previous?.value
            await liveStatus.activate(fingerprint: fingerprint)
        }
        liveStatusLifecycleLock.unlock()
        Task { @MainActor [weak self] in
            if fingerprint == nil { self?.liveStatusObservation = nil }
            else { self?.startLiveStatusObservation() }
        }
    }

    private func currentLiveStatusActivation() -> Task<Void, Never>? {
        liveStatusLifecycleLock.lock()
        defer { liveStatusLifecycleLock.unlock() }
        return liveStatusLifecycleTask
    }

    @MainActor
    private func startLiveStatusObservation() {
        guard liveStatusObservation == nil else {
            publishLiveStatusSnapshot()
            return
        }
        // Throttle, not debounce: a streaming tab changes constantly, and another
        // tab finishing must still be published.
        liveStatusObservation = manager?.objectWillChange
            .throttle(for: .milliseconds(1500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishLiveStatusSnapshot() }
            }
        publishLiveStatusSnapshot()
    }

    @MainActor
    private func publishLiveStatusSnapshot() {
        guard !token.isEmpty, let manager else { return }
        let snapshot = liveStatusSnapshot(from: manager)
        let activation = currentLiveStatusActivation()
        Task { [liveStatus] in
            await activation?.value
            await liveStatus.update(snapshot)
        }
    }

    @MainActor
    private func liveStatusSnapshot(from manager: SessionManager) -> LiveStatusSnapshot {
        LiveStatusSnapshot.build(from: manager.sessions.map { session in
            LiveStatusSession(
                id: session.id,
                title: session.title,
                customTitle: session.tabMetadata.customTitle,
                isPrivate: session.isPrivate,
                isLocalPrivate: session.isLocalPrivate,
                isStreaming: session.isStreaming,
                statusText: session.statusText,
                currentActivityTitle: session.currentActivity?.title,
                queued: session.queued.count,
                pendingInputs: session.pendingInputs.map { LiveStatusInput(title: $0.title, kind: $0.kind.rawValue) },
                currentRunStartedAt: session.currentRunStart,
                lastRunOutcome: session.lastRunOutcome,
                activeSubagents: activeSubagents(in: session)
            )
        })
    }

    @MainActor
    private func activeSubagents(in session: ChatSession) -> Int {
        let messages: [ChatMessage]
        if let runID = session.currentRunIdentifier {
            messages = session.messages.filter { $0.runID == runID && $0.role == .assistant }
        } else if let latest = session.messages.last(where: { $0.role == .assistant }) {
            messages = [latest]
        } else {
            messages = []
        }
        return messages.flatMap(\.activities).flatMap(\.subagentActivities)
            .filter { $0.subagent?.isActive == true }.count
    }

    private func cancelLANListener() {
        lanGeneration += 1
        lanListener?.stateUpdateHandler = nil
        lanListener?.cancel()
        lanListener = nil
    }

    /// Starts the TLS-PSK listener, on `pinnedPort` when given. A pinned port that can't be bound
    /// is retried briefly, then falls back to a dynamic port so Bonjour clients keep working.
    private func startLANListener(token: String, pinnedPort: Int?, fallbackFrom: Int? = nil, attempt: Int = 0) {
        let generation = lanGeneration
        do {
            let parameters = RemoteLANProtocol.listenerParameters(token: token)
            let listener = try pinnedPort.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) }
                .map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
            if advertisesLANService {
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "Cantrip",
                    type: RemoteLANProtocol.serviceType,
                    txtRecord: NWTXTRecord([
                        "id": RemoteLANProtocol.tokenFingerprint(token),
                        "v": "1",
                    ])
                )
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.lanListener === listener else { return }
                switch state {
                case .ready:
                    self.onError?(nil)
                    if let port = listener.port {
                        Log.write("remote-control: encrypted LAN service ready on port \(port)"
                            + (fallbackFrom.map { " (port \($0) was unavailable)" } ?? ""))
                        self.onLANStatus?(RemoteLANStatus(
                            port: Int(port.rawValue), requestedPort: fallbackFrom ?? pinnedPort
                        ))
                    }
                case .waiting(let error) where pinnedPort != nil && Self.isPortConflict(error),
                     .failed(let error) where pinnedPort != nil:
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    // start() and stop() run on the main queue; continue there unless they replaced us.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == self.lanGeneration, self.lanListener === listener else { return }
                        self.lanListener = nil
                        if attempt == 0 || attempt + 1 >= self.lanPinnedRetries {
                            Log.write("remote-control: LAN port \(pinnedPort!) unavailable: \(error.localizedDescription)")
                        }
                        self.pinnedLANPortUnavailable(token: token, pinnedPort: pinnedPort!, attempt: attempt)
                    }
                case .failed(let error):
                    self.onError?(
                        "Direct local-network control failed: \(error.localizedDescription)"
                    )
                    Log.write("remote-control: LAN listener failed: \(error.localizedDescription)")
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    self.lanListener = nil
                    self.onLANStatus?(nil)
                default:
                    break
                }
            }
            lanListener = listener
            listener.start(queue: queue)
        } catch {
            if let pinnedPort {
                Log.write("remote-control: LAN port \(pinnedPort) unavailable: \(error.localizedDescription)")
                pinnedLANPortUnavailable(token: token, pinnedPort: pinnedPort, attempt: lanPinnedRetries)
                return
            }
            onError?("Direct local-network control failed: \(error.localizedDescription)")
            Log.write("remote-control: LAN listener failed: \(error.localizedDescription)")
        }
    }

    /// Main queue. Retries the pinned port, then serves on a dynamic port and keeps checking
    /// whether the pinned one has been released.
    private func pinnedLANPortUnavailable(token: String, pinnedPort: Int, attempt: Int) {
        let generation = lanGeneration
        if attempt + 1 < lanPinnedRetries {
            DispatchQueue.main.asyncAfter(deadline: .now() + lanPinnedRetryDelay) { [weak self] in
                guard let self, generation == self.lanGeneration, self.lanListener == nil,
                      self.token == token else { return }
                self.startLANListener(token: token, pinnedPort: pinnedPort, attempt: attempt + 1)
            }
            return
        }
        startLANListener(token: token, pinnedPort: nil, fallbackFrom: pinnedPort)
        scheduleLANReclaim(token: token, pinnedPort: pinnedPort, generation: generation)
    }

    private func scheduleLANReclaim(token: String, pinnedPort: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + lanReclaimInterval) { [weak self] in
            guard let self, generation == self.lanGeneration, self.token == token,
                  self.activeLANPort == pinnedPort else { return }
            guard Self.portIsFree(pinnedPort) else {
                self.scheduleLANReclaim(token: token, pinnedPort: pinnedPort, generation: generation)
                return
            }
            Log.write("remote-control: LAN port \(pinnedPort) is free again; moving back to it")
            self.cancelLANListener()
            self.startLANListener(token: token, pinnedPort: pinnedPort)
        }
    }

    /// Whether a dual-stack wildcard bind of `port` would succeed right now.
    private static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_any
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }

    private static func isPortConflict(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return [.EADDRINUSE, .EACCES, .EADDRNOTAVAIL].contains(code)
    }

    private func accept(_ connection: NWConnection) {
        let request = RemoteRequestConnection(socket: connection, queue: queue,
                                              sendTimeout: sendTimeout, log: requestLog)
        request.start()
        receiveRequest(on: request, buffer: Data())
    }

    private func receiveRequest(on connection: RemoteRequestConnection, buffer: Data) {
        connection.socket.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.socket.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if next.count > self.maximumRequestBytes {
                self.sendError(413, "request too large", on: connection)
                return
            }
            if let request = HTTPRequest.parse(next) {
                connection.trace.identify(request)
                connection.trace.enter(.parse)
                if request.method == "GET", request.path == "/health" {
                    self.send(status: 200, contentType: "application/json; charset=utf-8",
                              body: Self.healthBody, on: connection)
                    return
                }
                let json = authorized(request.headers["authorization"]) ? request.json : nil
                connection.trace.enter(.mainWait)
                Task { @MainActor [weak self] in
                    connection.trace.enter(.handler)
                    self?.route(request, json: json, on: connection)
                }
            } else if !HTTPRequest.needsMoreData(next) {
                self.sendError(400, "malformed request", on: connection)
            } else if isComplete || error != nil {
                self.sendError(400, "incomplete request", on: connection)
            } else {
                self.receiveRequest(on: connection, buffer: next)
            }
        }
    }

    @MainActor
    private func route(_ request: HTTPRequest, json: [String: Any]?, on connection: RemoteRequestConnection) {
        // Frame navigations cannot carry the pairing header, so views load
        // through short-lived single-use URLs minted by an authorized request.
        if request.method == "GET", request.path.hasPrefix("/mcp-app/") {
            serveMCPAppView(String(request.path.dropFirst("/mcp-app/".count)), on: connection)
            return
        }
        if request.method == "GET", request.path == "/" {
            send(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(Self.webApp.utf8),
                on: connection
            )
            return
        }
        guard request.path == "/api/v1/sessions"
                || request.path == "/api/v1/ready"
                || request.path.hasPrefix("/api/v1/sessions/")
                || request.path == "/api/v1/sections"
                || request.path.hasPrefix("/api/v1/sections/")
                || request.path == "/api/v1/home"
                || request.path.hasPrefix("/api/v1/home/")
                || request.path == "/api/v1/github/builds"
                || request.path == "/api/v1/memory"
                || request.path == "/api/v1/memory/document"
                || request.path == "/api/v1/voice/vocabulary"
                || request.path == "/api/v1/notifications"
                || request.path == "/api/v1/live-status"
                || request.path == "/api/v1/live-status/subscription"
                || request.path == "/api/v1/maintenance"
                || request.path == "/api/v1/mac-access"
                || request.path.hasPrefix("/api/v1/desktop/")
                || request.path == "/api/v1/copilot/usage" else {
            sendError(404, "not found", on: connection)
            return
        }
        guard authorized(request.headers["authorization"]) else {
            sendError(401, "invalid pairing token", on: connection)
            return
        }
        if request.path == "/api/v1/mac-access" || request.path.hasPrefix("/api/v1/desktop/") {
            handleMacAccess(request, on: connection)
            return
        }
        if request.path == "/api/v1/maintenance" {
            guard ["GET", "POST"].contains(request.method) else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard let manager else {
                sendError(503, "session manager unavailable", on: connection)
                return
            }
            let maintenance = self.maintenance ?? RemoteMaintenance(manager: manager)
            self.maintenance = maintenance
            do {
                let value: RemoteMaintenanceSnapshot
                if request.method == "POST" {
                    guard request.body.count <= 1024, let json,
                          Set(json.keys) == ["id", "action", "revision"],
                          let action = try? JSONDecoder().decode(RemoteMaintenanceRequest.self, from: request.body) else {
                        sendError(400, "Provide UUID id and revision values, and one action: check, update, rebuild, or restart.", on: connection)
                        return
                    }
                    value = try maintenance.start(action)
                } else {
                    value = maintenance.snapshot()
                }
                sendEncoded(status: request.method == "POST" ? 202 : 200, on: connection) {
                    try JSONEncoder().encode(value)
                }
            } catch let error as RemoteMaintenanceError {
                sendError(error.status, error.message, on: connection)
            } catch {
                Log.write("remote-maintenance: request failed: \(error.localizedDescription)")
                sendError(500, "Could not save maintenance state on the Mac. No new operation was started.", on: connection)
            }
            return
        }
        if request.path == "/api/v1/notifications" {
            let fingerprint = RemoteLANProtocol.tokenFingerprint(token)
            guard ["GET", "POST", "DELETE"].contains(request.method) else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard request.body.count <= 4096 else {
                sendError(413, "notification registration is too large", on: connection)
                return
            }
            Task {
                do {
                    if request.method == "POST" {
                        let registration: RemotePushRegistration
                        do { registration = try JSONDecoder().decode(RemotePushRegistration.self, from: request.body) }
                        catch { throw RemotePushError(status: 400, message: "Invalid notification registration.") }
                        try await notifications.register(registration, fingerprint: fingerprint)
                    } else if request.method == "DELETE" {
                        struct Removal: Decodable { let installationID: UUID; let serverID: UUID }
                        let removal: Removal
                        do { removal = try JSONDecoder().decode(Removal.self, from: request.body) }
                        catch { throw RemotePushError(status: 400, message: "Invalid notification removal.") }
                        try await notifications.unregister(installationID: removal.installationID,
                                                           serverID: removal.serverID, fingerprint: fingerprint)
                    }
                    let status = await notifications.status()
                    sendEncoded(on: connection) { try JSONEncoder().encode(status) }
                } catch let error as RemotePushError {
                    sendError(error.status, error.message, on: connection)
                } catch {
                    Log.write("remote-notifications: request failed: \(error.localizedDescription)")
                    sendError(500, "Could not update notification registration on the Mac.", on: connection)
                }
            }
            return
        }
        if request.path == "/api/v1/live-status/subscription" {
            let fingerprint = RemoteLANProtocol.tokenFingerprint(token)
            guard ["GET", "POST", "DELETE"].contains(request.method) else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard request.body.count <= 4096 else {
                sendError(413, "live status subscription is too large", on: connection)
                return
            }
            let activation = currentLiveStatusActivation()
            Task {
                do {
                    await activation?.value
                    if request.method == "POST" {
                        guard let json = request.json else {
                            throw RemotePushError(status: 400, message: "Invalid live status subscription.")
                        }
                        try await liveStatus.merge(RemoteLiveStatusSubscriptionUpdate(json: json),
                                                   fingerprint: fingerprint)
                    } else if request.method == "DELETE" {
                        guard let json = request.json else {
                            throw RemotePushError(status: 400, message: "Invalid live status subscription removal.")
                        }
                        try await liveStatus.unregister(RemoteLiveStatusSubscriptionRemoval(json: json),
                                                        fingerprint: fingerprint)
                    }
                    let status = await liveStatus.status()
                    sendEncoded(on: connection) { try JSONEncoder().encode(status) }
                } catch let error as RemotePushError {
                    sendError(error.status, error.message, on: connection)
                } catch {
                    Log.write("remote-live-status: request failed: \(error.localizedDescription)")
                    sendError(500, "Could not update live status subscription on the Mac.", on: connection)
                }
            }
            return
        }
        if request.path == "/api/v1/memory" || request.path == "/api/v1/memory/document" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let path = AppSettings.shared.memoryPath
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendError(503, "Configure a Cantrip memory folder on the Mac first.", on: connection)
                return
            }
            serveMemory(request, directory: URL(fileURLWithPath: path),
                        enabled: AppSettings.shared.memoryEnabled, on: connection)
            return
        }
        if request.path == "/api/v1/voice/vocabulary" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            serveVoiceVocabulary(on: connection)
            return
        }
        if request.path == "/api/v1/copilot/usage" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            usage.refreshQuotas()
            let snapshot = usage.copilotUsage
            sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
            return
        }
        if request.path == "/api/v1/github/builds" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            Task {
                let snapshot = await buildMonitor.snapshot()
                sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
            }
            return
        }
        guard let manager else {
            sendError(503, "session manager unavailable", on: connection)
            return
        }

        if request.path == "/api/v1/live-status" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let snapshot = liveStatusSnapshot(from: manager)
            sendEncoded(on: connection) { try JSONEncoder().encode(snapshot) }
            return
        }

        if request.path == "/api/v1/ready" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let sessions = manager.sessions.filter { !$0.isPrivate }
                .map { snapshot($0, includeMessages: false, on: connection) }
            sendJSON(["status": "ready", "sessions": sessions], on: connection)
            return
        }
        let recentExchanges: Int?
        if connection.trace.usesPagedHistory, let raw = request.query("recentExchanges") {
            guard let count = Int(raw), (1...3).contains(count) else {
                sendError(400, "recentExchanges must be between 1 and 3.", on: connection)
                return
            }
            recentExchanges = count
        } else {
            recentExchanges = nil
        }
        if request.path == "/api/v1/sections" || request.path.hasPrefix("/api/v1/sections/") {
            handleTabSections(request, on: connection)
            return
        }

        if request.path == "/api/v1/sessions" {
            switch request.method {
            case "GET":
                let sessions = manager.sessions
                    .filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false, on: connection) }
                var listing: [String: Any] = ["sessions": sessions, "uiRevision": Self.webAppRevision,
                                              "sections": manager.tabSections.map(\.json), "supportsTabSections": true]
                if AppSettings.shared.cantripHomeEnabled {
                    // Web clients pin it as their first tab; tab-list clients ignore it.
                    listing["home"] = snapshot(manager.homeSession, includeMessages: false, on: connection)
                }
                let homeInputs = Self.homeInputs()
                if !homeInputs.isEmpty { listing["homeInputs"] = homeInputs }
                sendJSON(listing, on: connection)
            case "POST":
                // Optional {"sectionID": "<uuid>"} files the new tab under a section.
                let rawSection = request.body.isEmpty ? nil : request.json?["sectionID"]
                let sectionID: UUID?
                if let rawSection, !(rawSection is NSNull) {
                    guard let text = rawSection as? String, let id = UUID(uuidString: text) else {
                        sendError(400, "sectionID must be a UUID or null.", on: connection)
                        return
                    }
                    sectionID = id
                } else {
                    sectionID = nil
                }
                do {
                    let session = try manager.newSession(inSection: sectionID)
                    sendSession(session, status: 201, recentExchanges: recentExchanges, on: connection)
                } catch let error as TabSectionError {
                    sendError(error.status, error.localizedDescription, on: connection)
                } catch {
                    sendError(500, error.localizedDescription, on: connection)
                }
            default:
                sendError(405, "method not allowed", on: connection)
            }
            return
        }

        if request.path == "/api/v1/home" || request.path.hasPrefix("/api/v1/home/") {
            handleCantripHome(
                request, json: json, manager: manager,
                recentExchanges: recentExchanges, on: connection
            )
            return
        }

        let tail = String(request.path.dropFirst("/api/v1/sessions/".count))
        let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
        guard let rawID = parts.first,
              let id = UUID(uuidString: String(rawID)),
              let session = manager.managedSession(id: id),
              !session.isPrivate,
              (!SessionManager.isCantripHomeReserved(session) || AppSettings.shared.cantripHomeEnabled)
        else {
            sendError(404, "session not found", on: connection)
            return
        }

        if parts.count >= 3, parts[1] == "apps" {
            handleMCPApp(request, json: json, session: session, appID: String(parts[2]),
                         action: parts.count == 4 ? String(parts[3]) : parts.count == 3 ? nil : "invalid",
                         on: connection)
            return
        }

        // Child tabs: fork a queued message; act on a child's card in its parent.
        if parts.count == 4, parts[1] == "queue", parts[3] == "fork" {
            guard request.method == "POST" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard let promptID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "queued message ID must be a UUID", on: connection)
                return
            }
            Task {
                do {
                    let child = try await manager.childTabs.fork(parentID: session.id, itemID: promptID)
                    Log.write("remote-control: forked a queued message into a child tab")
                    var body = ["session": snapshot(session, on: connection)] as [String: Any]
                    body["childID"] = child.id.uuidString
                    sendJSON(body, on: connection)
                } catch let error as ChildTabError {
                    sendError(error.status, error.localizedDescription, on: connection)
                } catch {
                    sendError(409, error.localizedDescription, on: connection)
                }
            }
            return
        }
        if parts.count >= 2, parts[1] == "children" {
            guard parts.count == 4, request.method == "POST", let childID = UUID(uuidString: String(parts[2])) else {
                sendError(404, "child tab action not found", on: connection)
                return
            }
            guard let record = ChildTabStore.shared.record(childID), record.parentID == session.id else {
                sendError(404, "child tab not found", on: connection)
                return
            }
            do {
                try manager.childTabs.perform(String(parts[3]), childID: childID)
                sendSession(session, recentExchanges: recentExchanges, on: connection)
            } catch let error as ChildTabError {
                sendError(error.status, error.localizedDescription, on: connection)
            } catch {
                sendError(409, error.localizedDescription, on: connection)
            }
            return
        }

        if parts.count >= 2, parts[1] == "commands" {
            guard parts.count == 2 else {
                sendError(404, "not found", on: connection)
                return
            }
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let refresh = request.query("refresh") == "true"
            Task { @MainActor in
                let list = await BackendCommandCatalog.shared.list(for: session, refresh: refresh)
                self.sendEncoded(on: connection) { try JSONEncoder().encode(list) }
            }
            return
        }

        if parts.count >= 2, parts[1] == "subagents" {
            guard parts.count == 4, parts[3] == "cancel", !parts[2].isEmpty, parts[2].count <= 128 else {
                sendError(404, "not found", on: connection)
                return
            }
            guard request.method == "POST" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard request.body.count <= 1024 else {
                sendError(400, "Stopping a subagent takes no request body.", on: connection)
                return
            }
            session.cancelSubagent(agentID: String(parts[2])) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let cancelled):
                    self.sendJSON(["cancelled": cancelled], on: connection)
                case .failure(let error):
                    let notFound = (error as? SubagentCancelError) == .notFound
                    self.sendError(notFound ? 404 : 409, error.localizedDescription, on: connection)
                }
            }
            return
        }

        if parts.count >= 2, parts[1] == "input" {
            if parts.count == 2, request.method == "GET" {
                let requests = Self.presentedInputs(session)
                sendEncoded(on: connection) { try JSONEncoder().encode(["requests": requests]) }
            } else if parts.count == 3, request.method == "POST",
                      let requestID = UUID(uuidString: String(parts[2])) {
                guard request.body.count <= 12000, let json,
                      Set(json.keys).isSubset(of: ["decision", "text"]), json["decision"] is String,
                      json["text"] == nil || json["text"] is String else {
                    sendError(400, "Provide a decision and, only when requested, a text value.", on: connection)
                    return
                }
                do {
                    let answer = try JSONDecoder().decode(InputRequestAnswer.self, from: request.body)
                    try session.respondToInput(id: requestID, answer: answer)
                    sendJSON(["accepted": true], on: connection)
                } catch let error as InputRequestError {
                    sendError(error == .unavailable ? 409 : 400, error.localizedDescription, on: connection)
                } catch {
                    sendError(400, "Invalid input response.", on: connection)
                }
            } else { sendError(405, "method not allowed", on: connection) }
            return
        }

        if parts.count >= 2, parts[1] == "videos" {
            guard session.supportsRemoteImages else {
                sendError(409, "Choose a Claude, Copilot, or Codex backend to analyze videos.", on: connection)
                return
            }
            guard (parts.count == 3 || (parts.count == 4 && parts[3] == "prepare")),
                  let uploadID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "invalid video upload ID", on: connection)
                return
            }
            let method = request.method
            guard (parts.count == 3 && ["GET", "PUT"].contains(method))
                    || (parts.count == 4 && method == "POST") else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            Task {
                do {
                    let upload: RemoteVideoUpload?
                    if method == "GET" {
                        upload = try await RemoteVideoAttachments.shared.status(sessionID: id, uploadID: uploadID)
                    } else if method == "PUT" {
                        guard let offset = request.query("offset").flatMap(Int.init),
                              let total = request.query("totalBytes").flatMap(Int.init),
                              let format = request.query("format"), let name = request.query("name"),
                              let sha256 = request.query("sha256") else {
                            throw RemoteVideoError(status: 400, message: "Video upload metadata is required.")
                        }
                        upload = try await RemoteVideoAttachments.shared.receive(
                            sessionID: id, uploadID: uploadID, offset: offset,
                            upload: RemoteVideoUpload(totalBytes: total, format: format, name: name,
                                                      sha256: sha256, receivedBytes: 0),
                            data: request.body
                        )
                    } else {
                        try await RemoteVideoAttachments.shared.prepare(sessionID: id, uploadID: uploadID)
                        upload = nil
                    }
                    guard manager.managedSession(id: id).map({ !$0.isPrivate }) == true else {
                        sendError(404, "session not found", on: connection)
                        return
                    }
                    if let upload {
                        sendEncoded(on: connection) {
                            try JSONEncoder().encode(["upload": upload])
                        }
                    } else {
                        sendJSON(["ready": true], on: connection)
                    }
                } catch let error as RemoteVideoError {
                    sendError(error.status, error.message, on: connection)
                } catch {
                    Log.write("remote-control: video preparation failed: \(error.localizedDescription)")
                    sendError(422, "Could not save or decode this video on the Mac. Choose a playable MOV or MP4 and check disk space.", on: connection)
                }
            }
            return
        }

        if parts.count >= 2, parts[1] == "files" {
            guard session.supportsRemoteImages else {
                sendError(409, "Choose a Claude, Copilot, or Codex backend to attach files.", on: connection)
                return
            }
            guard parts.count == 3, let uploadID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "invalid file upload ID", on: connection)
                return
            }
            let method = request.method
            guard ["GET", "PUT"].contains(method) else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            Task {
                do {
                    let upload: RemoteFileUpload
                    if method == "GET" {
                        upload = try await RemoteFileAttachments.shared.status(sessionID: id, uploadID: uploadID)
                    } else {
                        guard let offset = request.query("offset").flatMap(Int.init),
                              let total = request.query("totalBytes").flatMap(Int.init),
                              let name = request.query("name"), let sha256 = request.query("sha256") else {
                            throw RemoteVideoError(status: 400, message: "File upload metadata is required.")
                        }
                        upload = try await RemoteFileAttachments.shared.receive(
                            sessionID: id, uploadID: uploadID, offset: offset,
                            upload: RemoteFileUpload(totalBytes: total, name: name, sha256: sha256, receivedBytes: 0),
                            data: request.body
                        )
                    }
                    guard manager.managedSession(id: id).map({ !$0.isPrivate }) == true else {
                        sendError(404, "session not found", on: connection)
                        return
                    }
                    sendEncoded(on: connection) { try JSONEncoder().encode(["upload": upload]) }
                } catch let error as RemoteVideoError {
                    sendError(error.status, error.message, on: connection)
                } catch {
                    Log.write("remote-control: file upload failed: \(error.localizedDescription)")
                    sendError(422, "Could not save this file on the Mac. Check disk space and try again.", on: connection)
                }
            }
            return
        }

        if parts.count == 3, parts[1] == "messages", request.method == "GET" {
            guard let messageID = UUID(uuidString: String(parts[2])),
                  let message = session.messages.first(where: { $0.id == messageID }) else {
                sendError(404, "message no longer available", on: connection)
                return
            }
            let index = session.messages.firstIndex { $0.id == messageID } ?? 0
            let tags = ThreadTags.tags(in: session.messages, range: index..<index + 1, sessionID: id)
            let object = messageSnapshot(message, sessionID: id, home: HomeReplyView(session), thread: tags[messageID])
            sendEncoded(on: connection, queue: detailEncodingQueue) {
                try JSONSerialization.data(withJSONObject: ["message": object], options: [.sortedKeys])
            }
            return
        }
        // A thread tag's thread: its prompt and the earlier messages in it (Home).
        if parts.count == 3, parts[1] == "threads", request.method == "GET" {
            let home = HomeReplyView(session)
            guard let threadID = UUID(uuidString: String(parts[2])),
                  let thread = ThreadTags.thread(
                    threadID, in: session.messages, before: request.query("before").flatMap(UUID.init(uuidString:)),
                    sessionID: id, visibleText: { message in
                        message.role == .assistant ? home?.text(of: message) ?? message.text : message.text
                    }
                  ) else {
                sendError(404, "This thread's first message is no longer available.", on: connection)
                return
            }
            sendEncoded(on: connection, queue: detailEncodingQueue) {
                try JSONSerialization.data(withJSONObject: ["thread": thread], options: [.sortedKeys])
            }
            return
        }
        if parts.count == 2, ["private-settings", "private-models"].contains(String(parts[1])) {
            do {
                guard session.isLocalPrivate else { throw SessionModelSettingsError(404, "Private Local tab not found.") }
                if parts[1] == "private-models" {
                    guard request.method == "GET" else { throw SessionModelSettingsError(405, "method not allowed") }
                    var configuration = try session.privateLocalConfiguration()
                    if let baseURL = request.query("baseURL") { configuration.baseURL = baseURL }
                    try configuration.validate(requireModel: false)
                    Task {
                        let client = PrivateLocalClient()
                        defer { client.close() }
                        do {
                            let models = try await client.models(configuration)
                            sendJSON(["models": models], on: connection)
                        } catch {
                            sendError(502, error.localizedDescription, on: connection)
                        }
                    }
                    return
                }
                if request.method == "POST" {
                    guard let json, Set(json.keys) == ["revision", "configuration"],
                          let revision = json["revision"] as? String,
                          let fields = json["configuration"] as? [String: Any],
                          Set(fields.keys) == ["baseURL", "model", "contextWindow", "systemPrompt"],
                          fields["baseURL"] is String, fields["model"] is String, fields["systemPrompt"] is String,
                          let tokens = fields["contextWindow"] as? NSNumber,
                          CFGetTypeID(tokens) != CFBooleanGetTypeID(),
                          tokens.doubleValue == Double(tokens.intValue) else {
                        throw SessionModelSettingsError(400, "Provide revision and the complete Private Local configuration.")
                    }
                    let configuration = try JSONDecoder().decode(PrivateLocalConfiguration.self,
                        from: JSONSerialization.data(withJSONObject: fields))
                    try session.updatePrivateLocalSettings(configuration, revision: revision)
                } else if request.method != "GET" {
                    throw SessionModelSettingsError(405, "method not allowed")
                }
                let data = try JSONEncoder().encode(session.privateLocalSnapshot())
                send(status: 200, contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch let error as SessionModelSettingsError {
                sendError(error.status, error.message, on: connection)
            } catch {
                sendError(400, "Could not read or save Private Local settings. Reload before retrying.", on: connection)
            }
            return
        }
        if parts.count == 2, parts[1] == "model-settings" {
            do {
                guard !session.isLocalPrivate else {
                    throw SessionModelSettingsError(409, "Private Local cannot use cloud models. Open Private Local Settings.")
                }
                guard !session.isCantripHomeBackground else {
                    throw SessionModelSettingsError(409, "Background runs use Cantrip Home's model. Change it in Home.")
                }
                if request.method == "GET" {
                    if request.query("refresh") == "true" {
                        session.settings.refreshCopilotModels()
                    } else if session.settings.copilotModelRefreshError == nil {
                        session.settings.refreshCopilotModelsIfNeeded()
                    }
                } else if request.method == "POST" {
                    guard let json, let revision = json["revision"] as? String,
                          let inherit = json["usesDefaults"] as? NSNumber,
                          CFGetTypeID(inherit) == CFBooleanGetTypeID() else {
                        throw SessionModelSettingsError(400, "Provide revision and usesDefaults.")
                    }
                    let selection: SessionModelSelection?
                    if inherit.boolValue {
                        guard Set(json.keys) == ["revision", "usesDefaults"] else {
                            throw SessionModelSettingsError(400, "Do not include overrides when using Mac defaults.")
                        }
                        selection = nil
                    } else {
                        guard Set(json.keys) == ["revision", "usesDefaults", "model", "effort", "contextTier"],
                              let model = json["model"] as? String, let effort = json["effort"] as? String,
                              let tier = json["contextTier"] as? String else {
                            throw SessionModelSettingsError(400, "Provide model, effort and contextTier strings.")
                        }
                        selection = SessionModelSelection(model: model, effort: effort, contextTier: tier)
                    }
                    try session.updateModelSettings(selection, revision: revision)
                } else {
                    throw SessionModelSettingsError(405, "method not allowed")
                }
                let data = try JSONEncoder().encode(session.modelSettingsSnapshot)
                send(status: 200, contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch let error as SessionModelSettingsError {
                sendError(error.status, error.message, on: connection)
            } catch {
                Log.write("remote-control: model settings failed: \(error.localizedDescription)")
                sendError(500, "Could not save model settings on the Mac. Reload before retrying.", on: connection)
            }
            return
        }
        if parts.count == 2, parts[1] == "move" {
            guard request.method == "POST" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard let json, Set(json.keys) == ["targetID", "placement"],
                  let rawTarget = json["targetID"] as? String,
                  let targetID = UUID(uuidString: rawTarget),
                  let placement = json["placement"] as? String,
                  ["before", "after"].contains(placement) else {
                sendError(400, "targetID must be a UUID and placement must be before or after", on: connection)
                return
            }
            guard manager.sessions.contains(where: { $0.id == targetID && !$0.isPrivate }) else {
                sendError(404, "session not found", on: connection)
                return
            }
            do {
                try manager.moveSession(id, relativeTo: targetID, after: placement == "after")
                let sessions = manager.sessions.filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false, on: connection) }
                sendJSON(["sessions": sessions, "sections": manager.tabSections.map(\.json)], on: connection)
            } catch {
                sendError(409, error.localizedDescription, on: connection)
            }
            return
        }

        if parts.count >= 2, parts[1] == "previews" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard parts.count == 4 || (parts.count == 5 && parts[4] == "thumbnail"),
                  let messageID = UUID(uuidString: String(parts[2])) else {
                sendError(404, "preview not found", on: connection)
                return
            }
            let imageID = "previews/\(parts[2])/\(parts[3])"
            guard !session.isLocalPrivate, RemoteGeneratedImages.validID(imageID),
                  let text = Self.previewSourceText(in: session, id: messageID),
                  let reference = RemoteGeneratedImages.presentation(
                    text,
                    messageID: messageID,
                    additionalRoots: generatedImageRoots(sessionID: session.id)
                  )
                    .images.first(where: { $0.id == imageID }) else {
                sendError(404, "preview not found in this session", on: connection)
                return
            }
            Task {
                do {
                    let data = try await generatedImages.read(reference, sessionID: id, thumbnail: parts.count == 5)
                    guard                     let current = manager.managedSession(id: id), !current.isPrivate,
                          let text = Self.previewSourceText(in: current, id: messageID),
                          RemoteGeneratedImages.presentation(
                            text,
                            messageID: messageID,
                            additionalRoots: generatedImageRoots(sessionID: current.id)
                          )
                            .images.contains(where: { $0.id == imageID }) else {
                        sendError(404, "preview not found in this session", on: connection)
                        return
                    }
                    sendJSON(["data": data.base64EncodedString()], on: connection)
                } catch {
                    Log.write("remote-control: generated preview failed: \(error.localizedDescription)")
                    sendError(404, "The generated image is no longer available or cannot be previewed on the Mac.",
                              on: connection)
                }
            }
            return
        }
        if parts.count >= 2, parts[1] == "attachments" {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard parts.count == 4 || (parts.count == 5 && parts[4] == "thumbnail") else {
                sendError(404, "image not found", on: connection)
                return
            }
            let imageID = "\(parts[2])/\(parts[3])"
            let prompts = session.messages.filter { $0.role == .user }.map(\.text)
                + session.queued.map(\.text)
            guard RemoteImageAttachments.validID(imageID),
                  prompts.contains(where: {
                      RemoteImageAttachments.presentation($0, sessionID: id).imageIDs.contains(imageID)
                  }) else {
                sendError(404, "image not found in this session", on: connection)
                return
            }
            let thumbnail = parts.count == 5
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try RemoteImageAttachments.read(id: imageID, sessionID: id, thumbnail: thumbnail)
                    }.value
                    guard manager.managedSession(id: id).map({ !$0.isPrivate }) == true else {
                        sendError(404, "session not found", on: connection)
                        return
                    }
                    sendJSON(["data": data.base64EncodedString()], on: connection)
                } catch {
                    Log.write("remote-control: attachment read failed: \(error.localizedDescription)")
                    sendError(404, "The attached image is no longer available on the Mac.", on: connection)
                }
            }
            return
        }
        if parts.count == 1, request.method == "GET" {
            if connection.trace.usesPagedHistory {
                let summary = snapshot(session, includeMessages: false, on: connection)
                if request.query("before") == nil,
                   request.query("revision") == summary["historyRevision"] as? String {
                    sendJSON(["unchanged": true], on: connection)
                    return
                }
                var end = session.messages.endIndex
                if let before = request.query("before") {
                    guard let cursor = UUID(uuidString: before),
                          let index = session.messages.firstIndex(where: { $0.id == cursor }) else {
                        sendError(409, "History changed. Refresh the conversation before loading older messages.", on: connection)
                        return
                    }
                    end = index
                }
                sendPagedSession(session, summary: summary, end: end,
                                 recentExchanges: request.query("before") == nil ? recentExchanges : nil,
                                 on: connection)
                return
            }
            sendJSON(["session": snapshot(session, on: connection)], on: connection)
            return
        }
        if parts.count == 3, parts[1] == "queue", request.method == "DELETE" {
            guard let promptID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "queued message ID must be a UUID", on: connection)
                return
            }
            guard let index = session.queued.firstIndex(where: { $0.id == promptID }) else {
                sendError(409, "This message is no longer queued. It may have started or been removed on another device.", on: connection)
                return
            }
            // Resolve and remove on the main actor without yielding to queue draining.
            session.removeQueued(at: index)
            sendSession(session, recentExchanges: recentExchanges, on: connection)
            return
        }
        if parts.count == 4, parts[1] == "queue", parts[3] == "send" {
            guard request.method == "POST" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            guard request.body.count <= 1024 else {
                sendError(400, "Sending a queued message now takes no request body.", on: connection)
                return
            }
            guard let promptID = UUID(uuidString: String(parts[2])) else {
                sendError(400, "queued message ID must be a UUID", on: connection)
                return
            }
            if let problem = session.sendQueuedNow(id: promptID) {
                sendError(409, problem, on: connection)
                return
            }
            sendSession(session, recentExchanges: recentExchanges, on: connection)
            return
        }
        guard request.method == "POST", parts.count == 2 else {
            sendError(405, "method not allowed", on: connection)
            return
        }

        switch parts[1] {
        case "metadata":
            guard let body = json,
                  !body.isEmpty,
                  Set(body.keys).isSubset(of: ["customTitle", "isLocked", "sectionID"]),
                  body["customTitle"] == nil || body["customTitle"] is String,
                  body["isLocked"] == nil || (body["isLocked"] as? NSNumber).map({
                      CFGetTypeID($0) == CFBooleanGetTypeID()
                  }) == true,
                  body["sectionID"] == nil || body["sectionID"] is NSNull
                    || (body["sectionID"] as? String).flatMap(UUID.init(uuidString:)) != nil else {
                sendError(400, "Provide customTitle (string), isLocked (boolean) and/or sectionID (UUID or null).", on: connection)
                return
            }
            do {
                if body.keys.contains("sectionID") {
                    try manager.setSection((body["sectionID"] as? String).flatMap(UUID.init(uuidString:)), for: session.id)
                }
                try session.updateTab(name: body["customTitle"] as? String,
                                      isLocked: body["isLocked"] as? Bool)
                sendSession(session, recentExchanges: recentExchanges, on: connection)
            } catch let error as SessionTabError {
                sendError(400, error.localizedDescription, on: connection)
            } catch let error as TabSectionError {
                sendError(error.status, error.localizedDescription, on: connection)
            } catch let error as SessionModelSettingsError {
                sendError(error.status, error.message, on: connection)
            } catch {
                Log.write("remote-control: tab metadata storage failed: \(error.localizedDescription)")
                sendError(500, "Could not save the tab on the Mac.", on: connection)
            }
        case "messages":
            if let message = session.privateStorageError {
                sendError(503, message, on: connection)
                return
            }
            guard let body = json,
                  let text = body["text"] as? String
            else {
                sendError(400, "message text is required", on: connection)
                return
            }
            guard let rawMode = (body["mode"] ?? "auto") as? String,
                  let mode = MessageDeliveryMode(rawValue: rawMode) else {
                sendError(400, "mode must be auto, queue, interrupt, or inject", on: connection)
                return
            }
            do {
                let inputRequestID: UUID?
                if let value = body["inputRequestID"] {
                    guard let raw = value as? String, let id = UUID(uuidString: raw), mode == .auto else {
                        sendError(400, "A chat reply requires an input request UUID and auto delivery.", on: connection)
                        return
                    }
                    try session.validateChatInput(id: id)
                    inputRequestID = id
                } else { inputRequestID = nil }
                let images = try RemoteImageAttachments.decode(body["images"])
                var videoID: UUID?
                if let value = body["videoID"] {
                    guard let raw = value as? String, let uploadID = UUID(uuidString: raw) else {
                        sendError(400, "videoID must be a video upload ID.", on: connection)
                        return
                    }
                    videoID = uploadID
                }
                var fileIDs: [UUID] = []
                if let value = body["fileIDs"] {
                    let raw = value as? [String] ?? []
                    fileIDs = raw.compactMap(UUID.init(uuidString:))
                    guard !raw.isEmpty, raw.count <= RemoteFileAttachments.maximumCount,
                          fileIDs.count == raw.count, Set(fileIDs).count == fileIDs.count else {
                        sendError(400, "Attach up to five files, each sent once.", on: connection)
                        return
                    }
                }
                if videoID != nil || !fileIDs.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard session.supportsRemoteImages else {
                        sendError(409, videoID != nil
                                  ? "The selected backend does not support video analysis."
                                  : "The selected backend can't read attached files.", on: connection)
                        return
                    }
                    guard !trimmed.hasPrefix("!"), !trimmed.hasPrefix("/") else {
                        sendError(400, "Attach videos and files to an agent prompt, not a shell or slash command.",
                                  on: connection)
                        return
                    }
                    Task {
                        do {
                            var video: String?
                            if let videoID {
                                video = try await RemoteVideoAttachments.shared.claim(sessionID: id, uploadID: videoID)
                            }
                            var files: [String] = []
                            for fileID in fileIDs {
                                files.append(try await RemoteFileAttachments.shared.claim(sessionID: id, uploadID: fileID))
                            }
                            guard manager.managedSession(id: id) === session, !session.isPrivate,
                                  session.supportsRemoteImages else {
                                sendError(409, "The session changed before the attachments could be sent.", on: connection)
                                return
                            }
                            let prompt = try RemoteImageAttachments.preparePrompt(
                                RemoteFileAttachments.prompt(trimmed, video: video, files: files, imageCount: images.count),
                                images: images, sessionID: session.id
                            )
                            if let inputRequestID { try session.respondInChat(id: inputRequestID, text: prompt) }
                            else { session.submitRemote(prompt, mode: mode) }
                            sendSession(session, status: 202, recentExchanges: recentExchanges, on: connection)
                        } catch let error as InputRequestError {
                            sendError(error == .unavailable ? 409 : 400, error.localizedDescription, on: connection)
                        } catch let error as RemoteVideoError {
                            sendError(error.status, error.message, on: connection)
                        } catch let error as RemoteImageAttachmentError {
                            sendError(400, error.localizedDescription, on: connection)
                        } catch {
                            Log.write("remote-control: attachment claim failed: \(error.localizedDescription)")
                            sendError(500, "Could not retain the attachments for this session.", on: connection)
                        }
                    }
                    return
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !images.isEmpty else {
                    sendError(400, "message text or images are required", on: connection)
                    return
                }
                guard images.isEmpty || session.supportsRemoteImages else {
                    sendError(409, "The selected Cantrip backend does not support image attachments.", on: connection)
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard images.isEmpty || (!trimmed.hasPrefix("!") && !trimmed.hasPrefix("/")) else {
                    sendError(400, "Attach images to an agent prompt, not a shell or slash command.", on: connection)
                    return
                }
                let prompt = try RemoteImageAttachments.preparePrompt(
                    text, images: images, sessionID: session.id
                )
                if let inputRequestID { try session.respondInChat(id: inputRequestID, text: prompt) }
                else { session.submitRemote(prompt, mode: mode) }
            } catch let error as InputRequestError {
                sendError(error == .unavailable ? 409 : 400, error.localizedDescription, on: connection)
                return
            } catch let error as RemoteImageAttachmentError {
                sendError(400, error.localizedDescription, on: connection)
                return
            } catch {
                Log.write("remote-control: image storage failed: \(error.localizedDescription)")
                sendError(500, "Could not save the attached images on the Mac.", on: connection)
                return
            }
            sendSession(session, status: 202, recentExchanges: recentExchanges, on: connection)
        case "cancel":
            session.cancel()
            sendSession(session, recentExchanges: recentExchanges, on: connection)
        case "resume":
            guard session.canResume, !session.isStreaming else {
                sendError(409, "session is not resumable", on: connection)
                return
            }
            session.resumeInterrupted()
            sendSession(session, status: 202, recentExchanges: recentExchanges, on: connection)
        case "new-conversation":
            guard !session.isLocked else {
                sendError(409, SessionTabError.locked.localizedDescription, on: connection)
                return
            }
            guard !session.isStreaming else {
                sendError(409, "stop the running session before resetting it", on: connection)
                return
            }
            session.newConversation()
            sendSession(session, recentExchanges: recentExchanges, on: connection)
        case "start-fresh":
            guard request.body.count <= 1024, json?.isEmpty ?? true else {
                sendError(400, "Starting fresh takes no request body.", on: connection)
                return
            }
            do {
                try session.startFresh()
                sendSession(session, recentExchanges: recentExchanges, on: connection)
            } catch let error as SessionModelSettingsError {
                sendError(error.status, error.message, on: connection)
            } catch {
                sendError(500, "Could not start this tab fresh on the Mac.", on: connection)
            }
        case "close":
            guard !session.isLocked else {
                sendError(409, SessionTabError.locked.localizedDescription, on: connection)
                return
            }
            guard let sessionIndex = manager.sessions.firstIndex(where: { $0 === session }) else {
                sendError(409, "This permanent session cannot be closed.", on: connection)
                return
            }
            manager.close(sessionIndex)
            let candidate = manager.sessions[min(sessionIndex, manager.sessions.count - 1)]
            let replacement = candidate.isPrivate
                ? manager.sessions.first(where: { !$0.isPrivate }) ?? manager.newSession()
                : candidate
            sendSession(replacement, recentExchanges: recentExchanges, afterJournal: session, on: connection)
        default:
            sendError(404, "action not found", on: connection)
        }
    }

    @MainActor
    private func handleCantripHome(
        _ request: HTTPRequest,
        json: [String: Any]?,
        manager: SessionManager,
        recentExchanges: Int?,
        on connection: RemoteRequestConnection
    ) {
        guard AppSettings.shared.cantripHomeEnabled else {
            sendError(409, "Turn on Cantrip Home in the Mac's Cantrip settings first.", on: connection)
            return
        }
        let store = CantripHomeStore.shared
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 3 {
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let session = manager.homeSession
            if connection.trace.usesPagedHistory {
                let summary = snapshot(session, includeMessages: false, on: connection)
                if request.query("revision") == summary["historyRevision"] as? String {
                    sendJSON(["unchanged": true], on: connection)
                    return
                }
                sendPagedSession(
                    session, summary: summary, end: session.messages.endIndex,
                    recentExchanges: recentExchanges, on: connection
                )
            } else {
                sendJSON(["session": snapshot(session, on: connection)], on: connection)
            }
            return
        }
        guard parts.count >= 4 else {
            sendError(404, "not found", on: connection)
            return
        }
        switch String(parts[3]) {
        case "tasks":
            if parts.count == 4 {
                guard request.method == "GET" else {
                    sendError(405, "Tasks are created conversationally in Cantrip Home.", on: connection)
                    return
                }
                let revision = store.revision.uuidString
                // Clients clear the warning on "unchanged", so send it in full while one stands.
                let warning = store.storageError ?? Consolidator.healthWarning
                if warning == nil, request.query("revision") == revision {
                    sendJSON(["unchanged": true, "revision": revision], on: connection)
                    return
                }
                let value = CantripHomeTasksSnapshot(
                    tasks: store.tasks, revision: revision,
                    error: warning
                )
                sendEncoded(on: connection) { try JSONEncoder().encode(value) }
                return
            }
            guard parts.count >= 5, let id = UUID(uuidString: String(parts[4])) else {
                sendError(404, "task not found", on: connection)
                return
            }
            do {
                if parts.count == 5 {
                    switch request.method {
                    case "PATCH":
                        guard request.body.count <= 16_384, let json,
                              !json.isEmpty,
                              Set(json.keys).isSubset(of: ["title", "prompt", "enabled"]),
                              json["title"] == nil || json["title"] is String,
                              json["prompt"] == nil || json["prompt"] is String,
                              json["enabled"] == nil || (json["enabled"] as? NSNumber).map({
                                  CFGetTypeID($0) == CFBooleanGetTypeID()
                              }) == true else {
                            throw CantripHomeError(400, "Provide title, prompt, and/or enabled.")
                        }
                        let update = try JSONDecoder().decode(
                            CantripHomeTaskUpdate.self, from: request.body
                        )
                        let task = try store.update(id: id, update: update)
                        sendEncoded(on: connection) { try JSONEncoder().encode(task) }
                    case "DELETE":
                        try store.delete(id: id)
                        sendJSON(["deleted": true], on: connection)
                    default:
                        sendError(405, "method not allowed", on: connection)
                    }
                    return
                }
                if parts.count == 6, String(parts[5]) == "move" {
                    guard request.method == "POST" else {
                        throw CantripHomeError(405, "Use POST to move a task.")
                    }
                    guard request.body.count <= 4_096, let json,
                          Set(json.keys) == ["targetID", "placement"],
                          let rawTarget = json["targetID"] as? String,
                          let targetID = UUID(uuidString: rawTarget),
                          let placement = json["placement"] as? String,
                          ["before", "after"].contains(placement) else {
                        throw CantripHomeError(
                            400, "targetID must be a task UUID and placement must be before or after."
                        )
                    }
                    try store.move(id: id, relativeTo: targetID, after: placement == "after")
                    let value = CantripHomeTasksSnapshot(
                        tasks: store.tasks, revision: store.revision.uuidString,
                        error: store.storageError
                    )
                    sendEncoded(on: connection) { try JSONEncoder().encode(value) }
                    return
                }
                guard String(parts[5]) == "records" else {
                    throw CantripHomeError(404, "task record not found")
                }
                if parts.count == 6 {
                    guard request.method == "POST", request.body.count <= 65_536 else {
                        throw CantripHomeError(405, "Use POST to create a task record.")
                    }
                    let update = try JSONDecoder().decode(
                        CantripHomeTaskRecordUpdate.self, from: request.body
                    )
                    let task = try store.upsertRecord(
                        taskID: id, recordID: nil, values: update.values
                    )
                    sendEncoded(on: connection) { try JSONEncoder().encode(task) }
                    return
                }
                guard parts.count == 7,
                      let recordID = UUID(uuidString: String(parts[6])) else {
                    throw CantripHomeError(404, "task record not found")
                }
                let task: CantripHomeTask
                switch request.method {
                case "PATCH":
                    guard request.body.count <= 65_536 else {
                        throw CantripHomeError(413, "The task record update is too large.")
                    }
                    let update = try JSONDecoder().decode(
                        CantripHomeTaskRecordUpdate.self, from: request.body
                    )
                    task = try store.upsertRecord(
                        taskID: id, recordID: recordID, values: update.values
                    )
                case "DELETE":
                    task = try store.deleteRecord(taskID: id, recordID: recordID)
                default:
                    throw CantripHomeError(405, "method not allowed")
                }
                sendEncoded(on: connection) { try JSONEncoder().encode(task) }
            } catch let error as CantripHomeError {
                sendError(error.status, error.message, on: connection)
            } catch is DecodingError {
                sendError(400, "Task data must match the documented JSON shape.", on: connection)
            } catch {
                Log.write("home: task update failed: \(error.localizedDescription)")
                sendError(500, "Could not save the task on the Mac.", on: connection)
            }
        case "artifacts":
            if parts.count == 4 {
                guard request.method == "GET" else {
                    sendError(405, "method not allowed", on: connection)
                    return
                }
                let revision = store.revision.uuidString
                if store.storageError == nil, request.query("revision") == revision {
                    sendJSON(["unchanged": true, "revision": revision], on: connection)
                    return
                }
                let value = CantripHomeArtifactsSnapshot(
                    artifacts: store.artifacts, revision: revision
                )
                sendEncoded(on: connection) { try JSONEncoder().encode(value) }
                return
            }
            if parts.count == 6, parts[5] == "thumbnail" {
                // GET /api/v1/home/artifacts/<id>/thumbnail: a cached JPEG for images and videos.
                guard request.method == "GET" else {
                    sendError(405, "method not allowed", on: connection)
                    return
                }
                guard let id = UUID(uuidString: String(parts[4])),
                      let artifact = store.artifacts.first(where: { $0.id == id }) else {
                    sendError(404, "artifact not found", on: connection)
                    return
                }
                guard CantripHomeArtifactThumbnails.supports(artifact) else {
                    sendError(404, "This artifact has no thumbnail.", on: connection)
                    return
                }
                Task {
                    do {
                        let thumbnail = try await CantripHomeArtifactThumbnails.shared.thumbnail(for: artifact)
                        var object: [String: Any] = [
                            "data": thumbnail.jpeg.base64EncodedString(),
                            "width": thumbnail.width, "height": thumbnail.height,
                        ]
                        if let duration = thumbnail.durationSeconds { object["durationSeconds"] = duration }
                        sendJSON(object, on: connection)
                    } catch {
                        Log.write("home: thumbnail for \(id.uuidString.prefix(8)) unavailable: \(error)")
                        sendError(404, "A thumbnail is not available for this artifact.", on: connection)
                    }
                }
                return
            }
            guard parts.count == 5,
                  let id = UUID(uuidString: String(parts[4])) else {
                sendError(404, "artifact not found", on: connection)
                return
            }
            do {
                switch request.method {
                case "GET":
                    let (artifact, data) = try store.artifactData(id: id)
                    sendJSON([
                        "artifact": [
                            "id": artifact.id.uuidString,
                            "title": artifact.title,
                            "mimeType": artifact.mimeType,
                        ],
                        "data": data.base64EncodedString(),
                    ], on: connection)
                case "DELETE":
                    try store.deleteArtifact(id: id)
                    sendJSON(["deleted": true], on: connection)
                default:
                    sendError(405, "method not allowed", on: connection)
                }
            } catch let error as CantripHomeError {
                sendError(error.status, error.message, on: connection)
            } catch {
                Log.write("home: artifact request failed: \(error.localizedDescription)")
                sendError(
                    request.method == "DELETE" ? 500 : 404,
                    request.method == "DELETE"
                        ? "Could not delete the artifact from the Mac."
                        : "Artifact is no longer available on the Mac.",
                    on: connection
                )
            }
        case "builds":
            // Read-only: the Mac's over-the-air install page (~/Sites/ota). Publishing and
            // removal stay on the Mac (ota-publish.py).
            guard request.method == "GET" else {
                sendError(405, "Builds are published on the Mac.", on: connection)
                return
            }
            if parts.count == 4 {
                // The folder scan runs on the encoding queue, off the main actor.
                sendEncoded(on: connection) { try JSONEncoder().encode(CantripHomeOTABuilds.snapshot()) }
                return
            }
            // GET /api/v1/home/builds/<bundle id>/<build folder>/icon
            guard parts.count == 7, parts[6] == "icon" else {
                sendError(404, "build not found", on: connection)
                return
            }
            let id = "\(parts[4])/\(parts[5])"
            guard let data = CantripHomeOTABuilds.iconData(id: id) else {
                sendError(404, "This build has no icon.", on: connection)
                return
            }
            sendJSON(["data": data.base64EncodedString(), "mimeType": "image/png"], on: connection)
        case "background":
            if parts.count == 6, parts[5] == "stop" {
                // POST /api/v1/home/background/<run id>/stop
                guard request.method == "POST" else {
                    sendError(405, "method not allowed", on: connection)
                    return
                }
                guard request.body.count <= 1024, let runID = UUID(uuidString: String(parts[4])) else {
                    sendError(400, "Stopping a background run takes its ID and no body.", on: connection)
                    return
                }
                do {
                    try store.stopBackgroundRun(id: runID)
                    let value = store.backgroundSnapshot()
                    sendEncoded(on: connection) { try JSONEncoder().encode(value) }
                } catch let error as CantripHomeError {
                    sendError(error.status, error.message, on: connection)
                } catch {
                    sendError(500, "Could not stop the background run.", on: connection)
                }
                return
            }
            guard parts.count == 4 else {
                sendError(404, "not found", on: connection)
                return
            }
            guard request.method == "GET" else {
                sendError(405, "method not allowed", on: connection)
                return
            }
            let value = store.backgroundSnapshot()
            sendEncoded(on: connection) { try JSONEncoder().encode(value) }
        default:
            sendError(404, "not found", on: connection)
        }
    }

    /// `/api/v1/sections`: GET lists them; POST {"name"} adds one; `/api/v1/sections/{id}` PATCH
    /// {"name"?, "position"?} renames or reorders it; DELETE removes it (its tabs go back to Tabs).
    @MainActor
    private func handleTabSections(_ request: HTTPRequest, on connection: RemoteRequestConnection) {
        guard let manager else {
            sendError(503, "Cantrip is shutting down.", on: connection)
            return
        }
        let parts = request.path.split(separator: "?")[0].split(separator: "/").dropFirst(3)
        func reply(_ status: Int = 200, extra: [String: Any] = [:]) {
            var body: [String: Any] = ["sections": manager.tabSections.map(\.json)]
            body.merge(extra) { $1 }
            sendJSON(body, status: status, on: connection)
        }
        do {
            if parts.isEmpty {
                switch request.method {
                case "GET":
                    reply()
                case "POST":
                    guard let json = request.json, Set(json.keys) == ["name"], let name = json["name"] as? String else {
                        sendError(400, "Provide the section's name.", on: connection)
                        return
                    }
                    let section = try manager.createSection(named: name)
                    Log.write("remote-control: tab section added")
                    reply(201, extra: ["section": section.json])
                default:
                    sendError(405, "method not allowed", on: connection)
                }
                return
            }
            guard parts.count == 1, let id = UUID(uuidString: String(parts.first!)) else {
                sendError(404, "section not found", on: connection)
                return
            }
            switch request.method {
            case "PATCH":
                guard let json = request.json, !json.isEmpty, Set(json.keys).isSubset(of: ["name", "position"]),
                      json["name"] == nil || json["name"] is String,
                      json["position"] == nil || (json["position"] as? NSNumber).map({
                          CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == $0.doubleValue.rounded()
                      }) == true else {
                    sendError(400, "Provide name (string) and/or position (integer).", on: connection)
                    return
                }
                if let name = json["name"] as? String { try manager.renameSection(id, to: name) }
                if let position = json["position"] as? NSNumber { try manager.moveSection(id, to: position.intValue) }
                reply()
            case "DELETE":
                try manager.deleteSection(id)
                Log.write("remote-control: tab section removed")
                let sessions = manager.sessions.filter { !$0.isPrivate }
                    .map { snapshot($0, includeMessages: false, on: connection) }
                reply(extra: ["sessions": sessions])
            default:
                sendError(405, "method not allowed", on: connection)
            }
        } catch let error as TabSectionError {
            sendError(error.status, error.localizedDescription, on: connection)
        } catch {
            Log.write("remote-control: tab section change failed: \(error.localizedDescription)")
            sendError(500, "Could not save the section on the Mac.", on: connection)
        }
    }

    @MainActor
    private func sendSession(_ session: ChatSession, status: Int = 200,
                             recentExchanges: Int?,
                             afterJournal journalSession: ChatSession? = nil,
                             on connection: RemoteRequestConnection) {
        connection.trace.enter(.journalWait)
        Task {
            do {
                try await (journalSession ?? session).flushJournal()
                guard !session.isPrivate else {
                    sendError(404, "session not found", on: connection)
                    return
                }
                if connection.trace.usesPagedHistory {
                    let summary = snapshot(session, includeMessages: false, on: connection)
                    sendPagedSession(session, summary: summary, end: session.messages.endIndex,
                                     status: status, recentExchanges: recentExchanges, on: connection)
                } else {
                    sendJSON(["session": snapshot(session, on: connection)], status: status, on: connection)
                }
            } catch {
                requestLog("remote-request: id=\(connection.trace.id) outcome=journal_error")
                sendError(500, "The action may have applied, but run history could not be saved. Check the session before retrying.", on: connection)
            }
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let candidate = String(header.dropFirst("Bearer ".count))
        let lhs = Array(candidate.utf8)
        let rhs = Array(token.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    static func inputObject(_ request: InputRequestSnapshot) -> [String: Any] {
        var object: [String: Any] = [
            "id": request.id.uuidString, "kind": request.kind.rawValue,
            "source": request.source, "title": request.title, "detail": request.detail,
            "choices": request.choices, "allowsFreeform": request.allowsFreeform,
            "expiresAt": request.expiresAt
        ]
        if let url = request.url { object["url"] = url }
        if let code = request.code { object["code"] = code }
        if let displayText = request.displayText, let images = request.images, !images.isEmpty {
            object["displayText"] = displayText
            object["images"] = images.map { ["id": $0.id, "altText": $0.altText] }
        }
        return object
    }

    /// Home background runs waiting on the user. Their sessions are never tabs, so the tab list
    /// carries them for clients without a Home view (browser and Mac Remote).
    @MainActor
    static func homeInputs() -> [[String: Any]] {
        guard AppSettings.shared.cantripHomeEnabled else { return [] }
        return CantripHomeStore.shared.runner.runsNeedingInput.map { entry in
            ["runID": entry.run.id.uuidString, "sessionID": entry.session.id.uuidString,
             "label": entry.run.label, "requests": presentedInputs(entry.session).map(inputObject)]
        }
    }

    @MainActor
    private func snapshot(
        _ session: ChatSession,
        includeMessages: Bool = true,
        on connection: RemoteRequestConnection
    ) -> [String: Any] {
        connection.trace.enter(.snapshot)
        defer { connection.trace.enter(.handler) }
        var result: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.title,
            "customTitle": session.tabMetadata.customTitle ?? "",
            "isLocked": session.isLocked,
            "isLocalPrivate": session.isLocalPrivate,
            "isCantripHome": session.isCantripHome,
            "isCantripHomeBackground": session.isCantripHomeBackground,
            "supportsPrivateLocalSettings": session.isLocalPrivate,
            "supportsInputRequests": true,
            "supportsChatInputReplies": true,
            "pendingInputCount": session.pendingInputs.count,
            "supportsTabMetadata": !SessionManager.isCantripHomeReserved(session),
            "supportsTabReordering": !SessionManager.isCantripHomeReserved(session) && manager?.parentID(ofChild: session.id) == nil,
            "supportsTabSections": !SessionManager.isCantripHomeReserved(session) && manager?.parentID(ofChild: session.id) == nil,
            // Child tabs: queued messages can move into child tabs (POST …/queue/{id}/fork), and
            // queue items carry a suggested plan.
            "supportsChildTabs": session.supportsChildTabs,
            "supportsQueuePlans": true,
            "supportsModelSettings": !session.isLocalPrivate && !session.isCantripHomeBackground,
            "modelSettingsRevision": session.modelSettingsRevision,
            "workdir": session.workdir,
            "isStreaming": session.isStreaming,
            "canResume": session.canResume,
            "councilMode": session.councilMode,
            "queuedCount": session.queued.count,
            "supportsImageAttachments": session.supportsRemoteImages,
            "supportsVideoAttachments": session.supportsRemoteImages,
            "supportsFileAttachments": session.supportsRemoteImages,
            // One message may carry images, a video and files together.
            "supportsMixedAttachments": true,
            "supportsAutoDelivery": true,
            "supportsQueueRemoval": true,
            "supportsQueueSendNow": true,
            "supportsPagedHistory": true,
            "supportsStartFresh": session.supportsStartFresh,
            // GET /api/v1/sessions/{id}/commands: the backend's slash commands and skills.
            "supportsBackendCommands": true,
        ]
        if let status = session.statusText { result["status"] = status }
        if let section = manager?.sectionID(of: session) { result["sectionID"] = section.uuidString }
        if let parentID = manager?.parentID(ofChild: session.id), let record = ChildTabStore.shared.record(session.id) {
            result["parentID"] = parentID.uuidString
            var child: [String: Any] = ["state": record.state.rawValue, "title": record.title,
                                        "parentTitle": record.parentTitle, "statusLine": record.statusLine]
            child["branch"] = record.branch
            child["baseBranch"] = record.baseBranch
            child["repoName"] = record.repoName
            result["child"] = child
        }
        if session.supportsChildTabs, let reason = manager?.childTabs.forkUnavailableReason(session) {
            result["childTabsUnavailableReason"] = reason
        }
        if let status = session.deliveryStatus { result["deliveryStatus"] = status }
        if let repeated = session.repeatedErrorMessageID {
            result["repeatedErrorMessageID"] = repeated.uuidString
        }
        if session.isCantripHome {
            // Drives the Background button badge without fetching the run list.
            result["supportsBackgroundRuns"] = true
            result["backgroundActiveCount"] = CantripHomeStore.shared.runner.activeCount
            result["backgroundInputCount"] = CantripHomeStore.shared.runner.runsNeedingInput
                .reduce(0) { $0 + $1.session.pendingInputs.count }
        }
        // Hash only small metadata and mutation tokens, never the full transcript.
        var hasher = SHA256()
        for key in result.keys.sorted() {
            let value = String(describing: result[key]!)
            hasher.update(data: Data("\(key.utf8.count):\(key)\(value.utf8.count):\(value)".utf8))
        }
        hasher.update(data: Data(session.remoteMessageRevision.uuidString.utf8))
        hasher.update(data: Data(session.remoteQueueRevision.uuidString.utf8))
        result["historyRevision"] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // Tab lists (Cantrip Home's drawer, Gateway's sidebar) show each tab's age and latest
        // outcome; kept out of the revision so they never force a transcript reload.
        if !SessionManager.isCantripHomeReserved(session) {
            if let date = session.lastActivityDate { result["lastActivityAt"] = date.timeIntervalSince1970 }
            if !session.isStreaming, let preview = session.tabPreview() { result["preview"] = preview }
        }
        result["pendingInputs"] = Self.presentedInputs(session).map(Self.inputObject)
        if includeMessages {
            result["queued"] = session.queued.map { prompt in
                let presentation = RemoteImageAttachments.presentation(prompt.text, sessionID: session.id)
                var object: [String: Any] = [
                    "id": prompt.id.uuidString,
                    "text": prompt.text,
                ]
                object["plan"] = session.queuePlans[prompt.id]?.snapshot
                if presentation.replacesText {
                    object["displayText"] = presentation.text
                    object["images"] = presentation.imageIDs.map { ["id": $0] }
                }
                return object
            }
            let home = HomeReplyView(session)
            let tags = ThreadTags.tags(in: session.messages, range: session.messages.indices, sessionID: session.id)
            result["messages"] = session.messages.map {
                messageSnapshot($0, sessionID: session.id, home: home, thread: tags[$0.id])
            }
        }
        return result
    }

    /// Text whose image refs a preview ID may name: an assistant reply, or a waiting question.
    @MainActor
    private static func previewSourceText(in session: ChatSession, id: UUID) -> String? {
        if let message = session.messages.first(where: { $0.id == id && $0.role == .assistant }) {
            return message.text
        }
        return session.pendingInputs.first(where: { $0.id == id && $0.kind == .question })?.detail
    }

    /// What Home's off-main message snapshots need from the session: which reply is still
    /// streaming, and the text an in-progress block correction will restore.
    struct HomeReplyView {
        let streamingID: UUID?
        let correction: (messageID: UUID, prefix: String)?

        @MainActor
        init?(_ session: ChatSession) {
            guard SessionManager.isCantripHomeReserved(session) else { return nil }
            streamingID = session.isStreaming
                ? session.messages.last(where: { $0.role == .assistant })?.id : nil
            correction = session.cantripHomeCorrection
        }

        func text(of message: ChatMessage) -> String {
            // A correction reply is written for Cantrip; the user keeps seeing the original.
            if let correction, correction.messageID == message.id { return correction.prefix }
            return CantripHomeProtocol.visibleText(message.text, streaming: message.id == streamingID)
        }
    }

    private func messageSnapshot(_ message: ChatMessage, sessionID: UUID,
                                 home: HomeReplyView? = nil, thread: [String: Any]? = nil) -> [String: Any] {
        var message = message
        if let home, message.role == .assistant { message.text = home.text(of: message) }
        var object = RemoteHistory.message(message)
        object["thread"] = thread
        object["isLocalPrivate"] = sessionID == ChatSession.privateLocalID
        if message.role == .user {
            let presentation = RemoteImageAttachments.presentation(message.text, sessionID: sessionID)
            if presentation.replacesText {
                object["displayText"] = presentation.text
                object["images"] = presentation.imageIDs.map { ["id": $0] }
            }
        } else if message.role == .assistant, sessionID != ChatSession.privateLocalID {
            let presentation = RemoteGeneratedImages.presentation(
                message.text,
                messageID: message.id,
                additionalRoots: generatedImageRoots(sessionID: sessionID)
            )
            if !presentation.images.isEmpty {
                object["displayText"] = presentation.text
                object["images"] = presentation.images.map(\.snapshot)
            }
        }
        return object
    }

    /// Folders this session owns: they preview even inside Cantrip's reserved folders (Home's
    /// artifacts). Images anywhere else on the Mac preview for every session.
    nonisolated static func generatedImageRoots(sessionID: UUID) -> [URL] {
        (SessionManager.isCantripHomeReserved(sessionID) ? [RemoteGeneratedImages.homeArtifactRoot] : [])
            + SessionOutputFolders.shared.roots(for: sessionID)
    }

    private func generatedImageRoots(sessionID: UUID) -> [URL] {
        Self.generatedImageRoots(sessionID: sessionID)
    }

    /// A question's detail previews Mac images like an assistant reply. The request ID stands in
    /// for the message ID, and the answered question's transcript copy keeps that ID.
    nonisolated static func presentedInput(_ request: InputRequestSnapshot, sessionID: UUID,
                                           isLocalPrivate: Bool) -> InputRequestSnapshot {
        guard request.kind == .question, !isLocalPrivate, sessionID != ChatSession.privateLocalID else {
            return request
        }
        let presentation = RemoteGeneratedImages.presentation(
            request.detail, messageID: request.id, additionalRoots: generatedImageRoots(sessionID: sessionID)
        )
        guard !presentation.images.isEmpty else { return request }
        var presented = request
        presented.displayText = presentation.text
        presented.images = presentation.images.map { .init(id: $0.id, altText: $0.altText) }
        return presented
    }

    @MainActor
    static func presentedInputs(_ session: ChatSession) -> [InputRequestSnapshot] {
        session.pendingInputs.map {
            presentedInput($0, sessionID: session.id, isLocalPrivate: session.isLocalPrivate)
        }
    }

    @MainActor
    private func sendPagedSession(_ session: ChatSession, summary: [String: Any], end: Int,
                                  status: Int = 200, recentExchanges: Int? = nil,
                                  on connection: RemoteRequestConnection) {
        let sessionID = session.id
        var exchangeStart: Int?
        if var remaining = recentExchanges {
            for index in session.messages[..<end].indices.reversed() where session.messages[index].role == .user {
                exchangeStart = index
                remaining -= 1
                if remaining == 0 { break }
            }
        }
        var candidateStart = exchangeStart ?? max(0, end - RemoteHistory.pageSize)
        if candidateStart < end, session.messages[candidateStart].role != .user,
           let prompt = session.messages[..<candidateStart].lastIndex(where: { $0.role == .user }) {
            candidateStart = prompt
        }
        let candidates = Array(session.messages[candidateStart..<end])
        let includesCompleteExchanges = exchangeStart != nil
        let historyStartID = session.messages.first?.id.uuidString ?? "empty"
        let queued = session.queued
        let plans = session.queuePlans.mapValues(\.snapshot)
        let home = HomeReplyView(session)
        let tags = ThreadTags.tags(in: session.messages, range: candidateStart..<end, sessionID: sessionID)
        // Full-message sizing and encoding belong off the main actor and tab-list queue.
        sendEncoded(status: status, on: connection, queue: detailEncodingQueue) {
            var result = summary
            var messages: [[String: Any]] = []
            if includesCompleteExchanges {
                messages = candidates.map { self.messageSnapshot($0, sessionID: sessionID, home: home, thread: tags[$0.id]) }
            } else {
                var bytes = 0
                for candidate in candidates.suffix(RemoteHistory.pageSize).reversed() {
                    let message = self.messageSnapshot(candidate, sessionID: sessionID, home: home,
                                                       thread: tags[candidate.id])
                    let size = try JSONSerialization.data(withJSONObject: message).count
                    if !messages.isEmpty, bytes + size > RemoteHistory.pageBytes { break }
                    messages.insert(message, at: 0)
                    bytes += size
                    if bytes >= RemoteHistory.pageBytes { break }
                }
                let start = candidates.count - messages.count
                // Soft limits must not separate a response (including council bubbles) from its prompt.
                if start < candidates.count, candidates[start].role != .user,
                   let prompt = candidates[..<start].lastIndex(where: { $0.role == .user }) {
                    messages = candidates[prompt..<start].map {
                        self.messageSnapshot($0, sessionID: sessionID, home: home, thread: tags[$0.id])
                    } + messages
                }
            }
            result["messages"] = messages
            result["historyStartID"] = historyStartID
            result["hasOlderMessages"] = end > messages.count
            result["queued"] = queued.map { prompt -> [String: Any] in
                let presentation = RemoteImageAttachments.presentation(prompt.text, sessionID: sessionID)
                var object: [String: Any] = [
                    "id": prompt.id.uuidString,
                    "text": prompt.text,
                    "displayText": presentation.text,
                    "images": presentation.imageIDs.map { ["id": $0] },
                ]
                object["plan"] = plans[prompt.id]
                return object
            }
            return try JSONSerialization.data(withJSONObject: ["session": result], options: [.sortedKeys])
        }
    }

    private func serveMemory(_ request: HTTPRequest, directory: URL, enabled: Bool,
                             on connection: RemoteRequestConnection) {
        let memory = RemoteMemory(directory: directory)
        connection.trace.enter(.encodeWait)
        memoryQueue.async {
            connection.trace.enter(.encode)
            do {
                let data: Data
                if request.path == "/api/v1/memory" {
                    data = try JSONEncoder().encode(memory.catalog(
                        enabled: enabled, query: request.query("q") ?? "", after: request.query("after")
                    ))
                } else {
                    guard let id = request.query("id"),
                          let offset = Int(request.query("offset") ?? "0") else {
                        throw RemoteMemoryError(status: 400, message: "Invalid memory file or page.")
                    }
                    data = try JSONEncoder().encode(memory.document(
                        id: id, offset: offset, revision: request.query("revision")
                    ))
                }
                self.send(status: 200, contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch let error as RemoteMemoryError {
                self.sendError(error.status, error.message, on: connection)
            } catch {
                self.requestLog("remote-memory: id=\(connection.trace.id) error=\(error.localizedDescription)")
                self.sendError(500, "Could not read Cantrip memory. Check file access on the Mac.", on: connection)
            }
        }
    }

    /// Read-only and cached for 10 minutes; sources are read on `vocabularyQueue`, and the main
    /// actor only copies tab names, Home tasks and the memory path.
    @MainActor
    private func serveVoiceVocabulary(on connection: RemoteRequestConnection) {
        if let data = voiceVocabulary.cachedData() {
            send(status: 200, contentType: "application/json; charset=utf-8", body: data, on: connection)
            return
        }
        let inputs = VoiceVocabularyService.Inputs.current(manager: manager)
        let vocabulary = voiceVocabulary
        connection.trace.enter(.encodeWait)
        vocabularyQueue.async {
            connection.trace.enter(.encode)
            do {
                let data = try vocabulary.responseData(for: inputs)
                self.send(status: 200, contentType: "application/json; charset=utf-8", body: data, on: connection)
            } catch {
                self.requestLog("remote-voice-vocabulary: id=\(connection.trace.id) outcome=encoding_error")
                self.sendError(500, "Could not prepare the voice vocabulary on the Mac.", on: connection)
            }
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        status: Int = 200,
        on connection: RemoteRequestConnection
    ) {
        // Only the immutable snapshot is captured; encoding large transcripts
        // must not monopolize the main actor or the socket receive queue.
        sendEncoded(status: status, on: connection) {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    private func sendEncoded(status: Int = 200, on connection: RemoteRequestConnection,
                             queue: DispatchQueue? = nil,
                             encode: @escaping () throws -> Data) {
        connection.trace.enter(.encodeWait)
        (queue ?? encodingQueue).async {
            connection.trace.enter(.encode)
            do {
                let data = try encode()
                self.send(
                    status: status,
                    contentType: "application/json; charset=utf-8",
                    body: data,
                    on: connection
                )
            } catch {
                self.requestLog("remote-request: id=\(connection.trace.id) outcome=encoding_error")
                self.send(status: 500, contentType: "application/json; charset=utf-8",
                          body: Data(#"{"error":"response serialization failed"}"#.utf8),
                          on: connection)
            }
        }
    }

    // MARK: - MCP App views

    @MainActor
    private func handleMCPApp(_ request: HTTPRequest, json: [String: Any]?, session: ChatSession,
                              appID: String, action: String?, on connection: RemoteRequestConnection) {
        guard AppSettings.shared.copilotMCPApps else {
            sendError(404, "Interactive MCP App views are turned off on the Mac.", on: connection)
            return
        }
        guard let app = session.messages.lazy.flatMap(\.apps).last(where: { $0.id == appID }) else {
            sendError(404, "This view is no longer in the conversation.", on: connection)
            return
        }
        switch (request.method, action) {
        case ("GET", nil):
            sendEncoded(on: connection) { try JSONEncoder().encode(app) }
        case ("POST", "view"):
            let now = Date()
            mcpAppViewTokens = mcpAppViewTokens.filter { $0.value.expires > now }
            guard mcpAppViewTokens.count < 64 else {
                sendError(409, "Too many views are loading. Try again shortly.", on: connection)
                return
            }
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                sendError(500, "Could not create a view address.", on: connection)
                return
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            mcpAppViewTokens[token] = (session.id, app.id, now.addingTimeInterval(60))
            sendJSON(["url": "/mcp-app/\(token)"], on: connection)
        case ("POST", "request"):
            guard request.body.count <= 256 * 1024, let json, Set(json.keys).isSubset(of: ["method", "params"]),
                  let method = json["method"] as? String,
                  ["tools/call", "tools/list", "resources/read"].contains(method),
                  json["params"] == nil || json["params"] is [String: Any] else {
                sendError(400, "Provide method tools/call, tools/list or resources/read, and params as an object.", on: connection)
                return
            }
            session.mcpAppRequest(app, method: method, params: json["params"] as? [String: Any] ?? [:]) { [weak self] result in
                switch result {
                case .success(let value): self?.sendJSON(["result": value], on: connection)
                case .failure(let error): self?.sendError(502, error.localizedDescription, on: connection)
                }
            }
        case ("POST", "message"):
            guard request.body.count <= 16 * 1024, let json, Set(json.keys) == ["text"],
                  let raw = json["text"] as? String else {
                sendError(400, "Provide the approved message text.", on: connection)
                return
            }
            let text = MCPAppHost.messageText(raw)
            guard !text.isEmpty else {
                sendError(400, "The message is empty.", on: connection)
                return
            }
            session.submitMCPAppMessage(text, from: app)
            sendJSON(["accepted": true, "text": text], on: connection)
        case ("POST", "context"):
            guard request.body.count <= 16 * 1024, let json, Set(json.keys) == ["text"],
                  json["text"] is String || json["text"] is NSNull else {
                sendError(400, "Provide text as a string, or null to clear it.", on: connection)
                return
            }
            let text = (json["text"] as? String).map { String($0.prefix(8_000)) }
            session.setMCPAppContext(app, text: text?.isEmpty == false ? text : nil)
            sendJSON(["accepted": true], on: connection)
        case (_, nil), (_, "view"), (_, "request"), (_, "message"), (_, "context"):
            sendError(405, "method not allowed", on: connection)
        default:
            sendError(404, "not found", on: connection)
        }
    }

    @MainActor
    private func serveMCPAppView(_ token: String, on connection: RemoteRequestConnection) {
        guard token.count == 48, let entry = mcpAppViewTokens.removeValue(forKey: token),
              entry.expires > Date(), AppSettings.shared.copilotMCPApps,
              let session = manager?.managedSession(id: entry.sessionID), !session.isPrivate,
              let app = session.messages.lazy.flatMap(\.apps).last(where: { $0.id == entry.appID }) else {
            sendError(404, "This view address expired. Reload the conversation.", on: connection)
            return
        }
        // The sandbox directive keeps the view on an opaque origin even when
        // opened directly, so it can never read the Remote page's pairing token.
        send(status: 200, contentType: "text/html; charset=utf-8",
             body: Data(MCPAppDocument.viewHTML(app).utf8),
             contentSecurityPolicy: app.csp.policy + "; frame-ancestors 'self'; sandbox allow-scripts allow-forms",
             on: connection)
    }

    private func sendError(_ status: Int, _ message: String, on connection: RemoteRequestConnection) {
        sendJSON(["error": message], status: status, on: connection)
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        contentSecurityPolicy: String = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' https: data:; frame-ancestors 'none'",
        on connection: RemoteRequestConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Content"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }
        let compress = connection.trace.acceptsGzip && body.count >= HTTPCompression.minimumBytes
            && body.count <= HTTPCompression.maximumBytes
            && HTTPCompression.isCompressible(contentType: contentType)
        let respond = {
            var payload = body
            var encoding = ""
            if compress {
                connection.trace.enter(.compress)
                if let gzipped = HTTPCompression.gzip(body), gzipped.count < body.count {
                    payload = gzipped
                    encoding = "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n"
                }
            }
            let header = "HTTP/1.1 \(status) \(reason)\r\n"
                + "Content-Type: \(contentType)\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + encoding
                + "Cache-Control: no-store\r\n"
                + "X-Content-Type-Options: nosniff\r\n"
                + "X-Cantrip-Request-ID: \(connection.trace.id)\r\n"
                + "Content-Security-Policy: \(contentSecurityPolicy)\r\n"
                + "Referrer-Policy: no-referrer\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(payload)
            connection.send(response, status: status, bodyBytes: body.count, wireBytes: payload.count)
        }
        // Never on the caller's queue: the main actor, or the serial JSON queue that also
        // encodes every client's tab-list poll.
        if compress {
            DispatchQueue.global(qos: .userInitiated).async(execute: respond)
        } else {
            respond()
        }
    }
}

private extension RemoteControlServer {
    static let webAppRevision = SHA256.hash(data: Data(webAppTemplate.utf8))
        .map { String(format: "%02x", $0) }.joined()
    static let webApp = webAppTemplate.replacingOccurrences(of: "__CANTRIP_UI_REVISION__", with: webAppRevision)
    static let webAppTemplate = """
    <!doctype html>
    <html lang="en" data-cantrip-connected="false"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="dark light"><title>Cantrip Remote</title>
    <style>
    :root{color-scheme:light dark;--chrome:rgba(240,240,242,.72);--surface:rgba(0,0,0,.045);--surface-2:rgba(0,0,0,.075);--line:rgba(0,0,0,.12);--text:rgba(20,20,24,.92);--secondary:rgba(20,20,24,.62);--tertiary:rgba(20,20,24,.42);--accent:#4169d8;--green:#28a745;--orange:#d97900;--red:#dc3545}
    @media(prefers-color-scheme:dark){:root{--chrome:rgba(44,45,50,.72);--surface:rgba(255,255,255,.045);--surface-2:rgba(255,255,255,.09);--line:rgba(255,255,255,.11);--text:rgba(255,255,255,.92);--secondary:rgba(255,255,255,.62);--tertiary:rgba(255,255,255,.38);--accent:#6b8cff;--green:#35c759;--orange:#ff9f0a;--red:#ff453a}}
    *{box-sizing:border-box}html,body{min-height:100%;background:transparent}body{margin:0;color:var(--text);font:14px -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
    button,select,input,textarea{font:inherit;color:inherit}button{cursor:pointer}.hidden{display:none!important}.grow{flex:1;min-width:0}.muted{color:var(--secondary);font-size:12px}
    #app{min-height:100vh}.workspace{position:sticky;top:0;z-index:4;background:var(--chrome);border-bottom:1px solid var(--line);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}
    .prompt-row{display:flex;align-items:center;gap:10px;padding:14px 16px 2px}.prompt-row input{flex:1;min-width:0;height:28px;padding:0;border:0;outline:0;background:transparent;font-size:20px;font-weight:300;line-height:28px}.prompt-row input::placeholder{color:var(--tertiary)}
    .tools{display:flex;align-items:center;gap:8px;min-height:32px;padding:2px 14px 8px}.tools-spacer{flex:1;min-width:8px}.connection{display:flex;align-items:center;gap:5px;color:var(--tertiary);font-size:11px}.connection-dot{width:6px;height:6px;border-radius:50%;background:var(--tertiary)}[data-cantrip-connected=true] .connection-dot{background:var(--green)}
    .control{min-height:27px;padding:4px 9px;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.control:hover{background:var(--surface-2)}.control.primary{border-color:var(--accent);background:var(--accent);color:white}.control:disabled{opacity:.45;cursor:default}.quiet{border:0;background:transparent;color:var(--secondary);font-size:12px}.quiet:hover{background:var(--surface)}
    .round{display:grid;place-items:center;flex:none;width:27px;height:27px;padding:0;border:0;border-radius:50%;background:var(--surface-2);font-size:17px;font-weight:600;line-height:1}.round:hover{filter:brightness(1.12)}.round.primary{background:var(--accent);color:white}.round.danger{color:var(--red);font-size:12px}
    #sessions{display:flex;gap:5px;min-width:0;overflow-x:auto;scrollbar-width:none}#sessions::-webkit-scrollbar{display:none}.session-tab{display:flex;align-items:center;flex:none;max-width:210px;border-radius:999px;color:var(--secondary)}.session-tab:hover{background:var(--surface);color:var(--text)}.session-tab.active{background:var(--surface-2);color:var(--text)}.session-select{min-width:0;max-width:180px;padding:4px 4px 4px 9px;border:0;background:transparent;color:inherit;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.session-close{display:grid;place-items:center;flex:none;width:22px;height:22px;padding:0 3px 1px 0;border:0;border-radius:50%;background:transparent;color:var(--tertiary);font-size:15px;line-height:1;opacity:.45}.session-tab:hover .session-close,.session-tab.active .session-close,.session-close:focus-visible{opacity:1}.session-close:hover{color:var(--red)}
    select{height:27px;max-width:90px;padding:0 5px;border:0;border-radius:6px;outline:0;background:transparent;color:var(--secondary);font-size:12px}select:hover,select:focus{background:var(--surface)}
    #messages{width:100%;min-height:calc(100vh - 88px);margin:0;padding:16px;display:flex;flex-direction:column;gap:12px}
    .message{width:100%;overflow-wrap:anywhere}.message.user{color:var(--secondary);font-size:13px;font-weight:600;line-height:1.4}.message.assistant{color:var(--text);line-height:1.5}.message.error{color:var(--orange);padding-left:21px;position:relative}.message.handoff{color:var(--text);line-height:1.45}.message.error:before{content:"!";position:absolute;left:3px;font-weight:800}.author{display:block;margin-bottom:5px;color:var(--tertiary);font-size:11px;font-weight:600}
    .mcp-app{margin:0;width:100%;display:flex;flex-direction:column;gap:5px}.mcp-app figcaption{color:var(--tertiary);font-size:11px;font-weight:600}.mcp-app iframe{display:block;width:100%;border:0;border-radius:10px;background:transparent}.mcp-app-status{color:var(--secondary);font-size:12px}.mcp-app-link{align-self:flex-start;color:var(--accent);font-size:11px}
    .prose p{margin:0 0 8px}.prose p:last-child{margin-bottom:0}.prose h1,.prose h2,.prose h3{margin:12px 0 6px;line-height:1.25}.prose h1:first-child,.prose h2:first-child,.prose h3:first-child{margin-top:0}.prose h1{font-size:17px}.prose h2{font-size:15px}.prose h3{font-size:13.5px}.prose ul,.prose ol{margin:4px 0 8px;padding-left:22px}.prose li{margin:3px 0}.prose blockquote{margin:7px 0;padding-left:10px;border-left:3px solid rgba(107,140,255,.55);color:var(--secondary)}.prose a{color:var(--accent);text-decoration:none}.prose a:hover{text-decoration:underline}.prose code{padding:1px 4px;border-radius:4px;background:var(--surface-2);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}.prose pre{margin:8px 0;padding:8px;border:0;border-radius:6px;background:var(--surface-2);overflow:auto}.prose pre code{padding:0;background:transparent;white-space:pre}.prose hr{margin:10px 0;border:0;border-top:1px solid var(--line)}.prose table{display:block;width:max-content;max-width:100%;margin:8px 0;border-collapse:collapse;border-radius:8px;background:var(--surface);overflow-x:auto;font-size:13px}.prose th,.prose td{padding:6px 10px;border:0;text-align:left;vertical-align:top}.prose th{font-weight:600;border-bottom:1px solid var(--line)}.prose img{display:block;max-width:min(100%,440px);max-height:280px;margin:8px 0;border-radius:8px;object-fit:contain}
    .mac-image{display:block;max-width:min(100%,600px);margin:8px 0;padding:0;border:1px solid var(--line);border-radius:8px;background:var(--surface);overflow:hidden;color:var(--secondary);text-align:left;cursor:zoom-in}.mac-image:focus-visible{outline:2px solid var(--accent);outline-offset:2px}.mac-image.failed{cursor:pointer}.preview-link{display:inline;margin:0;padding:0;border:0;border-radius:0;background:none;color:var(--accent);font:inherit;text-align:inherit;cursor:zoom-in}.preview-link:hover{text-decoration:underline}.preview-link:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    .mac-image img,.prose .mac-image img{display:block;max-width:100%;max-height:360px;margin:0;border-radius:0;object-fit:contain}.mac-image-status{display:grid;place-items:center;width:min(100vw - 48px,360px);min-height:160px;padding:12px;font-size:12px;line-height:1.4}.mac-image.failed .mac-image-status{min-height:88px;place-items:center start}
    .mac-image-grid{display:flex;flex-wrap:wrap;gap:8px;margin-top:7px}.mac-image.attachment{width:88px;height:88px;margin:0}.mac-image.attachment img{width:100%;height:100%;max-height:none;object-fit:cover}.mac-image.attachment .mac-image-status{width:100%;height:100%;min-height:0;padding:4px;text-align:center;place-items:center}.image-unavailable{color:var(--secondary);font-style:italic}
    #imageViewer{position:fixed;inset:0;width:auto;height:auto;max-width:none;max-height:none;margin:0;padding:0;border:0;background:#000;color:#fff}#imageViewer[open]{display:grid;grid-template-columns:minmax(0,1fr);grid-template-rows:auto minmax(0,1fr)}#imageViewer::backdrop{background:#000}
    .viewer-bar{display:flex;align-items:center;gap:8px;padding:8px 12px;background:#161618;border-bottom:1px solid rgba(255,255,255,.14)}.viewer-bar strong{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.viewer-bar .control{flex:none;min-height:44px;padding:4px 14px;white-space:nowrap;border-color:rgba(255,255,255,.28);background:rgba(255,255,255,.1);color:#fff}.viewer-bar .control:hover{background:rgba(255,255,255,.18)}
    #imageStage{display:flex;overflow:auto;overscroll-behavior:contain}#imageFull{display:block;margin:auto;max-width:100%;max-height:100%;object-fit:contain;cursor:zoom-in}#imageViewer.zoomed #imageFull{max-width:none;max-height:none;cursor:zoom-out}#imageStatus{margin:auto;padding:16px;text-align:center;line-height:1.45}#imageStatus:empty{display:none}
    details{min-width:0}summary{list-style:none;cursor:pointer}summary::-webkit-details-marker{display:none}.disclosure{margin-top:7px;color:var(--secondary)}.disclosure>summary{display:flex;align-items:center;gap:7px;width:max-content;max-width:100%;font-size:12px}.disclosure>summary:before{content:"›";width:12px;color:var(--tertiary);font-size:17px;line-height:12px;transition:transform .12s}.disclosure[open]>summary:before{transform:rotate(90deg)}.disclosure-body{margin:7px 0 2px 18px;padding-left:10px;border-left:2px solid rgba(107,140,255,.22)}
    .subagents{display:grid;gap:6px;margin:8px 0}
    .fresh-start{display:flex;align-items:center;gap:10px;margin:2px 0;color:var(--secondary);font-size:12px;text-align:center;overflow-wrap:anywhere}.fresh-start:before,.fresh-start:after{content:"";flex:1 1 24px;border-top:1px solid var(--line)}
    .error-actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:6px}.message.error .muted{margin:6px 0 0;color:var(--secondary)}
    .handoffs{display:grid;gap:6px;margin:8px 0}
    .handoff-card{padding:9px 11px 4px;border:1px solid var(--line);border-radius:10px;background:var(--surface);font-size:13px}
    .handoff-card.result{border-left:3px solid var(--tertiary)}.handoff-card.result.completed{border-left-color:var(--green)}.handoff-card.result.needsInput{border-left-color:var(--orange)}.handoff-card.result.failed{border-left-color:var(--red)}
    .handoff-head{display:flex;align-items:flex-start;gap:7px}
    .handoff-icon{flex:none;width:16px;text-align:center;font-weight:800;color:var(--secondary)}
    .handoff-icon.completed{color:var(--green)}.handoff-icon.needsInput{color:var(--orange)}.handoff-icon.failed{color:var(--red)}.handoff-icon.running{color:var(--accent);animation:pulse 1.1s ease-in-out infinite}
    .handoff-title{display:flex;flex:1;flex-wrap:wrap;align-items:center;gap:3px 6px;min-width:0}
    .handoff-title strong{color:var(--secondary);font-size:12px}.handoff-card.needsInput .handoff-title strong{color:var(--text)}
    .handoff-tab{padding:0 6px;border-radius:999px;background:var(--surface-2);color:var(--secondary);font-size:11px;font-weight:600;overflow-wrap:anywhere}
    .handoff-summary{margin:3px 0 0 23px;font-weight:600;overflow-wrap:anywhere}
    .handoff-detail{margin:4px 0 0 23px;white-space:pre-wrap;overflow-wrap:anywhere}
    .handoff-foot{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:0 8px;margin:2px 0 0 23px;color:var(--secondary);font-size:12px;font-variant-numeric:tabular-nums}
    .handoff-open{min-height:36px;color:var(--accent);font-weight:600}
    :root{--child-ok:#1d7a33;--child-work:#9e5700;--child-bad:#c42b39;--child-lane:#06708f}@media(prefers-color-scheme:dark){:root{--child-ok:#35c759;--child-work:#ff9f0a;--child-bad:#ff6961;--child-lane:#64d2ff}}
    .remote-sidebar .session-tab.child-tab{position:relative;width:calc(100% - 14px);min-height:34px;margin-left:14px}.remote-sidebar .session-tab.child-tab:before{content:"";position:absolute;left:-8px;top:-3px;bottom:-3px;width:2px;border-radius:1px;background:var(--line)}.remote-sidebar .session-tab.child-tab .session-name{font-size:12.5px}
    html:not(.remote-sidebar) .session-tab.child-tab .session-select:before{content:"↳ ";content:"↳ "/"";color:var(--secondary)}
    .branch-glyph{flex:none;width:13px;height:13px;fill:none;stroke:currentColor;stroke-width:1.5;stroke-linecap:round}
    .child-card{display:grid;gap:7px;justify-items:start}.child-card>*{max-width:100%}
    .child-thread>summary{display:flex;flex-wrap:wrap;align-items:center;gap:6px;border-radius:999px}.child-thread>summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    .child-lane,.child-tag{display:inline-flex;align-items:center;gap:5px;min-width:0;max-width:100%;padding:3px 9px;border-radius:999px;font-size:12px;font-weight:600}
    .child-lane{color:var(--child-lane);background:color-mix(in srgb,var(--child-lane) 13%,transparent)}.child-tag{color:var(--secondary);background:var(--surface-2)}.child-tag>span{min-width:0;max-width:52ch;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .child-tag:before{content:"↩";content:"↩"/""}.child-tag:after{content:"⌄";content:"⌄"/"";transition:transform .12s}.child-thread[open] .child-tag:after{transform:rotate(180deg)}
    .child-thread-body{display:grid;gap:8px;margin:8px 0 2px 4px;padding-left:12px;border-left:2px solid var(--line)}.thread-tag{margin-bottom:6px}.thread-tag>summary{width:fit-content;max-width:100%;min-height:24px}.thread-reply{display:grid;justify-items:start;gap:2px;max-width:86%}.thread-reply .child-who{padding-left:11px}.thread-bubble{padding:6px 11px;border-radius:14px;background:var(--surface-2)}
    .child-prompt{justify-self:end;max-width:86%;margin:0;padding:6px 11px;border-radius:14px;background:#3a5fcd;color:#fff;font-size:13px;line-height:1.4;white-space:pre-wrap;overflow-wrap:anywhere}
    .child-reply p{margin:0;line-height:1.45;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}.child-who{display:block;color:var(--secondary);font-size:11px;font-weight:600}
    .child-files{margin:0;color:var(--secondary);font-size:12px;line-height:1.7;font-variant-numeric:tabular-nums}.child-files code{padding:0 4px;border-radius:4px;background:var(--surface-2);font-size:11.5px}
    .child-summary{margin:0;line-height:1.5}.child-note{margin:0;color:var(--secondary);font-size:12.5px}
    .child-meta{display:flex;flex-wrap:wrap;align-items:center;gap:6px}
    .child-chip{display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:999px;background:var(--surface-2);color:var(--secondary);font-size:12px;font-weight:600;font-variant-numeric:tabular-nums}
    .child-chip.ok{color:var(--child-ok);background:color-mix(in srgb,var(--child-ok) 13%,transparent)}.child-chip.work{color:var(--child-work);background:color-mix(in srgb,var(--child-work) 13%,transparent)}.child-chip.bad{color:var(--child-bad);background:color-mix(in srgb,var(--child-bad) 12%,transparent)}
    .child-pulse{animation:pulse 1.1s ease-in-out infinite}@media(prefers-reduced-motion:reduce){.child-pulse{animation:none}}
    .child-link{min-height:32px;color:var(--accent);font-weight:600}.child-action{min-height:32px}
    .child-question{display:grid;gap:8px;width:min(100%,640px);padding:12px 13px;border:1px solid var(--line);border-radius:12px;background:var(--surface)}.child-question h4{margin:0;font-size:14px}.child-question>p{margin:0;line-height:1.45}
    .child-excerpt{margin:0;padding:8px 10px;border-radius:8px;background:var(--surface-2);font:11.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre;overflow-x:auto}.child-excerpt:focus-visible{outline:2px solid var(--accent)}.child-excerpt .ours{color:var(--child-ok)}.child-excerpt .theirs{color:var(--child-lane)}.child-excerpt .ctx{color:var(--secondary)}
    .child-options{display:grid;gap:6px}.child-options .control{min-height:36px}
    .child-banner{display:flex;flex-wrap:wrap;align-items:center;gap:6px 9px;padding:7px 11px;border:1px solid var(--line);border-radius:10px;background:var(--surface);color:var(--secondary);font-size:12.5px}.child-banner .branch-glyph{color:var(--child-lane)}
    .queue-list{display:grid;grid-template-columns:minmax(0,1fr);gap:6px;padding-top:10px;border-top:1px solid var(--line)}.queue-list h3{margin:0;color:var(--secondary);font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase}.queue-note{margin:0;color:var(--secondary);font-size:12px}
    .queue-row{display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;font-size:13px}.queue-text{flex:1 1 220px;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
    .plan-chip{flex:none;max-width:100%;padding:2px 8px;border-radius:999px;background:var(--surface-2);color:var(--secondary);font-size:11.5px;font-weight:600;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.plan-chip.fork{color:var(--child-lane);background:color-mix(in srgb,var(--child-lane) 13%,transparent)}
    .queue-action{min-height:32px;color:var(--accent);font-weight:600}
    .session-tab.home-tab .session-select{font-weight:650}
    .session-close[hidden]{display:none}.live-subagents{position:sticky;bottom:0;z-index:3;display:grid;gap:6px;max-height:45vh;overflow-y:auto;padding:8px 16px;background:var(--chrome);border-top:1px solid var(--line);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}.subagent{padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--surface);font-size:12px}.subagent.active{border-left:3px solid var(--accent)}.subagent-head{display:flex;align-items:flex-start;gap:7px}.subagent-head>.status-icon{flex:none;margin-top:2px}.subagent-title{display:flex;flex:1;flex-wrap:wrap;align-items:center;gap:3px 6px;min-width:0}.subagent-title strong{font-size:13px;overflow-wrap:anywhere}.subagent-badge{padding:0 5px;border-radius:4px;background:var(--surface-2);color:var(--secondary);font-size:10px}.subagent-stop{flex:none;min-height:32px;min-width:52px}.subagent-body{display:grid;gap:3px;margin:4px 0 0 21px;color:var(--secondary)}.subagent-now{color:var(--text);overflow-wrap:anywhere}.subagent-meta{font-variant-numeric:tabular-nums}.subagent-error{color:var(--red);font-weight:600;overflow-wrap:anywhere}.subagent-latest{margin:0 0 6px;color:var(--secondary);white-space:pre-wrap;overflow-wrap:anywhere}.subagent-step{display:flex;align-items:center;gap:7px;padding:2px 0;min-width:0}.subagent .disclosure{margin-top:3px}.status-icon.idle{color:var(--secondary)}
    .steps{margin-top:8px}.status-icon{display:inline-grid;place-items:center;width:14px;height:14px;border-radius:50%;font-size:10px;font-weight:800;color:var(--tertiary)}.status-icon.succeeded{color:var(--green)}.status-icon.failed{color:var(--red)}.status-icon.cancelled{color:var(--secondary)}.status-icon.running{color:var(--accent);animation:pulse 1.1s ease-in-out infinite}@keyframes pulse{50%{opacity:.35}}
    .step{margin:5px 0;border:1px solid var(--line);border-radius:7px;background:var(--surface)}.step>summary,.step-static{display:flex;align-items:center;gap:7px;padding:7px 9px;font-size:12px}.step>summary:after{content:"›";margin-left:auto;color:var(--tertiary);font-size:16px;transition:transform .12s}.step[open]>summary:after{transform:rotate(90deg)}.step-title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tool-name{margin-left:auto;color:var(--tertiary);font:10px ui-monospace,SFMono-Regular,Menlo,monospace}.step>summary .tool-name{margin-left:8px}.step-details{display:grid;gap:8px;padding:0 9px 9px 30px}.detail-label{margin-bottom:4px;color:var(--secondary);font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.04em}.step-details pre{max-height:180px;margin:0;padding:8px;border-radius:5px;background:var(--surface);overflow:auto;white-space:pre-wrap;word-break:break-word;color:var(--secondary);font:11px ui-monospace,SFMono-Regular,Menlo,monospace}
    .run-status{display:flex;align-items:center;gap:7px;color:var(--secondary);font-size:13px}.home-inputs{margin:8px 12px;padding:10px 12px;border:1px solid var(--accent);border-radius:10px;background:var(--surface);max-height:45vh;overflow:auto}.home-inputs h2{margin:0;font-size:14px}.home-inputs .input-card{margin:8px 0;gap:8px}.home-inputs pre{max-height:9em;overflow:auto;white-space:pre-wrap;margin:0}.home-inputs input{min-height:36px}.home-inputs .control{min-height:36px;padding:4px 14px}.home-input-status:empty{display:none}
    .older-history{display:flex;align-items:center;justify-content:center;gap:8px;min-height:28px;margin:0 0 8px;color:var(--secondary);font-size:13px}.older-history .spinner{visibility:hidden}.older-history[data-state=loading] .spinner{visibility:visible}.older-history.has-retry{justify-content:space-between}.older-history.has-retry .control{min-height:36px;padding:4px 14px}.sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
    .spinner{width:12px;height:12px;border:1.5px solid rgba(255,255,255,.2);border-top-color:var(--secondary);border-radius:50%;animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.empty{margin:auto;color:var(--tertiary)}
    #pair{width:min(calc(100% - 32px),430px);margin:18vh auto 0;padding:22px;border:1px solid var(--line);border-radius:14px;background:var(--surface);box-shadow:0 18px 50px rgba(0,0,0,.2)}#pair h2{margin:0 0 7px;font-size:18px}#pair p{line-height:1.45}#pairControls{display:flex;gap:7px;margin-top:15px}#pair input{min-width:0;padding:9px 10px;border:1px solid var(--line);border-radius:8px;outline:0;background:var(--surface)}#pair input:focus{border-color:var(--accent)}
    #tabEditor{width:min(calc(100% - 32px),380px);padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}#tabEditor::backdrop{background:rgba(0,0,0,.35)}#tabEditor form{display:grid;gap:12px}#tabName{width:100%;padding:8px;background:var(--surface);border:1px solid var(--line);border-radius:7px}.tab-actions{display:flex;justify-content:flex-end;gap:8px}#tabError,#actionError{color:var(--orange);font-size:12px}#actionError:not(:empty){padding:8px 14px}.session-close:disabled{opacity:.65;cursor:default}.session-menu{border:0;background:transparent;color:var(--secondary);padding:2px 5px}
    .section-header{display:flex;align-items:center;flex:none;border-radius:999px;color:var(--secondary)}.section-header.drop-target{outline:2px solid var(--accent)}.section-header[draggable=true]{cursor:grab}.section-header.dragging{opacity:.5}.section-toggle{display:flex;align-items:center;gap:5px;min-width:0;max-width:170px;padding:4px 4px 4px 9px;border:0;background:transparent;color:inherit;font-size:12px;font-weight:600;white-space:nowrap}.section-toggle .section-name{overflow:hidden;text-overflow:ellipsis}.section-toggle .section-count{color:var(--tertiary);font-weight:400}.section-header:hover{background:var(--surface);color:var(--text)}.section-menu{border:0;background:transparent;color:var(--tertiary);padding:2px 7px 2px 3px;opacity:.6}.section-header:hover .section-menu,.section-menu:focus-visible{opacity:1}
    .remote-sidebar .section-header{width:100%;min-height:30px;margin-top:6px;border-radius:7px}.remote-sidebar .section-toggle{flex:1;max-width:none;text-transform:uppercase;letter-spacing:.04em;font-size:11px}
    #sectionEditor{width:min(calc(100% - 32px),380px);padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}#sectionEditor::backdrop{background:rgba(0,0,0,.35)}#sectionEditor form{display:grid;gap:12px}#sectionName,#tabNewSection{width:100%;padding:8px;background:var(--surface);border:1px solid var(--line);border-radius:7px}#sectionActions{flex-wrap:wrap;justify-content:flex-start}#sectionError{color:var(--orange);font-size:12px}#tabSection{max-width:none;width:100%;height:32px;border:1px solid var(--line);background:var(--surface);color:var(--text)}
    .prompt-usage{margin-top:4px}.prompt-usage>summary{font-size:11px}.usage-table{margin:6px 0 2px 19px;max-width:340px;color:var(--text)}.usage-title{margin-top:6px;color:var(--secondary);font-size:11px;font-weight:600}.usage-table dl{display:grid;grid-template-columns:1fr auto;gap:2px 12px;margin:3px 0;font-size:12px}.usage-table dd{margin:0;text-align:right;font-variant-numeric:tabular-nums}.prompt-preview{white-space:pre-wrap}.prompt-preview.clipped{max-height:11.2em;overflow:hidden}#promptReader{width:min(calc(100% - 24px),680px);border:1px solid var(--line);border-radius:12px;background:Canvas;color:var(--text)}#promptReader::backdrop{background:rgba(0,0,0,.35)}#promptPage{height:55vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}
    @media(max-width:620px){.prompt-row{padding-inline:12px}.tools{padding-inline:10px}.connection-label{display:none}.session-tab{max-width:145px}.session-select{max-width:115px}#messages{padding:14px 12px 22px}.live-subagents{padding:8px 12px}}
    .remote-sidebar{--sidebar-width:clamp(136px,30vw,240px)}.remote-sidebar #app{padding-left:var(--sidebar-width)}
    #sessionSidebar{position:fixed;inset:0 auto 0 0;z-index:5;display:flex;flex-direction:column;width:var(--sidebar-width);background:var(--chrome);border-right:1px solid var(--line)}
    #sessionSidebarHeader{display:flex;align-items:center;justify-content:space-between;gap:8px;flex:none;padding:12px;font-size:13px}#sessionSidebarHeader #newSection{margin-left:auto}#newSection svg{display:block}
    .remote-sidebar #sessions{flex:1;min-height:0;flex-direction:column;gap:4px;padding:0 8px 8px;overflow-x:hidden;overflow-y:auto;overscroll-behavior-y:contain;scrollbar-width:thin}
    .remote-sidebar #sessions::-webkit-scrollbar{display:initial;width:6px}.remote-sidebar #sessions::-webkit-scrollbar-thumb{background:var(--line);border-radius:3px}
    .remote-sidebar .session-tab{width:100%;max-width:none;min-height:40px;border-radius:8px}.remote-sidebar .session-tab.active{background:var(--surface-2);box-shadow:inset 3px 0 var(--accent)}
    .remote-sidebar .session-select{flex:1;max-width:none;padding:9px 6px 9px 9px;text-align:left;white-space:normal;overflow-wrap:anywhere;line-height:1.35}
    .remote-sidebar .session-close{opacity:1}.remote-sidebar .session-menu{flex:none}.remote-sidebar .tools,.remote-sidebar .prompt-row{flex-wrap:wrap}.remote-sidebar .prompt-row input{flex:1 1 80px}
    .session-name{font-weight:600}.session-status{display:block;margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--secondary);font-size:11px;font-weight:400}
    .brain-indicator{display:inline-block;flex:none;width:16px;height:16px;margin-right:4px;vertical-align:-3px;color:var(--tertiary);visibility:hidden}
    [data-streaming=true] .brain-indicator{visibility:visible;color:var(--accent);animation:pulse 1.1s ease-in-out infinite}
    #sessionProgress{min-width:0;padding:0 14px 9px;font-size:12px}#sessionProgress .brain-indicator{margin:0}#sessionProgressText{display:-webkit-box;min-width:0;overflow:hidden;overflow-wrap:anywhere;-webkit-line-clamp:2;-webkit-box-orient:vertical;line-height:1.35}
    [data-cantrip-connected=false] .brain-indicator,[data-cantrip-connected=false].remote-sidebar .status-icon.running{animation:none;color:var(--tertiary)}
    @media(prefers-reduced-motion:reduce){.brain-indicator,.spinner,.status-icon.running{animation:none}}
    .session-tab[draggable=true]{cursor:grab}.session-tab.drop-target{outline:2px solid var(--accent);outline-offset:-2px}
    #modelEditor{width:min(calc(100% - 24px),480px);max-height:90vh;overflow:auto;padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}
    #modelEditor::backdrop{background:rgba(0,0,0,.35)}#modelForm{display:grid;gap:14px}#modelForm label{display:grid;gap:6px}
    #modelForm select{width:100%;max-width:none;min-height:44px;border:1px solid var(--line);font-size:14px;color:var(--text)}
    #modelEditor button{min-height:44px}#modelForm select:focus-visible,#modelEditor button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    #modelError{color:var(--text);font-size:13px}#modelForm .tab-actions{flex-wrap:wrap}#modelForm input{width:24px;height:24px}
    #privateEditor{width:min(calc(100% - 24px),480px);max-height:90vh;overflow:auto;padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}
    #privateEditor::backdrop{background:rgba(0,0,0,.35)}#privateForm{display:grid;gap:14px}#privateForm label{display:grid;gap:6px}
    #privateForm input,#privateForm select,#privateForm textarea{box-sizing:border-box;width:100%;max-width:none;min-height:44px;background:Canvas;color:var(--text);border:1px solid var(--line);padding:8px;font:inherit}
    #privateForm .tab-actions{flex-wrap:wrap}#privateForm button{min-height:44px}#privateForm :focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    #inputEditor{width:min(calc(100% - 24px),580px);max-height:90vh;overflow:auto;padding:20px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}
    #inputEditor::backdrop{background:rgba(0,0,0,.35)}.input-card{display:grid;gap:12px;margin:16px 0;padding:12px;border:1px solid var(--line);border-radius:10px}
    #desktopEditor{width:min(calc(100% - 24px),1000px);max-height:92vh;overflow:auto;padding:18px;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}
    #desktopEditor::backdrop{background:rgba(0,0,0,.35)}#desktopEditor .tab-actions{flex-wrap:wrap}#desktopEditor button,#desktopEditor select{min-height:44px}
    #desktopViewport{height:380px;overflow:auto;border:1px solid var(--line)}#desktopImage{display:block;max-width:none;height:auto;width:100%}
    #desktopText{width:100%;box-sizing:border-box;min-height:44px}#desktopPermissions>div{margin:12px 0}
    .input-card input,.input-card textarea,.input-card select{box-sizing:border-box;width:100%;max-width:none;min-height:44px;background:Canvas;color:var(--text);border:1px solid var(--line);padding:8px;font:inherit}
    .input-card .tab-actions{flex-wrap:wrap}.input-card pre{max-height:240px;overflow:auto;white-space:pre-wrap}
    .input-detail{max-height:240px;overflow:auto;min-width:0}.input-detail .prose>:first-child{margin-top:0}.input-detail .prose>:last-child{margin-bottom:0}
    .input-images{display:flex;gap:8px;overflow-x:auto;padding-bottom:2px}.input-image{display:flex;flex:none;flex-direction:column;align-items:flex-start;gap:4px;width:min-content;min-width:96px;margin:0}
    .input-image figcaption{font-size:12px;line-height:1.3;color:var(--secondary);overflow-wrap:anywhere}.input-images .mac-image{flex:none;margin:0;max-width:none}
    .input-images .mac-image img{height:120px;width:auto;max-width:200px;max-height:none}.input-images .mac-image-status{width:96px;min-height:120px;padding:6px;text-align:center}
    #tasksPanel{width:min(calc(100% - 24px),720px);max-height:90vh;overflow:auto;padding:0;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}
    #tasksPanel::backdrop{background:rgba(0,0,0,.35)}.tasks-bar{position:sticky;top:0;z-index:1;display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--line);background:Canvas}
    #tasksPanel .control{min-height:44px;padding:4px 14px}#tasksPanel button:focus-visible,#tasksPanel summary:focus-visible,#tasksSearch:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
    #artifactsPanel{width:min(calc(100% - 24px),860px);max-height:90vh;overflow:auto;padding:0;border:1px solid var(--line);border-radius:14px;background:Canvas;color:var(--text)}#artifactsPanel::backdrop{background:rgba(0,0,0,.35)}
    #artifactsPanel .control{min-height:44px;padding:4px 14px}#artifactsPanel button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}#artifactsTitle{font-size:16px}#artifactsTitle:focus{outline:0}
    #artifactsError:not(:empty){margin:10px 14px 0;color:var(--red);font-size:13px}#artifactsBody{padding:10px 14px 16px}.artifact-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px;margin:0;padding:0;list-style:none}.artifact-grid li{position:relative}
    .artifact-card{display:grid;gap:6px;box-sizing:border-box;width:100%;height:100%;align-content:start;padding:8px;border:1px solid var(--line);border-radius:12px;background:var(--surface);color:inherit;font:inherit;text-align:left;cursor:pointer}.artifact-card:hover{background:var(--surface-2)}.artifact-card[aria-busy="true"]{opacity:.6}
    .artifact-thumb{display:grid;place-items:center;aspect-ratio:4/3;overflow:hidden;border-radius:8px;background:var(--surface-2);color:var(--secondary);font-size:13px;font-weight:650;letter-spacing:.04em}.artifact-thumb img{width:100%;height:100%;object-fit:cover}
    .artifact-title{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-size:14px;font-weight:600;overflow-wrap:anywhere}.artifact-meta{display:flex;justify-content:space-between;gap:6px;color:var(--secondary);font-size:12px}
    .artifact-delete{position:absolute;top:14px;right:14px;display:grid;place-items:center;width:36px;height:36px;padding:0;border:0;border-radius:18px;background:rgba(0,0,0,.6);color:#fff;opacity:.85}.artifact-delete:hover,.artifact-delete:focus-visible{background:rgba(0,0,0,.82);opacity:1}.artifact-delete svg{width:18px;height:18px}
    #tasksTitle{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:16px}#tasksTitle:focus{outline:0}
    #tasksError:not(:empty){margin:10px 14px 0;color:var(--red);font-size:13px}#tasksSearch{display:block;box-sizing:border-box;width:calc(100% - 28px);min-height:40px;margin:12px 14px 0;padding:6px 10px;border:1px solid var(--line);border-radius:9px;background:var(--surface);color:var(--text);font:inherit}
    #tasksBody{padding:10px 14px 16px}.tasks-empty{padding:18px 2px;font-size:14px}.task-list,.record-list,.run-list{display:grid;gap:8px;margin:0;padding:0;list-style:none}
    .task-card{display:grid;gap:4px;box-sizing:border-box;width:100%;min-height:44px;padding:11px 12px;border:1px solid var(--line);border-radius:11px;background:var(--surface);color:inherit;font:inherit;text-align:left}.task-card:hover{background:var(--surface-2)}
    .task-title{font-size:15px;overflow-wrap:anywhere}.task-meta{color:var(--secondary);font-size:12px}.task-run,.run-summary{color:var(--secondary);font-size:13px;line-height:1.4;white-space:pre-line;overflow-wrap:anywhere}
    .task-run{display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}.run-list li{display:grid;gap:3px;padding:9px 0;border-top:1px solid var(--line)}
    .task-facts,.record-details dl{display:grid;grid-template-columns:minmax(100px,max-content) 1fr;gap:5px 14px;margin:0 0 12px;font-size:13px}.task-facts dt,.record-details dt{color:var(--secondary)}.task-facts dd,.record-details dd{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}
    .task-detail h3,.record-details h3{margin:6px 0 2px;color:var(--tertiary);font-size:11px;font-weight:650;letter-spacing:.04em;text-transform:uppercase}
    .record-group{border-bottom:1px solid var(--line)}.record-group:last-child{border-bottom:0}.record-group>summary{display:flex;align-items:center;gap:8px;min-height:48px;padding:2px}
    .record-group>summary:after{content:"›";margin-left:auto;color:var(--tertiary);font-size:22px;line-height:1;transition:transform .12s}.record-group[open]>summary:after{transform:rotate(90deg)}
    .record-group.searching>summary{cursor:default}.record-group.searching>summary:after{content:none}.record-group>.record-list,.group-empty{margin:0 0 12px}
    .group-title{font-size:16px;font-weight:650}.group-count{min-width:22px;padding:1px 8px;border-radius:999px;background:var(--surface-2);color:var(--secondary);font-size:12px;font-weight:650;text-align:center;font-variant-numeric:tabular-nums}
    .record{border:1px solid var(--line);border-radius:11px;background:var(--surface)}.record>summary{display:grid;gap:3px;min-height:44px;padding:10px 12px}.record>summary:hover{background:var(--surface-2);border-radius:11px}
    .record-head{display:flex;align-items:baseline;gap:8px}.record-title{flex:1;min-width:0;font-weight:650;overflow-wrap:anywhere}
    .record-badge{flex:none;max-width:55%;padding:2px 8px;border-radius:999px;background:var(--surface-2);background:color-mix(in srgb,var(--tone,var(--accent)) 14%,transparent);color:var(--tone,var(--accent));font-size:11px;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .record-badge.rejected{--tone:var(--red)}.record-badge.offer{--tone:var(--green)}.record-badge.applied{--tone:var(--orange)}
    .record-subtitle{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;color:var(--secondary);font-size:13px;overflow-wrap:anywhere}.record-date{color:var(--secondary);font-size:12px}
    .record-details{padding:2px 12px 12px}.record-details a{color:var(--accent);overflow-wrap:anywhere}@media(max-width:480px){.task-facts,.record-details dl{grid-template-columns:1fr;gap:1px}.task-facts dd,.record-details dd{margin-bottom:7px}}
    #uiUpdateStatus:not(:empty){padding:8px 14px}
    .prompt-row{position:relative}.slash-popover{position:absolute;top:calc(100% + 2px);left:10px;right:10px;z-index:6;max-width:720px;max-height:320px;overflow-y:auto;overscroll-behavior:contain;padding:4px;border:1px solid var(--line);border-radius:10px;background:Canvas;color:var(--text);box-shadow:0 12px 32px rgba(0,0,0,.28)}.slash-popover.above{top:auto;bottom:calc(100% + 2px)}@media(prefers-color-scheme:dark){.slash-popover{background:#2a2b30}}
    .slash-row{display:grid;grid-template-columns:fit-content(45%) minmax(0,1fr) auto;grid-template-areas:"cmd desc source" "note note note";align-items:baseline;gap:1px 12px;padding:7px 10px;border-radius:7px;cursor:pointer}.slash-row:hover{background:var(--surface)}.slash-row[aria-selected=true]{background:var(--surface-2);box-shadow:inset 3px 0 var(--accent)}.slash-row[aria-disabled=true]{cursor:default}.slash-row[aria-disabled=true]:hover{background:transparent}.slash-row[aria-disabled=true] .slash-cmd,.slash-row[aria-disabled=true] .slash-desc,.slash-row[aria-disabled=true] .slash-source{opacity:.5}
    .slash-cmd{grid-area:cmd;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font:12.5px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}.slash-name{font-weight:650}.slash-hint{margin-left:6px;color:var(--secondary)}.slash-desc{grid-area:desc;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--secondary);font-size:13px;line-height:1.4}.slash-source{grid-area:source;padding:0 6px;border-radius:4px;background:var(--surface-2);color:var(--secondary);font-size:10px;font-weight:600;line-height:1.6;white-space:nowrap}.slash-note{grid-area:note;color:var(--secondary);font-size:12px;line-height:1.35;overflow-wrap:anywhere}
    .slash-info{display:flex;align-items:center;gap:7px;padding:7px 10px;color:var(--secondary);font-size:12px;line-height:1.35;overflow-wrap:anywhere}#slashList:not(:empty)~.slash-info{border-top:1px solid var(--line)}.slash-info .spinner{flex:none}
    @media(max-width:620px){.slash-popover{left:8px;right:8px}.slash-row{grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"cmd source" "desc desc" "note note";padding:8px 10px}.slash-desc{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;white-space:normal;overflow-wrap:anywhere}}@media(pointer:coarse){.slash-row,.slash-info{min-height:44px}}
    </style></head><body>
    <section id="pair"><h2>Pair Cantrip Remote</h2><p class="muted">Paste the token from Cantrip Settings. It stays in this browser only.</p>
    <div id="pairControls"><input id="token" class="grow" type="password" placeholder="Pairing token" autocomplete="off"><button id="pairButton" class="control primary">Connect</button></div><p id="pairError" class="muted"></p></section>
    <main id="app" class="hidden"><aside id="sessionSidebar" class="hidden" aria-labelledby="sessionSidebarTitle"><div id="sessionSidebarHeader"><strong id="sessionSidebarTitle">Tabs</strong></div></aside><header class="workspace">
    <div class="prompt-row"><input id="draft" type="text" placeholder="How can I help you?" autocomplete="off" role="combobox" aria-autocomplete="list" aria-haspopup="listbox" aria-expanded="false" aria-controls="slashList"><div id="slashPopover" class="slash-popover hidden"><div id="slashList" role="listbox" aria-label="Commands"></div><div id="slashLoading" class="slash-info hidden"><span class="spinner" aria-hidden="true"></span>Loading commands…</div><div id="slashInfo" class="slash-info hidden"></div></div><div id="slashStatus" class="sr-only" role="status" aria-live="polite"></div><button id="resume" class="control quiet hidden">Resume</button><button id="stop" class="round danger hidden" title="Stop" aria-label="Stop">■</button><button id="send" class="round primary" title="Send" aria-label="Send">↑</button></div>
    <div class="tools"><nav id="sessions" aria-label="Remote sessions"></nav><button id="newSection" class="round hidden" title="New section" aria-label="New section"><svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><path d="M1.5 4.5v8a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H8L6.5 3.5h-4a1 1 0 0 0-1 1z"/><path d="M8 7.5v4M6 9.5h4"/></svg></button><button id="newSession" class="round" title="New remote session" aria-label="New remote session">+</button><button id="homeTasks" class="control quiet hidden" aria-haspopup="dialog" title="Cantrip Home tasks">Tasks</button><button id="homeArtifacts" class="control quiet hidden" aria-haspopup="dialog" title="Cantrip Home artifacts">Artifacts</button><span class="tools-spacer"></span>
    <select id="mode" aria-label="Delivery override"><option value="auto">Auto</option><option value="queue">Queue</option><option value="interrupt">Redirect</option><option value="inject">Inject</option></select>
    <span class="connection"><span class="connection-dot"></span><span class="connection-label">Connected</span></span><button id="forget" class="control quiet">Unpair</button></div>
    <div id="sessionProgress" class="run-status hidden" role="status" aria-live="polite" aria-atomic="true"><span id="sessionProgressText"></span></div>
    <section id="homeInputs" class="home-inputs hidden" aria-labelledby="homeInputsTitle"><h2 id="homeInputsTitle" tabindex="-1">Cantrip Home needs your input</h2><div id="homeInputCards"></div></section><div id="homeInputsStatus" class="sr-only" role="status" aria-live="polite"></div></header>
    <div id="uiUpdateStatus" class="muted" role="status" aria-live="polite"></div><div id="actionError" role="alert"></div><button id="inputBanner" class="control hidden">Your input is needed</button><div id="historyError" role="alert"></div><div id="olderHistory" class="older-history hidden" data-state="idle"><span class="spinner" aria-hidden="true"></span><span id="olderHistoryText" role="status" aria-live="polite"></span><button id="olderMessages" class="control hidden" aria-label="Retry loading older messages">Retry</button><button id="olderHistoryReader" class="sr-only" tabindex="-1">Load older messages</button></div><section id="messages"></section><section id="liveSubagents" class="live-subagents hidden" aria-label="Running subagents"></section></main>
    <dialog id="inputEditor" aria-labelledby="inputTitle"><strong id="inputTitle">Secure Input</strong>
    <p class="muted">Only passwords and passphrases belong here. Questions and other actions appear in chat.</p>
    <div id="inputError" role="alert"></div><div id="inputCards"></div>
    <div class="tab-actions"><button id="inputReload" class="control">Reload</button><button id="inputDone" class="control">Done</button></div></dialog>
    <dialog id="tabEditor" aria-labelledby="tabEditorTitle"><form id="tabForm">
    <strong id="tabEditorTitle">Tab settings</strong><label>Tab name<input id="tabName" autocomplete="off"></label>
    <span class="muted">Up to 80 characters. Leave blank for the automatic name.</span>
    <label><input id="tabLocked" type="checkbox"> Lock tab against closing or clearing</label>
    <label id="tabSectionLabel" class="hidden">Section<select id="tabSection"></select></label><input id="tabNewSection" class="hidden" maxlength="40" autocomplete="off" placeholder="New section name" aria-label="New section name">
    <button id="tabModelSettings" type="button" class="control">Model Settings</button><button id="tabStartFresh" type="button" class="control" title="Keep this tab's messages, but don't send them to the model">Start Fresh</button><button id="tabMacAccess" type="button" class="control">Mac Permissions &amp; View Mac</button>
    <div id="tabMoveControls" class="tab-actions hidden"><button id="tabMoveEarlier" type="button" class="control">Move earlier</button><button id="tabMoveLater" type="button" class="control">Move later</button></div>
    <div id="tabError" role="alert"></div><div class="tab-actions"><button id="tabCancel" type="button" class="control">Cancel</button><button id="tabSave" type="submit" class="control primary">Save</button></div>
    </form></dialog>
    <dialog id="sectionEditor" aria-labelledby="sectionEditorTitle"><form id="sectionForm">
    <strong id="sectionEditorTitle">Section</strong><label>Name<input id="sectionName" maxlength="40" autocomplete="off"></label>
    <div id="sectionActions" class="tab-actions"><button id="sectionNewTab" type="button" class="control">New Tab Here</button><button id="sectionUp" type="button" class="control">Move Up</button><button id="sectionDown" type="button" class="control">Move Down</button><button id="sectionDelete" type="button" class="control">Delete Section</button></div>
    <span id="sectionNote" class="muted" role="status" aria-live="polite"></span><div id="sectionError" role="alert"></div>
    <div class="tab-actions"><button id="sectionCancel" type="button" class="control">Cancel</button><button id="sectionSave" type="submit" class="control primary">Save</button></div>
    </form></dialog>
    <dialog id="modelEditor" aria-labelledby="modelTitle"><form id="modelForm">
    <strong id="modelTitle">Model Settings</strong><span id="modelTabTitle"></span>
    <label><input id="modelDefaults" type="checkbox">Use Mac defaults</label>
    <label>Model<select id="modelChoice"></select></label><label>Effort<select id="modelEffort"></select></label>
    <label>Context window<select id="modelContext"></select></label><span id="modelBudget" class="muted"></span>
    <p class="muted">Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.</p>
    <div id="modelError" role="alert"></div><div class="tab-actions">
    <button id="modelReload" type="button" class="control">Reload settings</button><button id="modelRefresh" type="button" class="control">Refresh models</button>
    <button id="modelCancel" type="button" class="control">Cancel</button><button id="modelSave" type="submit" class="control primary">Save</button>
    </div></form></dialog>
    <dialog id="desktopEditor" aria-labelledby="desktopTitle"><strong id="desktopTitle">Mac Permissions &amp; View Mac</strong>
    <p class="muted">Start viewing explicitly. The Mac must first allow paired clients in Cantrip settings. Screen frames and typed text stay out of chat, files and AI models. Protected dialogs may be unavailable. Phone Face ID does not authorize macOS dialogs.</p>
    <div id="desktopError" role="alert"></div><div class="tab-actions">
    <label><input id="desktopControl" type="checkbox">Keyboard and pointer control</label>
    <button id="desktopStart" class="control">Start View Mac</button><button id="desktopEnd" class="control">End View</button>
    <button id="desktopReload" class="control">Refresh permissions</button><button id="desktopDone" class="control">Done</button></div>
    <div id="desktopLive" class="hidden">
    <p class="muted">Five-minute maximum; disconnects expire after 60 seconds. The paired connection carries the viewing key: use a trusted HTTPS endpoint. Frames refresh about once per second.</p>
    <div class="tab-actions"><select id="desktopDisplay" aria-label="Display"></select>
    <select id="desktopZoom" aria-label="Zoom"><option value="1">1x</option><option value="2">2x</option><option value="3">3x</option></select>
    <select id="desktopClick" aria-label="Tap action"><option value="click">Click</option><option value="rightClick">Right click</option><option value="doubleClick">Double click</option></select></div>
    <div id="desktopViewport"><img id="desktopImage" alt="Live Mac screen. Press Enter to click the center when control is enabled." tabindex="0"></div>
    <div id="desktopInput"><label>Type into the focused Mac field<input id="desktopText" type="password" maxlength="4096" autocomplete="off"></label>
    <div class="tab-actions"><button id="desktopSend" class="control">Send Text</button><button id="desktopReturn" class="control">Return</button>
    <button id="desktopTab" class="control">Tab</button><button id="desktopEscape" class="control">Escape</button><button id="desktopDelete" class="control">Delete</button>
    <button id="desktopUp" class="control">Scroll up</button><button id="desktopDown" class="control">Scroll down</button></div></div></div>
    <div id="desktopPermissions"></div></dialog>
    <dialog id="privateEditor" aria-labelledby="privateTitle"><form id="privateForm">
    <strong id="privateTitle">Private Local Settings</strong>
    <p class="muted">Local means self-hosted, not limited to the Cantrip Mac. Your Ollama server may run on another machine. This permanent tab stays saved on the Mac and accessible through paired Remote clients. No cloud fallback, tools, shared memory, push summaries or automatic external content.</p>
    <label>Self-hosted Ollama server URL<input id="privateURL" type="url" required autocomplete="off"></label>
    <label>Installed model<input id="privateModel" required autocomplete="off" list="privateModels"></label><datalist id="privateModels"></datalist>
    <label>Context tokens<input id="privateContext" type="number" min="512" max="131072" step="1" required></label>
    <label>System prompt<textarea id="privatePrompt" maxlength="8000" rows="4"></textarea></label>
    <p class="muted">Use your own server's HTTPS URL, including LAN or Tailscale hostnames and reverse-proxy base paths. HTTP is allowed only on loopback. Install models on that server. Context depends on its model and RAM; saved history is not unlimited model context. Save while idle.</p>
    <div id="privateError" role="alert"></div><div class="tab-actions">
    <button id="privateReload" type="button" class="control">Reload settings</button><button id="privateRefresh" type="button" class="control">Load server models</button>
    <button id="privateCancel" type="button" class="control">Cancel</button><button id="privateSave" type="submit" class="control primary">Save</button>
    </div></form></dialog>
    <dialog id="promptReader" aria-labelledby="promptTitle"><strong id="promptTitle">Full prompt</strong>
    <pre id="promptPage"></pre><div class="tab-actions"><button id="promptPrevious" class="control">Previous</button><span id="promptNumber"></span><button id="promptNext" class="control">Next</button><button id="promptDownload" class="control">Download all</button><button id="promptDone" class="control">Done</button></div></dialog>
    <dialog id="tasksPanel" aria-labelledby="tasksTitle"><div class="tasks-bar"><button id="tasksBack" type="button" class="control hidden" aria-label="Back to tasks">‹ Tasks</button><strong id="tasksTitle" class="grow" tabindex="-1">Tasks</strong><button id="tasksDone" type="button" class="control">Done</button></div>
    <div id="tasksError" role="alert"></div><input id="tasksSearch" class="hidden" type="search" autocomplete="off" aria-label="Search records"><div id="tasksBody"></div><div id="tasksStatus" class="sr-only" role="status" aria-live="polite"></div></dialog>
    <dialog id="artifactsPanel" aria-labelledby="artifactsTitle"><div class="tasks-bar"><strong id="artifactsTitle" class="grow" tabindex="-1">Artifacts</strong><button id="artifactsCreate" type="button" class="control">Create in Chat</button><button id="artifactsDone" type="button" class="control">Done</button></div><div id="artifactsError" role="alert"></div><div id="artifactsBody"></div><div id="artifactsStatus" class="sr-only" role="status" aria-live="polite"></div></dialog>
    <dialog id="imageViewer" aria-labelledby="imageViewerTitle"><div class="viewer-bar"><strong id="imageViewerTitle" class="grow">Preview</strong><button id="imageZoom" type="button" class="control" aria-pressed="false">Actual size</button><button id="imageRetry" type="button" class="control hidden">Retry</button><button id="imageDone" type="button" class="control">Done</button></div>
    <div id="imageStage"><img id="imageFull" alt=""><p id="imageStatus" role="status" aria-live="polite"></p></div></dialog>
    <script>
    const $=id=>document.getElementById(id);let token=localStorage.cantripToken||"",selected=null,timer=null,renderedSession=null,renderedPayload="",followOutput=true,suppressScroll=false;const expanded=new Set();
    const uiRevision="__CANTRIP_UI_REVISION__",uiReloadStorageKey="cantrip.uiReload.v1";
    let pendingUIRevision=null,blockedUIRevision=null,uiReloadTimer=null,uiNavigationTimer=null,uiReloading=false,uiNavigating=false,uiRestoreFailed=false,uiActiveWrites=0,uiLastInteraction=0,uiComposing=false,uiMutationWarning="";
    function scheduleUIReload(){if(uiReloadTimer)clearTimeout(uiReloadTimer);uiReloadTimer=null;
      if(pendingUIRevision&&pendingUIRevision!==blockedUIRevision&&!uiReloading&&!uiRestoreFailed&&!document.hidden)uiReloadTimer=setTimeout(reloadUpdatedUI,1000)}
    function observeUIRevision(revision){
      const previous=pendingUIRevision;
      pendingUIRevision=typeof revision==="string"&&/^[a-f0-9]{64}$/.test(revision)&&revision!==uiRevision?revision:null;
      if(!uiRestoreFailed){
        if(pendingUIRevision&&pendingUIRevision!==blockedUIRevision)$("uiUpdateStatus").textContent="Remote update ready. Refreshing automatically when it is safe...";
        else if(previous&&!pendingUIRevision&&!blockedUIRevision)$("uiUpdateStatus").textContent="";
      }
      scheduleUIReload();
    }
    function canReloadUI(){return Boolean(token&&!document.hidden&&!uiRestoreFailed&&!uiNavigating&&!uiComposing&&!uiActiveWrites&&!refreshTask&&!loadingHistory
      &&!movingTab&&!draggedTabID&&!chatInputSaving&&!$("send").disabled&&!document.querySelector("dialog[open]")
      &&Date.now()-uiLastInteraction>=2000&&followOutput&&document.documentElement.dataset.cantripConnected==="true")}
    async function uiStateOwner(value){const bytes=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(value));
      return Array.from(new Uint8Array(bytes),byte=>byte.toString(16).padStart(2,"0")).join("")}
    function captureUIState(owner,revision){const drafts=new Map(tabDrafts);if(selected)drafts.set(selected,$("draft").value);
      const reply=chatInputReply?.sessionID===selected&&chatInputReply.token===token?{id:chatInputReply.id,sessionID:selected}:null;
      return {schema:1,owner,revision,selected,drafts:[...drafts],mode:$("mode").value,reply,
        error:uiMutationWarning||$("actionError").textContent,focus:document.activeElement===$("draft"),
        selectionStart:$("draft").selectionStart,selectionEnd:$("draft").selectionEnd};
    }
    function navigateUpdatedUI(){location.replace(location.href)}
    function pauseUIReload(revision,error){
      if(uiNavigationTimer)clearTimeout(uiNavigationTimer);uiNavigationTimer=null;
      if(uiNavigating){window.stop();
        try{sessionStorage.removeItem(uiReloadStorageKey)}catch(storageError){uiRestoreFailed=true;error=new Error(`${error.message}; saved draft cleanup failed: ${storageError.message}`)}
      }
      uiNavigating=false;uiReloading=false;blockedUIRevision=revision;$("app").inert=false;
      $("uiUpdateStatus").textContent=`Automatic refresh paused: ${error.message}. Your current drafts have not been cleared.`;
      scheduleRefresh();
    }
    async function reloadUpdatedUI(){
      uiReloadTimer=null;
      if(!pendingUIRevision||pendingUIRevision===blockedUIRevision||uiReloading)return;
      if(!canReloadUI()){scheduleUIReload();return}
      const requestToken=token,revision=pendingUIRevision;uiReloading=true;
      try{const owner=await uiStateOwner(requestToken);
        if(token!==requestToken||pendingUIRevision!==revision||!canReloadUI()){uiReloading=false;scheduleUIReload();return}
        // Persist only ordinary composer drafts, never secure fields, credentials or transcript data.
        sessionStorage.setItem(uiReloadStorageKey,JSON.stringify(captureUIState(owner,revision)));
        uiNavigating=true;$("app").inert=true;$("uiUpdateStatus").textContent="Updating Remote...";
        if(timer)clearTimeout(timer);timer=null;
        uiNavigationTimer=setTimeout(()=>pauseUIReload(revision,new Error("The updated interface did not load in time")),20000);
        navigateUpdatedUI();
      }catch(error){pauseUIReload(revision,error)}
    }
    async function restoreUIState(){
      try{const raw=sessionStorage.getItem(uiReloadStorageKey);if(!raw)return;
        const state=JSON.parse(raw),requestToken=token;
        if(!requestToken){sessionStorage.removeItem(uiReloadStorageKey);return}
        const owner=await uiStateOwner(requestToken);
        if(token!==requestToken)return;
        if(state.owner!==owner){sessionStorage.removeItem(uiReloadStorageKey);return}
        if(state.schema!==1||typeof state.revision!=="string"||(state.selected!==null&&typeof state.selected!=="string")
          ||!Array.isArray(state.drafts)||!state.drafts.every(item=>Array.isArray(item)&&item.length===2&&item.every(value=>typeof value==="string"))
          ||!["auto","queue","interrupt","inject"].includes(state.mode)||typeof state.error!=="string"
          ||(state.reply!==null&&(!state.reply||typeof state.reply.id!=="string"||state.reply.sessionID!==state.selected)))
          throw Error("Saved Remote draft state is invalid");
        tabDrafts.clear();for(const [id,text] of state.drafts)tabDrafts.set(id,text);
        selected=state.selected;$("draft").value=tabDrafts.get(selected)||"";$("mode").value=state.mode;
        chatInputReply=state.reply?{...state.reply,token}:null;$("actionError").textContent=state.error;
        sessionStorage.removeItem(uiReloadStorageKey);
        if(state.revision!==uiRevision){blockedUIRevision=state.revision;
          $("uiUpdateStatus").textContent="The host returned an older Remote interface. Automatic refresh paused to avoid a reload loop; your drafts were restored."}
        return state.focus?{start:state.selectionStart,end:state.selectionEnd}:null;
      }catch(error){uiRestoreFailed=true;$("uiUpdateStatus").textContent=`Could not restore Remote drafts: ${error.message}. Automatic refresh paused; the saved state was retained.`}
    }
    function clearUIReloadState(){pendingUIRevision=null;blockedUIRevision=null;uiMutationWarning="";uiRestoreFailed=false;scheduleUIReload();
      try{sessionStorage.removeItem(uiReloadStorageKey)}catch(error){$("uiUpdateStatus").textContent=`Could not clear saved Remote drafts: ${error.message}`}}
    for(const name of ["input","change","pointerdown","keydown","wheel","touchmove"])document.addEventListener(name,()=>{uiLastInteraction=Date.now()},{passive:true});
    document.addEventListener("compositionstart",()=>{uiComposing=true});
    document.addEventListener("compositionend",()=>{uiComposing=false;uiLastInteraction=Date.now()});
    // The native Mac embed exposes this bridge; ordinary browsers keep the top tab strip.
    // Native shells (Mac Remote, Cantrip Gateway for Windows) get the left tab list and an unpair hook.
    const sidebarLayout=Boolean(window.webkit?.messageHandlers?.cantripRemoteUnpair||window.cantripGateway?.sidebarLayout);
    if(sidebarLayout){document.documentElement.classList.add("remote-sidebar");$("sessionSidebar").classList.remove("hidden");$("sessionSidebar").append($("sessions"));$("sessionSidebarHeader").append($("newSection"),$("newSession"));$("sessionProgress").prepend(brainIndicator())}
    function connection(active){document.documentElement.dataset.cantripConnected=active?"true":"false";const label=document.querySelector(".connection-label");if(label)label.textContent=active?"Connected":"Reconnecting…";updateProgressConnection()}
    function brainIndicator(){const icon=document.createElementNS("http://www.w3.org/2000/svg","svg");icon.setAttribute("class","brain-indicator");icon.setAttribute("viewBox","0 0 24 24");icon.setAttribute("aria-hidden","true");icon.setAttribute("focusable","false");
      const path=document.createElementNS(icon.namespaceURI,"path");path.setAttribute("d","M12 5C12 1 6 1 6 5C3 5 2 8 4 10C1 12 2 16 5 17C4 21 10 23 12 19C14 23 20 21 19 17C22 16 23 12 20 10C22 8 21 5 18 5C18 1 12 1 12 5V19M6 5C6 8 9 7 9 10M4 10C7 10 8 12 6 14M5 17C8 16 10 17 10 19M18 5C18 8 15 7 15 10M20 10C17 10 16 12 18 14M19 17C16 16 14 17 14 19");path.setAttribute("fill","none");path.setAttribute("stroke","currentColor");path.setAttribute("stroke-width","1.5");path.setAttribute("stroke-linecap","round");path.setAttribute("stroke-linejoin","round");icon.append(path);return icon}
    function setText(node,text){if(node.textContent!==text)node.textContent=text}
    function progressSummary(session){const parts=[session.pendingInputCount?"Needs your input":session.isStreaming?(session.status||"Working…"):(session.canResume?"Paused":"Ready")];if(session.isLocalPrivate)parts.unshift("Self-hosted, saved");if(session.queuedCount>0)parts.push(`${session.queuedCount} queued`);return parts.join(" · ")}
    function updateProgressConnection(){if(!sidebarLayout)return;const connected=document.documentElement.dataset.cantripConnected==="true";
      for(const button of $("sessions").querySelectorAll(".session-select")){const summary=connected?button.dataset.status:`Last known: ${button.dataset.status}`;setText(button.querySelector(".session-status"),summary);button.title=`${button.dataset.title} — ${summary}${button.dataset.locked==="true"?" · Locked":""}`;button.setAttribute("aria-label",button.title)}
      const progress=$("sessionProgress");if(!progress.classList.contains("hidden")){const summary=connected?progress.dataset.status:`Reconnecting… Last known: ${progress.dataset.status}`;setText($("sessionProgressText"),summary);progress.title=summary}}
    function renderProgress(session){if(!sidebarLayout)return;const progress=$("sessionProgress");progress.classList.toggle("hidden",!session);progress.dataset.streaming=String(Boolean(session?.isStreaming));progress.dataset.status=session?progressSummary(session):"";if(!session)setText($("sessionProgressText"),"");updateProgressConnection()}
    function atBottom(){const root=document.scrollingElement||document.documentElement;return root.scrollHeight-root.clientHeight-root.scrollTop<=4}
    // historyScrollIntent: the latest input gesture points upward (cleared by each render).
    // historyReading: the reader is heading into older history, so loaded pages may chain.
    // restoredScrollTop: where Remote itself last positioned the page, so that scroll is not mistaken for reading.
    let historyScrollIntent=false,historyReading=false,lastHistoryScrollTop=0,lastHistoryScrollHeight=0,restoredScrollTop=null,historyTouchY=null;
    let historyAnchorRows=()=>Array.from($("messages").querySelectorAll("article[data-message-id]"));
    let renderScrollRevision=0;
    function positionConversation(top){const root=document.scrollingElement||document.documentElement;root.scrollTop=top;restoredScrollTop=root.scrollTop}
    function visibleHistoryAnchor(){for(const row of historyAnchorRows()){const bounds=row.getBoundingClientRect();if(bounds.bottom>0&&bounds.top<innerHeight)return {id:row.dataset.messageId,top:bounds.top}}return null}
    function settleConversationPosition(anchor,target,shouldFollow,revision){return new Promise(resolve=>{const root=document.scrollingElement||document.documentElement;let attempts=0,stable=0;
      const step=()=>requestAnimationFrame(()=>{if(revision!==renderScrollRevision){resolve();return}
        const row=anchor&&historyAnchorRows().find(item=>item.dataset.messageId===anchor.id);
        if(row){const delta=row.getBoundingClientRect().top-anchor.top;if(Math.abs(delta)>=0.5){positionConversation(root.scrollTop+delta);stable=0}else stable++}
        else{if(!attempts)positionConversation(target);stable=2}
        attempts++;if(!anchor||attempts>=6||stable>=2){followOutput=shouldFollow;suppressScroll=false;resolve()}else step()});
      step()})}
    function nearHistoryTop(){return (document.scrollingElement||document.documentElement).scrollTop<=Math.max(600,innerHeight)}
    function requestHistoryOnScroll(){if(historyScrollIntent&&!suppressScroll&&!document.querySelector("dialog[open]")&&nearHistoryTop())loadOlderMessages(true)}
    function historyGesture(upward){historyScrollIntent=upward;historyReading=upward;if(upward){followOutput=false;requestHistoryOnScroll()}}
    addEventListener("wheel",event=>{if(event.target.closest("#sessions")||!event.deltaY)return;historyGesture(event.deltaY<0)},{passive:true});
    addEventListener("touchstart",event=>{historyTouchY=event.touches[0]?.clientY??null;historyScrollIntent=false},{passive:true});
    addEventListener("touchmove",event=>{const y=event.touches[0]?.clientY;if(y!==undefined&&historyTouchY!==null&&y!==historyTouchY&&!event.target.closest("#sessions"))historyGesture(y>historyTouchY);historyTouchY=y??null},{passive:true});
    addEventListener("keydown",event=>{if(event.target.closest("input,textarea,select,[contenteditable],#sessions")||document.querySelector("dialog[open]"))return;
      const upward=["ArrowUp","PageUp","Home"].includes(event.key)||(event.key===" "&&event.shiftKey);if(upward||["ArrowDown","PageDown","End"," "].includes(event.key))historyGesture(upward)});
    // Any upward scroll Remote did not cause (momentum after a render, scrollbar drags, find, assistive tech)
    // is reading; content shrinking above the reader is layout, not intent.
    addEventListener("scroll",()=>{const root=document.scrollingElement||document.documentElement,top=root.scrollTop,height=root.scrollHeight,restored=restoredScrollTop!==null&&Math.abs(top-restoredScrollTop)<1;restoredScrollTop=null;
      if(!suppressScroll&&!restored){followOutput=atBottom();if(followOutput)historyReading=false;if(top<lastHistoryScrollTop&&height>=lastHistoryScrollHeight){historyScrollIntent=true;historyReading=true;requestHistoryOnScroll()}}
      lastHistoryScrollTop=top;lastHistoryScrollHeight=height},{passive:true});
    async function api(path,options={}){options.headers={...(options.headers||{}),Authorization:`Bearer ${token}`};if(options.body)options.headers["Content-Type"]="application/json";
      if(uiNavigating)throw Error("Remote is updating; this request was not sent.");
      path+=(path.includes("?")?"&":"?")+"history=recent";
      const controller=(!options.method||options.method==="GET")?new AbortController():null;
      const segments=path.split("?")[0].split("/").filter(Boolean),historyRead=segments.slice(0,3).join("/")==="api/v1/sessions"&&(segments.length===4||(segments.length===6&&segments[4]==="messages"));
      if(sidebarLayout&&controller&&historyRead&&segments.length===4&&!new URLSearchParams(path.split("?")[1]).has("before"))path+="&recentExchanges=3";
      const deadline=controller?setTimeout(()=>controller.abort(),historyRead?20000:8000):null;if(controller)options.signal=controller.signal;
      if(!controller)uiActiveWrites++;
      try{const response=await fetch(path,options);const data=await response.json();if(!response.ok){const error=new Error(data.error||`HTTP ${response.status}`);error.status=response.status;throw error}return data}
      catch(error){if(!controller)uiMutationWarning=`A Remote action failed: ${error.message}. Check the conversation before retrying; it was not resent.`;throw error}
      finally{if(deadline!==null)clearTimeout(deadline);if(!controller){uiActiveWrites--;scheduleUIReload()}}}
    function pair(show){$("pair").classList.toggle("hidden",!show);$("app").classList.toggle("hidden",show);if(show){connection(false);if(timer){clearInterval(timer);timer=null}}}
    let refreshTask=null,refreshRequested=false,sessionItems=[],draggedTabID=null,draggedSectionID=null,movingTab=false,tabOrderRevision=0,loadingHistory=false;
    // Sections come from the Mac; which ones are collapsed is this browser's choice.
    const collapsedSectionsKey="cantrip.collapsedSections",looseSectionID="tabs";let tabSections=[],sectionsSupported=false,collapsedSections=new Set();
    try{collapsedSections=new Set(JSON.parse(localStorage.getItem(collapsedSectionsKey)||"[]"))}catch{}
    const tabDrafts=new Map();
    function selectTab(id){if(selected)tabDrafts.set(selected,$("draft").value);selected=id;$("draft").value=tabDrafts.get(id)||"";if(typeof syncSlashCommands==="function")syncSlashCommands()}
    // historyPaused: tabs whose last older page failed; automatic loading waits for Retry.
    const historyCache=new Map(),expandedHistory=new Set(),historyPaused=new Map(),initialHistoryGroups=sidebarLayout?3:11;
    function historySuffix(messages,groups){if(groups<=0)return [];const prompts=messages.flatMap((m,i)=>m.role==="user"?[i]:[]);return prompts.length>groups?messages.slice(prompts[prompts.length-groups]):messages}
    function canAutomaticallyLoadHistory(session){return Boolean(session?.hasOlderMessages&&!historyPaused.has(session.id))}
    // The row keeps its height for paged tabs, so progress or reaching the start never moves the text being read.
    // A retry shows progress in place of the error, so a repeated failure is announced again.
    function updateHistoryControls(session){const older=Boolean(session?.hasOlderMessages),failure=older?historyPaused.get(session.id):null,loading=older&&loadingHistory,row=$("olderHistory");
      row.classList.toggle("hidden",!session?.supportsPagedHistory);row.dataset.state=loading?"loading":failure?"failed":"idle";row.classList.toggle("has-retry",Boolean(failure));
      setText($("olderHistoryText"),loading?"Loading older messages…":failure||"");
      $("olderMessages").classList.toggle("hidden",!failure);$("olderMessages").disabled=loadingHistory;
      // Stays mounted while loading so a screen reader's focus is not dropped.
      $("olderHistoryReader").classList.toggle("hidden",!older||Boolean(failure));$("olderHistoryReader").setAttribute("aria-disabled",String(loading))}
    function continueHistoryReading(id){setTimeout(()=>{if(historyReading&&selected===id&&!document.querySelector("dialog[open]")&&nearHistoryTop())loadOlderMessages(true)},120)}
    function cacheSession(session,merge=true){const previous=historyCache.get(session.id);
      if(previous?.historyStartID!==session.historyStartID){expandedHistory.delete(session.id);historyPaused.delete(session.id)}
      if(merge&&session.historyStartID&&previous?.historyStartID===session.historyStartID){
        const overlap=previous.messages.findIndex(m=>m.id===session.messages[0]?.id);
        if(overlap>=0)session={...session,messages:[...previous.messages.slice(0,overlap),...session.messages],hasOlderMessages:previous.hasOlderMessages}}
      if(!expandedHistory.has(session.id)&&session.supportsPagedHistory){const bounded=historySuffix(session.messages,initialHistoryGroups);
        if(bounded.length<session.messages.length)session={...session,messages:bounded,hasOlderMessages:true}}
      if(!expandedHistory.has(session.id)&&session.supportsPagedHistory&&session.messages.length>120&&(!sidebarLayout||!session.messages.some(m=>m.role==="user"))){
        let start=session.messages.length-120;
        if(session.messages[start].role!=="user"){const prompt=session.messages.slice(0,start).findLastIndex(m=>m.role==="user");if(prompt>=0)start=prompt}
        if(start>0)session={...session,messages:session.messages.slice(start),hasOlderMessages:true}}
      historyCache.delete(session.id);historyCache.set(session.id,session);while(historyCache.size>5){const id=historyCache.keys().next().value;historyCache.delete(id);expandedHistory.delete(id);historyPaused.delete(id)}return session}
    function scheduleRefresh(){if(timer)clearTimeout(timer);timer=null;if(!token||document.hidden||uiNavigating)return;
      // Fast polling follows the open tab; other tabs' status still refreshes every 5 s.
      const busy=sessionItems.some(s=>s.id===selected&&(s.isStreaming||s.queuedCount))||$("historyError").textContent||document.documentElement.dataset.cantripConnected!=="true";
      timer=setTimeout(refresh,busy?1500:5000)}
    function refresh(){refreshRequested=true;if(refreshTask)return refreshTask;
      refreshTask=(async()=>{while(refreshRequested&&token){refreshRequested=false;const requestedID=selected,requestToken=token,orderRevision=tabOrderRevision;
        let listedSuccessfully=false,requestSelection=requestedID;
        try{const listed=await api("/api/v1/sessions");if(token!==requestToken||orderRevision!==tabOrderRevision)continue;connection(true);listedSuccessfully=true;observeUIRevision(listed.uiRevision);tabSections=listed.sections||[];sectionsSupported=listed.supportsTabSections===true;$("newSection").classList.toggle("hidden",!sectionsSupported);renderHomeInputs(listed.homeInputs||[]);
          // Cantrip Home is pinned first when the Mac has it on; it is never closed or moved.
          const sessions=listed.home?[listed.home,...listed.sessions]:listed.sessions;$("homeTasks").classList.toggle("hidden",!listed.home);$("homeArtifacts").classList.toggle("hidden",!listed.home);
          for(const id of historyCache.keys())if(!sessions.some(s=>s.id===id)){historyCache.delete(id);expandedHistory.delete(id);historyPaused.delete(id)}
          if(selected!==requestedID){refreshRequested=true;continue}
          if(tabLink&&sessions.some(s=>s.id===tabLink)){selectTab(tabLink);tabLink=null;history.replaceState(null,"",location.pathname+location.search)}
          if(!selected||!sessions.some(s=>s.id===selected))selectTab(listed.sessions[0]?.id||listed.home?.id||null);
          requestSelection=selected;
          renderSessions(sessions);const detailID=selected;if(detailID){const cached=historyCache.get(detailID),summary=sessions.find(s=>s.id===detailID);
            if(cached)render(cached);else if(renderedSession!==detailID)render(null);
            if(!cached?.historyRevision||cached.historyRevision!==summary.historyRevision){
              const suffix=cached?.historyRevision?`?revision=${encodeURIComponent(cached.historyRevision)}`:"";
              const data=await api(`/api/v1/sessions/${detailID}${suffix}`);if(token!==requestToken||orderRevision!==tabOrderRevision)continue;if(selected!==detailID){refreshRequested=true;continue}
              if(data.session)render(cacheSession(data.session));else if(!data.unchanged||!cached)throw new Error("Invalid conversation update")}
          }else render(null);$("historyError").textContent=""}
        catch(error){if(token!==requestToken||selected!==requestSelection)continue;
          if(!listedSuccessfully||error.status===401)connection(false);
          $("historyError").textContent=`${listedSuccessfully?"Could not update this conversation":"Could not refresh tabs"}: ${error.message}. Retrying...`;
          if(error.status===401){refreshRequested=false;pair(true)}}}
      })().finally(()=>{refreshTask=null;scheduleRefresh();scheduleUIReload()});return refreshTask}
    // Cantrip Home background runs live in hidden sessions that are never tabs, so their approvals
    // and questions are answered here, in place, against the run's own session.
    const answeredHomeInputs=new Map();
    function renderHomeInputs(entries){const cards=$("homeInputCards"),now=Date.now();
      for(const [id,at] of answeredHomeInputs)if(now-at>60000)answeredHomeInputs.delete(id);
      const items=entries.flatMap(entry=>(entry.requests||[]).map(request=>({entry,request}))).filter(item=>!answeredHomeInputs.has(item.request.id));
      const ids=new Set(items.map(item=>item.request.id)),before=cards.children.length;
      for(const card of Array.from(cards.children))if(!ids.has(card.dataset.id)&&!card.dataset.saving)card.remove();
      for(const {entry,request} of items)if(!Array.from(cards.children).some(card=>card.dataset.id===request.id))cards.append(homeInputCard(entry,request));
      const count=cards.children.length;$("homeInputs").classList.toggle("hidden",!count);
      setText($("homeInputsTitle"),count>1?`Cantrip Home needs your input (${count})`:"Cantrip Home needs your input");
      if(count>before)setText($("homeInputsStatus"),count===1?"A Cantrip Home background run needs your input.":`${count} Cantrip Home requests need your input.`)}
    function homeInputCard(entry,request){const card=document.createElement("section"),status=document.createElement("div"),actions=document.createElement("div");
      card.className="input-card home-input";card.dataset.id=request.id;card.setAttribute("aria-label",`${entry.label}: ${request.title}`);
      const run=document.createElement("span"),title=document.createElement("strong");run.className="muted";run.textContent=`${entry.label} · background run`;title.textContent=request.title;card.append(run,title);
      appendInputDetail(card,request,entry.sessionID);
      status.className="home-input-status";status.setAttribute("role","alert");actions.className="tab-actions";let field=null;
      const button=(label,body,primary)=>{const node=document.createElement("button");node.className=primary?"control primary":"control";node.textContent=label;
        node.onclick=()=>answerHomeInput(entry,request,typeof body==="function"?body():body,card,status);actions.append(node)};
      const input=(type,label)=>{field=document.createElement("input");field.type=type;field.autocomplete="off";field.spellcheck=false;field.setAttribute("aria-label",label);card.append(field)};
      if(request.kind==="approval"){button("Approve once",{decision:"approve"},true);button("Deny",{decision:"deny"})}
      else if(request.kind==="question"){for(const choice of request.choices||[])button(choice,{decision:"submit",text:choice},false);
        if(request.allowsFreeform){input("text",`Answer: ${request.title}`);button("Send",()=>({decision:"submit",text:field.value.trim()}),true)}
        button("Skip",{decision:"cancel"})}
      else if(request.kind==="secret"){input("password","Password or passphrase");button("Submit",()=>({decision:"submit",text:field.value}),true);button("Cancel",{decision:"cancel"})}
      else{if(request.url){const url=safeURL(request.url);if(url?.startsWith("https:")){const link=document.createElement("a");link.href=url;link.textContent="Open sign-in page";link.target="_blank";link.rel="noopener noreferrer";card.append(link)}}
        if(request.code){const code=document.createElement("pre");code.textContent=`Device code: ${request.code}`;card.append(code)}
        button(request.kind==="login"?"I've signed in":"Done on Mac",{decision:"approve"},true);button("Cancel",{decision:"cancel"})}
      card.append(actions,status);return card}
    async function answerHomeInput(entry,request,body,card,status){if(card.dataset.saving)return;
      if(body.decision==="submit"&&!body.text){status.textContent="Enter an answer first.";return}
      const requestToken=token,controls=card.querySelectorAll("button,input");card.dataset.saving="1";for(const control of controls)control.disabled=true;status.textContent="";
      try{await api(`/api/v1/sessions/${entry.sessionID}/input/${request.id}`,{method:"POST",body:JSON.stringify(body)});if(token!==requestToken)return;
        answeredHomeInputs.set(request.id,Date.now());const next=card.nextElementSibling||card.previousElementSibling;card.remove();
        setText($("homeInputsStatus"),`${body.decision==="approve"?"Approved":body.decision==="deny"?"Denied":body.decision==="cancel"?"Skipped":"Answered"}: ${request.title}. The run continues.`);
        if(!$("homeInputCards").children.length)$("homeInputs").classList.add("hidden");else next?.querySelector("button")?.focus()}
      catch(error){if(token===requestToken){delete card.dataset.saving;for(const control of controls)control.disabled=false;status.textContent=`${error.message} Not retried. It refreshes on its own if the run moved on.`}}
      finally{delete body.text;const secret=card.querySelector("input[type=password]");if(secret)secret.value="";refresh()}}
    async function loadOlderMessages(automatically=false){const current=historyCache.get(selected),before=current?.messages[0]?.id;if(loadingHistory||!current?.hasOlderMessages||!before||(automatically&&!canAutomaticallyLoadHistory(current)))return;
      const requestToken=token,orderRevision=tabOrderRevision;let loaded=false;loadingHistory=true;updateHistoryControls(current);
      try{const data=await api(`/api/v1/sessions/${current.id}?before=${encodeURIComponent(before)}`),latest=historyCache.get(current.id);
        if(token!==requestToken||selected!==current.id||orderRevision!==tabOrderRevision||latest?.historyStartID!==data.session.historyStartID||latest?.messages[0]?.id!==before)return;
        const ids=new Set(latest.messages.map(m=>m.id)),page=data.session,received=page.messages.filter(m=>!ids.has(m.id));
        if(!received.length&&page.hasOlderMessages!==false)throw Error("Invalid history page");
        historyPaused.delete(current.id);expandedHistory.add(current.id);
        render(cacheSession({...latest,messages:[...received,...latest.messages],hasOlderMessages:page.hasOlderMessages===true},false),true);$("historyError").textContent="";loaded=true}
      catch(error){if(token===requestToken&&selected===current.id)historyPaused.set(current.id,`Couldn't load older messages: ${error.message}`)}
      finally{loadingHistory=false;updateHistoryControls(historyCache.get(selected));if(loaded)continueHistoryReading(current.id)}}
    $("olderMessages").onclick=()=>loadOlderMessages();
    $("olderHistoryReader").onclick=()=>loadOlderMessages();$("olderHistoryReader").onfocus=()=>loadOlderMessages(true);
    document.addEventListener("visibilitychange",()=>{if(document.hidden){if(timer)clearTimeout(timer);timer=null}else if(token)refresh()});
    function renderSessions(items){const nav=$("sessions"),previousLeft=nav.scrollLeft,previousTop=nav.scrollTop,selectionChanged=nav.dataset.selected!==(selected||"");
      if(draggedTabID||draggedSectionID||movingTab)return;sessionItems=items;
      // Keep existing controls mounted so polling does not interrupt scrolling or keyboard focus.
      const existing=new Map(),headers=new Map();for(const node of nav.children)(node.dataset.sessionId?existing:headers).set(node.dataset.sessionId||node.dataset.sectionId,node);
      const order=sectionedOrder(items),wanted=new Set(order.map(entry=>entry.item?entry.item.id:"section:"+entry.group.id));
      for(const node of Array.from(nav.children))if(!wanted.has(node.dataset.sessionId||"section:"+node.dataset.sectionId))node.remove();
      for(const [index,entry] of order.entries()){if(entry.group){const header=headers.get(entry.group.id)||sectionHeader(entry.group.id);updateSectionHeader(header,entry.group);
          if(nav.children[index]!==header)nav.insertBefore(header,nav.children[index]||null);continue}
        const item=entry.item;let tab=existing.get(item.id);
        if(!tab){tab=document.createElement("span");tab.dataset.sessionId=item.id;
          const button=document.createElement("button");button.className="session-select";
          if(sidebarLayout){const title=document.createElement("span"),status=document.createElement("span");title.className="session-name";status.className="session-status";button.append(brainIndicator(),title,status)}
          const close=document.createElement("button");close.className="session-close";tab.append(button,close)}
        tab.className=`session-tab ${item.id===selected?"active":""}${item.isCantripHome?" home-tab":""}${item.parentID?" child-tab":""}`;
        tab.draggable=Boolean(item.supportsTabReordering);
        tab.ondragstart=event=>{if(movingTab||!item.supportsTabReordering){event.preventDefault();return}draggedTabID=item.id;event.dataTransfer.effectAllowed="move";event.dataTransfer.setData("text/plain",`cantrip-tab:${item.id}`)};
        tab.ondragend=()=>{draggedTabID=null;for(const row of nav.children)row.classList.remove("drop-target");refresh()};
        tab.ondragover=event=>{if(draggedTabID&&draggedTabID!==item.id&&item.supportsTabReordering&&!movingTab){event.preventDefault();event.dataTransfer.dropEffect="move";tab.classList.add("drop-target")}};
        tab.ondragleave=()=>tab.classList.remove("drop-target");
        tab.ondrop=event=>{event.preventDefault();tab.classList.remove("drop-target");const id=draggedTabID;draggedTabID=null;
          const source=sessionItems.findIndex(s=>s.id===id),target=sessionItems.findIndex(s=>s.id===item.id);
          if(id&&id!==item.id&&source>=0&&target>=0&&item.supportsTabReordering)moveTab(id,item.id,source<target)};
        tab.onkeydown=event=>{if(!event.altKey||!item.supportsTabReordering)return;const earlier=sidebarLayout?"ArrowUp":"ArrowLeft",later=sidebarLayout?"ArrowDown":"ArrowRight";
          if(event.key===earlier||event.key===later){event.preventDefault();moveTabBy(item.id,event.key===earlier?-1:1)}};
        const button=tab.children[0];if(sidebarLayout){setText(button.querySelector(".session-name"),item.title);tab.dataset.streaming=String(Boolean(item.isStreaming));button.dataset.title=item.title;button.dataset.status=progressSummary(item);button.dataset.locked=String(Boolean(item.isLocked))}else{button.textContent=item.title;button.title=item.title}
        const childNote=item.parentID?`, child tab of ${item.child?.parentTitle||"another tab"}`:"";let note=button.querySelector(".child-note");if(childNote){if(!note){note=document.createElement("span");note.className="sr-only child-note";button.append(note)}setText(note,childNote)}else if(note)note.remove();
        button.setAttribute("aria-current",item.id===selected?"true":"false");button.onclick=()=>{selectTab(item.id);renderedPayload="";renderProgress(item);refresh()};
        const close=tab.children[1];close.textContent=item.isLocked?"🔒":"×";close.disabled=Boolean(item.isLocked);close.title=item.isLocked?"Locked - unlock in tab settings":`Close ${item.title}`;close.setAttribute("aria-label",close.title);close.hidden=Boolean(item.isCantripHome);close.onclick=event=>{event.stopPropagation();closeSession(item.id)};
        let menu=tab.children[2];if(item.supportsTabMetadata){if(!menu){menu=document.createElement("button");menu.className="session-menu";menu.textContent="…";tab.append(menu)}
          menu.title=`Settings for ${item.title}${item.supportsTabReordering?" - drag tabs to reorder":""}`;menu.setAttribute("aria-label",menu.title);menu.onclick=()=>editTab(item)}else if(menu)menu.remove();
        if(nav.children[index]!==tab)nav.insertBefore(tab,nav.children[index]||null)}
      renderProgress(items.find(item=>item.id===selected));if(nav.scrollLeft!==previousLeft)nav.scrollLeft=previousLeft;if(nav.scrollTop!==previousTop)nav.scrollTop=previousTop;nav.dataset.selected=selected||"";
      if(selectionChanged){const active=nav.querySelector(".active");if(active){const bounds=active.getBoundingClientRect(),viewport=nav.getBoundingClientRect();
        if(sidebarLayout){if(bounds.top<viewport.top||bounds.height>viewport.height)nav.scrollTop+=bounds.top-viewport.top;
          else if(bounds.bottom>viewport.bottom)nav.scrollTop+=bounds.bottom-viewport.bottom}
        else if(bounds.left<viewport.left||bounds.width>viewport.width)nav.scrollLeft+=bounds.left-viewport.left;
        else if(bounds.right>viewport.right)nav.scrollLeft+=bounds.right-viewport.right}}}
    $("sessions").addEventListener("wheel",event=>{const nav=$("sessions");
      if(sidebarLayout||event.ctrlKey||event.shiftKey||Math.abs(event.deltaX)>=Math.abs(event.deltaY)||nav.scrollWidth<=nav.clientWidth)return;
      event.preventDefault();const unit=event.deltaMode===1?16:event.deltaMode===2?nav.clientWidth:1;nav.scrollLeft+=event.deltaY*unit
    },{passive:false});
    // Home first, then each section in the Mac's order, then unfiled tabs under "Tabs". A collapsed
    // section still shows the open tab and tabs that are working or waiting for an answer.
    function sectionedOrder(items){if(!tabSections.length)return items.map(item=>({item}));
      const known=new Set(tabSections.map(section=>section.id)),groups=[],order=[];
      const loose=items.filter(item=>!item.isCantripHome&&!known.has(item.sectionID));
      for(const item of items)if(item.isCantripHome)order.push({item});
      for(const section of tabSections)groups.push({id:section.id,name:section.name,items:items.filter(item=>item.sectionID===section.id)});
      if(loose.length)groups.push({id:looseSectionID,name:"Tabs",items:loose});
      for(const group of groups){order.push({group});const collapsed=collapsedSections.has(group.id);
        for(const item of group.items)if(!collapsed||item.id===selected||item.isStreaming||item.pendingInputCount>0)order.push({item})}
      return order}
    function sectionHeader(id){const header=document.createElement("div"),toggle=document.createElement("button"),name=document.createElement("span"),count=document.createElement("span"),menu=document.createElement("button");
      header.className="section-header";header.dataset.sectionId=id;toggle.type="button";toggle.className="section-toggle";name.className="section-name";count.className="section-count";toggle.append(name,count);
      menu.type="button";menu.className="section-menu";menu.textContent="…";header.append(toggle,menu);
      toggle.onclick=()=>{if(collapsedSections.has(id))collapsedSections.delete(id);else collapsedSections.add(id);
        try{localStorage.setItem(collapsedSectionsKey,JSON.stringify([...collapsedSections]))}catch{}renderSessions(sessionItems)};
      // Sections reorder by dragging their header onto another one (onto Tabs = last), or with Alt+arrows.
      header.ondragstart=event=>{if(movingTab||id===looseSectionID){event.preventDefault();return}draggedSectionID=id;header.classList.add("dragging");
        event.dataTransfer.effectAllowed="move";event.dataTransfer.setData("text/plain",`cantrip-section:${id}`)};
      header.ondragend=()=>{draggedSectionID=null;header.classList.remove("dragging");for(const row of $("sessions").children)row.classList.remove("drop-target");refresh()};
      header.ondragover=event=>{if(!movingTab&&(draggedTabID||draggedSectionID&&draggedSectionID!==id)){event.preventDefault();event.dataTransfer.dropEffect="move";header.classList.add("drop-target")}};
      header.ondragleave=()=>header.classList.remove("drop-target");
      header.ondrop=event=>{event.preventDefault();header.classList.remove("drop-target");const tabID=draggedTabID,sectionID=draggedSectionID;draggedTabID=null;draggedSectionID=null;
        if(tabID)fileTab(tabID,id===looseSectionID?null:id);
        else if(sectionID&&sectionID!==id)moveSectionTo(sectionID,id===looseSectionID?tabSections.length-1:tabSections.findIndex(section=>section.id===id))};
      toggle.onkeydown=event=>{if(!event.altKey||id===looseSectionID)return;const earlier=sidebarLayout?"ArrowUp":"ArrowLeft",later=sidebarLayout?"ArrowDown":"ArrowRight";
        if(event.key===earlier||event.key===later){event.preventDefault();moveSectionBy(id,event.key===earlier?-1:1)}};
      return header}
    function updateSectionHeader(header,group){const collapsed=collapsedSections.has(group.id),toggle=header.children[0],menu=header.children[1];
      setText(toggle.children[0],`${collapsed?"▸":"▾"} ${group.name}`);setText(toggle.children[1],String(group.items.length));
      const movable=group.id!==looseSectionID&&sectionsSupported,arrows=sidebarLayout?"Alt+ArrowUp Alt+ArrowDown":"Alt+ArrowLeft Alt+ArrowRight";header.draggable=movable;
      if(movable)toggle.setAttribute("aria-keyshortcuts",arrows);else toggle.removeAttribute("aria-keyshortcuts");
      toggle.setAttribute("aria-expanded",String(!collapsed));toggle.title=`${collapsed?"Expand":"Collapse"} ${group.name}${movable?` - drag to reorder sections, or press ${sidebarLayout?"Alt+↑/↓":"Alt+←/→"}`:""}`;
      menu.title=group.id===looseSectionID?"New section":`${group.name} section options`;menu.setAttribute("aria-label",menu.title);menu.onclick=()=>editSection(group)}
    async function fileTab(id,sectionID){if(movingTab||tabSaving)return;movingTab=true;tabOrderRevision++;$("actionError").textContent="";
      try{await api(`/api/v1/sessions/${id}/metadata`,{method:"POST",body:JSON.stringify({sectionID})})}
      catch(error){$("actionError").textContent=`${error.message} Refresh the tabs before trying again.`}
      finally{movingTab=false;refresh()}}
    async function moveSectionTo(id,position){if(movingTab||tabSaving||position<0)return;movingTab=true;tabOrderRevision++;$("actionError").textContent="";
      try{const data=await api(`/api/v1/sections/${id}`,{method:"PATCH",body:JSON.stringify({position})});if(data?.sections)tabSections=data.sections}
      catch(error){$("actionError").textContent=`${error.message} Refresh the tabs before trying again.`}
      finally{movingTab=false;renderSessions(sessionItems);refresh()}}
    async function moveSectionBy(id,offset){const index=tabSections.findIndex(section=>section.id===id);if(index<0||!tabSections[index+offset])return;
      await moveSectionTo(id,index+offset);$("sessions").querySelector(`[data-section-id="${id}"] .section-toggle`)?.focus()}
    let editingSection=null,sectionSaving=false,sectionDeleteArmed=false;
    function editSection(group){editingSection=group;sectionDeleteArmed=false;$("sectionDelete").textContent="Delete Section";const creating=group.id===looseSectionID,index=tabSections.findIndex(section=>section.id===group.id);
      $("sectionEditorTitle").textContent=creating?"New section":"Section";$("sectionName").value=creating?"":group.name;$("sectionSave").textContent=creating?"Create":"Save";
      $("sectionActions").classList.toggle("hidden",creating);$("sectionUp").disabled=index<=0;$("sectionDown").disabled=index<0||index>=tabSections.length-1;
      $("sectionNote").textContent=creating?"Sections show on every device. File a tab from its … menu, or drag it onto a section.":"Drag a section's header to reorder it. Deleting a section moves its tabs back to Tabs.";
      $("sectionError").textContent="";$("sectionEditor").showModal();$("sectionName").focus()}
    async function sectionRequest(work){if(sectionSaving||!editingSection)return;sectionSaving=true;$("sectionError").textContent="";
      for(const button of $("sectionForm").querySelectorAll("button"))button.disabled=true;
      try{await work();$("sectionEditor").close();editingSection=null;tabOrderRevision++;await refresh()}
      catch(error){$("sectionError").textContent=error.message}
      finally{sectionSaving=false;for(const button of $("sectionForm").querySelectorAll("button"))button.disabled=false;
        if(editingSection){const index=tabSections.findIndex(section=>section.id===editingSection.id);$("sectionUp").disabled=index<=0;$("sectionDown").disabled=index<0||index>=tabSections.length-1}}}
    $("sectionForm").onsubmit=event=>{event.preventDefault();const group=editingSection,name=$("sectionName").value;if(!group)return;
      sectionRequest(()=>group.id===looseSectionID?api("/api/v1/sections",{method:"POST",body:JSON.stringify({name})})
        :name===group.name?Promise.resolve():api(`/api/v1/sections/${group.id}`,{method:"PATCH",body:JSON.stringify({name})}))};
    $("sectionNewTab").onclick=()=>{const group=editingSection;sectionRequest(async()=>{const data=await api("/api/v1/sessions",{method:"POST",body:JSON.stringify({sectionID:group.id})});selectTab(data.session.id)})};
    $("sectionUp").onclick=()=>{const group=editingSection,index=tabSections.findIndex(section=>section.id===group?.id);sectionRequest(()=>api(`/api/v1/sections/${group.id}`,{method:"PATCH",body:JSON.stringify({position:index-1})}))};
    $("sectionDown").onclick=()=>{const group=editingSection,index=tabSections.findIndex(section=>section.id===group?.id);sectionRequest(()=>api(`/api/v1/sections/${group.id}`,{method:"PATCH",body:JSON.stringify({position:index+1})}))};
    // A section with tabs asks first (its tabs move back to Tabs; none close); an empty one goes at once.
    $("sectionDelete").onclick=()=>{const group=editingSection;if(!group)return;const count=sessionItems.filter(item=>item.sectionID===group.id).length;
      if(count&&!sectionDeleteArmed){sectionDeleteArmed=true;$("sectionDelete").textContent="Confirm Delete";
        $("sectionNote").textContent=`Delete “${group.name}”? Its ${count===1?"tab moves":count+" tabs move"} back to Tabs; no tabs are closed. Press Confirm Delete to continue.`;return}
      sectionRequest(()=>api(`/api/v1/sections/${group.id}`,{method:"DELETE"}))};
    $("newSection").onclick=()=>editSection({id:looseSectionID,name:"Tabs",items:[]});
    $("sectionCancel").onclick=()=>{$("sectionEditor").close();editingSection=null};
    $("sectionEditor").addEventListener("cancel",event=>{if(sectionSaving)event.preventDefault()});
    $("tabSection").onchange=()=>{const creating=$("tabSection").value==="new";$("tabNewSection").classList.toggle("hidden",!creating);if(creating)$("tabNewSection").focus()};
    let modelEditorState=null;
    function modelInfo(state){return state.data?.models.find(m=>m.id===(state.draft.model||state.data.fileDefaultModel))}
    function modelValidation(state){if(state.usesDefaults)return "";const info=modelInfo(state),draft=state.draft;
      if(draft.model&&!info)return "This model is no longer in the Mac's catalog.";
      if(draft.effort&&!info?.reasoningEfforts?.includes(draft.effort))return "Choose a supported effort or Model default.";
      if(draft.contextTier&&!info?.contextTiers?.includes(draft.contextTier))return "Choose a supported context window or CLI default.";return ""}
    function modelTokens(value){return `${Number((value/(value>=1000000?1000000:value>=1000?1000:1)).toFixed(3))}${value>=1000000?"M":value>=1000?"k":""}`}
    function modelOptions(id,values,current,defaultLabel,label=value=>value){const select=$(id);select.replaceChildren();
      for(const value of [...new Set(["",...(values||[]),current])]){const option=document.createElement("option");option.value=value;option.textContent=value?label(value):defaultLabel;
        option.disabled=Boolean(value)&&!values?.includes(value);select.append(option)}select.value=current}
    function renderModelSettings(){const state=modelEditorState;if(!state)return;const info=state.data&&modelInfo(state),disabled=state.loading||state.saving,reason=state.data?.unavailableReason;
      $("modelDefaults").checked=state.usesDefaults;$("modelDefaults").disabled=disabled||!state.data||Boolean(reason);
      if(state.data){modelOptions("modelChoice",state.data.models.map(m=>m.id),state.draft.model,`CLI default (${state.data.fileDefaultModel||"Auto"})`);
        modelOptions("modelEffort",info?.reasoningEfforts,state.draft.effort,"Model default");
        modelOptions("modelContext",info?.contextTiers,state.draft.contextTier,"CLI default",tier=>{const name=tier==="default"?"Standard":tier==="long_context"?"Long":tier;
          const budget=tier==="default"?info?.defaultContextPromptTokens:tier==="long_context"?info?.longContextPromptTokens:null;return budget?`${name} - ${modelTokens(budget)} input`:name})}
      for(const id of ["modelChoice","modelEffort","modelContext"])$(id).disabled=disabled||!state.data||state.usesDefaults||Boolean(reason);
      $("modelBudget").textContent=info?.contextWindow?`Advertised maximum: ${modelTokens(info.contextWindow)} tokens. Tier values are input budgets, not total context.`:"";
      $("modelError").textContent=state.loading?"Loading model options...":state.error||reason||(state.data&&modelValidation(state))||state.data?.catalogError||"";
      $("modelSave").disabled=disabled||!state.data||Boolean(reason)||Boolean(state.data&&modelValidation(state))||state.needsReload;
      $("modelReload").disabled=disabled;$("modelRefresh").disabled=disabled;$("modelCancel").disabled=state.saving}
    function editModelSettings(item){if(!item)return;if(item.isLocalPrivate){editPrivateSettings(item);return}modelEditorState={id:item.id,token,data:null,draft:null,usesDefaults:true,loading:false,saving:false,error:"",needsReload:false};
      $("modelTabTitle").textContent=item.title;$("modelEditor").showModal();loadModelSettings(true)}
    async function loadModelSettings(replaceDraft=false,refreshModels=false){const state=modelEditorState;if(!state||state.loading||state.saving)return;state.loading=true;renderModelSettings();
      const current=()=>modelEditorState===state&&token===state.token;
      try{let data=await api(`/api/v1/sessions/${state.id}/model-settings${refreshModels?"?refresh=true":""}`);if(!current())return;
        const revision=replaceDraft?data.revision:state.data?.revision||data.revision;
        for(let attempt=0;data.isRefreshing&&attempt<30;attempt++){await new Promise(resolve=>setTimeout(resolve,1000));if(!current())return;
          data=await api(`/api/v1/sessions/${state.id}/model-settings`);if(!current())return}
        if(data.revision!==revision)throw Error("Model settings changed on another device. Reload before saving.");
        if(data.isRefreshing)throw Error("Model lookup is still running. Reload in a moment.");
        state.data=data;if(replaceDraft){state.draft={...data.selection};state.usesDefaults=data.usesDefaults}state.error="";state.needsReload=false}
      catch(error){if(current()){state.error=`${error.message} Reload settings before saving.`;state.needsReload=true}}
      finally{if(current()){state.loading=false;renderModelSettings()}}}
    $("modelCancel").onclick=()=>{if(modelEditorState?.saving)return;$("modelEditor").close();modelEditorState=null};
    $("modelEditor").addEventListener("cancel",event=>{if(modelEditorState?.saving)event.preventDefault();else modelEditorState=null});
    $("modelReload").onclick=()=>loadModelSettings(true);$("modelRefresh").onclick=()=>loadModelSettings(!modelEditorState?.data,true);
    $("modelDefaults").onchange=()=>{const state=modelEditorState;if(!state?.data)return;state.usesDefaults=$("modelDefaults").checked;if(state.usesDefaults)state.draft={...state.data.defaults};renderModelSettings()};
    $("modelChoice").onchange=()=>{const state=modelEditorState;if(!state?.data)return;state.draft.model=$("modelChoice").value;state.draft.effort="";
      state.draft.contextTier=modelInfo(state)?.contextTiers?.includes("default")?"default":"";renderModelSettings()};
    $("modelEffort").onchange=()=>{if(modelEditorState?.draft){modelEditorState.draft.effort=$("modelEffort").value;renderModelSettings()}};
    $("modelContext").onchange=()=>{if(modelEditorState?.draft){modelEditorState.draft.contextTier=$("modelContext").value;renderModelSettings()}};
    $("modelForm").onsubmit=async event=>{event.preventDefault();const state=modelEditorState;
      if(!state?.data||state.loading||state.saving||state.needsReload||modelValidation(state)||token!==state.token)return;
      const body={revision:state.data.revision,usesDefaults:state.usesDefaults,...(state.usesDefaults?{}:state.draft)};
      state.saving=true;renderModelSettings();
      try{await api(`/api/v1/sessions/${state.id}/model-settings`,{method:"POST",body:JSON.stringify(body)});
        if(modelEditorState===state&&token===state.token){$("modelEditor").close();modelEditorState=null;await refresh()}}
      catch(error){if(modelEditorState===state){state.error=`${error.message} The change may have reached Cantrip. Reload settings before retrying.`;state.needsReload=true}}
      finally{if(modelEditorState===state){state.saving=false;renderModelSettings()}}};
    let editingTab=null,tabSaving=false;
    function editTab(item){editingTab=item;$("tabName").value=item.customTitle||item.title;$("tabLocked").checked=Boolean(item.isLocked);$("tabLocked").disabled=Boolean(item.isLocalPrivate);$("tabModelSettings").textContent=item.isLocalPrivate?"Private Local Settings":"Model Settings";$("tabStartFresh").classList.toggle("hidden",!item.supportsStartFresh);$("tabStartFresh").disabled=Boolean(item.isStreaming||item.queuedCount);$("tabError").textContent=item.isLocalPrivate?"Permanent self-hosted-model tab. History is saved and available remotely.":"";updateTabMoveControls();
      const picker=$("tabSection"),choices=[["","Tabs"],...tabSections.map(section=>[section.id,section.name]),["new","New section…"]];picker.replaceChildren(...choices.map(([value,label])=>{const option=document.createElement("option");option.value=value;option.textContent=label;return option}));
      picker.value=tabSections.some(section=>section.id===item.sectionID)?item.sectionID:"";$("tabNewSection").value="";$("tabNewSection").classList.add("hidden");$("tabSectionLabel").classList.toggle("hidden",!(sectionsSupported&&item.supportsTabSections));$("tabEditor").showModal();$("tabName").focus();$("tabName").select()}
    function updateTabMoveControls(){const index=sessionItems.findIndex(s=>s.id===editingTab?.id);
      $("tabMoveControls").classList.toggle("hidden",!editingTab?.supportsTabReordering);
      $("tabMoveEarlier").textContent=sidebarLayout?"Move up":"Move left";$("tabMoveLater").textContent=sidebarLayout?"Move down":"Move right";
      $("tabMoveEarlier").disabled=movingTab||tabSaving||index<=0;$("tabMoveLater").disabled=movingTab||tabSaving||index<0||index>=sessionItems.length-1}
    $("tabMoveEarlier").onclick=()=>{if(editingTab)moveTabBy(editingTab.id,-1)};
    $("tabMoveLater").onclick=()=>{if(editingTab)moveTabBy(editingTab.id,1)};
    $("tabModelSettings").onclick=()=>{if(editingTab&&!tabSaving&&!movingTab){const item=editingTab;$("tabEditor").close();editingTab=null;editModelSettings(item)}};
    $("tabStartFresh").onclick=async()=>{if(!editingTab||tabSaving||movingTab)return;const item=editingTab;tabSaving=true;$("tabStartFresh").disabled=true;$("tabError").textContent="";
      try{await startFresh(item.id);if(editingTab===item){$("tabEditor").close();editingTab=null}}
      catch(error){$("tabError").textContent=`Start Fresh failed: ${error.message}`}
      finally{tabSaving=false;$("tabStartFresh").disabled=false}};
    async function startFresh(id){await api(`/api/v1/sessions/${id}/start-fresh`,{method:"POST"});renderedPayload="";await refresh()}
    function appendErrorRecovery(row,session){const note=document.createElement("p"),actions=document.createElement("div"),fresh=document.createElement("button"),model=document.createElement("button"),busy=Boolean(session.isStreaming||session.queuedCount);
      note.className="muted";note.textContent="This error happened twice in a row. Start fresh to drop the earlier context, or try another model.";actions.className="error-actions";
      fresh.className="control";fresh.textContent="Start Fresh";fresh.disabled=busy;model.className="control";model.textContent=session.isLocalPrivate?"Private Local Settings":"Change Model";model.disabled=busy;
      fresh.onclick=async()=>{fresh.disabled=true;$("actionError").textContent="";try{await startFresh(session.id)}catch(error){$("actionError").textContent=`Start Fresh failed: ${error.message}`;fresh.disabled=false}};
      model.onclick=()=>editModelSettings(session);actions.append(fresh,model);row.append(note,actions)}
    $("tabMacAccess").onclick=()=>{if(tabSaving||movingTab)return;$("tabEditor").close();editingTab=null;openDesktop()};
    $("tabCancel").onclick=()=>{$("tabEditor").close();editingTab=null};
    $("tabEditor").addEventListener("cancel",event=>{if(tabSaving||movingTab)event.preventDefault()});
    $("tabForm").onsubmit=async event=>{event.preventDefault();if(!editingTab||tabSaving||movingTab)return;const item=editingTab,body={};
      if($("tabName").value!==(item.customTitle||item.title))body.customTitle=$("tabName").value;
      if($("tabLocked").checked!==Boolean(item.isLocked))body.isLocked=$("tabLocked").checked;
      const pickedSection=$("tabSectionLabel").classList.contains("hidden")?null:$("tabSection").value,currentSection=tabSections.some(section=>section.id===item.sectionID)?item.sectionID:"";
      if(pickedSection!==null&&pickedSection!=="new"&&pickedSection!==currentSection)body.sectionID=pickedSection||null;
      const newSectionName=pickedSection==="new"?$("tabNewSection").value:null;
      if(!Object.keys(body).length&&newSectionName===null){$("tabEditor").close();return}tabSaving=true;$("tabSave").disabled=true;$("tabCancel").disabled=true;updateTabMoveControls();
      try{if(newSectionName!==null){const created=await api("/api/v1/sections",{method:"POST",body:JSON.stringify({name:newSectionName})});body.sectionID=created.section.id;tabSections=created.sections}
        await api(`/api/v1/sessions/${item.id}/metadata`,{method:"POST",body:JSON.stringify(body)});$("tabEditor").close();editingTab=null;tabOrderRevision++;await refresh()}
      catch(error){$("tabError").textContent=`${error.message} Refresh the session if the result is uncertain.`}
      finally{tabSaving=false;$("tabSave").disabled=false;$("tabCancel").disabled=false;updateTabMoveControls()}};
    function moveTabBy(id,offset){const index=sessionItems.findIndex(s=>s.id===id),target=sessionItems[index+offset];if(index>=0&&target?.supportsTabReordering)moveTab(id,target.id,offset>0)}
    async function moveTab(id,targetID,after){if(movingTab||tabSaving)return;movingTab=true;tabOrderRevision++;const requestToken=token;
      $("actionError").textContent="";$("tabError").textContent="";$("tabSave").disabled=true;$("tabCancel").disabled=true;updateTabMoveControls();
      try{const data=await api(`/api/v1/sessions/${id}/move`,{method:"POST",body:JSON.stringify({targetID,placement:after?"after":"before"})});
        if(token===requestToken){movingTab=false;if(data.sections)tabSections=data.sections;renderSessions(data.sessions)}}
      catch(error){if(token===requestToken){const message=`${error.message} Refresh the tabs before trying again; the move may have reached Cantrip.`;$("actionError").textContent=message;$("tabError").textContent=message}}
      finally{movingTab=false;$("tabSave").disabled=false;$("tabCancel").disabled=false;updateTabMoveControls();refresh()}}
    let privateEditorState=null;
    function privateBusy(busy){for(const element of $("privateForm").elements)element.disabled=busy;
      $("privateSave").disabled=busy||!privateEditorState?.data||Boolean(privateEditorState?.data?.unavailableReason)||Boolean(privateEditorState?.needsReload)}
    function editPrivateSettings(item){privateEditorState={id:item.id,token,data:null,saving:false,needsReload:false};
      $("privateEditor").showModal();loadPrivateSettings()}
    async function loadPrivateSettings(){const state=privateEditorState;if(!state||state.saving)return;privateBusy(true);
      try{const data=await api(`/api/v1/sessions/${state.id}/private-settings`);if(privateEditorState!==state||token!==state.token)return;
        state.data=data;state.needsReload=false;const c=data.configuration;$("privateURL").value=c.baseURL;$("privateModel").value=c.model;$("privateContext").value=c.contextWindow;$("privatePrompt").value=c.systemPrompt;$("privateModels").replaceChildren();$("privateError").textContent=data.unavailableReason||""}
      catch(error){if(privateEditorState===state){state.needsReload=true;$("privateError").textContent=error.message}}
      finally{if(privateEditorState===state)privateBusy(false)}}
    $("privateReload").onclick=loadPrivateSettings;
    $("privateRefresh").onclick=async()=>{const state=privateEditorState;if(!state?.data||state.saving)return;privateBusy(true);
      try{const data=await api(`/api/v1/sessions/${state.id}/private-models?baseURL=${encodeURIComponent($("privateURL").value)}`);if(privateEditorState!==state||token!==state.token)return;
        $("privateModels").replaceChildren();for(const model of data.models){const option=document.createElement("option");option.value=model;$("privateModels").append(option)}
        $("privateError").textContent=data.models.length?"Server models loaded. Choose an installed model.":"No self-hosted models installed. Install one with Ollama on the selected server."}
      catch(error){if(privateEditorState===state)$("privateError").textContent=error.message}finally{if(privateEditorState===state)privateBusy(false)}};
    $("privateCancel").onclick=()=>{if(privateEditorState?.saving)return;$("privateEditor").close();privateEditorState=null};
    $("privateEditor").addEventListener("cancel",event=>{if(privateEditorState?.saving)event.preventDefault();else privateEditorState=null});
    $("privateForm").onsubmit=async event=>{event.preventDefault();const state=privateEditorState;if(!state?.data||state.saving||state.needsReload||token!==state.token)return;
      const configuration={baseURL:$("privateURL").value,model:$("privateModel").value,contextWindow:Number($("privateContext").value),systemPrompt:$("privatePrompt").value};
      state.saving=true;privateBusy(true);
      try{await api(`/api/v1/sessions/${state.id}/private-settings`,{method:"POST",body:JSON.stringify({revision:state.data.revision,configuration})});
        if(privateEditorState===state&&token===state.token){$("privateEditor").close();privateEditorState=null;await refresh()}}
      catch(error){if(privateEditorState===state){state.needsReload=true;$("privateError").textContent=`${error.message} The change may have reached Cantrip. Reload settings before retrying.`}}
      finally{if(privateEditorState===state){state.saving=false;privateBusy(false)}}};
    let inputState=null;
    function closeInputs(){if(inputState?.saving)return;if(inputState?.timer)clearTimeout(inputState.timer);inputState=null;$("inputCards").replaceChildren();$("inputEditor").close()}
    function showInputs(){if(!selected)return;inputState={id:selected,token,saving:false,timer:null};$("inputCards").replaceChildren();$("inputError").textContent="";$("inputEditor").showModal();loadInputs()}
    async function loadInputs(){const state=inputState;if(!state||state.saving)return;if(state.timer)clearTimeout(state.timer);
      try{const data=await api(`/api/v1/sessions/${state.id}/input`);if(inputState!==state||token!==state.token)return;
        const requests=data.requests.filter(r=>r.kind==="secret"),cards=$("inputCards"),ids=new Set(requests.map(r=>r.id));
        for(const card of Array.from(cards.children))if(!ids.has(card.dataset.id))card.remove();
        for(const request of requests){if(Array.from(cards.children).some(card=>card.dataset.id===request.id))continue;
          const card=document.createElement("section");card.className="input-card";card.dataset.id=request.id;
          const title=document.createElement("strong"),source=document.createElement("span"),detail=document.createElement("pre");
          title.textContent=request.title;source.textContent=request.source;detail.textContent=request.detail;card.append(title,source,detail);
          const field=document.createElement("input");field.type="password";field.autocomplete="off";field.spellcheck=false;
          field.setAttribute("aria-label","Password or passphrase");card.append(field);
          const actions=document.createElement("div");actions.className="tab-actions";
          for(const [label,decision] of [["Cancel","cancel"],["Submit","submit"]]){
            const button=document.createElement("button");button.className="control";button.textContent=label;button.onclick=()=>respondInput(state,request,decision,field);actions.append(button)}
          card.append(actions);cards.append(card)}
        if(!requests.length)$("inputError").textContent="No password is pending. Return to chat for questions and other actions."}
      catch(error){if(inputState===state)$("inputError").textContent=error.message}
      finally{if(inputState===state&&token===state.token)state.timer=setTimeout(loadInputs,2000)}}
    async function respondInput(state,request,decision,field){if(state!==inputState||token!==state.token||state.saving)return;
      const body={decision};if(decision==="submit"){body.text=field.value;if(!body.text)return}if(field)field.value="";
      state.saving=true;for(const control of $("inputEditor").querySelectorAll("button,input,select"))control.disabled=true;
      try{await api(`/api/v1/sessions/${state.id}/input/${request.id}`,{method:"POST",body:JSON.stringify(body)});
        if(inputState===state)$("inputError").textContent="Response submitted."}
      catch(error){if(inputState===state)$("inputError").textContent=`${error.message} Not retried. Reload the pending requests before responding again.`}
      finally{delete body.text;state.saving=false;for(const control of $("inputEditor").querySelectorAll("button,input,select"))control.disabled=false;if(inputState===state){loadInputs();refresh()}}}
    $("inputBanner").onclick=showInputs;$("inputReload").onclick=loadInputs;$("inputDone").onclick=closeInputs;
    $("inputEditor").addEventListener("cancel",event=>{if(inputState?.saving)event.preventDefault();else closeInputs()});
    let chatInputReply=null,chatInputSaving=false;
    // Questions read like replies. Their Mac images sit in one compact row so the answers stay in reach;
    // a bold or heading label right above an image ("**Light — before**") becomes its caption.
    function appendInputDetail(card,request,sessionID){
      if(request.kind!=="question"){if(request.detail){const pre=document.createElement("pre");pre.textContent=request.detail;card.append(pre)}return}
      const images=request.images||[],byID=new Map(images.map(image=>[image.id,image])),tiles=[],removed=new Set();
      const lines=((byID.size&&request.displayText)||request.detail||"").split("\\n");
      lines.forEach((line,index)=>{
        const match=line.match(/^ {0,3}!\\[[^\\]]*\\]\\(cantrip-preview:\\/\\/image\\/([^)\\s]+)\\)\\s*$/),image=match&&byID.get(match[1]);if(!image)return;removed.add(index);
        let above=index-1;while(above>=0&&!lines[above].trim())above--;let caption=(image.altText||"").trim();
        const label=above>=0&&!removed.has(above)&&lines[above].match(/^ {0,3}(?:#{1,6}[ \\t]+(.+?)[ \\t]*#*|\\*\\*([^*]+)\\*\\*|__([^_]+)__)[ \\t]*\\r?$/);
        if(label){const text=(label[1]||label[2]||label[3]).trim().replace(/:$/,"");if(text){removed.add(above);caption=text}}
        if(!tiles.some(tile=>tile.image===image))tiles.push({image,caption:caption||"Image"})});
      const text=lines.filter((line,index)=>!removed.has(index)).join("\\n").trim();
      if(text){const detail=document.createElement("div");detail.className="input-detail";inlineImages=byID.size?{sessionID,images:byID}:null;
        try{appendProse(detail,text)}finally{inlineImages=null}card.append(detail)}
      if(!tiles.length)return;const row=document.createElement("div");row.className="input-images";row.setAttribute("role","group");
      row.setAttribute("aria-label",tiles.length===1?"Image":`${tiles.length} images`);
      for(const {image,caption} of tiles){const figure=document.createElement("figure"),label=document.createElement("figcaption");figure.className="input-image";
        label.textContent=caption;figure.append(macImage(sessionID,image,"preview",caption),label);row.append(figure)}card.append(row)}
    function appendChatInputs(parent,session){
      const requests=session.pendingInputs||[],questions=requests.filter(r=>r.kind==="question");
      const previous=chatInputReply?.sessionID===session.id&&chatInputReply.token===token?chatInputReply:null;
      const chosen=previous?questions.find(r=>r.id===previous.id):null;
      const question=chosen||questions[0];chatInputReply=question?{id:question.id,sessionID:session.id,token}:null;
      $("draft").placeholder=question?`Reply in chat: ${question.title} (not passwords)`:"Message Cantrip...";
      if(previous&&$("draft").value.trim()){
        chatInputReply=previous;
        if(!chosen)$("draft").placeholder="Previous question is no longer waiting. Choose another question or delivery mode.";
      }
      for(const request of requests){const card=document.createElement("section");card.className="input-card";card.dataset.id=request.id;
        const title=document.createElement("strong");title.textContent=request.title;card.append(title);
        const button=(label,action)=>{const node=document.createElement("button");node.className="control";node.textContent=label;node.disabled=chatInputSaving||request.expiresAt<=Date.now()/1000;node.onclick=action;card.append(node)};
        if(request.kind==="secret"){button("Enter password securely",showInputs);parent.append(card);continue}
        appendInputDetail(card,request,session.id);
        const state={sessionID:session.id,token};
        if(request.kind==="question"){
          for(const choice of request.choices)button(choice,()=>respondChatInput(state,request,{decision:"submit",text:choice}));
          if(request.allowsFreeform)button("Reply in chat",()=>{chatInputReply={id:request.id,sessionID:session.id,token};$("mode").value="auto";$("draft").focus()});
        }else if(request.kind==="approval"){
          button("Approve once",()=>respondChatInput(state,request,{decision:"approve"}));button("Deny",()=>respondChatInput(state,request,{decision:"deny"}));
        }else{
          if(request.url){const url=safeURL(request.url);if(url?.startsWith("https:")){const link=document.createElement("a");link.href=url;link.textContent="Open sign-in page";link.target="_blank";link.rel="noopener noreferrer";card.append(link)}}
          if(request.code){const code=document.createElement("pre");code.textContent=`Device code: ${request.code}`;card.append(code)}
          button(request.kind==="login"?"I've signed in":"Done on Mac",()=>respondChatInput(state,request,{decision:"approve"}));
        }
        button("Cancel",()=>respondChatInput(state,request,{decision:"cancel"}));parent.append(card);
      }
    }
    async function respondChatInput(state,request,body){
      if(chatInputSaving||selected!==state.sessionID||token!==state.token)return;chatInputSaving=true;
      try{await api(`/api/v1/sessions/${state.sessionID}/input/${request.id}`,{method:"POST",body:JSON.stringify(body)});if(token===state.token&&selected===state.sessionID){$("actionError").textContent="";await refresh()}}
      catch(error){if(token===state.token&&selected===state.sessionID)$("actionError").textContent=`${error.message} Not retried. Refresh before responding again.`}
      finally{chatInputSaving=false;renderedPayload="";refresh()}
    }
    let desktopState=null;
    const desktopBytes=value=>Uint8Array.from(atob(value),c=>c.charCodeAt(0));
    function desktopBase64(bytes){let result="";for(let i=0;i<bytes.length;i+=8192)result+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(result)}
    function openDesktop(){desktopState={token,lease:null,frame:null,sequence:0,timer:null,saving:false,starting:false,generation:0};$("desktopError").textContent="";$("desktopEditor").showModal();loadDesktopStatus()}
    async function loadDesktopStatus(){const state=desktopState;if(!state)return;
      try{const data=await api("/api/v1/mac-access");if(desktopState!==state||token!==state.token)return;
        $("desktopStart").disabled=!data.desktopEnabled||Boolean(state.lease)||state.starting;
        $("desktopPermissions").replaceChildren();const title=document.createElement("strong");title.textContent=data.name;$("desktopPermissions").append(title);
        if(!data.desktopEnabled)$("desktopError").textContent="Enable View Mac in Cantrip settings on the Mac first. This cannot be enabled remotely.";
        for(const issue of data.issues){const notice=document.createElement("p");notice.textContent=issue.title;$("desktopPermissions").append(notice)}
        for(const permission of data.permissions){const row=document.createElement("div"),label=document.createElement("span"),button=document.createElement("button");
          label.textContent=`${permission.title}: ${permission.state==="granted"?"Granted":permission.state==="notGranted"?"Not granted":permission.state==="restartRequired"?"Reopen Cantrip on the Mac":permission.state==="needsAttention"?"Needs attention":"Check on Mac"} `;
          button.className="control";button.textContent="Open on Mac";button.onclick=async()=>{if(desktopState!==state||token!==state.token)return;button.disabled=true;
            try{await api("/api/v1/mac-access",{method:"POST",body:JSON.stringify({permission:permission.permission})})}
            catch(error){if(desktopState===state)$("desktopError").textContent=error.message}finally{button.disabled=false}};row.append(label,button);$("desktopPermissions").append(row)}}
      catch(error){if(desktopState===state)$("desktopError").textContent=`${error.message} Update and reopen Cantrip if Mac access is unavailable.`}}
    async function startDesktop(){const state=desktopState;if(!state||state.lease||state.starting||token!==state.token)return;
      if(!crypto?.subtle){$("desktopError").textContent="A secure browser context is required for encrypted viewing.";return}
      state.starting=true;const generation=++state.generation;$("desktopStart").disabled=true;
      try{const lease=await api("/api/v1/desktop/start",{method:"POST",body:JSON.stringify({control:$("desktopControl").checked})});
        if(desktopState!==state||token!==state.token||generation!==state.generation){if(token===state.token)await api("/api/v1/desktop/stop",{method:"POST",body:JSON.stringify({id:lease.id,token:lease.token})});return}
        state.lease=lease;state.key=await crypto.subtle.importKey("raw",desktopBytes(lease.key),"AES-GCM",false,["encrypt","decrypt"]);
        if(desktopState!==state||token!==state.token||generation!==state.generation)return;
        $("desktopDisplay").replaceChildren();for(const display of lease.displays){const option=document.createElement("option");option.value=display.id;option.textContent=display.name;$("desktopDisplay").append(option)}
        $("desktopLive").classList.remove("hidden");$("desktopImage").style.width=`${Number($("desktopZoom").value)*100}%`;$("desktopInput").classList.toggle("hidden",!lease.control);$("desktopError").textContent="";refreshDesktop()}
      catch(error){if(desktopState===state)$("desktopError").textContent=`${error.message} Not retried; the Mac may retain a lease for up to 60 seconds.`}
      finally{state.starting=false;if(desktopState===state)$("desktopStart").disabled=Boolean(state.lease)}}
    async function refreshDesktop(){const state=desktopState;if(!state?.lease||document.hidden)return;
      const lease=state.lease,displayID=Number($("desktopDisplay").value);if(state.timer)clearTimeout(state.timer);
      try{const frame=await api("/api/v1/desktop/frame",{method:"POST",body:JSON.stringify({id:lease.id,token:lease.token,displayID})});
        if(desktopState!==state||state.lease!==lease||token!==state.token)return;
        const encrypted=desktopBytes(frame.encryptedJPEG),ad=new TextEncoder().encode(`cantrip-desktop|${lease.id}|${frame.id}|${frame.display.id}|${frame.width}|${frame.height}`);
        const plain=await crypto.subtle.decrypt({name:"AES-GCM",iv:encrypted.slice(0,12),additionalData:ad},state.key,encrypted.slice(12));
        if(desktopState!==state||state.lease!==lease||token!==state.token)return;
        if(Number($("desktopDisplay").value)===displayID){state.frame=frame;$("desktopImage").src=`data:image/jpeg;base64,${desktopBase64(new Uint8Array(plain))}`}}
      catch(error){if(desktopState===state){$("desktopError").textContent=`${error.message} Viewing stopped. Start a new session to reconnect.`;endDesktop(false);return}}
      if(desktopState===state)state.timer=setTimeout(refreshDesktop,1000)}
    async function desktopInput(command){const state=desktopState;if(!state?.lease?.control||!state.frame||state.saving||token!==state.token)return;
      state.saving=true;const lease=state.lease,sequence=++state.sequence;command.frameID=state.frame.id;
      try{const iv=crypto.getRandomValues(new Uint8Array(12)),ad=new TextEncoder().encode(`cantrip-desktop|${lease.id}|input|${sequence}`);
        const cipher=new Uint8Array(await crypto.subtle.encrypt({name:"AES-GCM",iv,additionalData:ad},state.key,new TextEncoder().encode(JSON.stringify(command))));
        const combined=new Uint8Array(iv.length+cipher.length);combined.set(iv);combined.set(cipher,iv.length);
        if(desktopState!==state||token!==state.token||state.lease!==lease)return;
        await api("/api/v1/desktop/input",{method:"POST",body:JSON.stringify({id:lease.id,token:lease.token,sequence,encrypted:desktopBase64(combined)})});
        if(desktopState===state)$("desktopError").textContent="Input sent. Verify the screen; this is not confirmation of macOS authorization."}
      catch(error){if(desktopState===state)$("desktopError").textContent=`${error.message} Input was not retried.`}
      finally{delete command.text;state.saving=false}}
    async function endDesktop(close=true){const state=desktopState;if(!state)return;const lease=state.lease;state.generation++;state.lease=null;state.frame=null;state.key=null;
      if(state.timer)clearTimeout(state.timer);$("desktopImage").removeAttribute("src");$("desktopText").value="";$("desktopLive").classList.add("hidden");$("desktopStart").disabled=false;
      if(close){desktopState=null;$("desktopEditor").close()}
      if(lease&&token===state.token){try{await api("/api/v1/desktop/stop",{method:"POST",body:JSON.stringify({id:lease.id,token:lease.token})})}
        catch(error){$("actionError").textContent="View cleared; the Mac's session may remain until its 60-second idle timeout."}}}
    $("desktopStart").onclick=startDesktop;$("desktopEnd").onclick=()=>endDesktop(false);$("desktopDone").onclick=()=>endDesktop();$("desktopReload").onclick=loadDesktopStatus;
    $("desktopEditor").addEventListener("cancel",()=>endDesktop());$("desktopZoom").onchange=()=>{$("desktopImage").style.width=`${Number($("desktopZoom").value)*100}%`};
    $("desktopDisplay").onchange=()=>{if(desktopState)desktopState.frame=null;$("desktopImage").removeAttribute("src");$("desktopText").value=""};
    $("desktopImage").onclick=event=>{const rect=event.currentTarget.getBoundingClientRect();if(rect.width&&rect.height)desktopInput({kind:$("desktopClick").value,x:(event.clientX-rect.left)/rect.width,y:(event.clientY-rect.top)/rect.height})};
    $("desktopImage").onkeydown=event=>{if(event.key==="Enter"){event.preventDefault();desktopInput({kind:"click",x:0.5,y:0.5})}};
    $("desktopSend").onclick=()=>{const text=$("desktopText").value;$("desktopText").value="";if(text)desktopInput({kind:"text",text})};
    for(const [id,key] of [["desktopReturn","return"],["desktopTab","tab"],["desktopEscape","escape"],["desktopDelete","delete"]])$(id).onclick=()=>desktopInput({kind:"key",key});
    $("desktopUp").onclick=()=>desktopInput({kind:"scroll",delta:3});$("desktopDown").onclick=()=>desktopInput({kind:"scroll",delta:-3});
    document.addEventListener("visibilitychange",()=>{if(document.hidden&&desktopState)endDesktop()});
    addEventListener("pagehide",()=>{if(desktopState)endDesktop()});
    function safeURL(raw,image=false){try{const url=new URL(raw,location.href);if(url.protocol==="https:"||url.protocol==="http:"||(!image&&url.protocol==="mailto:"))return url.href}catch{}return null}
    function appendInline(parent,source){source=source.replace(/<br\\s*\\/?\\s*>/gi,"\\n");let cursor=0,plain="";
      const flush=()=>{if(plain){parent.append(document.createTextNode(plain));plain=""}};
      const paired=(marker,tag)=>{const end=source.indexOf(marker,cursor+marker.length);if(end<0)return false;flush();const node=document.createElement(tag);appendInline(node,source.slice(cursor+marker.length,end));parent.append(node);cursor=end+marker.length;return true};
      while(cursor<source.length){if(source[cursor]==="\\\\"&&cursor+1<source.length){plain+=source[cursor+1];cursor+=2;continue}
        if(source[cursor]==="`"){const end=source.indexOf("`",cursor+1);if(end>=0){flush();const code=document.createElement("code");code.textContent=source.slice(cursor+1,end);parent.append(code);cursor=end+1;continue}}
        const image=source.slice(cursor).match(/^!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+["'][^"']*["'])?\\)/);
        if(image){const preview=inlineImages&&image[2].startsWith("cantrip-preview://image/")?inlineImages.images.get(image[2].slice(24)):null,imageURL=/^https?:\\/\\//i.test(image[2])&&safeURL(image[2],true);flush();
          if(preview)parent.append(macImage(inlineImages.sessionID,preview,"preview",image[1]||preview.altText||"Generated image"));
          else if(imageURL){const img=document.createElement("img");img.alt=image[1];img.src=imageURL;img.loading="lazy";parent.append(img)}
          // Mac file paths are not served; show the description instead of a broken image.
          else{const note=document.createElement("span");note.className="image-unavailable";note.textContent=image[1]?`Image on the Mac: ${image[1]}`:"Image on the Mac";parent.append(note)}
          cursor+=image[0].length;continue}
        const link=source.slice(cursor).match(/^\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+["'][^"']*["'])?\\)/),linkPreview=link&&inlineImages&&link[2].startsWith("cantrip-preview://image/")?inlineImages.images.get(link[2].slice(24)):null;
        if(linkPreview){flush();parent.append(previewLink(inlineImages.sessionID,linkPreview,link[1]));cursor+=link[0].length;continue}
        const linkURL=link&&safeURL(link[2]);if(linkURL){flush();const anchor=document.createElement("a");anchor.href=linkURL;anchor.target="_blank";anchor.rel="noopener noreferrer";appendInline(anchor,link[1]);parent.append(anchor);cursor+=link[0].length;continue}
        const auto=source.slice(cursor).match(/^<(https?:\\/\\/[^ >]+|mailto:[^ >]+)>/),autoURL=auto&&safeURL(auto[1]);if(autoURL){flush();const anchor=document.createElement("a");anchor.href=autoURL;anchor.target="_blank";anchor.rel="noopener noreferrer";anchor.textContent=auto[1];parent.append(anchor);cursor+=auto[0].length;continue}
        if(source.startsWith("**",cursor)&&paired("**","strong"))continue;if(source.startsWith("__",cursor)&&paired("__","strong"))continue;if(source.startsWith("~~",cursor)&&paired("~~","del"))continue;
        if(source[cursor]==="*"&&paired("*","em"))continue;if(source[cursor]==="_"&&paired("_","em"))continue;
        if(source[cursor]==="\\n"){flush();parent.append(document.createElement("br"));cursor++;continue}plain+=source[cursor++]}
      flush()}
    function listLine(line){const match=line.match(/^(\\s*)([-*+]|\\d+[.)])\\s+(.+)$/);return match?{indent:Math.floor(match[1].length/2),ordered:/^\\d/.test(match[2]),start:parseInt(match[2],10)||1,text:match[3]}:null}
    function tableCells(line){let text=line.trim();if(text.startsWith("|"))text=text.slice(1);if(text.endsWith("|"))text=text.slice(0,-1);return text.split("|").map(cell=>cell.trim())}
    // MCP App views (e.g. Mobbin galleries): each runs in a frame sandboxed to an
    // opaque origin (never allow-same-origin: this page holds the pairing token).
    const mcpMaxHeight=640,mcpApps=new Map(),mcpHeights=new Map(),mcpDark=matchMedia("(prefers-color-scheme: dark)"),mcpCoarse=matchMedia("(pointer: coarse)");
    function mcpAppSlot(sessionID,app){const slot=document.createElement("div");slot.dataset.mcpSession=sessionID;slot.dataset.mcpApp=JSON.stringify(app);return slot}
    function mcpReconcile(live,staged){
      const nodes=[...staged.childNodes].map(node=>node.dataset?.mcpApp?mcpAppElement(node.dataset.mcpSession,JSON.parse(node.dataset.mcpApp)):node),keep=new Set(nodes);
      for(const child of [...live.childNodes])if(!keep.has(child))child.remove();
      let cursor=live.firstChild;for(const node of nodes){if(node===cursor){cursor=cursor.nextSibling;continue}live.insertBefore(node,cursor)}
      for(const [key,state] of mcpApps)if(!state.element.isConnected){state.stopped=true;mcpApps.delete(key)}}
    async function mcpFetch(path,options={}){const headers={Authorization:`Bearer ${token}`};if(options.body)headers["Content-Type"]="application/json";
      const response=await fetch(path,{...options,headers}),data=await response.json().catch(()=>({}));if(!response.ok)throw Error(data.error||`HTTP ${response.status}`);return data}
    function mcpAppElement(sessionID,app){const key=`${sessionID}:${app.id}`;let state=mcpApps.get(key);if(state)return state.element;
      const figure=document.createElement("figure"),caption=document.createElement("figcaption"),status=document.createElement("div"),label=`${app.serverName||"MCP app"} · ${app.title||app.toolName}`;
      figure.className="mcp-app";caption.textContent=label;caption.title=`Interactive view from ${app.serverName||"an MCP server"}, shown in a sandbox`;status.className="mcp-app-status";status.textContent="Loading view…";status.setAttribute("role","status");figure.append(caption,status);
      state={key,app,label,element:figure,status,frame:null,payload:null,base:`/api/v1/sessions/${sessionID}/apps/${encodeURIComponent(app.id)}`,sentData:false,initialized:false,loads:0,stopped:false};
      mcpApps.set(key,state);mcpLoad(state);return figure}
    async function mcpLoad(state){try{state.payload=await mcpFetch(state.base);const view=await mcpFetch(`${state.base}/view`,{method:"POST"});if(state.stopped)return;
        const frame=document.createElement("iframe");frame.setAttribute("sandbox","allow-scripts allow-forms");frame.setAttribute("referrerpolicy","no-referrer");
        if((state.payload.permissions||[]).includes("clipboardWrite"))frame.setAttribute("allow","clipboard-write");
        frame.title=`Interactive view: ${state.label}`;frame.style.height=`${mcpHeights.get(state.key)||150}px`;frame.src=view.url;
        frame.addEventListener("load",()=>{if(++state.loads>1)mcpStop(state,"This view tried to leave its page, so it was closed. Reload the conversation to show it again.")});
        state.frame=frame;state.status.replaceWith(frame);new ResizeObserver(()=>mcpContext(state,{containerDimensions:{width:frame.clientWidth,maxHeight:mcpMaxHeight}})).observe(frame)}
      catch(error){state.status.textContent=`Could not load this view: ${error.message}`}}
    function mcpStop(state,reason){state.stopped=true;state.frame?.remove();state.frame=null;state.status.textContent=reason;state.element.append(state.status)}
    function mcpSend(state,message){state.frame?.contentWindow?.postMessage({jsonrpc:"2.0",...message},"*")}
    function mcpContext(state,changes){if(state.initialized&&!state.stopped)mcpSend(state,{method:"ui/notifications/host-context-changed",params:changes})}
    mcpDark.addEventListener("change",()=>{for(const state of mcpApps.values())mcpContext(state,{theme:mcpDark.matches?"dark":"light"})});
    function mcpText(content){const blocks=Array.isArray(content)?content:content&&typeof content==="object"?[content]:[];
      return blocks.filter(block=>block?.type==="text"&&typeof block.text==="string").map(block=>block.text).join("\\n\\n").trim()}
    function mcpMessageText(text){return text.replace(/[\\u00AD\\u061C\\u180E\\u200B-\\u200F\\u202A-\\u202E\\u2060-\\u2064\\u2066-\\u206F\\uFEFF]/g,"").replace(/[^\\S\\n]+/g," ").replace(/ *\\n\\s*\\n\\s*/g,"\\n\\n").trim().slice(0,2000)}
    function mcpExternalURL(raw){try{const url=new URL(String(raw));return (url.protocol==="https:"||url.protocol==="http:")&&url.hostname&&!url.username&&!url.password?url.href:null}catch{return null}}
    function mcpOpen(state,url){const link=document.createElement("a");link.href=url;link.target="_blank";link.rel="noopener noreferrer";link.click();
      let note=state.element.querySelector(".mcp-app-link");if(!note){note=document.createElement("a");note.className="mcp-app-link";note.target="_blank";note.rel="noopener noreferrer";state.element.append(note)}
      note.href=url;note.textContent=`Open ${new URL(url).host} ↗`}
    function mcpInitialize(state){const payload=state.payload,permissions=Object.fromEntries((payload.permissions||[]).map(name=>[name,{}]));let tool;try{tool=JSON.parse(payload.tool)}catch{tool={name:payload.toolName,inputSchema:{type:"object"}}}
      return {protocolVersion:"2026-01-26",hostInfo:{name:"Cantrip Remote",version:"1.0"},
        hostCapabilities:{openLinks:{},logging:{},serverTools:{},serverResources:{},message:{text:{}},updateModelContext:{text:{},structuredContent:{}},sandbox:{csp:payload.csp||{},permissions}},
        hostContext:{toolInfo:{tool},theme:mcpDark.matches?"dark":"light",displayMode:"inline",availableDisplayModes:["inline"],containerDimensions:{width:state.frame.clientWidth,maxHeight:mcpMaxHeight},
          locale:navigator.language,timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,userAgent:"Cantrip Remote",platform:mcpCoarse.matches?"mobile":"web",
          deviceCapabilities:{touch:mcpCoarse.matches,hover:matchMedia("(hover: hover)").matches},styles:{variables:{"--font-sans":"-apple-system, BlinkMacSystemFont, system-ui, sans-serif","--font-mono":"ui-monospace, Menlo, monospace"}}}}}
    function mcpPost(state,path,body){return mcpFetch(`${state.base}/${path}`,{method:"POST",body:JSON.stringify(body)})}
    function mcpReceive(state,message){if(!message||message.jsonrpc!=="2.0"||typeof message.method!=="string"||state.stopped||!state.payload)return;
      const params=message.params&&typeof message.params==="object"?message.params:{},id=message.id;
      if(id===undefined){if(message.method==="ui/notifications/initialized"){state.initialized=true;if(!state.sentData){state.sentData=true;let input={},result={content:[]};try{input=JSON.parse(state.payload.toolInput);result=JSON.parse(state.payload.toolResult)}catch{}
          mcpSend(state,{method:"ui/notifications/tool-input",params:{arguments:input}});mcpSend(state,{method:"ui/notifications/tool-result",params:result})}}
        else if(message.method==="ui/notifications/size-changed"&&Number(params.height)>0&&state.frame){const height=Math.min(mcpMaxHeight,Math.max(48,Math.ceil(Number(params.height))));state.frame.style.height=`${height}px`;mcpHeights.set(state.key,height)}
        else if(message.method==="notifications/message")console.debug(`${state.app.serverName} view:`,params.data);return}
      if(typeof id!=="string"&&typeof id!=="number")return;
      const reply=result=>mcpSend(state,{id,result}),fail=(code,text)=>mcpSend(state,{id,error:{code,message:text}});
      switch(message.method){
        case "ui/initialize":state.initialized=false;state.sentData=false;reply(mcpInitialize(state));break;
        case "ping":reply({});break;
        case "ui/request-display-mode":reply({mode:"inline"});break;
        case "ui/open-link":{const url=mcpExternalURL(params.url);if(!url){fail(-32602,"Invalid URL");break}mcpOpen(state,url);reply({});break}
        case "ui/message":{const text=mcpMessageText(mcpText(params.content));if((params.role&&params.role!=="user")||!text){fail(-32602,"Invalid message format");break}
          if(!confirm(`Send this message from ${state.app.serverName||"the MCP app"} to the model as your next message?\\n\\n${text}`)){fail(-32000,"Message sending denied");break}
          mcpPost(state,"message",{text}).then(()=>reply({}),error=>fail(-32000,error.message));break}
        case "ui/update-model-context":{const parts=[mcpText(params.content)];if(params.structuredContent&&typeof params.structuredContent==="object"&&Object.keys(params.structuredContent).length)parts.push(JSON.stringify(params.structuredContent));
          const text=parts.filter(Boolean).join("\\n").slice(0,8000);mcpPost(state,"context",{text:text||null}).then(()=>reply({}),error=>fail(-32000,error.message));break}
        case "tools/call":case "tools/list":case "resources/read":mcpPost(state,"request",{method:message.method,params}).then(data=>reply(data.result||{}),error=>fail(-32000,error.message));break;
        default:fail(-32601,`Method not found: ${message.method}`)}}
    window.addEventListener("message",event=>{for(const state of mcpApps.values())if(state.frame&&event.source===state.frame.contentWindow){mcpReceive(state,event.data);return}});
    // Mac images (generated previews, iPhone uploads) load through the paired API as
    // data URLs. Each keeps one element so transcript re-renders never refetch or flicker.
    const macImages=new Map(),macImageStates=new WeakMap(),macImageData=new Map();let inlineImages=null,viewerState=null,viewerRequest=0;
    const macImageObserver="IntersectionObserver" in window?new IntersectionObserver(entries=>{for(const entry of entries)if(entry.isIntersecting){macImageObserver.unobserve(entry.target);const state=macImageStates.get(entry.target);if(state)loadMacImage(state)}},{rootMargin:"900px 0px"}):null;
    function macImagePath(sessionID,id,full){return `/api/v1/sessions/${encodeURIComponent(sessionID)}/${id.startsWith("previews/")?"":"attachments/"}${id.split("/").map(encodeURIComponent).join("/")}${full?"":"/thumbnail"}`}
    function macImage(sessionID,image,kind,label){const key=`${sessionID}:${image.id}`;let state=macImages.get(key);
      if(!state){const button=document.createElement("button"),status=document.createElement("span");button.type="button";button.className=`mac-image ${kind}`;status.className="mac-image-status";status.textContent=kind==="preview"?"Loading preview…":"Loading…";button.append(status);
        state={key,sessionID,id:image.id,kind,label,button,status,img:null,loading:false,error:null};macImageStates.set(button,state);macImages.set(key,state);
        button.onclick=()=>{if(state.img)openImageViewer(state);else if(state.error)loadMacImage(state)};
        if(macImageObserver)macImageObserver.observe(button);else loadMacImage(state)}
      state.label=label;macImageLabel(state);return state.button}
    // A Markdown link to a Mac image opens the same full-size viewer as an inline preview.
    function previewLink(sessionID,image,text){const button=document.createElement("button");button.type="button";button.className="preview-link";button.setAttribute("aria-haspopup","dialog");appendInline(button,text);
      const label=image.altText||button.textContent||"Preview";button.onclick=()=>{const key=`${sessionID}:${image.id}`;openImageViewer(macImages.get(key)||{key,sessionID,id:image.id,kind:"preview",label,img:null})};return button}
    function macImageLabel(state){state.button.setAttribute("aria-label",state.error?`${state.label}. Could not load. Activate to retry.`:state.img?`${state.label}. Open full size.`:`${state.label}. Loading.`);if(state.img)state.img.alt=state.label}
    async function loadMacImage(state){if(state.loading||state.img)return;state.loading=true;state.error=null;state.button.classList.remove("failed");state.status.textContent=state.kind==="preview"?"Loading preview…":"Loading…";macImageLabel(state);const requestToken=token;
      try{let url=macImageData.get(state.key);if(!url){const data=await mcpFetch(macImagePath(state.sessionID,state.id,false));url=`data:image/jpeg;base64,${data.data}`}
        if(requestToken!==token)return;macImageData.delete(state.key);macImageData.set(state.key,url);while(macImageData.size>48)macImageData.delete(macImageData.keys().next().value);
        const img=document.createElement("img");img.src=url;await img.decode().catch(()=>{});state.img=img;state.status.replaceWith(img);state.button.removeAttribute("title");
        if(followOutput&&state.button.isConnected){const root=document.scrollingElement||document.documentElement;root.scrollTop=root.scrollHeight}}
      catch(error){if(requestToken!==token)return;state.error=error.message||"Could not load the image.";state.button.classList.add("failed");state.status.textContent=state.kind==="preview"?`Preview unavailable. ${state.error} Tap or click to retry.`:"Retry";state.button.title=state.error}
      finally{state.loading=false;macImageLabel(state)}}
    function pruneMacImages(){for(const [key,state] of macImages)if(!state.button.isConnected){macImageObserver?.unobserve(state.button);macImages.delete(key)}}
    function clearMacImages(){for(const state of macImages.values())macImageObserver?.unobserve(state.button);macImages.clear();macImageData.clear();if($("imageViewer").open)$("imageViewer").close()}
    function appendAttachments(parent,sessionID,images){const grid=document.createElement("div");grid.className="mac-image-grid";images.forEach((image,index)=>grid.append(macImage(sessionID,image,"attachment",`Attached image ${index+1}`)));parent.append(grid)}
    function setImageZoom(zoomed,point){const viewer=$("imageViewer"),stage=$("imageStage"),img=$("imageFull");if(!img.naturalWidth)return;const before=img.getBoundingClientRect();
      viewer.classList.toggle("zoomed",zoomed);$("imageZoom").textContent=zoomed?"Fit to screen":"Actual size";$("imageZoom").setAttribute("aria-pressed",String(zoomed));
      if(zoomed&&point&&before.width){const x=(point.x-before.left)/before.width,y=(point.y-before.top)/before.height;stage.scrollLeft=x*img.naturalWidth-stage.clientWidth/2;stage.scrollTop=y*img.naturalHeight-stage.clientHeight/2}
      else if(zoomed){stage.scrollLeft=(stage.scrollWidth-stage.clientWidth)/2;stage.scrollTop=(stage.scrollHeight-stage.clientHeight)/2}}
    function updateImageZoomControl(){const stage=$("imageStage"),img=$("imageFull"),fits=!img.naturalWidth||(img.naturalWidth<=stage.clientWidth&&img.naturalHeight<=stage.clientHeight);$("imageZoom").disabled=fits&&!$("imageViewer").classList.contains("zoomed");img.style.cursor=fits?"default":""}
    async function loadViewerImage(){const state=viewerState,request=++viewerRequest,requestToken=token,img=$("imageFull");if(!state)return;$("imageRetry").classList.add("hidden");$("imageStatus").textContent=state.img?"":"Loading image…";
      try{const src=state.load?await state.load():`data:image/jpeg;base64,${(await mcpFetch(macImagePath(state.sessionID,state.id,true))).data}`;if(request!==viewerRequest||requestToken!==token||!$("imageViewer").open)return;img.src=src;const decoded=await img.decode().then(()=>true,()=>false);
        if(request!==viewerRequest)return;if(!decoded){if(state.img)img.src=state.img.src;else img.classList.add("hidden");$("imageStatus").textContent=state.img?"Showing a smaller copy. This browser can't display the full image.":"This browser can't display this image.";updateImageZoomControl();return}$("imageStatus").textContent="";img.classList.remove("hidden");updateImageZoomControl()}
      catch(error){if(request!==viewerRequest||requestToken!==token)return;$("imageStatus").textContent=state.img?`Showing a smaller copy. The full image could not load: ${error.message}`:`Image unavailable. ${error.message}`;$("imageRetry").classList.remove("hidden");if(!state.img)img.classList.add("hidden")}}
    function openImageViewer(state){viewerState=state;const img=$("imageFull");$("imageViewer").classList.remove("zoomed");$("imageZoom").textContent="Actual size";$("imageZoom").setAttribute("aria-pressed","false");
      $("imageViewerTitle").textContent=state.kind==="preview"?(state.label||"Preview"):state.label;img.alt=state.label;img.classList.toggle("hidden",!state.img);if(state.img)img.src=state.img.src;else img.removeAttribute("src");
      $("imageViewer").showModal();$("imageDone").focus();updateImageZoomControl();loadViewerImage()}
    $("imageDone").onclick=()=>$("imageViewer").close();$("imageRetry").onclick=()=>loadViewerImage();
    $("imageZoom").onclick=()=>setImageZoom(!$("imageViewer").classList.contains("zoomed"));
    $("imageFull").addEventListener("click",event=>{if(!$("imageZoom").disabled)setImageZoom(!$("imageViewer").classList.contains("zoomed"),{x:event.clientX,y:event.clientY})});
    $("imageViewer").addEventListener("close",()=>{viewerRequest++;viewerState=null;$("imageFull").removeAttribute("src");$("imageStatus").textContent="";$("imageViewer").classList.remove("zoomed")});
    addEventListener("resize",()=>{if($("imageViewer").open)updateImageZoomControl()});
    function appendProse(parent,source){const prose=document.createElement("div");prose.className="prose";const lines=source.split("\\n");let index=0,paragraph=[];
      const flush=()=>{if(!paragraph.length)return;const p=document.createElement("p");appendInline(p,paragraph.join(" "));prose.append(p);paragraph=[]};
      while(index<lines.length){const line=lines[index],trimmed=line.trim();if(!trimmed){flush();index++;continue}
        if(trimmed.startsWith("```")){flush();index++;const codeLines=[];while(index<lines.length&&!lines[index].trim().startsWith("```"))codeLines.push(lines[index++]);if(index<lines.length)index++;const pre=document.createElement("pre"),code=document.createElement("code");code.textContent=codeLines.join("\\n");pre.append(code);prose.append(pre);continue}
        const heading=trimmed.match(/^(#{1,6})\\s+(.+)$/);if(heading){flush();const level=Math.min(3,heading[1].length),node=document.createElement(`h${level}`);appendInline(node,heading[2]);prose.append(node);index++;continue}
        if(/^(---+|\\*\\*\\*+|___+)$/.test(trimmed)){flush();prose.append(document.createElement("hr"));index++;continue}
        if(trimmed.startsWith(">")){flush();const quoted=[];while(index<lines.length&&lines[index].trim().startsWith(">"))quoted.push(lines[index++].trim().replace(/^>\\s?/,""));const quote=document.createElement("blockquote");appendProse(quote,quoted.join("\\n"));prose.append(quote);continue}
        if(trimmed.includes("|")&&index+1<lines.length&&/^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?\\s*$/.test(lines[index+1])){flush();const table=document.createElement("table"),head=document.createElement("thead"),headRow=document.createElement("tr");for(const cell of tableCells(line)){const th=document.createElement("th");appendInline(th,cell);headRow.append(th)}head.append(headRow);table.append(head);index+=2;const body=document.createElement("tbody");while(index<lines.length&&lines[index].includes("|")&&lines[index].trim()){const row=document.createElement("tr");for(const cell of tableCells(lines[index++])){const td=document.createElement("td");appendInline(td,cell);row.append(td)}body.append(row)}table.append(body);prose.append(table);continue}
        const item=listLine(line);if(item){flush();const list=document.createElement(item.ordered?"ol":"ul");if(item.ordered)list.start=item.start;while(index<lines.length){const next=listLine(lines[index]);if(!next||next.ordered!==item.ordered)break;const li=document.createElement("li");li.style.marginLeft=`${next.indent*16}px`;appendInline(li,next.text);list.append(li);index++}prose.append(list);continue}
        paragraph.push(trimmed);index++}flush();parent.append(prose)}
    const subagentStatusText={queued:"Queued",running:"Running",idle:"Waiting",completed:"Done",failed:"Failed",cancelled:"Stopped"},subagentErrors=new Map();
    function subagentActive(agent){return agent.status==="queued"||agent.status==="running"||agent.status==="idle"}
    function subagentName(agent){return agent.name||(agent.agentType?agent.agentType.split("-").map(word=>word.charAt(0).toUpperCase()+word.slice(1)).join(" "):"Subagent")}
    function subagentElapsed(agent,now=Date.now()/1000){const seconds=Math.max(0,Math.floor((agent.finishedAt??now)-(agent.startedAt??now)));if(seconds<60)return `${seconds}s`;if(seconds<3600)return `${Math.floor(seconds/60)}m ${String(seconds%60).padStart(2,"0")}s`;return `${Math.floor(seconds/3600)}h ${String(Math.floor(seconds%3600/60)).padStart(2,"0")}m`}
    function subagentTokens(tokens){return tokens<1000?`${tokens} tokens`:tokens<1000000?`${(tokens/1000).toFixed(1)}k tokens`:`${(tokens/1000000).toFixed(1)}M tokens`}
    function subagentMeta(agent){const parts=[subagentStatusText[agent.status]||"Working",subagentElapsed(agent)];if(agent.steps>0)parts.push(`${agent.steps} ${agent.steps===1?"step":"steps"}`);if(agent.tokens>0)parts.push(subagentTokens(agent.tokens));if(agent.model)parts.push(agent.effort?`${agent.model} (${agent.effort})`:agent.model);return parts.join(" · ")}
    function subagentIcon(status){const state=status==="completed"?"succeeded":status==="queued"||status==="idle"||status==="running"||status==="failed"||status==="cancelled"?status:"running",icon=statusIcon(state==="idle"||state==="queued"?"idle":state);if(state==="idle")icon.textContent="‖";if(state==="queued")icon.textContent="◷";icon.setAttribute("aria-hidden","true");return icon}
    async function stopSubagent(sessionID,agent,button){if(!confirm(`Stop ${subagentName(agent)}? The rest of the reply keeps going.`))return;const requestToken=token;button.disabled=true;subagentErrors.delete(agent.agentID);
      try{const data=await api(`/api/v1/sessions/${encodeURIComponent(sessionID)}/subagents/${encodeURIComponent(agent.agentID)}/cancel`,{method:"POST",body:"{}"});if(data&&data.cancelled===false)subagentErrors.set(agent.agentID,"It had already finished.")}
      catch(error){if(token===requestToken)subagentErrors.set(agent.agentID,error.message||"Could not stop this subagent.")}finally{button.disabled=false;if(token===requestToken){renderedPayload=null;await refresh()}}}
    function subagentCard(sessionID,agent,messageID){const card=document.createElement("section"),active=subagentActive(agent),name=subagentName(agent);card.className=`subagent${active?" active":""}`;card.setAttribute("aria-label",`${name} subagent, ${subagentMeta(agent)}`);
      const head=document.createElement("div");head.className="subagent-head";head.append(subagentIcon(agent.status));const title=document.createElement("div");title.className="subagent-title";const strong=document.createElement("strong");strong.textContent=name;title.append(strong);
      for(const label of [agent.agentType,agent.background?"Background":""]){if(!label)continue;const badge=document.createElement("span");badge.className="subagent-badge";badge.textContent=label;title.append(badge)}head.append(title);
      if(active&&agent.canCancel){const stop=document.createElement("button");stop.className="control subagent-stop";stop.textContent="Stop";stop.title="Stop only this subagent. The reply keeps going.";stop.setAttribute("aria-label",`Stop ${name}`);stop.onclick=()=>stopSubagent(sessionID,agent,stop);head.append(stop)}card.append(head);
      const body=document.createElement("div");body.className="subagent-body";const line=(className,text)=>{const element=document.createElement("div");element.className=className;element.textContent=text;body.append(element);return element};
      if(agent.summary&&agent.summary!==agent.name)line("subagent-summary",agent.summary);if(agent.status==="queued")line("subagent-queued","Starts when the main agent waits for it or finishes its turn.");const now=agent.intent||agent.currentStep;if(agent.status==="running"&&now)line("subagent-now",`Now: ${now}`);
      const meta=line("subagent-meta",subagentMeta(agent));if(active)meta.dataset.live=JSON.stringify({status:agent.status,startedAt:agent.startedAt,steps:agent.steps,tokens:agent.tokens,model:agent.model,effort:agent.effort});
      if(agent.error)line("subagent-error",`⚠ ${agent.error}`);const stopError=subagentErrors.get(agent.agentID);if(stopError)line("subagent-error",stopError);
      const steps=agent.recentSteps||[];if(steps.length||agent.latestMessage){const details=remember(document.createElement("details"),`subagent:${messageID}:${agent.id}`);details.className="disclosure";const summary=document.createElement("summary");summary.textContent=steps.length?(agent.steps>steps.length?`Latest ${steps.length} of ${agent.steps} steps`:`${steps.length} ${steps.length===1?"step":"steps"}`):"Latest message";details.append(summary);
        const inner=document.createElement("div");inner.className="disclosure-body";if(agent.latestMessage){const latest=document.createElement("p");latest.className="subagent-latest";latest.textContent=agent.latestMessage;inner.append(latest)}
        for(const step of steps){const row=document.createElement("div");row.className="subagent-step";row.append(statusIcon(step.state||"running"));const text=document.createElement("span");text.className="step-title";text.textContent=step.title||step.toolName;const tool=document.createElement("span");tool.className="tool-name";tool.textContent=step.toolName||"";row.append(text,tool);inner.append(row)}details.append(inner);body.append(details)}
      card.append(body);return card}
    function appendSubagents(parent,agents,sessionID,messageID,block=0){if(!agents.length)return;const box=document.createElement("div");box.className="subagents";const active=agents.filter(subagentActive),finished=agents.filter(agent=>!subagentActive(agent));
      if(agents.length<=3){for(const agent of agents)box.append(subagentCard(sessionID,agent,messageID))}
      else{for(const agent of active)box.append(subagentCard(sessionID,agent,messageID));if(finished.length){const details=remember(document.createElement("details"),`subagents:${messageID}${block?`:${block}`:""}`);details.className="disclosure";const summary=document.createElement("summary");summary.textContent=`${finished.length} finished ${finished.length===1?"subagent":"subagents"}`;details.append(summary);const inner=document.createElement("div");inner.className="subagents";for(const agent of finished)inner.append(subagentCard(sessionID,agent,messageID));details.append(inner);box.append(details)}}
      parent.append(box)}
    // A finished card follows the reply block that was streaming when its agent ended (split as in ReplyBlocks.swift).
    function replyBlockStarts(text){const starts=[];let offset=0,fence="",afterBlank=true;for(const line of text.split("\\n")){const trimmed=line.trim();if(fence){if(trimmed.startsWith(fence))fence="";afterBlank=false}else if(!trimmed)afterBlank=true;else{if(afterBlank)starts.push(offset);afterBlank=false;if(trimmed.startsWith("```")||trimmed.startsWith("~~~"))fence=trimmed.slice(0,3)}offset+=line.length+1}return starts}
    function appendReply(row,message,settled,session){const images=message.images||[],text=(images.length&&message.displayText)||message.text||"";inlineImages=images.length&&!session.isLocalPrivate?{sessionID:session.id,images:new Map(images.map(image=>[image.id,image]))}:null;try{appendReplyText(row,message,text,settled,session)}finally{inlineImages=null}}
    function appendReplyText(row,message,text,settled,session){const appendText=part=>{if(!part)return;if(session.isLocalPrivate){const pre=document.createElement("pre");pre.textContent=part;row.append(pre)}else appendProse(row,part)};
      if(!settled.length){appendText(text);return}const groups=new Map();for(const agent of settled){const block=Math.max(0,agent.textBlock??0);if(!groups.has(block))groups.set(block,[]);groups.get(block).push(agent)}
      const starts=replyBlockStarts(text);let from=0;for(const block of [...groups.keys()].sort((a,b)=>a-b)){const to=Math.max(from,block===0?0:block<starts.length?starts[block]:text.length);appendText(text.slice(from,to).replace(/\\s+$/,""));from=to;appendSubagents(row,groups.get(block),session.id,message.id,block)}appendText(text.slice(from))}
    // Running subagents stay pinned at the bottom of the chat; finished ones return to their reply.
    function renderPinnedSubagents(sessionID,pinned){const bar=$("liveSubagents");bar.replaceChildren(...pinned.map(([agent,messageID])=>subagentCard(sessionID,agent,messageID)));bar.classList.toggle("hidden",!pinned.length)}
    setInterval(()=>{for(const meta of document.querySelectorAll(".subagent-meta[data-live]")){try{meta.textContent=subagentMeta(JSON.parse(meta.dataset.live))}catch{}}},1000);
    function statusIcon(state){const icon=document.createElement("span");icon.className=`status-icon ${state}`;icon.textContent=state==="running"?"•":state==="succeeded"?"✓":state==="failed"?"×":"–";return icon}
    function remember(details,key){details.open=expanded.has(key);details.addEventListener("toggle",()=>{if(details.open)expanded.add(key);else expanded.delete(key)});return details}
    function appendDetail(parent,label,value){if(!value)return;const section=document.createElement("section"),title=document.createElement("div"),content=document.createElement("pre");title.className="detail-label";title.textContent=label;content.textContent=value;section.append(title,content);parent.append(section)}
    function appendActivity(parent,activity,messageID){const hasDetails=Boolean(activity.input||activity.output),row=document.createElement(hasDetails?"details":"div");row.className="step";
      const head=document.createElement(hasDetails?"summary":"div");if(!hasDetails)head.className="step-static";head.append(statusIcon(activity.state));const title=document.createElement("span");title.className="step-title";title.textContent=activity.title||activity.toolName;const tool=document.createElement("span");tool.className="tool-name";tool.textContent=activity.toolName;head.append(title,tool);row.append(head);
      if(hasDetails){remember(row,`activity:${messageID}:${activity.id}`);const body=document.createElement("div");body.className="step-details";appendDetail(body,"Input",activity.input);appendDetail(body,"Output",activity.output);row.append(body)}parent.append(row)}
    function appendActivities(parent,activities,messageID){if(!activities.length)return;const disclosure=remember(document.createElement("details"),`steps:${messageID}`);disclosure.className="disclosure steps";
      const states=activities.map(item=>item.state),state=states.includes("running")?"running":states.includes("failed")?"failed":states.includes("cancelled")?"cancelled":"succeeded";const summary=document.createElement("summary");summary.append(statusIcon(state));
      const label=document.createElement("span");const noun=activities.length===1?"step":"steps";label.textContent=state==="running"?`Working · ${activities.length} ${noun}`:`${activities.length} ${noun}`;summary.append(label);disclosure.append(summary);
      const body=document.createElement("div");body.className="disclosure-body";for(const activity of activities)appendActivity(body,activity,messageID);disclosure.append(body);parent.append(disclosure)}
    function appendThinking(parent,text,messageID){if(!text)return;const details=remember(document.createElement("details"),`thinking:${messageID}`);details.className="disclosure";const summary=document.createElement("summary");const label=document.createElement("span");label.textContent="Reasoning";summary.append(label);const body=document.createElement("div");body.className="disclosure-body prose";body.textContent=text;details.append(summary,body);parent.append(details)}
    function promptSlice(text,start,limit){let end=Math.min(text.length,start+limit);if(end<text.length&&text.charCodeAt(end-1)>=0xD800&&text.charCodeAt(end-1)<=0xDBFF)end--;return {text:text.slice(start,end),end}}
    function compactTokens(n){return n<1000?String(n):n<1e6?(n<1e5?(n/1000).toFixed(1):String(Math.round(n/1000)))+"k":(n/1e6).toFixed(1)+"M"}
    function tokenPercent(part,whole){if(!(whole>0))return "0%";const value=part/whole*100;return value>0&&value<1?"<1%":`${Math.round(value)}%`}
    function promptUsageSummary(u){if(u.contextTokens!=null)return `${compactTokens(u.contextTokens)} tokens of context${u.contextLimit>0?` · ${tokenPercent(u.contextTokens,u.contextLimit)} of ${compactTokens(u.contextLimit)}`:""}`;if(u.messageTokens!=null)return `About ${compactTokens(u.messageTokens)} tokens sent`;return `${compactTokens(u.inputTokens||0)} input tokens`}
    function appendPromptUsage(parent,u,messageID){const details=remember(document.createElement("details"),`usage:${messageID}`),summary=document.createElement("summary"),body=document.createElement("div"),n=value=>Number(value).toLocaleString();details.className="disclosure prompt-usage";summary.textContent=promptUsageSummary(u);summary.setAttribute("aria-label",`Prompt context: ${summary.textContent}`);
      const sent=[u.contextTokens!=null&&["Total",n(u.contextTokens)+(u.contextLimit>0?` of ${n(u.contextLimit)}`:"")],u.systemTokens!=null&&["System instructions",n(u.systemTokens)],u.toolTokens!=null&&["Tool definitions",n(u.toolTokens)],u.conversationTokens!=null&&["Conversation",n(u.conversationTokens)],u.messageTokens!=null&&["This message",`≈ ${n(u.messageTokens)}`],u.messageTokens!=null&&u.addedTokens>0&&["Added by Cantrip",`≈ ${n(u.addedTokens)}`]].filter(Boolean),run=[];
      if(u.modelCalls>0)run.push(["Model calls",n(u.modelCalls)],["Input tokens",n(u.inputTokens)+(u.inputTokens>0&&u.cachedInputTokens>0?` (${tokenPercent(u.cachedInputTokens,u.inputTokens)} cached)`:"")],["Output tokens",n(u.outputTokens)]);if(u.latestContextTokens!=null&&u.latestContextTokens!==u.contextTokens)run.push(["Latest context",n(u.latestContextTokens)]);body.className="usage-table";
      for(const [title,rows] of [["When sent",sent],["This run",run]]){if(!rows.length)continue;const heading=document.createElement("div"),list=document.createElement("dl");heading.className="usage-title";heading.textContent=title;for(const [label,value] of rows){const term=document.createElement("dt"),detail=document.createElement("dd");term.textContent=label;detail.textContent=value;list.append(term,detail)}body.append(heading,list)}
      const note=document.createElement("p");note.className="muted";note.textContent="Token counts come from the model provider. “This message” includes memory and context Cantrip added, estimated at about 4 characters per token. Run totals include subagents and every step’s model call.";body.append(note);details.append(summary,body);parent.append(details)}
    function appendPrompt(parent,text){const preview=document.createElement("div"),page=promptSlice(text,0,1200),long=page.end<text.length;preview.className=`prompt-preview${long?" clipped":""}`;preview.textContent=page.text;parent.append(preview);
      if(long){const button=document.createElement("button");button.className="control quiet";button.textContent="Read full prompt";button.onclick=()=>readPrompt(text);parent.append(button)}}
    let readingPrompt="",promptStarts=[0],promptEnd=0;
    function renderPromptPage(){const page=promptSlice(readingPrompt,promptStarts[promptStarts.length-1],4000);promptEnd=page.end;$("promptPage").textContent=page.text;$("promptPage").scrollTop=0;$("promptNumber").textContent=`Page ${promptStarts.length}`;$("promptPrevious").disabled=promptStarts.length===1;$("promptNext").disabled=promptEnd===readingPrompt.length}
    function readPrompt(text){readingPrompt=text;promptStarts=[0];$("promptTitle").textContent="Full prompt";renderPromptPage();$("promptReader").showModal()}
    $("promptPrevious").onclick=()=>{if(promptStarts.length>1){promptStarts.pop();renderPromptPage()}};
    $("promptNext").onclick=()=>{if(promptEnd<readingPrompt.length){promptStarts.push(promptEnd);renderPromptPage()}};
    $("promptDownload").onclick=()=>{const url=URL.createObjectURL(new Blob([readingPrompt],{type:"text/plain;charset=utf-8"})),link=document.createElement("a");link.href=url;link.download="cantrip-prompt.txt";link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
    $("promptDone").onclick=()=>$("promptReader").close();
    $("promptReader").addEventListener("close",()=>{readingPrompt="";promptStarts=[0];$("promptPage").textContent=""});
    // Cantrip Home handoffs: one card per handoff. It starts under the reply that made it; once
    // the tab reports back (asks, finishes, fails, stops) the result card posted into Home's chat
    // takes over and the original is hidden. Tab output is shown as text only, never as markup.
    function handoffClock(seconds){return seconds?new Date(seconds*1000).toLocaleTimeString([],{hour:"numeric",minute:"2-digit"}):""}
    function handoffDuration(start,end){const total=Math.max(0,Math.round(end-start));if(total<60)return `${total}s`;const minutes=Math.round(total/60);return minutes<60?`${minutes}m`:`${Math.floor(minutes/60)}h ${minutes%60}m`}
    function openHandoffTab(id){if(!sessionItems.some(s=>s.id===id)){$("actionError").textContent="That tab is no longer open.";return}$("actionError").textContent="";selectTab(id);renderedPayload="";refresh()}
    function handoffCardElement({state,label,tabID,tabTitle,summary,detail,time,result}){const card=document.createElement("section"),tab=tabTitle||"Project tab";
      card.className=`handoff-card ${state}${result?" result":""}`;card.setAttribute("role","group");card.setAttribute("aria-label",`${label}, ${tab}`);
      const head=document.createElement("div");head.className="handoff-head";const icon=document.createElement("span");icon.className=`handoff-icon ${state}`;icon.setAttribute("aria-hidden","true");
      icon.textContent={completed:"✓",failed:"!",cancelled:"–",needsInput:"?",queued:"◷",running:"•",working:"•"}[state]||"•";
      const title=document.createElement("div");title.className="handoff-title";const strong=document.createElement("strong");strong.textContent=label;const chip=document.createElement("span");chip.className="handoff-tab";chip.textContent=tab;title.append(strong,chip);head.append(icon,title);card.append(head);
      if(summary){const line=document.createElement("div");line.className="handoff-summary";line.textContent=summary;card.append(line)}
      if(detail){const text=document.createElement("p");text.className="handoff-detail";text.textContent=detail;card.append(text)}
      const foot=document.createElement("div");foot.className="handoff-foot";const when=document.createElement("span");when.textContent=time;foot.append(when);
      if(tabID){const open=document.createElement("button");open.className="control quiet handoff-open";open.textContent="Open tab";open.setAttribute("aria-label",`Open ${tab} tab`);open.onclick=()=>openHandoffTab(tabID);foot.append(open)}
      card.append(foot);return card}
    function handoffCard(handoff){const needs=handoff.status==="running"&&(handoff.needsInput||handoff.latestStatus==="Needs your answer"||handoff.latestStatus==="Waiting for your input"),state=needs?"needsInput":handoff.status;
      const label=needs?"Needs your answer":{queued:"Queued in tab",running:"Working in tab",completed:"Done in tab",failed:"Failed in tab",cancelled:"Stopped"}[handoff.status]||"Handed off";
      const time=handoff.finishedAt?`Took ${handoffDuration(handoff.startedAt,handoff.finishedAt)}`:handoff.startedAt?`Started ${handoffClock(handoff.startedAt)}`:"";
      return handoffCardElement({state,label,tabID:handoff.tabID,tabTitle:handoff.tabTitle,summary:handoff.summary||handoff.prompt,time})}
    function freshStartDivider(message){const divider=document.createElement("p");divider.className="fresh-start";divider.dataset.messageId=message.id;divider.textContent=message.text||"Started fresh — earlier messages aren't sent to the model";return divider}
    function handoffResultCard(result){const label=(result.kind==="ask"?{working:"Asked tab",needsInput:"Needs your answer first",completed:"Answer from tab",failed:"Couldn't answer",cancelled:"Question stopped"}:{working:"Working in tab",needsInput:"Needs your answer",completed:"Done in tab",failed:"Failed in tab",cancelled:"Stopped"})[result.state]||"Handoff update";
      const time=result.finishedAt?`Finished ${handoffClock(result.finishedAt)} · took ${handoffDuration(result.startedAt,result.finishedAt)}`:`Updated ${handoffClock(result.updatedAt)}`;
      return handoffCardElement({state:result.state,label,tabID:result.tabID,tabTitle:result.tabTitle,summary:result.summary,detail:result.detail,time,result:true})}
    // Child tabs: a queued message runs in its own tab (and branch) and merges back; the parent shows
    // one card. Its tag opens the thread: the request, the child's replies and the files it changed.
    function branchGlyph(){const svg=document.createElementNS("http://www.w3.org/2000/svg","svg");svg.setAttribute("viewBox","0 0 16 16");svg.setAttribute("aria-hidden","true");svg.setAttribute("class","branch-glyph");
      svg.innerHTML='<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="5" r="1.6"/><path d="M4.5 5.1v5.8M11.5 6.6c0 3.2-7 2-7 4.3"/>';return svg}
    const childVerbs={open:"open it",requeue:"move it back to this tab",discard:"discard it",resolve:"start the merge",keepParent:"keep that version",keepChild:"keep that version",leave:"leave it unmerged",retry:"try the merge again",merge:"merge it"};
    async function childAction(sessionID,child,name,button){if(name==="open"&&sessionItems.some(s=>s.id===child.id)){openHandoffTab(child.id);return}
      if(name==="discard"&&!confirm(`Discard child tab “${child.title}”?${child.branch?` Its work on ${child.branch} is deleted.`:""}`))return;
      if(name==="requeue"&&!confirm(`Run “${child.title}” in this tab instead? The child tab stops${child.branch?` and its work on ${child.branch} is deleted`:""}. The request goes back to the front of this tab's queue.`))return;
      $("actionError").textContent="";if(button)button.disabled=true;
      try{await api(`/api/v1/sessions/${sessionID}/children/${child.id}/${name}`,{method:"POST"});if(name==="open")selectTab(child.id);renderedPayload="";await refresh()}
      catch(error){$("actionError").textContent=`Couldn't ${childVerbs[name]||"do that"}: ${error.message}`;if(button)button.disabled=false}}
    function childChip(child){const chip=document.createElement("span"),icon=document.createElement("span");chip.className=`child-chip ${{working:"work",needsInput:"work",conflict:"work",merged:"ok",noChanges:"ok",failed:"bad"}[child.state]||""}`;
      icon.setAttribute("aria-hidden","true");icon.textContent={needsInput:"?",finished:"◷",merged:"✓",noChanges:"✓",conflict:"⚠",unmerged:"–",failed:"!",stopped:"–",discarded:"–",requeued:"↩"}[child.state]||"•";
      if(child.state==="working"||child.state==="merging")icon.className="child-pulse";chip.append(icon,child.statusLine);return chip}
    function childExcerpt(text){const pre=document.createElement("pre");pre.className="child-excerpt";pre.tabIndex=0;pre.setAttribute("aria-label","Conflicting lines");
      for(const [index,line] of text.split("\\n").entries()){if(index)pre.append("\\n");const span=document.createElement("span");span.className=line.startsWith(" ")||line==="…"?"ctx":line.startsWith("child ")?"theirs":"ours";span.textContent=line;pre.append(span)}return pre}
    function childFiles(files){const line=document.createElement("p");line.className="child-files";
      files.slice(0,8).forEach((file,index)=>{if(index)line.append(" · ");const code=document.createElement("code");code.textContent=file.path;line.append(code,` +${file.added} −${file.removed}`)});
      if(files.length>8)line.append(` · ${files.length-8} more`);return line}
    function childQuestion(sessionID,child){const box=document.createElement("div"),title=document.createElement("h4"),text=document.createElement("p"),files=child.conflictFiles||[],clean=child.cleanFileCount||0;
      box.className="child-question";box.setAttribute("role","group");title.id=`child-question-${child.id}`;title.textContent="Merge needs your answer";box.setAttribute("aria-labelledby",title.id);
      const name=document.createElement("strong"),base=document.createElement("code");name.textContent=child.title;base.textContent=child.baseBranch||"the parent's branch";
      text.append("Merging ",name," into ",base,clean?`: ${clean} ${clean===1?"file":"files"} merged cleanly, but both branches changed the same lines in `:": both branches changed the same lines in ");
      files.slice(0,4).forEach((file,index)=>{if(index)text.append(", ");const code=document.createElement("code");code.textContent=file;text.append(code)});if(files.length>4)text.append(` and ${files.length-4} more`);text.append(".");
      box.append(title,text);if(child.conflictExcerpt)box.append(childExcerpt(child.conflictExcerpt));
      if(child.note){const note=document.createElement("p");note.className="child-note";note.textContent=child.note;box.append(note)}
      const options=document.createElement("div");options.className="child-options";
      for(const [action,label] of [["resolve","Keep both, then run the tests (Recommended)"],["keepParent",`Keep ${child.baseBranch?`${child.baseBranch}'s`:"the parent's"} version`],["keepChild","Keep the child's version"],["leave","Leave it unmerged; I'll look"]]){
        if(!(child.actions||[]).includes(action))continue;const button=document.createElement("button");button.type="button";button.className=`control${action==="resolve"?" primary":""}`;button.textContent=label;button.onclick=()=>childAction(sessionID,child,action,button);options.append(button)}
      box.append(options);return box}
    // Thread tags (Home): a reply from a different thread than the message above names the prompt that
    // started its thread. It opens that thread inline, fetched from the Mac so it works before older
    // messages load: the prompt, then the earlier messages in the thread (unrelated ones skipped).
    const threadPages=new Map();
    function threadTag(sessionID,message){const thread=message.thread,details=remember(document.createElement("details"),`thread:${message.id}`),summary=document.createElement("summary"),tag=document.createElement("span"),label=document.createElement("span"),body=document.createElement("div");
      details.className="child-thread thread-tag";summary.setAttribute("aria-label",`Reply to: ${thread.prompt}`);tag.className="child-tag";label.textContent=thread.prompt;tag.append(label);summary.append(tag);body.className="child-thread-body";details.append(summary,body);
      const note=text=>{const line=document.createElement("p");line.className="child-note";line.textContent=text;body.append(line)};
      const fill=page=>{body.replaceChildren();if(!page){note("Loading the thread…");return}if(page.error){note(page.error);return}
        const prompt=document.createElement("p");prompt.className="child-prompt";prompt.textContent=page.prompt.text;body.append(prompt);if(page.hasEarlier)note("Earlier messages in this thread aren't shown.");
        for(const item of page.messages||[]){if(item.role==="user"){const answer=document.createElement("p");answer.className="child-prompt";answer.textContent=item.text;body.append(answer);continue}
          const reply=document.createElement("div"),who=document.createElement("span"),bubble=document.createElement("div"),text=document.createElement("p");reply.className="child-reply thread-reply";who.className="child-who";who.textContent=item.role==="handoff"?"Handoff":item.role==="error"?"Error":"Home";bubble.className="thread-bubble";appendInline(text,item.text.replace(/\\s*\\n\\s*/g," "));bubble.append(text);reply.append(who,bubble);body.append(reply)}};
      const load=retry=>{let page=threadPages.get(message.id);if(retry&&page?.error){threadPages.delete(message.id);page=null}
        if(page&&!(page instanceof Promise)){fill(page);return}
        if(!page){page=api(`/api/v1/sessions/${sessionID}/threads/${thread.id}?before=${message.id}`).then(data=>data.thread,error=>({error:`Couldn't load this thread: ${error.message}`}));threadPages.set(message.id,page)}
        fill(null);page.then(result=>{threadPages.set(message.id,result);fill(result)})};
      details.addEventListener("toggle",()=>{if(details.open)load(true)});if(details.open)load(false);return details}
    function childResultCard(sessionID,child){const card=document.createElement("section"),open=sessionItems.some(s=>s.id===child.id);card.className=`child-card ${child.state}`;card.setAttribute("role","group");card.setAttribute("aria-label",`Child tab ${child.title}`);
      const thread=remember(document.createElement("details"),`child:${child.id}`),summary=document.createElement("summary"),lane=document.createElement("span"),tag=document.createElement("span"),tagText=document.createElement("span");thread.className="child-thread";
      lane.className="child-lane";lane.append(branchGlyph(),`Child tab · ${child.title}`);tag.className="child-tag";tagText.textContent=(child.prompt||"").split("\\n")[0];tag.append(tagText);summary.append(lane,tag);summary.title="Show the request and the child tab's replies";thread.append(summary);
      const body=document.createElement("div"),prompt=document.createElement("p");body.className="child-thread-body";prompt.className="child-prompt";prompt.textContent=child.prompt||"";body.append(prompt);
      for(const reply of child.replies||[]){const item=document.createElement("div"),who=document.createElement("span"),text=document.createElement("p");item.className="child-reply";who.className="child-who";who.textContent=child.title;appendInline(text,reply);item.append(who,text);body.append(item)}
      if((child.files||[]).length)body.append(childFiles(child.files));
      const full=document.createElement("button");full.type="button";full.className="control quiet child-link";full.textContent="Open the full conversation ↗";full.setAttribute("aria-label",`Open the full conversation of ${child.title}`);full.onclick=()=>childAction(sessionID,child,"open",full);body.append(full);thread.append(body);card.append(thread);
      const said=child.summary||(child.state==="working"?"Working on it in its own tab.":"");if(said){const line=document.createElement("p");line.className="child-summary";appendInline(line,said);card.append(line)}
      if(child.state==="conflict")card.append(childQuestion(sessionID,child));
      const meta=document.createElement("div"),link=document.createElement("button");meta.className="child-meta";meta.append(childChip(child));
      link.type="button";link.className="control quiet child-link";link.textContent=open?"Open tab ↗":"Open conversation ↗";link.setAttribute("aria-label",`${open?"Open tab":"Open conversation"}: ${child.title}`);link.onclick=()=>childAction(sessionID,child,"open",link);meta.append(link);
      const running=["working","needsInput"].includes(child.state),extra=running?{requeue:"Run in this tab instead"}:{retry:"Try Again",merge:"Merge Its Work",discard:"Discard"};
      if(child.state!=="conflict")for(const action of child.actions||[])if(extra[action]&&!(action==="discard"&&!child.branch)){const button=document.createElement("button");button.type="button";button.className="control child-action";button.textContent=extra[action];button.onclick=()=>childAction(sessionID,child,action,button);meta.append(button)}
      card.append(meta);return card}
    function childBanner(session){const child=session.child,banner=document.createElement("div"),text=document.createElement("span");banner.className="child-banner";banner.setAttribute("role","note");
      text.textContent=`Child tab of ${child.parentTitle}${child.branch?` · ${child.branch} → ${child.baseBranch||"the parent's branch"}`:""} · ${child.statusLine}`;banner.append(branchGlyph(),text);
      if(session.parentID){const back=document.createElement("button");back.type="button";back.className="control quiet child-link";back.textContent="Open parent";back.setAttribute("aria-label",`Open the parent tab, ${child.parentTitle}`);back.onclick=()=>openHandoffTab(session.parentID);banner.append(back)}return banner}
    async function queueAction(sessionID,item,name,button){$("actionError").textContent="";button.disabled=true;
      try{await api(`/api/v1/sessions/${sessionID}/queue/${item.id}/${name}`,{method:"POST"});renderedPayload="";await refresh()}
      catch(error){$("actionError").textContent=`Couldn't ${name==="fork"?"start a child tab":"send it now"}: ${error.message}`;button.disabled=false}}
    // Queued messages with their suggested plan; each can run in a child tab or go now.
    function queueList(session){const items=session.queued||[];if(!items.length||session.isCantripHome)return null;
      const list=document.createElement("section"),head=document.createElement("h3"),reason=session.supportsChildTabs?session.childTabsUnavailableReason:null;list.className="queue-list";head.id=`queue-${session.id}`;head.textContent=`Queue · ${items.length}`;list.setAttribute("aria-labelledby",head.id);list.append(head);
      if(reason){const note=document.createElement("p");note.className="queue-note";note.textContent=reason;list.append(note)}
      for(const item of items){const row=document.createElement("div"),text=document.createElement("span"),label=item.displayText??item.text;row.className="queue-row";text.className="queue-text";text.textContent=label;text.title=label;row.append(text);
        if(item.plan){const chip=document.createElement("span");chip.className=`plan-chip ${item.plan.kind}`;chip.textContent=item.plan.reason;chip.title=item.plan.reason;row.append(chip)}
        if(session.supportsChildTabs){const fork=document.createElement("button");fork.type="button";fork.className="control quiet queue-action";fork.textContent="Run in child tab";fork.disabled=Boolean(reason);fork.setAttribute("aria-label",`Run “${label.slice(0,80)}” in a child tab`);fork.onclick=()=>queueAction(session.id,item,"fork",fork);row.append(fork)}
        if(session.supportsQueueSendNow){const send=document.createElement("button");send.type="button";send.className="control quiet queue-action";send.textContent="Send now";send.setAttribute("aria-label",`Send “${label.slice(0,80)}” now`);send.onclick=()=>queueAction(session.id,item,"send",send);row.append(send)}
        list.append(row)}
      return list}
    function render(session,prepend=false){const root=document.scrollingElement||document.documentElement,previousTop=root.scrollTop,previousHeight=root.scrollHeight,anchor=prepend?visibleHistoryAnchor():null;
      $("inputBanner").classList.toggle("hidden",!session?.pendingInputs?.some(r=>r.kind==="secret"));$("inputBanner").textContent="Enter password securely";
      renderProgress(session);updateHistoryControls(session);const liveBox=$("messages"),box=document.createElement("div"),sessionID=session?.id||null,payload=JSON.stringify(session);if(sessionID===renderedSession&&payload===renderedPayload)return;
      const sameSession=sessionID===renderedSession,shouldFollow=!prepend&&(followOutput||!sameSession),scrollRevision=++renderScrollRevision;renderedSession=sessionID;renderedPayload=payload;suppressScroll=true;historyScrollIntent=false;if(!sameSession)historyReading=false;$("resume").classList.toggle("hidden",!session?.canResume);$("stop").classList.toggle("hidden",!session?.isStreaming);
      const pinned=[];if(!session){const empty=document.createElement("div");empty.className="empty";empty.textContent="No open sessions.";box.append(empty)}
      else{if(session.isLocalPrivate){const notice=document.createElement("p");notice.className="muted";notice.textContent="Private Local - saved on the Mac and available remotely. Self-hosted models; no cloud fallback. Configure the server in the tab menu.";box.append(notice)}
        if(session.child)box.append(childBanner(session));
        const answered=new Set(session.messages.filter(m=>m.role==="handoff"&&m.handoffResult).map(m=>m.handoffResult.delegationID));
        for(const message of session.messages){const handoffs=(message.delegations||[]).filter(handoff=>!answered.has(handoff.id)),subagents=message.subagents||[],subagentIDs=new Set(subagents.map(agent=>agent.id)),activities=(message.activities||[]).filter(activity=>!subagentIDs.has(activity.id)),apps=message.apps||[],settled=subagents.filter(agent=>!subagentActive(agent));for(const agent of subagents)if(subagentActive(agent))pinned.push([agent,message.id]);for(const app of apps)box.append(mcpAppSlot(session.id,app));
          if(!message.text&&!message.thinking&&!activities.length&&!settled.length&&!handoffs.length)continue;if(message.role==="freshStart"){box.append(freshStartDivider(message));continue}const row=document.createElement("article");row.className=`message ${message.role}`;row.dataset.messageId=message.id;
          if(message.author){const author=document.createElement("span");author.className="author";author.textContent=message.author;row.append(author)}
          if(message.thread&&message.role!=="user")row.append(threadTag(session.id,message));
          appendThinking(row,message.thinking,message.id);if(message.role==="user"){const images=message.images||[],text=message.displayText??message.text;if(text)appendPrompt(row,text);if(images.length)appendAttachments(row,session.id,images);if(message.promptUsage)appendPromptUsage(row,message.promptUsage,message.id)}else if(message.childResult)row.append(childResultCard(session.id,message.childResult));else if(message.role==="handoff"&&message.handoffResult)row.append(handoffResultCard(message.handoffResult));else appendReply(row,message,settled,session);
          if(message.role==="error"&&session.supportsStartFresh&&message.id===session.repeatedErrorMessageID)appendErrorRecovery(row,session);
          if(handoffs.length){const stack=document.createElement("div");stack.className="handoffs";for(const handoff of handoffs)stack.append(handoffCard(handoff));row.append(stack)}appendActivities(row,activities,message.id);
          if(message.isPreview){const button=document.createElement("button");button.className="control quiet";button.textContent="Load full message and details";button.onclick=async()=>{
            const requestToken=token;button.disabled=true;try{const data=await api(`/api/v1/sessions/${session.id}/messages/${message.id}`);if(token!==requestToken||selected!==session.id)return;
              const full=data.message,parts=[full.text];if(full.thinking)parts.push("Reasoning\\n"+full.thinking);for(const step of full.activities||[])parts.push([step.title,step.input,step.output].filter(Boolean).join("\\n"));readPrompt(parts.join("\\n\\n"));$("promptTitle").textContent="Message details"}
            catch(error){if(token===requestToken)$("historyError").textContent=`Could not load message details: ${error.message}`}finally{button.disabled=false}};row.append(button)}box.append(row)}
        appendChatInputs(box,session);
        const queue=queueList(session);if(queue)box.append(queue);
        if(session.deliveryStatus){const note=document.createElement("div");note.className="run-status";note.textContent=session.deliveryStatus;box.append(note)}
        if(!sidebarLayout&&(session.isStreaming||session.queuedCount)){const status=document.createElement("div");status.className="run-status";if(session.isStreaming){const spinner=document.createElement("span");spinner.className="spinner";status.append(spinner)}const label=document.createElement("span");label.textContent=session.isStreaming?(session.status||"Working…"):`${session.queuedCount} queued`;status.append(label);box.append(status)}}
      mcpReconcile(liveBox,box);pruneMacImages();renderPinnedSubagents(sessionID,pinned);
      settleConversationPosition(anchor,shouldFollow?root.scrollHeight:Math.min(previousTop+(prepend?root.scrollHeight-previousHeight:0),Math.max(0,root.scrollHeight-root.clientHeight)),shouldFollow,scrollRevision)}
    async function action(name,body){if(!selected)return;await api(`/api/v1/sessions/${selected}/${name}`,{method:"POST",body:body?JSON.stringify(body):undefined});await refresh()}
    async function closeSession(id){$("actionError").textContent="";try{const data=await api(`/api/v1/sessions/${id}/close`,{method:"POST"});if(selected===id)selectTab(data.session.id);renderedPayload="";await refresh()}
      catch(error){$("actionError").textContent=`Close failed: ${error.message}`}}
    $("pairButton").onclick=async()=>{if(desktopState)await endDesktop();clearUIReloadState();historyCache.clear();clearMacImages();expandedHistory.clear();historyPaused.clear();tabDrafts.clear();selected=null;$("draft").value="";token=$("token").value.trim();try{await api("/api/v1/sessions");localStorage.cantripToken=token;connection(true);pair(false);refresh()}
      catch(error){$("pairError").textContent=error.message}};
    $("send").onclick=async()=>{const text=$("draft").value.trim();if(!text)return;const sessionID=selected,requestToken=token,mode=$("mode").value,body={text,mode};
      if(mode==="auto"&&chatInputReply?.sessionID===sessionID&&chatInputReply.token===requestToken)body.inputRequestID=chatInputReply.id;
      $("send").disabled=true;try{await action("messages",body);if(selected===sessionID&&token===requestToken){if($("draft").value.trim()===text)$("draft").value="";$("mode").value="auto"}}
      catch(error){$("actionError").textContent=`Send failed: ${error.message}. Check the session before resending.`}finally{$("send").disabled=false;scheduleUIReload()}};
    // Backend slash commands: the tab agent's commands, custom commands and skills, suggested while the composer holds a lone "/token".
    function slashToken(text){if(typeof text!=="string"||!text.startsWith("/")||/\\s/.test(text))return null;const query=text.slice(1);return query.includes("/")?null:query.toLowerCase()}
    function slashCommandScore(command,query){const name=String(command?.name||"").toLowerCase();if(!name)return null;if(!query)return 1;
      if(name===query)return 0;if(name.startsWith(query))return 1;
      if(Array.isArray(command.aliases)&&command.aliases.some(alias=>String(alias).toLowerCase().startsWith(query)))return 2;
      const bare=value=>value.replace(/[-_:]/g,""),bareQuery=bare(query);
      if(name.includes(query)||(bareQuery&&bare(name).includes(bareQuery)))return 3;
      if([...query].length>=2&&String(command.description||"").toLowerCase().split(/[^\\p{L}\\p{M}\\p{N}]+/u).some(word=>word.startsWith(query)))return 4;
      return null}
    function matchCommands(commands,query){const rows=[];
      (Array.isArray(commands)?commands:[]).forEach((command,index)=>{const score=slashCommandScore(command,query);if(score!==null)rows.push({command,score,index,unavailable:command.availability==="unavailable"})});
      rows.sort((a,b)=>Number(a.unavailable)-Number(b.unavailable)||a.score-b.score||a.index-b.index);
      const shown=rows.slice(0,50),first=shown[0];
      return {rows:shown,highlighted:query!==""&&first&&first.score<=2&&!first.unavailable?0:-1}}
    // how: "tab" inserts only; "return" (also click or tap) sends commands that take no argument.
    function chooseCommand(command,how,canOpenModelSettings){if(!command||command.availability==="unavailable")return {kind:"none"};
      if(command.action==="modelSettings"&&canOpenModelSettings)return {kind:"modelSettings",text:""};
      const text=typeof command.insert==="string"?command.insert:"";if(!text)return {kind:"none"};
      if(how==="tab"||command.requiresInput||String(command.inputHint??"").trim())return {kind:"insert",text};
      return {kind:"send",text,send:text.trim()}}
    // A row shows exactly what it inserts: "/plan", or "$imagegen" for a Codex skill.
    function commandTitle(command){return String(command?.insert||"").trim().split(/\\s+/)[0]||`/${command?.name||""}`}
    function slashCommandsStale(entry,session,now){return !entry?.data||now-entry.at>=30000||entry.workdir!==(session?.workdir??null)||entry.modelRevision!==(session?.modelSettingsRevision??null)}
    const slashCache=new Map(),slashState={mode:null,dismissed:null,key:null,choice:null,signature:"",data:null,rows:[],highlighted:-1,open:false};let slashSequence=0,slashPointer=false;
    function slashSession(){return sessionItems.find(item=>item.id===selected)||null}
    // One request per tab at a time; a response is kept only for the tab, pairing and request sequence that asked for it.
    function loadSlashCommands(session){if(!session?.supportsBackendCommands||!token)return;const id=session.id,previous=slashCache.get(id);
      const entry=previous?.token===token?previous:{token,data:null,at:0,workdir:null,modelRevision:null,pending:0};
      if(entry.pending||!slashCommandsStale(entry,session,Date.now()))return;
      const sequence=++slashSequence,requestToken=token,workdir=session.workdir??null,modelRevision=session.modelSettingsRevision??null;entry.pending=sequence;slashCache.set(id,entry);
      for(const key of slashCache.keys())if(key!==id&&!sessionItems.some(item=>item.id===key))slashCache.delete(key);
      api(`/api/v1/sessions/${encodeURIComponent(id)}/commands`).then(data=>{if(slashCache.get(id)!==entry||entry.pending!==sequence||token!==requestToken)return;
          if(!Array.isArray(data?.commands))throw new Error("Invalid command list");
          Object.assign(entry,{pending:0,at:Date.now(),workdir,modelRevision,data:{revision:String(data.revision||""),status:typeof data.status==="string"?data.status.trim():"",
            commands:data.commands.filter(command=>typeof command?.name==="string"&&command.name)}})})
        .catch(()=>{if(slashCache.get(id)===entry&&entry.pending===sequence)entry.pending=0})
        .finally(()=>{if(selected===id)syncSlashCommands()})}
    function slashOption(row,index,canModel){const command=row.command,option=document.createElement("div"),cmd=document.createElement("span"),name=document.createElement("span");
      const hint=String(command.inputHint??"").trim(),description=String(command.description||"").trim(),source=String(command.source||"").trim(),note=typeof command.note==="string"?command.note.trim():"";
      option.id=`slashOption${index}`;option.className="slash-row";option.dataset.index=String(index);option.setAttribute("role","option");option.setAttribute("aria-selected","false");
      cmd.className="slash-cmd";name.className="slash-name";name.textContent=commandTitle(command);cmd.append(name);
      if(hint){const node=document.createElement("span");node.className="slash-hint";node.textContent=hint;cmd.append(node)}option.append(cmd);
      for(const [className,value] of [["slash-desc",description],["slash-source",source],["slash-note",note]])if(value){const node=document.createElement(className==="slash-note"?"div":"span");node.className=className;node.textContent=value;option.append(node)}
      option.setAttribute("aria-label",[commandTitle(command),description,source,note].filter(Boolean).join(", "));if(description)option.title=description;
      if(row.unavailable)option.setAttribute("aria-disabled","true");
      else option.setAttribute("aria-description",chooseCommand(command,"return",canModel).kind==="insert"?"Inserts the command":"Runs the command");
      option.onclick=()=>chooseSlashRow(index,"return");return option}
    function highlightSlashRow(index){const draft=$("draft"),list=$("slashList"),popover=$("slashPopover");if(!slashState.rows[index]||slashState.rows[index].unavailable)index=-1;
      slashState.highlighted=index;slashState.choice=index>=0?slashState.rows[index].command.name:null;
      for(const option of list.children)option.setAttribute("aria-selected",String(option.dataset.index===String(index)));
      const active=index>=0?list.children[index]:null;if(!active){draft.removeAttribute("aria-activedescendant");return}
      draft.setAttribute("aria-activedescendant",active.id);const top=active.offsetTop,bottom=top+active.offsetHeight;
      if(top<popover.scrollTop)popover.scrollTop=top;else if(bottom>popover.scrollTop+popover.clientHeight)popover.scrollTop=bottom-popover.clientHeight}
    // The list opens below the composer while it sits at the top of the page, and above it when more room is there.
    function placeSlashPopover(){const popover=$("slashPopover");if(popover.classList.contains("hidden"))return;const rect=$("draft").getBoundingClientRect(),view=window.visualViewport;
      const top=view?view.offsetTop:0,bottom=view?view.offsetTop+view.height:innerHeight,below=bottom-rect.bottom-12,above=rect.top-top-12,upward=above>below&&below<200;
      const limit=matchMedia("(max-width:620px)").matches?(bottom-top)*0.4:320;popover.classList.toggle("above",upward);
      popover.style.maxHeight=`${Math.round(Math.max(88,Math.min(limit,upward?above:below)))}px`}
    function syncSlashCommands(){const draft=$("draft"),popover=$("slashPopover"),list=$("slashList"),text=draft.value,session=slashSession(),query=slashToken(text);
      if(slashState.dismissed!==null&&slashState.dismissed!==text)slashState.dismissed=null;
      const mode=query!==null&&token&&session?.supportsBackendCommands&&document.activeElement===draft?session.id:null;
      if(mode&&mode!==slashState.mode)loadSlashCommands(session);slashState.mode=mode;
      const entry=mode?slashCache.get(mode):null,current=entry?.token===token?entry:null,data=current?.data||null,loading=Boolean(mode&&!data&&current?.pending);
      const matched=data?matchCommands(data.commands,query):{rows:[],highlighted:-1},status=data?.status||"";
      const visible=Boolean(mode)&&slashState.dismissed!==text&&(loading||matched.rows.length>0||Boolean(status));
      draft.setAttribute("aria-expanded",String(visible));popover.classList.toggle("hidden",!visible);slashState.open=visible;
      if(!visible){Object.assign(slashState,{rows:[],highlighted:-1,choice:null,key:null,signature:"",data:null});list.replaceChildren();draft.removeAttribute("aria-activedescendant");setText($("slashStatus"),"");return}
      const key=`${mode} ${query}`,canModel=Boolean(session.supportsModelSettings),signature=`${key} ${loading} ${canModel}`;let highlighted=matched.highlighted;
      if(data&&slashState.key===key&&slashState.choice!==null){const kept=matched.rows.findIndex(row=>row.command.name===slashState.choice&&!row.unavailable);if(kept>=0)highlighted=kept}
      slashState.key=data?key:null;slashState.rows=matched.rows;
      if(slashState.data!==data||slashState.signature!==signature){slashState.data=data;slashState.signature=signature;list.replaceChildren(...matched.rows.map((row,index)=>slashOption(row,index,canModel)));popover.scrollTop=0}
      $("slashLoading").classList.toggle("hidden",!loading);setText($("slashInfo"),status);$("slashInfo").classList.toggle("hidden",!status);
      placeSlashPopover();highlightSlashRow(highlighted);const count=matched.rows.length;
      setText($("slashStatus"),loading?"Loading commands…":`${count} command${count===1?"":"s"}${status?`. ${status}`:""}`)}
    function chooseSlashRow(index,how){const row=slashState.rows[index],session=slashSession(),draft=$("draft");if(!row||!session||slashState.mode!==session.id)return;
      const result=chooseCommand(row.command,how,Boolean(session.supportsModelSettings));if(result.kind==="none")return;
      draft.value=result.text;slashState.dismissed=null;
      if(result.kind==="modelSettings"){syncSlashCommands();editModelSettings(session);return}
      draft.focus();draft.setSelectionRange(result.text.length,result.text.length);syncSlashCommands();if(result.kind==="send")$("send").click()}
    // Returns true when the open suggestion list consumed the key.
    function slashKeydown(event){if(!slashState.open||event.isComposing||event.altKey||event.ctrlKey||event.metaKey)return false;const rows=slashState.rows;
      if(event.key==="ArrowDown"||event.key==="ArrowUp"){if(!rows.some(row=>!row.unavailable))return false;event.preventDefault();const step=event.key==="ArrowDown"?1:-1;let index=slashState.highlighted;
        do index=index<0?(step>0?0:rows.length-1):(index+step+rows.length)%rows.length;while(rows[index].unavailable);highlightSlashRow(index);return true}
      if(event.key==="Tab"&&!event.shiftKey&&slashState.highlighted>=0){event.preventDefault();chooseSlashRow(slashState.highlighted,"tab");return true}
      if(event.key==="Enter"&&!event.shiftKey){if(slashState.highlighted>=0){event.preventDefault();chooseSlashRow(slashState.highlighted,"return");return true}
        slashState.dismissed=$("draft").value;syncSlashCommands();return false}
      if(event.key==="Escape"){event.preventDefault();slashState.dismissed=$("draft").value;syncSlashCommands();return true}
      return false}
    $("draft").addEventListener("input",syncSlashCommands);
    $("draft").addEventListener("focus",()=>{const session=slashSession();if(session?.supportsBackendCommands&&token&&!slashCache.has(session.id))loadSlashCommands(session);syncSlashCommands()});
    $("draft").addEventListener("blur",()=>setTimeout(()=>{if(!slashPointer&&document.activeElement!==$("draft"))syncSlashCommands()},0));
    // Keeps the composer focused (and the touch keyboard up) while a row is clicked or tapped.
    $("slashPopover").addEventListener("mousedown",event=>event.preventDefault());$("slashPopover").addEventListener("pointerdown",()=>{slashPointer=true});
    for(const name of ["pointerup","pointercancel"])$("slashPopover").addEventListener(name,()=>setTimeout(()=>{slashPointer=false;if(document.activeElement!==$("draft"))syncSlashCommands()},300));
    addEventListener("resize",placeSlashPopover);window.visualViewport?.addEventListener("resize",placeSlashPopover);
    $("draft").onkeydown=event=>{if(slashKeydown(event))return;if(event.key==="Enter"&&!event.shiftKey){event.preventDefault();$("send").click()}};
    $("stop").onclick=()=>action("cancel");$("resume").onclick=()=>action("resume");$("newSession").onclick=async()=>{const data=await api("/api/v1/sessions",{method:"POST"});selectTab(data.session.id);refresh()};
    $("forget").onclick=async()=>{if(desktopState)await endDesktop();clearUIReloadState();localStorage.removeItem("cantripToken");artifactThumbs.clear();if($("artifactsPanel").open)$("artifactsPanel").close();historyCache.clear();clearMacImages();expandedHistory.clear();tabDrafts.clear();selected=null;$("draft").value="";token="";connection(false);pair(true);window.webkit?.messageHandlers?.cantripRemoteUnpair?.postMessage(null);window.cantripGateway?.unpair?.()};
    // Home Tasks: the task list, each workspace's records (grouped when its list declares a groupField) and record details.
    const appleEpochSeconds=978307200,workspaceGroupsKey="cantrip.workspaceGroups.",otherGroupID=String.fromCharCode(1)+"other";
    let tasksState=null;
    function homeNode(tag,className,text){const node=document.createElement(tag);if(className)node.className=className;if(text!==undefined)node.textContent=text;return node}
    function homeNoun(workspace,count){return count===1?workspace.recordLabel:(workspace.recordLabelPlural||`${workspace.recordLabel}s`)}
    function homeTime(seconds){return new Date((seconds+appleEpochSeconds)*1000).toLocaleString(undefined,{month:"short",day:"numeric",hour:"numeric",minute:"2-digit"})}
    function loadWorkspaceGroups(taskID){try{const value=JSON.parse(localStorage.getItem(workspaceGroupsKey+taskID)||"{}");return value&&typeof value==="object"?value:{}}catch{return {}}}
    function saveWorkspaceGroups(taskID,value){try{if(Object.keys(value).length)localStorage.setItem(workspaceGroupsKey+taskID,JSON.stringify(value));else localStorage.removeItem(workspaceGroupsKey+taskID)}catch{}}
    // Same rules as Cantrip Agent: explicit groups always show (0 when empty), one-per-option sections and Other only
    // with records, records keep their saved order, and a search keeps only sections with matches.
    function workspaceSections(workspace,records,searching){const key=workspace.list?.groupField;if(!key)return null;
      const explicit=workspace.list.groups,options=workspace.fields.find(field=>field.key===key)?.options||[];
      const groups=explicit||options.map(option=>({title:option,values:[option]})),index=new Map();
      groups.forEach((group,position)=>{for(const value of group.values)if(!index.has(value))index.set(value,position)});
      const buckets=groups.map(()=>[]),other=[];
      for(const record of records){const position=index.get(record.values[key]);if(position===undefined)other.push(record);else buckets[position].push(record)}
      let sections=groups.map((group,position)=>({id:group.title,title:group.title,records:buckets[position],startsCollapsed:group.collapsed===true}));
      if(!explicit)sections=sections.filter(section=>section.records.length);
      if(other.length)sections.push({id:otherGroupID,title:"Other",records:other,startsCollapsed:false});
      return searching?sections.filter(section=>section.records.length):sections}
    function formatHomeValue(field,value){if(value===undefined||value===null||value==="")return "—";
      if(field.kind==="boolean")return value==="true"?"Yes":"No";
      if(field.kind==="date"){const parts=/^([0-9]{4})-([0-9]{2})-([0-9]{2})$/.exec(value);return parts?new Date(+parts[1],+parts[2]-1,+parts[3]).toLocaleDateString(undefined,{month:"short",day:"numeric",year:"numeric"}):value}
      if(field.kind==="dateTime"){const date=new Date(value);return isNaN(date)?value:date.toLocaleString(undefined,{month:"short",day:"numeric",year:"numeric",hour:"numeric",minute:"2-digit"})}
      return value}
    function badgeTone(value){const text=value.trim().toLowerCase();
      return text.includes("reject")||text.includes("declin")?"rejected":text.includes("offer")?"offer":text==="applied"||text==="application received"?"applied":""}
    function openTasks(){closeTasks();tasksState={token,taskID:null,tasks:[],revision:null,loaded:false,failed:false,loading:false,openRecords:new Set(),timer:setInterval(()=>loadTasks(),10000)};
      $("tasksSearch").value="";setText($("tasksError"),"");renderTasks();$("tasksPanel").showModal();loadTasks()}
    function closeTasks(){if(tasksState)clearInterval(tasksState.timer);tasksState=null}
    async function loadTasks(){const state=tasksState;if(!state||state.loading)return;state.loading=true;
      try{const data=await api("/api/v1/home/tasks"+(state.loaded&&state.revision?`?revision=${encodeURIComponent(state.revision)}`:""));if(state!==tasksState)return;state.failed=false;
        if(data.unchanged){setText($("tasksError"),"");return}
        setText($("tasksError"),data.error||"");
        if(!state.loaded||data.revision!==state.revision){state.revision=data.revision;state.tasks=data.tasks||[];state.loaded=true;renderTasks()}}
      catch(error){if(state===tasksState){setText($("tasksError"),`Couldn't load tasks: ${error.message}`);if(!state.loaded){state.loaded=true;state.failed=true;renderTasks()}}}
      finally{state.loading=false}}
    // Polling re-renders in place: scroll, open records, collapsed sections and the focused row survive.
    function renderTasks(){const state=tasksState;if(!state)return;const panel=$("tasksPanel"),body=$("tasksBody");
      let task=state.taskID?state.tasks.find(item=>item.id===state.taskID):null;if(state.taskID&&!task&&state.loaded&&!state.failed)state.taskID=null;
      const workspace=task?.workspace,focused=document.activeElement?.closest?.("#tasksBody [data-focus-key]")?.dataset.focusKey,scroll=panel.scrollTop;
      $("tasksBack").classList.toggle("hidden",!task);setText($("tasksTitle"),task?task.title:"Tasks");
      $("tasksSearch").classList.toggle("hidden",!workspace?.records?.length);if(workspace)$("tasksSearch").placeholder=`Search ${homeNoun(workspace,2)}`;
      body.replaceChildren(task?(workspace?workspaceView(task):taskDetailView(task)):taskListView(state));panel.scrollTop=scroll;
      if(focused)Array.from(body.querySelectorAll("[data-focus-key]")).find(node=>node.dataset.focusKey===focused)?.focus()}
    function showTask(id){if(!tasksState)return;const previous=tasksState.taskID;tasksState.taskID=id;tasksState.openRecords.clear();$("tasksSearch").value="";setText($("tasksStatus"),"");renderTasks();$("tasksPanel").scrollTop=0;
      if(id)$("tasksTitle").focus();else Array.from($("tasksBody").querySelectorAll("[data-focus-key]")).find(node=>node.dataset.focusKey===`task:${previous}`)?.focus()}
    function taskListView(state){if(!state.loaded)return homeNode("p","muted tasks-empty","Loading tasks…");
      if(!state.tasks.length)return homeNode("p","muted tasks-empty",state.failed?"Tasks are unavailable right now.":"No tasks yet. Ask Cantrip Home to track or schedule something.");
      const list=homeNode("ul","task-list");
      for(const task of state.tasks){const item=homeNode("li"),card=homeNode("button","task-card");card.type="button";card.dataset.focusKey=`task:${task.id}`;
        const meta=[task.hasSchedule===false?"No schedule":task.enabled?task.schedule.summary:`Paused · ${task.schedule.summary}`];
        if(task.workspace)meta.push(`${task.workspace.records.length} ${homeNoun(task.workspace,task.workspace.records.length)}`);
        if(task.model)meta.push(task.model);if(task.state==="running")meta.push("Running now");
        card.append(homeNode("strong","task-title",task.title),homeNode("span","task-meta",meta.join(" · ")));
        if(task.runs?.[0]?.summary)card.append(homeNode("span","task-run",task.runs[0].summary));
        card.onclick=()=>showTask(task.id);item.append(card);list.append(item)}
      return list}
    function taskDetailView(task){const view=homeNode("div","task-detail"),facts=homeNode("dl","task-facts");
      const fact=(label,value)=>{if(value)facts.append(homeNode("dt","",label),homeNode("dd","",value))};
      fact("Schedule",task.hasSchedule===false?"No schedule":task.schedule.summary);fact("Status",!task.enabled?"Paused":task.state==="running"?"Running now":"On");
      fact("Model",(task.model||"Home's model")+(task.effort?` · ${task.effort} effort`:""));
      if(task.enabled&&task.nextRunAt!==null&&task.nextRunAt!==undefined)fact("Next run",homeTime(task.nextRunAt));
      view.append(facts,homeNode("h3","","Recent runs"));
      if(!task.runs?.length)view.append(homeNode("p","muted","No runs yet."));
      else{const runs=homeNode("ul","run-list");for(const run of task.runs.slice(0,5)){const item=homeNode("li");item.append(homeNode("span","task-meta",`${homeTime(run.finishedAt)} · ${run.status}${run.model?` · ${run.model}`:""}`),homeNode("span","run-summary",run.summary||"No summary"));runs.append(item)}view.append(runs)}
      const prompt=homeNode("details","disclosure");prompt.append(homeNode("summary","","Instructions"),homeNode("p","run-summary",task.prompt));view.append(prompt);
      return view}
    function workspaceView(task){const workspace=task.workspace,query=$("tasksSearch").value.trim().toLowerCase(),searching=Boolean(query);
      if(!workspace.records.length)return homeNode("p","muted tasks-empty",`No ${homeNoun(workspace,2)} yet. Tell Cantrip Home about one in Chat.`);
      const records=searching?workspace.records.filter(record=>Object.values(record.values).some(value=>String(value).toLowerCase().includes(query))):workspace.records;
      setText($("tasksStatus"),searching?`${records.length} ${homeNoun(workspace,records.length)} found`:"");
      const view=homeNode("div","workspace-records"),sections=workspaceSections(workspace,records,searching);
      if(searching&&!records.length)view.append(homeNode("p","muted tasks-empty",`No ${homeNoun(workspace,2)} match.`));
      if(!sections){if(records.length)view.append(recordList(task,records));return view}
      const remembered=loadWorkspaceGroups(task.id);
      for(const section of sections){const group=homeNode("details",`record-group${searching?" searching":""}`),summary=homeNode("summary");
        group.dataset.group=section.id;group.open=searching||!(remembered[section.id]??section.startsCollapsed);summary.dataset.focusKey=`group:${section.id}`;
        summary.append(homeNode("span","group-title",section.title),homeNode("span","group-count",String(section.records.length)),homeNode("span","sr-only",` ${homeNoun(workspace,section.records.length)}`));
        // Only the user's own toggles are remembered, never a search's temporary expansion.
        summary.addEventListener("click",event=>{if(searching){event.preventDefault();return}const saved=loadWorkspaceGroups(task.id);saved[section.id]=group.open;saveWorkspaceGroups(task.id,saved)});
        group.append(summary,section.records.length?recordList(task,section.records):homeNode("p","muted group-empty",`No ${homeNoun(workspace,2)}.`));view.append(group)}
      return view}
    function recordList(task,records){const workspace=task.workspace,list=homeNode("ul","record-list"),fields=new Map(workspace.fields.map(field=>[field.key,field])),layout=workspace.list;
      for(const record of records){const item=homeNode("li"),details=homeNode("details","record"),summary=homeNode("summary"),head=homeNode("span","record-head");
        details.open=tasksState?.openRecords.has(record.id)||false;details.addEventListener("toggle",()=>{if(details.open)tasksState?.openRecords.add(record.id);else tasksState?.openRecords.delete(record.id)});
        summary.dataset.focusKey=`record:${record.id}`;head.append(homeNode("span","record-title",record.values[layout.titleField]||workspace.recordLabel));
        const badge=layout.badgeField&&record.values[layout.badgeField];if(badge)head.append(homeNode("span",`record-badge ${badgeTone(badge)}`.trim(),badge));
        summary.append(head);
        const subtitles=layout.subtitleFields.flatMap(key=>{const field=fields.get(key),value=record.values[key];return field&&value?[`${field.label}: ${formatHomeValue(field,value)}`]:[]});
        if(subtitles.length)summary.append(homeNode("span","record-subtitle",subtitles.join(" · ")));
        const dateField=layout.dateField&&fields.get(layout.dateField),date=dateField&&record.values[dateField.key];
        if(date)summary.append(homeNode("span","record-date",`${dateField.label}: ${formatHomeValue(dateField,date)}`));
        details.append(summary,recordDetails(workspace,record,fields));item.append(details);list.append(item)}
      return list}
    function recordDetails(workspace,record,fields){const body=homeNode("div","record-details");
      const sections=workspace.detailSections.length?workspace.detailSections:[{title:null,fields:workspace.fields.map(field=>field.key)}];
      for(const section of sections){if(section.title)body.append(homeNode("h3","",section.title));const list=homeNode("dl");
        for(const key of section.fields){const field=fields.get(key);if(!field)continue;const value=record.values[key],cell=homeNode("dd");
          if(field.kind==="url"&&/^https?:[/][/]/i.test(value||"")){const link=homeNode("a","",value);link.href=value;link.target="_blank";link.rel="noopener noreferrer";cell.append(link)}
          else{cell.textContent=formatHomeValue(field,value);if(!value)cell.className="muted"}
          list.append(homeNode("dt","",field.label),cell)}
        body.append(list)}
      return body}
    // Artifacts: files Cantrip Home saved on the Mac. Images open in the viewer; other files download.
    let artifactsState=null,artifactThumbActive=0;const artifactThumbs=new Map(),artifactThumbQueue=[];
    function openArtifacts(){closeArtifacts();artifactsState={token,artifacts:[],revision:null,loaded:false,failed:false,loading:false,opening:null,timer:setInterval(()=>loadArtifacts(),15000)};
      setText($("artifactsError"),"");renderArtifacts();$("artifactsPanel").showModal();$("artifactsTitle").focus();loadArtifacts()}
    function closeArtifacts(){if(artifactsState)clearInterval(artifactsState.timer);artifactsState=null}
    async function loadArtifacts(){const state=artifactsState;if(!state||state.loading)return;state.loading=true;
      try{const data=await api("/api/v1/home/artifacts"+(state.loaded&&state.revision?`?revision=${encodeURIComponent(state.revision)}`:""));if(state!==artifactsState)return;state.failed=false;setText($("artifactsError"),"");
        if(data.unchanged)return;
        if(!state.loaded||data.revision!==state.revision){state.revision=data.revision;state.artifacts=data.artifacts||[];state.loaded=true;renderArtifacts()}}
      catch(error){if(state===artifactsState){setText($("artifactsError"),`Couldn't load artifacts: ${error.message}`);if(!state.loaded){state.loaded=true;state.failed=true;renderArtifacts()}}}
      finally{state.loading=false}}
    function renderArtifacts(){const state=artifactsState;if(!state)return;const panel=$("artifactsPanel"),body=$("artifactsBody"),scroll=panel.scrollTop,focused=document.activeElement?.closest?.("#artifactsBody [data-focus-key]")?.dataset.focusKey;
      if(!state.loaded)body.replaceChildren(homeNode("p","muted tasks-empty","Loading artifacts…"));
      else if(!state.artifacts.length)body.replaceChildren(homeNode("p","muted tasks-empty",state.failed?"Artifacts are unavailable right now.":"No artifacts yet. Documents and media created in Cantrip Home are collected here automatically."));
      else{const list=homeNode("ul","artifact-grid");for(const artifact of state.artifacts)list.append(artifactItem(artifact));body.replaceChildren(list)}
      panel.scrollTop=scroll;if(focused)Array.from(body.querySelectorAll("[data-focus-key]")).find(node=>node.dataset.focusKey===focused)?.focus()}
    function artifactKind(artifact){const kind=String(artifact.kind||"file");return kind[0].toUpperCase()+kind.slice(1)}
    function artifactSize(bytes){if(!(bytes>=0))return"";const units=["bytes","KB","MB","GB"];let value=bytes,unit=0;while(value>=1000&&unit<units.length-1){value/=1000;unit++}
      return unit?`${value<10?value.toFixed(1):Math.round(value)} ${units[unit]}`:`${bytes} ${bytes===1?"byte":"bytes"}`}
    function artifactDuration(seconds){const total=Math.round(seconds),minutes=Math.floor(total/60),rest=total%60;return`${minutes}:${String(rest).padStart(2,"0")}`}
    function artifactFileName(artifact){return String(artifact.relativePath||"").split("/").pop()||artifact.title}
    function artifactBadge(artifact){const extension=artifactFileName(artifact).split(".");return extension.length>1?extension.pop().slice(0,5).toUpperCase():artifactKind(artifact)}
    function artifactItem(artifact){const item=homeNode("li"),card=homeNode("button","artifact-card"),thumb=homeNode("span","artifact-thumb"),meta=homeNode("span","artifact-meta"),remove=homeNode("button","artifact-delete");
      card.type="button";card.dataset.focusKey=`artifact:${artifact.id}`;card.title=artifact.kind==="image"?"Opens the image":"Downloads the file";card.onclick=()=>openArtifact(artifact,card);
      meta.append(homeNode("span","artifact-kind",artifactKind(artifact)),homeNode("span",null,artifactSize(artifact.size)));card.append(thumb,homeNode("span","artifact-title",artifact.title),meta);
      remove.type="button";remove.title="Delete";remove.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M9 3h6l1 2h4v2H4V5h4zM6 9h12l-1 12H7zm4 2v8h1.5v-8zm2.5 0v8H14v-8z"/></svg>';remove.dataset.focusKey=`artifact-delete:${artifact.id}`;remove.setAttribute("aria-label",`Delete ${artifact.title}`);remove.onclick=()=>deleteArtifact(artifact);
      item.append(card,remove);showArtifactThumb(artifact,card);return item}
    function showArtifactThumb(artifact,card){const cached=artifactThumbs.get(artifact.id),thumb=card.querySelector(".artifact-thumb"),kind=card.querySelector(".artifact-kind");
      if(cached?.src){const img=homeNode("img");img.alt="";img.src=cached.src;thumb.replaceChildren(img)}else thumb.replaceChildren(homeNode("span",null,artifactBadge(artifact)));
      if(cached?.duration)setText(kind,`${artifactKind(artifact)} · ${artifactDuration(cached.duration)}`);
      card.setAttribute("aria-label",[artifact.title,artifactKind(artifact),cached?.duration?artifactDuration(cached.duration):null,artifactSize(artifact.size)].filter(Boolean).join(", "));
      if(!cached&&(artifact.kind==="image"||artifact.kind==="video")){artifactThumbs.set(artifact.id,{pending:true});artifactThumbQueue.push(artifact);pumpArtifactThumbs()}}
    function pumpArtifactThumbs(){while(artifactThumbActive<3&&artifactThumbQueue.length){const artifact=artifactThumbQueue.shift(),requestToken=token;artifactThumbActive++;
      api(`/api/v1/home/artifacts/${artifact.id}/thumbnail`).then(data=>{if(requestToken===token)artifactThumbs.set(artifact.id,{src:`data:image/jpeg;base64,${data.data}`,duration:data.durationSeconds})},
        ()=>{if(requestToken===token)artifactThumbs.set(artifact.id,{failed:true})})
      .finally(()=>{artifactThumbActive--;const card=document.querySelector(`#artifactsBody [data-focus-key="artifact:${artifact.id}"]`);if(card)showArtifactThumb(artifact,card);pumpArtifactThumbs()})}}
    async function openArtifact(artifact,card){const state=artifactsState;if(!state||state.opening)return;
      if(artifact.kind==="image"){openImageViewer({kind:"preview",label:artifact.title,img:card.querySelector(".artifact-thumb img"),
        load:async()=>{const data=await mcpFetch(`/api/v1/home/artifacts/${artifact.id}`);return`data:${data.artifact?.mimeType||"image/png"};base64,${data.data}`}});return}
      state.opening=artifact.id;card.setAttribute("aria-busy","true");setText($("artifactsStatus"),`Downloading ${artifact.title}…`);
      try{const data=await mcpFetch(`/api/v1/home/artifacts/${artifact.id}`),binary=atob(data.data),bytes=new Uint8Array(binary.length);for(let index=0;index<binary.length;index++)bytes[index]=binary.charCodeAt(index);
        const url=URL.createObjectURL(new Blob([bytes],{type:data.artifact?.mimeType||"application/octet-stream"})),link=homeNode("a");link.href=url;link.download=artifactFileName(artifact);document.body.append(link);link.click();link.remove();
        setTimeout(()=>URL.revokeObjectURL(url),60000);setText($("artifactsStatus"),`Downloaded ${artifact.title}.`)}
      catch(error){setText($("artifactsError"),`Couldn't open ${artifact.title}: ${error.message}`)}
      finally{if(state===artifactsState)state.opening=null;card.removeAttribute("aria-busy")}}
    async function deleteArtifact(artifact){if(!confirm(`Delete ${artifact.title}?\n\nThis permanently deletes the file from your Mac.`))return;
      try{await api(`/api/v1/home/artifacts/${artifact.id}`,{method:"DELETE"});artifactThumbs.delete(artifact.id);const state=artifactsState;if(!state)return;
        state.artifacts=state.artifacts.filter(item=>item.id!==artifact.id);renderArtifacts();setText($("artifactsStatus"),`Deleted ${artifact.title}.`);$("artifactsTitle").focus();loadArtifacts()}
      catch(error){setText($("artifactsError"),`Couldn't delete ${artifact.title}: ${error.message}`)}}
    function createArtifactInChat(){const home=sessionItems.find(item=>item.isCantripHome);$("artifactsPanel").close();
      if(home&&selected!==home.id){selectTab(home.id);renderedPayload="";renderProgress(home);refresh()}
      const draft=$("draft");if(!draft.value.trim())draft.value="Create a ";draft.dispatchEvent(new Event("input",{bubbles:true}));draft.focus();draft.setSelectionRange(draft.value.length,draft.value.length)}
    $("homeArtifacts").onclick=openArtifacts;$("artifactsDone").onclick=()=>$("artifactsPanel").close();$("artifactsCreate").onclick=createArtifactInChat;
    $("artifactsPanel").addEventListener("close",()=>{closeArtifacts();$("artifactsBody").replaceChildren();setText($("artifactsStatus"),"")});
    $("homeTasks").onclick=openTasks;$("tasksDone").onclick=()=>$("tasksPanel").close();$("tasksBack").onclick=()=>showTask(null);
    $("tasksSearch").oninput=()=>{if(tasksState){renderTasks();$("tasksPanel").scrollTop=0}};
    $("tasksPanel").addEventListener("close",()=>{closeTasks();$("tasksBody").replaceChildren();setText($("tasksStatus"),"")});
    function readTabLink(){const match=/^#tab=([0-9A-Fa-f-]{36})$/.exec(location.hash);return match?match[1].toUpperCase():null}
    let tabLink=readTabLink();window.addEventListener("hashchange",()=>{tabLink=readTabLink();if(tabLink&&token)refresh()});
    async function startRemoteUI(){
      if(token){const focus=await restoreUIState();if(!token)return;pair(false);
        if(focus){$("draft").focus();if(Number.isInteger(focus.start)&&Number.isInteger(focus.end))$("draft").setSelectionRange(focus.start,focus.end)}
        refresh();
      }else pair(true);
    }
    startRemoteUI();
    </script></body></html>
    """
}

/// Where the encrypted LAN listener ended up. `requestedPort` is the pinned port, if any.
struct RemoteLANStatus: Equatable {
    let port: Int
    let requestedPort: Int?

    /// The pinned port was busy, so a dynamic port is in use.
    var fellBack: Bool { requestedPort != nil && requestedPort != port }
}

enum RemoteLANStatusText {
    /// Settings' line under the direct port: the address to save in a client profile, or why the
    /// pinned port isn't in use.
    static func describe(_ status: RemoteLANStatus?, pinnedPort: Int, addresses: [String]) -> String {
        guard let status else { return "The encrypted local-network connection is starting." }
        if status.fellBack, let requested = status.requestedPort {
            return "Port \(requested) is in use by another app, so the encrypted connection is on port \(status.port) for now. Choose another direct port."
        }
        guard pinnedPort != 0 else {
            return "Encrypted local-network port \(status.port) (automatic; it changes when Cantrip restarts). Set a direct port to save this Mac's direct address in Cantrip Agent."
        }
        let direct = addresses.map { "\($0):\(status.port)" }
        return direct.isEmpty
            ? "Encrypted local-network port \(status.port). Add <this Mac's IP>:\(status.port) as the direct address in Cantrip Agent."
            : "Direct address: \(direct.joined(separator: " or ")). Add it to a Cantrip Agent or Gateway Mac profile with this Mac's pairing token; Tailscale subnet routes reach it away from home."
    }
}
