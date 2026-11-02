import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@testable import Hermes

private final class ProfileRequestProtocol: URLProtocol {
    @MainActor static var handler: ((ProfileRequestProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                try XCTUnwrap(Self.handler)(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    func respond(title: String) throws {
        var data = Data("""
        {"session":{"id":"shared-id","title":"\(title)","workdir":"/tmp",
        "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,
        "messages":[{"id":"reply","role":"assistant","text":"\(title) reply",
        "thinking":"","activities":[]}]}}
        """.utf8)
        if request.httpMethod == "GET", request.url?.path == "/api/v1/sessions" {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            data = try JSONSerialization.data(withJSONObject: ["sessions": [try XCTUnwrap(object["session"])]])
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class ProfileCredentials {
    var values: [String: String] = [:]
    var failing = false
    var store: ServerCredentialStore {
        ServerCredentialStore(
            read: { [self] in
                if failing { throw ServerConfigurationError(message: "Keychain unavailable") }
                return values[$0]
            },
            write: { [self] in
                if failing { throw ServerConfigurationError(message: "Keychain unavailable") }
                values[$0] = $1
            },
            remove: { [self] in
                if failing { throw ServerConfigurationError(message: "Keychain unavailable") }
                values[$0] = nil
            }
        )
    }
}

@MainActor
final class ServerProfilesTests: XCTestCase {
    private func fixture(_ kind: ServerKind) throws -> (ServerProfiles, UserDefaults, ProfileCredentials) {
        let suite = "ServerProfilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let credentials = ProfileCredentials()
        return (ServerProfiles(kind: kind, defaults: defaults, credentials: credentials.store), defaults, credentials)
    }

    private func preserveLegacyConfiguration() throws {
        let keys = [
            "hermes.baseURL", "hermes.executionLane", "cantrip.remote.base-url",
            "cantrip.remote.tailscale-only"
        ]
        let values = keys.map { UserDefaults.standard.object(forKey: $0) }
        let accounts = ["hermes.apiKey", "cantrip.remote.pairing-token"]
        let secrets = try accounts.map(Keychain.loadCredential)
        addTeardownBlock { @MainActor in
            for (key, value) in zip(keys, values) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            for (account, secret) in zip(accounts, secrets) {
                if let secret { try Keychain.saveCredential(secret, for: account) }
                else { try Keychain.deleteCredential(account) }
            }
            ProfileRequestProtocol.handler = nil
        }
    }

    private func draft(_ name: String, url: String? = nil) -> ServerDraft {
        ServerDraft(name: name, url: url ?? "https://\(name.lowercased()).example",
                    credential: "\(name)-test-credential")
    }

    func testAddingPersistsSelectableServersWithoutChangingSelectionOrStoringSecretsInDefaults() throws {
        let (store, defaults, credentials) = try fixture(.hermes)
        let a = try store.add(draft("Home"))
        XCTAssertNil(store.selectedID, "Adding is separate from connecting")
        try store.select(a)
        let b = try store.add(draft("Work"))
        XCTAssertEqual(store.selectedID, a.id)
        let restored = ServerProfiles(kind: .hermes, defaults: defaults, credentials: credentials.store)
        XCTAssertEqual(restored.servers, [a, b])
        XCTAssertEqual(restored.selectedID, a.id)
        XCTAssertEqual(try restored.credential(for: a), "Home-test-credential")
        XCTAssertEqual(try restored.credential(for: b), "Work-test-credential")
        let persisted = try XCTUnwrap(defaults.data(forKey: "hermes.saved-servers.v1"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("test-credential"))
        try restored.select(b)
        XCTAssertEqual(restored.selectedID, b.id)
    }

    func testSuccessfulAddClearsEveryFieldAndFailureKeepsTheDraft() async throws {
        let (store, _, credentials) = try fixture(.cantrip)
        let form = ServerFormModel()
        form.draft = ServerDraft(name: "Home", url: "home.example", credential: "test-token", tailscaleOnly: true)
        await form.save { try store.add($0) }
        XCTAssertTrue(form.saved)
        XCTAssertNil(form.error)
        XCTAssertEqual(form.draft, ServerDraft())
        XCTAssertFalse(form.saving)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertNil(store.selectedID)

        form.draft = draft("Work")
        let entered = form.draft
        credentials.failing = true
        await form.save { try store.add($0) }
        XCTAssertEqual(form.draft, entered)
        XCTAssertEqual(form.error, "Keychain unavailable")
        XCTAssertFalse(form.saved)
        XCTAssertEqual(store.servers.count, 1)
        credentials.failing = false
        await form.save { try store.add($0) }
        XCTAssertEqual(form.draft, ServerDraft())
        XCTAssertEqual(store.servers.count, 2)
    }

    func testInvalidAndDuplicateEntriesDoNotClearTheFormOrReplaceServers() async throws {
        for kind in [ServerKind.hermes, .cantrip] {
            let (store, _, _) = try fixture(kind)
            let form = ServerFormModel()
            let original = ServerDraft(name: "Home", url: "https://HOME.example:443/", credential: "test-token")
            form.draft = original
            await form.save { try store.add($0) }
            let server = try XCTUnwrap(store.servers.first)
            XCTAssertEqual(server.url, "https://home.example")
            try store.select(server)
            form.draft = ServerDraft(name: "Again", url: "https://home.example", credential: "test-token")
            await form.save { try store.add($0) }
            XCTAssertNotNil(form.error)
            XCTAssertEqual(form.draft.name, "Again")
            XCTAssertEqual(store.servers, [server])
            XCTAssertEqual(store.selectedID, server.id)
            form.draft.url = "http://192.168.0.10"
            await form.save { try store.add($0) }
            XCTAssertNotNil(form.error)
            XCTAssertFalse(form.draft.url.isEmpty)
            XCTAssertEqual(store.servers.count, 1)
        }
    }

    func testReaddingAServerWhoseCredentialIsMissingRepairsItInsteadOfFailing() throws {
        for kind in [ServerKind.hermes, .cantrip] {
            let (store, defaults, _) = try fixture(kind)
            let home = try store.add(ServerDraft(name: "Home", url: "https://home.example",
                                                 credential: "old-token", tailscaleOnly: kind == .cantrip))
            let work = try store.add(draft("Work"))
            try store.select(home)
            // A new or restored device gets the saved list, but not Keychain items from the old one.
            let newDevice = ProfileCredentials()
            let restored = ServerProfiles(kind: kind, defaults: defaults, credentials: newDevice.store)
            XCTAssertNil(try restored.storedCredential(for: home))
            XCTAssertThrowsError(try restored.credential(for: home))

            let repaired = try restored.add(ServerDraft(url: "https://HOME.example/", credential: " new-token \n",
                                                        tailscaleOnly: kind == .cantrip))
            XCTAssertEqual(repaired, home, "The saved entry keeps its ID, name and routes")
            XCTAssertEqual(restored.servers, [home, work], "Nothing is duplicated")
            XCTAssertEqual(restored.selectedID, home.id)
            XCTAssertEqual(try restored.credential(for: home), "new-token")
            XCTAssertNil(try restored.storedCredential(for: work), "Only the matching entry is repaired")
            XCTAssertThrowsError(try restored.add(ServerDraft(url: "https://home.example", credential: "new-token")),
                                 "Once repaired, the same server and token is a duplicate again")

            let renamed = try restored.add(ServerDraft(name: "Office", url: work.url, credential: "work-token"))
            XCTAssertEqual(renamed.id, work.id)
            XCTAssertEqual(renamed.name, "Office")
            XCTAssertEqual(newDevice.values.count, 2)
            let reopened = ServerProfiles(kind: kind, defaults: defaults, credentials: newDevice.store)
            XCTAssertEqual(reopened.servers, [home, renamed])
            XCTAssertEqual(reopened.selectedID, home.id)
            XCTAssertEqual(try reopened.credential(for: renamed), "work-token")
        }
    }

    func testReaddingTheSelectedMacOnANewDeviceLetsItConnect() async throws {
        try preserveLegacyConfiguration()
        let (store, defaults, _) = try fixture(.cantrip)
        let home = try store.add(draft("Home"))
        try store.select(home)
        let restored = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: ProfileCredentials().store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: config), servers: restored)
        defer { model.setAppActive(false) }
        XCTAssertFalse(model.hasConfiguration)
        XCTAssertNotNil(model.errorMessage)

        try model.addServer(ServerDraft(name: "Home", url: home.url, credential: "Home-new-token"))
        XCTAssertEqual(restored.servers, [home])
        ProfileRequestProtocol.handler = { transport in
            XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"), "Bearer Home-new-token")
            try transport.respond(title: "Home")
        }
        try await model.selectServer(home)
        XCTAssertEqual(model.selectedServerID, home.id)
        XCTAssertNil(model.errorMessage)
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Home")
    }

    func testReenteringAMissingPairingTokenRestoresTheConnectionInPlace() async throws {
        try preserveLegacyConfiguration()
        let (store, defaults, _) = try fixture(.cantrip)
        let home = try store.add(draft("Home"))
        let work = try store.add(draft("Work"))
        try store.select(home)
        let newDevice = ProfileCredentials()
        let restored = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: newDevice.store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: config), servers: restored)
        defer { model.setAppActive(false) }
        XCTAssertFalse(model.hasConfiguration)
        XCTAssertNil(model.selectedServerID)
        let reenterMessage = "The pairing token for Home isn't saved on this device "
            + "(it doesn't move to a new device). Open Settings and select Home to re-enter it."
        XCTAssertEqual(model.errorMessage, reenterMessage)
        await model.selectSession("shared-id")
        XCTAssertEqual(model.errorMessage, reenterMessage, "Later requests keep pointing to re-entry")
        XCTAssertEqual(restored.missingCredentialIDs, [home.id])
        restored.refreshCredentialStatus()
        XCTAssertEqual(restored.missingCredentialIDs, [home.id, work.id])

        do {
            try await model.reenterCredential(" \n", for: home)
            XCTFail("An empty token is not saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter the pairing token.")
        }
        XCTAssertTrue(newDevice.values.isEmpty)

        var authorizations: [String: String] = [:]
        ProfileRequestProtocol.handler = { transport in
            authorizations[transport.request.url?.path ?? ""] =
                transport.request.value(forHTTPHeaderField: "Authorization")
            try transport.respond(title: "Home")
        }
        try await model.reenterCredential(" Home-new-token\n", for: home)
        XCTAssertEqual(model.selectedServerID, home.id)
        XCTAssertEqual(model.configuredURL, home.url)
        XCTAssertTrue(model.hasStoredToken)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(restored.servers, [home, work], "The same entry is restored, not re-added")
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restored.missingCredentialIDs, [work.id])
        XCTAssertEqual(try restored.credential(for: home), "Home-new-token")
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Home")
        XCTAssertEqual(authorizations["/api/v1/sessions/shared-id"], "Bearer Home-new-token")

        // A mistyped or rotated token can be replaced on the connected server too.
        try await model.reenterCredential("Home-rotated-token", for: home)
        XCTAssertNil(model.selectedSession, "Reconnecting reloads the host's sessions")
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Home")
        XCTAssertEqual(authorizations["/api/v1/sessions/shared-id"], "Bearer Home-rotated-token")
        XCTAssertEqual(newDevice.values.count, 1)
        let reopened = CantripRemoteModel(servers: ServerProfiles(kind: .cantrip, defaults: defaults,
                                                                 credentials: newDevice.store))
        XCTAssertEqual(reopened.selectedServerID, home.id)
        XCTAssertNil(reopened.errorMessage)
    }

    func testReenteringAMissingGatewayKeySelectsTheSavedGateway() throws {
        try preserveLegacyConfiguration()
        let (store, defaults, _) = try fixture(.hermes)
        let home = try store.add(draft("Home"))
        try store.select(home)
        let newDevice = ProfileCredentials()
        let restored = ServerProfiles(kind: .hermes, defaults: defaults, credentials: newDevice.store)
        let env = HermesEnv(servers: restored)
        XCTAssertNil(env.selectedServerID)
        XCTAssertEqual(env.apiKey, "")
        XCTAssertEqual(restored.missingCredentialIDs, [home.id])
        XCTAssertThrowsError(try env.reenterCredential("", for: home))
        try env.reenterCredential("Home-new-key", for: home)
        XCTAssertEqual(env.selectedServerID, home.id)
        XCTAssertEqual(env.baseURL, home.url)
        XCTAssertEqual(env.apiKey, "Home-new-key")
        XCTAssertEqual(restored.servers, [home])
        XCTAssertTrue(restored.missingCredentialIDs.isEmpty)
        let stranger = SavedServer(id: UUID(), name: "Gone", url: "https://gone.example",
                                   tailscaleOnly: false, usesLegacyHistory: false)
        XCTAssertThrowsError(try restored.replaceCredential("key", for: stranger))
    }

    func testLANOnlyProfilesRequireIndependentTokensAndKeepRoutingPreferences() throws {
        let (store, defaults, credentials) = try fixture(.cantrip)
        let a = try store.add(ServerDraft(name: "LAN A", credential: "token-a"))
        let b = try store.add(ServerDraft(name: "LAN B", credential: "token-b"))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.address, "Local network discovery")
        XCTAssertThrowsError(try store.add(ServerDraft(credential: "token-a")))
        XCTAssertThrowsError(try store.add(ServerDraft(credential: "token-c", tailscaleOnly: true)))
        XCTAssertThrowsError(try store.add(ServerDraft(url: "https://host.example/path", credential: "token-c")))
        let c = try store.add(ServerDraft(url: "https://remote.example", credential: "token-c", tailscaleOnly: true))
        try store.select(c)
        let restored = ServerProfiles(kind: .cantrip, defaults: defaults, credentials: credentials.store)
        XCTAssertEqual(restored.selected?.tailscaleOnly, true)
        XCTAssertFalse(a.tailscaleOnly)
    }

    func testMigrationRunsOnceAndPreservesLegacyHistoryScope() throws {
        for kind in [ServerKind.hermes, .cantrip] {
            let (store, defaults, credentials) = try fixture(kind)
            try store.migrate(url: "https://old.example", credential: "legacy-token", tailscaleOnly: true)
            let migrated = try XCTUnwrap(store.selected)
            XCTAssertTrue(migrated.usesLegacyHistory)
            XCTAssertEqual(try store.credential(for: migrated), "legacy-token")
            try store.migrate(url: "https://different.example", credential: "other-token")
            XCTAssertEqual(store.servers.count, 1)
            let restored = ServerProfiles(kind: kind, defaults: defaults, credentials: credentials.store)
            XCTAssertEqual(restored.selectedID, migrated.id)
            try restored.remove(migrated)
            try restored.migrate(url: "https://old.example", credential: "legacy-token")
            XCTAssertTrue(restored.servers.isEmpty, "Removing the last server must not remigrate a legacy slot")
        }
    }

    func testFailedMigrationAndCorruptStorageAreNotOverwritten() throws {
        let (store, defaults, credentials) = try fixture(.hermes)
        credentials.failing = true
        XCTAssertThrowsError(try store.migrate(url: "https://old.example", credential: "legacy"))
        XCTAssertFalse(store.hasSavedState)
        credentials.failing = false
        try store.migrate(url: "https://old.example", credential: "legacy")
        XCTAssertEqual(store.servers.count, 1)
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "hermes.saved-servers.v1")
        let restored = ServerProfiles(kind: .hermes, defaults: defaults, credentials: credentials.store)
        XCTAssertNotNil(restored.loadIssue)
        XCTAssertThrowsError(try restored.add(draft("New")))
        XCTAssertEqual(defaults.data(forKey: "hermes.saved-servers.v1"), corrupt)
    }

