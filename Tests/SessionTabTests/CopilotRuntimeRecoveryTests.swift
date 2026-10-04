import Foundation

private final class RecoveryEvents {
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
    /// The Copilot CLI runtime crashes (stack overflow) after many idle hours. Each case below is
    /// one seen in Brian's logs: none may reach him as "startup timed out" or a 15-minute stall.
    @MainActor
    static func testCopilotRuntimeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeSDK = #"""
        import { EventEmitter } from 'node:events';
        import { existsSync, unlinkSync, appendFileSync } from 'node:fs';
        const dir = 'FIXTURE_DIR';
        const take = name => {
          const path = `${dir}/${name}`;
          if (!existsSync(path)) return false;
          if (name !== 'crash-always') unlinkSync(path);
          return true;
        };
        export const RuntimeConnection = { forStdio: options => options };
        export class CopilotClient {
          constructor() { this.cliProcess = new EventEmitter(); }
          async start() {}
          async forceStop() {}
          session(config, id, resumed) {
            let count = 0, slowAbort = false;
            const die = () => this.cliProcess.emit('exit', null, 'SIGBUS');
            const say = text => config.onEvent({type:'assistant.message_delta', id:`e${count}`,
              data:{messageId:`m${count}`, deltaContent:text}});
            return {
              sessionId: id, rpc: {},
              async abort() { if (slowAbort) await new Promise(resolve => setTimeout(resolve, 1000)); },
              async send(options) {
                count++;
                appendFileSync(`${dir}/sends`, options.prompt.split('\n')[0] + '\n');
                if (take('crash-always') || take('crash-before-accept')) {
                  setTimeout(die, 20);
                  return new Promise(() => {});
                }
                if (take('hang')) return new Promise(() => {});
                if (take('reject')) throw Error('Session is disconnected');
                if (take('reject-slowly')) {
                  slowAbort = true;
                  await new Promise(resolve => setTimeout(resolve, 1200));
                  throw Error('Session is disconnected');
                }
                if (take('crash-after-accept')) { setTimeout(die, 50); return `native-${count}`; }
                if (take('crash-mid-reply')) { say('partial'); setTimeout(die, 50); return `native-${count}`; }
                if (take('die-when-idle')) setTimeout(die, 150);
                say(`${id}:${resumed ? 'resumed' : 'new'}:${count}:${options.prompt}\n`);
                const idle = () => config.onEvent({type:'session.idle', data:{}});
                if (options.prompt.includes('slow reply')) setTimeout(idle, 1500); else idle();
                return `native-${count}`;
              }
            };
          }
          async createSession(config) { return this.session(config, `s-${process.pid}`, false); }
          async resumeSession(id, config) {
            appendFileSync(`${dir}/resumes`, id + '\n');
            return this.session(config, id, true);
          }
        }
        """#.replacingOccurrences(of: "FIXTURE_DIR", with: directory.path)
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime() { return {sdk: '\(sdkURL)', runtime: 'fixture', sessionRuntime: 'fixture'}; }"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        let backend = CopilotBackend(bridgeScript: script)
        backend.readOnly = true
        backend.reusedStartupLimit = 1.5
        backend.newRuntimeStartupLimit = 5
        defer { backend.cancel() }

        func run(_ prompt: String, history: [ConversationTurn] = []) async throws -> RecoveryEvents {
            let events = RecoveryEvents()
            backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: history),
                         workdir: NSHomeDirectory(), onEvent: events.append)
            let deadline = Date().addingTimeInterval(15)
            while events.done == 0, events.errors.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(events.done + events.errors.count == 1, "turn \(prompt) never ended")
            return events
        }
        func arm(_ name: String) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }
        func sends() -> [String] {
            ((try? String(contentsOf: directory.appendingPathComponent("sends"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func resumes() -> [String] {
            ((try? String(contentsOf: directory.appendingPathComponent("resumes"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        let history = [ConversationTurn(user: "OLD_TURN_RECAP", assistant: "old")]

        let first = try await run("first")
        precondition(first.errors.isEmpty && first.text.hasSuffix(":new:1:first\n"), first.text)
        let session = String(first.text.prefix { $0 != ":" })

        // Oct 4 05:05: the idle runtime died as the prompt arrived. Before, this waited 45 s and
        // failed with "startup timed out"; now a new runtime resumes the session and answers.
        arm("crash-before-accept")
        let crashed = try await run("after crash", history: history)
        precondition(crashed.errors.isEmpty, "\(crashed.errors)")
        precondition(crashed.text == "\(session):resumed:1:after crash\n",
                     "a resumed session gets the prompt without a history recap: \(crashed.text)")
        precondition(crashed.statuses.contains("Restarting Copilot"), "\(crashed.statuses)")
        precondition(resumes() == [session])

        // A runtime that is alive but never answers is replaced after the reused-runtime limit.
        arm("hang")
        let hung = try await run("after hang")
        precondition(hung.errors.isEmpty && hung.text == "\(session):resumed:1:after hang\n", "\(hung.errors) \(hung.text)")

        // A runtime whose connection dropped while idle rejects the prompt instead of crashing.
        arm("reject")
        let rejected = try await run("after reject")
        precondition(rejected.errors.isEmpty && rejected.text == "\(session):resumed:1:after reject\n",
                     "\(rejected.errors) \(rejected.text)")

        // Rejected just before the startup limit, by a bridge slow to exit: one retry, never two.
        arm("reject-slowly")
        let slow = try await run("after slow reject, slow reply")
        precondition(slow.errors.isEmpty && slow.text == "\(session):resumed:1:after slow reject, slow reply\n",
                     "\(slow.errors) \(slow.text)")
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(sends().filter { $0.hasPrefix("after slow reject") }.count == 2,
                     "the prompt was resent more than once: \(sends())")

        // Oct 4 08:12: accepted, then the runtime died before any output. Before, the turn sat
        // silent until the 15-minute stall cancel; nothing ran, so it is safe to resend.
        arm("crash-after-accept")
        let accepted = try await run("after accept")
        precondition(accepted.errors.isEmpty && accepted.text == "\(session):resumed:1:after accept\n",
                     "\(accepted.errors) \(accepted.text)")

        // Died mid-reply: output can't be replayed, so the turn ends at once (not after 15 minutes)
        // and the next prompt continues the same session.
        arm("crash-mid-reply")
        let mid = try await run("mid")
        precondition(mid.errors == [CopilotBackend.lostMidReply] && mid.text == "partial", "\(mid.errors) \(mid.text)")
        backend.cancel() // ChatSession cancels after every failure; that must keep the session to resume.
        let next = try await run("continue")
        precondition(next.errors.isEmpty && next.text == "\(session):resumed:1:continue\n", "\(next.errors) \(next.text)")

        // Oct 4 08:37: the runtime died between turns. The next prompt resumes in a new runtime.
        arm("die-when-idle")
        let beforeDeath = try await run("before idle death")
        precondition(beforeDeath.errors.isEmpty)
        try await Task.sleep(nanoseconds: 400_000_000)
        let afterDeath = try await run("after idle death")
        precondition(afterDeath.errors.isEmpty && afterDeath.text == "\(session):resumed:1:after idle death\n",
                     "\(afterDeath.errors) \(afterDeath.text)")

        // Prevention: a runtime idle past the limit is restarted before reuse, keeping the session.
        backend.idleRuntimeLimit = 0.2
        try await Task.sleep(nanoseconds: 300_000_000)
        let restarted = try await run("after long idle")
        precondition(restarted.errors.isEmpty && restarted.text == "\(session):resumed:1:after long idle\n",
                     "\(restarted.errors) \(restarted.text)")
        let quick = try await run("soon after")
        precondition(quick.text == "\(session):resumed:2:soon after\n", "a recently used runtime is reused: \(quick.text)")
        backend.idleRuntimeLimit = 3_600

        // Stopping a live turn still starts the next prompt in a new session, as before.
        arm("hang")
        let stopped = RecoveryEvents()
        backend.send(BackendRequest(prompt: "stop me", userMessage: "stop me", previousTurns: []),
                     workdir: NSHomeDirectory(), onEvent: stopped.append)
        try await Task.sleep(nanoseconds: 300_000_000)
        backend.cancel()
        let afterStop = try await run("after stop", history: history)
        precondition(afterStop.errors.isEmpty && afterStop.text.contains(":new:1:") && afterStop.text.contains("OLD_TURN_RECAP"),
                     "\(afterStop.errors) \(afterStop.text)")

        // One automatic retry only: a second loss reports clearly instead of looping.
        arm("crash-always")
        let doomed = try await run("doomed")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("crash-always"))
        precondition(doomed.errors == [CopilotBackend.startupFailure], "\(doomed.errors)")

        // Reset still starts a new conversation (recap included), never a resume.
        let resumedCount = resumes().count
        backend.reset()
        let fresh = try await run("fresh", history: history)
        precondition(fresh.errors.isEmpty && fresh.text.contains(":new:1:") && fresh.text.contains("OLD_TURN_RECAP"),
                     "\(fresh.errors) \(fresh.text)")
        precondition(resumes().count == resumedCount)
        print("Copilot runtime recovery: crashes, stalls and idle restarts recovered without user-facing errors")
    }

    /// Opt-in (CANTRIP_RECOVERY_LIVE_TEST=1, a few cheap model calls): the real SDK reports a crashed
    /// runtime and resumes the same Copilot session in a new one, idle or mid-send.
    @MainActor
    static func testCopilotRuntimeRecoveryLive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-recovery-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CopilotBackend()
        backend.modelOverride = "gpt-5.4-mini"
        backend.readOnly = true
        defer { backend.cancel() }
        func children(of pid: Int32) -> [Int32] {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", String(pid)]
            let out = Pipe()
            pgrep.standardOutput = out
            try? pgrep.run()
            pgrep.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").compactMap { Int32($0) }
        }
        /// Crashes the runtime the way the CLI does (a fatal signal), leaving the bridge alive.
        func crashRuntime() -> Int32? {
            for bridge in children(of: getpid()) {
                if let runtime = children(of: bridge).first { kill(runtime, SIGSEGV); return runtime }
            }
            return nil
        }
        func run(_ prompt: String, crashAfter delay: UInt64? = nil) async throws -> RecoveryEvents {
            let events = RecoveryEvents()
            backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: []),
                         workdir: directory.path, onEvent: events.append)
            if let delay {
                try await Task.sleep(nanoseconds: delay)
                precondition(crashRuntime() != nil, "no runtime to crash")
            }
            let deadline = Date().addingTimeInterval(150)
            while events.done == 0, events.errors.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(events.errors.isEmpty && events.done == 1, "\(prompt): \(events.errors)")
            return events
        }
        _ = try await run("This is a tool-free integration test. Remember CANTRIP_RESUME_MARKER_314 and reply only OK.")
        precondition(crashRuntime() != nil, "the runtime must be a child of the bridge")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let afterIdleCrash = try await run("Reply only with the marker string you were asked to remember.")
        precondition(afterIdleCrash.text.contains("CANTRIP_RESUME_MARKER_314"), "idle crash lost the session: \(afterIdleCrash.text)")
        let midSend = try await run("Reply only with the marker string again.", crashAfter: 150_000_000)
        precondition(midSend.text.contains("CANTRIP_RESUME_MARKER_314"), "crash during send lost the session: \(midSend.text)")
        backend.idleRuntimeLimit = 0
        let restarted = try await run("One more time: reply only with the marker string.")
        precondition(restarted.text.contains("CANTRIP_RESUME_MARKER_314"), "idle restart lost the session: \(restarted.text)")
        print("Live Copilot: idle crash, crash during send and idle restart all resumed the same session")
    }
}
