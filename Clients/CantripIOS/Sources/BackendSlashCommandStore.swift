import Combine
import Foundation

/// Backend command lists cached per session (`GET /api/v1/sessions/{id}/commands`).
/// A list is refetched on the next slash entry once it is 30 s old or the tab's folder or model
/// settings changed; cached rows show meanwhile. Responses superseded by a newer request, or
/// fetched before `removeAll()`, are dropped. Failures cache nothing and show nothing.
@MainActor
final class BackendSlashCommandStore: ObservableObject {
    /// One session's identity for caching. `key` also names the connected Mac, so a list never
    /// follows a session ID to another server.
    struct Context: Equatable {
        let key: String
        let sessionID: String
        let workdir: String
        let modelSettingsRevision: String?
    }

    private struct Entry {
        let response: BackendCommandsResponse
        let context: Context
        let fetchedAt: Date
    }

    private struct Request {
        let sequence: Int
        let context: Context
    }

    static let maximumAge: TimeInterval = 30
    static let maximumEntries = 24

    @Published private(set) var revision = 0
    private var entries: [String: Entry] = [:]
    private var requests: [String: Request] = [:]
    private var order: [String] = []
    private var sequence = 0

    func response(for key: String) -> BackendCommandsResponse? { entries[key]?.response }

    func isLoading(_ key: String) -> Bool { requests[key] != nil }

    /// Whether the next slash entry should fetch: nothing cached, too old, or the backend changed.
    func needsFetch(_ context: Context, now: Date = Date()) -> Bool {
        if let request = requests[context.key] { return request.context != context }
        guard let entry = entries[context.key] else { return true }
        return now.timeIntervalSince(entry.fetchedAt) >= Self.maximumAge
            || entry.context.workdir != context.workdir
            || entry.context.modelSettingsRevision != context.modelSettingsRevision
    }

    /// Starts a fetch when `needsFetch`; never blocks typing.
    func refreshIfNeeded(
        _ context: Context, now: Date = Date(),
        fetch: @escaping @MainActor (String) async throws -> BackendCommandsResponse
    ) {
        guard needsFetch(context, now: now) else { return }
        sequence += 1
        let request = Request(sequence: sequence, context: context)
        requests[context.key] = request
        revision += 1
        Task { @MainActor [weak self] in
            let response = try? await fetch(context.sessionID)
            self?.finish(request, response: response, at: Date())
        }
    }

    /// Forgets every list, e.g. when the app connects to another Mac. In-flight responses are dropped.
    func removeAll() {
        entries = [:]
        requests = [:]
        order = []
        revision += 1
    }

    private func finish(_ request: Request, response: BackendCommandsResponse?, at date: Date) {
        let key = request.context.key
        guard requests[key]?.sequence == request.sequence else { return }
        requests[key] = nil
        if let response {
            entries[key] = Entry(response: response, context: request.context, fetchedAt: date)
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > Self.maximumEntries { entries[order.removeFirst()] = nil }
        }
        revision += 1
    }
}

extension CantripRemoteSession {
    /// The Mac serves this session's backend commands; older Macs never get the call.
    var offersBackendCommands: Bool {
        #if DEBUG
        if CantripUITestFixtures.backendCommands != nil { return true }
        #endif
        return supportsBackendCommands == true
    }
}