    func testModelsMigrateExistingConfigurationWithoutReenteringCredentials() throws {
        try preserveLegacyConfiguration()
        UserDefaults.standard.set("https://legacy-hermes.example", forKey: "hermes.baseURL")
        try Keychain.saveCredential("legacy-hermes-test-token", for: "hermes.apiKey")
        let (hermesStore, _, _) = try fixture(.hermes)
        let env = HermesEnv(servers: hermesStore)
        let gateway = try XCTUnwrap(hermesStore.selected)
        XCTAssertEqual(env.selectedServerID, gateway.id)
        XCTAssertEqual(env.baseURL, "https://legacy-hermes.example")
        XCTAssertEqual(env.apiKey, "legacy-hermes-test-token")
        XCTAssertNil(env.chatStorageID)
        XCTAssertEqual(env.sessionKey, UserDefaults.standard.string(forKey: "hermes.sessionKey"))

        UserDefaults.standard.set("https://legacy-cantrip.example", forKey: "cantrip.remote.base-url")
        UserDefaults.standard.set(true, forKey: "cantrip.remote.tailscale-only")
        try Keychain.saveCredential("legacy-cantrip-test-token", for: "cantrip.remote.pairing-token")
        let (cantripStore, _, _) = try fixture(.cantrip)
        let remote = CantripRemoteModel(servers: cantripStore)
        XCTAssertEqual(remote.selectedServerID, cantripStore.selectedID)
        XCTAssertEqual(remote.configuredURL, "https://legacy-cantrip.example")
        XCTAssertTrue(remote.hasStoredToken)
        XCTAssertTrue(remote.tailscaleOnly)
        XCTAssertEqual(try cantripStore.credential(for: XCTUnwrap(cantripStore.selected)),
                       "legacy-cantrip-test-token")
        XCTAssertEqual(ServerFormModel().draft, ServerDraft(), "The add form must stay empty after migration")
    }

