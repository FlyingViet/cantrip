import Foundation
import SQLite3
import SystemConfiguration

// MARK: - Muse logins (docs/muse.md "Staying signed in")

/// When a muse.ai login was made and when its cookie says it ends. Read from muse-cli's saved
/// cookies or Chrome's cookie database: names and times only, never a cookie's value.
struct MuseLoginStamp: Equatable {
    /// The `hatch_sess` cookie's own expiry (30 days after sign-in).
    var expires: Date
    var signedInAt: Date

    /// muse.ai ends a login on its server a week after sign-in, though the cookie claims 30 days.
    static let serverLifetime: TimeInterval = 7 * 86_400
    static let cookieLifetime: TimeInterval = 30 * 86_400

    var endsAt: Date { signedInAt.addingTimeInterval(Self.serverLifetime) }

    /// A later sign-in than `other` (or any login when there's none saved).
    func isNewer(than other: MuseLoginStamp?) -> Bool {
        guard let other else { return true }
        return expires.timeIntervalSince(other.expires) > 60
    }
}

enum MuseLoginFiles {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// muse-cli's saved login (`auth export` writes it, 0600).
    static var savedCookies: URL { home.appendingPathComponent(".config/muse-cli/cookies.txt") }
    static var chromeSupport: URL { home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true) }

    /// The saved login's `hatch_sess` row in muse-cli's Netscape cookie file: its expiry, and the
    /// sign-in 30 days before it (the file's date for a cookie with no expiry). Reads the domain,
    /// name and expiry columns only.
    static func savedLogin(at url: URL) -> MuseLoginStamp? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var newest: Date?
        for line in text.split(whereSeparator: \.isNewline) {
            var row = Substring(line)
            if row.hasPrefix("#HttpOnly_") { row = row.dropFirst("#HttpOnly_".count) } else if row.hasPrefix("#") { continue }
            // domain, include-subdomains, path, secure, expiry, name (the value, column 7, is never split out).
            let columns = row.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            guard columns.count >= 6, columns[0].hasSuffix("muse.ai"), columns[5] == "hatch_sess",
                  let expiry = Double(columns[4]) else { continue }
            let date = expiry > 0 ? Date(timeIntervalSince1970: expiry) : .distantFuture
            newest = max(newest ?? date, date)
        }
        guard let newest else { return nil }
        if newest == .distantFuture {
            let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return MuseLoginStamp(expires: saved.addingTimeInterval(MuseLoginStamp.cookieLifetime), signedInAt: saved)
        }
        return MuseLoginStamp(expires: newest, signedInAt: newest.addingTimeInterval(-MuseLoginStamp.cookieLifetime))
    }

    /// Chrome's cookie databases, one per profile (Default, Profile 1…), as muse-cli finds them.
    static func chromeStores(in support: URL) -> [URL] {
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        return profiles.compactMap { profile in
            ["Network/Cookies", "Cookies"].lazy.map { support.appendingPathComponent(profile).appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// When Chrome's cookie files last changed: reading them again only matters after that.
    static func chromeStamp(in support: URL) -> [String] {
        chromeStores(in: support).flatMap { store in
            ["", "-journal", "-wal"].map { suffix -> String in
                let path = store.path + suffix
                guard let values = try? FileManager.default.attributesOfItem(atPath: path) else { return path + " -" }
                let date = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return "\(path) \(values[.size] as? Int ?? 0) \(date)"
            }
        }
    }

    /// Chrome's newest muse.ai `hatch_sess` across profiles: when it was created and its expiry.
    /// Chrome locks its database, so this reads a copy in a private temporary folder and deletes it.
    /// Only `creation_utc` and `expires_utc` are selected; values stay encrypted and unread.
    static func chromeLogin(in support: URL) -> MuseLoginStamp? {
        var newest: MuseLoginStamp?
        for store in chromeStores(in: support) {
            guard let login = chromeLogin(store: store) else { continue }
            if login.isNewer(than: newest) { newest = login }
        }
        return newest
    }

    private static func chromeLogin(store: URL) -> MuseLoginStamp? {
        let files = FileManager.default
        let sidecars = ["-journal", "-wal"]
        func stamp() -> [String] {
            ([""] + sidecars).map { suffix in
                let values = try? files.attributesOfItem(atPath: store.path + suffix)
                return "\(values?[.size] as? Int ?? -1) \((values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
        }
        for _ in 0..<3 {
            let folder = files.temporaryDirectory.appendingPathComponent("cantrip-muse-login-\(UUID().uuidString)", isDirectory: true)
            guard (try? files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil
            else { return nil }
            defer { try? files.removeItem(at: folder) }
            let copy = folder.appendingPathComponent("Cookies")
            let before = stamp()
            do {
                try files.copyItem(at: store, to: copy)
                for suffix in sidecars where files.fileExists(atPath: store.path + suffix) {
                    try files.copyItem(atPath: store.path + suffix, toPath: copy.path + suffix)
                }
            } catch {
                continue
            }
            // Chrome wrote while this copied: the copy may be torn, so copy again.
            guard stamp() == before else { continue }
            return newestSession(inCopy: copy)
        }
        return nil
    }

    private static func newestSession(inCopy copy: URL) -> MuseLoginStamp? {
        var db: OpaquePointer?
        // Read-write on the private copy, so SQLite can roll back a journal Chrome left mid-write.
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "SELECT creation_utc, expires_utc FROM cookies WHERE host_key IN ('muse.ai', '.muse.ai') AND name = 'hatch_sess'"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var newest: MuseLoginStamp?
        while sqlite3_step(statement) == SQLITE_ROW {
            let created = chromeDate(sqlite3_column_int64(statement, 0))
            let expires = chromeDate(sqlite3_column_int64(statement, 1))
            let login = MuseLoginStamp(expires: expires, signedInAt: created)
            if login.isNewer(than: newest) { newest = login }
        }
        return newest
    }

    /// Chrome counts microseconds from 1601-01-01 UTC.
    static func chromeDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }
}

// MARK: - Copying Chrome's login

/// `muse-cli auth export --browser chrome`: muse-cli decrypts Chrome's muse.ai cookies with the
/// Chrome Safe Storage key from the login keychain and saves them to its cookies.txt (0600). Always
/// Chrome only, so it never falls back to opening a browser window. Its output is never logged:
/// only the outcome below.
enum MuseLoginExport {
    enum Outcome: String, Codable {
        case saved
        /// Chrome has no unexpired muse.ai login.
        case noChromeLogin
        /// macOS didn't hand over Chrome's key (denied, or no keychain).
        case keychain
        /// No answer in time: macOS may be showing a keychain dialog.
        case timedOut
        /// Chrome wrote its cookies while muse-cli read them; worth one more try later.
        case busy
        case notInstalled
        case failed

        var succeeded: Bool { self == .saved }

        /// Why it didn't work, for Settings and the notice.
        var explanation: String? {
            switch self {
            case .saved: nil
            case .noChromeLogin: "Chrome has no current muse.ai login"
            case .keychain: "macOS didn't let muse-cli read Chrome's login (Chrome Safe Storage in the keychain)"
            case .timedOut: "copying Chrome's login took too long; macOS may be asking to share it"
            case .busy: "Chrome was saving its cookies"
            case .notInstalled: "muse-cli isn't installed"
            case .failed: "muse-cli couldn't copy Chrome's login"
            }
        }
    }

    /// muse-cli gives the keychain 120 seconds; this outlasts that so its own timeout answers first.
    static let timeout: TimeInterval = 150

    static func arguments() -> [String] { ["-m", "muse_cli", "auth", "export", "--browser", "chrome"] }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MUSE_NO_UPDATE_CHECK"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "MUSE_CLI_DEMO")
        return environment
    }

    /// What muse-cli's message says happened (the message itself goes nowhere).
    static func classify(status: Int32, timedOut: Bool, message: String) -> Outcome {
        if timedOut { return .timedOut }
        if status == 0 { return .saved }
        let text = message.lowercased()
        if text.contains("timed out waiting for the macos keychain") { return .timedOut }
        if text.contains("keychain") { return .keychain }
        if text.contains("changed while reading") { return .busy }
        if text.contains("valid hatch_sess") || text.contains("no muse.ai login") || text.contains("no chrome profile") { return .noChromeLogin }
        return .failed
    }

    static func run(python: String = MuseConnector.defaultPython, timeout: TimeInterval = MuseLoginExport.timeout) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: python) else { return .notInstalled }
        return await Task.detached(priority: .utility) {
            do {
                let result = try ProcessRunner.run(python, arguments(), environment: environment(), errorOutput: .merge,
                                                   timeout: timeout, outputLimit: 64_000)
                return classify(status: result.status, timedOut: result.timedOut, message: result.text)
            } catch {
                return .failed
            }
        }.value
    }
}

