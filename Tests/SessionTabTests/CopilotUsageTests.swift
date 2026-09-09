import Foundation

extension SessionTabTests {
    static func projectQuota(_ bucket: [String: Any], userFields: [String: Any] = [:],
                             normalized: [String: Any] = [:]) throws -> CopilotAccountUsage {
        var user: [String: Any] = [
            "quota_snapshots": ["premium_interactions": bucket],
            "quota_reset_date_utc": "2026-10-01T00:00:00Z",
            "copilot_plan": "individual", "token_based_billing": true,
            "unrelated_private_field": "must-not-leave-process",
        ]
        user.merge(userFields) { _, new in new }
        let fixture: [String: Any] = [
            "quota": ["quotaSnapshots": ["premium_interactions": normalized]],
            "auth": ["authInfo": [
                "login": "quota-fixture", "token": "must-not-leave-process",
                "copilotUser": user,
            ]],
        ]
        let script = QuotaFetcher.script.components(separatedBy: "let client;\n")[0]
            + "\nconst fixture = JSON.parse(process.env.QUOTA_TEST_INPUT);"
            + "\nconsole.log(JSON.stringify(project(fixture.quota, fixture.auth)));"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["QUOTA_TEST_INPUT"] = String(decoding: try JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        precondition(!String(decoding: data, as: UTF8.self).contains("must-not-leave-process"))
        return try JSONDecoder().decode(CopilotAccountUsage.self, from: data)
    }

    @MainActor
    static func testCopilotUsage() async throws {
        let account = try projectQuota([
            "entitlement": 1000, "quota_remaining": 964.1234, "remaining": 964,
            "percent_remaining": 96, "quota_reset_at": 0, "unlimited": false,
            "overage_count": 0, "overage_permitted": true,
        ], normalized: ["resetDate": "2026-09-08T00:00:00Z", "remainingPercentage": 96])
        let primary = account.primary!
        precondition(abs(primary.remainingPercent! - 96.41234) < 0.00001)
        precondition(primary.resetAt == "2026-10-01T00:00:00.000Z", "Never use SDK's bogus reset time")
        precondition(primary.billingMode == "credits" && !primary.summary.contains("requests"))
        precondition(primary.overage == 0 && primary.overageAllowed == true)
        let locale = Locale(identifier: "en_US")
        precondition(primary.remaining == 964.1234 && primary.entitlement == 1000)
        precondition(primary.amountRatio(locale: locale) == "35.87 / 1,000")
        precondition(primary.amountRatio(compact: true, locale: locale) == "35.87 / 1K")
        precondition(primary.summary.contains("AI credits used") && !primary.summary.contains("%"))
        precondition(primary.percentageSummary == "3.6% used / 96.4% remaining")
        let large = try projectQuota(["entitlement": 1000000, "quota_remaining": 964422.4])
        precondition(large.primary!.amountRatio(locale: locale) == "35,577.6 / 1,000,000")
        precondition(large.primary!.amountRatio(compact: true, locale: locale) == "35.5K / 1M")
        precondition(copilotAmount(999999.999, compact: true, locale: locale) == "999.9K")
        precondition(copilotAmount(0.001, locale: locale) == "<0.01")
        precondition(copilotAmount(0, locale: locale) == "0")
        precondition(copilotAmount(12.349, locale: Locale(identifier: "de_DE")) == "12,34")

        let unlimited = try projectQuota(["entitlement": -1, "unlimited": true, "percent_remaining": 100])
        precondition(unlimited.primary!.isUnlimited && unlimited.primary!.remainingPercent == nil)
        precondition(unlimited.primary!.amountRatio() == nil && unlimited.primary!.summary.hasPrefix("Unlimited"))
        let exhausted = try projectQuota(["entitlement": 100, "quota_remaining": 0, "overage_permitted": false])
        precondition(exhausted.primary!.remainingPercent == 0)
        precondition(exhausted.primary!.amountRatio(locale: locale) == "100 / 100")
        for (remaining, expected) in [(100.0, "0 / 100"), (99.99, "0.01 / 100"),
                                       (99.999, "<0.01 / 100"), (0.0, "100 / 100")] {
            let quota = try projectQuota(["entitlement": 100, "quota_remaining": remaining, "overage_count": 25])
            precondition(quota.primary!.amountRatio(locale: locale) == expected,
                         "Show included usage as total minus remaining, with overage separate")
        }
        let zeroTotal = try projectQuota(["entitlement": 0, "quota_remaining": 0])
        precondition(zeroTotal.primary!.amountRatio(locale: locale) == "0 / 0")
        let unknown = try projectQuota([:], userFields: ["quota_reset_date_utc": "invalid"])
        precondition(unknown.primary!.remainingPercent == nil && unknown.primary!.resetAt == nil)
        precondition(unknown.primary!.summary == "AI-credit amounts unavailable")
        let requests = try projectQuota(["entitlement": 300, "remaining": 200, "token_based_billing": false])
        precondition(requests.primary!.billingMode == "requests")
        precondition(requests.primary!.amountRatio(locale: locale) == "100 / 300")
        precondition(requests.primary!.summary.contains("requests used"))
        precondition(!requests.primary!.summary.contains("AI credits"))
        let fallback = try projectQuota([:], normalized: [
            "isUnlimitedEntitlement": false, "remainingPercentage": 50, "entitlementRequests": 300,
            "overage": 2, "overageAllowedWithExhaustedQuota": true,
        ])
        precondition(fallback.primary!.remainingPercent == 50 && fallback.primary!.overage == 2)
        precondition(fallback.primary!.amountRatio() == nil, "Do not invent amounts from a rounded percentage")
        let missingTotal = try projectQuota(["quota_remaining": 50, "percent_remaining": 50])
        let negative = try projectQuota(["entitlement": 100, "quota_remaining": -1])
        precondition(missingTotal.primary!.amountRatio() == nil && negative.primary!.amountRatio() == nil)
        let aboveTotal = try projectQuota(["entitlement": 100, "quota_remaining": 101])
        precondition(aboveTotal.primary!.amountRatio() == nil, "Invalid balances must not show negative usage")
        let unknownUnits = try projectQuota(["entitlement": 100, "remaining": 50],
                                           userFields: ["token_based_billing": NSNull()])
        precondition(unknownUnits.primary!.amountRatio() == nil && unknownUnits.primary!.unit == nil)
        let epoch = try projectQuota(["quota_reset_at": 1790812800])
        precondition(epoch.primary!.resetAt == "2026-10-01T00:00:00.000Z")

        var now = copilotDate("2026-09-08T22:00:00Z")!
        var completion: ((Result<CopilotAccountUsage, Error>) -> Void)?
        var calls = 0
        let tracker = UsageTracker(quotaLoader: {
            calls += 1
            completion = $0
        }, quotaClock: { now })
        tracker.refreshQuotas()
        tracker.refreshQuotas()
        precondition(calls == 1 && tracker.copilotUsage.isRefreshing)
        completion?(.success(account))
        try await Task.sleep(for: .milliseconds(20))
        precondition(!tracker.copilotUsage.isRefreshing && tracker.copilotUsage.error == nil)
        precondition(!tracker.copilotUsage.isStale(at: now))
        tracker.refreshQuotas()
        precondition(calls == 1, "Manual/Remote refresh must share the same throttle")
        now = now.addingTimeInterval(61)
        tracker.refreshQuotas()
        precondition(calls == 2)
        completion?(.failure(CopilotQuotaError.timeout))
        try await Task.sleep(for: .milliseconds(20))
        precondition(tracker.copilotUsage.account?.primary?.remainingPercent == primary.remainingPercent)
        precondition(tracker.copilotUsage.isStale(at: now) && tracker.copilotUsage.error != nil)
        now = now.addingTimeInterval(61)
        tracker.refreshQuotas()
        completion?(.success(requests))
        try await Task.sleep(for: .milliseconds(20))
        precondition(tracker.copilotUsage.account?.primary?.billingMode == "requests")
        precondition(!tracker.copilotUsage.isStale(at: now))
        precondition(tracker.copilotUsage.isStale(at: now.addingTimeInterval(301)))

        let staleSource = try projectQuota(["observedAt": "ignored", "timestamp_utc": "2026-09-08T20:00:00Z"])
        let snapshot = CopilotUsageSnapshot(account: staleSource, checkedAt: "2026-09-08T22:00:00Z")
        precondition(snapshot.isStale(at: now))
        print("Copilot usage projection, precision, reset, freshness, caching and failure tests passed")
    }
}
