import SwiftUI

/// Runs `StorageUpkeep` in the host about once a day: 10 minutes after launch, then whenever a
/// day has passed since the last cleanup (including one run with `cantrip cleanup`), and on
/// request from Settings. Work happens off the main thread, one cleanup at a time. The simulator
/// pool's own upkeep (`SimulatorPool.tidy`) runs every few minutes, whether or not the daily
/// cleanup is on: idle simulators shut down and members the pool no longer keeps go once free.
@MainActor
final class StorageUpkeepStatus: ObservableObject {
    static let shared = StorageUpkeepStatus()
    static let interval: TimeInterval = 24 * 60 * 60
    static let firstCheckDelay: TimeInterval = 10 * 60
    static let checkInterval: TimeInterval = 60 * 60
    static let simulatorFirstCheckDelay: TimeInterval = 60
    static let simulatorCheckInterval: TimeInterval = 5 * 60

    @Published private(set) var lastReport: StorageUpkeep.Report?
    @Published private(set) var isRunning = false
    private var timer: Timer?
    private var simulatorTimer: Timer?
    private var tidyingSimulators = false
    private var lastSimulatorErrors: [String] = []
    private let stateDirectory = StorageUpkeep.Configuration.standard().stateDirectory

    private init() {
        lastReport = StorageUpkeep.lastReport(in: stateDirectory)
    }

    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            self?.runIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
        simulatorTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.simulatorFirstCheckDelay) { [weak self] in
            self?.tidySimulators()
        }
        simulatorTimer = Timer.scheduledTimer(withTimeInterval: Self.simulatorCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tidySimulators() }
        }
    }

    /// `SimulatorPool.tidy`, logging what it did to the host log and the cleanup's removal log.
    func tidySimulators() {
        guard !tidyingSimulators else { return }
        tidyingSimulators = true
        let logFile = stateDirectory.appendingPathComponent("storage-upkeep.log")
        DispatchQueue.global(qos: .utility).async {
            let report = SimulatorPool.tidy { line in
                Log.write("simulators: \(line)")
                StorageUpkeep.appendLog(line, to: logFile)
            }
            if let report, report.removedCount > 0 {
                let count = report.removedCount == 1 ? "1 simulator" : "\(report.removedCount) simulators"
                Log.write("simulators: the pool's upkeep freed \(StorageUpkeep.format(report.bytesRemoved)) (\(count))")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tidyingSimulators = false
                    let errors = report?.errors ?? []
                    // The same failure every few minutes is logged once.
                    if errors != self.lastSimulatorErrors { errors.forEach { Log.write("simulators: \($0)") } }
                    self.lastSimulatorErrors = errors
                }
            }
        }
    }

    func runIfDue(now: Date = Date()) {
        guard AppSettings.shared.storageUpkeepEnabled, !isRunning else { return }
        lastReport = StorageUpkeep.lastReport(in: stateDirectory) ?? lastReport
        // A few minutes' slack so an hourly check doesn't push the daily run an hour later each day.
        if let last = lastReport?.finishedAt, now.timeIntervalSince(last) < Self.interval - 10 * 60 { return }
        runNow()
    }

    func runNow() {
        guard !isRunning else { return }
        isRunning = true
        let configuration = StorageUpkeep.Configuration.standard()
        DispatchQueue.global(qos: .utility).async {
            let report = StorageUpkeep.perform(configuration, dryRun: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRunning = false
                    guard let report else {
                        Log.write("storage-upkeep: skipped, another cleanup is running")
                        return
                    }
                    self.lastReport = report
                    Log.write("storage-upkeep: \(report.summary) Kept \(report.keptSummary.joined(separator: "; ")). "
                        + report.worktreesKept.map { "Kept worktree \($0.path): \($0.reason ?? "")." }.joined(separator: " ")
                        + " Took \(Int(report.finishedAt.timeIntervalSince(report.startedAt))) s; "
                        + "details in \(StorageUpkeep.Configuration.standard().stateDirectory.path)/storage-upkeep.log")
                }
            }
        }
    }

    var statusText: String {
        if isRunning { return "Cleaning up…" }
        guard let report = lastReport else {
            return AppSettings.shared.storageUpkeepEnabled
                ? "The first cleanup runs 10 minutes after Cantrip starts."
                : "Not run yet."
        }
        let when = report.finishedAt.formatted(.relative(presentation: .named))
        var text = "Last cleanup \(when): \(report.summary)"
        if let free = report.freeBytesAfter { text += " \(StorageUpkeep.format(free)) free." }
        return text
    }
}

/// Settings: the daily cleanup switch, how long unused sessions stay, and the last result.
struct StorageUpkeepView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var status = StorageUpkeepStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $settings.storageUpkeepEnabled) {
                Text("Clean up unused agent sessions and worktrees daily").fixedSize(horizontal: false, vertical: true)
            }
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Removes Copilot session folders nothing has used for the set number of days, and agent git "
                    + "worktrees (in session folders, ~/.cache/Cantrip or temporary folders) that are clean, unchanged "
                    + "for 3 days and whose commits are on a branch. Sessions of open or closed tabs, ones named in "
                    + "memory notes, ones in use and anything with uncommitted or unpushed work stay. Also removes "
                    + "build output the next build makes again (DerivedData and SwiftPM checkouts nothing used for "
                    + "days, git-ignored ones only in your checkouts) and trims package caches over their caps.")
            if settings.storageUpkeepEnabled {
                Stepper(value: $settings.storageSessionRetentionDays, in: StorageUpkeep.sessionRetentionDays) {
                    Text("Keep unused sessions for \(settings.storageSessionRetentionDays) days")
                        .font(.caption)
                }
                Toggle("Also remove simulators unused for \(SimulatorPool.SweepOptions().unusedDays) days",
                       isOn: $settings.storageSimulatorCleanup)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("Simulators that tabs lease with `cantrip sim acquire` are always tidied: free ones are shut "
                        + "down and temporary copies deleted. This also deletes other named simulators nobody used for "
                        + "\(SimulatorPool.SweepOptions().unusedDays) days, empties Xcode's default ones and removes ones "
                        + "whose iOS runtime is gone. Booted simulators and ones a build or test is using stay.")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(status.isRunning ? "Cleaning Up…" : "Clean Up Now") { status.runNow() }
                    .font(.caption)
                    .disabled(status.isRunning)
            }
        }
    }
}
