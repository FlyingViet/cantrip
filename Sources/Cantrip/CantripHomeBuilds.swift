import CryptoKit
import Foundation

/// A read-only index of the Mac's private over-the-air install page (`~/Sites/ota`, written by
/// `~/.hermes/scripts/ota-publish.py`) for Cantrip Home's Builds tab. Each published build is
/// `apps/<bundle id>/<version>-<build>-<timestamp>/` with `meta.json`, `manifest.plist`,
/// `app.ipa` and an optional `icon.png`. Entries group by `page_key` (else bundle id), newest
/// first, exactly like the page itself. Install links come from each build's own manifest, so
/// the page's address is never configured here.
struct CantripHomeOTABuild: Encodable, Equatable {
    /// `<bundle directory>/<build directory>`; also addresses the build's icon.
    let id: String
    let bundleID: String
    let title: String
    let version: String
    let build: String
    let note: String?
    let hasIcon: Bool
    let size: Int64?
    let sizeLabel: String?
    let profileName: String?
    let profileKind: String?
    let profileExpires: String?
    let publishedAt: Date
    let publishedLabel: String?
    let sourceCommit: String?
    let manifestURL: String
    let installURL: String
}

struct CantripHomeOTAApp: Encodable, Equatable {
    /// The page key the builds share.
    let id: String
    let title: String
    let bundleID: String
    /// Newest first; the first is the page's primary Install.
    let builds: [CantripHomeOTABuild]
}

struct CantripHomeOTASnapshot: Encodable {
    let apps: [CantripHomeOTAApp]
    /// The install page itself, for opening it in Safari; nil when nothing is published.
    let pageURL: String?
    /// False when the Mac has no install page folder at all.
    let available: Bool
    /// Build folders that could not be listed (unreadable or incomplete metadata).
    let skipped: Int
    let revision: String
}

