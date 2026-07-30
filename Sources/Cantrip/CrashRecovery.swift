import Darwin
import Foundation

/// Records the running build and keeps a tiny detached watcher alive. If the
/// app exits without its normal termination callback, the watcher reports the
/// crash and reopens this exact bundle path instead of asking LaunchServices
/// to choose among installed copies.
enum CrashRecovery {
    struct Report: Codable, Equatable {
        let id: UUID
        let detectedAt: Date
        let crashedBuild: String
        let bundlePath: String
        let automaticRelaunchAttempted: Bool
    }

    private struct RunMarker: Codable {
        let id: UUID
        let pid: Int32
        let startedAt: Date
        let buildIdentity: String
        let bundlePath: String
    }

    private static let crashWindow: TimeInterval = 60
    private static let maximumAutomaticRelaunches = 3
    private static var currentMarkerURL: URL?

    private static var stateDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/recovery")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var latestReportURL: URL {
        stateDirectory.appendingPathComponent("latest-crash.json")
    }

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cantrip.log")
    }

    static var buildIdentity: String {
        Bundle.main.object(forInfoDictionaryKey: "CantripBuildIdentity") as? String
            ?? "development"
    }

    static var buildDate: String {
        Bundle.main.object(forInfoDictionaryKey: "CantripBuildDate") as? String
            ?? "unknown"
    }

    /// Starts watching this process and returns any unreported prior crash.
    static func start() -> Report? {
        let previousReport = consumeLatestReport()
        guard let executableURL = Bundle.main.executableURL else {
            appendLog("recovery: executable URL unavailable; watcher not started")
            return previousReport
        }

        let marker = RunMarker(
            id: UUID(),
            pid: getpid(),
            startedAt: Date(),
            buildIdentity: buildIdentity,
            bundlePath: Bundle.main.bundlePath
        )
        let markerURL = stateDirectory
            .appendingPathComponent("run-\(marker.id.uuidString).json")
        do {
            try write(marker, to: markerURL)
            currentMarkerURL = markerURL

            let watcher = Process()
            watcher.executableURL = executableURL
            watcher.arguments = ["--cantrip-crash-watcher", markerURL.path]
            watcher.standardInput = FileHandle.nullDevice
            watcher.standardOutput = FileHandle.nullDevice
            watcher.standardError = FileHandle.nullDevice
            try watcher.run()
            appendLog("launch: build \(buildIdentity) (\(buildDate)), pid \(marker.pid), bundle \(marker.bundlePath)")
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            currentMarkerURL = nil
            appendLog("recovery: failed to start watcher: \(error.localizedDescription)")
        }
        return previousReport
    }

    static func markCleanExit() {
        guard let markerURL = currentMarkerURL else { return }
        do {
            try FileManager.default.removeItem(at: markerURL)
            appendLog("exit: clean termination for build \(buildIdentity)")
        } catch {
            appendLog("exit: could not clear recovery marker: \(error.localizedDescription)")
        }
        currentMarkerURL = nil
    }

    static func runWatcher(markerPath: String) {
        let markerURL = URL(fileURLWithPath: markerPath)
        guard let marker: RunMarker = read(from: markerURL) else { return }

        while FileManager.default.fileExists(atPath: markerURL.path),
              processExists(marker.pid) {
            usleep(250_000)
        }
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        try? FileManager.default.removeItem(at: markerURL)

        let now = Date()
        let crashCount = recordCrash(at: now.timeIntervalSince1970, in: stateDirectory)
        let shouldRelaunch = shouldAutomaticallyRelaunch(crashCount: crashCount)
        let report = Report(
            id: UUID(),
            detectedAt: now,
            crashedBuild: marker.buildIdentity,
            bundlePath: marker.bundlePath,
            automaticRelaunchAttempted: shouldRelaunch
        )
        try? write(report, to: latestReportURL)
        appendLog("crash: unexpected exit of pid \(marker.pid), build \(marker.buildIdentity), bundle \(marker.bundlePath)")

        if shouldRelaunch {
            relaunchExactBundle(marker.bundlePath)
        } else {
            appendLog("recovery: paused after \(crashCount) crashes in \(Int(crashWindow)) seconds")
            showCrashLoopNotification()
        }
    }

    static func message(for report: Report) -> String {
        let action = report.automaticRelaunchAttempted
            ? "Cantrip relaunched the same app bundle automatically."
            : "Automatic relaunch paused because Cantrip crashed repeatedly."
        return """
        Cantrip recovered from an unexpected exit. \(action)

        Crashed build: \(report.crashedBuild)
        Running build: \(buildIdentity) (\(buildDate))
        Bundle: \(report.bundlePath)
        Details: ~/Library/Logs/Cantrip.log
        """
    }

    static func shouldAutomaticallyRelaunch(crashCount: Int) -> Bool {
        crashCount <= maximumAutomaticRelaunches
    }

    static func relaunchArguments(bundlePath: String) -> [String] {
        ["-n", bundlePath]
    }

    /// Each watcher writes its own marker before counting. Unlike a shared
    /// JSON history, concurrent crashes cannot overwrite one another.
    static func recordCrash(at timestamp: TimeInterval, in directory: URL) -> Int {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markerURL = directory
            .appendingPathComponent("crash-\(UUID().uuidString).marker")
        try? Data(String(timestamp).utf8).write(to: markerURL, options: .atomic)

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var count = 0
        for url in urls where url.pathExtension == "marker"
            && url.lastPathComponent.hasPrefix("crash-") {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  let crashTime = TimeInterval(text),
                  crashTime <= timestamp,
                  timestamp - crashTime <= crashWindow else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            count += 1
        }
        return count
    }

    private static func relaunchExactBundle(_ bundlePath: String) {
        let executablePath = (bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS/Cantrip")
        for _ in 0..<60 {
            if FileManager.default.isExecutableFile(atPath: executablePath) { break }
            usleep(500_000)
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            appendLog("recovery: current bundle never became available at \(bundlePath)")
            return
        }
        if hasRunningInstance(from: bundlePath) {
            appendLog("recovery: skipped relaunch because \(bundlePath) is already running")
            return
        }

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = relaunchArguments(bundlePath: bundlePath)
        opener.standardInput = FileHandle.nullDevice
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        do {
            try opener.run()
            opener.waitUntilExit()
            appendLog("recovery: open \(bundlePath) exited \(opener.terminationStatus)")
        } catch {
            appendLog("recovery: relaunch failed: \(error.localizedDescription)")
        }
    }

    private static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func hasRunningInstance(from bundlePath: String) -> Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("run-")
            && url.pathExtension == "json" {
            guard let marker: RunMarker = read(from: url) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if processExists(marker.pid) {
                if marker.bundlePath == bundlePath { return true }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return false
    }

    private static func consumeLatestReport() -> Report? {
        guard let report: Report = read(from: latestReportURL) else { return nil }
        try? FileManager.default.removeItem(at: latestReportURL)
        return report
    }

    private static func read<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func appendLog(_ message: String) {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(timestamp)] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func showCrashLoopNotification() {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = [
            "-e",
            "display notification \"Open Cantrip manually after checking the log.\" with title \"Cantrip stopped restarting\""
        ]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try? script.run()
    }
}
