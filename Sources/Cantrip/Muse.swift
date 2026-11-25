import Foundation
import Combine

/// One message in a Muse chat, as muse-cli's bridge shapes it (docs/TUI.md `Message`).
struct MuseMessage: Equatable {
    struct File: Equatable {
        let path: String
        let kind: String
        let mime: String?
        let label: String?
    }

    /// Something Muse showed after its text: a link, a finished space, a browser task…
    struct Card: Equatable {
        let kind: String?
        let title: String
        let subtitle: String?
        let url: String?
        let status: String?
    }

    let seq: Int
    let id: String
    let role: String
    let text: String
    let final: Bool
    /// A proactive message (a scheduled job's result, a background update), not a direct reply.
    let push: Bool
    let widget: Bool
    let files: [File]
    /// Quick replies Muse offers, e.g. approving a purchase. Cantrip never picks one.
    let choices: [[String]]
    let card: Card?

    init(seq: Int, id: String = "", role: String, text: String, final: Bool = true, push: Bool = false,
         widget: Bool = false, files: [File] = [], choices: [[String]] = [], card: Card? = nil) {
        self.seq = seq
        self.id = id
        self.role = role
        self.text = text
        self.final = final
        self.push = push
        self.widget = widget
        self.files = files
        self.choices = choices
        self.card = card
    }

    init?(json: [String: Any]) {
        guard let seq = json["seq"] as? Int, let role = json["role"] as? String else { return nil }
        self.seq = seq
        id = json["id"] as? String ?? ""
        self.role = role
        text = json["text"] as? String ?? ""
        final = json["final"] as? Bool ?? true
        push = json["push"] as? Bool ?? false
        widget = json["widget"] as? Bool ?? false
        files = (json["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let path = file["path"] as? String else { return nil }
            return File(path: path, kind: file["kind"] as? String ?? "file", mime: file["mime"] as? String,
                        label: file["label"] as? String)
        }
        choices = (json["choices"] as? [[String: Any]] ?? []).compactMap { $0["options"] as? [String] }
        card = (json["card"] as? [String: Any]).flatMap { card in
            (card["title"] as? String).map {
                Card(kind: card["kind"] as? String, title: $0, subtitle: card["subtitle"] as? String,
                     url: card["url"] as? String, status: card["status"] as? String)
            }
        }
    }
}

/// What Muse answered one `@muse` message with.
struct MuseReply: Equatable {
    var text: String
    var files: [MuseMessage.File]
    var cards: [MuseMessage.Card]
    var choices: [[String]]
    var replied: Bool
    /// Files saved into Home's artifacts, by title.
    var savedFiles: [String] = []
    var lastSeq: Int
}

/// Muse's connection as Settings and clients show it. Never holds a cookie or token.
struct MuseStatus: Codable, Equatable {
    enum State: String, Codable {
        case off, notInstalled, unknown, connected, loginNeeded, offline, broken
    }

    var state: State
    var detail: String?
    var demo = false
    var checkedAt: Date?
    /// Muse's own name for itself (identity), when connected.
    var account: String?

    var label: String {
        switch state {
        case .off: return "Off"
        case .notInstalled: return "muse-cli isn't installed"
        case .unknown: return "Not checked yet"
        case .connected: return demo ? "Connected (demo: made-up data, no account)" : "Connected"
        case .loginNeeded: return "Login missing or expired"
        case .offline: return "Can't reach Muse"
        case .broken: return "Not working"
        }
    }

    /// The label with what went wrong, for Settings and cards.
    var summary: String {
        guard let detail, !detail.isEmpty, state != .connected, state != .off else { return label }
        return label + ": " + String(detail.prefix(200))
    }

