import Foundation
import SwiftUI

enum ServerKind: String {
    case hermes
    case cantrip

    var title: String { self == .hermes ? "Hermes Gateway" : "Cantrip Remote" }
    var credentialName: String { self == .hermes ? "API key" : "pairing token" }
    var credentialTitle: String { self == .hermes ? "API Key" : "Pairing Token" }
}

struct SavedServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let url: String
    let tailscaleOnly: Bool
    let usesLegacyHistory: Bool
    /// Cantrip only: host:port of the Mac's encrypted LAN listener, tried when Bonjour can't see
    /// it (e.g. through a Tailscale subnet router). Absent in profiles saved by older builds.
    var directAddress: String? = nil

    var address: String {
        let parts = [url.isEmpty ? nil : url, directAddress.map { "Direct \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Local network discovery" : parts.joined(separator: " · ")
    }
}

struct ServerConfigurationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ServerCredentialStore {
    var read: (String) throws -> String?
    var write: (String, String) throws -> Void
    var remove: (String) throws -> Void

    static let keychain = Self(
        read: Keychain.loadCredential,
        write: { try Keychain.saveCredential($1, for: $0) },
        remove: Keychain.deleteCredential
    )
}

@MainActor
final class ServerProfiles: ObservableObject {
    private struct Snapshot: Codable {
        var servers: [SavedServer] = []
        var selectedID: UUID?
    }

    let kind: ServerKind
    @Published private(set) var servers: [SavedServer] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var loadIssue: String?
    /// Saved servers known to have no credential on this device, e.g. after moving to a new one.
    @Published private(set) var missingCredentialIDs: Set<UUID> = []
    private let defaults: UserDefaults
    private let credentials: ServerCredentialStore
    private let storageKey: String

    var selected: SavedServer? { servers.first { $0.id == selectedID } }
    var hasSavedState: Bool { defaults.data(forKey: storageKey) != nil }

    init(
        kind: ServerKind,
        defaults: UserDefaults = .standard,
        credentials: ServerCredentialStore = .keychain
    ) {
        self.kind = kind
        self.defaults = defaults
        self.credentials = credentials
        storageKey = "\(kind.rawValue).saved-servers.v1"
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard Set(snapshot.servers.map(\.id)).count == snapshot.servers.count,
                  snapshot.selectedID == nil
                    || snapshot.servers.contains(where: { $0.id == snapshot.selectedID }) else {
                throw ServerConfigurationError(message: "The saved server list is invalid.")
            }
            servers = snapshot.servers
            selectedID = snapshot.selectedID
        } catch {
            loadIssue = "Could not load saved servers: \(error.localizedDescription)"
        }
    }

    func credential(for server: SavedServer) throws -> String {
        guard let value = try storedCredential(for: server) else {
            throw ServerConfigurationError(
                message: "The \(kind.credentialName) for \(server.name) isn't saved on this device "
                    + "(it doesn't move to a new device). Open Settings and select \(server.name) to re-enter it."
            )
        }
        return value
    }

    /// Nil when this device has no credential for the server. Credentials are Keychain items that
    /// stay on the device that saved them, so a new or restored device gets the list without them.
    func storedCredential(for server: SavedServer) throws -> String? {
        guard servers.contains(where: { $0.id == server.id }) else {
            throw ServerConfigurationError(message: "This server is no longer saved.")
        }
        let value = try credentials.read(account(for: server.id)).flatMap { $0.isEmpty ? nil : $0 }
        markCredential(missing: value == nil, for: server.id)
        return value
    }

    /// False when the credential can't be read for another reason (e.g. Keychain locked).
    func isMissingCredential(_ server: SavedServer) -> Bool {
        do { return try storedCredential(for: server) == nil } catch { return false }
    }

    /// Rechecks which saved servers have no credential on this device.
    func refreshCredentialStatus() {
        for server in servers { _ = isMissingCredential(server) }
    }

    /// Saves a re-entered credential for a saved server, keeping the entry, its ID and its history.
    func replaceCredential(_ credential: String, for server: SavedServer) throws {
        try ensureLoaded()
        guard servers.contains(where: { $0.id == server.id }) else {
            throw ServerConfigurationError(message: "This server is no longer saved.")
        }
        let secret = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw ServerConfigurationError(message: missingCredentialPrompt) }
        try credentials.write(account(for: server.id), secret)
        markCredential(missing: false, for: server.id)
    }

    @discardableResult
    func add(_ draft: ServerDraft, usesLegacyHistory: Bool = false) throws -> SavedServer {
        try ensureLoaded()
        let secret = draft.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw ServerConfigurationError(message: missingCredentialPrompt) }
        let url = try normalizedURL(draft.url)
        guard kind != .cantrip || !draft.tailscaleOnly || !url.isEmpty else {
            throw ServerConfigurationError(message: "Enter a Tailscale URL to use Tailscale only.")
        }
        let direct = kind == .cantrip ? try CantripDirectAddress.normalized(draft.directAddress) : nil
        // A same-route entry without a credential (e.g. after moving to a new device) is repaired
        // in place rather than duplicated, so it keeps its ID, history and selection.
        var stale: SavedServer?
        for existing in servers where existing.url == url && existing.directAddress == direct {
            guard let saved = try storedCredential(for: existing) else {
                stale = stale ?? existing
                continue
            }
            if saved == secret {
                throw ServerConfigurationError(
                    message: "This server is already saved as \(existing.name). Select it from the list."
                )
            }
        }
        let name = draft.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard name.count <= 80 else {
            throw ServerConfigurationError(message: "Use a server name of 80 characters or fewer.")
        }
        let server = SavedServer(
            id: stale?.id ?? UUID(),
            name: name.isEmpty ? (stale?.name ?? URL(string: url)?.host ?? direct ?? "Cantrip on LAN") : name,
            url: url,
            tailscaleOnly: kind == .cantrip && draft.tailscaleOnly,
            usesLegacyHistory: stale?.usesLegacyHistory ?? usesLegacyHistory,
            directAddress: direct
        )
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        let snapshot = Snapshot(servers: updated, selectedID: selectedID)
        let data = try JSONEncoder().encode(snapshot)
        try credentials.write(account(for: server.id), secret)
        commit(snapshot, data: data)
        markCredential(missing: false, for: server.id)
        return server
    }

    func select(_ server: SavedServer?) throws {
        try ensureLoaded()
        if let server { _ = try credential(for: server) }
        let snapshot = Snapshot(servers: servers, selectedID: server?.id)
        commit(snapshot, data: try JSONEncoder().encode(snapshot))
    }

    func remove(_ server: SavedServer) throws {
        try ensureLoaded()
        let snapshot = Snapshot(
            servers: servers.filter { $0.id != server.id },
            selectedID: selectedID == server.id ? nil : selectedID
        )
        let data = try JSONEncoder().encode(snapshot)
        try credentials.remove(account(for: server.id))
        commit(snapshot, data: data)
        markCredential(missing: false, for: server.id)
    }

    func migrate(url: String, credential: String, tailscaleOnly: Bool = false) throws {
        guard !hasSavedState else { return }
        let server = try add(
            ServerDraft(url: url, credential: credential, tailscaleOnly: tailscaleOnly),
            usesLegacyHistory: true
        )
        try select(server)
    }

    private func normalizedURL(_ raw: String) throws -> String {
        if kind == .cantrip {
            return try CantripRemoteModel.normalizedBaseURL(raw)?.absoluteString ?? ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              let url = components.url else {
            throw ServerConfigurationError(message: "Enter a complete gateway URL.")
        }
        if let issue = GatewayTransportPolicy.issue(for: url) {
            throw ServerConfigurationError(message: issue)
        }
        guard components.query == nil, components.fragment == nil else {
            throw ServerConfigurationError(message: "The gateway URL cannot contain a query or fragment.")
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let normalized = components.url else {
            throw ServerConfigurationError(message: "Enter a valid gateway URL.")
        }
        return normalized.absoluteString
    }

    private func account(for id: UUID) -> String {
        "\(kind.rawValue).server.\(id.uuidString).credential"
    }

    private var missingCredentialPrompt: String {
        kind == .hermes ? "Enter the gateway API key." : "Enter the pairing token."
    }

    private func markCredential(missing: Bool, for id: UUID) {
        guard missingCredentialIDs.contains(id) != missing else { return }
        if missing { missingCredentialIDs.insert(id) } else { missingCredentialIDs.remove(id) }
    }

    private func ensureLoaded() throws {
        if let loadIssue { throw ServerConfigurationError(message: loadIssue) }
    }

    private func commit(_ snapshot: Snapshot, data: Data) {
        defaults.set(data, forKey: storageKey)
        servers = snapshot.servers
        selectedID = snapshot.selectedID
    }
}

struct ServerDraft: Equatable {
    var name = ""
    var url = ""
    var credential = ""
    var tailscaleOnly = false
    /// Cantrip only: host:port of the Mac's encrypted LAN listener.
    var directAddress = ""
}

@MainActor
final class ServerFormModel: ObservableObject {
    @Published var draft = ServerDraft()
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var saved = false

    func save(using add: (ServerDraft) async throws -> Void) async {
        guard !saving else { return }
        saving = true
        saved = false
        error = nil
        defer { saving = false }
        do {
            try await add(draft)
            draft = ServerDraft()
            saved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
