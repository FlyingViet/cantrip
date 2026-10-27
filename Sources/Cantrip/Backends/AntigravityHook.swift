import Darwin
import Foundation

/// Antigravity's PreToolUse hook, answered by the Cantrip session that started `agy`.
///
/// `agy` loads hooks only from a workspace's `.agents/hooks.json`, the global
/// `~/.gemini/config/hooks.json` or a plugin; there is no per-run option. Rather than write into
/// the folders it works in (and have a child tab commit the file), Cantrip keeps one entry in the
/// global file. The entry runs a helper that answers `allow` (leave the decision to agy's own
/// policy) unless `CANTRIP_AGY_HOOK_SOCKET` is set, which Cantrip does only for the `agy`
/// processes it launches. With the variable set, the app binary (`--cantrip-agy-hook`) passes
/// the request to that session's socket, and anything that goes wrong is a `deny`.
enum AntigravityHook {
    static let entryName = "cantrip-guardrail"
    static let socketVariable = "CANTRIP_AGY_HOOK_SOCKET"
    static let helperArgument = "--cantrip-agy-hook"
    /// Seconds agy waits for the hook; an approval Cantrip asks for can take this long.
    static let timeout = 600

    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json")
    }

    static var helperFile: URL { CantripPaths.cache("agy-hook") }

    /// Tools that only look: allowed in read-only sessions and never asked about.
    static func isReadOnly(tool: String, arguments: [String: Any]) -> Bool {
        let action = (arguments["Action"] as? String)?.lowercased()
        switch tool {
        case "view_file", "list_dir", "find_by_name", "grep_search", "search_web", "read_url_content",
             "list_permissions":
            return true
        case "manage_task":
            return action == "list" || action == "status"
        case "manage_subagents":
            return action == "list"
        default:
            return false
        }
    }

    /// Writes the helper and makes sure the global entry runs it. Throws instead of replacing a
    /// hooks file it can't read.
    static func install(executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]) throws {
        let fm = FileManager.default
        let helper = helperFile
        let script = Data(helperScript(executable: executable).utf8)
        if (try? Data(contentsOf: helper)) != script {
            try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: helper, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: configFile.path) {
            let data = try Data(contentsOf: configFile)
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: configFile.path])
                }
                root = existing
            }
        }
        let wanted = entry(command: shellQuoted(helper.path))
        if let current = root[entryName] as? [String: Any], NSDictionary(dictionary: current).isEqual(to: wanted) {
            return
        }
        root[entryName] = wanted
        try fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configFile, options: .atomic)
    }

    static func entry(command: String) -> [String: Any] {
        [
            "enabled": true,
            "PreToolUse": [[
                "matcher": "*",
                "hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]],
            ] as [String: Any]],
        ]
    }

    static func helperScript(executable: String) -> String {
        let binary = shellQuoted(executable)
        return """
        #!/bin/sh
        # Cantrip's Antigravity guardrail. Only agy sessions Cantrip starts set the socket; any
        # other run gets "allow", which leaves the decision to agy's own permission policy.
        if [ -z "$\(socketVariable)" ]; then
          cat >/dev/null
          echo '{"decision":"allow"}'
          exit 0
        fi
        if [ ! -x \(binary) ]; then
          cat >/dev/null
          echo '{"decision":"deny","reason":"Cantrip is not available to check this action."}'
          exit 0
        fi
        exec \(binary) \(helperArgument)

        """
    }

    /// The `--cantrip-agy-hook` process: hands agy's hook input to the session's socket and prints
    /// its decision. Every failure is a deny, so a broken connection never lets a tool run unchecked.
    static func runHelper() -> Int32 {
        func reply(_ object: [String: Any]) -> Int32 {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"decision":"deny"}"#.utf8)
            FileHandle.standardOutput.write(data + Data([0x0A]))
            return 0
        }
        func deny(_ reason: String) -> Int32 { reply(["decision": "deny", "reason": reason]) }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let path = ProcessInfo.processInfo.environment[socketVariable], !path.isEmpty else {
            return reply(["decision": "allow"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: input),
              let line = try? JSONSerialization.data(withJSONObject: object) else {
            return deny("Cantrip couldn't read this tool call.")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return deny("Cantrip couldn't check this action.") }
        defer { Darwin.close(fd) }
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw POSIXError(.ECONNREFUSED) }
            }
            var timeout = timeval(tv_sec: timeout + 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            try writeLine(fd, data: line)
            let response = try readLine(fd, limit: 65_536)
            guard let decision = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  decision["decision"] is String else {
                return deny("Cantrip sent an unreadable decision.")
            }
            return reply(decision)
        } catch {
            return deny("Cantrip couldn't check this action (code \((error as NSError).code)).")
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func withAddress<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try operation($0, length) }
        }
    }

    static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count <= limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[0..<newline])
                return result
            }
            result.append(contentsOf: buffer[0..<count])
        }
        throw POSIXError(.EMSGSIZE)
    }

    static func writeLine(_ fd: Int32, data: Data) throws {
        var value = data
        value.append(0x0A)
        try value.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { throw POSIXError(.EPIPE) }
                sent += count
            }
        }
    }
}

/// One `agy` process's end of the hook: a socket in a private temporary folder. Each connection
/// carries one request line and gets one decision line back.
final class AntigravityHookServer {
    typealias Respond = (_ decision: String, _ reason: String?) -> Void

    let socketPath: String
    private let directory: URL
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var stopped = false
    private let onRequest: (_ request: [String: Any], _ respond: @escaping Respond) -> Void

    init(onRequest: @escaping (_ request: [String: Any], _ respond: @escaping Respond) -> Void) throws {
        self.onRequest = onRequest
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ct-agy-\(UUID().uuidString.prefix(12))")
        socketPath = directory.appendingPathComponent("hook.sock").path
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            try AntigravityHook.withAddress(socketPath) { address, length in
                guard Darwin.bind(listener, address, length) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
            guard Darwin.listen(listener, 16) == 0 else { throw POSIXError(.EIO) }
            _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
            let fd = listener
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source
            source.resume()
        } catch {
            if listener >= 0 { Darwin.close(listener) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        let source: DispatchSourceRead? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return self.source
        }
        source?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private func acceptAll() {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var user: uid_t = 0, group: gid_t = 0
            guard getpeereid(fd, &user, &group) == 0, user == getuid(), !lock.withLock({ stopped }) else {
                Darwin.close(fd)
                continue
            }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let answered = NSLock()
                var done = false
                let respond: Respond = { decision, reason in
                    let first = answered.withLock { () -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    var body: [String: Any] = ["decision": decision]
                    if let reason, !reason.isEmpty { body["reason"] = reason }
                    if let data = try? JSONSerialization.data(withJSONObject: body) {
                        try? AntigravityHook.writeLine(fd, data: data)
                    }
                    Darwin.close(fd)
                }
                guard let self,
                      let line = try? AntigravityHook.readLine(fd, limit: 32 << 20),
                      let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    respond("deny", "Cantrip couldn't read this tool call.")
                    return
                }
                self.onRequest(request, respond)
            }
        }
    }
}
