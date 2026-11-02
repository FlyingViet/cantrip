import Combine
import Foundation
import UserNotifications

/// The agent backends whose CLI sign-in Cantrip checks.
enum MonitoredBackend: String, CaseIterable, Codable {
    case copilot, claude, antigravity, codex

    var kind: BackendKind {
        switch self {
        case .copilot: return .copilot
        case .claude: return .claudeCode
        case .antigravity: return .antigravity
        case .codex: return .codex
        }
    }

    init?(kind: BackendKind) {
        switch kind {
        case .copilot: self = .copilot
        case .claudeCode: self = .claude
        case .antigravity: self = .antigravity
        case .codex: self = .codex
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .copilot: return "Copilot CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        }
    }

    /// How the CLI signs in: Copilot and Codex have a device flow any client can finish (a link and
    /// a code); Claude Code returns to a page on the Mac, and Antigravity signs in only interactively.
    var signInMode: String { self == .copilot || self == .codex ? "deviceCode" : "terminal" }

    var signInArguments: [String] {
        switch self {
        case .copilot: return ["login", "--device-code"]
        case .codex: return ["login", "--device-auth"]
        case .claude: return ["auth", "login"]
        case .antigravity: return []
        }
    }

    var signInCommand: String {
        (["\(self == .antigravity ? "agy" : self == .claude ? "claude" : rawValue)"] + signInArguments).joined(separator: " ")
    }

    var signInHint: String {
        switch self {
        case .copilot, .codex:
            return "Sign in shows a link and a code here. Open the link on any device and enter the code."
        case .claude:
            return "Claude Code signs in through a page that returns to the Mac, so Sign in opens Terminal on the Mac to finish there."
        case .antigravity:
            return "Antigravity signs in only in its own interactive mode, so Sign in opens agy in Terminal on the Mac."
        }
    }
}

/// What one check found: the CLI's install, version and sign-in. Never a token or key.
struct BackendProbe: Codable, Equatable {
    var installed: Bool
    var path: String?
    var version: String?
    /// nil when the check couldn't tell (the CLI didn't answer, or answered something unexpected).
    var signedIn: Bool?
    var account: String?
    var authMethod: String?
    var plan: String?
    /// Why `signedIn` is nil, or the CLI's own words when it's signed out.
    var problem: String?
}

/// One backend as every client shows it.
struct BackendStatus: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case ready, signedOut, outOfQuota, notInstalled, unknown
    }

    struct Quota: Codable, Equatable {
        let name: String
        let usedPercent: Double?
        let resetsAt: String?
    }

    struct Event: Codable, Equatable {
        let message: String
        let at: String
    }

    struct SignIn: Codable, Equatable {
        /// `deviceCode` or `terminal` (see `MonitoredBackend.signInMode`).
        let mode: String
        let command: String
        let hint: String
        /// A device sign-in in progress: the page to open and the code to enter.
        var url: String?
        var code: String?
        var startedAt: String?
        /// How the last sign-in attempt ended, or where it continues.
        var message: String?
    }

    let id: String
    let name: String
    var state: State
    var summary: String
    var path: String?
    var version: String?
    var signedIn: Bool?
    var account: String?
    var authMethod: String?
    var plan: String?
    var quota: [Quota] = []
    /// When a used-up account-wide limit lifts.
    var limitedUntil: String?
    var lastSuccessAt: String?
    var lastAuthError: Event?
    var checkedAt: String?
    var checking = false
    /// Routing, fallback, backups and scheduled Home runs skip it until a check finds it signed in.
    var unavailable = false
    var problem: String?
    var signIn: SignIn
}

/// The checks themselves: cheap CLI commands that never call a model, each with a time limit so a
/// slow CLI on a loaded Mac can't hold anything up.
enum BackendProbes {
    static var versionTimeout: TimeInterval = 20
    static var authTimeout: TimeInterval = 45

