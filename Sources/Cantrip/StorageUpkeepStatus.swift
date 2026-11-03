import SwiftUI

/// Runs `StorageUpkeep` in the host about once a day: 10 minutes after launch, then whenever a
/// day has passed since the last cleanup (including one run with `cantrip cleanup`), on request
/// from Settings, and when free space falls under 20 GB (checked every 5 minutes; at most hourly
/// while it stays low). If a low-space cleanup leaves under 15 GB, one alert names what's largest;
/// the next goes only after space has recovered. Work happens off the main thread, one cleanup at a time. The simulator
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
    static let freeSpaceCheckInterval: TimeInterval = 5 * 60
    private static let lowDiskKey = "storageLowDiskGuard"

    @Published private(set) var lastReport: StorageUpkeep.Report?
    @Published private(set) var isRunning = false
    private var timer: Timer?
    private var simulatorTimer: Timer?
    private var freeSpaceTimer: Timer?
    /// Paired devices get the low-space alert through it.
    weak var remote: RemoteControlServer?
    var postsMacNotifications = false
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
        freeSpaceTimer?.invalidate()
        freeSpaceTimer = Timer.scheduledTimer(withTimeInterval: Self.freeSpaceCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFreeSpace() }
        }
    }

    /// Cleans up now when free space is low (`StorageUpkeep.LowDiskGuard`), and alerts once if the
    /// cleanup couldn't free enough.
    func checkFreeSpace() {
        guard AppSettings.shared.storageUpkeepEnabled, !isRunning else { return }
        var state = Self.loadGuard()
        let configuration = StorageUpkeep.Configuration.standard()
        guard let free = StorageUpkeep.freeBytes(configuration.sessionRoot) else { return }
        // Decided here (cheap), so the work below only starts when a cleanup is due.
        var probe = state
        guard probe.shouldRun(free: free, now: configuration.now) else {
            if probe != state { Self.saveGuard(probe) }
            return
        }
        isRunning = true
        let logFile = stateDirectory.appendingPathComponent("storage-upkeep.log")
        DispatchQueue.global(qos: .utility).async {
            var alert: (String, String)?
            let report = StorageUpkeep.lowDiskRun(configuration, guard: &state, free: {
                StorageUpkeep.freeBytes(configuration.sessionRoot)
            }, alert: { alert = ($0, $1) }, log: { line in
                if line.hasPrefix("free space") || line.hasPrefix("low disk") { StorageUpkeep.appendLog(line, to: logFile) }
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRunning = false
                    Self.saveGuard(state)
                    if let report {
                        self.lastReport = report
                        Log.write("storage-upkeep: low disk (\(StorageUpkeep.format(free)) free): \(report.summary)")
                    }
                    if let alert { self.sendAlert(title: alert.0, body: alert.1) }
                }
            }
        }
    }

    private func sendAlert(title: String, body: String) {
        Log.write("storage-upkeep: alert: \(title). \(body)")
        remote?.notifyNotice(title: title, body: body, kind: "storageLow")
        guard postsMacNotifications else { return }
        MacNotices.post(MacNotice(id: UUID().uuidString, title: title, body: body))
    }

    private static func loadGuard() -> StorageUpkeep.LowDiskGuard {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return UserDefaults.standard.data(forKey: lowDiskKey)
            .flatMap { try? decoder.decode(StorageUpkeep.LowDiskGuard.self, from: $0) } ?? StorageUpkeep.LowDiskGuard()
    }

    private static func saveGuard(_ state: StorageUpkeep.LowDiskGuard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) { UserDefaults.standard.set(data, forKey: lowDiskKey) }
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
        var text = "Last cleanup \(when)\(report.lowDisk == true ? " (space was low)" : ""): \(report.summary)"
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
                    + "worktrees (in session folders, ~/.cache/Cantrip or temporary folders) that are clean and either "
                    + "pushed and unchanged for a day, or unchanged for 3 days with their commits on a branch, "
                    + "submodules included. Worktrees that stay lose their git-ignored build output (DerivedData, "
                    + ".build, build, node_modules, dist) after 12 idle hours; agents' own DerivedData folders go "
                    + "after 6. Open tabs' and child tabs' worktrees, locked ones, ones in use, sessions of tabs or "
                    + "named in memory notes, and anything uncommitted or unpushed stay. Also trims package caches "
                    + "over their caps, and runs early when free space falls under 20 GB.")
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
