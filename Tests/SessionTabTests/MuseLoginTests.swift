import Foundation
import SQLite3

extension SessionTabTests {
    /// Keeping Muse signed in: reading the saved and Chrome's logins (times only), copying a newer
    /// Chrome login, rechecking a turned-down login before acting, the failure path, rate limits,
    /// the weekly reminder and its Upcoming item, and the export command.
    @MainActor
    static func testMuseLogin() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("cantrip-muse-login-test-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let savedLogDirectory = MuseLog.directory
        MuseLog.directory = root
        defer {
            MuseLog.directory = savedLogDirectory
            try? files.removeItem(at: root)
        }
        let cookies = root.appendingPathComponent("cookies.txt")
        let chrome = root.appendingPathComponent("Chrome", isDirectory: true)
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func log() -> String { (try? String(contentsOf: root.appendingPathComponent("activity.log"), encoding: .utf8)) ?? "" }

        // Saved login: muse-cli's Netscape file; the sign-in is 30 days before the cookie's expiry.
        func writeSaved(signedIn: Date, value: String = "SAVED-SECRET-VALUE") throws {
            let expiry = Int(signedIn.addingTimeInterval(30 * day).timeIntervalSince1970)
            try ("# Netscape HTTP Cookie File\n"
                + ".muse.ai\tTRUE\t/\tTRUE\t\(expiry)\thatch_sess\t\(value)\n"
                + "muse.ai\tFALSE\t/\tTRUE\t\(expiry + 99 * Int(day))\t__Host-hatch_one_tap\tONE-TAP-SECRET\n"
                + ".example.com\tTRUE\t/\tFALSE\t\(expiry + 500)\thatch_sess\tOTHER\n").write(to: cookies, atomically: true, encoding: .utf8)
        }
        // Chrome: a cookies table per profile, values encrypted and never read.
        func micros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }
        func writeChrome(profile: String = "Default", path: String = "Cookies", signedIn: [Date], otherHost: Bool = true) throws {
            let url = chrome.appendingPathComponent(profile).appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: url)
            var db: OpaquePointer?
            precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            var sql = "CREATE TABLE cookies(creation_utc INTEGER, host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);"
            for date in signedIn {
                sql += "INSERT INTO cookies VALUES(\(micros(date)), '.muse.ai', 'hatch_sess', '', X'4348524F4D452D534543524554', \(micros(date.addingTimeInterval(30 * day))));"
            }
            if otherHost {
                let late = base.addingTimeInterval(400 * day)
                sql += "INSERT INTO cookies VALUES(\(micros(late)), '.example.com', 'hatch_sess', '', X'00', \(micros(late)));"
            }
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }

        // Reading: names and times only.
        try writeSaved(signedIn: base.addingTimeInterval(-8 * day))
        let saved = try requireHome(MuseLoginFiles.savedLogin(at: cookies))
        precondition(saved.signedInAt == base.addingTimeInterval(-8 * day) && saved.endsAt == base.addingTimeInterval(-day),
                     "the other site's hatch_sess and the one-tap cookie don't count: \(saved)")
        try "# Netscape HTTP Cookie File\n#HttpOnly_.muse.ai\tTRUE\t/\tTRUE\t1800000000\thatch_sess\tX\n"
            .write(to: root.appendingPathComponent("httponly.txt"), atomically: true, encoding: .utf8)
        precondition(MuseLoginFiles.savedLogin(at: root.appendingPathComponent("httponly.txt"))?.expires == base)
        try "# Netscape HTTP Cookie File\n.muse.ai\tTRUE\t/\tTRUE\t1800000000\thatch_vml\tX\n"
            .write(to: root.appendingPathComponent("none.txt"), atomically: true, encoding: .utf8)
        precondition(MuseLoginFiles.savedLogin(at: root.appendingPathComponent("none.txt")) == nil
                     && MuseLoginFiles.savedLogin(at: root.appendingPathComponent("missing.txt")) == nil)
        precondition(MuseLoginFiles.chromeLogin(in: chrome) == nil, "no Chrome profile")
        let copiesBefore = try files.contentsOfDirectory(atPath: files.temporaryDirectory.path).filter { $0.hasPrefix("cantrip-muse-login-") && !$0.contains("test") }
        try writeChrome(signedIn: [base.addingTimeInterval(-3 * day), base.addingTimeInterval(-2 * day)])
        try writeChrome(profile: "Profile 2", path: "Network/Cookies", signedIn: [base.addingTimeInterval(-3_600)])
        try writeChrome(profile: "System Profile", signedIn: [base])
        let newest = try requireHome(MuseLoginFiles.chromeLogin(in: chrome))
        precondition(newest.signedInAt == base.addingTimeInterval(-3_600) && newest.isNewer(than: saved) && !saved.isNewer(than: newest),
                     "the newest muse.ai login across Default and Profile N: \(newest)")
        let copiesAfter = try files.contentsOfDirectory(atPath: files.temporaryDirectory.path).filter { $0.hasPrefix("cantrip-muse-login-") && !$0.contains("test") }
        precondition(Set(copiesAfter) == Set(copiesBefore), "the database copies are deleted")
        try files.removeItem(at: chrome.appendingPathComponent("Profile 2"))
        try files.removeItem(at: chrome.appendingPathComponent("System Profile"))

        // A watcher with this test's files, clock, status and export.
        let watcher = MuseLoginWatcher()
        watcher.directory = root
        watcher.savedCookies = cookies
        watcher.chromeSupport = chrome
        var clock = base
        watcher.now = { clock }
        var live = true
        watcher.isLive = { live }
        var current = MuseStatus(state: .connected)
        watcher.status = { current }
        var answers: [MuseStatus.State] = []
        var rechecks = 0
        watcher.recheck = {
            rechecks += 1
            current = MuseStatus(state: answers.isEmpty ? current.state : answers.removeFirst())
            return current
        }
        var exports = 0
        var outcome = MuseLoginExport.Outcome.saved
        var rejectAfterCopy = false
        watcher.export = {
            exports += 1
            await Task.yield()
            if outcome == .saved, let login = MuseLoginFiles.chromeLogin(in: chrome) {
                try? writeSaved(signedIn: login.signedInAt, value: "NEW-SECRET-VALUE")
                answers = [rejectAfterCopy ? .loginNeeded : .connected]
            }
            return outcome
        }
        var shown: [String] = []
        watcher.showSignIn = { shown.append($0) }
        var notices: [(title: String, body: String)] = []
        watcher.notify = { notices.append(($0, $1)) }
        watcher.macName = { "Test Mac" }
        watcher.isStarted = true
        watcher.load()

        // Chrome has a newer login than the saved one: copied right away, then checked.
        await watcher.tick()
        precondition(exports == 1 && rechecks == 1 && current.state == .connected && notices.isEmpty, "\(exports) \(rechecks) \(notices)")
        precondition(MuseLoginFiles.savedLogin(at: cookies)?.signedInAt == base.addingTimeInterval(-2 * day))
        precondition(log().contains("login: Chrome has a newer muse.ai login") && log().contains("login: copy saved")
                     && log().contains("login: connected with Chrome's login"), log())
        await watcher.tick()
        precondition(exports == 1, "the same login isn't copied again")

        // A turned-down login is checked again a few minutes later before anything happens…
        current = MuseStatus(state: .loginNeeded)
        await watcher.tick()
        precondition(exports == 0 + 1 && rechecks == 1 && notices.isEmpty && watcher.state.recheckAt == clock.addingTimeInterval(240))
        clock = clock.addingTimeInterval(100)
        await watcher.tick()
        precondition(rechecks == 1, "not before the recheck time")
        clock = clock.addingTimeInterval(150)
        answers = [.connected]
        await watcher.tick()
        precondition(rechecks == 2 && current.state == .connected && notices.isEmpty && shown.isEmpty, "a short failure recovers: nothing to do")
        // …and when it's still turned down and Chrome has nothing newer, the user is asked once.
        current = MuseStatus(state: .loginNeeded)
        await watcher.tick()
        clock = clock.addingTimeInterval(241)
        answers = [.loginNeeded]
        await watcher.tick()
        precondition(rechecks == 3 && exports == 1 && notices.count == 1 && notices[0].title == "Muse needs you to sign in"
                     && notices[0].body.contains("Sign in at muse.ai in Chrome on Test Mac; Cantrip copies the new login by itself."),
                     "\(notices)")
        precondition(shown.last?.contains("Chrome's muse.ai login is the one that ended") == true, "\(shown)")
        let waiting = try requireHome(watcher.upcomingItem(now: clock))
        precondition(waiting.kind == .reminder && waiting.state == .waiting && waiting.title == "Sign in to Muse in Chrome"
                     && waiting.cancelLabel == nil && waiting.json["kind"] as? String == "reminder")
        clock = clock.addingTimeInterval(3_600)
        await watcher.tick()
        await watcher.tick()
        precondition(rechecks == 3 && exports == 1 && notices.count == 1, "asked once; Muse isn't asked again while waiting")

        // The user signs in again in Chrome: copied, connected, and told it's fixed.
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        await watcher.tick()
        precondition(exports == 2 && current.state == .connected && notices.count == 2 && notices[1].title == "Muse is connected again",
                     "\(notices)")
        precondition(watcher.state.askedAt == nil && watcher.upcomingItem(now: clock)?.state == .scheduled)

        // Failure while the saved login still works: that Chrome login is blocked, the user isn't bothered…
        clock = clock.addingTimeInterval(3_600)
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        outcome = .keychain
        await watcher.tick()
        precondition(exports == 3 && notices.count == 2 && log().contains("kept the saved login, which still works"), log())
        clock = clock.addingTimeInterval(3 * 3_600)
        await watcher.tick()
        precondition(exports == 3, "no more copies until Chrome's login changes")
        // …and once the saved one ends, the user is asked with the reason.
        current = MuseStatus(state: .loginNeeded)
        await watcher.tick()
        clock = clock.addingTimeInterval(241)
        answers = [.loginNeeded]
        await watcher.tick()
        precondition(exports == 3 && notices.count == 3 && shown.last?.contains("Chrome Safe Storage") == true, "\(shown)")
        // Check Now tries the blocked login once more; a dialog nobody answers isn't retried on its own.
        outcome = .timedOut
        await watcher.tick(manual: true)
        precondition(exports == 4 && notices.count == 3)
        clock = clock.addingTimeInterval(6 * 3_600)
        await watcher.tick()
        precondition(exports == 4)
        // Copied, but muse.ai turns Chrome's login down too: blocked, and the user (already asked) waits.
        clock = clock.addingTimeInterval(day)
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        outcome = .saved
        rejectAfterCopy = true
        await watcher.tick()
        precondition(exports == 5 && current.state == .loginNeeded && notices.count == 3
                     && shown.last?.contains("turned Chrome's login down too") == true, "\(shown)")
        clock = clock.addingTimeInterval(11 * 60)
        await watcher.tick()
        precondition(exports == 5, "blocked")
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        rejectAfterCopy = false
        await watcher.tick()
        precondition(exports == 6 && current.state == .connected && notices.count == 4 && notices[3].title == "Muse is connected again")

        // Rate limit: a busy Chrome is tried again only after the interval, at most 4 a day, one at a time.
        clock = clock.addingTimeInterval(2 * day)
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        outcome = .busy
        async let first: Void = watcher.tick()
        async let second: Void = watcher.tick()
        _ = await (first, second)
        precondition(exports == 7, "one copy at a time: \(exports)")
        clock = clock.addingTimeInterval(5 * 60)
        await watcher.tick()
        precondition(exports == 7 && log().contains("next copy of Chrome's login waits until"))
        for _ in 0..<5 {
            clock = clock.addingTimeInterval(11 * 60)
            await watcher.tick()
        }
        precondition(exports == 10 && log().contains("4 copies in the last day; no more until Chrome's login changes"), "\(exports)")
        clock = clock.addingTimeInterval(day)
        await watcher.tick()
        precondition(exports == 10, "blocked until Chrome's login changes, even a day later")

        // The weekly reminder: listed in Upcoming, sent once a day before the login ends, then a check
        // once the week is up.
        outcome = .saved
        let signedIn = clock.addingTimeInterval(-60)
        try writeChrome(signedIn: [signedIn])
        await watcher.tick()
        precondition(exports == 11 && MuseLoginFiles.savedLogin(at: cookies)?.signedInAt == signedIn)
        let before = notices.count
        clock = signedIn.addingTimeInterval(5 * day)
        await watcher.tick()
        let reminder = try requireHome(watcher.upcomingItem(now: clock))
        precondition(reminder.id == "muse:login" && reminder.nextRunAt == signedIn.addingTimeInterval(6 * day)
                     && reminder.state == .scheduled && reminder.group == "next" && reminder.cancelLabel == "Skip"
                     && reminder.detail?.contains("Sign in at muse.ai in Chrome on Test Mac") == true && notices.count == before, "\(reminder)")
        clock = signedIn.addingTimeInterval(6 * day + 60)
        await watcher.tick()
        await watcher.tick()
        precondition(notices.count == before + 1 && notices.last?.title.hasPrefix("Sign in to Muse again by") == true
                     && notices.last?.body.contains("in Chrome on Test Mac") == true, "\(notices)")
        precondition(watcher.upcomingItem(now: clock)?.state == .waiting)
        let checks = rechecks
        clock = signedIn.addingTimeInterval(7 * day + 180)
        answers = [.connected]
        await watcher.tick()
        await watcher.tick()
        precondition(rechecks == checks + 1 && watcher.upcomingItem(now: clock) == nil, "one check once the week is up")
        // Skip: this login's reminder doesn't go out and leaves Upcoming.
        let next = clock.addingTimeInterval(-60)
        try writeChrome(signedIn: [next])
        await watcher.tick()
        precondition(watcher.upcomingItem(now: clock)?.nextRunAt == next.addingTimeInterval(6 * day))
        _ = try watcher.skipReminder()
        precondition(watcher.upcomingItem(now: clock) == nil)
        clock = next.addingTimeInterval(6 * day + 60)
        let skippedBefore = notices.count
        await watcher.tick()
        precondition(notices.count == skippedBefore, "skipped")

        // Off, or the demo: nothing at all.
        live = false
        let copied = exports
        try writeChrome(signedIn: [clock])
        await watcher.tick()
        precondition(exports == copied && watcher.upcomingItem(now: clock) == nil, "\(exports)")

        // Never a cookie value in the log or the saved state.
        let state = try String(contentsOf: watcher.stateURL, encoding: .utf8)
        for secret in ["SECRET", "ONE-TAP", "OTHER"] {
            precondition(!log().contains(secret) && !state.contains(secret), "no cookie values in logs: \(secret)")
        }
        let mode = try files.attributesOfItem(atPath: watcher.stateURL.path)[.posixPermissions] as? Int
        precondition(mode == 0o600)

        // The command: Chrome only (no browser window fallback), no update check, outcomes by message.
        precondition(MuseLoginExport.arguments() == ["-m", "muse_cli", "auth", "export", "--browser", "chrome"]
                     && MuseLoginExport.environment()["MUSE_NO_UPDATE_CHECK"] == "1" && MuseLoginExport.timeout > 120)
        typealias Export = MuseLoginExport
        precondition(Export.classify(status: 0, timedOut: false, message: "saved 9 muse.ai cookies") == .saved
                     && Export.classify(status: 1, timedOut: false, message: "cookie export failed: timed out waiting for the macOS keychain prompt") == .timedOut
                     && Export.classify(status: 1, timedOut: false, message: "cookie export failed: could not read 'Chrome Safe Storage' from the keychain (denied)") == .keychain
                     && Export.classify(status: 1, timedOut: false, message: "Chrome answered, but the cookies do not include a valid hatch_sess") == .noChromeLogin
                     && Export.classify(status: 1, timedOut: false, message: "cookie export failed: cookie database changed while reading x") == .busy
                     && Export.classify(status: 1, timedOut: true, message: "") == .timedOut
                     && Export.classify(status: 2, timedOut: false, message: "something else") == .failed)
        let slow = root.appendingPathComponent("slow-python")
        try "#!/bin/sh\nexec sleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        let started = Date()
        let slowOutcome = await MuseLoginExport.run(python: slow.path, timeout: 0.5)
        precondition(slowOutcome == .timedOut && Date().timeIntervalSince(started) < 10, "\(slowOutcome)")
        let denied = root.appendingPathComponent("denied-python")
        try "#!/bin/sh\necho \"cookie export failed: could not read 'Chrome Safe Storage' from the keychain (denied)\" >&2\nexit 1\n"
            .write(to: denied, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        let deniedOutcome = await MuseLoginExport.run(python: denied.path)
        let missingOutcome = await MuseLoginExport.run(python: root.appendingPathComponent("none").path)
        precondition(deniedOutcome == .keychain && missingOutcome == .notInstalled, "\(deniedOutcome) \(missingOutcome)")

        // Settings and clients say what to do now: sign in in Chrome; no Terminal.
        precondition(MuseStatus.loginSteps.contains("sign in at muse.ai in Chrome on") && !MuseStatus.loginSteps.contains("auth export"))
        print("Muse login: saved and Chrome logins, copy, recheck, failure, rate limit, reminder and export passed")
    }
}