    static func probe(_ backend: MonitoredBackend, settings: AppSettings = .shared,
                      copilotAccount: @escaping (@escaping (Result<CopilotAccountUsage, Error>) -> Void) -> Void,
                      completion: @escaping (BackendProbe) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let path = executable(backend, settings: settings) else {
                return completion(BackendProbe(installed: false))
            }
            var probe = BackendProbe(installed: true, path: path, version: version(backend, path: path))
            switch backend {
            case .claude:
                apply(claudeStatus(path), to: &probe)
            case .codex:
                apply(codexStatus(path), to: &probe)
            case .antigravity:
                apply(antigravityStatus(path), to: &probe)
            case .copilot:
                let done = DispatchSemaphore(value: 0)
                var outcome: Result<CopilotAccountUsage, Error>?
                copilotAccount { result in
                    outcome = result
                    done.signal()
                }
                if done.wait(timeout: .now() + authTimeout) == .timedOut {
                    probe.problem = "Copilot's account didn't answer within \(Int(authTimeout)) s."
                } else if let outcome {
                    apply(copilotStatus(outcome), to: &probe)
                }
            }
            completion(probe)
        }
    }

    static func executable(_ backend: MonitoredBackend, settings: AppSettings) -> String? {
        switch backend {
        case .copilot: return ToolLocator.shared.copilot(configured: settings.copilotPath)
        case .claude: return ToolLocator.shared.claude(configured: settings.claudePath)
        case .codex: return ToolLocator.shared.codex(configured: settings.codexPath)
        case .antigravity: return AntigravityBackend.resolveExecutable(customPath: settings.agyPath)
        }
    }

    struct Auth: Equatable {
        var signedIn: Bool?
        var account: String?
        var method: String?
        var plan: String?
        var problem: String?
    }

    private static func apply(_ auth: Auth, to probe: inout BackendProbe) {
        probe.signedIn = auth.signedIn
        probe.account = auth.account
        probe.authMethod = auth.method
        probe.plan = auth.plan
        probe.problem = auth.problem
    }

    /// Where the CLIs keep their own files: their `$HOME`, which Cantrip's tests may point elsewhere.
    static var cliHome: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        environment["NO_COLOR"] = "1"
        return environment
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> ProcessRunner.Result? {
        try? ProcessRunner.run(path, arguments, environment: environment,
                               directory: FileManager.default.homeDirectoryForCurrentUser,
                               errorOutput: .merge, timeout: timeout, outputLimit: 1_000_000)
    }

    static func version(_ backend: MonitoredBackend, path: String) -> String? {
        // Copilot's own discovery cache already holds the version: `--version` starts its whole CLI.
        if backend == .copilot, let cached = copilotCachedVersion(path) { return cached }
        guard let result = run(path, ["--version"], timeout: versionTimeout), result.succeeded else { return nil }
        return parseVersion(result.text)
    }

    static func parseVersion(_ text: String) -> String? {
        text.range(of: #"\d+\.\d+\.\d+(?:[-+.][0-9A-Za-z.]+)?"#, options: .regularExpression).map { String(text[$0]) }
    }

    static func copilotCachedVersion(_ path: String) -> String? {
        let url = CantripPaths.cache("copilot-runtime.json")
        guard let data = try? Data(contentsOf: url),
              let cache = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = cache[path] as? [String: Any] else { return nil }
        return entry["version"] as? String
    }

    /// Phrases a CLI prints when it has no sign-in (never "failed": that can be the network).
    static let signedOutPhrases = [
        "not logged in", "not logged into", "not signed in", "please sign in", "please log in",
        "run /login", "unauthenticated", "not authenticated", "no credentials",
    ]

    static func saysSignedOut(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return signedOutPhrases.contains { lowered.contains($0) }
    }

    // MARK: Claude Code: `claude auth status` (JSON)

    static func claudeStatus(_ path: String) -> Auth {
        guard let result = run(path, ["auth", "status"], timeout: authTimeout) else {
            return Auth(problem: "Claude Code couldn't start.")
        }
        if result.timedOut { return Auth(problem: "Claude Code didn't answer within \(Int(authTimeout)) s.") }
        return parseClaudeStatus(result.text)
    }

    static func parseClaudeStatus(_ text: String) -> Auth {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let json = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
           let loggedIn = json["loggedIn"] as? Bool {
            guard loggedIn else { return Auth(signedIn: false, problem: "Claude Code isn't signed in.") }
            let method: String
            switch (json["apiProvider"] as? String, json["authMethod"] as? String) {
            case ("bedrock"?, _): method = "Amazon Bedrock"
            case ("vertex"?, _): method = "Google Vertex AI"
            case (_, "claude.ai"?): method = "Claude account"
            case (_, "console"?), (_, "oauth_console"?): method = "Anthropic Console"
            case (_, let other?) where other.lowercased().contains("key"): method = "API key"
            case (_, let other?): method = other
            default: method = "Claude account"
            }
            let plan = (json["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0.capitalized }
            return Auth(signedIn: true, account: (json["email"] as? String) ?? (json["orgName"] as? String),
                        method: method, plan: plan)
        }
        if saysSignedOut(text) { return Auth(signedIn: false, problem: firstLine(text)) }
        return Auth(problem: text.isEmpty ? "Claude Code didn't report its sign-in." : firstLine(text))
    }

    // MARK: Codex: the app server's `account/read`, else `codex login status`

    static func codexStatus(_ path: String) -> Auth {
        let done = DispatchSemaphore(value: 0)
        var account: [String: Any]?
        var answered = false
        Task.detached(priority: .utility) {
            defer { done.signal() }
            guard let result = try? await CodexAppServer.withServer(executable: path, { server in
                try await server.request("account/read", ["refreshToken": false], timeout: authTimeout)
            }) else { return }
            answered = true
            account = result
        }
        if done.wait(timeout: .now() + authTimeout + 5) == .success, answered, let account {
            return parseCodexAccount(account)
        }
        guard let result = run(path, ["login", "status"], timeout: authTimeout) else {
            return Auth(problem: "Codex couldn't start.")
        }
        if result.timedOut { return Auth(problem: "Codex didn't answer within \(Int(authTimeout)) s.") }
        return parseCodexLoginStatus(result.text)
    }

    static func parseCodexAccount(_ result: [String: Any]) -> Auth {
        guard let account = result["account"] as? [String: Any] else {
            if result["requiresOpenaiAuth"] as? Bool == false { return Auth(signedIn: true, method: "Custom provider") }
            return Auth(signedIn: false, problem: "Codex isn't signed in.")
        }
        switch account["type"] as? String {
        case "chatgpt":
            let plan = (account["planType"] as? String).flatMap { $0.isEmpty ? nil : $0.capitalized }
            return Auth(signedIn: true, account: account["email"] as? String, method: "ChatGPT", plan: plan)
        case "apiKey":
            return Auth(signedIn: true, method: "API key")
        case let other?:
            return Auth(signedIn: true, method: other)
        case nil:
            return Auth(signedIn: true)
        }
    }

    static func parseCodexLoginStatus(_ text: String) -> Auth {
        let lowered = text.lowercased()
        if lowered.contains("not logged in") { return Auth(signedIn: false, problem: firstLine(text)) }
        if lowered.contains("logged in using chatgpt") { return Auth(signedIn: true, method: "ChatGPT") }
        if lowered.contains("api key") && lowered.contains("logged in") { return Auth(signedIn: true, method: "API key") }
        if lowered.contains("logged in") { return Auth(signedIn: true) }
        return Auth(problem: text.isEmpty ? "Codex didn't report its sign-in." : firstLine(text))
    }

    // MARK: Antigravity: `agy -p /usage`, answered by the CLI itself after its silent sign-in

    static func antigravityStatus(_ path: String) -> Auth {
        guard let result = run(path, ["-p", "/usage", "--output-format", "json"], timeout: authTimeout) else {
            return Auth(problem: "Antigravity couldn't start.")
        }
        if result.timedOut { return Auth(problem: "Antigravity didn't answer within \(Int(authTimeout)) s.") }
        var auth = parseAntigravityUsage(result.text)
        if auth.signedIn == true, let (account, method) = antigravityAccount() {
            auth.account = account
            auth.method = method
        }
        return auth
    }

    static func parseAntigravityUsage(_ text: String) -> Auth {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let json = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any],
           let status = json["status"] as? String {
            if status == "SUCCESS" { return Auth(signedIn: true, method: "Google account") }
            let message = (json["error"] as? String) ?? (json["response"] as? String) ?? status
            if saysSignedOut(message) { return Auth(signedIn: false, problem: firstLine(message)) }
            return Auth(problem: firstLine(message))
        }
        if saysSignedOut(text) { return Auth(signedIn: false, problem: firstLine(text)) }
        return Auth(problem: text.isEmpty ? "Antigravity didn't report its sign-in." : firstLine(text))
    }

    /// The account agy's own log names at its last sign-in (it has no status command).
    static func antigravityAccount(home: String = cliHome) -> (String, String)? {
        let folder = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/log")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.lastPathComponent.hasPrefix("cli-") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }.prefix(4)
        for file in newest {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = handle.readData(ofLength: 400_000)
            try? handle.close()
            let text = String(decoding: data, as: UTF8.self)
            let pattern = #"applyAuthResult: email=([^,\s]+), authMethod=([A-Za-z_]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard let last = matches.last, let email = Range(last.range(at: 1), in: text),
                  let method = Range(last.range(at: 2), in: text) else { continue }
            let kind = String(text[method])
            return (String(text[email]), kind == "consumer" ? "Google account" : "Google (\(kind))")
        }
        return nil
    }

    // MARK: Copilot: the account lookup Cantrip already uses for its usage

    static func copilotStatus(_ result: Result<CopilotAccountUsage, Error>, home: String = cliHome) -> Auth {
        switch result {
        case .success(let account):
            return Auth(signedIn: true, account: account.login ?? copilotConfigUser(home: home)?.login,
                        method: "GitHub account", plan: account.plan.flatMap { $0.isEmpty ? nil : $0.capitalized })
        case .failure(let error):
            if (error as? CopilotQuotaError) == .authentication {
                return Auth(signedIn: false, problem: "Copilot CLI isn't signed in.")
            }
            let problem = (error as? CopilotQuotaError ?? .response).localizedDescription
            // The account lookup failed for another reason: Copilot's own config still names who's signed in.
            guard let user = copilotConfigUser(home: home) else { return Auth(problem: problem) }
            return Auth(signedIn: user.signedIn, account: user.login, method: user.signedIn ? "GitHub account" : nil,
                        problem: user.signedIn ? problem : "Copilot CLI isn't signed in.")
        }
    }

    /// `~/.copilot/config.json` lists the signed-in GitHub users (host and login, no token). It
    /// opens with `//` comment lines.
    static func copilotConfigUser(home: String = cliHome) -> (signedIn: Bool, login: String?)? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".copilot/config.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let json = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        guard let config = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let users = config["loggedInUsers"] as? [[String: Any]] ?? []
        let last = (config["lastLoggedInUser"] as? [String: Any])?["login"] as? String
        return (!users.isEmpty, users.isEmpty ? nil : last ?? users.first?["login"] as? String)
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(200) ?? "")
    }
}

