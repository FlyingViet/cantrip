import Foundation

// MachineJobs: reading ps/lsof/procargs, naming jobs, and which process groups count.
// Run: make test-machine-jobs

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        print("FAIL line \(line): \(message)")
        exit(1)
    }
}

let me: UInt32 = 501
let ps = """
  100     1   100 501 Ss   18:08:08   0.0   1024 /bin/bash --norc --noprofile -c ROOT=/Volumes/Builds/projects/atlas; caffeinate -i python3 -u -B build-atlas.py 1 > $ROOT/b.log 2>&1
  101   100   100 501 S    18:08:08   0.0   2048 /usr/bin/caffeinate -i python3 -u -B build-atlas.py 1
  102   101   100 501 U    17:59:58   0.1  16384 /opt/homebrew/bin/python3 /Users/x/.cache/Cantrip/worktrees/atlas-2/tools/compile_shaders.py /Volumes/a
  200     1   200 501 Ss      41:14 120.0 400000 /opt/homebrew/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot --headless
  300     1   300 501 Ss 1-02:00:00  90.0   9000 /System/Library/PrivateFrameworks/X.framework/mediaanalysisd
  400   200   400 501 Ss      17:00   0.2   1000 /bin/bash --norc --noprofile -c for i in $(seq 1 1080); do curl -s http://x; sleep 60; done
  401   400   400 501 S       00:20   0.0    500 sleep 60
  500   200   500 501 Ss      02:00   0.5   1000 /bin/bash --norc --noprofile -c cd ~/Coding/Notes && xcodebuild -scheme Notes -destination generic archive
  501   500   500 501 S       01:59  95.0 300000 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme Notes archive
  600   200   600 501 Ss      00:40   0.1   1000 /bin/bash --norc --noprofile -c node capture.js /tmp
  601   600   600 501 S       00:40 150.0 200000 node capture.js /tmp
  700   200   700 501 Ss   01:00:00   0.0   1000 /bin/bash --norc --noprofile -c caffeinate -i python3 export.py
  701   700   700 501 T    01:00:00   0.0   9000 python3 export.py
  800   200   800 501 Ss      05:00   0.0   1000 /bin/bash --norc --noprofile -c make app
  801   800   800 501 S       04:59   0.0   1000 /Applications/Cantrip.app/Contents/MacOS/Cantrip build-queue run --tool swift -- swift build
  900     1   900 501 Ss   02:00:00  40.0   1000 /opt/homebrew/bin/model-server --port 9000
  950     1   950 501 Ss      10:00  20.0   1000 /bin/bash /Users/x/.local/backup/run.sh
  951   950   950 501 S       09:00  20.0   1000 /opt/homebrew/bin/restic backup /Users/x
  960     1   960 501 Ss   03:00:00   5.0  90000 /Applications/Safari.app/Contents/MacOS/Safari
  990     1   990   0 Ss      10:00 300.0   1000 /usr/local/bin/something-root
  999     1   999 501 Ss      10:00 300.0   1000 /Applications/Cantrip.app/Contents/MacOS/Cantrip
 1000   200  1000 501 Ss      10:00   0.0   1000 /bin/bash --norc --noprofile -c cd ~/Coding/atlas && caffeinate -i python3 -u prepare-atlas.py > a.log 2>&1; rc=$?; if [ $rc = 0 ]; then caffeinate -i python3 -u publish-atlas.py > p.log 2>&1; fi; echo done=$rc
 1001  1000  1000 501 S       02:00   0.0   1000 caffeinate -i python3 -u publish-atlas.py
 1002  1001  1000 501 S       02:00  30.0  50000 /opt/homebrew/bin/python3 -u publish-atlas.py
"""

// Parsing
let rows = MachineJobs.parse(ps: ps)
check(rows.count == 24, "parsed \(rows.count) rows")
check(rows[102]?.state == "U" && rows[102]?.age == 64_798 && rows[102]?.memory == 16_777_216, "row 102")
check(rows[300]?.age == 93_600, "day-long elapsed")
check(MachineJobs.elapsed("00:20") == 20 && MachineJobs.elapsed("1-02:03:04") == 93_784 && MachineJobs.elapsed("x") == nil, "elapsed")

