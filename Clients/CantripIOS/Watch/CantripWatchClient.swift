import Foundation

/// Signed requests from the watch to Cantrip on the Mac, shared by the app and Siri.
/// Tries the tailnet route (through the paired iPhone), then the optional internet route.
actor CantripWatchClient {
    /// Sends one request. watchOS URLSession ignores custom URL protocols, so tests replace this.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxAudioBytes = 4 * 1024 * 1024

    private var configuration: CantripWatchConfiguration
    private let signer: CantripDeviceSigner
    private let transport: Transport
    private var confirmedRoute: (route: CantripWatchRoute, at: Date)?

    init(configuration: CantripWatchConfiguration, signer: CantripDeviceSigner, transport: Transport? = nil) {
        self.configuration = configuration
        self.signer = signer
        self.transport = transport ?? { [session = Self.session] in try await session.data(for: $0) }
    }

    /// The client for the saved setup.
    static func current() throws -> CantripWatchClient {
        guard let configuration = WatchSettings.configuration else { throw CantripWatchError.notSetUp }
        return CantripWatchClient(configuration: configuration, signer: try WatchSettings.signer())
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    // MARK: Voice API

    func startTurn(audio: Data, contentType: String = "audio/mp4") async throws -> CantripVoiceTurn {
        guard audio.count <= Self.maxAudioBytes else { throw CantripWatchError.clipTooLarge }
        // The Mac transcribes before it answers, so the upload gets a longer deadline.
        return try await startTurn(body: audio, contentType: contentType, timeout: 60)
    }

    func startTurn(text: String) async throws -> CantripVoiceTurn {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        return try await startTurn(body: body, contentType: "application/json", timeout: 20)
    }

    func turn(id: String, wait: Int) async throws -> CantripVoiceTurn {
        guard let target = CantripWatchURL.turnTarget(id: id, wait: wait) else {
            throw CantripWatchError.failed("Cantrip on your Mac sent an unexpected answer.")
        }
        let data = try await perform(method: "GET", target: target, body: Data(), contentType: nil,
                                     timeout: TimeInterval(wait) + 10, idempotent: true)
        return try decodeTurn(data)
    }

    /// Long-polls `turn` until it is done or failed, or `deadline` passes (then it is returned unfinished).
    func follow(
        _ turn: CantripVoiceTurn, until deadline: Date,
        onUpdate: @escaping @Sendable (CantripVoiceTurn) async -> Void = { _ in }
    ) async throws -> CantripVoiceTurn {
        var current = turn
        while !current.isFinished {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= 1 else { break }
            let started = Date()
            let next = try await self.turn(id: current.id, wait: min(20, Int(remaining)))
            if next != current { await onUpdate(next) }
            current = next
            if !current.isFinished, Date().timeIntervalSince(started) < 1 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        return current
    }

    /// Checks the Mac is reachable (and Home is on), refreshing the internet route.
    @discardableResult
    func refreshConfig() async throws -> CantripVoiceConfig? {
        let routes = CantripWatchRoute.order(
            tailnet: configuration.tailnet, internet: configuration.internet, lastWorking: WatchSettings.lastRoute
        )
        for (route, base) in routes {
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await attempt(base: base, method: "GET", target: "/api/v1/voice/config",
                                                 body: Data(), contentType: nil, timeout: 8)
            } catch let error as URLError where error.code != .cancelled {
                continue
            }
            remember(route)
            if http.statusCode == 401 { throw CantripWatchError.unauthorized }
            // A Mac without the config endpoint is still reachable on this route.
            guard http.statusCode == 200,
                  let config = try? JSONDecoder().decode(CantripVoiceConfig.self, from: data) else { return nil }
            let internet = CantripWatchURL.origin(config.internet)
            if internet != configuration.internet {
                configuration.internet = internet
                WatchSettings.saveInternet(internet)
            }
            return config
        }
        throw CantripWatchError.unreachable
    }

    // MARK: Requests

    private func startTurn(body: Data, contentType: String, timeout: TimeInterval) async throws -> CantripVoiceTurn {
        let reachedRecently = confirmedRoute.map { Date().timeIntervalSince($0.at) < 60 } ?? false
        if !reachedRecently, try await refreshConfig()?.home?.available == false {
            throw CantripWatchError.homeOff
        }
        let data = try await perform(method: "POST", target: "/api/v1/voice/turns", body: body,
                                     contentType: contentType, timeout: timeout, idempotent: false)
        return try decodeTurn(data)
    }

    private func perform(
        method: String, target: String, body: Data, contentType: String?,
        timeout: TimeInterval, idempotent: Bool
    ) async throws -> Data {
        let routes = CantripWatchRoute.order(
            tailnet: configuration.tailnet, internet: configuration.internet,
            lastWorking: confirmedRoute?.route ?? WatchSettings.lastRoute
        )
        for (route, base) in routes {
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await attempt(base: base, method: method, target: target, body: body,
                                                 contentType: contentType, timeout: timeout)
            } catch let error as URLError where Self.canTryNextRoute(error, idempotent: idempotent) {
                if confirmedRoute?.route == route { confirmedRoute = nil }
                continue
            } catch let error as URLError where error.code != .cancelled {
                throw CantripWatchError.unreachable
            }
            remember(route)
            guard (200..<300).contains(http.statusCode) else {
                throw CantripWatchError.http(http.statusCode, body: data)
            }
            return data
        }
        throw CantripWatchError.unreachable
    }

    private func attempt(
        base: URL, method: String, target: String, body: Data, contentType: String?, timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = CantripWatchURL.url(base: base, target: target) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if method != "GET" { request.httpBody = body }
        let headers = try CantripDeviceSignature.headers(
            deviceID: configuration.deviceID, method: method, target: target, body: body,
            sign: { try signer.signature(for: $0) }
        )
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func remember(_ route: CantripWatchRoute) {
        confirmedRoute = (route, Date())
        if WatchSettings.lastRoute != route { WatchSettings.lastRoute = route }
    }

    private func decodeTurn(_ data: Data) throws -> CantripVoiceTurn {
        guard let envelope = try? JSONDecoder().decode(CantripVoiceTurnEnvelope.self, from: data) else {
            throw CantripWatchError.failed("Cantrip on your Mac sent an unexpected answer. Update Cantrip on the Mac.")
        }
        return envelope.turn
    }

    /// GETs move on after any network failure. A POST moves on only when it surely never reached the
    /// Mac, so a turn is never sent twice.
    private static func canTryNextRoute(_ error: URLError, idempotent: Bool) -> Bool {
        switch error.code {
        case .cancelled:
            return false
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .appTransportSecurityRequiresSecureConnection,
             .internationalRoamingOff, .dataNotAllowed, .badURL:
            return true
        default:
            return idempotent
        }
    }
}
