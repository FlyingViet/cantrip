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

    private func fixture(remaining: Double? = 96.44224, unlimited: Bool = false,
                         amount: Double? = 964422.4, entitlement: Double? = 1000000,
                         billingMode: String = "credits",
                         checked: Date = Date(), observed: Date = Date(),
                         reset: Date = Date().addingTimeInterval(86400),
                         error: String? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var bucket: [String: Any] = [
            "id": "premium_interactions", "billingMode": billingMode,
            "isUnlimited": unlimited, "overage": 0, "overageAllowed": true,
            "resetAt": formatter.string(from: reset), "observedAt": formatter.string(from: observed),
        ]
        if let remaining { bucket["remainingPercent"] = remaining }
        if let amount { bucket["remaining"] = amount }
        if let entitlement { bucket["entitlement"] = entitlement }
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
        XCTAssertEqual(value.account?.primary?.remainingPercent, 96.44224)
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
        XCTAssertEqual(model.headerText(at: Date(), locale: Locale(identifier: "en_US")), "35.5K / 1M")
        XCTAssertTrue(model.accessibilityValue(at: Date()).contains("AI credits used"))
        await model.refresh { throw CantripRemoteError.transport("Offline") }
        XCTAssertEqual(model.headerText(at: Date()), "Stale")
        XCTAssertEqual(model.snapshot?.account?.primary?.remainingPercent, 96.44224)
        XCTAssertTrue(model.accessibilityValue(at: Date()).hasPrefix("Stale. Last known: "))
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
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: 0, amount: 0)) }
        XCTAssertEqual(model.headerText(at: now, locale: Locale(identifier: "en_US")), "1M / 1M")
        await model.refresh {
            try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: 100, amount: 1000000))
        }
        XCTAssertEqual(model.headerText(at: now, locale: Locale(identifier: "en_US")), "0 / 1M")
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: nil, unlimited: true)) }
        XCTAssertEqual(model.headerText(at: now), "Unlimited")
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: nil, amount: nil)) }
        XCTAssertEqual(model.headerText(at: now), "--")
        XCTAssertFalse(model.snapshot!.account!.primary!.summary.contains("requests"))
    }

    func testCreditAmountsPrecisionMissingValuesAndLegacyUnits() async throws {
        let locale = Locale(identifier: "en_US")
        let model = CopilotUsageModel()
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(CopilotUsageSnapshot.self, from: fixture())
        let bucket = try XCTUnwrap(snapshot.account?.primary)
        XCTAssertEqual(bucket.amountRatio(locale: locale), "35,577.6 / 1,000,000")
        XCTAssertTrue(bucket.summary.contains("AI credits used"))
        XCTAssertFalse(bucket.summary.contains("%"))
        XCTAssertEqual(bucket.percentageSummary, "3.6% used / 96.4% remaining")
        XCTAssertEqual(copilotAmount(999999.999, compact: true, locale: locale), "999.9K")
        XCTAssertEqual(copilotAmount(0.001, locale: locale), "<0.01")
        XCTAssertEqual(copilotAmount(0, locale: locale), "0")
        XCTAssertEqual(copilotAmount(12.349, locale: Locale(identifier: "de_DE")), "12,34")

        for data in [try fixture(amount: nil), try fixture(entitlement: nil), try fixture(amount: -1),
                     try fixture(amount: 1000001), try fixture(entitlement: -1)] {
            await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: data) }
            XCTAssertEqual(model.headerText(at: Date()), "--")
            XCTAssertEqual(model.snapshot?.account?.primary?.summary, "AI-credit amounts unavailable")
            XCTAssertNotNil(model.snapshot?.account?.primary?.percentageSummary)
        }
        await model.refresh { try decoder.decode(CopilotUsageSnapshot.self, from: fixture(remaining: nil)) }
        XCTAssertEqual(model.headerText(at: Date(), locale: locale), "35.5K / 1M",
                       "Amounts remain usable even when the percentage is absent")
        await model.refresh {
            try decoder.decode(CopilotUsageSnapshot.self,
                from: fixture(remaining: 75, amount: 225, entitlement: 300, billingMode: "requests"))
        }
        XCTAssertEqual(model.headerText(at: Date(), locale: locale), "75 / 300")
        XCTAssertTrue(model.snapshot!.account!.primary!.summary.contains("requests used"))
        XCTAssertFalse(model.snapshot!.account!.primary!.summary.contains("AI credits"))
        await model.refresh {
            try decoder.decode(CopilotUsageSnapshot.self,
                from: fixture(remaining: 80, billingMode: "unknown"))
        }
        XCTAssertEqual(model.headerText(at: Date()), "20.0%")
        XCTAssertNil(model.snapshot?.account?.primary?.amountRatio())
    }

    func testUsedAmountsPreserveDecimalPrecisionAndKeepOverageSeparate() throws {
        let locale = Locale(identifier: "en_US")
        for (remaining, expected) in [(100.0, "0 / 100"), (99.99, "0.01 / 100"),
                                       (99.999, "<0.01 / 100"), (0.0, "100 / 100")] {
            let bucket = CopilotQuotaBucket(id: "premium_interactions", billingMode: "credits",
                isUnlimited: false, remainingPercent: nil, entitlement: 100, remaining: remaining,
                overage: 25, overageAllowed: true, resetAt: nil, observedAt: nil)
            XCTAssertEqual(bucket.amountRatio(locale: locale), expected)
            XCTAssertTrue(bucket.summary.contains("AI credits used"))
        }
        let snapshot = try JSONDecoder().decode(CopilotUsageSnapshot.self,
            from: fixture(amount: 0, entitlement: 0))
        XCTAssertEqual(snapshot.account?.primary?.amountRatio(locale: locale), "0 / 0")
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
                if width == 288 && (size == .large || size == .accessibility5) {
                    let renderer = ImageRenderer(content: row.rootView.frame(width: width).padding()
                        .background(Color(uiColor: .systemBackground)))
                    let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                    attachment.name = "credit-details-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        let button = UIHostingController(rootView: CopilotUsageButton(remote: CantripRemoteModel()))
        let measured = button.sizeThatFits(in: CGSize(width: 124, height: 44))
        XCTAssertEqual(measured.width, 124, accuracy: 1)
        XCTAssertEqual(measured.height, 44, accuracy: 1)
        for text in ["35.5K / 1M", "999.9K / 1M", "<0.01 / 1M", "0 / 1M", "1M / 1M", "Unlimited", "Stale", "--"] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                let label = UIHostingController(rootView: CopilotUsageButton.CopilotUsageButtonLabel(text: text)
                    .environment(\.dynamicTypeSize, size))
                let measured = label.sizeThatFits(in: CGSize(width: 124, height: 44))
                XCTAssertEqual(measured.width, 124, accuracy: 1)
                XCTAssertEqual(measured.height, 44, accuracy: 1)
                if text == "35.5K / 1M" && (size == .large || size == .accessibility5) {
                    let renderer = ImageRenderer(content: label.rootView.padding()
                        .background(Color(uiColor: .systemBackground)))
                    renderer.scale = 3
                    let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                    attachment.name = "credit-header-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testHeaderIconsMatchAndShareOneRowInNavigationBar() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for size: DynamicTypeSize in [.large, .accessibility5] {
            for symbol in ["antenna.radiowaves.left.and.right", "gauge.with.dots.needle.33percent"] {
                let icon = UIHostingController(rootView: ChatHeaderIcon(systemName: symbol)
                    .environment(\.dynamicTypeSize, size))
                let measured = icon.sizeThatFits(in: CGSize(width: 100, height: 100))
                XCTAssertEqual(measured.width, 30, accuracy: 0.5)
                XCTAssertEqual(measured.height, 22, accuracy: 0.5)
            }
            for width: CGFloat in [320, 393, 768] {
                var laneFrame = CGRect.zero
                var usageFrame = CGRect.zero
                let content = NavigationStack {
                    Color(uiColor: .systemBackground)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                ChatHeader(title: "Bass Compass", isLocked: true) {
                                    Menu {
                                        Button("Cantrip Remote") {}
                                    } label: {
                                        ExecutionLaneBadge(lane: .cantrip, iconOnly: true)
                                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                                laneFrame = $0
                                            }
                                    }
                                    .menuIndicator(.hidden)
                                } usage: {
                                    Button {} label: {
                                        CopilotUsageButton.CopilotUsageButtonLabel(text: "35.5K / 1M")
                                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                                usageFrame = $0
                                            }
                                    }
                                }
                            }
                            ToolbarItem(placement: .topBarLeading) {
                                Button {} label: { Image(systemName: "line.3.horizontal") }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {} label: { Image(systemName: "gearshape") }
                            }
                        }
                }
                .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: content)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                XCTAssertEqual(laneFrame.height, 44, accuracy: 1)
                XCTAssertEqual(usageFrame.height, 44, accuracy: 1)
                XCTAssertEqual(laneFrame.midY, usageFrame.midY, accuracy: 0.5)
                XCTAssertLessThanOrEqual(laneFrame.maxX, usageFrame.minX)
                XCTAssertGreaterThanOrEqual(laneFrame.minX, 44)
                XCTAssertLessThanOrEqual(usageFrame.maxX, width - 44)
                let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 180))
                    .image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "aligned-header-\(Int(width))-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