    /// What connects Muse (MuseLoginWatcher does the rest): Settings, clients and notices show it.
    static var loginSteps: String {
        "To connect Muse, sign in at muse.ai in Chrome on \(MuseLoginWatcher.computerName). Cantrip copies that login "
            + "to muse-cli by itself, within a few minutes (Check Now does it right away). It stays on that Mac, readable "
            + "only by you. The first time, macOS may ask to share Chrome's login: choose Always Allow. muse.ai ends a "
            + "login a week after you sign in, so Cantrip reminds you a day before; signing in again in Chrome is all it takes."
    }
    static let installSteps = "Install muse-cli on the Mac running Cantrip: `uv tool install muse-cli==\(MuseConnector.pinnedVersion)`."
}

/// Plain-text log of what Cantrip sent to and read from Muse: methods, chats and sizes, never
/// message text or credentials. `~/.cache/Cantrip/muse/activity.log`.
enum MuseLog {
    /// Follows `MuseConnector.directory` (tests move it).
    nonisolated(unsafe) static var directory = MuseConnector.directory
    static var url: URL { directory.appendingPathComponent("activity.log") }
    private static let lock = NSLock()

    static func write(_ line: String, to url: URL = MuseLog.url) {
        let entry = ISODate.string(from: Date()) + " " + line.replacingOccurrences(of: "\n", with: " ") + "\n"
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: url, to: old)
            }
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
        Log.write("muse: " + line)
    }
}

/// Cantrip's connection to the user's Meta Muse agent, through muse-cli's bridge. Cantrip starts
/// the bridge only to send an `@muse` message, read a feed chat or check the login, and stops it
/// after a quiet minute, so nothing runs while Muse isn't in use. Calls run one at a time (the
/// bridge has one gateway consumer). Opt-in: nothing happens while Muse is off in Settings.
@MainActor
final class MuseConnector: ObservableObject {
    static let shared = MuseConnector()
    static let pinnedVersion = "0.3.14"

