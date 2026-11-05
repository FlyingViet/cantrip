import Foundation

extension SessionTabTests {
    /// A finished run's preferences domain. A temporary HOME doesn't move preferences, so without
    /// this every run would leave its settings in ~/Library/Preferences. (cfprefsd may still write
    /// an empty plist for it a few seconds later; that holds nothing.)
    static func removeTestPreferences(domain: String) {
        // A binary's own name, never an app's reverse-DNS domain.
        guard !domain.isEmpty, !domain.contains(".") else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist"))
    }

    /// Tests and QA builds never reach Cantrip's real settings. A binary takes the bundle ID of a
    /// folder holding Info.plist or Resources/Info.plist, so a checkout holds neither; and a process
    /// with a bundle ID that isn't an app stops before it opens its settings.
    static func testSettingsIdentity() throws {
        precondition(Bundle.main.bundleIdentifier == nil, "this run has its own settings domain")
        // Cantrip.app's ID, from the plist its build ships.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let info = NSDictionary(contentsOf: repo.appendingPathComponent("Resources/Cantrip-Info.plist"))
        let id = try requireHome(info?["CFBundleIdentifier"] as? String)

        precondition(AppSettings.borrowedIdentityProblem(bundleIdentifier: id, bundlePath: "/Applications/Cantrip.app") == nil)
        precondition(AppSettings.borrowedIdentityProblem(bundleIdentifier: id, bundlePath: "/Users/me/Coding/Cantrip/Cantrip.app") == nil)
        precondition(AppSettings.borrowedIdentityProblem(bundleIdentifier: nil, bundlePath: "/tmp/tests") == nil)
        precondition(AppSettings.borrowedIdentityProblem(bundleIdentifier: "com.example.qa", bundlePath: "/tmp/qa.app") == nil)
        for (identifier, folder) in [(id, "/Users/me/Coding/Cantrip"), (id, "/Users/me/Coding/Cantrip/Resources"),
                                     (id, "/tmp/archive-copy"), ("com.example.other", "/tmp/other-checkout")] {
            let problem = AppSettings.borrowedIdentityProblem(bundleIdentifier: identifier, bundlePath: folder) ?? ""
            precondition(problem.contains(folder) && problem.contains(identifier) && problem.contains("real settings"), problem)
        }

        // What macOS reads as a bundle, with a stand-in ID: one Info.plist in Resources is enough.
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("bundle-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        try fm.createDirectory(at: probe.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.bundle-probe"] as NSDictionary)
            .write(to: probe.appendingPathComponent("Resources/Info.plist"))
        precondition(Bundle(path: probe.path)?.bundleIdentifier == "com.example.bundle-probe",
                     "a folder with Resources/Info.plist is a bundle")

        // The checkout isn't one.
        for path in ["Info.plist", "Resources/Info.plist", "Contents/Info.plist"] {
            precondition(!fm.fileExists(atPath: repo.appendingPathComponent(path).path),
                         "\(path) would give binaries run from a checkout Cantrip's settings")
        }
        precondition(Bundle(path: repo.path)?.bundleIdentifier == nil
                     && Bundle(path: repo.appendingPathComponent("Resources").path)?.bundleIdentifier == nil)
        print("Settings identity: test and QA builds stay out of Cantrip's real settings passed")
    }
}