// Naming
check(MachineJobs.summary("bash -c cd x && make app -j8") == "make app", "make")
check(MachineJobs.summary("/usr/bin/swift build -c release") == "swift build", "swift build")
check(MachineJobs.summary("/usr/bin/xcodebuild -scheme Notes -destination generic archive") == "xcodebuild archive · Notes", "xcodebuild")
check(MachineJobs.summary("/usr/bin/rsync -a /x /y") == "rsync", "rsync")
check(MachineJobs.summary("bash -c ROOT=/a\\012python3 -u render-frames.py 3") == "render-frames.py", "script")
check(MachineJobs.project(in: ["cd /Users/x/Coding/Notes && make"]) == "Notes", "project")
check(MachineJobs.project(in: ["echo hi"]) == nil, "no project")

// Logs: progress redraws with \r, colors, secrets
let log = "start\n[5/6] shaders \u{1B}[32m98%\u{1B}[0m\r[5/6] shaders 99%, 1,424/1,426\r\n\n".data(using: .utf8)!
check(MachineJobs.lastLine(of: log) == "[5/6] shaders 99%, 1,424/1,426", "last line: \(MachineJobs.lastLine(of: log) ?? "nil")")
check(MachineJobs.masked("uploading with token=abc123 to x") == "uploading with token=••• to x", "token masked")
check(MachineJobs.masked("key " + String(repeating: "a", count: 44)).contains("•••"), "long secret masked")
let lsof = "p100\nf1\ntREG\naw\nn/Volumes/Builds/b.log\nf3\ntREG\nar\nn/x/input.bin\np102\nf4\ntREG\nau\nn/x/compile.log\nf5\ntREG\naw\nn/x/data.bin\nf2\ntCHR\naw\nn/dev/null\n"
check(MachineJobs.parse(lsof: lsof) == [100: ["/Volumes/Builds/b.log"], 102: ["/x/compile.log"]], "lsof: \(MachineJobs.parse(lsof: lsof))")

// The tab variable from KERN_PROCARGS2
var procargs = withUnsafeBytes(of: Int32(2)) { Array($0) }
procargs += Array("/bin/bash".utf8) + [0, 0, 0] + Array("bash".utf8) + [0] + Array("-c".utf8) + [0]
procargs += Array("HOME=/Users/x".utf8) + [0] + Array("CANTRIP_TAB_ID=ABC".utf8) + [0, 0]
check(MachineJobs.environmentValue("CANTRIP_TAB_ID", procargs: procargs) == "ABC", "procargs tab")
check(MachineJobs.environmentValue("PATH", procargs: procargs) == nil, "procargs missing")
var tricky = withUnsafeBytes(of: Int32(2)) { Array($0) }
tricky += Array("/bin/echo".utf8) + [0] + Array("echo".utf8) + [0] + Array("CANTRIP_TAB_ID=fake".utf8) + [0, 0]
check(MachineJobs.environmentValue("CANTRIP_TAB_ID", procargs: tricky) == nil, "an argument isn't the environment")
check(MachineJobs.environmentValue("HOME", pid: getpid()) == Foundation.ProcessInfo.processInfo.environment["HOME"], "live procargs")

// Steps a log announces
func marker(_ line: String) -> String? {
    MachineJobs.stepMarker(in: line).map { "\($0.index)/\($0.total) \($0.name)" }
}
check(marker("[20:01:32] [1/4] pack v6 …") == "1/4 pack v6", "timestamped: \(marker("[20:01:32] [1/4] pack v6 …") ?? "nil")")
check(marker("[5/6] Shaders · compiling: 99%, 1,424/1,426") == "5/6 Shaders", "named before the dot")
check(marker("2026-11-07T10:00:00Z Step 2 of 4: Upload 45%") == "2/4 Upload", "Step n of m")
check(marker("==> [3/3] notarize") == "3/3 notarize", "arrow prefix")
check(marker("[12/345] Compiling Foo.swift") == nil, "a compile counter isn't steps")
check(marker("copied 3/6 files") == nil && marker("[7/6] x") == nil, "not markers")
check(MachineJobs.percent(in: "compiling: 98.5% of 1/2") == 0.985 && MachineJobs.percent(in: "no percent") == nil, "percent")
var steps = MachineJobs.LogSteps()
steps.read("hello\n[1/4] pack …\n")
check(steps.pipeline == .init(steps: ["pack", "", "", ""], current: 1), "first step: \(String(describing: steps.pipeline))")
steps.read("[2/5] check\n[3/6] rewrite\n[5/6] Shaders · \u{1B}[32mcompiling: 42%\u{1B}[0m\r[5/6] Shaders · compiling: 4")
steps.read("3%")
check(steps.pipeline == .init(steps: ["pack", "check", "rewrite", "", "Shaders", ""], current: 5, fraction: 0.43),
      "totals grow, the line being written counts: \(String(describing: steps.pipeline))")
