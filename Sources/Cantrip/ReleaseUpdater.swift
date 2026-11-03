import CryptoKit
import Foundation
import Security

/// Updates a release install (`CantripInstall.isRelease`) from GitHub. The repository's Latest
/// release is the newest Cantrip, and its `Cantrip-X.Y.Z.dmg` holds the notarized app
/// (Scripts/release-mac.sh). Staging checks the image's checksum and the app's Developer ID
/// signature and notarization, then puts the app where `PendingUpdate` installs it on the next launch.
enum ReleaseUpdater {
    static let repository = "FlyingViet/cantrip"
    /// Release builds are signed by this Developer ID team, and staging accepts no other; the next
    /// launch checks the same requirement before installing (PendingUpdate).
    static var teamIdentifier: String { PendingUpdate.releaseTeamIdentifier }
    static func requirement(bundleIdentifier: String) -> String {
        PendingUpdate.releaseRequirement(bundleIdentifier: bundleIdentifier)
    }

    struct Release: Equatable {
        let tag: String
        let name: String
        let publishedAt: Date?
        let page: URL?
        let diskImage: URL?
        let checksum: URL?

        /// "1.1.16" for tag "v1.1.16".
        var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
        var diskImageName: String { "Cantrip-\(version).dmg" }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Finding the latest release

    static func parseLatest(_ data: Data) throws -> Release {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError("GitHub's answer didn't name a release.")
        }
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(tag: tag, name: (object["name"] as? String) ?? "Cantrip \(version)",
                       publishedAt: (object["published_at"] as? String).flatMap(CantripVersionReport.parseDate),
                       page: (object["html_url"] as? String).flatMap(URL.init(string:)),
                       diskImage: asset("Cantrip-\(version).dmg"),
                       checksum: asset("Cantrip-\(version).dmg.sha256"))
    }

    static func latest(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cantrip", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("GitHub answered \(status) for the latest release.") }
        return try parseLatest(data)
    }

    // MARK: - Staging

    /// Downloads `release`'s disk image, checks it and stages its app beside `app`. Returns the staged
    /// build's identity.
    static func stage(_ release: Release, app: URL = Bundle.main.bundleURL,
                      bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                      session: URLSession = .shared,
                      progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        guard let diskImage = release.diskImage, let checksumURL = release.checksum else {
            throw UpdateError("\(release.name) has no disk image to download yet.")
        }
        guard let bundleIdentifier else { throw UpdateError("This Cantrip has no bundle identifier.") }
        let fileManager = FileManager.default
        let folder = CantripPaths.cache("updates", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        progress("Downloading \(release.diskImageName)…")
        let (checksumData, checksumResponse) = try await session.data(from: checksumURL)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: checksumData, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
              expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw UpdateError("Couldn't read the checksum of \(release.diskImageName).")
        }
        let (download, response) = try await session.download(from: diskImage)
        let image = folder.appendingPathComponent(release.diskImageName)
        defer { try? fileManager.removeItem(at: image) }
        try? fileManager.removeItem(at: image)
        try fileManager.moveItem(at: download, to: image)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub didn't send \(release.diskImageName).")
        }
        guard try sha256(of: image) == expected else {
            throw UpdateError("\(release.diskImageName) doesn't match its checksum, so it wasn't used.")
        }

        progress("Checking \(release.name)…")
        let mount = folder.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = try? ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], timeout: 60)
            try? fileManager.removeItem(at: mount)
        }
        let attach = try ProcessRunner.run("/usr/bin/hdiutil",
                                           ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path],
                                           errorOutput: .merge, timeout: 120)
        guard attach.succeeded else { throw UpdateError("Couldn't open \(release.diskImageName): \(attach.text)") }
        let candidate = mount.appendingPathComponent("Cantrip.app", isDirectory: true)
        if let problem = problem(with: candidate, release: release, bundleIdentifier: bundleIdentifier) {
            throw UpdateError("\(release.name) wasn't used: \(problem)")
        }

        progress("Preparing \(release.name)…")
        let pending = PendingUpdate.pendingURL(for: app)
        let incoming = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).download", isDirectory: true)
        try? fileManager.removeItem(at: incoming)
        let copy = try ProcessRunner.run("/usr/bin/ditto", [candidate.path, incoming.path], errorOutput: .merge, timeout: 300)
        guard copy.succeeded else {
            try? fileManager.removeItem(at: incoming)
            throw UpdateError("Couldn't copy the new Cantrip next to \(app.lastPathComponent) (\(copy.text)). Download it from the release page instead.")
        }
        if let problem = problem(with: incoming, release: release, bundleIdentifier: bundleIdentifier) {
            try? fileManager.removeItem(at: incoming)
            throw UpdateError("The copied app failed its check: \(problem)")
        }
        try? fileManager.removeItem(at: pending)
        try fileManager.moveItem(at: incoming, to: pending)
        Log.write("update: staged \(release.tag) from \(release.diskImageName)")
        return release.tag
    }

    /// Why `bundle` isn't `release`'s notarized Cantrip, or nil when it is.
    static func problem(with bundle: URL, release: Release, bundleIdentifier: String) -> String? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else {
            return "the disk image has no Cantrip.app"
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { return "it isn't Cantrip" }
        guard info["CantripBuildIdentity"] as? String == release.tag else {
            return "it's build \(info["CantripBuildIdentity"] as? String ?? "unknown"), not \(release.tag)"
        }
        return signatureProblem(bundle, requirement: requirement(bundleIdentifier: bundleIdentifier))
    }

    static func signatureProblem(_ bundle: URL, requirement text: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return "its signature can't be read"
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return "the signing requirement is invalid"
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
            | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        switch status {
        case errSecSuccess: return nil
        case errSecCSReqFailed: return "it isn't signed and notarized by Cantrip's developer"
        default: return "its signature is invalid (\(status))"
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
