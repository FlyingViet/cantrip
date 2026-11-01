import Foundation

/// Drives the Bitwarden CLI. The master password and session key only ever travel in a child
/// process's environment, never in arguments, files or output.
struct BitwardenCLI {
    typealias Runner = (_ arguments: [String], _ environment: [String: String], _ input: Data?) throws -> ProcessRunner.Result

    var executable: String
    var run: Runner

    static let candidates = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]

    static func locate() -> String? {
        if let configured = ProcessInfo.processInfo.environment["CANTRIP_BW_PATH"], !configured.isEmpty {
            return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? ToolLocator.loginShellPath("bw")
    }

    static func live(_ executable: String) -> BitwardenCLI {
        BitwardenCLI(executable: executable) { arguments, environment, input in
            try ProcessRunner.run(executable, arguments, environment: environment, input: input,
                                  errorOutput: .capture, timeout: 120)
        }
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    private func environment(session: String?, extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "BW_SESSION")
        environment.removeValue(forKey: Self.passwordVariable)
        environment["BW_NOINTERACTION"] = "true"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        if let session { environment["BW_SESSION"] = session }
        return environment.merging(extra) { _, new in new }
    }

    static let passwordVariable = "CANTRIP_BW_MASTER_PASSWORD"

    @discardableResult
    private func call(_ arguments: [String], session: String? = nil, input: Data? = nil,
                      extra: [String: String] = [:], action: String) throws -> Data {
        let result = try run(arguments + ["--nointeraction"], environment(session: session, extra: extra), input)
        guard result.succeeded else {
            if result.timedOut { throw Failure(message: "Bitwarden didn't answer while trying to \(action).") }
            let detail = result.errorText.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(result.status)"
            throw Failure(message: "Bitwarden couldn't \(action): \(detail.prefix(200))")
        }
        return result.output
    }

    /// "unauthenticated", "locked" or "unlocked".
    func status() throws -> String {
        let data = try call(["status"], action: "report its status")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            throw Failure(message: "Bitwarden's status wasn't readable.")
        }
        return status
    }

    /// A session key for this unlock. Unlocking ends any other session key (the Bitwarden MCP's).
    func unlock(password: String) throws -> String {
        let result = try run(["unlock", "--passwordenv", Self.passwordVariable, "--raw", "--nointeraction"],
                             environment(session: nil, extra: [Self.passwordVariable: password]), nil)
        guard result.succeeded else {
            if result.errorText.localizedCaseInsensitiveContains("invalid master password") {
                throw Failure(message: "Bitwarden didn't accept that master password. Nothing changed.")
            }
            throw Failure(message: "Bitwarden couldn't unlock: \(result.errorText.split(whereSeparator: \.isNewline).first ?? "exit \(result.status)")")
        }
        let session = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !session.contains(" ") else { throw Failure(message: "Bitwarden unlocked but gave no session key.") }
        return session
    }

    func sync(session: String) throws {
        try call(["sync"], session: session, action: "sync with the server")
    }

    func lock() {
        _ = try? run(["lock", "--nointeraction"], environment(session: nil), nil)
    }

    func folderID(named name: String, session: String, create: Bool) throws -> String? {
        let data = try call(["list", "folders", "--search", name], session: session, action: "list folders")
        let folders = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        if let id = folders.first(where: { $0["name"] as? String == name })?["id"] as? String { return id }
        guard create else { return nil }
        let created = try call(["create", "folder"], session: session,
                               input: try SecretBitwarden.encoded(["name": name]), action: "create the \(name) folder")
        guard let object = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = object["id"] as? String else { throw Failure(message: "Bitwarden created the folder but didn't return it.") }
        return id
    }

    func items(folderID: String, session: String) throws -> [[String: Any]] {
        let data = try call(["list", "items", "--folderid", folderID], session: session, action: "list the folder's items")
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(message: "Bitwarden's item list wasn't readable.")
        }
        // Only the folder's own, live items (a search can return others; trash is never synced).
        return items.filter { item in
            item["folderId"] as? String == folderID && (item["deletedDate"] == nil || item["deletedDate"] is NSNull)
        }
    }

    func create(_ item: SecretItem, folderID: String, session: String) throws {
        try call(["create", "item"], session: session,
                 input: try SecretBitwarden.encoded(SecretBitwarden.newItem(item, folderID: folderID)),
                 action: "create \(item.name)")
    }

    func edit(_ item: SecretItem, existing: [String: Any], folderID: String, session: String) throws {
        guard let id = existing["id"] as? String else { throw Failure(message: "\(item.name) has no Bitwarden ID.") }
        var updated = existing
        let fresh = SecretBitwarden.newItem(item, folderID: folderID)
        updated["notes"] = fresh["notes"]
        updated["fields"] = fresh["fields"]
        try call(["edit", "item", id], session: session, input: try SecretBitwarden.encoded(updated), action: "update \(item.name)")
    }
}

/// Asks for the Bitwarden master password in a dialog on the Mac: from any process, never
/// blocking Cantrip's main thread, and giving up after two minutes.
enum SecretPasswordDialog {
    static let script = """
    on run argv
        set prompt to item 1 of argv
        activate
        set answer to display dialog prompt default answer "" with hidden answer with title "Cantrip — Bitwarden" buttons {"Cancel", "Unlock"} default button "Unlock" cancel button "Cancel" with icon caution giving up after 120
        if gave up of answer then return ""
        return text returned of answer
    end run
    """

