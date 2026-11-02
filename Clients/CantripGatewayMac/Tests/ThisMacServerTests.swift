import XCTest
@testable import Hermes

/// Cantrip's Home window plug-in: This Mac and other paired Macs (`ThisMacServer`).
@MainActor
final class ThisMacServerTests: XCTestCase {
    private final class Persisted {
        var values: [String: String] = [:]
        var store: ServerCredentialStore {
            ServerCredentialStore(read: { [self] in values[$0] },
                                  write: { [self] in values[$0] = $1 },
                                  remove: { [self] in values[$0] = nil })
        }
    }

    private struct Launch {
        let token: ThisMacToken
        let profiles: ServerProfiles
        let remote: CantripRemoteModel
    }

    private func defaults() throws -> UserDefaults {
        let suite = "ThisMacServerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// What the plug-in builds when Cantrip opens the window: memory for This Mac's token.
    private func launch(_ defaults: UserDefaults, _ persisted: Persisted) throws -> Launch {
        let token = ThisMacToken()
        let profiles = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: token.store(persistent: persisted.store))
        if !profiles.hasSavedState { try profiles.select(nil) }
        return Launch(token: token, profiles: profiles, remote: CantripRemoteModel(servers: profiles))
    }

    private func register(_ launch: Launch, _ defaults: UserDefaults, port: Int = 8765,
                          token: String = "local-token") throws -> ThisMacServer.Registration {
        try ThisMacServer.register(url: "http://127.0.0.1:\(port)", token: token, remote: launch.remote,
                                   local: launch.token, defaults: defaults)
    }

    func testThisMacsTokenStaysInMemoryWhileOtherMacsAreSaved() throws {
        let defaults = try defaults()
        let persisted = Persisted()
        let first = try launch(defaults, persisted)
        let registration = try register(first, defaults)
        XCTAssertEqual(first.remote.localServerID, registration.server.id)
        XCTAssertEqual(registration.server.name, ThisMacServer.name)
        XCTAssertEqual(try first.profiles.credential(for: registration.server), "local-token")
        XCTAssertTrue(persisted.values.isEmpty, "This Mac's token is never written to the Keychain")

        let studio = try first.profiles.add(ServerDraft(name: "Studio", url: "https://studio.example", credential: "studio-token"))
        XCTAssertEqual(Array(persisted.values.values), ["studio-token"])
        XCTAssertEqual(try first.profiles.credential(for: studio), "studio-token")
    }

    func testRelaunchKeepsThisMacsEntryAndTheMacPickedInSettings() throws {
        let defaults = try defaults()
        let persisted = Persisted()
        let first = try launch(defaults, persisted)
        let thisMac = try register(first, defaults).server
        let studio = try first.profiles.add(ServerDraft(name: "Studio", url: "https://studio.example", credential: "studio-token"))
        try first.profiles.select(studio)

        let second = try launch(defaults, persisted)
        XCTAssertTrue(second.profiles.isMissingCredential(thisMac), "Memory is empty until Cantrip hands the token over")
        let registration = try register(second, defaults)
        XCTAssertEqual(registration.server.id, thisMac.id, "Same entry, so its history stays")
        XCTAssertFalse(registration.replacedSelection)
        XCTAssertEqual(second.profiles.selectedID, studio.id, "Opening the window doesn't switch away from Studio")
        XCTAssertEqual(second.profiles.servers.map(\.id), [thisMac.id, studio.id])
        XCTAssertEqual(try second.profiles.credential(for: studio), "studio-token")
        XCTAssertThrowsError(try second.remote.removeServer(registration.server))
    }

    func testANewTokenKeepsTheEntryAndANewAddressReplacesIt() throws {
        let defaults = try defaults()
        let persisted = Persisted()
        let first = try launch(defaults, persisted)
        let original = try register(first, defaults).server
        try first.profiles.select(original)

        let rotated = try register(first, defaults, token: "rotated-token")
        XCTAssertEqual(rotated.server.id, original.id)
        XCTAssertEqual(try first.profiles.credential(for: original), "rotated-token")
        XCTAssertTrue(persisted.values.isEmpty)

        let moved = try register(first, defaults, port: 8766, token: "rotated-token")
        XCTAssertNotEqual(moved.server.id, original.id)
        XCTAssertTrue(moved.replacedSelection, "This Mac was in use, so the window switches to its new entry")
        XCTAssertEqual(first.profiles.servers.map(\.id), [moved.server.id])
        XCTAssertEqual(defaults.string(forKey: ThisMacServer.idKey), moved.server.id.uuidString)
    }

    func testThisMacFromOlderBuildsIsAdoptedNotDuplicated() throws {
        let defaults = try defaults()
        // Older builds saved This Mac without an ID marker and kept its token in memory only.
        let older = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: Persisted().store)
        let leftover = try older.add(ServerDraft(name: ThisMacServer.name, url: "http://127.0.0.1:8765",
                                                 credential: "local-token", tailscaleOnly: true))
        try older.select(leftover)

        let launch = try launch(defaults, Persisted())
        let registration = try register(launch, defaults)
        XCTAssertEqual(registration.server.id, leftover.id)
        XCTAssertEqual(launch.profiles.servers.count, 1)
        XCTAssertEqual(launch.profiles.selectedID, leftover.id)
    }
}