enum CantripHomeOTABuilds {
    static let maximumMetadataBytes = 64 * 1024
    static let maximumIconBytes = 2 * 1024 * 1024

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sites/ota", isDirectory: true)
    }

    static func snapshot(root: URL = defaultRoot) -> CantripHomeOTASnapshot {
        let apps = root.appendingPathComponent("apps", isDirectory: true)
        guard isDirectory(root), isDirectory(apps) else {
            return CantripHomeOTASnapshot(
                apps: [], pageURL: nil, available: false, skipped: 0, revision: revision(of: [])
            )
        }
        var builds: [(key: String, build: CantripHomeOTABuild, base: String)] = []
        var skipped = 0
        for bundle in children(of: apps) where isDirectory(apps.appendingPathComponent(bundle)) {
            let bundleDirectory = apps.appendingPathComponent(bundle, isDirectory: true)
            for folder in children(of: bundleDirectory)
            where isDirectory(bundleDirectory.appendingPathComponent(folder)) {
                if let entry = build(bundle: bundle, folder: folder, root: root) {
                    builds.append(entry)
                } else {
                    skipped += 1
                }
            }
        }
        builds.sort {
            $0.build.publishedAt != $1.build.publishedAt
                ? $0.build.publishedAt > $1.build.publishedAt : $0.build.id > $1.build.id
        }
        var order: [String] = []
        var grouped: [String: [CantripHomeOTABuild]] = [:]
        for entry in builds {
            if grouped[entry.key] == nil { order.append(entry.key) }
            grouped[entry.key, default: []].append(entry.build)
        }
        let listed = order.compactMap { key -> CantripHomeOTAApp? in
            guard let builds = grouped[key], let newest = builds.first else { return nil }
            return CantripHomeOTAApp(id: key, title: newest.title, bundleID: newest.bundleID, builds: builds)
        }
        // The page most builds were published to (all of them, normally); ties go to the newest.
        let counts = Dictionary(builds.map { ($0.base, 1) }, uniquingKeysWith: +)
        let pageURL = counts.values.max()
            .flatMap { most in builds.first { counts[$0.base] == most } }
            .map { $0.base + "/" }
        return CantripHomeOTASnapshot(
            apps: listed, pageURL: pageURL, available: true,
            skipped: skipped, revision: revision(of: listed)
        )
    }

    /// The PNG icon of one listed build; nil when it has none.
    static func iconData(id: String, root: URL = defaultRoot) -> Data? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(isSafeComponent) else { return nil }
        let folder = root.appendingPathComponent("apps", isDirectory: true)
            .appendingPathComponent(parts[0], isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: true)
        guard isDirectory(root), isDirectory(root.appendingPathComponent("apps")),
              isDirectory(folder.deletingLastPathComponent()), isDirectory(folder),
              let data = regularFile(folder.appendingPathComponent("icon.png"), limit: maximumIconBytes),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        return data
    }

    // MARK: - Reading one build

    private static func build(
        bundle: String, folder: String, root: URL
    ) -> (key: String, build: CantripHomeOTABuild, base: String)? {
        let directory = root.appendingPathComponent("apps/\(bundle)/\(folder)", isDirectory: true)
        let relative = "apps/\(bundle)/\(folder)"
        guard let metaData = regularFile(directory.appendingPathComponent("meta.json"), limit: maximumMetadataBytes),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
              let bundleID = text(meta["bundle_id"]), let title = text(meta["title"]),
              let version = text(meta["version"]), let build = text(meta["build"]),
              let publishedText = text(meta["published_at"]), let published = date(publishedText),
              isRegularFile(directory.appendingPathComponent("app.ipa")),
              let manifest = manifestURL(in: directory, relative: relative) else { return nil }
        let hasIcon = (meta["icon"] as? Bool) == true && isRegularFile(directory.appendingPathComponent("icon.png"))
        let entry = CantripHomeOTABuild(
            id: "\(bundle)/\(folder)", bundleID: bundleID, title: title, version: version, build: build,
            note: text(meta["note"]), hasIcon: hasIcon,
            size: (meta["size"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.int64Value },
            sizeLabel: text(meta["size_label"]), profileName: text(meta["profile_name"]),
            profileKind: text(meta["profile_kind"]), profileExpires: text(meta["profile_expires"]),
            publishedAt: published, publishedLabel: text(meta["published_label"]),
            sourceCommit: text(meta["source_commit"]), manifestURL: manifest.url,
            installURL: "itms-services://?action=download-manifest&url="
                + (manifest.url.addingPercentEncoding(withAllowedCharacters: unreserved) ?? manifest.url)
        )
        return (text(meta["page_key"]) ?? bundleID, entry, manifest.base)
    }

    /// The build's https manifest address, derived from the package URL its manifest already
    /// carries (`<page>/apps/<bundle>/<folder>/app.ipa`), and the page address before `/apps/`.
    private static func manifestURL(in directory: URL, relative: String) -> (url: String, base: String)? {
        guard let data = regularFile(directory.appendingPathComponent("manifest.plist"), limit: maximumMetadataBytes),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let items = plist["items"] as? [[String: Any]], let assets = items.first?["assets"] as? [[String: Any]],
              let package = assets.first(where: { $0["kind"] as? String == "software-package" })?["url"] as? String,
              let components = URLComponents(string: package), components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        let suffix = "/\(relative)/app.ipa"
        guard package.hasSuffix(suffix) else { return nil }
        let base = String(package.dropLast(suffix.count))
        guard let baseComponents = URLComponents(string: base), baseComponents.host == components.host else { return nil }
        return (base + "/\(relative)/manifest.plist", base)
    }

    // MARK: - File guards

    /// Bundle ids and the publisher's `<version>-<build>-<timestamp>` folders.
    static func isSafeComponent(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 200,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0)) }
    }

    private static func children(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(isSafeComponent).sorted()
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    /// A real directory, never a symlink to one elsewhere.
    private static func isDirectory(_ url: URL) -> Bool {
        attributes(url)?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        attributes(url)?[.type] as? FileAttributeType == .typeRegular
    }

    /// The bytes of a regular, non-symlinked file no larger than `limit`.
    private static func regularFile(_ url: URL, limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= off_t(limit),
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// RFC 3986 unreserved characters: the publisher percent-encodes everything else.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func revision(of apps: [CantripHomeOTAApp]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(apps)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
