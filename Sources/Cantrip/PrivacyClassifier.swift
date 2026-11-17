import Foundation

/// Where the Privacy Gate asks: an OpenAI-compatible server with Splash's `POST /judgments` or
/// oMLX's `POST /decisions` (the classifier finds out which, `PrivacyClassifier.API`).
struct PrivacyClassifierEndpoint: Equatable {
    /// The server's OpenAI-compatible base, ending in /v1.
    let baseURL: URL
    let model: String

    var judgmentsURL: URL { baseURL.appendingPathComponent("judgments") }
    var decisionsURL: URL { baseURL.appendingPathComponent("decisions") }
    var modelsURL: URL { baseURL.appendingPathComponent("models") }
    /// The base without a trailing slash, as settings and the log show it.
    var address: String { baseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }

    /// The classifier's address: its own settings, else the Private Local server when that speaks
    /// the OpenAI-compatible API.
    static func resolve(_ settings: PrivacyClassifierSettings,
                        privateLocal: PrivateLocalConfiguration?) -> Result<Self, PrivacyClassifierError> {
        guard settings.enabled else { return .failure(.notConfigured("The classifier is off.")) }
        var base = settings.baseURL.trimmingCharacters(in: .whitespaces)
        var model = settings.model.trimmingCharacters(in: .whitespaces)
        if base.isEmpty, let local = privateLocal, local.api == .openAI {
            base = local.baseURL
            if model.isEmpty { model = local.model }
        }
        guard !base.isEmpty else {
            return .failure(.notConfigured("No classifier server: set one, or point Private Local at an OpenAI-compatible server."))
        }
        guard !model.isEmpty else { return .failure(.notConfigured("No classifier model is set.")) }
        if let problem = PrivacyHostCheck.problem(with: base) { return .failure(.notConfigured(problem)) }
        let trimmed = base.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: trimmed) else { return .failure(.notConfigured("Invalid classifier address.")) }
        return .success(Self(baseURL: url, model: model))
    }
}

enum PrivacyClassifierError: Error, Equatable {
    case notConfigured(String)
    case unreachable(String)
    case timedOut(Int)
    case badResponse(String)

    var message: String {
        switch self {
        case .notConfigured(let text): return text
        case .unreachable(let text): return "The classifier server didn't answer: \(text)"
        case .timedOut(let ms): return "The classifier didn't answer within \(ms) ms."
        case .badResponse(let text): return "The classifier's answer couldn't be read: \(text)"
        }
    }
}

/// The classifier's averaged answer.
struct PrivacyClassification: Equatable {
    var probabilities: [PrivacyRoute: Double]
    /// Rotations that answered (refusals are left out of the average).
    var answered: Int
    var elapsedMs: Int

    func probability(_ route: PrivacyRoute) -> Double { probabilities[route] ?? 0 }

    /// Cloud only when it's clearly cloud; otherwise local or ask, never a guess toward the cloud.
    func route(cloudMinimum: Double, uncertain: PrivacyRoute) -> PrivacyRoute {
        if probability(.cloud) >= cloudMinimum { return .cloud }
        if probability(.local) >= 0.5 { return .local }
        if probability(.redactApprove) >= 0.5 { return .redactApprove }
        return uncertain == .cloud ? .redactApprove : uncertain
    }
}

/// Asks one question several times with the options rotated and averages the per-option
/// probabilities: on Splash, one `POST /judgments` per rotation, sent together; on oMLX, every
/// rotation in one `POST /decisions` (the server reuses the shared prompt's prefix cache).
final class PrivacyClassifier {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    /// The scoring API a server has. Both read the same question and options and give each option
    /// a probability; Splash scores rotations side by side, oMLX one after another.
    enum API: String {
        case judgments, decisions
    }

    /// Scored on a labeled synthetic set (`CANTRIP_PRIVACY_CLASSIFIER_LIVE_TEST`). The earlier wording
    /// kept every private request off the cloud but sent 1 of 12 plain ones there.
    static let instructions = """
        Decide where this request to a personal AI assistant should run. Most requests are not \
        private: coding, debugging, pasted code, logs and error messages, writing, planning, general \
        knowledge, questions about apps or about testing and setting up the assistant itself \
        (including its privacy features), and routine work on the user's computer (files, folders, \
        builds, git, simulators) belong in the cloud. Answer local only when the request itself \
        contains or asks about private information: the user's messages or email, health, money, \
        bank or other accounts, passwords, family and relationships, legal matters, identity \
        documents, or details about other people. Answer redact when it is mainly a general task \
        that mentions a few personal details (a name, phone number or address) that could be hidden \
        before sending.
        """
    static let choices: [(PrivacyRoute, String)] = [
        (.local, "run on the private model at home"),
        (.cloud, "send to a cloud AI service"),
        (.redactApprove, "hide personal details, then ask before sending"),
    ]

