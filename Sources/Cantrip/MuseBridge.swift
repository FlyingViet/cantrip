import Foundation

/// One `python -m muse_cli.bridge` process (muse-cli docs/TUI.md): newline-delimited JSON
/// requests and replies over its pipes, plus events. The bridge's single worker answers requests
/// in order and is the only thing that talks to Muse's gateway.
final class MuseBridgeProcess: @unchecked Sendable {
    struct Failure: Error, LocalizedError, Equatable {
        /// `auth`, `not_found`, `gateway`, `timeout`, `bad_request`, `internal`, or `exited`.
        let kind: String
        let message: String
        var code: String? = nil
        var errorDescription: String? { message }
    }

    let executable: String
    let arguments: [String]
    let environment: [String: String]
    /// Every event line (`connection`, `message`, `idle`, …), on the reader's thread.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// The process ended (crash, `shutdown`, or `stop`).
    var onExit: (() -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var exited = false
    private var stderrTail = ""

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    var isRunning: Bool { lock.withLock { !exited } && process.isRunning }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.read(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                if data.isEmpty { handle.readabilityHandler = nil }
                return
            }
            // Kept only for error messages; muse-cli never prints cookies there.
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { self.stderrTail = String((self.stderrTail + text).suffix(600)) }
        }
        process.terminationHandler = { [weak self] _ in self?.ended() }
        try process.run()
    }

    /// Sends one request and waits for its reply (at most `timeout` seconds).
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let line: Data
        do {
            line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([0x0A])
        } catch {
            throw Failure(kind: "bad_request", message: "Couldn't encode the request for Muse.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gone: Bool = lock.withLock {
                if exited { return true }
                waiting[id] = continuation
                return false
            }
            if gone {
                continuation.resume(throwing: Failure(kind: "exited", message: exitMessage))
                return
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: line)
            } catch {
                finish(id, .failure(Failure(kind: "exited", message: exitMessage)))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, .failure(Failure(kind: "timeout", message: "Muse didn't answer \(method) within \(Int(timeout)) s.")))
            }
        }
    }

    /// Asks the bridge to close its gateway and exit; terminates it if it hasn't after 3 s.
    func stop() {
        guard isRunning else { return }
        if let line = try? JSONSerialization.data(withJSONObject: ["id": 0, "method": "shutdown", "params": [:]]) {
            try? input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
        }
        try? input.fileHandleForWriting.close()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    private var exitMessage: String {
        let tail = lock.withLock { stderrTail }
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return "The Muse bridge stopped" + (tail.isEmpty ? "." : ": \(tail.prefix(200))")
    }

    private func read(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            // A runaway line (no newline) is dropped rather than held forever.
            if buffer.count > 8_000_000 { buffer.removeAll() }
        }
        for line in lines where !line.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let event = object["event"] as? String {
                onEvent?(event, object["data"] as? [String: Any] ?? [:])
            } else if let id = object["id"] as? Int {
                if let error = object["error"] as? [String: Any] {
                    finish(id, .failure(Failure(kind: error["kind"] as? String ?? "internal",
                                                message: error["message"] as? String ?? "Muse reported an error.",
                                                code: error["code"] as? String)))
                } else {
                    finish(id, .success(object["result"] as? [String: Any] ?? [:]))
                }
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func ended() {
        let pending: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            exited = true
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        let failure = Failure(kind: "exited", message: exitMessage)
        for continuation in pending { continuation.resume(throwing: failure) }
        onExit?()
    }
}

/// Cantrip's Muse demo: muse-cli's own demo bridge (made-up data, no account, no network) with
/// two additions, so feeds can be tried end to end. Its fake account is kept on disk, so feed
/// chats and their message numbers survive the bridge stopping between uses; and a feed setup
/// message gets a reply with sample results in the feed's format. A JSON file dropped in the
/// state folder's `demo-inbox/` ({"session_id", "text"}) arrives as a message from Muse in that
/// chat, like a scheduled job's result.
enum MuseDemo {
    static let fileName = "cantrip_muse_demo.py"

    /// Writes the script into `directory` (when it changed) and returns its path.
    static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(fileName)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("demo-inbox"),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static let script = #"""
    """Cantrip's Muse demo bridge: muse-cli's demo with its fake account kept on disk and sample
    feed results. Usage: python cantrip_muse_demo.py <state dir>. Written by Cantrip."""
    import json
    import os
    import re
    import sys
    import time

    from muse_cli import bridge, demo

    STATE_DIR = sys.argv[1] if len(sys.argv) > 1 else "."
    STATE = os.path.join(STATE_DIR, "demo-world.json")
    INBOX = os.path.join(STATE_DIR, "demo-inbox")

    SAMPLES = [
        {"title": "Sunny one-bedroom by the park", "address": "120 Example St, Unit 4",
         "neighborhood": "Mission", "price": "2950", "beds": "1", "baths": "1",
         "url": "https://example.com/listings/1001", "source": "Demo listings"},
        {"title": "Top-floor two-bedroom with a deck", "address": "88 Sample Ave",
         "neighborhood": "Noe Valley", "price": "4200", "beds": "2", "baths": "1",
         "url": "https://example.com/listings/1002", "source": "Demo listings"},
        {"title": "Studio near the train", "address": "5 Placeholder Ct",
         "neighborhood": "SoMa", "price": "2100", "beds": "0", "baths": "1",
         "url": "https://example.com/listings/1003", "source": "Demo listings"},
    ]
    SETUP = re.compile(r"Cantrip feed setup \(feed id: ([A-Za-z0-9_-]+)\)")
    KEYS = re.compile(r"^Keys: (.+)$", re.M)


    class World(demo.World):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            try:
                with open(STATE) as fh:
                    saved = json.load(fh)
                self.sessions = saved["sessions"]
                self.events = saved["events"]
                self.seq = saved["seq"]
                self.next_session = saved["next_session"]
            except (OSError, ValueError, KeyError):
                self.save()

        def save(self):
            tmp = STATE + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"sessions": self.sessions, "events": self.events, "seq": self.seq,
                           "next_session": self.next_session}, fh)
            os.chmod(tmp, 0o600)
            os.replace(tmp, STATE)

        def advance(self):
            before = len(self.streams)
            super().advance()
            changed = self.read_inbox()
            if changed or len(self.streams) != before:
                self.save()

        def read_inbox(self):
            try:
                names = sorted(n for n in os.listdir(INBOX) if n.endswith(".json"))
            except OSError:
                return False
            changed = False
            for name in names:
                path = os.path.join(INBOX, name)
                try:
                    with open(path) as fh:
                        item = json.load(fh)
                except (OSError, ValueError):
                    item = None
                try:
                    os.remove(path)
                except OSError:
                    pass
                sid = item.get("session_id") if isinstance(item, dict) else None
                text = item.get("text") if isinstance(item, dict) else None
                if not isinstance(text, str) or self._session(sid or demo.MAIN) is None:
                    continue
                sid = sid or demo.MAIN
                role = "assistant" if item.get("role", "assistant") == "assistant" else "user"
                ev = self._event(sid, role, text, int(self.wall() * 1000), push=role == "assistant")
                self.events[sid].append(ev)
                self._touch(sid, text)
                changed = True
            return changed

        def send(self, sid, text):
            match = SETUP.search(text)
            if not match:
                super().send(sid, text)
                self.save()
                return
            now = int(self.wall() * 1000)
            self.events[sid].append(self._event(sid, "user", text, now))
            keys_line = KEYS.search(text)
            keys = [k.split(" (")[0].strip() for k in keys_line.group(1).split(",")] if keys_line else []
            today = time.strftime("%Y-%m-%d")
            items = []
            for sample in SAMPLES:
                sample = dict(sample, listedOn=today)
                items.append({k: sample.get(k, "") for k in keys} if keys else sample)
            block = json.dumps({"feed": match.group(1), "items": items}, indent=1)
            reply = ("Got it. I'll run this every day and post what I find here.\n\n"
                     "Today's first results:\n\n```cantrip-feed\n" + block + "\n```")
            self.events[sid].append(self._event(sid, "assistant", reply, now + 900))
            self._touch(sid, reply)
            self.save()

        def api_session_start(self, pp, b):
            result = super().api_session_start(pp, b)
            self.save()
            return result

        def api_session_rename(self, pp, b):
            result = super().api_session_rename(pp, b)
            self.save()
            return result

        def api_session_delete(self, pp, b):
            result = super().api_session_delete(pp, b)
            self.save()
            return result


    demo.World = World
    if __name__ == "__main__":
        bridge.main(["--demo"])
    """#
}