/// Keeps every backend's install and sign-in state current: on launch, every 30 minutes, after
/// a run fails with a sign-in error, and on Check now. Results are kept on disk so a tab never
/// waits for a check. A backend that goes signed out (or out of quota) sends one alert, and one
/// more when it's back; while it's signed out, routing and fallback skip it.
final class BackendStatusMonitor: ObservableObject {
    static let shared = BackendStatusMonitor()
    static var checkInterval: TimeInterval = 30 * 60
    /// A signed-out answer is checked once more after this long before it counts.
    static var confirmDelay: TimeInterval = 3
    static var signInTimeout: TimeInterval = 15 * 60

    typealias Prober = (MonitoredBackend, @escaping (BackendProbe) -> Void) -> Void

    @Published private(set) var statuses: [BackendStatus] = []
    @Published private(set) var revision = 0

    weak var remote: RemoteControlServer?
    var postsMacNotifications = false
    /// Every alert, in order (tests and the Mac log read it).
    private(set) var alerts: [(title: String, body: String)] = []

    private struct Saved: Codable {
        var probes: [String: BackendProbe] = [:]
        var checkedAt: [String: String] = [:]
        var lastSuccessAt: [String: String] = [:]
        var lastAuthError: [String: BackendStatus.Event] = [:]
        /// The down state each backend was alerted for; cleared (with an alert) when it's back.
        var alerted: [String: String] = [:]
    }