    private let transport: Transport
    /// The API each server answered with last, tried first next time; the other one when it's
    /// missing (a server swapped between oMLX and Splash).
    private var learned: [URL: API] = [:]
    private let lock = NSLock()

    init(transport: Transport? = nil) {
        self.transport = transport ?? PrivacyClassifier.urlSessionTransport
    }

    func preferredAPI(for endpoint: PrivacyClassifierEndpoint) -> API {
        lock.lock(); defer { lock.unlock() }
        return learned[endpoint.baseURL] ?? .judgments
    }

    private func learn(_ api: API, for endpoint: PrivacyClassifierEndpoint) {
        lock.lock(); learned[endpoint.baseURL] = api; lock.unlock()
    }

    /// The option order of each rotation: each option leads once; past three, reversed orders.
    static func orders(rotations: Int) -> [[Int]] {
        let count = choices.count
        return (0..<max(1, rotations)).map { index in
            let rotated = (0..<count).map { ($0 + index) % count }
            return index / count % 2 == 1 ? rotated.reversed() : rotated
        }
    }

    static func body(text: String, model: String, rotations: Int) throws -> Data {
        let questions: [[String: Any]] = orders(rotations: rotations).enumerated().map { index, order in
            ["name": "route_\(index)", "type": "choice", "instructions": instructions,
             "choices": order.map { ["value": wireValue(choices[$0].0), "description": choices[$0].1] }]
        }
        return try JSONSerialization.data(withJSONObject: ["model": model, "input": text, "questions": questions])
    }

    /// One `POST /judgments` row per rotation: the request is the evidence, the instructions the
    /// question, and the options in that rotation's order.
    static func judgmentBodies(text: String, model: String, rotations: Int) throws -> [Data] {
        try orders(rotations: rotations).enumerated().map { index, order in
            try JSONSerialization.data(withJSONObject: [
                "model": model, "id": "route_\(index)", "state": text, "question": instructions,
                "options": order.map { ["id": wireValue(choices[$0].0), "description": choices[$0].1] },
            ] as [String: Any])
        }
    }

    static func wireValue(_ route: PrivacyRoute) -> String { route == .redactApprove ? "redact" : route.rawValue }

    private static func route(wire value: String) -> PrivacyRoute? {
        choices.map(\.0).first { wireValue($0) == value }
    }

