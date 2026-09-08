import Foundation
import Network
import XCTest
@testable import Hermes

private final class RoutingTestConnections: @unchecked Sendable {
    // Accessed only on the test listener's serial queue.
    var values: [NWConnection] = []
}

@MainActor
final class CantripRoutingTests: XCTestCase {
    private let lan = CantripTransport.lan(.hostPort(host: "127.0.0.1", port: 8765))
    private let remote = CantripTransport.remote(URL(string: "https://cantrip.example")!)

    func testTailscaleIsFirstAndNeverProbesHealthyLAN() async throws {
        let router = CantripRemoteRouter()
        var now = Date()
        router.now = { now }
        router.available = [lan, remote]
        for _ in 0..<3 {
            _ = try await router.perform(readOnly: true) { route in
                XCTAssertEqual(route, self.remote)
                return 1
            }
            let probe = router.recoverTailscale { _ in XCTFail("Healthy Tailscale needs no probes") }
            XCTAssertNil(probe)
            now = now.addingTimeInterval(31)
            router.available = [remote]
            router.available = [lan, remote]
        }
        _ = try await router.perform(readOnly: false) { route in
            XCTAssertEqual(route, self.remote)
            return 1
        }
    }

    func testFailedTailscaleBacksOffAndLANRemainsFirstUntilProbed() async throws {
        let router = CantripRemoteRouter()
        var now = Date()
        router.now = { now }
        router.available = [lan, remote]
        var calls: [CantripTransport] = []
        let operation: (CantripTransport) async throws -> Int = { route in
            calls.append(route)
            if route == self.remote { throw CantripRemoteError.transport("Offline") }
            return 1
        }
        _ = try await router.perform(readOnly: true, operation: operation)
        XCTAssertEqual(calls, [remote, lan])
        calls = []
        router.available = [lan]
        router.available = [lan, remote]
        _ = try await router.perform(readOnly: true, operation: operation)
        now = now.addingTimeInterval(31)
        _ = try await router.perform(readOnly: true, operation: operation)
        XCTAssertEqual(calls, [lan, lan], "Route changes and cooldown expiry must not stall reads")
    }

    func testMutationIsNotReplayedAndNextReadUsesLAN() async throws {
        let router = CantripRemoteRouter()
        router.available = [lan, remote]
        var calls: [CantripTransport] = []
        do {
            _ = try await router.perform(readOnly: false) { route in
                calls.append(route)
                throw CantripRemoteError.transport("Response lost")
            }
            XCTFail("Mutation must report an uncertain failure")
        } catch {}
        XCTAssertEqual(calls, [remote])
        _ = try await router.perform(readOnly: true) { route in
            calls.append(route)
            return 1
        }
        XCTAssertEqual(calls, [remote, lan])
    }

    func testAuthenticationAndApplicationErrorsDoNotSwitchRoutes() async throws {
        for error in [CantripRemoteError.authentication, .http(409, "Busy"), .decoding] {
            let router = CantripRemoteRouter()
            router.available = [lan, remote]
            var calls = 0
            do {
                _ = try await router.perform(readOnly: true) { _ in
                    calls += 1
                    throw error
                }
                XCTFail("Expected host error")
            } catch {}
            XCTAssertEqual(calls, 1)
        }
    }