    private let store: URL
    private let prober: Prober
    private let clock: () -> Date
    private let tracker: BackendLimitTracker
    private var saved = Saved()
    private var checking: Set<MonitoredBackend> = []
    private var timer: Timer?
    private var wakeTimer: Timer?
    private var usageWatch: AnyCancellable?
    private var lastRecheck: [MonitoredBackend: Date] = [:]
    private var signIns: [MonitoredBackend: Process] = [:]
    private var signInState: [MonitoredBackend: BackendStatus.SignIn] = [:]
    /// Off until the app starts the monitor (or a test brings its own prober), so a run failing
    /// in a test never probes the real CLIs.
    private var checksEnabled: Bool

    init(store: URL = CantripPaths.cache("backend-status.json"),
         prober: Prober? = nil,
         tracker: BackendLimitTracker = .shared,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.tracker = tracker
        self.clock = clock
        checksEnabled = prober != nil
        self.prober = prober ?? { backend, completion in
            BackendProbes.probe(backend, copilotAccount: QuotaFetcher.fetchCopilotQuota, completion: completion)
        }
        if let data = try? Data(contentsOf: store), let loaded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = loaded
        }
        onMain { self.publish() }
    }

    /// Checks soon after launch, then every `checkInterval`; refreshes when the usage limits change.
    func start(postsMacNotifications: Bool, firstCheckAfter delay: TimeInterval = 20) {
        onMain {
            self.checksEnabled = true
            self.postsMacNotifications = postsMacNotifications
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                self?.check()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
            self.usageWatch = UsageTracker.shared.$copilotUsage
                .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.publish() }
        }
    }

    /// Starts a check of `backends` (all when nil). Already-running checks aren't started twice.
    func check(_ backends: [MonitoredBackend]? = nil) {
        onMain {
            guard self.checksEnabled else { return }
            let wanted = (backends ?? MonitoredBackend.allCases).filter { !self.checking.contains($0) }
            guard !wanted.isEmpty else { return }
            self.checking.formUnion(wanted)
            self.publish()
            for backend in wanted { self.runProbe(backend, confirming: false) }
        }
    }

    private func runProbe(_ backend: MonitoredBackend, confirming: Bool) {
        prober(backend) { [weak self] probe in
            DispatchQueue.main.async {
                guard let self else { return }
                // One answer of "signed out" is checked again before routing changes.
                if probe.signedIn == false, !confirming,
                   self.saved.probes[backend.rawValue]?.signedIn != false {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay) { [weak self] in
                        self?.runProbe(backend, confirming: true)
                    }
                    return
                }
                self.checking.remove(backend)
                self.saved.probes[backend.rawValue] = probe
                self.saved.checkedAt[backend.rawValue] = ISODate.string(from: self.clock())
                // A sign-in outcome is old news once a check has run: signed in, or an attempt that ended.
                if self.signIns[backend] == nil, let note = self.signInState[backend], note.code == nil,
                   probe.signedIn == true || note.message == "Sign-in cancelled."
                    || note.message?.hasSuffix("ended without signing in.") == true {
                    self.signInState[backend] = nil
                }
                Log.write("backends: \(backend.rawValue) "
                    + (probe.installed ? "\(probe.version ?? "?") signedIn=\(probe.signedIn.map(String.init) ?? "unknown")"
                       : "not installed") + (probe.problem.map { " (\($0.prefix(120)))" } ?? ""))
                self.save()
                self.publish()
            }
        }
    }

    // MARK: Real runs

    func runSucceeded(_ kind: BackendKind) {
        guard let backend = MonitoredBackend(kind: kind) else { return }
        onMain {
            self.saved.lastSuccessAt[backend.rawValue] = ISODate.string(from: self.clock())
            self.save()
            self.publish()
        }
    }

    /// A run failed: a sign-in error is remembered and checked right away (at most every two minutes).
    func runFailed(_ kind: BackendKind, message: String) {
        guard let backend = MonitoredBackend(kind: kind),
              ConsolidationBackend.isAuthenticationFailure(message) || BackendProbes.saysSignedOut(message) else { return }
        onMain {
            let now = self.clock()
            self.saved.lastAuthError[backend.rawValue] = BackendStatus.Event(
                message: String(message.split(whereSeparator: \.isNewline).first?.prefix(240) ?? ""),
                at: ISODate.string(from: now))
            self.save()
            self.publish()
            if let last = self.lastRecheck[backend], now.timeIntervalSince(last) < 120 { return }
            self.lastRecheck[backend] = now
            self.check([backend])
        }
    }

    // MARK: Sign in

    /// Starts the CLI's own sign-in: a device flow whose link and code every client shows, or
    /// Terminal on the Mac. Returns what the person should do next.
    @discardableResult
    func signIn(_ backend: MonitoredBackend) -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let path = saved.probes[backend.rawValue]?.path ?? BackendProbes.executable(backend, settings: .shared) else {
            return "\(backend.name) isn't installed on the Mac."
        }
        if backend.signInMode == "terminal" {
            let message: String
            do {
                try openTerminal(backend, path: path)
                message = "Finish signing in to \(backend.name) in Terminal on the Mac."
            } catch {
                message = "Couldn't open Terminal. Run `\(backend.signInCommand)` on the Mac."
            }
            signInState[backend] = signInBase(backend).with(message: message)
            // Check again while the person signs in.
            for delay in [30.0, 90, 180, 300] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check([backend]) }
            }
            publish()
            return message
        }
        if let running = signIns[backend], running.isRunning { return "A \(backend.name) sign-in is already waiting." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = backend.signInArguments
        process.environment = BackendProbes.environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var text = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.signIns[backend] === process else { return }
                text += String(decoding: data, as: UTF8.self)
                let (url, code) = Self.deviceCode(in: text)
                var state = self.signInState[backend] ?? self.signInBase(backend)
                if let url, state.url != url { state.url = url }
                if let code, state.code != code { state.code = code }
                if state != self.signInState[backend] {
                    state.message = state.url == nil ? "Starting \(backend.name) sign-in…"
                        : "Open the link on any device and enter the code."
                    self.signInState[backend] = state
                    self.publish()
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.signIns[backend] === finished else { return }
                self.signIns[backend] = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                let message = finished.terminationReason == .exit && finished.terminationStatus == 0
                    ? "Signed in. Checking \(backend.name)…" : "The \(backend.name) sign-in ended without signing in."
                self.signInState[backend] = self.signInBase(backend).with(message: message)
                self.publish()
                self.check([backend])
            }
        }
        do {
            try process.run()
        } catch {
            return "Couldn't start `\(backend.signInCommand)` on the Mac."
        }
        signIns[backend] = process
        var state = signInBase(backend)
        state.startedAt = ISODate.string(from: clock())
        state.message = "Starting \(backend.name) sign-in…"
        signInState[backend] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.signInTimeout) { [weak self] in
            guard let self, self.signIns[backend] === process else { return }
            self.cancelSignIn(backend)
        }
        publish()
        return "Starting \(backend.name) sign-in…"
    }

    func cancelSignIn(_ backend: MonitoredBackend) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let process = signIns.removeValue(forKey: backend) else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { Self.stopTree(process.processIdentifier) }
        signInState[backend] = signInBase(backend).with(message: "Sign-in cancelled.")
        publish()
    }

    /// Stops a process and everything it started: npm's Copilot loader runs the real CLI as its
    /// child, which would otherwise keep waiting on the device sign-in.
    static func stopTree(_ root: pid_t) {
        var doomed = [root]
        if let table = CopilotRuntimeActivity.processTable() {
            var frontier = [root]
            while let parent = frontier.popLast() {
                let children = table.filter { $0.value.parent == parent }.map(\.key)
                doomed += children
                frontier += children
            }
        }
        for pid in doomed.reversed() { kill(pid, SIGTERM) }
    }

    /// The first link and device code a CLI's sign-in prints.
    static func deviceCode(in text: String) -> (url: String?, code: String?) {
        let plain = text.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        let url = plain.range(of: #"https://[^\s"'<>)]+"#, options: .regularExpression)
            .map { String(plain[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) }
        let code = plain.range(of: #"\b[A-Z0-9]{4,5}-[A-Z0-9]{4,5}\b"#, options: .regularExpression).map { String(plain[$0]) }
        return (url, code)
    }

    private func openTerminal(_ backend: MonitoredBackend, path: String) throws {
        let folder = CantripPaths.cache("backend-signin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("\(backend.rawValue).command")
        let quoted = ([path] + backend.signInArguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try ("#!/bin/zsh -l\n" + quoted.joined(separator: " ") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let open = try ProcessRunner.run("/usr/bin/open", ["-a", "Terminal", script.path], timeout: 20)
        guard open.succeeded else { throw CocoaError(.executableLoad) }
    }

    private func signInBase(_ backend: MonitoredBackend) -> BackendStatus.SignIn {
        BackendStatus.SignIn(mode: backend.signInMode, command: backend.signInCommand, hint: backend.signInHint)
    }

    // MARK: Status

    /// The JSON every client reads (GET /api/v1/backends).
    func remotePayload() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        publish()
        let encoder = JSONEncoder()
        let backends = statuses.compactMap { status -> Any? in
            guard let data = try? encoder.encode(status) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        return ["backends": backends, "checkInterval": Int(Self.checkInterval), "revision": revision]
    }

    func status(_ backend: MonitoredBackend) -> BackendStatus? {
        statuses.first { $0.id == backend.rawValue }
    }

    private func publish() {
        let now = clock()
        let next = MonitoredBackend.allCases.map { compose($0, now: now) }
        for status in next {
            guard let backend = MonitoredBackend(rawValue: status.id) else { continue }
            tracker.setUnavailable(backend.kind, reason: status.unavailable ? "\(backend.name) isn't signed in on the Mac" : nil)
        }
        reconcileAlerts(next)
        scheduleWake(next, now: now)
        if next != statuses {
            statuses = next
            revision += 1
        }
    }

    private func compose(_ backend: MonitoredBackend, now: Date) -> BackendStatus {
        let id = backend.rawValue
        let probe = saved.probes[id]
        let usage = UsageTracker.shared.copilotUsage
        var quota: [BackendStatus.Quota] = []
        var plan: String?
        switch backend {
        case .copilot:
            quota = (usage.account?.buckets ?? []).filter { !$0.isUnlimited }.map {
                .init(name: $0.title, usedPercent: $0.remainingPercent.map { max(0, min(100, 100 - $0)) }, resetsAt: $0.resetAt)
            }
            plan = usage.account?.plan
        case .claude:
            quota = (usage.claude?.account?.windows ?? []).map { .init(name: $0.title, usedPercent: $0.percentUsed, resetsAt: $0.resetsAt) }
            plan = usage.claude?.account?.plan
        case .codex:
            quota = (usage.codex?.account?.windows ?? []).map { .init(name: $0.title, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
            plan = usage.codex?.account?.plan
        case .antigravity:
            quota = (usage.antigravity?.account?.groups ?? []).flatMap { group in
                group.buckets.map { .init(name: "\(group.name): \($0.title.lowercased())", usedPercent: $0.percentUsed, resetsAt: $0.resetsAt) }
            }
        }
        let limited = tracker.usageLimitedUntil(backend.kind, now: now)
        // A signed-out CLI's plan and limits belong to an account it no longer uses.
        if probe?.signedIn == false {
            quota = []
            plan = nil
        }
        var status = BackendStatus(
            id: id, name: backend.name, state: .unknown, summary: "", path: probe?.path, version: probe?.version,
            signedIn: probe?.signedIn, account: probe?.account, authMethod: probe?.authMethod,
            plan: probe?.plan ?? plan.flatMap { $0.isEmpty ? nil : $0.capitalized }, quota: quota,
            limitedUntil: limited.map(ISODate.string(from:)), lastSuccessAt: saved.lastSuccessAt[id],
            lastAuthError: saved.lastAuthError[id], checkedAt: saved.checkedAt[id], checking: checking.contains(backend),
            unavailable: false, problem: probe?.problem, signIn: signInState[backend] ?? signInBase(backend))
        // A sign-in error from a run newer than the last check counts until a check says otherwise.
        let authErrorIsNewer = saved.lastAuthError[id].flatMap { ISODate.date(from: $0.at) }.map { error in
            saved.checkedAt[id].flatMap({ ISODate.date(from: $0) }).map { error > $0 } ?? true
        } ?? false
        switch probe {
        case nil:
            status.state = .unknown
            status.summary = checking.contains(backend) ? "Checking…" : "Not checked yet"
        case let probe? where !probe.installed:
            status.state = .notInstalled
            status.summary = "Not installed on the Mac"
        case let probe? where probe.signedIn == false:
            status.state = .signedOut
            status.unavailable = true
            status.summary = "Skipped by routing: your backups run until you sign in."
        case _ where limited != nil:
            status.state = .outOfQuota
            status.summary = "Out of quota until \(BackendFallback.untilLabel(limited!, now: now))"
        case let probe? where probe.signedIn == true:
            status.state = .ready
            status.summary = "Signed in"
        case let probe?:
            status.state = .unknown
            status.summary = probe.problem ?? "Couldn't check the sign-in"
        }
        if authErrorIsNewer, status.state == .ready {
            status.summary += ". A run just failed to sign in: checking again"
        }
        return status
    }

    private func reconcileAlerts(_ statuses: [BackendStatus]) {
        var changed = false
        for status in statuses {
            let down = status.state == .signedOut || status.state == .outOfQuota
            if down, saved.alerted[status.id] == nil {
                saved.alerted[status.id] = status.state.rawValue
                changed = true
                if status.state == .signedOut {
                    alert(title: "\(status.name) is signed out",
                          body: "Cantrip uses your backups until you sign in. Open Settings › Backends to sign in.")
                } else {
                    let until = status.limitedUntil.flatMap({ ISODate.date(from: $0) }).map { " until \(BackendFallback.untilLabel($0))" } ?? ""
                    alert(title: "\(status.name) is out of quota", body: "Cantrip uses your backups\(until).")
                }
            } else if status.state == .ready, saved.alerted[status.id] != nil {
                saved.alerted[status.id] = nil
                changed = true
                alert(title: "\(status.name) is back", body: "It's signed in and has quota, so Cantrip uses it again.")
            }
        }
        if changed { save() }
    }

    /// Re-reads the state when a limit lifts, so the "back" alert doesn't wait for the next check.
    private func scheduleWake(_ statuses: [BackendStatus], now: Date) {
        let next = statuses.compactMap { $0.limitedUntil.flatMap({ ISODate.date(from: $0) }) }.filter { $0 > now }.min()
        guard let next else { wakeTimer?.invalidate(); wakeTimer = nil; return }
        if let current = wakeTimer?.fireDate, abs(current.timeIntervalSince(next.addingTimeInterval(5))) < 1 { return }
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 5, repeats: false) { [weak self] _ in
            self?.publish()
        }
    }

    private func alert(title: String, body: String) {
        alerts.append((title, body))
        Log.write("backends: alert: \(title)")
        remote?.notifyBackendStatus(title: title, body: body)
        guard postsMacNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

private extension BackendStatus.SignIn {
    func with(message: String) -> Self {
        var copy = self
        copy.message = message
        return copy
    }
}
