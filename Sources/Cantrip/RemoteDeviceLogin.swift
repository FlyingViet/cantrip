import Foundation

/// Explicit GitHub CLI device flow: credentials go to github.com, not through chat.
final class RemoteDeviceLogin {
    private let queue = DispatchQueue(label: "cantrip.device-login")
    private var process: Process?
    private var pending: BackendInputRequest?
    private var buffer = ""
    private var onEvent: ((BackendEvent) -> Void)?
    private let executable: URL?

    init(executable: URL? = nil) { self.executable = executable }

    func start(workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        queue.async { [weak self] in
            self?.cancelOnQueue()
            self?.startProcess(workdir: workdir, onEvent: onEvent)
        }
    }

    private func startProcess(workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        self.onEvent = onEvent
        let process = Process()
        process.executableURL = executable ?? URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = (executable == nil ? ["gh"] : []) + ["auth", "login", "--hostname", "github.com", "--web",
                             "--git-protocol", "https", "--skip-ssh-key"]
        process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["BROWSER"] = "/usr/bin/true"
        environment["GH_BROWSER"] = "/usr/bin/true"
        // An ambient token would bypass device login or cause gh to print token-based diagnostics.
        environment.removeValue(forKey: "GH_TOKEN")
        environment.removeValue(forKey: "GITHUB_TOKEN")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data, owner: process) }
        }
        process.terminationHandler = { [weak self] proc in
            output.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                let pending = self.pending
                self.pending = nil
                pending?.cancel()
                if proc.terminationStatus == 0 {
                    self.onEvent?(.textDelta("GitHub sign-in completed on the Mac."))
                    self.onEvent?(.done)
                } else {
                    self.onEvent?(.failure("GitHub sign-in did not complete. Retry /login github, or sign in using gh on the Mac."))
                }
                self.onEvent = nil
                self.buffer = ""
            }
        }
        do {
            try process.run()
            self.process = process
            try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            try input.fileHandleForWriting.close()
            onEvent(.status("Starting GitHub device sign-in..."))
        } catch {
            cancelOnQueue()
            onEvent(.failure("Could not start GitHub sign-in. Install the GitHub CLI (gh) on the Mac."))
        }
    }

    private func consume(_ data: Data, owner: Process) {
        guard process === owner, pending == nil, let text = String(data: data, encoding: .utf8) else { return }
        buffer = String((buffer + text).suffix(8192))
        guard let match = buffer.range(of: #"one-time code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})"#, options: .regularExpression) else { return }
        let code = String(buffer[match]).components(separatedBy: ":").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        let request = BackendInputRequest(kind: .login, source: "GitHub CLI on the Mac",
            title: "Sign in to GitHub", detail: "Authorize the GitHub CLI on this Mac using GitHub's device sign-in page.",
            url: "https://github.com/login/device", code: code, lifetime: 600) { [weak self] answer in
            self?.queue.async {
                guard let self, self.process === owner else { return }
                if answer.decision != .approve {
                    owner.terminate()
                }
                // gh polls GitHub itself. An approval click alone never claims login succeeded.
                self.pending = nil
            }
        }
        pending = request
        onEvent?(.inputRequired(request))
    }

    func cancel() {
        queue.async { [weak self] in self?.cancelOnQueue() }
    }

    private func cancelOnQueue() {
        let old = process
        process = nil
        pending?.cancel()
        pending = nil
        buffer = ""
        onEvent = nil
        if old?.isRunning == true { old?.terminate() }
    }
}
