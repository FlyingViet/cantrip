import Foundation

private final class DiscoveryEvents {
    private let lock = NSLock()
    private var events: [BackendEvent] = []
    func append(_ event: BackendEvent) { lock.withLock { events.append(event) } }
    var text: String {
        lock.withLock { events.compactMap { if case .textDelta(let text) = $0 { return text }; return nil }.joined() }
    }
    var statuses: [String] {
        lock.withLock { events.compactMap { if case .status(let text) = $0 { return text }; return nil } }
    }
    var done: Int { lock.withLock { events.filter { if case .done = $0 { return true }; return false }.count } }
    var errors: [String] {
        lock.withLock { events.compactMap { if case .failure(let text) = $0 { return text }; return nil } }
    }
}

extension SessionTabTests {
    /// Nov 1: a tab's first message failed with "spawnSync /opt/homebrew/bin/copilot ETIMEDOUT" while the
    /// Mac was swapping, because every new runtime ran `copilot --version` with a 10 s limit.
    @MainActor
    static func testCopilotDiscoveryCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let savedPath = settings.copilotPath
        defer {
            settings.copilotPath = savedPath
            try? FileManager.default.removeItem(at: directory)
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        precondition(ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil,
                     "the discovery cache lives under HOME: run with a temporary one")
        func write(_ text: String, _ path: String, executable: Bool = false) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        }
        // A CLI install whose `--version` sleeps as long as `<dir>/sleep` says, and whose SDK
        // answers every prompt with the install's name.
        func install(_ name: String) throws -> String {
            let root = directory.appendingPathComponent(name).path
            try write("""
            #!/bin/sh
            echo probe >> '\(root)/probes'
            sleep "$(cat '\(directory.path)/sleep' 2>/dev/null || echo 0)"
            echo "GitHub Copilot CLI 9.8.7"
            """, "\(root)/bin/copilot", executable: true)
            try write("""
            import { EventEmitter } from 'node:events';
            import { existsSync, readFileSync } from 'node:fs';
            export const RuntimeConnection = { forStdio: options => options };
            export class CopilotClient {
              constructor() { this.cliProcess = new EventEmitter(); }
              async start() {
                const delay = '\(directory.path)/start-delay';
                if (existsSync(delay)) await new Promise(resolve => setTimeout(resolve, Number(readFileSync(delay, 'utf8')) * 1000));
              }
              async forceStop() {}
              async createSession(config) {
                return { sessionId: `s-${process.pid}`, rpc: {}, async abort() {},
                  async send(options) {
                    config.onEvent({type:'assistant.message_delta', id:'e1',
                      data:{messageId:'m1', deltaContent:`\(name):${options.prompt}`}});
                    config.onEvent({type:'session.idle', data:{}});
                    return 'native-1';
                  } };
              }
            }
            """, "\(root)/copilot-sdk/index.js")
            try write("", "\(root)/prebuilds/darwin-\(arch)/copilot-runtime")
            return root
        }
        func probes(_ root: String) -> Int {
            ((try? String(contentsOfFile: "\(root)/probes", encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func set(_ name: String, _ value: String?) throws {
            let path = directory.appendingPathComponent(name).path
            if let value { try write(value, path) } else { try? FileManager.default.removeItem(atPath: path) }
        }
        // A new tab: a new backend, so a new runtime and a new discovery.
        func newTab(_ prompt: String, script: String = CopilotSessionBridge.script, startupLimit: TimeInterval = 60,
                    within seconds: TimeInterval = 90) async throws -> DiscoveryEvents {
            let backend = CopilotBackend(bridgeScript: script)
            backend.readOnly = true
            backend.newRuntimeStartupLimit = startupLimit
            defer { backend.cancel() }
            let events = DiscoveryEvents()
            backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: []),
                         workdir: home, onEvent: events.append)
            let deadline = Date().addingTimeInterval(seconds)
            while events.done == 0, events.errors.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            precondition(events.done + events.errors.count == 1, "\(prompt) never ended")
            return events
        }

        let first = try install("A")
        settings.copilotPath = "\(first)/bin/copilot"

        // The incident: `--version` takes 15 s. It used to fail at 10 s; now the probe waits, and the
        // runtime's own start gets the full allowance afterwards (25 s each here; 15 + 12 > 25).
        try set("sleep", "15")
        try set("start-delay", "12")
        let slow = try await newTab("slow", startupLimit: 25)
        precondition(slow.errors.isEmpty && slow.text == "A:slow", "\(slow.errors) \(slow.text)")
        precondition(!slow.statuses.contains("Restarting Copilot"), "the start was cut short: \(slow.statuses)")
        precondition(probes(first) == 1)
        try set("start-delay", nil)

        // Later tabs reuse that answer: no probe, so no wait, however slow `--version` is.
        let started = Date()
        let cached = try await newTab("cached")
        precondition(cached.errors.isEmpty && cached.text == "A:cached", "\(cached.errors) \(cached.text)")
        precondition(probes(first) == 1, "a cached install was probed again")
        precondition(Date().timeIntervalSince(started) < 12, "the cached start still waited on the CLI")
        try set("sleep", "0")

        // The CLI changed (npm update or reinstall): probe again, once.
        try "\n# updated\n".appendToFile(atPath: "\(first)/bin/copilot")
        _ = try await newTab("updated")
        _ = try await newTab("updated again")
        precondition(probes(first) == 2, "an updated CLI must be probed once: \(probes(first))")

        // Copilot updated itself: a finished new version folder changes what the loader runs.
        let selfUpdate = "\(home)/Library/Caches/copilot/pkg/darwin-\(arch)/9.9.9"
        try write("", "\(selfUpdate)/app.js")
        try write("", "\(selfUpdate)/.extraction-complete")
        defer { try? FileManager.default.removeItem(atPath: selfUpdate) }
        _ = try await newTab("self-updated")
        _ = try await newTab("self-updated again")
        precondition(probes(first) == 3, "a self-update must be probed once: \(probes(first))")

        // A custom path never borrows another install's SDK, cached or not.
        let second = try install("B")
        settings.copilotPath = "\(second)/bin/copilot"
        let other = try await newTab("other")
        precondition(other.text == "B:other" && probes(second) == 1, other.text)
        settings.copilotPath = "\(first)/bin/copilot"
        let back = try await newTab("back")
        precondition(back.text == "A:back" && probes(first) == 3, back.text)

        // `--version` never answers: one retry in a new runtime, then a plain explanation, not a Node error.
        let quick = CopilotSessionBridge.script.replacingOccurrences(
            of: "const copilotProbeTimeouts = [20000, 25000];", with: "const copilotProbeTimeouts = [300, 400];")
        precondition(quick != CopilotSessionBridge.script, "probe timeouts moved: update this test")
        try "\n# updated again\n".appendToFile(atPath: "\(first)/bin/copilot")
        try set("sleep", "5")
        let stuck = try await newTab("stuck", script: quick)
        precondition(stuck.statuses.contains("Restarting Copilot"), "\(stuck.statuses)")
        let message = stuck.errors.first ?? ""
        precondition(message.hasPrefix("Copilot CLI didn't answer within 1 s"), message)
        precondition(!message.contains("ETIMEDOUT") && !message.contains("spawnSync"), message)
        try set("sleep", "0")
        print("Copilot discovery: slow --version, cached starts, CLI and self-update invalidation, separate installs and probe timeouts passed")
    }
}

private extension String {
    func appendToFile(atPath path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
