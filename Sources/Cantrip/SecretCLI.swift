import Foundation

/// `cantrip secret …`: names, sync and import, and handing values to commands. Runs in the CLI
/// process itself (no host needed), so jobs keep working while Cantrip restarts. Never prints a value.
enum SecretCLI {
    static let usage = """
    Usage:
      cantrip secret list [--json]    Secret names, their field names and the last sync (never values)
      cantrip secret sync             Unlock Bitwarden (password dialog on the Mac), copy the \(SecretIndex.defaultFolder)
                                      folder into the keychain, and lock the vault again
      cantrip secret run [OPTIONS] SECRET... -- COMMAND [ARGS...]
                                      Run COMMAND with secrets in its environment; their values are masked in its output
          NAME                        Every field of NAME, as variables named after the fields
          NAME.FIELD | VAR=NAME.FIELD One field (as VAR)
          VAR=NAME                    A one-value secret, such as a token
          --file VAR=NAME             A file's content (key, JSON) at the path in VAR: a pipe that can be read once
          --env-file VAR=NAME         NAME's fields as KEY=value lines a shell can source, in a private file at
                                      the path in VAR
          --temp-files                Private files instead of pipes, for tools that read a file twice
                                      (files and pipes are deleted when COMMAND exits)
      cantrip secret import FOLDER [--apply] [--update]
                                      Make a Bitwarden item in \(SecretIndex.defaultFolder) for each secret file in FOLDER,
                                      sync, and compare each file with the keychain by hash. Without --apply, a preview;
                                      --update also overwrites items that already exist
      cantrip secret verify FOLDER    Compare FOLDER's files with the keychain cache by hash
    """

    struct Failure: LocalizedError {
        let message: String
        var code: Int32 = 1
        var errorDescription: String? { message }
    }