    func testRemovalOnlyDeletesItsOwnCredentialAndDoesNotSelectAnotherServer() throws {
        let (store, _, credentials) = try fixture(.cantrip)
        let a = try store.add(draft("Home"))
        let b = try store.add(draft("Work"))
        try store.select(a)
        credentials.failing = true
        XCTAssertThrowsError(try store.remove(a))
        XCTAssertEqual(store.selectedID, a.id)
        XCTAssertEqual(store.servers.count, 2)
        credentials.failing = false
        try store.remove(a)
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(store.servers, [b])
        XCTAssertEqual(credentials.values.count, 1)
        XCTAssertEqual(try store.credential(for: b), "Work-test-credential")
        XCTAssertThrowsError(try store.select(a))
    }

    func testHermesSelectionRestoresCredentialsHistoryAndMemoryNamespaces() throws {
        try preserveLegacyConfiguration()
        let (store, defaults, credentials) = try fixture(.hermes)
        try store.select(nil)
        let env = HermesEnv(servers: store)
        env.select(.copilot)
        try env.addServer(draft("Home"))
        try env.addServer(draft("Work", url: "https://home.example"))
        let a = store.servers[0], b = store.servers[1]
        defer {
            for id in [a.id, b.id] {
                ChatStore.clear(for: .copilot, serverID: id)
                ChatStore.clear(for: .local, serverID: id)
            }
        }
        try env.selectServer(a)
        let aKey = env.sessionKey
        let vm = ChatViewModel(env: env, remote: CantripRemoteModel(), voice: VoiceController())
        vm.turns = [ChatTurn(role: .user, text: "Home only", executionLane: .copilot)]
        vm.renameTab("Home chat")
        vm.setTabLocked(true)
        try env.selectServer(b)
        vm.gatewayDidChange()
        XCTAssertEqual(env.apiKey, "Work-test-credential")
        XCTAssertNotEqual(env.sessionKey, aKey)
        XCTAssertTrue(vm.turns.isEmpty, "Same origin with different credentials still has separate history")
        XCTAssertFalse(vm.isTabLocked)
        vm.turns = [ChatTurn(role: .user, text: "Work only", executionLane: .copilot)]
        vm.renameTab("Work chat")
        try env.selectServer(a)
        vm.gatewayDidChange()
        XCTAssertEqual(vm.turns.first?.text, "Home only")
        XCTAssertEqual(vm.tabTitle, "Home chat")
        XCTAssertTrue(vm.isTabLocked)
        XCTAssertEqual(env.sessionKey, aKey)
        XCTAssertEqual(env.apiKey, "Home-test-credential")
        let restoredStore = ServerProfiles(kind: .hermes, defaults: defaults, credentials: credentials.store)
        let restored = HermesEnv(servers: restoredStore)
        XCTAssertEqual(restored.selectedServerID, a.id)
        XCTAssertEqual(restored.sessionKey, aKey)
        XCTAssertEqual(restored.apiKey, "Home-test-credential")
        try env.removeServer(a)
        XCTAssertNil(env.client)
        XCTAssertNil(env.selectedServerID)
        XCTAssertEqual(store.servers, [b])
    }

