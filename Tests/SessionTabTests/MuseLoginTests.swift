import Foundation
import SQLite3

extension SessionTabTests {
    /// Keeping Muse signed in: reading the saved and Chrome's logins (times only), copying a newer
    /// Chrome login, rechecking a turned-down login before acting, signing in again through Chrome's
    /// remembered account and the View Mac fallback, the failure path, rate limits, the Upcoming item,
    /// what the sign-in may press, and the export command.
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

        // A watcher with this test's files, clock, status, export and Chrome sign-in.
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
        // Chrome's sign-in: pressing Continue makes Chrome a new login, unless the page needs the user.
        var signIns: [String] = []
        var signInResult = MuseChromeSignIn.Outcome.signedIn
        watcher.chromeSignIn = { profile, signedIn in
            signIns.append(profile)
            if signInResult == .signedIn {
                try? writeChrome(signedIn: [clock.addingTimeInterval(-5)])
                precondition(signedIn(), "the sign-in sees Chrome's new login")
            } else {
                precondition(!signedIn())
            }
            return signInResult
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

        // A turned-down login during its week is checked again a few minutes later before anything happens…
        current = MuseStatus(state: .loginNeeded)
        await watcher.tick()
        precondition(exports == 1 && rechecks == 1 && signIns.isEmpty && watcher.state.recheckAt == clock.addingTimeInterval(240))
        clock = clock.addingTimeInterval(100)
        await watcher.tick()
        precondition(rechecks == 1, "not before the recheck time")
        clock = clock.addingTimeInterval(150)
        answers = [.connected]
        await watcher.tick()
        precondition(rechecks == 2 && current.state == .connected && signIns.isEmpty && notices.isEmpty, "a short failure recovers")
        // …and when it's still turned down, Cantrip signs in again through Chrome and copies that: the user does nothing.
        current = MuseStatus(state: .loginNeeded)
        await watcher.tick()
        clock = clock.addingTimeInterval(241)
        answers = [.loginNeeded]
        await watcher.tick()
        precondition(rechecks == 4 && signIns == ["Default"] && exports == 2 && current.state == .connected && notices.isEmpty,
                     "\(rechecks) \(signIns) \(exports) \(current) \(notices)")
        precondition(log().contains("login: signing in again through Chrome's remembered account (muse.ai ended the login)"), log())
        let signedIn = try requireHome(MuseLoginFiles.savedLogin(at: cookies)).signedInAt
        precondition(signedIn == clock.addingTimeInterval(-5))

        // Upcoming lists the next sign-in: when the login's week is up.
        let next = try requireHome(watcher.upcomingItem(now: clock))
        precondition(next.id == "muse:login" && next.kind == .reminder && next.state == .scheduled && next.group == "next"
                     && next.nextRunAt == signedIn.addingTimeInterval(7 * day + 120) && next.cancelLabel == nil
                     && next.detail?.contains("in Chrome on Test Mac") == true && next.json["kind"] as? String == "reminder", "\(next)")

        // The week is up: checked once, and the ended login is signed in again at once (no recheck wait).
        // Here the page asks for a password, so the user gets one push to tap through View Mac.
        clock = signedIn.addingTimeInterval(7 * day + 121)
        answers = [.loginNeeded]
        signInResult = .needsYou("the sign-in asks for your password")
        await watcher.tick()
        precondition(rechecks == 5 && current.state == .loginNeeded && watcher.upcomingItem(now: clock) == nil, "probed once")
        await watcher.tick()
        precondition(signIns.count == 2 && rechecks == 5 && notices.count == 1 && notices[0].title == "Muse needs one tap"
                     && notices[0].body.contains("open View Mac in the Cantrip app and tap Continue")
                     && notices[0].body.contains("asks for your password"), "\(notices)")
        precondition(shown.last?.contains("muse.ai is open in Chrome on Test Mac") == true, "\(shown)")
        let waiting = try requireHome(watcher.upcomingItem(now: clock))
        precondition(waiting.state == .waiting && waiting.title == "Muse needs one tap in Chrome" && waiting.cancelLabel == nil)
        clock = clock.addingTimeInterval(3_600)
        await watcher.tick()
        await watcher.tick()
        precondition(signIns.count == 2 && rechecks == 5 && notices.count == 1, "asked once; Muse isn't asked again while waiting")
        // The user taps Continue: Chrome's new login is copied, and they're told it's fixed.
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        await watcher.tick()
        precondition(exports == 3 && current.state == .connected && notices.count == 2 && notices[1].title == "Muse is connected again")
        precondition(watcher.state.askedAt == nil)

        // Another ended login: signed in again through Chrome…
        func endLogin() async {
            current = MuseStatus(state: .loginNeeded)
            await watcher.tick()
            clock = clock.addingTimeInterval(241)
            answers = [.loginNeeded]
            await watcher.tick()
        }
        signInResult = .signedIn
        clock = clock.addingTimeInterval(600)
        await endLogin()
        precondition(signIns.count == 3 && exports == 4 && current.state == .connected && notices.count == 2, "\(signIns) \(exports) \(current.state) \(notices.count)\n\(log().suffix(1800))")
        // …but one more within 30 minutes goes to the user instead, and Check Now tries anyway.
        clock = clock.addingTimeInterval(300)
        await endLogin()
        precondition(signIns.count == 3 && notices.count == 3 && notices[2].title == "Muse needs one tap"
                     && log().contains("not signing in through Chrome again so soon"), "\(notices.map(\.title))")
        await watcher.tick(manual: true)
        precondition(signIns.count == 4 && exports == 5 && current.state == .connected && notices.count == 4
                     && notices[3].title == "Muse is connected again", "\(signIns) \(exports) \(notices.map(\.title))")

        // No Accessibility (or no Chrome): the user is asked to sign in at muse.ai in Chrome themselves.
        clock = clock.addingTimeInterval(day)
        signInResult = .unavailable("Cantrip doesn't have Accessibility access on this Mac")
        await endLogin()
        precondition(signIns.count == 5 && notices.count == 5 && notices[4].title == "Muse needs you to sign in"
                     && notices[4].body.contains("Sign in at muse.ai in Chrome on Test Mac")
                     && notices[4].body.contains("Accessibility"), "\(notices.last!)")
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        await watcher.tick()
        precondition(exports == 6 && current.state == .connected && notices.count == 6)
        signInResult = .signedIn

        // A copy that fails while the saved login still works: that Chrome login is blocked, nobody is bothered.
        clock = clock.addingTimeInterval(3_600)
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        outcome = .keychain
        await watcher.tick()
        precondition(exports == 7 && notices.count == 6 && log().contains("kept the saved login, which still works"), log())
        clock = clock.addingTimeInterval(3 * 3_600)
        await watcher.tick()
        precondition(exports == 7, "no more copies until Chrome's login changes")
        // Check Now tries the blocked login once more; a dialog nobody answers isn't retried on its own.
        outcome = .timedOut
        await watcher.tick(manual: true)
        precondition(exports == 8 && notices.count == 6)
        clock = clock.addingTimeInterval(6 * 3_600)
        await watcher.tick()
        precondition(exports == 8)

        // Copied, but muse.ai turns Chrome's login down too (Chrome's own login ended): Chrome signs in again.
        outcome = .saved
        rejectAfterCopy = true
        clock = clock.addingTimeInterval(day)
        try writeChrome(signedIn: [clock.addingTimeInterval(-600)])
        let previous = watcher.chromeSignIn
        watcher.chromeSignIn = { profile, signedIn in
            rejectAfterCopy = false
            return await previous(profile, signedIn)
        }
        await watcher.tick()
        precondition(exports == 10 && signIns.count == 6 && current.state == .connected && notices.count == 6
                     && log().contains("muse.ai turned Chrome's login down too"), "\(exports) \(signIns.count) \(current)")
        watcher.chromeSignIn = previous

        // Copy rate limit: a busy Chrome is tried again only after the interval, at most 4 a day, one at a time.
        clock = clock.addingTimeInterval(2 * day)
        try writeChrome(signedIn: [clock.addingTimeInterval(-60)])
        outcome = .busy
        async let first: Void = watcher.tick()
        async let second: Void = watcher.tick()
        _ = await (first, second)
        precondition(exports == 11, "one copy at a time: \(exports)")
        clock = clock.addingTimeInterval(5 * 60)
        await watcher.tick()
        precondition(exports == 11 && log().contains("next copy of Chrome's login waits until"))
        for _ in 0..<5 {
            clock = clock.addingTimeInterval(11 * 60)
            await watcher.tick()
        }
        precondition(exports == 14 && log().contains("4 copies in the last day; no more until Chrome's login changes"), "\(exports)")
        clock = clock.addingTimeInterval(day)
        await watcher.tick()
        precondition(exports == 14, "blocked until Chrome's login changes, even a day later")

        // Off, or the demo: nothing at all.
        live = false
        outcome = .saved
        try writeChrome(signedIn: [clock])
        await watcher.tick()
        precondition(exports == 14 && watcher.upcomingItem(now: clock) == nil, "\(exports)")

        // What the sign-in may press: only a remembered-account button; never with a password or code asked.
        typealias Page = MuseSignInPage
        typealias El = MuseSignInPage.Element
        let landing = [El(role: "AXTextField", label: "", placeholder: "Mobile number or email"), El(role: "AXButton", label: "Continue"),
                       El(role: "AXButton", label: "Log in")]
        precondition(Page.step(host: "muse.ai", elements: landing) == .wait, "a signed-out page: nothing to press")
        let oneTap = [El(role: "AXImage", label: "Alex"), El(role: "AXLink", label: "Use another account"),
                      El(role: "AXButton", label: "Continue as Alex Doe")]
        precondition(Page.step(host: "muse.ai", elements: oneTap) == .press(2) && Page.step(host: "auth.meta.com", elements: oneTap) == .press(2))
        precondition(Page.step(host: "evil.example", elements: oneTap) == .wait && Page.step(host: "muse.ai.evil.example", elements: oneTap) == .wait,
                     "only muse.ai and auth.meta.com")
        precondition(Page.step(host: "auth.meta.com", elements: [El(role: "AXButton", label: "Continue")]) == .press(0)
                     && Page.step(host: "muse.ai", elements: [El(role: "AXButton", label: "Continue")]) == .wait,
                     "a lone Continue only on Meta's account page, with nothing to fill in")
        precondition(Page.step(host: "auth.meta.com", elements: [El(role: "AXTextField", subrole: "AXSecureTextField", label: ""),
                                                                El(role: "AXButton", label: "Continue as Alex")])
                     == .needsYou("the sign-in asks for your password"))
        precondition(Page.step(host: "auth.meta.com", elements: [El(role: "AXTextField", label: "Enter code", placeholder: "6-digit code"),
                                                                El(role: "AXButton", label: "Continue")])
                     == .needsYou("the sign-in asks for a code"))
        precondition(Page.step(host: "muse.ai", elements: [El(role: "AXButton", label: "Continue as another account")]) == .wait)
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
        print("Muse login: saved and Chrome logins, copy, recheck, Chrome sign-in and its fallback, failure, rate limits, Upcoming and export passed")
    }
}