check(steps.pipeline?.label == "Step 5 of 6 · Shaders · 43%", "label")
steps.read("\nuploading 61%\n")
check(steps.pipeline?.fraction == 0.61, "a percentage on another line moves the step")
steps.read("[1/6] pack\n")
check(steps.pipeline == .init(steps: ["pack", "", "", "", "", ""], current: 1), "a new run starts over")
let stepLog = FileManager.default.temporaryDirectory.appendingPathComponent("steps-\(UUID().uuidString).log")
defer { try? FileManager.default.removeItem(at: stepLog) }
try! "[1/3] fetch\n[2/3] conv".write(to: stepLog, atomically: true, encoding: .utf8)
var fileSteps = MachineJobs.LogSteps()
MachineJobs.readSteps(&fileSteps, path: stepLog.path)
check(fileSteps.pipeline == .init(steps: ["fetch", "conv", ""], current: 2), "file: \(String(describing: fileSteps.pipeline))")
let appender = try! FileHandle(forWritingTo: stepLog)
appender.seekToEndOfFile()
appender.write("ert\n".data(using: .utf8)!)
try! appender.close()
MachineJobs.readSteps(&fileSteps, path: stepLog.path)
check(fileSteps.pipeline?.steps == ["fetch", "convert", ""], "only what was appended, finishing the line")
try! "[1/2] a\n".write(to: stepLog, atomically: true, encoding: .utf8)
MachineJobs.readSteps(&fileSteps, path: stepLog.path)
check(fileSteps.pipeline == .init(steps: ["a", ""], current: 1), "a shorter file was replaced")
var tailSteps = MachineJobs.LogSteps()
try! (String(repeating: "noise\n", count: 100) + "[2/2] last\n").write(to: stepLog, atomically: true, encoding: .utf8)
MachineJobs.readSteps(&tailSteps, path: stepLog.path, limit: 64)
check(tailSteps.pipeline?.current == 2, "a huge log is read from its end")

// Commands a shell chains
let chain = "/bin/bash --norc --noprofile -c ROOT=/Volumes/B; mv $ROOT/a.log $ROOT/old.log; cd ~/x && caffeinate -i Cantrip env run "
    + "--dir ~/Coding/atlas -- python -u -B prepare-atlas.py 1 > $ROOT/a.log 2>&1; rc=$?; echo $rc > $ROOT/a.exit; "
    + "if [ $rc = 0 ]; then caffeinate -i python3 publish-atlas.py > $ROOT/p.log 2>&1; else echo failed; fi; echo done=$(cat $ROOT/a.exit)"
check(MachineJobs.stages(of: chain) == ["prepare-atlas.py", "publish-atlas.py"], "chain: \(MachineJobs.stages(of: chain))")
check(MachineJobs.stages(of: "/bin/zsh -lc make app && xcrun notarytool submit x.zip | tee n.log\\012ditto a b") == ["make app", "notarytool", "ditto"],
      "newlines, pipes: \(MachineJobs.stages(of: "/bin/zsh -lc make app && xcrun notarytool submit x.zip | tee n.log\\012ditto a b"))")
check(MachineJobs.stages(of: "/bin/bash -c cd x && make app") == [], "one command isn't a chain")
check(MachineJobs.stages(of: "python3 a.py && b.py") == [], "not a shell")
check(MachineJobs.stages(of: "/bin/bash -c out=$(python3 probe.py); python3 a.py; python3 b.py") == ["a.py", "b.py"], "captures skipped")

