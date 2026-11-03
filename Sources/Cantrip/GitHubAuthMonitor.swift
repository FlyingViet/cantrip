import Foundation

/// Keeps the Mac's GitHub CLI sign-in (`GitHubAuthStatus`) for Settings on every client: checked
/// soon after launch, every `checkInterval`, after `/login github` ends and on demand
/// (POST /api/v1/backends `check`), and kept on disk so a relaunch shows the last answer at once.
/// Runs `gh auth status --json hosts`, which never prints a token unless asked to.
final class GitHubAuthMonitor: ObservableObject {
    /// A QA host may put its own in place before its server starts.
    static var shared = GitHubAuthMonitor()
    static var checkInterval: TimeInterval = 30 * 60

    typealias Prober = (@escaping (GitHubAuthStatus) -> Void) -> Void

    /// nil until the first check of this Mac has finished.
    @Published private(set) var status: GitHubAuthStatus?
    @Published private(set) var checking = false

    private let store: URL
    private let prober: Prober
    private let clock: () -> Date
    private var timer: Timer?
    /// Off until the app starts the monitor (or a test brings its own prober), so tests never run
    /// the real gh.
    private var checksEnabled: Bool

    init(store: URL = CantripPaths.cache("github-auth.json"), prober: Prober? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        checksEnabled = prober != nil
        self.prober = prober ?? { completion in
            DispatchQueue.global(qos: .utility).async { completion(Self.probe()) }
        }
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode(GitHubAuthStatus.self, from: data) {
            status = saved
        }
    }

    func start(firstCheckAfter delay: TimeInterval = 20) {
        onMain {
            self.checksEnabled = true
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                self?.check()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    /// Starts a check unless one is running.
    func check() {
        onMain {
            guard self.checksEnabled, !self.checking else { return }
            self.checking = true
            self.prober { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var result = result
                    result.checkedAt = ISODate.string(from: self.clock())
                    result.checking = false
                    self.checking = false
                    if result != self.status {
                        Log.write("github: \(result.state.rawValue)"
                                  + (result.login.map { " as \($0)" } ?? "")
                                  + (result.accounts.count > 1 ? " (\(result.accounts.count) accounts)" : ""))
                    }
                    self.status = result
                    if let data = try? JSONEncoder().encode(result) {
                        try? data.write(to: self.store, options: .atomic)
                    }
                }
            }
        }
    }

    /// `github` in GET /api/v1/backends. Before the first answer: unknown, and whether it's checking.
    func remotePayload() -> [String: Any] {
        var current = status ?? GitHubAuthStatus(state: .unknown)
        current.checking = checking
        return GitHubAuthParser.payload(current)
    }

    /// The panel's tab menu item: signed in, it says as whom and offers to sign in again.
    var signInMenuTitle: String {
        guard let status, status.state == .signedIn, let login = status.login else { return "Sign in to GitHub on Mac..." }
        return "GitHub on Mac: \(login) · Sign In Again..."
    }

    /// One check of this Mac's gh, without an ambient token (it would answer for that token, not
    /// for the sign-in the backends' gh keeps).
    static func probe() -> GitHubAuthStatus {
        let path = ToolLocator.shared.gh
        var environment = BackendProbes.environment
        environment.removeValue(forKey: "GH_TOKEN")
        environment.removeValue(forKey: "GITHUB_TOKEN")
        return GitHubAuthParser.probe(ghPath: path) { arguments in
            guard let path, let result = try? ProcessRunner.run(
                path, arguments, environment: environment,
                directory: FileManager.default.homeDirectoryForCurrentUser,
                errorOutput: .capture, timeout: 20, outputLimit: 200_000
            ) else { return nil }
            return .init(output: String(decoding: result.output, as: UTF8.self),
                         errors: String(decoding: result.errorOutput, as: UTF8.self), timedOut: result.timedOut)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
