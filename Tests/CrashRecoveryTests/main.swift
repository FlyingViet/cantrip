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

if failures == 0 {
    print("Crash recovery tests passed")
} else {
    exit(1)
}
