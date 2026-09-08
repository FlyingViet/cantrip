import SwiftUI
import XCTest
@testable import Hermes

private final class QuotaRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@MainActor
final class CopilotUsageTests: XCTestCase {
    override func tearDown() {
        QuotaRequestProtocol.handler = nil
        super.tearDown()
    }

    private func fixture(remaining: Double? = 96.4, unlimited: Bool = false,
                         checked: Date = Date(), observed: Date = Date(),
                         reset: Date = Date().addingTimeInterval(86400),
                         error: String? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var bucket: [String: Any] = [
            "id": "premium_interactions", "billingMode": "credits",
            "isUnlimited": unlimited, "overage": 0, "overageAllowed": true,
            "resetAt": formatter.string(from: reset), "observedAt": formatter.string(from: observed),
        ]
        if let remaining { bucket["remainingPercent"] = remaining }
        var value: [String: Any] = [
            "account": ["login": "quota-test", "plan": "individual", "buckets": [bucket]],
            "checkedAt": formatter.string(from: checked), "isRefreshing": false,
        ]
        if let error { value["error"] = error }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaRequestProtocol.self]
        return URLSession(configuration: config)
    }

    func testReadOnlyAuthenticatedEndpointAndOldHostErrors() async throws {
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                                   token: "quota-test-token", urlSession: session())
        let data = try fixture()
        QuotaRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/copilot/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer quota-test-token")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertNil(request.httpBody)
            return (200, data)
        }
        let value = try await api.copilotUsage()
        XCTAssertEqual(value.account?.primary?.remainingPercent, 96.4)
        XCTAssertFalse(value.isStale())
        for (status, expected) in [(404, "update"), (401, "authentication"), (200, "decoding")] {
            QuotaRequestProtocol.handler = { _ in (status, Data(#"{"error":"not found"}"#.utf8)) }
            do {
                _ = try await api.copilotUsage()
                XCTFail("Expected \(expected)")
            } catch CantripRemoteError.copilotUsageUnsupported {
                XCTAssertEqual(status, 404)
            } catch CantripRemoteError.authentication {
                XCTAssertEqual(status, 401)
            } catch CantripRemoteError.decoding {
                XCTAssertEqual(status, 200)
            }
        }
    }

    func testLoadingFailureAndEmptySnapshotNeverShowZeroOrFullAllowance() async throws {
        let model = CopilotUsageModel()
        XCTAssertEqual(model.headerText(at: Date()), "--")
        let snapshot = try JSONDecoder().decode(CopilotUsageSnapshot.self, from: fixture())
        await model.refresh { snapshot }
        XCTAssertEqual(model.headerText(at: Date()), "96.4%")
        await model.refresh { throw CantripRemoteError.transport("Offline") }
        XCTAssertEqual(model.headerText(at: Date()), "Stale")
        XCTAssertEqual(model.snapshot?.account?.primary?.remainingPercent, 96.4)
        XCTAssertNotNil(model.error)
        await model.refresh { throw CancellationError() }
        XCTAssertNotNil(model.error)
        await model.refresh { snapshot }
        XCTAssertNil(model.error)
        let unavailable = try JSONDecoder().decode(CopilotUsageSnapshot.self,
            from: Data(#"{"isRefreshing":true}"#.utf8))
        await model.refresh { unavailable }
        XCTAssertEqual(model.headerText(at: Date()), "--")
    }

    func testConfigurationChangesInvalidateCachedAndInFlightReadings() async throws {
        let model = CopilotUsageModel()
        let identity = UUID()
        model.useSource(identity)
        let snapshot = try JSONDecoder().decode(CopilotUsageSnapshot.self, from: fixture())
        var pending: CheckedContinuation<CopilotUsageSnapshot, Never>?
        let requested = expectation(description: "First read started")
        let first = Task {
            await model.refresh {
                await withCheckedContinuation {
                    pending = $0
                    requested.fulfill()
                }
            }
        }
        await fulfillment(of: [requested], timeout: 2)
        await model.refresh { XCTFail("Reads must coalesce"); return snapshot }
        model.useSource(UUID())
        pending?.resume(returning: snapshot)
        await first.value
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isLoading)
        await model.refresh { snapshot }
        model.useSource(identity)
        XCTAssertNil(model.snapshot)
        await model.refresh { snapshot }
        model.useSource(identity)
        XCTAssertNotNil(model.snapshot, "Foregrounding the same source keeps its last snapshot")
    }

    func testFreshnessResetUnlimitedAndExhaustion() async throws {
        let now = Date()
        let decoder = JSONDecoder()
        for data in [
            try fixture(checked: now.addingTimeInterval(-301)),
            try fixture(observed: now.addingTimeInterval(-601)),
            try fixture(reset: now.addingTimeInterval(-1)),
            try fixture(error: "Sign in on the Mac"),
        ] {
            XCTAssertTrue(try decoder.decode(CopilotUsageSnapshot.self, from: data).isStale(at: now))
        }
        let model = CopilotUsageModel()
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: 0)) }
        XCTAssertEqual(model.headerText(at: now), "0.0%")
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: nil, unlimited: true)) }
        XCTAssertEqual(model.headerText(at: now), "Unlimited")
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: nil)) }
        XCTAssertEqual(model.headerText(at: now), "--")
        XCTAssertFalse(model.snapshot!.account!.primary!.summary.contains("requests"))
    }

    func testUsageTransportDoesNotChangeSelectedSessionOrChatLane() async throws {
        let remote = CantripRemoteModel(urlSession: session())
        defer { remote.clearConfiguration() }
        let firstIdentity = remote.usageIdentity
        let configured = await remote.configure(url: "https://cantrip.example",
            pairingToken: "quota-test-token", tailscaleOnly: true)
        XCTAssertTrue(configured)
        XCTAssertNotEqual(firstIdentity, remote.usageIdentity)
        let data = try fixture()
        QuotaRequestProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/copilot/usage")
            return (200, data)
        }
        let value = try await remote.copilotUsage()
        XCTAssertNotNil(value.account)
        XCTAssertNil(remote.selectedSessionID)
        XCTAssertTrue(remote.sessions.isEmpty)
        XCTAssertFalse(remote.isMutating)
        remote.clearConfiguration()
        do {
            _ = try await remote.copilotUsage()
            XCTFail("Unconfigured usage must explain setup")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Configure Cantrip Remote"))
        }
    }

    func testQuotaRowsAndHeaderFitNarrowAndLargeTextLayouts() throws {
        let bucket = try XCTUnwrap(JSONDecoder().decode(CopilotUsageSnapshot.self, from: fixture()).account?.primary)
        for width: CGFloat in [288, 720] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                let row = UIHostingController(rootView: CopilotQuotaRow(bucket: bucket)
                    .environment(\.dynamicTypeSize, size))
                let measured = row.sizeThatFits(in: CGSize(width: width, height: 5000))
                XCTAssertLessThanOrEqual(measured.width, width + 1)
                XCTAssertGreaterThan(measured.height, 100)
                XCTAssertLessThan(measured.height, 4000)
            }
        }
        let button = UIHostingController(rootView: CopilotUsageButton(remote: CantripRemoteModel()))
        let measured = button.sizeThatFits(in: CGSize(width: 78, height: 44))
        XCTAssertEqual(measured.width, 78, accuracy: 1)
        XCTAssertEqual(measured.height, 44, accuracy: 1)
    }
}
