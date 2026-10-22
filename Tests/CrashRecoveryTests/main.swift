import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

let now: TimeInterval = 1_000
let historyDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("cantrip-recovery-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: historyDirectory) }

_ = CrashRecovery.recordCrash(at: 800, in: historyDirectory)
_ = CrashRecovery.recordCrash(at: 950, in: historyDirectory)
let thirdCount = CrashRecovery.recordCrash(at: 999, in: historyDirectory)
expect(thirdCount == 2, "crash markers outside the recovery window should be discarded")
let currentCount = CrashRecovery.recordCrash(at: now, in: historyDirectory)
expect(currentCount == 3, "concurrent-safe crash markers should count every recent crash")
expect(
    CrashRecovery.shouldAutomaticallyRelaunch(crashCount: currentCount),
    "the third crash should still relaunch"
)
let fourthCount = CrashRecovery.recordCrash(at: 1_001, in: historyDirectory)
expect(
    !CrashRecovery.shouldAutomaticallyRelaunch(crashCount: fourthCount),
    "the fourth crash in a minute should stop the relaunch loop"
)
expect(
    CrashRecovery.relaunchArguments(bundlePath: "/tmp/Current Cantrip.app")
        == ["-n", "/tmp/Current Cantrip.app"],
    "relaunch should target the exact bundle path"
)

// A run marker only counts while its own process runs: after a reboot its pid can belong to a
// process that started later, which must not keep a headless host from starting.
let markers = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-markers-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: markers) }
func writeMarker(pid: Int32, startedAt: Date) -> URL {
    let url = markers.appendingPathComponent("run-\(UUID().uuidString).json")
    let marker: [String: Any] = ["id": UUID().uuidString, "pid": Int(pid), "buildIdentity": "test",
                                 "startedAt": startedAt.timeIntervalSinceReferenceDate, "bundlePath": "/tmp/Test.app"]
    try! JSONSerialization.data(withJSONObject: marker).write(to: url)
    return url
}
let parent = getppid()
let stale = writeMarker(pid: parent, startedAt: Date(timeIntervalSince1970: 1_000))
expect(CrashRecovery.otherRunningHost(in: markers) == nil, "a marker older than its pid's process is stale")
expect(!FileManager.default.fileExists(atPath: stale.path), "stale markers are removed")
_ = writeMarker(pid: parent, startedAt: Date())
expect(CrashRecovery.otherRunningHost(in: markers) == parent, "a marker written after its process started is live")
_ = writeMarker(pid: getpid(), startedAt: Date())
expect(CrashRecovery.otherRunningHost(in: markers) == parent, "this process's own marker is never another host")

let report = CrashRecovery.Report(
    id: UUID(),
    detectedAt: Date(timeIntervalSince1970: now),
    crashedBuild: "abc123",
    bundlePath: "/tmp/Current Cantrip.app",
    automaticRelaunchAttempted: true
)
let roundTrip = try JSONDecoder().decode(
    CrashRecovery.Report.self,
    from: JSONEncoder().encode(report)
)
expect(roundTrip == report, "crash reports should survive persistence")

for failure in try pendingUpdateFailures() {
    expect(false, failure)
}
for failure in cantripVersionFailures() {
    expect(false, failure)
}

if failures == 0 {
    print("Crash recovery tests passed")
} else {
    exit(1)
}
