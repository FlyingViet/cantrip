import Foundation
import SwiftUI

enum ServerKind: String {
    case hermes
    case cantrip

    var title: String { self == .hermes ? "Hermes Gateway" : "Cantrip Remote" }
}

struct SavedServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let url: String
    let tailscaleOnly: Bool
    let usesLegacyHistory: Bool

    var address: String { url.isEmpty ? "Local network discovery" : url }
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
        guard servers.contains(where: { $0.id == server.id }) else {
            throw ServerConfigurationError(message: "This server is no longer saved.")
        }
        guard let value = try credentials.read(account(for: server.id)), !value.isEmpty else {
            throw ServerConfigurationError(
                message: "The credential for \(server.name) is missing. Remove it and add the server again."
            )
        }
        return value
    }

    @discardableResult
    func add(_ draft: ServerDraft, usesLegacyHistory: Bool = false) throws -> SavedServer {
        try ensureLoaded()
        let secret = draft.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            throw ServerConfigurationError(
                message: kind == .hermes ? "Enter the gateway API key." : "Enter the pairing token."
            )
        }
        let url = try normalizedURL(draft.url)
        guard kind != .cantrip || !draft.tailscaleOnly || !url.isEmpty else {
            throw ServerConfigurationError(message: "Enter a Tailscale URL to use Tailscale only.")
        }
        for existing in servers where existing.url == url {
            if try credential(for: existing) == secret {
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
            id: UUID(),
            name: name.isEmpty ? (URL(string: url)?.host ?? "Cantrip on LAN") : name,
            url: url,
            tailscaleOnly: kind == .cantrip && draft.tailscaleOnly,
            usesLegacyHistory: usesLegacyHistory
        )
        let snapshot = Snapshot(servers: servers + [server], selectedID: selectedID)
        let data = try JSONEncoder().encode(snapshot)
        try credentials.write(account(for: server.id), secret)
        commit(snapshot, data: data)
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
