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
        let sdk = try JSONDecoder().decode(CopilotAccountUsage.self, from: data)
        if normalized.isEmpty {
            // GitHub's own endpoint returns the same user payload: both readers must agree.
            let direct = try JSONSerialization.data(withJSONObject: user)
            let swift = QuotaFetcher.copilotAccount(fromUser: direct)
            let encoded = try JSONEncoder().encode(swift)
            precondition(!String(decoding: encoded, as: UTF8.self).contains("must-not-leave-process"))
            precondition(swift?.plan == sdk.plan && swift?.buckets.count == sdk.buckets.count,
                         "Direct and SDK readers agree: \(String(describing: swift))")
            for (a, b) in zip(swift?.buckets ?? [], sdk.buckets) {
                precondition(a.id == b.id && a.billingMode == b.billingMode && a.isUnlimited == b.isUnlimited
                             && a.remainingPercent == b.remainingPercent && a.entitlement == b.entitlement
                             && a.remaining == b.remaining && a.overage == b.overage
                             && a.overageAllowed == b.overageAllowed
                             && copilotDate(a.resetAt) == copilotDate(b.resetAt)
                             && copilotDate(a.observedAt) == copilotDate(b.observedAt),
                             "Bucket \(a.id): direct \(a) vs SDK \(b)")
            }
        }
        return sdk
    }

    /// Claude's limits from its usage reply, how the tracker keeps them, and a full window reaching
    /// the fallback tracker before Claude refuses a message.
    @MainActor
    static func testClaudeUsage() async throws {
        let reply = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 89.0, "resets_at": "2026-10-29T16:00:00.008092+00:00", "locked_reason": NSNull()],
            "seven_day": ["utilization": 31, "resets_at": "2026-11-03T04:00:00.008112+00:00"],
            "seven_day_opus": NSNull(), "seven_day_sonnet": ["utilization": 100, "resets_at": "2026-11-02T04:00:00Z"],
            "limits": [["kind": "session", "severity": "warning"], ["kind": "weekly_all", "severity": "normal"],
                       ["kind": "weekly_sonnet", "severity": "critical"]],
        ])
        let usage = try requireHome(ClaudeUsageFetcher.parse(reply, plan: "max"))
        precondition(usage.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_sonnet"]
                     && usage.windows[0].percentUsed == 89 && usage.windows[0].severity == "warning"
                     && usage.windows[0].resetsAt == "2026-10-29T16:00:00Z"
                     && usage.windows[2].severity == "critical" && usage.windows[2].isExhausted
                     && usage.primary?.id == "seven_day_sonnet" && usage.plan == "max",
                     "Windows, severity and resets: \(usage)")
        precondition(ClaudeUsageFetcher.parse(Data("{}".utf8), plan: nil) == nil, "No windows is no answer")
        let credentials = ClaudeUsageFetcher.credentials(from: Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1800000000000,"subscriptionType":"max"}}"#.utf8))
        precondition(credentials == .init(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), plan: "max"))
        precondition(ClaudeUsageFetcher.credentials(from: Data("{}".utf8)) == nil)

        let now = copilotDate("2026-10-29T15:00:00Z")!
        var claudeCompletion: ((Result<ClaudeAccountUsage, Error>) -> Void)?
        var copilotCompletion: ((Result<CopilotAccountUsage, Error>) -> Void)?
        let tracker = UsageTracker(quotaLoader: { copilotCompletion = $0 }, claudeLoader: { claudeCompletion = $0 },
                                   quotaClock: { now })
        BackendLimitTracker.shared.clear()
        defer { BackendLimitTracker.shared.clear() }
        tracker.refreshQuotas()
        precondition(claudeCompletion != nil && copilotCompletion != nil, "One refresh reads every backend")
        claudeCompletion?(.success(usage))
        try await Task.sleep(for: .milliseconds(20))
        precondition(tracker.copilotUsage.isRefreshing, "Still refreshing until Copilot answers too")
        copilotCompletion?(.failure(CopilotQuotaError.timeout))
        try await Task.sleep(for: .milliseconds(20))
        precondition(!tracker.copilotUsage.isRefreshing && tracker.copilotUsage.claude?.account == usage
                     && tracker.copilotUsage.claude?.isStale(at: now) == false)
        precondition(BackendLimitTracker.shared.limitedUntil(.claudeCode, now: now) == copilotDate("2026-11-02T04:00:00Z"),
                     "A full window sends messages to the fallback until it resets")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tracker.copilotUsage)) as? [String: Any]
        precondition(((encoded?["claude"] as? [String: Any])?["account"] as? [String: Any])?["windows"] != nil,
                     "Remote clients get Claude's limits under `claude`")
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
        }, claudeLoader: nil, quotaClock: { now })
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