    /// One judgment's probabilities by route: `option_ids` and `probabilities` in the same order
    /// (a map of id to probability is read too). Nil unless every option is there.
    static func parseJudgment(_ data: Data) -> [PrivacyRoute: Double]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [PrivacyRoute: Double] = [:]
        if let ids = object["option_ids"] as? [String], let values = object["probabilities"] as? [NSNumber],
           ids.count == values.count {
            for (id, value) in zip(ids, values) { if let route = route(wire: id) { result[route] = value.doubleValue } }
        } else if let map = object["probabilities"] as? [String: NSNumber] {
            for (id, value) in map { if let route = route(wire: id) { result[route] = value.doubleValue } }
        }
        return result.count == choices.count ? result : nil
    }

    static func parse(_ data: Data) throws -> (probabilities: [PrivacyRoute: Double], answered: Int) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [[String: Any]] else {
            throw PrivacyClassifierError.badResponse("no answers")
        }
        var sums: [PrivacyRoute: Double] = [:]
        var answered = 0
        for answer in answers where answer["type"] as? String == "choice" {
            guard let probabilities = answer["probabilities"] as? [[String: Any]] else { continue }
            var seen = 0
            for entry in probabilities {
                guard let value = entry["value"] as? String, let p = (entry["probability"] as? NSNumber)?.doubleValue,
                      let route = route(wire: value) else { continue }
                sums[route, default: 0] += p
                seen += 1
            }
            if seen == choices.count { answered += 1 }
        }
        guard answered > 0 else { throw PrivacyClassifierError.badResponse("every rotation was refused") }
        return (sums.mapValues { $0 / Double(answered) }, answered)
    }

    func classify(text: String, endpoint: PrivacyClassifierEndpoint,
                  settings: PrivacyClassifierSettings) async -> Result<PrivacyClassification, PrivacyClassifierError> {
        let started = Date()
        let timeout = max(100, settings.timeoutMs)
        let first = preferredAPI(for: endpoint)
        var missing: [API] = []
        for api in [first, first == .judgments ? API.decisions : .judgments] {
            let left = timeout - Int(Date().timeIntervalSince(started) * 1000)
            guard left > 0 else { return .failure(.timedOut(timeout)) }
            let outcome = await Self.within(left, total: timeout) { [self] in
                await ask(api, text: text, endpoint: endpoint, settings: settings, timeoutMs: left)
            }
            if case .failure(.unreachable(let detail)) = outcome, detail == Self.missingAPI {
                missing.append(api)
                continue
            }
            switch outcome {
            case .failure(let error):
                return .failure(error)
            case .success(let parsed):
                learn(api, for: endpoint)
                return .success(PrivacyClassification(probabilities: parsed.probabilities, answered: parsed.answered,
                                                       elapsedMs: Int(Date().timeIntervalSince(started) * 1000)))
            }
        }
        return .failure(.unreachable("the server has neither POST /judgments nor POST /decisions (HTTP 404)"))
    }

    /// Marks an answer that means "this server has no such API" (404, 405 or 501), so the other
    /// one is tried.
    private static let missingAPI = "missing API"

    private struct Parsed { let probabilities: [PrivacyRoute: Double]; let answered: Int }

    private func ask(_ api: API, text: String, endpoint: PrivacyClassifierEndpoint, settings: PrivacyClassifierSettings,
                     timeoutMs: Int) async -> Result<Parsed, PrivacyClassifierError> {
        func request(_ url: URL, _ body: Data) -> URLRequest {
            var request = URLRequest(url: url, timeoutInterval: Double(timeoutMs) / 1000)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        switch api {
        case .decisions:
            let body: Data
            do { body = try Self.body(text: text, model: endpoint.model, rotations: settings.rotations) }
            catch { return .failure(.badResponse(error.localizedDescription)) }
            switch await send(request(endpoint.decisionsURL, body), timeoutMs: timeoutMs) {
            case .failure(let error): return .failure(error)
            case .success(let data):
                do {
                    let parsed = try Self.parse(data)
                    return .success(Parsed(probabilities: parsed.probabilities, answered: parsed.answered))
                } catch let error as PrivacyClassifierError {
                    return .failure(error)
                } catch {
                    return .failure(.badResponse(error.localizedDescription))
                }
            }
        case .judgments:
            let bodies: [Data]
            do { bodies = try Self.judgmentBodies(text: text, model: endpoint.model, rotations: settings.rotations) }
            catch { return .failure(.badResponse(error.localizedDescription)) }
            let requests = bodies.map { request(endpoint.judgmentsURL, $0) }
            let replies = await withTaskGroup(of: Result<Data, PrivacyClassifierError>.self) { group in
                for request in requests { group.addTask { await self.send(request, timeoutMs: timeoutMs) } }
                var replies: [Result<Data, PrivacyClassifierError>] = []
                for await reply in group { replies.append(reply) }
                return replies
            }
            var sums: [PrivacyRoute: Double] = [:]
            var answered = 0
            var firstError: PrivacyClassifierError?
            for reply in replies {
                switch reply {
                case .success(let data):
                    guard let probabilities = Self.parseJudgment(data) else {
                        firstError = firstError ?? .badResponse("a judgment without every option")
                        continue
                    }
                    for (route, p) in probabilities { sums[route, default: 0] += p }
                    answered += 1
                case .failure(let error):
                    if case .unreachable(Self.missingAPI) = error { return .failure(error) }
                    firstError = firstError ?? error
                }
            }
            guard answered > 0 else { return .failure(firstError ?? .badResponse("no answers")) }
            return .success(Parsed(probabilities: sums.mapValues { $0 / Double(answered) }, answered: answered))
        }
    }

    /// One HTTP exchange: the body on a 2xx answer; a missing-API marker on 404, 405 or 501.
    private func send(_ request: URLRequest, timeoutMs: Int) async -> Result<Data, PrivacyClassifierError> {
        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.unreachable([404, 405, 501].contains(http.statusCode)
                                              ? Self.missingAPI : "HTTP \(http.statusCode)"))
            }
            return .success(data)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timedOut(timeoutMs))
        } catch is CancellationError {
            return .failure(.timedOut(timeoutMs))
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.timedOut(timeoutMs))
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// `work`'s result, or a timeout after `ms` (reported as the whole budget, `total`) without
    /// waiting for the server.
    private static func within<T>(_ ms: Int, total: Int,
                                  _ work: @escaping @Sendable () async -> Result<T, PrivacyClassifierError>)
        async -> Result<T, PrivacyClassifierError> {
        await withTaskGroup(of: Result<T, PrivacyClassifierError>?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return Task.isCancelled ? nil : .failure(.timedOut(total))
            }
            var result: Result<T, PrivacyClassifierError> = .failure(.timedOut(total))
            for await next in group {
                if let next { result = next; break }
            }
            group.cancelAll()
            if case .failure(.timedOut) = result { return .failure(.timedOut(total)) }
            return result
        }
    }

    /// Opens the connection (TLS, the tailnet path) before the question, with a request that carries
    /// no prompt text: `GET {base}/models`.
    func prewarm(endpoint: PrivacyClassifierEndpoint) async {
        var request = URLRequest(url: endpoint.modelsURL, timeoutInterval: 5)
        request.httpMethod = "GET"
        _ = try? await transport(request)
    }

    // MARK: - Transport

    /// Refuses redirects, so an answer only ever comes from the configured server.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) {
            throw URLError(.redirectToNonExistentLocation)
        }
        return (data, response)
    }
}
