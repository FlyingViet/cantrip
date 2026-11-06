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
        try testCombinedBuildCard()
        try await testTransferCardsThroughSession()
        testTransferCardDocuments()
        try writeBuildCardSnapshots()
        print("Build cards: detection, results, background shells, history estimates, session flow, transfers and client cards passed")
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
            // Interpreters and `cantrip env run` run the script that names the work.
            ("Cantrip env run --dir ~/Coding/nxnative -- python -u -B ~/.cache/Cantrip/nxnative/build-fefw.py 1", "build-fefw.py"),
            ("Cantrip env run --dir ~/Coding/nxnative -- bash ~/.cache/Cantrip/nxnative/build-mkw.sh", "build-mkw.sh"),
            ("node scripts/build.js --prod", "build.js"),
            ("python3 -c 'print(1)'", nil),
            ("python3 manage.py runserver", nil),
            // Transfers: copies, downloads, uploads and device installs.
            ("cd /Volumes/MacBuilds/projects/nxnative && usb-transfer-venv/bin/python -u -B ~/.cache/Cantrip/nxnative/push-fefw-usb.py 2>&1 | tee fefw-afc.log",
             "push-fefw-usb.py"),
            ("rsync -avP --info=progress2 --exclude .git build/ nas:/Volumes/Share/projects/", "rsync · projects"),
            ("rsync -a nas:/Volumes/Media/Roms/game.zip .", "rsync"),
            ("rsync -avn src/ dst/", nil),
            ("scp -P 2222 App.ipa user@host:/tmp/", "scp · tmp"),
            ("xcrun devicectl device copy to --device 0000-1 --source RomFS.img --destination Documents/romfs.img --domain-type appDataContainer --domain-identifier com.x.y",
             "devicectl copy to · romfs.img"),
            ("xcrun devicectl device install app --device 0000-1 build/Game.app", "devicectl install · Game.app"),
            ("xcrun devicectl device info files --device 0000-1", nil),
            ("python3 -m pymobiledevice3 afc push RomFS.img /Documents/romfs.img", "pymobiledevice3 afc push · romfs.img"),
            ("adb -s emulator-5554 push big.bin /sdcard/Download/", "adb push · Download"),
            ("curl -L -o ~/Downloads/Xcode_27.2.xip https://download.developer.apple.com/Developer_Tools/Xcode_27.2/Xcode_27.2.xip",
             "curl · Xcode_27.2.xip"),
            ("curl -fsSLO https://example.com/models/gemma.gguf", "curl · gemma.gguf"),
            ("curl -sS -o /tmp/r.json https://api.example.com/data", nil),
            ("curl -s https://api.github.com/repos/x/y | jq .", nil),
            ("wget -c https://example.com/file", "wget · file"),
            ("wget https://example.com/index.html", nil),
            ("rclone copy ./photos gdrive:backup --transfers 8 --progress", "rclone copy · backup"),
            ("aws s3 cp build.zip s3://bucket/releases/ --profile ci", "aws s3 cp · releases"),
            ("ollama pull llama3:8b", "ollama pull · llama3:8b"),
            ("hf download mlx-community/gemma-3-4b --local-dir models", "hf download · gemma-3-4b"),
            ("./scripts/upload-ipa.sh", "upload-ipa.sh"),
            ("git push origin main", nil),
            ("cp a.txt b.txt", nil),
        ]
        for (command, expected) in cases {
            precondition(title(command) == expected, "\(command) -> \(title(command) ?? "nil"), expected \(expected ?? "nil")")
        }
        func verb(_ command: String) -> String? {
            BuildDetector.detect(command, workdir: work).flatMap { $0.isTransfer ? $0.verb : nil }
        }
        precondition(verb("usb-transfer-venv/bin/python -u push-fefw-usb.py") == "Transferring"
                     && verb("rsync -a out/ nas:/x/") == "Uploading" && verb("rsync -a nas:/x/a.zip .") == "Downloading"
                     && verb("rsync -a a/ b/") == "Copying" && verb("curl -LO https://x.dev/a.zip") == "Downloading"
                     && verb("xcrun devicectl device install app --device 1 A.app") == "Installing"
                     && verb("rclone sync a remote:b") == "Syncing" && verb("aws s3 cp s3://b/a.zip .") == "Downloading")
        precondition(BuildDetector.detect("python -u build-fefw.py 1", workdir: work)?.isTransfer == false
                     && BuildDetector.detect("cd /Volumes/X/nxnative && python push-x.py", workdir: work)?.project == "nxnative")
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

        // Clients get the reply's builds as one card, before the reply's own cards: the newest
        // leads, the four before it are rows with their results.
        let snapshot = RemoteHistory.message(message)
        let cards = snapshot["cards"] as? [[String: Any]] ?? []
        precondition(cards.count == 1 && cards[0]["type"] as? String == "build"
                     && cards[0]["id"] as? String == "build-" + message.builds[0].id, "\(cards.count)")
        let blocks = cards[0]["blocks"] as? [[String: Any]] ?? []
        precondition(blocks.map { $0["type"] as? String } == ["header", "progress", "list"])
        let progress = blocks[1]
        precondition(progress["status"] as? String == "stopped" && progress["startedAt"] is String
                     && progress["finishedAt"] is String)
        let rows = blocks[2]["items"] as? [[String: Any]] ?? []
        precondition(rows.map { $0["tone"] as? String } == ["positive", "negative", "negative", "positive"]
                     && rows[2]["note"] as? String == "Failed · Exit code 65", "\(rows)")

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

    /// A reply's builds share one card that changes in place: the newest running build leads,
    /// builds running beside it keep live progress, finished ones become rows.
    static func testCombinedBuildCard() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ id: String, _ title: String, _ verb: String, folder: String = "/w/CantripIOS", at offset: TimeInterval,
                 end: (BuildRun.State, TimeInterval, Int?)? = nil) -> BuildRun {
            var run = BuildRun(id: id, command: BuildCommand(title: title, verb: verb, directory: folder, key: title),
                               startedAt: start.addingTimeInterval(offset), estimate: nil)
            if let end { run.finish(end.0, exitCode: end.2, at: run.startedAt.addingTimeInterval(end.1)) }
            return run
        }
        precondition(BuildRun.card(for: []) == nil)
        let build = run("a", "xcodebuild build · Hermes", "Building", at: 0, end: (.succeeded, 141, 0))
        precondition(BuildRun.card(for: [build]) == build.document, "one build keeps its own card")

        // Build, a failed test, then the test again: one card, led by the running test.
        let failed = run("b", "xcodebuild test · Hermes", "Testing", at: 150, end: (.failed, 97, 65))
        let rerun = run("c", "xcodebuild test · Hermes", "Testing", at: 260)
        var card = try require(BuildRun.card(for: [build, failed, rerun]))
        precondition(card.id == "build-a" && card.type == "build", "the card keeps the first build's id as it grows")
        precondition(card.blocks.map(\.type) == ["header", "progress", "list"])
        precondition(card.blocks[0].title == "xcodebuild test · Hermes" && card.blocks[0].symbol == "hammer"
                     && card.blocks[1].status == "running" && card.blocks[1].label == "Testing")
        let list = card.blocks[2]
        precondition(list.title == "Earlier steps" && list.items?.count == 2)
        let rows = list.items ?? []
        precondition(rows[0].title == "xcodebuild build · Hermes" && rows[0].note == "Succeeded" && rows[0].tone == "positive"
                     && rows[0].trailing == "2:21" && rows[0].symbol == nil && rows[0].subtitle == nil,
                     "a row's result is its tinted note; clients tint row icons with the accent")
        precondition(rows[1].note == "Failed · Exit code 65" && rows[1].tone == "negative" && rows[1].trailing == "1:37"
                     && rows[1].accessibilityLabel == "xcodebuild test · Hermes, Failed · Exit code 65, took 1 minute, 37 seconds",
                     "\(rows[1])")
        precondition(card.accessibilityLabel == "xcodebuild test · Hermes, Testing, and 2 other steps")
        precondition(card.fallbackText?.hasSuffix("Earlier steps\n• xcodebuild build · Hermes — Succeeded — 2:21\n"
                                                  + "• xcodebuild test · Hermes — Failed · Exit code 65 — 1:37") == true
                     && card.fallbackText?.hasPrefix("xcodebuild test · Hermes — CantripIOS\nTesting · since ") == true,
                     card.fallbackText ?? "")
        let decoded = try CardDocument.decoder.decode(CardDocument.self, from: JSONSerialization.data(withJSONObject: card.snapshot))
        precondition(decoded == card, "combined build cards round-trip")

        // Once everything is done the newest build leads with its result; another folder is named.
        var finished = rerun
        finished.finish(.succeeded, exitCode: 0, at: rerun.startedAt.addingTimeInterval(118))
        let install = run("d", "make install", "Building", folder: "/w/CantripGatewayMac", at: 400, end: (.stopped, 20, nil))
        card = try require(BuildRun.card(for: [build, failed, finished, install]))
        precondition(card.blocks[0].title == "make install" && card.blocks[0].tone == "warning" && card.blocks[1].status == "stopped")
        precondition(card.blocks[2].items?.last?.subtitle == "CantripIOS", "a row from another folder than the lead's names it")

        // Builds running side by side keep live progress, labeled by command; the lead is the newest.
        let app = run("e", "make app", "Building", folder: "/w/Cantrip", at: 500)
        let gateway = run("f", "make build", "Building", folder: "/w/CantripGatewayMac", at: 510)
        card = try require(BuildRun.card(for: [build, app, gateway]))
        precondition(card.blocks.map(\.type) == ["header", "progress", "progress", "list"])
        precondition(card.blocks[0].title == "make build" && card.blocks[2].label == "make app"
                     && card.blocks[2].status == "running" && card.blocks[3].items?.map(\.id) == ["a"])
        precondition(CardPanelView.sections(card.blocks).count == 4)

        // A long reply lists only its latest five earlier steps, and says how many there were.
        let many = (0..<8).map { run("m\($0)", "swift test", "Testing", at: Double($0) * 60, end: (.succeeded, 30, 0)) }
        card = try require(BuildRun.card(for: many))
        precondition(card.blocks[2].title == "Earlier steps · latest 5 of 7"
                     && card.blocks[2].items?.map(\.id) == ["m2", "m3", "m4", "m5", "m6"], "\(card.blocks[2])")
        precondition(card.blocks.count <= 12, "clients draw at most 12 blocks")

        // A reply's own cards still follow its builds' one card.
        var reply = ChatMessage(role: .assistant, text: "Done")
        reply.builds = [build, failed, finished]
        precondition(reply.cardDocuments(linkPreviews: false).map(\.id) == ["build-a"])
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderValueNotFound) }
        return value
    }

    /// A transfer through a tab: the card follows the bytes the command prints, keeps going in a
    /// background shell a watcher reads, and says where it stopped when it fails.
    @MainActor
    static func testTransferCardsThroughSession() async throws {
        let settings = AppSettings.shared
        let saved = (settings.memoryEnabled, settings.backend)
        settings.memoryEnabled = false
        settings.backend = .copilot
        defer { (settings.memoryEnabled, settings.backend) = saved }

        let command = "cd /Volumes/MacBuilds/projects/nxnative && usb-transfer-venv/bin/python -u -B push-fefw-usb.py"
        func shell(_ state: ToolActivityState = .running, output: String? = nil, transfer: TransferProgress? = nil) -> ToolActivity {
            var activity = ToolActivityFactory.start(id: "tx-1", toolName: "bash", arguments: ["command": command])
            activity.state = state
            activity.output = output
            activity.transfer = transfer
            return activity
        }
        let backend = BuildBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Send Fire Emblem's game data to the Duo")
        try await waitForJournalTest { backend.requests.count == 1 }

        backend.sink?(.activity(shell()))
        try await waitForJournalTest { chat.messages.last?.builds.count == 1 }
        var run = chat.messages.last!.builds[0]
        precondition(run.isTransfer && run.verb == "Transferring" && run.title == "push-fefw-usb.py" && run.project == "nxnative")
        precondition(run.document.type == "transfer" && run.document.blocks[0].symbol == "arrow.up.circle"
                     && run.document.blocks[1].label == "Transferring" && run.document.blocks[1].fraction == nil)

        // Streamed output (Copilot, Codex) moves the bar.
        let total: Int64 = 29_051_813_685
        backend.sink?(.activity(shell(transfer: TransferProgress(fraction: 0.2, bytes: 5_810_362_737, totalBytes: total))))
        try await waitForJournalTest { chat.messages.last?.builds.first?.reading?.progress.percent == 20 }
        run = chat.messages.last!.builds[0]
        precondition(run.document.blocks[1].fraction == 0.2 && run.detail == "5.81 GB of 29.1 GB", run.detail)

        // It moves to a background shell; a watcher reading the shell keeps the card current, then finishes it.
        backend.sink?(.activity(shell(.succeeded, output: "<command with shellId: fefw is still running after 30 seconds. The command is still running.>")))
        try await waitForJournalTest { chat.messages.last?.builds.first?.shellID == "fefw" }
        var watcher = ToolActivityFactory.start(id: "watch-tx", toolName: "task", arguments: ["description": "watch-transfer"])
        var read = ToolActivityFactory.start(id: "rb-tx-1", toolName: "read_bash", arguments: ["shellId": "fefw", "delay": 600])
        read.state = .succeeded
        read.output = "Transferred 26004395264/29051813685 bytes (89.5%), 555s\nTransferred 27009220608/29051813685 bytes (93.0%), 560s\n"
        watcher.children = [read]
        backend.sink?(.activity(watcher))
        try await waitForJournalTest { chat.messages.last?.builds.first?.reading?.progress.percent == 92 }
        precondition(chat.messages.last!.builds[0].state == .running
                     && chat.messages.last!.builds[0].detail.hasPrefix("27.0 GB of 29.1 GB"), chat.messages.last!.builds[0].detail)
        var final = ToolActivityFactory.start(id: "rb-tx-2", toolName: "read_bash", arguments: ["shellId": "fefw"])
        final.state = .succeeded
        final.output = "Transferred 27109220608/29051813685 bytes (93.3%), 565s\npymobiledevice3.exceptions.ConnectionTerminatedError\n<shellId: fefw completed with exit code 1>"
        watcher.children = [read, final]
        backend.sink?(.activity(watcher))
        try await waitForJournalTest { chat.messages.last?.builds.first?.state == .failed }
        run = chat.messages.last!.builds[0]
        precondition(run.exitCode == 1 && run.detail == "Exit code 1 at 27.1 GB of 29.1 GB", run.detail)
        precondition(run.document.blocks[0].symbol == "xmark.circle.fill")

        // Clients get it as a card like a build's, and a reload keeps its readings.
        let cards = RemoteHistory.message(chat.messages.last!)["cards"] as? [[String: Any]] ?? []
        precondition(cards.first?["type"] as? String == "transfer")
        let reloaded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(chat.messages.last!))
        precondition(reloaded.builds == chat.messages.last!.builds)
    }

    /// The rate and time left come from the transfer's own readings; a build ignores them.
    static func testTransferCardDocuments() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let command = BuildCommand(title: "push-fefw-usb.py", verb: "Transferring", directory: "/w/nxnative", key: "t", isTransfer: true)
        var run = BuildRun(id: "t-1", command: command, startedAt: start, estimate: .init(seconds: 999, runs: 2))
        func reading(_ fraction: Double) -> TransferProgress {
            TransferProgress(fraction: fraction, bytes: Int64(fraction * 1_000_000_000), totalBytes: 1_000_000_000)
        }
        precondition(run.advance(step: nil, transfer: reading(0.5), at: start.addingTimeInterval(10)))
        var progress = run.document.blocks[1]
        precondition(progress.fraction == 0.5 && progress.expectedSeconds == nil && run.detail == "500 MB of 1.00 GB",
                     "one reading has no rate yet, and earlier runs don't guess for it: \(run.detail)")
        precondition(!run.advance(step: nil, transfer: reading(0.505), at: start.addingTimeInterval(12)), "under a percent: no redraw")
        precondition(run.advance(step: nil, transfer: reading(0.75), at: start.addingTimeInterval(20)))
        progress = run.document.blocks[1]
        precondition(run.bytesPerSecond == 25_000_000 && run.detail == "750 MB of 1.00 GB · 25.0 MB/s", run.detail)
        precondition(progress.expectedSeconds == 30, "20s in, a quarter left at 2.5% a second: \(String(describing: progress.expectedSeconds))")
        let view = CardProgress(block: progress, now: start.addingTimeInterval(25))
        precondition(view.fraction == 0.75 && view.remaining == "About 0:05 left" && view.elapsed == "0:25")
        // Going back (another file or a restart) measures the rate afresh.
        precondition(run.advance(step: nil, transfer: reading(0.1), at: start.addingTimeInterval(25)) && run.bytesPerSecond == nil)
        _ = run.advance(step: nil, transfer: reading(0.6), at: start.addingTimeInterval(35))
        var stopped = run
        stopped.finish(.stopped, at: start.addingTimeInterval(36))
        precondition(stopped.detail == "Stopped at 600 MB of 1.00 GB")
        run.finish(.succeeded, exitCode: 0, at: start.addingTimeInterval(80))
        precondition(run.detail == "1.00 GB · 50.0 MB/s" && run.document.blocks[1].expectedSeconds == nil, run.detail)
        // A percentage alone, and a download's symbol.
        var download = BuildRun(id: "t-2", command: BuildCommand(title: "wget · a.zip", verb: "Downloading", directory: "/w", key: "w",
                                                                isTransfer: true), startedAt: start, estimate: nil)
        _ = download.advance(step: nil, transfer: TransferProgress(fraction: 0.45), at: start.addingTimeInterval(5))
        precondition(download.detail == "45%" && download.document.blocks[0].symbol == "arrow.down.circle")
        // A build's output can hold percentages; only transfers follow them.
        var build = BuildRun(id: "b-1", command: BuildCommand(title: "make", verb: "Building", directory: "/w", key: "m"),
                             startedAt: start, estimate: nil)
        precondition(!build.advance(step: nil, transfer: reading(0.3), at: start) && build.reading == nil
                     && build.document.type == "build")
        precondition(BuildRun.bytesText(999) == "999 bytes" && BuildRun.bytesText(1_850_000_000) == "1.85 GB"
                     && BuildRun.bytesText(29_051_813_685) == "29.1 GB" && BuildRun.bytesText(555_000_000) == "555 MB")
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
        // Transfers: Fire Emblem's game data going to the Duo, a download and a copy that dropped.
        func transfer(_ title: String, _ verb: String, started: TimeInterval, total: Int64, readings: [(TimeInterval, Double)],
                      end: (BuildRun.State, TimeInterval, Int?)? = nil) -> CardDocument {
            var run = BuildRun(id: title, command: BuildCommand(title: title, verb: verb, directory: "/w/nxnative", key: title, isTransfer: true),
                               startedAt: now.addingTimeInterval(-started), estimate: nil)
            for (at, fraction) in readings {
                _ = run.advance(step: nil, transfer: TransferProgress(fraction: fraction, bytes: Int64(Double(total) * fraction), totalBytes: total),
                                at: run.startedAt.addingTimeInterval(at))
            }
            if let end { run.finish(end.0, exitCode: end.2, at: run.startedAt.addingTimeInterval(end.1)) }
            return run.document
        }
        let transfers = [
            transfer("push-fefw-usb.py", "Transferring", started: 600, total: 29_051_813_685, readings: [(20, 0.02), (590, 0.66)]),
            transfer("curl · Xcode_27.2.xip", "Downloading", started: 40, total: 2_045_843_072, readings: [(5, 0.05), (38, 0.6)]),
            transfer("rsync · Roms", "Copying", started: 300, total: 23_052_122_595, readings: [(10, 0.01), (180, 0.26)],
                     end: (.failed, 183, 12)),
        ]
        // A reply's builds as its one card: a build, a failed test, the test again, and a Gateway
        // build running beside it.
        func step(_ title: String, _ verb: String, folder: String = "/w/CantripIOS", started: TimeInterval, estimate: Double? = nil,
                  end: (BuildRun.State, TimeInterval, Int?)? = nil) -> BuildRun {
            var run = BuildRun(id: "call-\(Int(started))", command: BuildCommand(title: title, verb: verb, directory: folder, key: title),
                               startedAt: now.addingTimeInterval(-started), estimate: estimate.map { .init(seconds: $0, runs: 3) })
            if let end { run.finish(end.0, exitCode: end.2, at: run.startedAt.addingTimeInterval(end.1)) }
            return run
        }
        let combined = try require(BuildRun.card(for: [
            step("xcodebuild build · Hermes", "Building", started: 420, end: (.succeeded, 141, 0)),
            step("xcodebuild test · Hermes", "Testing", started: 270, estimate: 190, end: (.failed, 97, 65)),
            step("make build", "Building", folder: "/w/CantripGatewayMac", started: 150),
            step("xcodebuild test · Hermes", "Testing", started: 95, estimate: 190),
        ]))
        // The host's JSON for the Windows clients' fixtures (tests/…/cards/build*.json, transfer.json).
        for (name, card) in [("build", cards[2]), ("build-failed", cards[4]), ("transfer", transfers[0]), ("builds", combined)] {
            let data = try JSONSerialization.data(withJSONObject: card.snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
        }
        let content = CardDocumentStack(cards: [combined] + cards + transfers, links: [])
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
