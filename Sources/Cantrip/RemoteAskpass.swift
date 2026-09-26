import Darwin
import Foundation

/// Only OS ssh/ssh-add/sudo children of this execution may request a secret.
/// The helper's stdout is consumed by those programs, never by the model bridge.
final class RemoteAskpass {
    private let process: Process
    private let queue = DispatchQueue(label: "cantrip.askpass")
    private let lock = NSLock()
    private let directory: URL
    private let socketPath: String
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private struct Client {
        let id: UUID
        var request: BackendInputRequest?
    }
    private var clients: [Int32: Client] = [:]
    private var stopped = false
    private var turn = UUID()
    private var turnStartedAt = Date().timeIntervalSince1970
    private var turnActive = true
    private let opened = Date()
    private var wasRunning = false
    private let onRequest: (BackendInputRequest) -> Void
    let environment: [String: String]

    init(process: Process, onRequest: @escaping (BackendInputRequest) -> Void) throws {
        self.process = process
        self.onRequest = onRequest
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ct-input-\(UUID().uuidString.prefix(12))")
        socketPath = directory.appendingPathComponent("input.sock").path
        let helper = directory.appendingPathComponent("askpass")
        environment = ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force",
                       "SUDO_ASKPASS": helper.path, "DISPLAY": "cantrip:0",
                       "CANTRIP_ASKPASS_SOCKET": socketPath]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            let executable = Bundle.main.executableURL!.path.replacingOccurrences(of: "'", with: "'\\''")
            let socket = socketPath.replacingOccurrences(of: "'", with: "'\\''")
            try Data("#!/bin/sh\nexport CANTRIP_ASKPASS_SOCKET='\(socket)'\nexec '\(executable)' --cantrip-askpass \"$@\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            try Self.withAddress(socketPath) { address, length in
                guard Darwin.bind(listener, address, length) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
            guard Darwin.listen(listener, 8) == 0 else { throw POSIXError(.EIO) }
            _ = fcntl(listener, F_SETFL, O_NONBLOCK)
            let fd = listener
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source
            source.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.process.isRunning { self.wasRunning = true }
                else if self.wasRunning || Date().timeIntervalSince(self.opened) > 10 { self.stop() }
            }
            self.timer = timer
            timer.resume()
        } catch {
            if listener >= 0 { Darwin.close(listener) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { stop() }

    func beginTurn() {
        endTurn()
        lock.withLock {
            turn = UUID()
            turnStartedAt = Date().timeIntervalSince1970
            turnActive = true
        }
    }

    func endTurn() {
        let pending = lock.withLock {
            turnActive = false
            let pending = clients.map { ($0.key, $0.value.request) }
            clients.removeAll()
            return pending
        }
        for (fd, request) in pending {
            request?.cancel()
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    func stop() {
        let pending: [(Int32, BackendInputRequest?)] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let pending = clients.map { ($0.key, $0.value.request) }
            clients.removeAll()
            return pending
        }
        timer?.cancel()
        source?.cancel()
        for (fd, request) in pending {
            request?.cancel()
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Darwin inherits listener flags on accepted sockets; read workers are blocking.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let lease = lock.withLock { (turn, turnStartedAt, turnActive) }
        var user: uid_t = 0, group: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard lease.2, getpeereid(fd, &user, &group) == 0, user == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              let requester = Self.trustedRequester(helper: pid, root: process.processIdentifier, startedAfter: lease.1),
              process.isRunning else {
            Log.write("askpass: refused requester pid=\(pid), uid=\(user), error=\(errno)")
            Darwin.close(fd)
            return
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connectionID = UUID()
        let readFD = dup(fd)
        guard readFD >= 0 else { Darwin.close(fd); return }
        let admitted = lock.withLock {
            guard !stopped, turnActive, turn == lease.0, clients.count < 8 else { return false }
            clients[fd] = Client(id: connectionID)
            return true
        }
        guard admitted else { Darwin.close(fd); Darwin.close(readFD); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { Darwin.close(readFD) }
            guard let self else { return }
            do {
                let data = try Self.readLine(readFD, limit: 8192)
                struct Prompt: Decodable { let prompt: String; let confirmation: Bool }
                let prompt = try JSONDecoder().decode(Prompt.self, from: data)
                let request = BackendInputRequest(kind: prompt.confirmation ? .approval : .secret,
                    source: "\(requester) on \(Host.current().localizedName ?? "the Mac")",
                    title: prompt.confirmation ? "Confirm SSH connection" : "Secure credential input",
                    detail: prompt.prompt) { [weak self] answer in
                    guard let self else { return }
                    let valid = self.lock.withLock { self.turnActive && self.turn == lease.0 }
                        && self.process.isRunning
                        && Self.trustedRequester(helper: pid, root: self.process.processIdentifier, startedAfter: lease.1) == requester
                    let value = prompt.confirmation ? (answer.decision == .approve ? "yes" : "no")
                        : (answer.decision == .submit ? answer.text : nil)
                    self.finish(fd, id: connectionID, value: valid ? value : nil)
                }
                let retained = self.lock.withLock {
                    guard self.clients[fd]?.id == connectionID, !self.stopped, self.turnActive, self.turn == lease.0 else { return false }
                    self.clients[fd]?.request = request
                    return true
                }
                if retained { self.onRequest(request) } else { request.cancel() }
            } catch {
                Log.write("askpass: invalid request code=\((error as NSError).code)")
                self.finish(fd, id: connectionID, value: nil)
            }
        }
    }

    private func finish(_ fd: Int32, id: UUID, value: String?) {
        let owned = lock.withLock {
            guard clients[fd]?.id == id else { return false }
            clients.removeValue(forKey: fd)
            return true
        }
        guard owned else { return }
        defer { Darwin.close(fd) }
        do {
            let body: [String: String] = value.map { ["value": $0] } ?? ["error": "Input cancelled"]
            try Self.writeLine(fd, data: JSONSerialization.data(withJSONObject: body))
        } catch {
            Log.write("askpass: input delivery failed; not retried")
        }
    }

    static func trustedRequester(helper: pid_t, root: pid_t, startedAfter: TimeInterval? = nil) -> String? {
        guard helper > 1, root > 1, let parent = parentPID(helper) else { return nil }
        if let startedAfter {
            var info = proc_bsdinfo()
            guard proc_pidinfo(parent, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 >= startedAfter else { return nil }
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(parent, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard ["/usr/bin/ssh", "/usr/bin/ssh-add", "/usr/bin/ssh-keygen", "/usr/bin/sudo"].contains(executable) else { return nil }
        var pid = parent
        for _ in 0..<32 {
            if pid == root { return executable }
            guard let next = parentPID(pid), next > 1, next != pid else { return nil }
            pid = next
        }
        return nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func runHelper() -> Int32 {
        guard let path = ProcessInfo.processInfo.environment["CANTRIP_ASKPASS_SOCKET"] else { return 1 }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        defer { Darwin.close(fd) }
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw POSIXError(.ECONNREFUSED) }
            }
            var timeout = timeval(tv_sec: 610, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let prompt = CommandLine.arguments.dropFirst(2).joined(separator: " ")
            let confirmation = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm"
            try writeLine(fd, data: JSONSerialization.data(withJSONObject: ["prompt": prompt, "confirmation": confirmation]))
            let data = try readLine(fd, limit: 16384)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let value = response["value"] else { return 1 }
            try FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8))
            return 0
        } catch {
            fputs("Cantrip secure input could not be delivered (code \((error as NSError).code)); no credential was sent.\n", stderr)
            return 1
        }
    }

    private static func withAddress<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
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

    private static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data(), byte: UInt8 = 0
        while result.count < limit {
            guard Darwin.read(fd, &byte, 1) == 1 else { throw POSIXError(.ECONNRESET) }
            if byte == 10 { return result }
            result.append(byte)
        }
        throw POSIXError(.EMSGSIZE)
    }

    private static func writeLine(_ fd: Int32, data: Data) throws {
        var value = data
        value.append(10)
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
