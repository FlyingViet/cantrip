import Foundation
import Network

/// The `model` names the endpoint accepts.
/// - `auto` (also empty, and any name that isn't a backend, so clients written for another
///   server keep working): the Mac's backend, then its usage-limit backup chain.
/// - `copilot`, `claude`, `antigravity`, `local`: that backend with its default model, no backups.
/// - `copilot:gpt-5.6-sol`: that backend and model, no backups.
enum OpenAIEndpointModel: Equatable {
    case auto
    case backend(BackendKind, model: String)

    static func parse(_ name: String?) -> OpenAIEndpointModel {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let kind = HostControl.backend(named: parts[0]), !parts[0].isEmpty else { return .auto }
        return .backend(kind, model: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    /// The short name requests and `/v1/models` use for a backend.
    static func alias(_ kind: BackendKind) -> String {
        switch kind {
        case .copilot: return "copilot"
        case .claudeCode: return "claude"
        case .antigravity: return "antigravity"
        case .codex: return "codex"
        case .localModel: return "local"
        case .copilotRemote: return "copilot-remote"
        }
    }

    static func name(_ kind: BackendKind, model: String) -> String {
        model.isEmpty ? alias(kind) : "\(alias(kind)):\(model)"
    }
}

/// A `POST /v1/chat/completions` body, checked and reduced to a `OneShotPrompt`.
struct OpenAIEndpointRequest {
    var model: OpenAIEndpointModel
    var requestedModel: String
    var prompt: OneShotPrompt
    var stream: Bool
    var includeUsageInStream: Bool
    var effort: String?

    struct Invalid: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static let maximumImageBytes = 10 * 1024 * 1024

    static func parse(_ body: Data) throws -> OpenAIEndpointRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Invalid("Send a JSON object.")
        }
        guard let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw Invalid("messages must be a non-empty array of message objects.")
        }
        if let tools = object["tools"] as? [Any], !tools.isEmpty { throw Invalid("This endpoint is tool-free: tools aren't supported.") }
        if let functions = object["functions"] as? [Any], !functions.isEmpty {
            throw Invalid("This endpoint is tool-free: functions aren't supported.")
        }
        if let n = object["n"] as? Int, n != 1 { throw Invalid("Only n = 1 is supported.") }
        var system: [String] = []
        var turns: [OneShotPrompt.Turn] = []
        var images: [OneShotPrompt.Image] = []
        for message in messages {
            let role = (message["role"] as? String ?? "").lowercased()
            if message["tool_calls"] != nil || message["function_call"] != nil {
                throw Invalid("This endpoint is tool-free: tool calls aren't supported.")
            }
            let (text, attached) = try content(message["content"])
            switch role {
            case "system", "developer":
                guard attached.isEmpty else { throw Invalid("Images belong in user messages.") }
                if !text.isEmpty { system.append(text) }
            case "user", "assistant":
                guard role == "user" || attached.isEmpty else { throw Invalid("Images belong in user messages.") }
                images += attached
                turns.append(OneShotPrompt.Turn(role: role, text: text))
            case "tool", "function":
                throw Invalid("This endpoint is tool-free: \(role) messages aren't supported.")
            default:
                throw Invalid("Unsupported message role: \(role.isEmpty ? "(none)" : role).")
            }
        }
        guard turns.contains(where: { $0.role == "user" }) else { throw Invalid("Include at least one user message.") }
        let requested = object["model"] as? String ?? ""
        var effort = (object["reasoning_effort"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        if effort?.isEmpty == true { effort = nil }
        let maxTokens = (object["max_completion_tokens"] as? Int) ?? (object["max_tokens"] as? Int)
        let streamOptions = object["stream_options"] as? [String: Any]
        return OpenAIEndpointRequest(
            model: OpenAIEndpointModel.parse(requested), requestedModel: requested,
            prompt: OneShotPrompt(system: system.joined(separator: "\n\n"), turns: turns, images: images,
                                  messagesJSON: (try? JSONSerialization.data(withJSONObject: messages)) ?? Data("[]".utf8),
                                  maxTokens: maxTokens),
            stream: object["stream"] as? Bool ?? false,
            includeUsageInStream: streamOptions?["include_usage"] as? Bool ?? false,
            effort: effort
        )
    }

    /// A message's text, and its images (base64 data URLs only: the endpoint fetches nothing).
    private static func content(_ value: Any?) throws -> (String, [OneShotPrompt.Image]) {
        if value == nil || value is NSNull { return ("", []) }
        if let text = value as? String { return (text, []) }
        guard let parts = value as? [[String: Any]] else { throw Invalid("Message content must be a string or an array of parts.") }
        var texts: [String] = []
        var images: [OneShotPrompt.Image] = []
        for part in parts {
            switch part["type"] as? String {
            case "text", "input_text":
                texts.append(part["text"] as? String ?? "")
            case "image_url", "input_image":
                let reference = part["image_url"]
                let url = (reference as? [String: Any])?["url"] as? String ?? reference as? String ?? ""
                images.append(try image(url))
            default:
                throw Invalid("Unsupported content part: \(part["type"] as? String ?? "(none)").")
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    private static func image(_ url: String) throws -> OneShotPrompt.Image {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64") else {
            throw Invalid("Images must be base64 data URLs (data:image/png;base64,...).")
        }
        let encoded = url[url.index(after: comma)...]
        guard encoded.count <= (maximumImageBytes + 2) / 3 * 4 else { throw Invalid("An image is larger than 10 MB.") }
        guard let data = Data(base64Encoded: String(encoded)) else { throw Invalid("An image isn't valid base64.") }
        guard let image = OneShotPrompt.Image(data: data) else { throw Invalid("Images must be PNG, JPEG, GIF or WebP.") }
        return image
    }
}

/// Which backends a request tries, in order.
struct OpenAIEndpointPlan: Equatable {
    struct Skipped: Equatable {
        let backend: BackendKind
        let reason: String
        /// Set when the backend was skipped for its usage limit.
        let limitedUntil: Date?
    }

    var targets: [OneShotTarget] = []
    var skipped: [Skipped] = []
    /// When the soonest skipped backend's limit lifts.
    var retryAfter: Date? { skipped.compactMap(\.limitedUntil).min() }
}

extension AppSettings {
    /// What the endpoint runs `kind` with when a request doesn't name a model: the endpoint's
    /// own model setting when it is for this backend (and still offered), else the tabs' default.
    func openAIEndpointTarget(for kind: BackendKind) -> OneShotTarget {
        let defaults = tabModelDefaults(for: kind)
        var target = kind == .localModel ? OneShotTarget(backend: kind, model: localModel)
            : OneShotTarget(backend: kind, model: defaults.model, effort: defaults.effort,
                            contextTier: kind == .copilot ? defaults.contextTier : "")
        guard case .backend(let pinned, let model) = OpenAIEndpointModel.parse(openAIEndpointModel), pinned == kind,
              !openAIEndpointModel.trimmingCharacters(in: .whitespaces).isEmpty else { return target }
        let catalog = tabModelCatalog(for: kind)
        if !model.isEmpty {
            // An empty list hasn't loaded yet: trust the choice.
            guard catalog.models.isEmpty || catalog.models.contains(where: { $0.id == model }) || kind == .localModel else {
                return target
            }
            target.model = model
        }
        if !openAIEndpointEffort.isEmpty { target.effort = openAIEndpointEffort }
        if kind == .copilot, !openAIEndpointContextTier.isEmpty { target.contextTier = openAIEndpointContextTier }
        return target
    }

    /// The Mac's backend first, then the usage-limit backups, each with its own model (a backend
    /// can come back with another model), each backend and model once.
    func openAIEndpointChain() -> [OneShotTarget] {
        var seen = Set<FallbackEntry>()
        var chain: [OneShotTarget] = []
        func add(_ target: OneShotTarget) {
            let key = FallbackEntry(backend: target.backend.rawValue, model: effectiveModel(target.backend, chosen: target.model))
            if seen.insert(key).inserted { chain.append(target) }
        }
        add(openAIEndpointTarget(for: backend))
        for entry in limitFallbackEntries {
            guard let kind = entry.kind else { continue }
            if kind == .localModel {
                add(openAIEndpointTarget(for: kind))
            } else {
                let selection = fallbackRun(for: entry).selection ?? tabModelDefaults(for: kind)
                add(OneShotTarget(backend: kind, model: selection.model, effort: selection.effort))
            }
        }
        return chain
    }
}

enum OpenAIEndpointPlanner {
    @MainActor
    static func plan(_ request: OpenAIEndpointRequest, settings: AppSettings = .shared,
                     tracker: BackendLimitTracker = .shared, now: Date = Date()) -> OpenAIEndpointPlan {
        var candidates: [OneShotTarget]
        switch request.model {
        case .auto:
            candidates = settings.openAIEndpointChain()
        case .backend(let kind, let model):
            var target = settings.openAIEndpointTarget(for: kind)
            if !model.isEmpty, model != target.model {
                target.model = model
                target.effort = ""
                target.contextTier = ""
            }
            candidates = [target]
        }
        var plan = OpenAIEndpointPlan()
        for var target in candidates {
            if let reason = OneShotCompletion.unsupportedReason(target.backend) {
                plan.skipped.append(.init(backend: target.backend, reason: reason, limitedUntil: nil))
                continue
            }
            if let until = tracker.limitedUntil(target.backend, model: settings.effectiveModel(target.backend, chosen: target.model),
                                                now: now) {
                plan.skipped.append(.init(backend: target.backend,
                                          reason: "\(target.label) is at its usage limit until \(ISODate.string(from: until)).",
                                          limitedUntil: until))
                continue
            }
            if let effort = request.effort, target.backend != .localModel {
                let catalog = settings.tabModelCatalog(for: target.backend)
                let supported = catalog.info(target.model)?.reasoningEfforts
                if supported == nil || supported?.contains(effort) == true { target.effort = effort }
            }
            plan.targets.append(target)
        }
        return plan
    }
}

/// How a request ended, for the HTTP reply and the usage ledger.
enum OpenAIEndpointOutcome {
    case answered(OneShotResult, target: OneShotTarget, fellBackFrom: [BackendKind])
    case failed(status: Int, code: String, message: String, retryAfter: Date?)
}

/// Runs a request through its plan: a usage limit marks the backend limited (for tabs too) and
/// moves on, as does a backend that can't take the request or fails. A model the request named
/// runs only there, as picked.
@MainActor
final class OpenAIEndpointService {
    let runner: (OneShotConfiguration) -> OneShotRunning
    let tracker: BackendLimitTracker
    let ledger: EndpointUsageLedger
    let gate: OneShotGate
    var timeout: TimeInterval
    var now: () -> Date

    init(runner: @escaping (OneShotConfiguration) -> OneShotRunning = { OneShotCompletion(configuration: $0) },
         tracker: BackendLimitTracker = .shared, ledger: EndpointUsageLedger = .shared,
         concurrentCalls: Int = 4, timeout: TimeInterval = 600, now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.tracker = tracker
        self.ledger = ledger
        self.gate = OneShotGate(limit: concurrentCalls)
        self.timeout = timeout
        self.now = now
    }

    func complete(_ request: OpenAIEndpointRequest, consumer: String, settings: AppSettings = .shared) async -> OpenAIEndpointOutcome {
        let started = now()
        let outcome = await attempt(request, settings: settings)
        let seconds = now().timeIntervalSince(started)
        switch outcome {
        case .answered(let result, let target, let fellBackFrom):
            Log.write("openai-endpoint: \(consumer) answered by \(target.label) in \(String(format: "%.1f", seconds))s"
                + (fellBackFrom.isEmpty ? "" : " after \(fellBackFrom.map(\.rawValue).joined(separator: ", "))"))
            ledger.record(consumer: consumer, backend: target.backend, outcome: .answered, result: result, at: started)
        case .failed(let status, let code, let message, _):
            guard code != "cancelled" else { break }
            Log.write("openai-endpoint: \(consumer) failed \(status) \(code): \(message.prefix(200))")
            ledger.record(consumer: consumer, backend: nil, outcome: status == 429 ? .limited : .failed, result: nil, at: started)
        }
        return outcome
    }

    private func attempt(_ request: OpenAIEndpointRequest, settings: AppSettings) async -> OpenAIEndpointOutcome {
        let plan = OpenAIEndpointPlanner.plan(request, settings: settings, tracker: tracker, now: now())
        let pinned: Bool
        if case .backend = request.model { pinned = true } else { pinned = false }
        guard !plan.targets.isEmpty else {
            if let retryAfter = plan.retryAfter {
                return .failed(status: 429, code: "usage_limit", message: "Every backend is at its usage limit: "
                    + plan.skipped.map { "\($0.backend.rawValue): \($0.reason)" }.joined(separator: " "),
                    retryAfter: retryAfter)
            }
            let reasons = plan.skipped.map { "\($0.backend.rawValue): \($0.reason)" }.joined(separator: " ")
            return .failed(status: pinned ? 400 : 503, code: "backend_unavailable",
                           message: reasons.isEmpty ? "No backend can answer." : reasons, retryAfter: nil)
        }
        let configuration = OneShotConfiguration.current(settings)
        let runner = runner(configuration)
        do { try await gate.acquire() } catch {
            return .failed(status: 499, code: "cancelled", message: "The request was cancelled.", retryAfter: nil)
        }
        defer { Task { await gate.release() } }
        var tried: [BackendKind] = []
        var notes: [String] = plan.skipped.map { "\($0.backend.rawValue): \($0.reason)" }
        var limits: [Date] = plan.skipped.compactMap(\.limitedUntil)
        var failedOnlyOnLimits = true
        for target in plan.targets {
            do {
                let result = try await runner.run(request.prompt, on: target, timeout: timeout)
                return .answered(result, target: target, fellBackFrom: tried)
            } catch let error as OneShotError {
                switch error {
                case .usageLimit(let report, let message):
                    let model = settings.effectiveModel(target.backend, chosen: target.model)
                    tracker.markLimited(target.backend, model: model, message: message, report: report, now: now())
                    if let until = tracker.limitedUntil(target.backend, model: model, now: now()) { limits.append(until) }
                    notes.append("\(target.label): at its usage limit (\(report.code)).")
                case .cancelled:
                    return .failed(status: 499, code: "cancelled", message: error.message, retryAfter: nil)
                case .timedOut:
                    return .failed(status: 504, code: "timeout", message: "\(target.label): \(error.message)", retryAfter: nil)
                case .unavailable(let message), .failed(let message):
                    failedOnlyOnLimits = false
                    notes.append("\(target.backend.rawValue): \(message)")
                }
                tried.append(target.backend)
            } catch {
                failedOnlyOnLimits = false
                notes.append("\(target.backend.rawValue): \(error.localizedDescription)")
                tried.append(target.backend)
            }
        }
        let message = notes.joined(separator: " ")
        if failedOnlyOnLimits, !limits.isEmpty {
            return .failed(status: 429, code: "usage_limit", message: message, retryAfter: limits.min())
        }
        return .failed(status: 502, code: "upstream_error", message: message, retryAfter: nil)
    }

    /// `GET /v1/models`: `auto`, then each usable backend's models.
    func models(settings: AppSettings = .shared) -> [[String: Any]] {
        var data: [[String: Any]] = [["id": "auto", "object": "model", "created": 0, "owned_by": "cantrip"]]
        var seen: Set<String> = ["auto"]
        func add(_ id: String, _ owner: BackendKind) {
            guard seen.insert(id).inserted else { return }
            data.append(["id": id, "object": "model", "created": 0, "owned_by": OpenAIEndpointModel.alias(owner)])
        }
        let kinds = [settings.backend] + settings.limitFallbackEntries.compactMap(\.kind)
            + [.copilot, .claudeCode, .antigravity]
        for kind in kinds where OneShotCompletion.unsupportedReason(kind) == nil {
            add(OpenAIEndpointModel.alias(kind), kind)
            if kind == .localModel {
                if !settings.localModel.isEmpty { add(OpenAIEndpointModel.name(kind, model: settings.localModel), kind) }
                continue
            }
            for model in settings.tabModelCatalog(for: kind).models where !model.id.isEmpty {
                add(OpenAIEndpointModel.name(kind, model: model.id), kind)
            }
        }
        return data
    }

    /// `GET /health`: the chain and each backend's limit. `copilot_limited_until` is the field older
    /// Copilot-only servers reported, for probes written against them.
    func health(settings: AppSettings = .shared) -> [String: Any] {
        let now = now()
        let chain = settings.openAIEndpointChain()
        let entries: [[String: Any]] = chain.map { target in
            var entry: [String: Any] = ["backend": target.backend.rawValue, "model": target.model, "effort": target.effort]
            if let reason = OneShotCompletion.unsupportedReason(target.backend) { entry["unavailable"] = reason }
            entry["limitedUntil"] = tracker.limitedUntil(target.backend, model: settings.effectiveModel(target.backend, chosen: target.model),
                                                         now: now).map { ISODate.string(from: $0) as Any } ?? NSNull()
            return entry
        }
        let usable = chain.contains {
            OneShotCompletion.unsupportedReason($0.backend) == nil
                && tracker.limitedUntil($0.backend, model: settings.effectiveModel($0.backend, chosen: $0.model), now: now) == nil
        }
        return [
            "status": usable ? "ok" : "limited", "service": "cantrip-openai",
            "backend": settings.backend.rawValue, "chain": entries,
            "fallback": settings.limitFallbackEntries.isEmpty ? "off"
                : settings.limitFallbackEntries.map { settings.fallbackRun(for: $0).label }.joined(separator: ", "),
            "copilot_limited_until": tracker.limitedUntil(.copilot, now: now).map { ISODate.string(from: $0) as Any } ?? NSNull(),
        ]
    }
}

/// Cantrip's OpenAI-compatible API on loopback: `POST /v1/chat/completions`, `GET /v1/models` and
/// `GET /health`. Each request is one stateless, tool-free call that goes through the Mac's backend
/// and usage-limit backup chain, and is counted per consumer.
///
/// A caller names itself with a path prefix, `/consumer/<name>/v1/...`, or an `X-Cantrip-Consumer`
/// header. Loopback callers need no key. A request that came through a proxy (Tailscale Serve and
/// most reverse proxies add `Tailscale-User-Login`, `X-Forwarded-For` or `Forwarded`) needs the
/// endpoint key, and is refused when no key is set.
final class OpenAIEndpoint: @unchecked Sendable {
    static let shared = OpenAIEndpoint()
    static let defaultPort = 11439
    static let maximumRequestBytes = 24 * 1024 * 1024

    private let queue = DispatchQueue(label: "cantrip.openai-endpoint")
    private var listener: NWListener?
    private(set) var port: Int?
    private var key: String?
    /// Listening at, or the error; delivered on the main thread.
    var onStatus: ((_ listening: Int?, _ error: String?) -> Void)?
    @MainActor lazy var service = OpenAIEndpointService()

    /// The port start() was asked for; a busy port is retried until stop() or another port.
    private var wantedPort: Int?

    func start(port: Int, key: String?) {
        queue.async { [self] in
            self.key = key?.isEmpty == true ? nil : key
            wantedPort = port
            guard listener == nil || self.port != port else { return }
            stopListener()
            guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                report(nil, "The API port must be between 1 and 65535.")
                return
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort)
            do {
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        Log.write("openai-endpoint: listening at http://127.0.0.1:\(port)/v1")
                        self.report(port, nil)
                    case .failed(let error):
                        Log.write("openai-endpoint: listener failed: \(error.localizedDescription)")
                        self.report(nil, "The API couldn't listen on port \(port): \(error.localizedDescription)")
                        self.stopListener()
                        // Another program (such as a service it replaces) may still hold the port.
                        self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                            guard let self, self.listener == nil, self.wantedPort == port else { return }
                            self.start(port: port, key: self.key)
                        }
                    default:
                        break
                    }
                }
                self.listener = listener
                self.port = port
                listener.start(queue: queue)
            } catch {
                report(nil, "The API couldn't listen on port \(port): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            wantedPort = nil
            stopListener()
            report(nil, nil)
        }
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func report(_ port: Int?, _ error: String?) {
        let onStatus = onStatus
        DispatchQueue.main.async { onStatus?(port, error) }
    }

    // MARK: - Connections

    private final class Connection: @unchecked Sendable {
        let socket: NWConnection
        var task: Task<Void, Never>?
        var finished = false
        init(_ socket: NWConnection) { self.socket = socket }
    }

    private func accept(_ socket: NWConnection) {
        let connection = Connection(socket)
        socket.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { connection.task?.cancel() }
            default: break
            }
        }
        socket.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: Connection, buffer: Data) {
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if next.count > Self.maximumRequestBytes {
                self.reply(connection, status: 413, error: ("Requests are limited to 24 MB.", "invalid_request_error", "request_too_large"))
                return
            }
            if let header = next.range(of: Data([13, 10, 13, 10])),
               let head = String(data: next[..<header.lowerBound], encoding: .utf8),
               head.lowercased().contains("\r\ntransfer-encoding:") {
                self.reply(connection, status: 411, error: ("Send the body with a Content-Length.", "invalid_request_error", "length_required"))
                return
            }
            if let request = HTTPRequest.parse(next) {
                self.watchForDisconnect(connection)
                self.handle(request, on: connection)
            } else if !HTTPRequest.needsMoreData(next) {
                self.reply(connection, status: 400, error: ("Malformed HTTP request.", "invalid_request_error", "bad_request"))
            } else if isComplete || error != nil {
                connection.socket.cancel()
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    /// A caller that gives up (closes the socket) stops its model call.
    private func watchForDisconnect(_ connection: Connection) {
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self, !connection.finished else { return }
            if isComplete || error != nil {
                connection.task?.cancel()
            } else {
                self.watchForDisconnect(connection)
            }
        }
    }

    /// `/consumer/<name>/...` names the caller; the path after it is the API path.
    static func split(path: String, headers: [String: String]) -> (consumer: String, path: String) {
        var path = path
        var consumer = headers["x-cantrip-consumer"] ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "consumer" {
            consumer = String(parts[1])
            path = "/" + parts.dropFirst(2).joined(separator: "/")
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (consumerName(consumer), path)
    }

    static func consumerName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = String(raw.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "unlabeled" : cleaned
    }

    /// Proxied requests need the key; loopback callers don't (their Authorization is ignored, as
    /// OpenAI clients send a placeholder key).
    static func authorize(_ headers: [String: String], key: String?) -> (status: Int, message: String)? {
        let proxied = ["tailscale-user-login", "x-forwarded-for", "forwarded", "x-real-ip"].contains { headers[$0] != nil }
        guard proxied else { return nil }
        guard let key, !key.isEmpty else {
            return (403, "This API answers only on this Mac. Set an API key in Cantrip to reach it through a proxy.")
        }
        let supplied = headers["authorization"].flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
        } ?? headers["x-api-key"] ?? ""
        let a = Array(supplied.utf8), b = Array(key.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<min(a.count, b.count) { difference |= a[index] ^ b[index] }
        return difference == 0 ? nil : (401, "Missing or wrong API key.")
    }

    private func handle(_ request: HTTPRequest, on connection: Connection) {
        let (consumer, path) = Self.split(path: request.path, headers: request.headers)
        if request.method == "GET", ["/health", "/v1/health"].contains(path) {
            connection.task = Task { @MainActor [weak self] in
                guard let self else { return }
                self.replyJSON(connection, status: 200, self.service.health())
            }
            return
        }
        if let denied = Self.authorize(request.headers, key: key) {
            reply(connection, status: denied.status, error: (denied.message, "authentication_error",
                                                             denied.status == 403 ? "proxy_without_key" : "invalid_api_key"))
            return
        }
        switch (request.method, path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            connection.task = Task { @MainActor [weak self] in
                guard let self else { return }
                self.replyJSON(connection, status: 200, ["object": "list", "data": self.service.models()])
            }
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            let parsed: OpenAIEndpointRequest
            do { parsed = try OpenAIEndpointRequest.parse(request.body) } catch let invalid as OpenAIEndpointRequest.Invalid {
                reply(connection, status: 400, error: (invalid.message, "invalid_request_error", "invalid_request"))
                return
            } catch {
                reply(connection, status: 400, error: ("Send a JSON object.", "invalid_request_error", "invalid_request"))
                return
            }
            if parsed.stream { startStream(connection) }
            connection.task = Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.service.complete(parsed, consumer: consumer)
                self.queue.async { self.finish(connection, parsed, outcome) }
            }
        case (_, "/v1/chat/completions"), (_, "/chat/completions"), (_, "/v1/models"), (_, "/models"):
            reply(connection, status: 405, error: ("Method not allowed.", "invalid_request_error", "method_not_allowed"))
        default:
            reply(connection, status: 404, error: ("Not found. Use /v1/chat/completions, /v1/models or /health.",
                                                   "invalid_request_error", "not_found"))
        }
    }

    // MARK: - Replies

    static func completionBody(_ result: OneShotResult, target: OneShotTarget, id: String, created: Int) -> [String: Any] {
        [
            "id": id, "object": "chat.completion", "created": created,
            "model": OpenAIEndpointModel.name(target.backend, model: result.model),
            "choices": [["index": 0, "message": ["role": "assistant", "content": result.text],
                         "logprobs": NSNull(), "finish_reason": "stop"]],
            "usage": usageBody(result),
        ]
    }

    static func usageBody(_ result: OneShotResult) -> [String: Any] {
        ["prompt_tokens": result.inputTokens, "completion_tokens": result.outputTokens,
         "total_tokens": result.inputTokens + result.outputTokens]
    }

    static func errorBody(message: String, type: String, code: String) -> [String: Any] {
        ["error": ["message": message, "type": type, "code": code, "param": NSNull()]]
    }

    private func finish(_ connection: Connection, _ request: OpenAIEndpointRequest, _ outcome: OpenAIEndpointOutcome) {
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        let created = Int(Date().timeIntervalSince1970)
        if request.stream {
            finishStream(connection, request, outcome, id: id, created: created)
            return
        }
        switch outcome {
        case .answered(let result, let target, _):
            replyJSON(connection, status: 200, Self.completionBody(result, target: target, id: id, created: created),
                      headers: [("X-Cantrip-Backend", target.backend.rawValue), ("X-Cantrip-Model", result.model)])
        case .failed(let status, let code, let message, let retryAfter):
            guard code != "cancelled" else { connection.socket.cancel(); return }
            var headers: [(String, String)] = []
            if let retryAfter { headers.append(("Retry-After", String(max(1, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))))) }
            let type = status == 429 ? "rate_limit_error" : status == 400 ? "invalid_request_error" : "api_error"
            replyJSON(connection, status: status, Self.errorBody(message: message, type: type, code: code), headers: headers)
        }
    }