    func testDurableRunAndLaneStateRemainScopedToOwningServer() throws {
        let a = UUID(), b = UUID()
        defer {
            for id in [a, b] {
                ChatStore.clear(for: .copilot, serverID: id)
                ChatStore.clear(for: .local, serverID: id)
            }
        }
        let turn = ChatTurn(role: .assistant, streaming: true, executionLane: .copilot)
        let run = ActiveHermesRun(
            runID: "run-a", idempotencyKey: "key-a", assistantTurnID: turn.id,
            sessionID: "conversation-a", executionLane: .copilot, startedAt: Date()
        )
        ChatStore.save(turns: [turn], conversationID: "conversation-a", gatewayIdentity: "a",
                       pendingRun: nil, activeRun: run, for: .copilot, serverID: a)
        XCTAssertEqual(ChatStore.load(for: .copilot, serverID: a).activeRun, run)
        XCTAssertNil(ChatStore.load(for: .copilot, serverID: b).activeRun)
        XCTAssertTrue(ChatStore.load(for: .local, serverID: a).turns.isEmpty)
        ChatStore.clear(for: .copilot, serverID: b)
        XCTAssertEqual(ChatStore.load(for: .copilot, serverID: a).activeRun, run)
    }

    func testCantripSelectionClearsOldSessionsAndUsesTheSelectedServersCredential() async throws {
        try preserveLegacyConfiguration()
        let (store, defaults, credentials) = try fixture(.cantrip)
        try store.select(nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: config), servers: store)
        try model.addServer(draft("Home"))
        var work = draft("Work")
        work.tailscaleOnly = true
        try model.addServer(work)
        let a = store.servers[0], b = store.servers[1]
        ProfileRequestProtocol.handler = { transport in
            let home = transport.request.url?.host == "home.example"
            XCTAssertEqual(transport.request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer \(home ? "Home" : "Work")-test-credential")
            try transport.respond(title: home ? "Home" : "Work")
        }
        try await model.selectServer(a)
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Home")
        let identity = model.usageIdentity
        try await model.selectServer(b)
        XCTAssertNil(model.selectedSession)
        XCTAssertNil(model.selectedSessionID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertFalse(model.isConnected)
        XCTAssertNotEqual(model.usageIdentity, identity)
        XCTAssertTrue(model.tailscaleOnly)
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Work")
        let restored = CantripRemoteModel(servers: ServerProfiles(kind: .cantrip, defaults: defaults,
                                                                credentials: credentials.store))
        XCTAssertEqual(restored.selectedServerID, b.id)
        XCTAssertEqual(restored.configuredURL, b.url)
        XCTAssertTrue(restored.hasStoredToken)
        try await model.selectServer(a)
        XCTAssertFalse(model.tailscaleOnly)
        await model.selectSession("shared-id")
        XCTAssertEqual(model.selectedSession?.title, "Home")
        try model.removeServer(a)
        XCTAssertNil(model.selectedServerID)
        XCTAssertNil(model.selectedSession)
        XCTAssertFalse(model.hasConfiguration)
        XCTAssertEqual(store.servers, [b])
    }

    func testLateResponseFromPreviousServerCannotRestoreItsSession() async throws {
        try preserveLegacyConfiguration()
        let (store, _, _) = try fixture(.cantrip)
        try store.select(nil)
        let a = try store.add(draft("Home")), b = try store.add(draft("Work"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: config), servers: store)
        let started = expectation(description: "Old server request is in flight")
        var oldRequest: ProfileRequestProtocol?
        ProfileRequestProtocol.handler = {
            oldRequest = $0
            started.fulfill()
        }
        try await model.selectServer(a)
        let oldTask = Task { await model.selectSession("shared-id") }
        await fulfillment(of: [started], timeout: 2)
        try await model.selectServer(b)
        try XCTUnwrap(oldRequest).respond(title: "Old server")
        await oldTask.value
        XCTAssertNil(model.selectedSession)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedServerID, b.id)
    }