    /// Runs one `cantrip secret` command and returns the exit status; errors go to stderr.
    static func main(_ arguments: [String]) -> Int32 {
        do {
            return try run(arguments)
        } catch let failure as Failure {
            FileHandle.standardError.write(Data(("cantrip secret: " + failure.message + "\n").utf8))
            return failure.code
        } catch {
            FileHandle.standardError.write(Data(("cantrip secret: " + error.localizedDescription + "\n").utf8))
            return error is SecretRunPlan.Failure ? 2 : 1
        }
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case nil, "list", "status":
            try list(json: rest.contains("--json"))
        case "sync":
            try sync()
        case "run":
            return try SecretRunner.run(try SecretRunPlan.parse(rest))
        case "import":
            try importFolder(rest)
        case "verify":
            try verify(try folder(rest.first { !$0.hasPrefix("-") }))
        case "help", "-h", "--help":
            print(usage)
        default:
            throw SecretCLI.Failure(message: usage, code: 2)
        }
        return 0
    }

    private static func folder(_ path: String?) throws -> URL {
        guard let path else { throw Failure(message: "Give the folder of secret files.", code: 2) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func when(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func list(json: Bool) throws {
        let index = SecretIndex.load() ?? SecretIndex()
        if json {
            let data = try JSONSerialization.data(withJSONObject: index.remotePayload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("Bitwarden folder “\(index.folder)” · last sync \(when(index.lastSync))")
        if let error = index.lastError { print("Last attempt (\(when(index.lastAttempt))) failed: \(error)") }
        if index.items.isEmpty {
            print("No secrets cached yet. Run `cantrip secret sync` (or `cantrip secret import` first).")
        }
        let width = min(36, index.items.map(\.name.count).max() ?? 0)
        for item in index.items {
            let detail = item.kind == .fields ? item.fields.joined(separator: " ") : "(\(item.kind.rawValue))"
            print(item.name.padding(toLength: max(width, item.name.count), withPad: " ", startingAt: 0) + "  " + detail)
        }
        for skipped in index.skipped { print("Skipped \(skipped)") }
    }

    private static func bitwarden() throws -> BitwardenCLI {
        guard let path = BitwardenCLI.locate() else {
            throw SecretCLI.Failure(message: "The Bitwarden CLI (bw) isn't installed. Install it with `brew install bitwarden-cli` and log in once with `bw login`.")
        }
        return .live(path)
    }

    static func sync() throws {
        print("Waiting for the Bitwarden password dialog on the Mac…")
        let report = try SecretSync.run(bitwarden: try bitwarden(), password: {
            try SecretPasswordDialog.ask(reason: "Cantrip is syncing its secrets (asked from Terminal).")
        })
        printReport(report)
    }

    private static func printReport(_ report: SecretSync.Report) {
        if !report.created.isEmpty { print("Created in Bitwarden: \(report.created.joined(separator: ", "))") }
        if !report.updated.isEmpty { print("Updated in Bitwarden: \(report.updated.joined(separator: ", "))") }
        if !report.existing.isEmpty { print("Already in Bitwarden (left as they are): \(report.existing.joined(separator: ", "))") }
        print("Cached \(report.cached.count) secret(s) in the keychain. The vault is locked again.")
        if !report.removed.isEmpty { print("Removed from the cache (gone from Bitwarden): \(report.removed.joined(separator: ", "))") }
        if !report.kept.isEmpty { print("The folder is empty, so the cache was kept: \(report.kept.joined(separator: ", "))") }
        for skipped in report.skipped { print("Skipped \(skipped)") }
    }

    static func importFolder(_ arguments: [String]) throws {
        let apply = arguments.contains("--apply"), update = arguments.contains("--update")
        let source = try folder(arguments.first { !$0.hasPrefix("-") })
        let plan = try SecretImport.plan(folder: source)
        guard !plan.isEmpty else { throw SecretCLI.Failure(message: "No secret files in \(source.path).") }
        let names = Dictionary(grouping: plan, by: \.item).filter { $0.value.count > 1 }
        guard names.isEmpty else {
            throw SecretCLI.Failure(message: "Two files would share an item name: \(names.keys.sorted().joined(separator: ", ")). Rename one first.")
        }
        guard apply else {
            print("Would create \(plan.count) item(s) in the Bitwarden folder “\(SecretIndex.defaultFolder)” (names only):")
            for entry in plan { print(describe(entry)) }
            print("\nCertificates, signing requests and provisioning profiles aren't secret and stay files.")
            print("Run again with --apply to create them (a password dialog appears on the Mac).")
            return
        }
        let items = try plan.map { try SecretImport.item(for: $0, folder: source) }
        print("Waiting for the Bitwarden password dialog on the Mac…")
        let report = try SecretSync.run(bitwarden: try bitwarden(), password: {
            try SecretPasswordDialog.ask(reason: "Cantrip is importing \(items.count) secret files into Bitwarden.")
        }, importing: items, updateExisting: update)
        printReport(report)
        try verify(source)
    }

    private static func describe(_ entry: SecretImport.Entry) -> String {
        let detail: String
        switch entry.kind {
        case .fields:
            detail = entry.fields.map { $0.hidden ? "\($0.name) (hidden)" : $0.name }.joined(separator: ", ")
        case .text: detail = "note text"
        case .binary: detail = "note text, base64"
        }
        return "  \(entry.path) → \(entry.item): \(detail)"
    }

    /// Compares every file with its cached item by SHA-256 and prints only whether they match.
    static func verify(_ source: URL) throws {
        let store = SecretKeychain.Store.keychain
        var matched = 0, problems: [String] = []
        for entry in try SecretImport.plan(folder: source) {
            let fromFile = try SecretImport.item(for: entry, folder: source)
            guard let cached = try store.item(entry.item) else {
                problems.append("\(entry.path): not in the keychain cache (\(entry.item))")
                continue
            }
            if SecretImport.matches(cached, fromFile) { matched += 1 } else {
                problems.append("\(entry.path): differs from \(entry.item)")
            }
        }
        print("\(matched) file(s) match the keychain cache.")
        for problem in problems { print(problem) }
        if !problems.isEmpty { throw SecretCLI.Failure(message: "\(problems.count) file(s) don't match.", code: 1) }
    }
}

/// Starts a command with secrets, passes its output on with every secret value masked, and exits
/// with its status.
enum SecretRunner {
    static func run(_ plan: SecretRunPlan, store: SecretKeychain.Store = .keychain) throws -> Int32 {
        var items: [String: SecretItem] = [:]
        for name in plan.items {
            guard let item = try store.item(name) else { throw SecretCLI.Failure(message: SecretRunPlan.missing(name)) }
            items[name] = item
        }
        return try execute(plan, items: items)
    }

    static func execute(_ plan: SecretRunPlan, items: [String: SecretItem],
                        output: Int32 = STDOUT_FILENO, errors: Int32 = STDERR_FILENO) throws -> Int32 {
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in try plan.environment(items: items) { environment[name] = value }

        var files: Files?
        if !plan.files.isEmpty {
            let made = try Files()
            files = made
            for file in plan.files {
                guard let item = items[file.item] else { throw SecretCLI.Failure(message: SecretRunPlan.missing(file.item)) }
                // The macOS shell (bash 3.2) can't source a pipe, so env files are always private files.
                environment[file.variable] = try made.add(try SecretRunPlan.fileContents(item, format: file.format),
                                                          name: file.variable.lowercased(),
                                                          temporary: plan.temporaryFiles || file.format == .env)
            }
        }
        defer { files?.remove() }

        guard let executable = resolve(plan.command[0], path: environment["PATH"]) else {
            throw SecretCLI.Failure(message: "\(plan.command[0]): command not found.", code: 127)
        }
        let masked = items.values.flatMap(\.maskedValues)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(plan.command.dropFirst())
        process.environment = environment

        var pumps: [Pump] = []
        if masked.isEmpty {
            if output != STDOUT_FILENO { process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false) }
            if errors != STDERR_FILENO { process.standardError = FileHandle(fileDescriptor: errors, closeOnDealloc: false) }
        } else {
            for (target, isError) in [(output, false), (errors, true)] {
                let pipe = Pipe()
                if isError { process.standardError = pipe } else { process.standardOutput = pipe }
                pumps.append(Pump(source: pipe.fileHandleForReading.fileDescriptor, target: target, masker: SecretMasker(masked)))
            }
        }
        do {
            try process.run()
        } catch {
            throw SecretCLI.Failure(message: "\(plan.command[0]): \(error.localizedDescription)", code: 126)
        }
        // Only after the launch: a child inherits ignored signals.
        signal(SIGPIPE, SIG_IGN)
        let forwarded = [SIGTERM, SIGHUP, SIGQUIT, SIGINT, SIGUSR1, SIGUSR2]
        var sources: [DispatchSourceSignal] = []
        defer {
            sources.forEach { $0.cancel() }
            for number in forwarded + [SIGPIPE] { signal(number, SIG_DFL) }
        }
        for number in forwarded {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                let pid = process.processIdentifier
                guard pid > 0 else { return }
                // A terminal's Ctrl-C already reached a child in our process group.
                if number == SIGINT, getpgid(pid) == getpgrp() { return }
                kill(pid, number)
            }
            source.resume()
            sources.append(source)
        }
        for pump in pumps { pump.start() }
        process.waitUntilExit()
        // A background child can hold the output open; don't wait on it forever.
        for pump in pumps { pump.finish(within: 3) }
        switch process.terminationReason {
        case .uncaughtSignal: return 128 + process.terminationStatus
        default: return process.terminationStatus
        }
    }

    static func resolve(_ command: String, path: String?) -> String? {
        if command.contains("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        for folder in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(folder)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Copies one stream to another through a masker.
    final class Pump {
        private let source: Int32, target: Int32
        private var masker: SecretMasker
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var flushed = false

        init(source: Int32, target: Int32, masker: SecretMasker) {
            self.source = source
            self.target = target
            self.masker = masker
        }

        func start() {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(source, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    let masked = lock.withLock { flushed ? [] : masker.feed(buffer[0..<count]) }
                    Self.write(masked, to: target)
                }
                done.signal()
            }
        }

        func finish(within seconds: TimeInterval) {
            _ = done.wait(timeout: .now() + seconds)
            let tail = lock.withLock { () -> [UInt8] in
                guard !flushed else { return [] }
                flushed = true
                return masker.finish()
            }
            Self.write(tail, to: target)
        }

        static func write(_ bytes: [UInt8], to descriptor: Int32) {
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
                if written < 0 { if errno == EINTR { continue }; return }
                offset += written
            }
        }
    }

    /// A private folder of pipes or temporary files, removed when the command ends.
    final class Files {
        let folder: URL

        init() throws {
            var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("cantrip-secret-XXXXXX").utf8CString)
            guard let made = mkdtemp(&template) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            folder = URL(fileURLWithPath: String(cString: made), isDirectory: true)
            chmod(folder.path, 0o700)
        }

        /// The path the command reads `data` from.
        func add(_ data: Data, name: String, temporary: Bool) throws -> String {
            let path = folder.appendingPathComponent(name).path
            if temporary {
                guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw POSIXError(.EIO)
                }
                return path
            }
            guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Opening a pipe for writing waits for the reader; the first one to open it gets the data.
            Thread.detachNewThread {
                let descriptor = open(path, O_WRONLY | O_CLOEXEC)
                guard descriptor >= 0 else { return }
                Pump.write(Array(data), to: descriptor)
                close(descriptor)
            }
            return path
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