    /// The password, or nil when the user cancelled or nobody answered.
    static func ask(reason: String) throws -> String? {
        let prompt = "\(reason)\n\nEnter your Bitwarden master password. Cantrip uses it once to unlock the vault, copies the \(SecretIndex.defaultFolder) folder into the keychain and locks the vault again. It isn't stored."
        let result = try ProcessRunner.run("/usr/bin/osascript", ["-", prompt], input: Data(script.utf8),
                                           errorOutput: .capture, timeout: 150)
        guard result.succeeded else { return nil }
        var password = String(decoding: result.output, as: UTF8.self)
        if password.hasSuffix("\n") { password.removeLast() }
        return password.isEmpty ? nil : password
    }
}

/// Unlocks Bitwarden, optionally imports new items, copies the secrets folder into the Keychain
/// and locks the vault again. Serialized across processes; the index records the outcome by name.
enum SecretSync {
    struct Report: Equatable {
        var created: [String] = []
        var updated: [String] = []
        var cached: [String] = []
        var removed: [String] = []
        var kept: [String] = []
        var skipped: [String] = []
        var existing: [String] = []
    }

    struct Cancelled: LocalizedError {
        var errorDescription: String? { "Nothing changed: the Bitwarden password dialog was cancelled or timed out." }
    }

    static func run(
        bitwarden: BitwardenCLI,
        store: SecretKeychain.Store = .keychain,
        password: () throws -> String?,
        importing: [SecretItem] = [],
        updateExisting: Bool = false,
        indexURL: URL = SecretIndex.file,
        now: () -> Date = Date.init
    ) throws -> Report {
        let lock = try SyncLock(SecretIndex.lockFile(for: indexURL))
        defer { lock.release() }
        var index = SecretIndex.load(from: indexURL) ?? SecretIndex()
        index.lastAttempt = now()
        do {
            let report = try perform(bitwarden: bitwarden, store: store, password: password, importing: importing,
                                     updateExisting: updateExisting, index: &index, now: now)
            index.lastError = nil
            try index.save(to: indexURL)
            return report
        } catch {
            index.lastError = error.localizedDescription
            try? index.save(to: indexURL)
            throw error
        }
    }

    private static func perform(
        bitwarden: BitwardenCLI, store: SecretKeychain.Store, password: () throws -> String?,
        importing: [SecretItem], updateExisting: Bool, index: inout SecretIndex, now: () -> Date
    ) throws -> Report {
        switch try bitwarden.status() {
        case "unauthenticated":
            throw BitwardenCLI.Failure(message: "The Bitwarden CLI isn't logged in. Log in once in Terminal with `bw login`, then sync again.")
        default:
            break
        }
        guard let secret = try password() else { throw Cancelled() }
        let session = try bitwarden.unlock(password: secret)
        defer { bitwarden.lock() }
        try bitwarden.sync(session: session)
        var report = Report()
        guard let folderID = try bitwarden.folderID(named: index.folder, session: session, create: !importing.isEmpty) else {
            throw BitwardenCLI.Failure(message: "Bitwarden has no folder named “\(index.folder)”. Create it, or import secrets into it with `cantrip secret import --apply`.")
        }
        if !importing.isEmpty {
            let existing = try bitwarden.items(folderID: folderID, session: session)
            let byName = Dictionary(existing.compactMap { item in (item["name"] as? String).map { ($0, item) } }) { first, _ in first }
            for item in importing {
                if let current = byName[item.name] {
                    guard updateExisting else { report.existing.append(item.name); continue }
                    try bitwarden.edit(item, existing: current, folderID: folderID, session: session)
                    report.updated.append(item.name)
                } else {
                    try bitwarden.create(item, folderID: folderID, session: session)
                    report.created.append(item.name)
                }
            }
            try bitwarden.sync(session: session)
        }
        var items: [SecretItem] = []
        for object in try bitwarden.items(folderID: folderID, session: session) {
            switch SecretBitwarden.item(from: object) {
            case .success(let item): items.append(item)
            case .failure(let reason): report.skipped.append(reason.description)
            }
        }
        items.sort { $0.name < $1.name }
        for item in items { try store.put(item) }
        report.cached = items.map(\.name)
        let fresh = Set(report.cached)
        let stale = try store.names().filter { !fresh.contains($0) }
        if items.isEmpty, !stale.isEmpty {
            // An emptied folder is more likely a mistake than a request to break every job.
            report.kept = stale
        } else {
            for name in stale { try store.delete(name) }
            report.removed = stale
        }
        index.items = try store.allItems().map(\.summary)
        index.skipped = report.skipped
        index.lastSync = now()
        return report
    }

    /// An exclusive lock on a file, so the app and the CLI never sync at once.
    final class SyncLock {
        private let descriptor: Int32

        init(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw BitwardenCLI.Failure(message: "Another sync is already running. Try again when it finishes.")
            }
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

extension SecretIndex {
    static func lockFile(for indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent().appendingPathComponent("sync.lock")
    }
}