// Which groups count
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-jobs-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let logFile = folder.appendingPathComponent("b.log")
try! log.write(to: logFile)
let tab = UUID().uuidString
var looks = 0
let scanner = MachineJobs.Scanner(uid: me, ownGroup: -1, cores: 10, listProcesses: { looks += 1; return ps },
                                  findLogs: { $0.contains(100) ? [100: [logFile.path]] : [:] },
                                  tabID: { $0 == 100 || $0 == 500 ? tab : nil })
func byGroup(_ jobs: [MachineJobs.Job]) -> [Int32: MachineJobs.Job] { Dictionary(uniqueKeysWithValues: jobs.map { ($0.group, $0) }) }
var jobs = byGroup(scanner.scan(queued: [801], now: 1_800_000_000))
check(Set(jobs.keys) == [100, 500, 700, 800, 950, 1000], "groups: \(jobs.keys.sorted())")
let atlas = jobs[100]!
check(atlas.title == "build-atlas.py" && atlas.project == "atlas" && atlas.state == .waitingOnDisk
      && atlas.step == "compile_shaders.py" && atlas.tabID == tab && atlas.processes == 3, "caffeinated job: \(atlas)")
check(atlas.logFile == "b.log" && atlas.logLine == "[5/6] shaders 99%, 1,424/1,426", "its log")
check(atlas.pipeline == .init(steps: ["", "", "", "", "shaders", ""], current: 5, fraction: 0.99),
      "its log's steps: \(String(describing: atlas.pipeline))")
check(jobs[1000]?.pipeline == .init(steps: ["prepare-atlas.py", "publish-atlas.py"], current: 2),
      "a chain on its second command: \(String(describing: jobs[1000]?.pipeline))")
check(jobs[500]?.pipeline == nil, "one command, no steps in its log: no pipeline")
check(jobs[500]?.title == "xcodebuild archive · Notes" && jobs[500]?.state == .running && jobs[500]?.cpu == 9.6, "xcodebuild")
check(jobs[700]?.state == .paused, "stopped = paused")
check(jobs[800]?.processIDs.contains(801) == true, "a queued build's group")
check(jobs[950]?.title == "restic", "a launchd job running a backup tool")
// A busy group counts on its second look (but never a launchd service); then it stays until it exits.
jobs = byGroup(scanner.scan(queued: [], now: 1_800_000_003))  // ps ages unchanged: a 3 s wobble
check(jobs[600]?.title == "capture.js" && jobs[600]?.cpu == 15, "hot group on the second look")
check(jobs[900] == nil, "a busy service isn't a job")
check(jobs[800] != nil && jobs[800]?.since == 1_800_000_000 - 300, "once listed, stays listed, same start")
check(byGroup(scanner.scan(queued: [], now: 1_800_000_060))[800] == nil, "a different start is a new group")
check(looks == 3, "one ps per look")

// A chain between commands stays on the furthest one it reached.
let chainLeader = " 2000   200  2000 501 Ss      10:00   0.0   1000 /bin/bash -c caffeinate -i python3 a.py; sleep 1; python3 b.py; python3 c.py\n"
var chainPS = chainLeader + " 2001  2000  2000 501 S       01:00  50.0   1000 python3 a.py\n"
let chainScanner = MachineJobs.Scanner(uid: me, ownGroup: -1, cores: 10, listProcesses: { chainPS }, findLogs: { _ in [:] }, tabID: { _ in nil })
check(chainScanner.scan(now: 1_800_000_000).first?.pipeline?.current == 1, "first command")
chainPS = chainLeader + " 2003  2000  2000 501 S       00:01   0.0   1000 python3 b.py\n"
check(chainScanner.scan(now: 1_800_000_002).first?.pipeline?.current == 2, "second command")
chainPS = chainLeader + " 2004  2000  2000 501 S       00:01   0.0   1000 sleep 1\n"
check(chainScanner.scan(now: 1_800_000_004).first?.pipeline?.current == 2, "between commands it stays put")

print("MachineJobs tests passed")
