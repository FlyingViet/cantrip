import Foundation

/// How many child tabs may run at once, and whether the Mac has room for auto-fork to start
/// another now. The limits are settings (Run in Child Tab stops at them); auto-fork also waits for
/// free disk, a calmer CPU and, for work that needs one, a free Simulator, and runs one fewer
/// child overall while the Mac is fairly busy or short on disk. Docs: sessions-and-council.md.
enum ChildTabCapacity {
    static let defaultPerParent = 3
    static let defaultOverall = 4
    static let maximumPerParent = 6
    static let maximumOverall = 8
    /// Below this much free disk (where worktrees live) auto-fork waits: a checkout and its build
    /// take several GB.
    static let minimumFreeGB = 15.0
    /// Below this, auto-fork runs one fewer child tab overall.
    static let comfortableFreeGB = 30.0
    /// 1-minute load per core at which auto-fork waits, and at which it runs one fewer.
    static let busyLoad = 1.0
    static let elevatedLoad = 0.7
    /// Simulator leases at which work that needs a Simulator waits: as many as the pool lets run at
    /// once (`simulatorPoolMaxBooted`).
    static var simulatorLeaseLimit: Int { SimulatorPool.Policy.standard().maxBooted }

    struct Resources: Equatable {
        /// 1-minute load average.
        var load: Double
        var cores: Int
        var freeGB: Double?
        var simulatorLeases: Int

        static let idle = Resources(load: 0, cores: 8, freeGB: nil, simulatorLeases: 0)

        var loadPerCore: Double { load / Double(max(cores, 1)) }
    }

    /// The Mac's load, free disk at `volume` and the Simulator pool's current leases. Quick, but it
    /// reads the disk; keep it off the main actor.
    static func sample(volume: URL) -> Resources {
        var averages = [Double](repeating: 0, count: 3)
        let load = getloadavg(&averages, 3) > 0 ? averages[0] : 0
        var url = volume
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
        let now = Date()
        let leases = SimulatorPool.Store.standard.read().leases.filter { $0.expiresAt > now }.count
        return Resources(load: load, cores: ProcessInfo.processInfo.activeProcessorCount, freeGB: free,
                         simulatorLeases: leases)
    }

    /// What holds the overall limit down for auto-fork, if anything.
    private static func pressure(_ resources: Resources) -> [String] {
        var reasons: [String] = []
        if resources.loadPerCore >= elevatedLoad { reasons.append("the Mac is busy") }
        if let free = resources.freeGB, free < comfortableFreeGB { reasons.append("disk is getting full") }
        return reasons
    }

    /// The overall limit auto-fork works to: one fewer for each kind of pressure, at least one.
    static func autoOverallLimit(_ limit: Int, resources: Resources) -> Int {
        max(limit - pressure(resources).count, 1)
    }

    /// Why auto-fork can't start another child tab for this parent now (shown on the queue row),
    /// or nil. `parentRunning` and `overallRunning` count children running or being set up.
    static func autoForkWait(parentRunning: Int, overallRunning: Int, perParentLimit: Int, overallLimit: Int,
                             resources: Resources, needsSimulator: Bool) -> String? {
        if let free = resources.freeGB, free < minimumFreeGB {
            return "Auto-forks when more disk is free (\(Int(free)) GB free, needs \(Int(minimumFreeGB)) GB)"
        }
        if resources.loadPerCore >= busyLoad {
            return "Auto-forks when the Mac is less busy (load \(String(format: "%.1f", resources.load)) on \(resources.cores) cores)"
        }
        if parentRunning >= perParentLimit {
            return "Auto-forks when a child tab finishes (\(parentRunning) of \(perParentLimit) running for this tab)"
        }
        let limit = autoOverallLimit(overallLimit, resources: resources)
        if overallRunning >= limit {
            let why = pressure(resources)
            let fewer = limit < overallLimit ? "; fewer while \(why.joined(separator: " and "))" : ""
            return "Auto-forks when a child tab finishes (\(overallRunning) of \(limit) running\(fewer))"
        }
        if needsSimulator, resources.simulatorLeases >= simulatorLeaseLimit {
            return "Auto-forks when a Simulator frees up (\(resources.simulatorLeases) in use)"
        }
        return nil
    }

    /// Whether a request will likely run the Simulator (UI tests, simulator screenshots).
    static func needsSimulator(_ text: String) -> Bool {
        text.range(of: #"\b(simulators?|simctl|maestro|ui ?tests?|xcuitest)\b|\bxcodebuild\b[^\n]*\btest\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}
