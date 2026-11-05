import AppKit
import Foundation
import SwiftUI

private final class BuildBackendFixture: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// Build cards: which commands count, how results and background shells are read, estimates
    /// from earlier runs only, and the card's life in a tab and on paired clients.
    @MainActor
    static func testBuildCards() async throws {
        testBuildDetection()
        testBuildOutcomes()
        try testBuildHistory()
        try await testBuildCardsThroughSession()
        try testBuildCardDocuments()
        try writeBuildCardSnapshots()
        print("Build cards: detection, results, background shells, history estimates, session flow and client cards passed")
    }

    static func testBuildDetection() {
        let work = "/Users/test/Coding/App"
        func title(_ command: String) -> String? { BuildDetector.detect(command, workdir: work)?.title }
        let cases: [(String, String?)] = [
            ("xcodebuild -scheme Hermes -destination 'id=1B2C3D4E-1111-2222-3333-444455556666' test 2>&1 | tail -40",
             "xcodebuild test · Hermes"),
            ("xcodebuild -project App.xcodeproj -scheme App -configuration Release archive -archivePath /tmp/a.xcarchive",
             "xcodebuild archive · App"),
            ("xcodebuild -exportArchive -archivePath x.xcarchive -exportOptionsPlist o.plist", "xcodebuild export"),
            ("xcodebuild -quiet build", "xcodebuild build"),
            ("xcodebuild -list", nil),
            ("xcodebuild -showBuildSettings -scheme App", nil),
            ("cd Clients/CantripIOS && xcodegen generate && xcrun xcodebuild -scheme Hermes build", "xcodebuild build · Hermes"),
            ("swift build -c release --arch arm64", "swift build (release)"),
            ("swift build --show-bin-path", nil),
            ("swift test", "swift test"),
            ("make test-copilot-parser 2>&1 | tail -15", "make test-copilot-parser"),
            ("make -C ~/Coding/Cantrip app", "make app"),
            ("make clean", nil),
            ("make -n build", nil),
            ("./gradlew assembleRelease", "gradle assembleRelease"),
            ("./gradlew --stop", nil),
            ("npm run build", "npm run build"),
            ("npm run package:win", "npm run package:win"),
            ("npm run typecheck", nil),
            ("npm test", nil),
            ("pnpm build", "pnpm build"),
            ("npx -y expo export --platform ios", "expo export"),
            ("npx expo start", nil),
            ("eas build --platform ios --profile production", "eas build (ios)"),
            ("bundle exec fastlane beta", "fastlane beta"),
            ("fastlane lanes", nil),
            ("xcrun altool --upload-app -f App.ipa -t ios", "App Store upload"),
            ("xcrun notarytool submit App.zip --wait", "Notarization"),
            ("perl -e 'alarm 900; exec @ARGV' xcodebuild -scheme Hermes test", "xcodebuild test · Hermes"),
            ("script -q /tmp/log make test", "make test"),
            ("bash -lc 'cd windows && npm run build'", "npm run build"),
            ("Scripts/build-home-window.sh", "build-home-window.sh"),
            ("./deploy-when-idle.sh abc", nil),
            ("cargo build --release", "cargo build"),
            ("docker buildx build -t app .", "docker build"),
            ("grep -rn xcodebuild Makefile", nil),
            ("echo 'swift build'", nil),
            ("git commit -m 'make build faster'", nil),
            ("make build && make test", "make build → make test"),
        ]
        for (command, expected) in cases {
            precondition(title(command) == expected, "\(command) -> \(title(command) ?? "nil"), expected \(expected ?? "nil")")
        }
        // A new simulator lease or temp folder is still the same build.
        let first = BuildDetector.detect("xcodebuild -scheme Hermes -destination 'id=1B2C3D4E-1111-2222-3333-444455556666' test", workdir: work)
        let second = BuildDetector.detect("xcodebuild -scheme Hermes -destination 'id=9F8E7D6C-1111-2222-3333-444455556666' test", workdir: work)
        precondition(first?.key == second?.key && first?.key.hasPrefix(work + "\n") == true)
        let elsewhere = BuildDetector.detect("cd /Users/test/Coding/Other && swift build", workdir: work)
        precondition(elsewhere?.directory == "/Users/test/Coding/Other" && elsewhere?.project == "Other"
                     && elsewhere?.key != BuildDetector.detect("swift build", workdir: work)?.key)
        precondition(BuildDetector.detect("make -C ~/Coding/Cantrip app", workdir: work)?.project == "Cantrip")
        precondition(BuildDetector.detect("xcodebuild -scheme Hermes test", workdir: work)?.verb == "Testing"
                     && BuildDetector.detect("xcrun altool --upload-app -f a.ipa", workdir: work)?.verb == "Uploading")
    }

    static func testBuildOutcomes() {
        func outcome(_ output: String, _ state: ToolActivityState = .succeeded) -> (BuildRun.State, Int?) {
            BuildOutput.outcome(output: output, state: state)
        }
        precondition(outcome("** BUILD SUCCEEDED **\n<shellId: 4 completed with exit code 0>") == (.succeeded, 0))
        // A piped `| tail` exits 0; the tool's own line wins.
        precondition(outcome("error: x\n** TEST FAILED **\n<shellId: 4 completed with exit code 0>") == (.failed, 0))
        precondition(outcome("make: *** [test] Error 1\n<shellId: 5 completed with exit code 2>") == (.failed, 2))
        precondition(outcome("Exit code 65\nerror: build failed", .failed) == (.failed, 65))
        precondition(outcome("Build complete! (12.3s)") == (.succeeded, nil))
        precondition(outcome("BUILD FAILED in 4s") == (.failed, nil))
        precondition(outcome("no markers", .failed) == (.failed, nil) && outcome("no markers", .cancelled) == (.stopped, nil))
        precondition(BuildOutput.neverRan("PreToolUse:Bash hook error: Blocked by Cantrip's agent policy (rule deletes-outside-workspace)")
                     && BuildOutput.neverRan("The user rejected this tool call. User feedback: Blocked by Cantrip's agent policy")
                     && BuildOutput.neverRan("Command not executed. The 'kill' command must specify a PID")
                     && !BuildOutput.neverRan("error: no such module 'Foo'\nThe user rejected this tool call"))
        precondition(BuildOutput.backgroundShell(in: "<command started in background with shellId: metro>") == "metro")
        precondition(BuildOutput.backgroundShell(in: "out\n<command with shellId: 83 is still running after 30 seconds. The command is still running.>") == "83")
        precondition(BuildOutput.backgroundShell(in: "Command running in background with ID: b6dlgjf0n. Output is being written to: /tmp/x") == "b6dlgjf0n")
        precondition(BuildOutput.backgroundShell(in: "<shellId: 3 completed with exit code 0>") == nil)
        precondition(BuildOutput.finishedShells(in: "x\n<shellId: 230 completed with exit code 1>").map(\.id) == ["230"])
        precondition(BuildOutput.finishedShells(in: "<command with shellId: 230 is still running after 1 seconds.>").isEmpty)
        // Long output keeps its tail for the exit code.
        let long = ToolActivityFactory.complete(nil, id: "l", toolName: "bash", success: true,
                                                output: String(repeating: "line\n", count: 6_000) + "** BUILD FAILED **\n<shellId: 9 completed with exit code 65>")
        precondition(long.output?.hasSuffix("output truncated") == true && long.outputTail?.contains("exit code 65") == true)
    }

    @MainActor
    static func testBuildHistory() throws {
        let file = CantripPaths.cache("test-build-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = BuildHistory(file: file)
        precondition(history.estimate(for: "k") == nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ seconds: Double, _ state: BuildRun.State) -> BuildRun {
            var run = BuildRun(id: UUID().uuidString, command: BuildCommand(title: "swift build", verb: "Building", directory: "/w", key: "k"),
                               startedAt: start, estimate: nil)
            run.finish(state, at: start.addingTimeInterval(seconds))
            return run
        }
        history.record(run(100, .succeeded))
        precondition(history.estimate(for: "k") == .init(seconds: 100, runs: 1))
        history.record(run(4, .failed))
        precondition(history.estimate(for: "k") == .init(seconds: 100, runs: 1), "failures stop early and don't count")
        history.record(run(120, .succeeded))
        history.record(run(400, .succeeded))
        precondition(history.estimate(for: "k") == .init(seconds: 120, runs: 3), "the median shrugs off one slow run")
        var ended = run(50, .succeeded)
        ended.state = .ended
        history.record(ended)
        precondition(history.runs(for: "k").count == 4, "a result Cantrip couldn't read is never recorded")
        for _ in 0..<12 { history.record(run(90, .succeeded)) }
        precondition(history.runs(for: "k").count == BuildHistory.keptRuns)
        let reloaded = BuildHistory(file: file)
        precondition(reloaded.estimate(for: "k") == .init(seconds: 90, runs: 5))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @MainActor
    static func testBuildCardsThroughSession() async throws {
        let settings = AppSettings.shared
        let saved = (settings.memoryEnabled, settings.backend)
        settings.memoryEnabled = false
        settings.backend = .copilot
        defer { (settings.memoryEnabled, settings.backend) = saved }
        try? FileManager.default.removeItem(at: BuildHistory.shared.file)

        func shell(_ id: String, _ command: String, _ state: ToolActivityState = .running, output: String? = nil,
                   step: BuildStep? = nil) -> ToolActivity {
            var activity = ToolActivityFactory.start(id: id, toolName: "bash", arguments: ["command": command])
            activity.state = state
            activity.output = output
            activity.buildStep = step
            return activity
        }
        let backend = BuildBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Build it")
        try await waitForJournalTest { backend.requests.count == 1 }

        // A plain command gets no card; a build gets one at once, with no estimate on its first run.
        backend.sink?(.activity(shell("ls-1", "ls -la")))
        backend.sink?(.activity(shell("sb-1", "swift build")))
        try await waitForJournalTest { chat.messages.last?.builds.count == 1 }
        var build = chat.messages.last!.builds[0]
        precondition(build.state == .running && build.title == "swift build" && build.expectedSeconds == nil)
        precondition(build.document.blocks[1].status == "running" && build.document.blocks[1].expectedSeconds == nil
                     && build.document.blocks[1].detail == "First timed run here, so no estimate yet")
        backend.sink?(.activity(shell("sb-1", "swift build", step: BuildStep(current: 30, total: 120))))
        try await waitForJournalTest { chat.messages.last?.builds.first?.step?.current == 30 }
        precondition(chat.messages.last!.builds[0].document.blocks[1].fraction == 0.25)
        try await Task.sleep(for: .milliseconds(1_100))
        backend.sink?(.activity(shell("sb-1", "swift build", .succeeded,
                                      output: "Build complete! (1.1s)\n<shellId: 1 completed with exit code 0>")))
        try await waitForJournalTest { chat.messages.last?.builds.first?.state == .succeeded }
        build = chat.messages.last!.builds[0]
        precondition(build.exitCode == 0 && (build.duration ?? 0) >= 1, "\(build)")
        precondition(BuildHistory.shared.estimate(for: build.key)?.runs == 1, "the duration is saved for next time")

        // The same build again: the card shows the estimate from the first run.
        backend.sink?(.activity(shell("sb-2", "swift build")))
        try await waitForJournalTest { chat.messages.last?.builds.count == 2 }
        let second = chat.messages.last!.builds[1]
        precondition(second.expectedSeconds == BuildHistory.shared.estimate(for: build.key)?.seconds && second.timedRuns == 1)
        precondition(second.document.blocks[1].expectedSeconds != nil && second.detail.hasPrefix("Usually "))
        backend.sink?(.activity(shell("sb-2", "swift build", .failed,
                                      output: "error: no such module\n<shellId: 2 completed with exit code 1>")))
        try await waitForJournalTest { chat.messages.last?.builds[1].state == .failed }
        precondition(chat.messages.last!.builds[1].exitCode == 1 && chat.messages.last!.builds[1].detail == "Exit code 1")

        // A command refused before it ran (a policy or hook said no) never was a build: no card.
        backend.sink?(.activity(shell("rf-1", "rm -rf .build && swift build")))
        try await waitForJournalTest { chat.messages.last?.builds.count == 3 }
        backend.sink?(.activity(shell("rf-1", "rm -rf .build && swift build", .failed,
                                      output: "PreToolUse:Bash hook error: Blocked by Cantrip's agent policy (rule deletes-outside-workspace)")))
        try await waitForJournalTest { chat.messages.last?.builds.count == 2 }

        // Moved to the background: the card keeps running until the shell's notification.
        backend.sink?(.activity(shell("xb-1", "xcodebuild -scheme Hermes test")))
        backend.sink?(.activity(shell("xb-1", "xcodebuild -scheme Hermes test", .succeeded,
                                      output: "<command with shellId: 12 is still running after 30 seconds. The command is still running.>")))
        try await waitForJournalTest { chat.messages.last?.builds.last?.shellID == "12" }
        precondition(chat.messages.last!.builds.last!.state == .running)
        backend.sink?(.commandFinished(FinishedCommand(ids: ["12"], exitCode: 65, state: .failed)))
        try await waitForJournalTest { chat.messages.last?.builds.last?.state == .failed }
        precondition(chat.messages.last!.builds.last!.exitCode == 65)

        // A watcher subagent reads a background build's shell; the result finishes the card.
        backend.sink?(.activity(shell("mk-1", "make app")))
        backend.sink?(.activity(shell("mk-1", "make app", .succeeded, output: "<command started in background with shellId: app1>")))
        try await waitForJournalTest { chat.messages.last?.builds.last?.shellID == "app1" }
        var watcher = ToolActivityFactory.start(id: "watch-1", toolName: "task", arguments: ["description": "watch-app"])
        var read = ToolActivityFactory.start(id: "rb-1", toolName: "read_bash", arguments: ["shellId": "app1"])
        read.state = .succeeded
        read.output = "Packaged Cantrip.app\n<shellId: app1 completed with exit code 0>"
        watcher.children = [read]
        backend.sink?(.activity(watcher))
        try await waitForJournalTest { chat.messages.last?.builds.last?.state == .succeeded }

        // A build still running when the run is stopped ends as stopped, and isn't timed.
        let recorded = BuildHistory.shared.runs(for: chat.messages.last!.builds.last!.key).count
        backend.sink?(.activity(shell("sb-3", "swift build")))
        try await waitForJournalTest { chat.messages.last?.builds.count == 5 }
        chat.stop()
        try await waitForJournalTest { chat.messages.last(where: { !$0.builds.isEmpty })?.builds.last?.state == .stopped }
        let message = chat.messages.last(where: { !$0.builds.isEmpty })!
        precondition(BuildHistory.shared.runs(for: message.builds[4].key).count == 2, "a stopped build isn't timed")
        precondition(BuildHistory.shared.runs(for: message.builds[3].key).count == recorded)

        // Clients get every build as a card, before the reply's own cards.
        let snapshot = RemoteHistory.message(message)
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        precondition(cards.count == 5 && cards.allSatisfy { $0["type"] as? String == "build" }, "\(cards.count)")
        let progress = (cards[0]["blocks"] as? [[String: Any]])?.last
        precondition(progress?["type"] as? String == "progress" && progress?["status"] as? String == "succeeded"
                     && progress?["startedAt"] is String && progress?["finishedAt"] is String)

        // Saved and reloaded: a build cut off mid-run reads as ended, never running forever.
        var running = message
        running.builds[4].state = .running
        running.builds[4].finishedAt = nil
        let reloaded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(running))
        precondition(reloaded.builds.count == 5 && reloaded.builds[4].state == .ended && reloaded.builds[4].finishedAt == nil)
        precondition(reloaded.builds[0] == message.builds[0])
    }

    static func testBuildCardDocuments() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let command = BuildCommand(title: "xcodebuild test · Hermes", verb: "Testing", directory: "/w/CantripIOS", key: "k")
        var run = BuildRun(id: "call-1", command: command, startedAt: start, estimate: .init(seconds: 185, runs: 4))
        var document = run.document
        precondition(document.type == "build" && document.blocks.map(\.type) == ["header", "progress"])
        precondition(document.blocks[0].title == "xcodebuild test · Hermes" && document.blocks[0].subtitle == "CantripIOS"
                     && document.blocks[0].symbol == "hammer")
        precondition(document.blocks[1].expectedSeconds == 185 && document.blocks[1].label == "Testing"
                     && document.blocks[1].detail == "Usually 3m 05s (4 earlier runs)")
        precondition(document.fallbackText?.contains("Testing · since") == true)
        let decoded = try CardDocument.decoder.decode(CardDocument.self,
                                                      from: JSONSerialization.data(withJSONObject: document.snapshot))
        precondition(decoded == document, "build cards round-trip")
        // The Mac's block: elapsed time ticks from startedAt; the bar follows the estimate.
        var view = CardProgress(block: document.blocks[1], now: start.addingTimeInterval(65))
        precondition(view.isRunning && view.elapsed == "1:05" && view.remaining == "About 2:00 left"
                     && abs((view.fraction ?? 0) - 65.0 / 185) < 0.001)
        view = CardProgress(block: document.blocks[1], now: start.addingTimeInterval(200))
        precondition(view.fraction == nil && view.remaining == "Longer than usual", "past the estimate the bar is indeterminate")
        precondition(CardProgress.clock(3_729) == "1:02:09")
        run.finish(.succeeded, exitCode: 0, at: start.addingTimeInterval(190))
        document = run.document
        precondition(document.blocks[1].expectedSeconds == nil && document.blocks[0].symbol == "checkmark.circle.fill")
        view = CardProgress(block: document.blocks[1], now: start.addingTimeInterval(9_999))
        precondition(!view.isRunning && view.elapsed == "3:10" && view.fraction == 1 && view.label == "Succeeded")
        precondition(document.fallbackText?.contains("Succeeded · in 3m 10s") == true)
        var ended = BuildRun(id: "call-2", command: command, startedAt: start, estimate: nil)
        ended.finish(.ended, at: start.addingTimeInterval(30))
        view = CardProgress(block: ended.document.blocks[1], now: start.addingTimeInterval(60))
        precondition(view.elapsed == nil && !view.showsBar, "an unknown end shows no made-up duration")
        // Model and tool cards can't claim progress: only Cantrip's own build cards have it.
        var tool = CardDocument(id: "t", type: "custom", blocks: [document.blocks[1]])
        tool.blocks.append(document.blocks[0])
        precondition(CardValidation.sanitized(tool, allowMaps: false)?.blocks.map(\.type) == ["header"])
        precondition(CardPanelView.sections(document.blocks).count == 2)
    }

    /// PNGs of the Mac's build cards for review when CANTRIP_SNAPSHOT_DIR is set.
    @MainActor
    static func writeBuildCardSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        let now = Date()
        func card(_ title: String, _ verb: String, started: TimeInterval, estimate: Double?, runs: Int?,
                  step: BuildStep? = nil, end: (BuildRun.State, TimeInterval, Int?)? = nil) -> CardDocument {
            var run = BuildRun(id: title, command: BuildCommand(title: title, verb: verb, directory: "/w/Cantrip", key: title),
                               startedAt: now.addingTimeInterval(-started),
                               estimate: estimate.map { .init(seconds: $0, runs: runs ?? 1) })
            run.step = step
            if let end { run.finish(end.0, exitCode: end.2, at: run.startedAt.addingTimeInterval(end.1)) }
            return run.document
        }
        let cards = [
            card("swift build", "Building", started: 42, estimate: nil, runs: nil),
            card("xcodebuild test · Hermes", "Testing", started: 83, estimate: 185, runs: 4),
            card("swift build (release)", "Building", started: 51, estimate: 140, runs: 2, step: BuildStep(current: 212, total: 640)),
            card("make app", "Building", started: 300, estimate: 190, runs: 3, end: (.succeeded, 192, 0)),
            card("xcodebuild archive · Hermes", "Archiving", started: 60, estimate: nil, runs: nil, end: (.failed, 47, 65)),
        ]
        // The host's JSON for the Windows clients' fixtures (tests/…/cards/build*.json).
        for (name, card) in [("build", cards[2]), ("build-failed", cards[4])] {
            let data = try JSONSerialization.data(withJSONObject: card.snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
        }
        let content = CardDocumentStack(cards: cards, links: [])
            .padding(16)
            .frame(width: 560)
            .background(Color(white: 0.08))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mac-build-cards.png"))
    }
}