// MARK: - Keeping Muse signed in

/// Keeps Cantrip's Muse login current without Terminal. muse.ai ends a login a week after sign-in
/// and its cookie can't be renewed, so: when Chrome on this Mac has a newer muse.ai login than the
/// saved one, Cantrip copies it (`MuseLoginExport`); when Muse turns the login down, it checks once
/// more a few minutes later (short failures recover by themselves), then copies Chrome's login or
/// asks the user to sign in at muse.ai in Chrome, once, and waits for Chrome's login to change. A day
/// before a login ends it reminds the user, and Home's Upcoming lists that reminder. Copies are rate
/// limited, one at a time, with a timeout, and stop after a failure until Chrome's login changes, so
/// keychain dialogs never pile up. State (times only) is in `~/.cache/Cantrip/muse/login.json`.
@MainActor
final class MuseLoginWatcher {
    static let shared = MuseLoginWatcher()

    struct State: Codable, Equatable {
        /// Copies started in the last day, for the rate limit.
        var exports: [Date] = []
        /// When a rejected login gets checked again before Cantrip acts on it.
        var recheckAt: Date?
        /// Chrome's login (its expiry) that failed to copy or that muse.ai also turned down: no
        /// more copies until Chrome has a different one.
        var blockedChromeExpiry: Date?
        /// Why that login wasn't used, for when the user is asked to sign in.
        var blockedReason: String?
        /// The user was asked to sign in (the login ended and Chrome had nothing newer); one
        /// notice, and no more checks of Muse until a login works again.
        var askedAt: Date?
        /// The saved login (its sign-in time) whose reminder went out or was skipped.
        var remindedFor: Date?
        var skippedFor: Date?
        /// The saved login that was checked once after its week ended.
        var probedFor: Date?
    }

