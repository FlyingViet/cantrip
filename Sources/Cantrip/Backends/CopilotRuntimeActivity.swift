import Darwin
import Foundation

/// Finds work still running under an idle Copilot runtime: shell commands, scripts and their
/// children. Stopping the runtime would kill them. MCP servers (and their helpers) run for the
/// runtime's whole life and don't count: the runtime's children when its session opened, plus
/// processes matching a configured stdio server (one restarted later).
enum CopilotRuntimeActivity {
    struct MCPServer: Equatable {
        let command: String
        let args: [String]
    }

    /// A process identity that survives pid reuse: pid plus start time.
    struct ProcessKey: Hashable {
        let pid: pid_t
        let seconds: Int
        let microseconds: Int32
    }

    struct ProcessEntry {
        let parent: pid_t
        let key: ProcessKey
    }

    /// The root the walk starts from: the reported runtime when it is the bridge's child, else the bridge.
    static func root(bridge: pid_t, runtime: pid_t?, in processes: [pid_t: ProcessEntry]) -> pid_t {
        runtime.flatMap { processes[$0]?.parent == bridge ? $0 : nil } ?? bridge
    }

    /// The runtime's direct children now, recorded before the model can start any tool. Empty
    /// unless the runtime is known, so an unidentified runtime still counts as work.
    static func baseline(bridge: pid_t, runtime: pid_t?) -> Set<ProcessKey> {
        guard let runtime, let processes = processTable(), processes[runtime]?.parent == bridge else { return [] }
        return Set(processes.values.filter { $0.parent == runtime }.map(\.key))
    }

    /// A short description of one process doing work under the runtime, or nil when only MCP
    /// servers remain. Unknown states count as work.
    static func liveWork(bridge: pid_t, runtime: pid_t?, baseline: Set<ProcessKey> = [],
                         servers: [MCPServer]? = nil) -> String? {
        guard let processes = processTable() else { return "an unreadable process list" }
        guard let servers = servers ?? configuredMCPServers() else { return "an unreadable MCP config" }
        let root = root(bridge: bridge, runtime: runtime, in: processes)
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in processes { children[entry.parent, default: []].append(pid) }
        /// A server, possibly behind a launcher such as npx that renames itself: follows only
        /// single-child links, and never through the runtime's own tool shells.
        func isServer(_ pid: pid_t) -> Bool {
            var current = pid
            for _ in 0..<6 {
                guard let args = arguments(of: current), !isToolShell(args) else { return false }
                if servers.contains(where: { matches(args, $0) }) { return true }
                guard let next = children[current], next.count == 1 else { return false }
                current = next[0]
            }
            return false
        }
        for child in children[root] ?? [] {
            if let entry = processes[child], baseline.contains(entry.key) { continue }
            if isServer(child) { continue }
            guard let first = arguments(of: child)?.first else { return "process \(child)" }
            return "\((first as NSString).lastPathComponent) (pid \(child))"
        }
        return nil
    }

    /// The Copilot CLI runs each shell tool command as `bash --norc --noprofile ...`.
    static func isToolShell(_ argv: [String]) -> Bool {
        argv.count > 2 && (argv[0] as NSString).lastPathComponent == "bash"
            && argv[1] == "--norc" && argv[2] == "--noprofile"
    }

    /// Stdio servers from ~/.copilot/mcp-config.json; nil when the file exists but can't be read.
    static func configuredMCPServers(
        url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.copilot/mcp-config.json")
    ) -> [MCPServer]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let servers = object["mcpServers"] as? [String: Any] ?? [:]
        return servers.values.compactMap { value in
            guard let spec = value as? [String: Any], let command = spec["command"] as? String,
                  !command.isEmpty else { return nil }
            return MCPServer(command: command, args: spec["args"] as? [String] ?? [])
        }
    }

    /// The server's arguments end the process's argv (launchers such as npx add their own first);
    /// a server without arguments is the program itself or a script its interpreter runs.
    static func matches(_ argv: [String], _ server: MCPServer) -> Bool {
        guard !argv.isEmpty else { return false }
        if server.args.isEmpty {
            let name = (server.command as NSString).lastPathComponent
            return argv.prefix(2).contains { ($0 as NSString).lastPathComponent == name }
        }
        return argv.count > server.args.count && Array(argv.suffix(server.args.count)) == server.args
    }

    /// Every live (non-zombie) process with its parent and start time.
    static func processTable() -> [pid_t: ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        size += size / 4
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        var table: [pid_t: ProcessEntry] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
        where Int32(process.kp_proc.p_stat) != SZOMB {
            let started = process.kp_proc.p_starttime
            let pid = process.kp_proc.p_pid
            table[pid] = ProcessEntry(parent: process.kp_eproc.e_ppid,
                                      key: ProcessKey(pid: pid, seconds: started.tv_sec,
                                                      microseconds: started.tv_usec))
        }
        return table
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