    func testSwitchIsBlockedDuringMutationButAddingDoesNotDisturbIt() async throws {
        try preserveLegacyConfiguration()
        let (store, _, _) = try fixture(.cantrip)
        try store.select(nil)
        let a = try store.add(draft("Home")), b = try store.add(draft("Work"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: config), servers: store)
        let started = expectation(description: "Mutation started")
        var request: ProfileRequestProtocol?
        ProfileRequestProtocol.handler = {
            if $0.request.httpMethod == "GET" {
                try $0.respond(title: "Home")
            } else {
                request = $0
                started.fulfill()
            }
        }
        try await model.selectServer(a)
        let task = Task { await model.createSession() }
        await fulfillment(of: [started], timeout: 2)
        do {
            try await model.selectServer(b)
            XCTFail("A send must finish before switching hosts")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Wait"))
        }
        try model.addServer(draft("Third"))
        XCTAssertEqual(model.selectedServerID, a.id)
        XCTAssertEqual(model.configuredURL, a.url)
        try XCTUnwrap(request).respond(title: "Home")
        let created = await task.value
        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedSession?.title, "Home")
        XCTAssertEqual(store.servers.count, 3)
    }

#if os(iOS)
    func testSavedRowsFitNarrowAndLargeTextLayouts() throws {
        let server = SavedServer(
            id: UUID(), name: "A long descriptive home server name", url: "https://home-private.example.com",
            tailscaleOnly: true, usesLegacyHistory: false
        )
        for width: CGFloat in [288, 361, 736] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                // A missing pairing token adds one short line.
                for (missing, limit) in [(nil, 600), ("pairing token", 700)] as [(String?, CGFloat)] {
                    let row = SavedServerRow(server: server, isSelected: true, missingCredential: missing)
                        .environment(\.dynamicTypeSize, size)
                    let controller = UIHostingController(rootView: row)
                    controller.safeAreaRegions = []
                    let measured = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertLessThanOrEqual(measured.width, width + 1)
                    XCTAssertGreaterThanOrEqual(measured.height, 44)
                    XCTAssertLessThan(measured.height, limit)
                }
            }
        }
    }