    // Tests replace these.
    var directory = MuseConnector.directory
    var savedCookies = MuseLoginFiles.savedCookies
    var chromeSupport = MuseLoginFiles.chromeSupport
    var now: () -> Date = Date.init
    /// Muse is on with the user's account (not the demo).
    var isLive: () -> Bool = { MuseConnector.shared.isEnabled && !AppSettings.shared.museDemo }
    var status: () -> MuseStatus = { MuseConnector.shared.status }
    /// Asks Muse again with the saved login, from a fresh bridge.
    var recheck: () async -> MuseStatus = {
        MuseConnector.shared.stopBridge()
        return await MuseConnector.shared.check()
    }
    var export: () async -> MuseLoginExport.Outcome = { await MuseLoginExport.run() }
    /// Puts what the user should do into Muse's status while the login is missing.
    var showSignIn: (String) -> Void = { MuseConnector.shared.noteLoginNeeded(detail: $0) }
    var notify: ((_ title: String, _ body: String) -> Void)?
    var macName: () -> String = { MuseLoginWatcher.computerName }

    var recheckDelay: TimeInterval = 240
    var minExportInterval: TimeInterval = 10 * 60
    var maxExportsPerDay = 4
    /// How long before a login ends the reminder goes out.
    var reminderLead: TimeInterval = 86_400

    private(set) var state = State()
    private(set) var savedLogin: MuseLoginStamp?
    private(set) var chromeLogin: MuseLoginStamp?
    private var chromeStamp: [String]?
    /// Running in the host (tests set it without the timer).
    var isStarted = false
    private var running = false
    private var again = false
    private var againManual = false
    private var timer: Timer?
    private var rateLimitLogged: Date?

    var stateURL: URL { directory.appendingPathComponent("login.json") }