    nonisolated static var directory: URL { CantripPaths.cache("muse", isDirectory: true) }
    /// muse-cli's own Python, from `uv tool install muse-cli==0.3.14`.
    nonisolated static var defaultPython: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/uv/tools/muse-cli/bin/python"
    }

    @Published private(set) var status: MuseStatus

    // Tests replace these.
    var directory = MuseConnector.directory {
        didSet { MuseLog.directory = directory }
    }
    var settings: () -> (enabled: Bool, demo: Bool) = { (AppSettings.shared.museEnabled, AppSettings.shared.museDemo) }
    /// The bridge command, or nil when muse-cli isn't installed.
    var bridgeCommand: (_ demo: Bool, _ directory: URL) throws -> (executable: String, arguments: [String])? = { demo, directory in
        let python = MuseConnector.defaultPython
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
        if demo { return (python, [try MuseDemo.install(in: directory).path, directory.path]) }
        return (python, ["-m", "muse_cli.bridge"])
    }
    /// How much faster the demo plays (muse-cli's `MUSE_CLI_DEMO_SPEED`).
    var demoSpeed = "4"
    var idleShutdown: TimeInterval = 60
    /// muse-cli's bridge reports `idle` 300 s after a send with no reply.
    var replyTimeout: TimeInterval = 330
    var callTimeout: TimeInterval = 60
    /// Alerts the user (Mac notification and paired devices); set by HostServices.
    var notify: ((_ title: String, _ body: String) -> Void)?
    /// The login's state changed (`MuseLoginWatcher` rechecks, copies Chrome's login and tells the
    /// user). Without it, losing a working login is reported right away.
    var onLoginChange: ((MuseStatus) -> Void)?
    /// Something was sent to Muse's main chat (the Muse tab mirrors it).
    var onMainChatActivity: (() -> Void)?
    var artifactDirectory: () -> URL = { CantripHomeStore.artifactDirectory }
    var registerArtifact: (_ title: String, _ path: String) -> String? = { title, path in
        (try? CantripHomeStore.shared.register(.init(title: title, path: path, kind: nil)))?.title
    }

    private var bridge: MuseBridgeProcess?
    private var bridgeDemo = false
    /// The chat the bridge has open: `.some(nil)` is the main chat.
    private var openChat: String??
    private var tail: Task<Void, Never>?
    private var running = 0
    private var shutdownTask: Task<Void, Never>?
    private var idleWaiters: [UUID: (chat: String?, continuation: CheckedContinuation<Bool, Never>)] = [:]

    init() {
        let saved = (try? Data(contentsOf: Self.directory.appendingPathComponent("status.json")))
            .flatMap { try? JSONDecoder.iso.decode(MuseStatus.self, from: $0) }
        status = saved ?? MuseStatus(state: .unknown)
    }

    var isEnabled: Bool { settings().enabled }

    /// Settings changed: off stops the bridge; on (or demo toggled) checks again.
    func settingsChanged() {
        let current = settings()
        if !current.enabled {
            stopBridge()
            setStatus(MuseStatus(state: .off, demo: current.demo))
        } else {
            if bridge != nil, bridgeDemo != current.demo { stopBridge() }
            Task { await self.check() }
        }
        MuseTab.shared.update()
    }

    // MARK: - Operations

    /// Connects (or reconnects) and reports the login's state. Cheap: one bridge `connect`.
    @discardableResult
    func check() async -> MuseStatus {
        do {
            _ = try await serial { _ in [:] as [String: Any] }
        } catch {}
        return status
    }

    /// Sends `text` to Muse's main chat (`chat` nil) or a side chat and waits for its reply.
    func ask(_ text: String, chat: String?, chatTitle: String, source: String) async throws -> MuseReply {
        try await serial { bridge in
            _ = try await self.open(chat, bridge: bridge, limit: 1)
            MuseLog.write("send to \(chatTitle) (\(text.count) characters) for \(source)")
            let sent = try await bridge.call("send", ["text": text], timeout: self.callTimeout)
            let baseline = sent["baseline"] as? Int ?? 0
            let replied = await self.waitForIdle(chat)
            let history = try await bridge.call("history", ["limit": 40], timeout: self.callTimeout)
            let messages = (history["messages"] as? [[String: Any]] ?? []).compactMap(MuseMessage.init(json:))
                .filter { $0.seq > baseline && $0.role == "assistant" && $0.final }
            var reply = MuseReply(
                text: messages.filter { !$0.widget }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                files: messages.flatMap(\.files), cards: messages.compactMap(\.card),
                choices: messages.flatMap(\.choices), replied: replied || !messages.isEmpty,
                lastSeq: messages.map(\.seq).max() ?? baseline
            )
            reply.savedFiles = await self.save(reply.files, bridge: bridge)
            MuseLog.write("reply from \(chatTitle): \(reply.replied ? "\(reply.text.count) characters" : "none")"
                          + (reply.files.isEmpty ? "" : ", \(reply.files.count) files")
                          + (reply.choices.isEmpty ? "" : ", asks for a choice"))
            if chat == nil { DispatchQueue.main.async { self.onMainChatActivity?() } }
            return reply
        }
    }

    /// Muse's chats with when each last changed (one call; feeds read only the ones that moved).
    func sessions() async throws -> [(id: String?, title: String, updatedAtMs: Int)] {
        try await serial { bridge in
            let result = try await bridge.call("sessions", [:], timeout: self.callTimeout)
            return (result["sessions"] as? [[String: Any]] ?? []).map {
                ($0["session_id"] as? String, $0["title"] as? String ?? "", $0["updated_at_ms"] as? Int ?? 0)
            }
        }
    }

    /// Messages in `chat` (nil: the main chat) after `seq` (oldest first), paging back up to
    /// `pages` × `pageSize`.
    func messages(in chat: String?, after seq: Int, pages: Int = 5, pageSize: Int = 100) async throws -> [MuseMessage] {
        try await serial { bridge in
            var batch = (try await self.open(chat, bridge: bridge, limit: pageSize)).compactMap(MuseMessage.init(json:))
            var collected = batch
            var page = 1
            while page < pages, let oldest = batch.map(\.seq).min(), oldest > seq + 1, batch.count >= pageSize {
                let older = try await bridge.call("history", ["limit": pageSize, "before_seq": oldest], timeout: self.callTimeout)
                batch = (older["messages"] as? [[String: Any]] ?? []).compactMap(MuseMessage.init(json:))
                collected = batch + collected
                page += 1
            }
            MuseLog.write("read chat \(chat ?? "main") after \(seq): \(collected.filter { $0.seq > seq }.count) new")
            return collected.filter { $0.seq > seq }.sorted { $0.seq < $1.seq }
        }
    }

    /// Starts a side chat titled `title` and sends `text` there; returns its ID and the last
    /// message number before the send (the setup reply counts as the feed's first result).
    func startChat(title: String, sending text: String, purpose: String = "setup") async throws -> (sessionID: String, baseline: Int) {
        try await serial { bridge in
            let made = try await bridge.call("new_chat", ["title": title], timeout: self.callTimeout)
            guard let session = (made["chat"] as? [String: Any])?["session_id"] as? String else {
                throw MuseBridgeProcess.Failure(kind: "gateway", message: "Muse didn't return the new chat.")
            }
            self.openChat = .some(session)
            MuseLog.write("started side chat \(session) “\(title)”; send \(purpose) (\(text.count) characters)")
            let sent = try await bridge.call("send", ["text": text], timeout: self.callTimeout)
            return (session, sent["baseline"] as? Int ?? 0)
        }
    }

    // MARK: - Bridge

    /// Runs `body` after every earlier call, with a connected bridge; stops the bridge after a
    /// quiet minute.
    private func serial<T>(_ body: @escaping @MainActor (MuseBridgeProcess) async throws -> T) async throws -> T {
        let previous = tail
        running += 1
        shutdownTask?.cancel()
        let task = Task { @MainActor () async throws -> T in
            _ = await previous?.value
            let bridge = try await self.ready()
            return try await body(bridge)
        }
        tail = Task { _ = try? await task.value }
        defer {
            running -= 1
            scheduleShutdown()
        }
        do {
            return try await task.value
        } catch let failure as MuseBridgeProcess.Failure {
            if failure.kind == "auth" {
                setStatus(state: .loginNeeded, detail: failure.message)
            } else if failure.kind == "exited" || failure.kind == "timeout" {
                stopBridge()
            }
            throw failure
        }
    }

    private func ready() async throws -> MuseBridgeProcess {
        let current = settings()
        guard current.enabled else {
            setStatus(MuseStatus(state: .off, demo: current.demo))
            throw MuseBridgeProcess.Failure(kind: "off", message: "Muse is off in Cantrip's Settings.")
        }
        if let bridge, bridge.isRunning, bridgeDemo == current.demo { return bridge }
        stopBridge()
        guard let command = try bridgeCommand(current.demo, directory) else {
            setStatus(MuseStatus(state: .notInstalled, detail: MuseStatus.installSteps, demo: current.demo, checkedAt: Date()))
            throw MuseBridgeProcess.Failure(kind: "notInstalled", message: MuseStatus.installSteps)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "MUSE_CLI_DEMO")
        if current.demo { environment["MUSE_CLI_DEMO_SPEED"] = demoSpeed }
        let process = MuseBridgeProcess(executable: command.executable, arguments: command.arguments, environment: environment)
        process.onEvent = { [weak self] name, data in
            Task { @MainActor in self?.handle(event: name, data: data) }
        }
        process.onExit = { [weak self, weak process] in
            Task { @MainActor in
                guard let self, let process, self.bridge === process else { return }
                self.bridge = nil
                self.openChat = nil
                self.resolveIdle(nil, replied: false, all: true)
            }
        }
        try process.start()
        bridge = process
        bridgeDemo = current.demo
        openChat = nil
        MuseLog.write("bridge started\(current.demo ? " (demo)" : "")")
        do {
            let connected = try await process.call("connect", [:], timeout: callTimeout)
            let name = (connected["identity"] as? [String: Any])?["name"] as? String
            setStatus(MuseStatus(state: .connected, demo: current.demo, checkedAt: Date(), account: name))
            return process
        } catch let failure as MuseBridgeProcess.Failure {
            stopBridge()
            switch failure.kind {
            case "auth": setStatus(state: .loginNeeded, detail: failure.message)
            case "gateway", "timeout": setStatus(state: .offline, detail: failure.message)
            default: setStatus(state: .broken, detail: failure.message)
            }
            throw failure
        }
    }

    @discardableResult
    private func open(_ chat: String?, bridge: MuseBridgeProcess, limit: Int) async throws -> [[String: Any]] {
        var params: [String: Any] = ["limit": limit]
        params["session_id"] = chat ?? NSNull()
        let result = try await bridge.call("open", params, timeout: callTimeout)
        openChat = .some(chat)
        return result["messages"] as? [[String: Any]] ?? []
    }

    private func waitForIdle(_ chat: String?) async -> Bool {
        let timeout = replyTimeout
        let id = UUID()
        return await withCheckedContinuation { continuation in
            idleWaiters[id] = (chat, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.idleWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
            }
        }
    }

    private func resolveIdle(_ chat: String?, replied: Bool, all: Bool = false) {
        for (id, waiter) in idleWaiters where all || waiter.chat == chat {
            idleWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: replied)
        }
    }

    private func handle(event: String, data: [String: Any]) {
        switch event {
        case "idle":
            resolveIdle(data["session_id"] as? String, replied: data["replied"] as? Bool ?? false)
        case "connection":
            let detail = data["detail"] as? String
            switch data["state"] as? String {
            case "auth_needed": setStatus(state: .loginNeeded, detail: detail)
            case "offline": setStatus(state: .offline, detail: detail)
            case "online" where status.state != .connected:
                setStatus(MuseStatus(state: .connected, demo: bridgeDemo, checkedAt: Date(), account: status.account))
            default: break
            }
        default:
            break
        }
    }

    private func scheduleShutdown() {
        shutdownTask?.cancel()
        guard running == 0, bridge != nil else { return }
        let delay = idleShutdown
        shutdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.running == 0 else { return }
            self.stopBridge()
        }
    }

    func stopBridge() {
        guard let bridge else { return }
        self.bridge = nil
        openChat = nil
        bridge.stop()
        resolveIdle(nil, replied: false, all: true)
        MuseLog.write("bridge stopped")
    }

    /// Downloads Muse's files into Home's artifacts (`Muse/`) and registers them.
    private func save(_ files: [MuseMessage.File], bridge: MuseBridgeProcess) async -> [String] {
        guard !files.isEmpty else { return [] }
        let folder = artifactDirectory().appendingPathComponent("Muse", isDirectory: true)
        var titles: [String] = []
        for file in files.prefix(8) {
            guard let result = try? await bridge.call("download", ["path": file.path, "dir": folder.path], timeout: 300),
                  let row = (result["rows"] as? [[String: Any]])?.first, row["error"] == nil,
                  let path = row["file"] as? String else { continue }
            let name = (path as NSString).lastPathComponent
            if let title = registerArtifact("Muse · " + (file.label?.isEmpty == false ? file.label! : name), path) {
                titles.append(title)
            }
        }
        return titles
    }

    // MARK: - Status

    private func setStatus(state: MuseStatus.State, detail: String?) {
        setStatus(MuseStatus(state: state, detail: detail, demo: settings().demo, checkedAt: Date(), account: status.account))
    }

    /// What the user should do about a missing login, in the status Settings and clients show.
    func noteLoginNeeded(detail: String) {
        guard status.state == .loginNeeded else { return }
        setStatus(MuseStatus(state: .loginNeeded, detail: detail, demo: status.demo, checkedAt: status.checkedAt, account: status.account))
    }

    private func setStatus(_ next: MuseStatus) {
        let previous = status.state
        status = next
        if previous != next.state {
            MuseLog.write("status: \(next.label)")
            if let onLoginChange {
                onLoginChange(next)
            } else if next.state == .loginNeeded, previous == .connected {
                notify?("Muse needs you to sign in", "Cantrip can't reach your Muse until you sign in again. " + MuseStatus.loginSteps)
            }
        }
        let url = directory.appendingPathComponent("status.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder.iso.encode(next) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, sorted keys.
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
