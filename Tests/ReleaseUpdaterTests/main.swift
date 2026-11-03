import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// MARK: GitHub's latest release

do {
    let json = """
    {"tag_name": "v1.1.16", "name": "Cantrip 1.1.16", "published_at": "2026-11-03T02:00:00Z",
     "html_url": "https://github.com/FlyingViet/cantrip/releases/tag/v1.1.16",
     "assets": [{"name": "Cantrip-1.1.16.dmg", "browser_download_url": "https://example.invalid/Cantrip-1.1.16.dmg"},
                {"name": "Cantrip-1.1.16.dmg.sha256", "browser_download_url": "https://example.invalid/Cantrip-1.1.16.dmg.sha256"},
                {"name": "CantripGatewayMac-1.2.14.dmg", "browser_download_url": "https://example.invalid/gw.dmg"}]}
    """
    let release = try ReleaseUpdater.parseLatest(Data(json.utf8))
    expect(release.tag == "v1.1.16" && release.version == "1.1.16", "tag and version: \(release.tag)")
    expect(release.name == "Cantrip 1.1.16" && release.publishedAt != nil, "name and date")
    expect(release.diskImage?.lastPathComponent == "Cantrip-1.1.16.dmg", "the release's own disk image")
    expect(release.checksum?.lastPathComponent == "Cantrip-1.1.16.dmg.sha256", "its checksum")
    let bare = try ReleaseUpdater.parseLatest(Data(#"{"tag_name": "v1.1.15", "assets": []}"#.utf8))
    expect(bare.diskImage == nil && bare.checksum == nil && bare.name == "Cantrip 1.1.15", "a release without a disk image")
    expect((try? ReleaseUpdater.parseLatest(Data(#"{"message": "Not Found"}"#.utf8))) == nil, "an answer without a tag fails")
} catch {
    expect(false, "parsing threw \(error)")
}

// MARK: Checksums

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory.appendingPathComponent("release-updater-\(UUID().uuidString)")
try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }
do {
    let file = root.appendingPathComponent("abc")
    try Data("abc".utf8).write(to: file)
    let digest = try ReleaseUpdater.sha256(of: file)
    expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")
} catch {
    expect(false, "checksum threw \(error)")
}

// MARK: Only Cantrip's notarized Developer ID build is staged

let release = ReleaseUpdater.Release(tag: "v1.1.16", name: "Cantrip 1.1.16", publishedAt: nil, page: nil,
                                     diskImage: nil, checksum: nil)
func bundle(_ name: String, info: [String: String]?) -> URL {
    let app = root.appendingPathComponent(name)
    try? fileManager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    if let info {
        var plist: [String: String] = ["CFBundleExecutable": "Cantrip", "CFBundlePackageType": "APPL"]
        plist.merge(info) { $1 }
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
    try? fileManager.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Cantrip").path)
    return app
}
let id = "com.brian.agentspotlight"
expect(ReleaseUpdater.problem(with: bundle("Empty.app", info: nil), release: release, bundleIdentifier: id)
       == "the disk image has no Cantrip.app", "no app")
expect(ReleaseUpdater.problem(with: bundle("Other.app", info: ["CFBundleIdentifier": "com.example.other",
                                                                "CantripBuildIdentity": "v1.1.16"]),
                              release: release, bundleIdentifier: id) == "it isn't Cantrip", "another app")
expect(ReleaseUpdater.problem(with: bundle("Old.app", info: ["CFBundleIdentifier": id, "CantripBuildIdentity": "v1.1.14"]),
                              release: release, bundleIdentifier: id) == "it's build v1.1.14, not v1.1.16", "another build")
let adHoc = bundle("AdHoc.app", info: ["CFBundleIdentifier": id, "CantripBuildIdentity": "v1.1.16"])
let signed = try? ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", id, adHoc.path], timeout: 60)
expect(signed?.succeeded == true, "ad-hoc signing the fixture")
expect(ReleaseUpdater.problem(with: adHoc, release: release, bundleIdentifier: id)
       == "it isn't signed and notarized by Cantrip's developer", "an ad-hoc build is refused")

// A real release image, when given: CANTRIP_RELEASE_DMG=path/Cantrip-X.dmg (its app's build identity is the tag).
if let path = ProcessInfo.processInfo.environment["CANTRIP_RELEASE_DMG"] {
    let mount = root.appendingPathComponent("mount")
    try? fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
    let attach = try? ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, path],
                                        errorOutput: .merge, timeout: 120)
    expect(attach?.succeeded == true, "mounting \(path)")
    let app = mount.appendingPathComponent("Cantrip.app")
    let identity = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CantripBuildIdentity"] as? String ?? ""
    let real = ReleaseUpdater.Release(tag: identity, name: "Cantrip", publishedAt: nil, page: nil, diskImage: nil, checksum: nil)
    let problem = ReleaseUpdater.problem(with: app, release: real, bundleIdentifier: id)
    expect(problem == nil, "the notarized release passes: \(problem ?? "")")
    _ = try? ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], timeout: 60)
    print("Checked the release image \(path)")
}

if failures == 0 {
    print("Release updater tests passed")
} else {
    exit(1)
}
