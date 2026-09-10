import Foundation

@MainActor
final class CantripRemoteRouter {
    var available: [CantripTransport] = [] {
        didSet {
            for route in oldValue where !available.contains(route) {
                routeRevisions[route, default: 0] += 1
                recoverySuccesses[route] = nil
            }
            if let preferred, !available.contains(preferred) { self.preferred = nil }
        }
    }
    private(set) var preferred: CantripTransport?
    private var retryAfter: [CantripTransport: Date] = [:]
    private var routeRevisions: [CantripTransport: Int] = [:]
    private var recoverySuccesses: [CantripTransport: Int] = [:]
    private var probeTask: Task<Void, Never>?
    private var generation = 0
    var now: () -> Date = Date.init

    func reset() {
        generation += 1
        probeTask?.cancel()
        probeTask = nil
        preferred = nil
        retryAfter = [:]
        available = []
        routeRevisions = [:]
        recoverySuccesses = [:]
    }

    func cancelProbe() {
        generation += 1
        probeTask?.cancel()
        probeTask = nil
    }

    func perform<T>(
        readOnly: Bool,
        operation: (CantripTransport) async throws -> T
    ) async throws -> T {
        try await perform(
            readOnly: readOnly, candidates: candidates(readOnly: readOnly),
            operation: operation
        )
    }

    func performMutation<Prepared, Result>(
        prepare: (CantripTransport) async throws -> Prepared,
        operation: (CantripTransport, Prepared) async throws -> Result
    ) async throws -> Result {
        let generation = generation
        let route: CantripTransport
        let prepared: Prepared
        do {
            (route, prepared) = try await perform(
                readOnly: true, candidates: candidates(readOnly: true, recoverAll: true)
            ) { route in
                (route, try await prepare(route))
            }
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            guard available.contains(route) else {
                throw CantripRemoteError.transport("The route disappeared before sending.")
            }
        } catch {
            if CantripRemoteError.isRouteFailure(error) {
                throw CantripRemoteError.notSent(error.localizedDescription)
            }
            throw error
        }
        // Pin the write to the host whose authenticated preparation succeeded,
        // even if an independent recovery probe changed the preferred route.
        return try await perform(readOnly: false, candidates: [route]) { route in
            try await operation(route, prepared)
        }
    }

    private func candidates(readOnly: Bool, recoverAll: Bool = false) -> [CantripTransport] {
        var candidates = available.filter { (retryAfter[$0] ?? .distantPast) <= now() }
        // Cooldowns protect a working alternative, not a completely disconnected client.
        if candidates.isEmpty, readOnly, !recoverAll {
            let cooling = available.sorted {
                (retryAfter[$0] ?? .distantPast) < (retryAfter[$1] ?? .distantPast)
            }
            candidates = Array(cooling.prefix(1))
        }
        candidates.sort { !isLAN($0) && isLAN($1) }
        if let preferred, let index = candidates.firstIndex(of: preferred) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        if recoverAll {
            let cooling = available.filter { !candidates.contains($0) }
                .sorted { !isLAN($0) && isLAN($1) }
            candidates += cooling
        }
        if !readOnly { candidates = Array(candidates.prefix(1)) }
        return candidates
    }

    private func perform<T>(
        readOnly: Bool,
        candidates: [CantripTransport],
        operation: (CantripTransport) async throws -> T
    ) async throws -> T {
        let generation = generation
        guard !candidates.isEmpty else {
            throw CantripRemoteError.transport(
                "No healthy route is available. Check the host connection and Remote settings."
            )
        }
        var lastError: Error = CantripRemoteError.invalidResponse
        for route in candidates {
            try Task.checkCancellation()
            guard available.contains(route) else { continue }
            let previousPreferred = preferred
            let revision = routeRevisions[route, default: 0]
            do {
                let result = try await operation(route)
                try Task.checkCancellation()
                guard generation == self.generation else { throw CancellationError() }
                if available.contains(route), routeRevisions[route, default: 0] == revision {
                    routeRevisions[route, default: 0] += 1
                    recoverySuccesses[route] = nil
                    retryAfter[route] = nil
                    if preferred == previousPreferred,
                       readOnly || preferred == nil || preferred == route {
                        preferred = route
                    }
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard generation == self.generation else { throw CancellationError() }
                guard CantripRemoteError.isRouteFailure(error) else { throw error }
                if readOnly, routeRevisions[route, default: 0] != revision {
                    throw CancellationError()
                }
                failed(route, revision: revision)
                lastError = error
                if !readOnly { throw error }
            }
        }
        throw lastError
    }

    @discardableResult
    func recoverTailscale(probe: @escaping (CantripTransport) async throws -> Void) -> Task<Void, Never>? {
        guard probeTask == nil,
              isLAN(preferred),
              let route = available.first(where: {
                  !isLAN($0) && (retryAfter[$0] ?? .distantPast) <= now()
              })
        else { return nil }
        let generation = generation
        let revision = routeRevisions[route, default: 0]
        probeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.generation { self.probeTask = nil }
            }
            do {
                try await probe(route)
                try Task.checkCancellation()
                guard generation == self.generation, self.available.contains(route),
                      self.isLAN(self.preferred),
                      self.routeRevisions[route, default: 0] == revision else { return }
                self.routeRevisions[route, default: 0] += 1
                self.recoverySuccesses[route, default: 0] += 1
                guard self.recoverySuccesses[route, default: 0] >= 2 else {
                    self.retryAfter[route] = self.now().addingTimeInterval(3)
                    return
                }
                self.recoverySuccesses[route] = nil
                self.retryAfter[route] = nil
                self.preferred = route
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                // A recovery probe must not interrupt the working LAN connection.
                print("[CantripRemote] Tailscale recovery probe failed; backing off: \(error.localizedDescription)")
                self.failed(route, revision: revision)
            }
        }
        return probeTask
    }

    private func failed(_ route: CantripTransport, revision: Int) {
        guard available.contains(route), routeRevisions[route, default: 0] == revision else { return }
        routeRevisions[route, default: 0] += 1
        recoverySuccesses[route] = nil
        retryAfter[route] = now().addingTimeInterval(isLAN(route) ? 30 : 15)
        if preferred == route { preferred = nil }
    }

    private func isLAN(_ route: CantripTransport?) -> Bool {
        if case .lan = route { return true }
        return false
    }
}
