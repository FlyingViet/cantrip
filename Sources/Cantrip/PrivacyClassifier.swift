import Foundation

/// Where the Privacy Gate asks: an OpenAI-compatible server with oMLX's `POST /decisions`.
struct PrivacyClassifierEndpoint: Equatable {
    let decisionsURL: URL
    let model: String

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
        guard let url = URL(string: trimmed + "/decisions") else { return .failure(.notConfigured("Invalid classifier address.")) }
        return .success(Self(decisionsURL: url, model: model))
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

/// Asks one question several times with the options rotated (one HTTP request; the server reuses
/// the shared prompt's prefix cache) and averages the per-option probabilities.
final class PrivacyClassifier {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

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

    init(transport: Transport? = nil) {
        self.transport = transport ?? PrivacyClassifier.urlSessionTransport
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

    static func wireValue(_ route: PrivacyRoute) -> String { route == .redactApprove ? "redact" : route.rawValue }

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
                      let route = choices.map(\.0).first(where: { wireValue($0) == value }) else { continue }
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
        var request = URLRequest(url: endpoint.decisionsURL, timeoutInterval: Double(timeout) / 1000)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try Self.body(text: text, model: endpoint.model, rotations: settings.rotations)
        } catch {
            return .failure(.badResponse(error.localizedDescription))
        }
        let transport = self.transport
        let outcome: Result<(Data, URLResponse), PrivacyClassifierError> = await withTaskGroup(
            of: Result<(Data, URLResponse), PrivacyClassifierError>?.self
        ) { group in
            group.addTask {
                do { return .success(try await transport(request)) }
                catch is CancellationError { return nil }
                catch let error as URLError where error.code == .cancelled { return nil }
                catch let error as URLError where error.code == .timedOut { return .failure(.timedOut(timeout)) }
                catch { return .failure(.unreachable(error.localizedDescription)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                return Task.isCancelled ? nil : .failure(.timedOut(timeout))
            }
            var result: Result<(Data, URLResponse), PrivacyClassifierError> = .failure(.timedOut(timeout))
            for await next in group {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome {
        case .failure(let error): return .failure(error)
        case .success(let (data, response)):
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.unreachable("HTTP \(http.statusCode)"))
            }
            do {
                let parsed = try Self.parse(data)
                return .success(PrivacyClassification(probabilities: parsed.probabilities, answered: parsed.answered,
                                                       elapsedMs: elapsed))
            } catch let error as PrivacyClassifierError {
                return .failure(error)
            } catch {
                return .failure(.badResponse(error.localizedDescription))
            }
        }
    }

    /// Opens the connection (TLS, the tailnet path) before the question, with a request that carries
    /// no prompt text: `GET {base}/models`.
    func prewarm(endpoint: PrivacyClassifierEndpoint) async {
        var request = URLRequest(url: endpoint.decisionsURL.deletingLastPathComponent().appendingPathComponent("models"),
                                 timeoutInterval: 5)
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