    private func startStream(_ connection: Connection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
            + "Connection: close\r\nX-Accel-Buffering: no\r\n\r\n"
        connection.socket.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        keepAlive(connection)
    }

    /// SSE comments while the model works, so proxies don't drop a quiet connection.
    private func keepAlive(_ connection: Connection) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !connection.finished else { return }
            connection.socket.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in })
            self.keepAlive(connection)
        }
    }

    private func finishStream(_ connection: Connection, _ request: OpenAIEndpointRequest, _ outcome: OpenAIEndpointOutcome,
                              id: String, created: Int) {
        var events: [[String: Any]] = []
        switch outcome {
        case .answered(let result, let target, _):
            let model = OpenAIEndpointModel.name(target.backend, model: result.model)
            func chunk(_ delta: [String: Any], finish: String?) -> [String: Any] {
                ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                 "choices": [["index": 0, "delta": delta, "logprobs": NSNull(), "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
            }
            events = [chunk(["role": "assistant", "content": ""], finish: nil),
                      chunk(["content": result.text], finish: nil),
                      chunk([:], finish: "stop")]
            if request.includeUsageInStream {
                events.append(["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                               "choices": [], "usage": Self.usageBody(result)])
            }
        case .failed(let status, let code, let message, _):
            guard code != "cancelled" else { connection.finished = true; connection.socket.cancel(); return }
            events = [Self.errorBody(message: message, type: status == 429 ? "rate_limit_error" : "api_error", code: code)]
        }
        var body = Data()
        for event in events {
            if let data = try? JSONSerialization.data(withJSONObject: event) {
                body.append(Data("data: ".utf8) + data + Data("\n\n".utf8))
            }
        }
        body.append(Data("data: [DONE]\n\n".utf8))
        connection.finished = true
        connection.socket.send(content: body, isComplete: true, completion: .contentProcessed { _ in
            connection.socket.cancel()
        })
    }

    private func replyJSON(_ connection: Connection, status: Int, _ object: [String: Any], headers: [(String, String)] = []) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        queue.async { self.send(connection, status: status, body: body, headers: headers) }
    }

    private func reply(_ connection: Connection, status: Int, error: (String, String, String)) {
        replyJSON(connection, status: status, Self.errorBody(message: error.0, type: error.1, code: error.2))
    }

    private func send(_ connection: Connection, status: Int, body: Data, headers: [(String, String)]) {
        guard !connection.finished else { return }
        connection.finished = true
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.socket.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in
            connection.socket.cancel()
        })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Error"
        }
    }
}
