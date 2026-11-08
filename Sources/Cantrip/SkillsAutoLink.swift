import Foundation

/// Links new or changed library skills without a `cantrip skills sync` (setting `skillsAutoLink`).
/// Each check fingerprints the library's files; a change is synced once it has settled (the next
/// check sees the same files), so a skill still being written isn't linked half-done. The sync is
/// the usual one: new skills linked for every backend, removed or turned-off ones unlinked, a skill
/// with a credential-looking value kept unlinked, a name clash reported, the change recorded in
/// the library's history. The first check catches up on changes made while Cantrip was closed.
final class SkillsAutoLink {
    static let interval: TimeInterval = 30

    let library: SkillsLibrary
    private var synced: String?
    private var pending: String?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cantrip.skills-autolink", qos: .utility)

    init(library: SkillsLibrary = SkillsLibrary()) { self.library = library }

    /// One check: the sync's report when one ran, nil when there was nothing settled to sync.
    func check() throws -> SkillsLibrary.Report? {
        let now = Self.fingerprint(of: library)
        if let synced {
            guard now != synced else { pending = nil; return nil }
            guard now == pending else { pending = now; return nil }
        }
        // A failed sync waits for the next change instead of retrying every check.
        defer { synced = Self.fingerprint(of: library); pending = nil }
        return try library.sync()
    }

    /// Checks every `interval` seconds (the first after `delay`) until `stop()`; `report` gets each
    /// sync's report or error, on a background queue.
    func start(delay: TimeInterval = 15, report: @escaping (Result<SkillsLibrary.Report, Error>) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + delay, repeating: Self.interval, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    if let synced = try self.check() { report(.success(synced)) }
                } catch {
                    report(.failure(error))
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            synced = nil
            pending = nil
        }
    }

    /// Every file in the library except its history and hidden files: path, size and date.
    static func fingerprint(of library: SkillsLibrary) -> String {
        let root = library.folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return "" }
        var lines: [String] = []
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count)
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(path)|\(values?.isDirectory == true ? -1 : values?.fileSize ?? 0)|\(date)")
        }
        return lines.sorted().joined(separator: "\n")
    }
}
