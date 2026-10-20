import Foundation

extension SessionTabTests {
    /// Idle runtimes are stopped to free memory only when nothing but MCP servers runs under them.
    static func testCopilotRuntimeActivity() throws {
        typealias Server = CopilotRuntimeActivity.MCPServer
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/bash")
        // A server, and a launcher that renamed itself (as npx does) running a server.
        let script = "/bin/sleep 3 & /bin/bash -c '/bin/sleep 4; :' & wait"
        parent.arguments = ["-c", script]
        try parent.run()
        defer { parent.terminate() }
        // A Copilot tool shell is never a launcher, even when its command looks like a server.
        let runtime = Process()
        runtime.executableURL = URL(fileURLWithPath: "/bin/bash")
        runtime.arguments = ["-c", "/bin/bash --norc --noprofile -c '/bin/sleep 4; :'; :"]
        try runtime.run()
        defer { runtime.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let pid = parent.processIdentifier

        let server = [Server(command: "/bin/sleep", args: ["3"])]
        let work = CopilotRuntimeActivity.liveWork(bridge: pid, runtime: nil, servers: server)
        precondition(work?.hasPrefix("bash (pid ") == true, "a non-server child is work: \(String(describing: work))")
        let both = server + [Server(command: "sleep", args: ["4"])]
        precondition(CopilotRuntimeActivity.liveWork(bridge: pid, runtime: nil, servers: both) == nil,
                     "MCP servers alone keep nothing alive, even behind a launcher")
        // A reported runtime pid narrows the walk to that child of the bridge.
        precondition(CopilotRuntimeActivity.liveWork(bridge: getpid(), runtime: pid, servers: both) == nil)
        precondition(CopilotRuntimeActivity.liveWork(bridge: getpid(), runtime: pid, servers: []) != nil)
        let shellWork = CopilotRuntimeActivity.liveWork(bridge: getpid(), runtime: runtime.processIdentifier, servers: both)
        precondition(shellWork?.hasPrefix("bash (pid ") == true, "a tool shell is work: \(String(describing: shellWork))")
        // Children present when the session opened are its servers, whatever their argv...
        let baseline = CopilotRuntimeActivity.baseline(bridge: getpid(), runtime: pid)
        precondition(baseline.count == 2, "\(baseline)")
        precondition(CopilotRuntimeActivity.liveWork(bridge: getpid(), runtime: pid, baseline: baseline, servers: []) == nil)
        // ...but only for a known runtime: otherwise the runtime itself would be skipped.
        precondition(CopilotRuntimeActivity.baseline(bridge: pid, runtime: nil).isEmpty)
        precondition(CopilotRuntimeActivity.baseline(bridge: pid, runtime: getpid()).isEmpty)
        precondition(CopilotRuntimeActivity.isToolShell(["/bin/bash", "--norc", "--noprofile", "-c", "x"]))

        precondition(CopilotRuntimeActivity.arguments(of: pid) == ["/bin/bash", "-c", script])
        precondition(CopilotRuntimeActivity.matches(["node", "/opt/homebrew/bin/npx", "-y", "pkg"],
                                                    Server(command: "npx", args: ["-y", "pkg"])))
        precondition(!CopilotRuntimeActivity.matches(["node", "x.js"], Server(command: "node", args: ["y.js"])))
        precondition(CopilotRuntimeActivity.matches(["/usr/local/bin/server"], Server(command: "server", args: [])))
        precondition(CopilotRuntimeActivity.matches(["node", "/usr/local/lib/server"], Server(command: "server", args: [])))
        precondition(!CopilotRuntimeActivity.matches(["/bin/bash", "-c", "server"], Server(command: "server", args: [])))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("mcp-config.json")
        precondition(CopilotRuntimeActivity.configuredMCPServers(url: config) == [], "no config, no servers")
        try Data(#"{"mcpServers":{"rea":{"type":"stdio","command":"node","args":["rea.mjs","mcp"]},"web":{"type":"http","url":"https://x"}}}"#.utf8).write(to: config)
        precondition(CopilotRuntimeActivity.configuredMCPServers(url: config) == [Server(command: "node", args: ["rea.mjs", "mcp"])])
        try Data("not json".utf8).write(to: config)
        precondition(CopilotRuntimeActivity.configuredMCPServers(url: config) == nil, "an unreadable config counts as unknown")
        print("Copilot runtime activity: shells and scripts keep an idle runtime, MCP servers don't")
    }
}