    func testRecoveryProbeDoesNotBlockLANAndPromotesTailscaleOnlyAfterSuccess() async throws {
        let router = CantripRemoteRouter()
        router.available = [lan]
        _ = try await router.perform(readOnly: true) { _ in 1 }
        router.available = [lan, remote]
        let started = expectation(description: "Read-only recovery starts")
        var resume: CheckedContinuation<Void, Never>?
        let probe = router.recoverTailscale { route in
            XCTAssertEqual(route, self.remote)
            await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        _ = try await router.perform(readOnly: true) { route in
            XCTAssertEqual(route, self.lan)
            return 1
        }
        XCTAssertEqual(router.preferred, lan)
        resume?.resume()
        await probe?.value
        XCTAssertEqual(router.preferred, remote)
        _ = try await router.perform(readOnly: false) { route in
            XCTAssertEqual(route, self.remote)
            return 1
        }
    }

    func testFailedProbeLeavesLANHealthyAndBacksOff() async throws {
        for error in [CantripRemoteError.transport("Offline"), .authentication, .decoding] {
            let router = CantripRemoteRouter()
            var now = Date()
            router.now = { now }
            router.available = [lan]
            _ = try await router.perform(readOnly: true) { _ in 1 }
            router.available = [lan, remote]
            let probe = router.recoverTailscale { _ in throw error }
            await probe?.value
            XCTAssertEqual(router.preferred, lan)
            let retry = router.recoverTailscale { _ in XCTFail("Must back off failed probe") }
            XCTAssertNil(retry)
            now = now.addingTimeInterval(4)
            let recovered = router.recoverTailscale { route in
                XCTAssertEqual(route, self.remote)
            }
            await recovered?.value
            XCTAssertEqual(router.preferred, remote)
        }
    }

    func testCancelledRecoveryCannotPromoteAnOldRoute() async throws {
        for reset in [false, true] {
            let router = CantripRemoteRouter()
            router.available = [lan]
            _ = try await router.perform(readOnly: true) { _ in 1 }
            router.available = [lan, remote]
            let started = expectation(description: "Recovery starts before cancellation")
            var resume: CheckedContinuation<Void, Never>?
            let probe = router.recoverTailscale { _ in
                await withCheckedContinuation { continuation in
                    resume = continuation
                    started.fulfill()
                }
            }
            await fulfillment(of: [started], timeout: 1)
            if reset { router.reset() } else { router.cancelProbe() }
            resume?.resume()
            await probe?.value
            XCTAssertEqual(router.preferred, reset ? nil : lan)
        }
    }

    func testConfigurationResetRejectsOldCompletionAndClearsCooldown() async throws {
        let router = CantripRemoteRouter()
        router.available = [lan]
        do {
            _ = try await router.perform(readOnly: true) { _ in
                router.reset()
                return 1
            }
            XCTFail("Old configuration must be cancelled")
        } catch is CancellationError {}
        XCTAssertNil(router.preferred)
        router.available = [remote]
        _ = try await router.perform(readOnly: true) { route in
            XCTAssertEqual(route, self.remote)
            return 1
        }
    }

    func testTailscaleOnlyHasNoLANRequestsOrProbes() async throws {
        let router = CantripRemoteRouter()
        router.available = [remote]
        _ = try await router.perform(readOnly: true) { route in
            XCTAssertEqual(route, self.remote)
            return 1
        }
        let probe = router.recoverTailscale { _ in XCTFail("Already using Tailscale") }
        XCTAssertNil(probe)
    }

    func testLANOnlyStillWorksWithoutTailscaleProbes() async throws {
        let router = CantripRemoteRouter()
        router.available = [lan]
        _ = try await router.perform(readOnly: true) { route in
            XCTAssertEqual(route, self.lan)
            return 1
        }
        let probe = router.recoverTailscale { _ in XCTFail("No Tailscale URL is saved") }
        XCTAssertNil(probe)
    }

    func testUnresponsiveLANReadTimesOutBeforeConnectionStales() async throws {
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "Local blackhole ready")
        let connections = RoutingTestConnections()
        let queue = DispatchQueue(label: "cantrip-routing-test")
        listener.newConnectionHandler = { connection in
            connections.values.append(connection)
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            queue.sync { connections.values.forEach { $0.cancel() } }
        }
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port)
        let start = Date()
        do {
            _ = try await CantripRemoteAPI(
                transport: .lan(.hostPort(host: "127.0.0.1", port: port)),
                token: "test-token"
            ).sessions()
            XCTFail("Stalled TLS must fail")
        } catch {
            XCTAssertTrue(CantripRemoteError.isRouteFailure(error))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
        let mutationStart = Date()
        do {
            _ = try await CantripRemoteAPI(
                transport: .lan(.hostPort(host: "127.0.0.1", port: port)),
                token: "test-token"
            ).createSession()
            XCTFail("A mutation must not wait 12 seconds for stalled TLS")
        } catch {
            XCTAssertTrue(CantripRemoteError.isRouteFailure(error))
        }
        XCTAssertLessThan(Date().timeIntervalSince(mutationStart), 3.5)
    }
}