#endif

#if os(iOS)
    func testSavedServerSettingsRenderWithBlankAddFields() throws {
        let (store, _, credentials) = try fixture(.cantrip)
        let selected = try store.add(draft("Home Mac", url: "https://home.example"))
        let moved = try store.add(draft("Work Mac", url: "https://work.example"))
        try store.select(selected)
        credentials.values = credentials.values.filter { !$0.key.contains(moved.id.uuidString) }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for size: DynamicTypeSize in [.large, .accessibility3] {
            let view = NavigationStack {
                Form {
                    ServerSettingsSections(
                        servers: store,
                        add: { try store.add($0) },
                        select: { try store.select($0) },
                        remove: store.remove,
                        reenter: { try store.replaceCredential($1, for: $0) }
                    )
                }
                .navigationTitle("Servers")
            }
            .environment(\.dynamicTypeSize, size)
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(store.missingCredentialIDs, [moved.id], "Opening the list finds the missing token")
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "saved-servers-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let scroll = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UIScrollView }.first)
            scroll.setContentOffset(CGPoint(
                x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)
            ), animated: false)
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let fields = descendants(of: controller.view).compactMap { $0 as? UITextField }
            XCTAssertTrue(fields.allSatisfy { ($0.text ?? "").isEmpty })
            XCTAssertFalse(fields.isEmpty, "The mounted form should contain its blank add fields")
            window.isHidden = true
        }
    }
#endif

#if os(iOS)
    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
#endif
}
