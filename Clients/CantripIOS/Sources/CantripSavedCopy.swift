import CryptoKit
import Foundation

/// The Mac's last full answers for what a launch draws first: the tab list, Home, the tabs last open,
/// Tasks, artifacts and views, each with the entity tag the Mac sent. Sending a tag back
/// (If-None-Match) turns an unchanged answer into a 304 with no body, so the copy here is used again.
///
/// On iPhone and iPad (`onDevice()`) the copy is also kept on the device, per pairing, in Caches and
/// protected while the device is locked: a cold launch draws it at once, marked as a saved copy until
/// the Mac confirms or replaces each part. Without a directory (Gateway Mac, tests) it's memory only.
final class CantripSavedCopy: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var body: Data
        var etag: String?
    }

    enum Part {
        static let sessions = "sessions"
        static let home = "home"
        static let tasks = "tasks"
        static let artifacts = "artifacts"
        static let views = "views"
        static func tab(_ id: String) -> String { "tab-" + id }
        static func isTab(_ name: String) -> Bool { name.hasPrefix("tab-") }
    }

    /// Tabs whose last copy is kept besides Home.
    static let tabLimit = 3
    /// Copies of pairings not opened for this long are deleted.
    static let unusedLifetime: TimeInterval = 30 * 24 * 60 * 60

    let directory: URL?
    private let lock = NSLock()
    private var pairing: String?
    private var entries: [String: Entry] = [:]
    private var tabOrder: [String] = []
    private var pending: [String: Entry?] = [:]
    private var flushScheduled = false
    private let writer = DispatchQueue(label: "cantrip.saved-copy", qos: .utility)

    init(directory: URL?) {
        self.directory = directory
    }

    static func onDevice() -> CantripSavedCopy {
        CantripSavedCopy(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CantripSavedCopy", isDirectory: true))
    }

    /// One pairing's copy: the Mac's address and its pairing token, never stored as such.
    static func pairingKey(url: String, directAddress: String?, token: String) -> String {
        let digest = SHA256.hash(data: Data("\(url)\n\(directAddress ?? "")\n\(token)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Switches to a pairing's copy (nil: none) and returns what this device kept for it.
    @discardableResult
    func open(pairing key: String?) -> [String: Entry] {
        lock.lock()
        defer { lock.unlock() }
        if key == pairing { return entries }
        flushLocked()
        pairing = key
        entries = [:]
        tabOrder = []
        guard let key, let folder = folder(key) else { return [:] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var tabs: [(String, Date)] = []
        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else { continue }
            entries[name] = entry
            if Part.isTab(name) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                tabs.append((name, date ?? .distantPast))
            }
        }
        tabOrder = tabs.sorted { $0.1 < $1.1 }.map(\.0)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        pruneUnusedLocked(keeping: key)
        return entries
    }

    func entry(_ name: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[name]
    }

    /// Keeps the Mac's full answer for `name` (and its tag) for the pairing that was open when the
    /// request started; a later switch drops it.
    func keep(_ name: String, body: Data, etag: String?, pairing key: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard key != nil, key == pairing else { return }
        let entry = Entry(body: body, etag: etag)
        guard entries[name] != entry else {
            if Part.isTab(name) { touchTabLocked(name) }
            return
        }
        entries[name] = entry
        pending[name] = entry
        if Part.isTab(name) { touchTabLocked(name) }
        scheduleFlushLocked()
    }

    var currentPairing: String? {
        lock.lock()
        defer { lock.unlock() }
        return pairing
    }

    /// Forgets a pairing's copy here and on the device (unpaired or removed).
    func discard(pairing key: String) {
        lock.lock()
        defer { lock.unlock() }
        if key == pairing {
            entries = [:]
            tabOrder = []
            pending = [:]
        }
        guard let folder = folder(key) else { return }
        writer.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Starts writing kept answers now (the app is leaving the foreground).
    func writePending() {
        lock.lock()
        flushLocked()
        lock.unlock()
    }

    /// Waits until every kept answer is on the device.
    func flush() {
        writePending()
        writer.sync {}
    }

    private func touchTabLocked(_ name: String) {
        tabOrder.removeAll { $0 == name }
        tabOrder.append(name)
        while tabOrder.count > Self.tabLimit {
            let removed = tabOrder.removeFirst()
            entries.removeValue(forKey: removed)
            pending[removed] = .some(nil)
        }
    }

    private func scheduleFlushLocked() {
        guard directory != nil, !flushScheduled else { return }
        flushScheduled = true
        // Coalesces a busy tab list (it changes with every streamed reply) into one write a second.
        writer.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.flushLocked()
            self.lock.unlock()
        }
    }

    private func flushLocked() {
        flushScheduled = false
        guard let key = pairing, !pending.isEmpty, let folder = folder(key) else {
            pending = [:]
            return
        }
        let writes = pending
        pending = [:]
        writer.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, entry) in writes {
                let file = folder.appendingPathComponent(name).appendingPathExtension("plist")
                guard let entry else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                guard let data = try? encoder.encode(entry) else { continue }
                #if os(iOS)
                try? data.write(to: file, options: [.atomic, .completeFileProtection])
                #else
                try? data.write(to: file, options: .atomic)
                #endif
            }
        }
    }

    private func pruneUnusedLocked(keeping key: String) {
        guard let directory else { return }
        let cutoff = Date().addingTimeInterval(-Self.unusedLifetime)
        writer.async {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for folder in folders where folder.lastPathComponent != key {
                let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if (date ?? .distantPast) < cutoff { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    private func folder(_ key: String) -> URL? {
        guard let directory, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent(key, isDirectory: true)
    }
}

import SwiftUI

/// Marks what's on screen as this device's saved copy until the Mac confirms or replaces it.
struct CantripSavedCopyNotice: View {
    enum Scope { case chat, tasks, artifacts }

    @ObservedObject var model: CantripRemoteModel
    let scope: Scope
    /// Inside the chat's notices band, which has its own padding and material.
    var inBand = false

    private var shown: Bool {
        switch scope {
        case .chat: model.showsSavedCopy
        case .tasks: model.homeTasksShowSavedCopy
        case .artifacts: model.homeArtifactsShowSavedCopy
        }
    }

    var body: some View {
        if shown {
            Label(model.errorMessage == nil ? "Saved copy · Updating…" : "Saved copy · Can't reach your Mac",
                  systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inBand ? 0 : 16)
                .padding(.vertical, inBand ? 0 : 6)
                .background(inBand ? AnyShapeStyle(.clear) : AnyShapeStyle(.thinMaterial))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remote.savedCopy")
        }
    }
}