    func start(interval: TimeInterval = 60) {
        load()
        isStarted = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.tick() } }
        }
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isStarted = false
    }

    func load() {
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder.iso.decode(State.self, from: $0) } ?? State()
        chromeStamp = nil
        savedLogin = MuseLoginFiles.savedLogin(at: savedCookies)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder.iso.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    /// One look at the login: on a timer, when Muse's status changes and after Check Now
    /// (`manual`: the user just checked, so no waiting to recheck and a blocked login is tried again).
    func tick(manual: Bool = false) async {
        if running {
            again = true
            againManual = againManual || manual
            return
        }
        running = true
        defer { running = false }
        var passes = 0
        var asked = manual
        repeat {
            again = false
            await pass(manual: asked)
            asked = againManual
            againManual = false
            passes += 1
        } while again && passes < 3
    }

    private func refresh() {
        savedLogin = MuseLoginFiles.savedLogin(at: savedCookies)
        let stamp = MuseLoginFiles.chromeStamp(in: chromeSupport)
        if stamp != chromeStamp {
            chromeLogin = MuseLoginFiles.chromeLogin(in: chromeSupport)
            chromeStamp = stamp
        }
    }

    private func pass(manual: Bool) async {
        guard isLive() else {
            if state.recheckAt != nil {
                state.recheckAt = nil
                save()
            }
            return
        }
        refresh()
        let date = now()
        let saved = savedLogin

        // Chrome has a newer login than the saved one (the user signed in again): copy it.
        if let chrome = chromeLogin, chrome.isNewer(than: saved), manual || !isBlocked(chrome) {
            await copy(chrome, saved: saved, manual: manual)
            return
        }

        let current = status()
        if current.state == .loginNeeded {
            // Already asked: wait for Chrome's login to change instead of asking Muse again.
            if state.askedAt != nil, !manual { return }
            if !manual {
                // One turn-down isn't proof: muse.ai's short failures recover within minutes.
                guard let at = state.recheckAt else {
                    state.recheckAt = date.addingTimeInterval(recheckDelay)
                    save()
                    MuseLog.write("login: muse.ai turned the saved login down; checking again at \(Self.clock(date.addingTimeInterval(recheckDelay))) before acting")
                    return
                }
                guard date >= at else { return }
                state.recheckAt = nil
                save()
                let after = await recheck()
                guard after.state == .loginNeeded else {
                    MuseLog.write("login: the second check answered \(after.label); nothing to do")
                    return
                }
            }
            state.recheckAt = nil
            let reason = if let chrome = chromeLogin, chrome.isNewer(than: saved), let why = state.blockedReason {
                why
            } else {
                chromeLogin == nil ? "Chrome on this Mac has no muse.ai login" : "Chrome's muse.ai login is the one that ended"
            }
            askToSignIn(reason: reason, blocking: chromeLogin)
            return
        }
        if state.recheckAt != nil || (state.askedAt != nil && current.state == .connected) {
            state.recheckAt = nil
            if current.state == .connected { state.askedAt = nil }
            save()
        }

        guard current.state == .connected, let saved else { return }
        // A day before the login ends: remind the user to sign in again in Chrome.
        let remindAt = saved.endsAt.addingTimeInterval(-reminderLead)
        if date >= remindAt, date < saved.endsAt, state.remindedFor != saved.signedInAt {
            state.remindedFor = saved.signedInAt
            save()
            MuseLog.write("login: reminder sent (signed in \(Self.clock(saved.signedInAt)); muse.ai ends it about \(Self.clock(saved.endsAt)))")
            notify?("Sign in to Muse again by \(Self.day(saved.endsAt))",
                    "muse.ai ends Cantrip's Muse login about \(Self.clock(saved.endsAt)). Sign in at muse.ai in Chrome on \(macName()); Cantrip copies the new login by itself.")
        }
        // The week is up: ask Muse once instead of waiting for the next feed or tab check.
        if date >= saved.endsAt.addingTimeInterval(120), state.probedFor != saved.signedInAt {
            state.probedFor = saved.signedInAt
            save()
            MuseLog.write("login: the saved login's week is up; checking it")
            _ = await recheck()
        }
    }

    private func isBlocked(_ chrome: MuseLoginStamp) -> Bool {
        guard let blocked = state.blockedChromeExpiry else { return false }
        return abs(blocked.timeIntervalSince(chrome.expires)) < 1
    }

    private func copy(_ chrome: MuseLoginStamp, saved: MuseLoginStamp?, manual: Bool) async {
        let date = now()
        state.exports = state.exports.filter { date.timeIntervalSince($0) < 86_400 }
        if !manual {
            if let last = state.exports.max(), date.timeIntervalSince(last) < minExportInterval {
                if rateLimitLogged.map({ date.timeIntervalSince($0) >= minExportInterval }) ?? true {
                    rateLimitLogged = date
                    MuseLog.write("login: next copy of Chrome's login waits until \(Self.clock(last.addingTimeInterval(minExportInterval)))")
                }
                return
            }
            if state.exports.count >= maxExportsPerDay {
                MuseLog.write("login: \(state.exports.count) copies in the last day; no more until Chrome's login changes")
                failed(chrome, reason: "Cantrip already tried to copy Chrome's login \(state.exports.count) times today")
                return
            }
        } else if let last = state.exports.max(), date.timeIntervalSince(last) < 60 {
            return
        }
        state.exports.append(date)
        save()
        MuseLog.write("login: Chrome has a newer muse.ai login (signed in \(Self.clock(chrome.signedInAt)); saved one "
                      + (saved.map { "from \(Self.clock($0.signedInAt))" } ?? "missing") + "); copying it with muse-cli auth export --browser chrome")
        let outcome = await export()
        MuseLog.write("login: copy \(outcome == .saved ? "saved" : "failed (\(outcome.rawValue))")")
        refresh()
        guard outcome.succeeded else {
            if outcome != .busy { failed(chrome, reason: outcome.explanation ?? "") }
            return
        }
        let after = await recheck()
        switch after.state {
        case .connected:
            MuseLog.write("login: connected with Chrome's login (signed in \(Self.clock(chrome.signedInAt)))")
            let wasAsked = state.askedAt != nil
            state.askedAt = nil
            state.recheckAt = nil
            state.blockedChromeExpiry = nil
            state.blockedReason = nil
            save()
            if wasAsked { notify?("Muse is connected again", "Cantrip copied your new muse.ai login from Chrome on \(macName()).") }
        case .loginNeeded:
            failed(chrome, reason: "muse.ai turned Chrome's login down too, so it has ended there as well")
        default:
            MuseLog.write("login: copied; Muse answered \(after.label)")
        }
    }

    /// Chrome's login couldn't be used: no more copies of it. While the saved login still works,
    /// nothing else happens (it's reported if that one ends); without a working login the user is asked.
    private func failed(_ chrome: MuseLoginStamp, reason: String) {
        state.blockedChromeExpiry = chrome.expires
        state.blockedReason = reason.isEmpty ? nil : reason
        save()
        if status().state == .loginNeeded {
            askToSignIn(reason: reason, blocking: chrome)
        } else {
            MuseLog.write("login: kept the saved login, which still works (\(reason.isEmpty ? "copy failed" : reason))")
        }
    }

    /// Shows what to do, tells the user once, and copies nothing more until Chrome's login changes.
    private func askToSignIn(reason: String, blocking chrome: MuseLoginStamp?) {
        let first = state.askedAt == nil
        state.askedAt = state.askedAt ?? now()
        state.blockedChromeExpiry = chrome?.expires ?? state.blockedChromeExpiry
        state.recheckAt = nil
        save()
        let what = "Sign in at muse.ai in Chrome on \(macName()); Cantrip copies the new login by itself."
        showSignIn(what + (reason.isEmpty ? "" : " (\(reason).)"))
        MuseLog.write("login: asked the user to sign in at muse.ai in Chrome (\(reason.isEmpty ? "no reason" : reason))")
        if first { notify?("Muse needs you to sign in", "muse.ai ended Cantrip's Muse login. " + what) }
    }

    /// Skips this login's reminder (Upcoming's Cancel).
    func skipReminder() throws -> String {
        guard let saved = savedLogin else { throw HomeUpcoming.Failure(status: 404, message: "That item isn't in Upcoming any more.") }
        state.remindedFor = saved.signedInAt
        state.skippedFor = saved.signedInAt
        save()
        MuseLog.write("login: reminder skipped for the login from \(Self.clock(saved.signedInAt))")
        return "Skipped this week's Muse sign-in reminder. Cantrip still tells you if the login ends."
    }

    /// The reminder (or the sign-in Cantrip is waiting for) in Home's Upcoming.
    func upcomingItem(now date: Date) -> HomeUpcoming.Item? {
        guard isStarted, isLive() else { return nil }
        let howTo = "Sign in at muse.ai in Chrome on \(macName()); Cantrip copies the new login by itself."
        if status().state == .loginNeeded {
            guard state.askedAt != nil else { return nil }
            return HomeUpcoming.Item(id: "muse:login", kind: .reminder, title: "Sign in to Muse in Chrome",
                                     detail: "muse.ai ended Cantrip's Muse login. " + howTo, nextRunAt: nil,
                                     schedule: "Waiting for you", owner: "Cantrip (Muse)", state: .waiting)
        }
        guard let saved = savedLogin, date < saved.endsAt, state.skippedFor != saved.signedInAt else { return nil }
        if state.remindedFor == saved.signedInAt {
            return HomeUpcoming.Item(id: "muse:login", kind: .reminder, title: "Sign in to Muse again before its login ends",
                                     detail: howTo, nextRunAt: nil, schedule: "Login ends \(Self.clock(saved.endsAt))",
                                     owner: "Cantrip (Muse)", state: .waiting)
        }
        let remindAt = saved.endsAt.addingTimeInterval(-reminderLead)
        return HomeUpcoming.Item(
            id: "muse:login", kind: .reminder, title: "Remind you to sign in to Muse again",
            detail: "muse.ai ends this login about \(Self.clock(saved.endsAt)). " + howTo,
            nextRunAt: remindAt, schedule: "Each week, a day before the login ends", owner: "Cantrip (Muse)",
            state: .scheduled, cancelLabel: "Skip",
            confirm: "Skip this week's Muse sign-in reminder? Cantrip still tells you if the login ends.")
    }

    // MARK: Text

    /// This Mac's name as Sharing shows it.
    nonisolated static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "the Mac running Cantrip"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE h:mm a"
        return formatter.string(from: date)
    }
}
