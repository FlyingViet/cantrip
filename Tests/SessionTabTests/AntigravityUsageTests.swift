import Foundation

extension SessionTabTests {
    /// Antigravity's limits from `agy -p /usage --output-format json` (the shape agy 1.4.12 prints):
    /// per model group, and the group the Mac's model runs on at its limit sends messages to the fallback.
    @MainActor
    static func testAntigravityUsage() async throws {
        func bucket(_ id: String, _ window: String, _ fraction: Double, _ reset: String) -> [String: Any] {
            ["id": id, "name": window == "weekly" ? "Weekly Limit Remaining" : "Five Hour Limit Remaining",
             "window": window, "remaining_fraction": fraction, "reset_time": reset, "description": "…"]
        }
        func reply(geminiFiveHour: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "conversation_id": "", "status": "SUCCESS", "response": "Gemini Models\tWeekly Limit Remaining\t99%",
                "usage": ["input_tokens": 0, "output_tokens": 0],
                "command": ["name": "usage", "data": ["groups": [
                    ["name": "Gemini Models", "description": "Models within this group: Gemini Flash, Gemini Pro",
                     "buckets": [bucket("gemini-weekly", "weekly", 0.9892, "2026-11-07T02:31:18Z"),
                                 bucket("gemini-5h", "5h", geminiFiveHour, "2026-10-31T07:31:18Z")]],
                    ["name": "Claude and GPT models", "description": "Models within this group: Claude, GPT",
                     "buckets": [bucket("thirdparty-weekly", "weekly", 1, "2026-11-07T03:14:39Z"),
                                 bucket("thirdparty-5h", "5h", 1, "2026-10-31T08:14:39Z")]],
                    ["name": "Gemini 4 Argon", "buckets": [bucket("argon-weekly", "weekly", 0.25, "2026-11-07T03:14:39Z")]],
                ]]],
            ])
        }
        let usage = try requireHome(AntigravityUsageFetcher.parse(reply(geminiFiveHour: 0.97)))
        precondition(usage.groups.map(\.name) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"]
                     && usage.groups[0].models == "Gemini Flash, Gemini Pro"
                     && usage.groups[0].buckets.map(\.title) == ["Weekly limit", "5-hour limit"]
                     && abs(usage.groups[0].buckets[1].percentUsed - 3) < 0.01
                     && usage.groups[0].buckets[0].resetsAt == "2026-11-07T02:31:18Z"
                     && usage.primary?.bucket.id == "argon-weekly",
                     "Groups, windows, remaining and resets: \(usage)")
        precondition(usage.group(forModel: "")?.name == "Gemini Models"
                     && usage.group(forModel: "gemini-3.8-flash-medium")?.name == "Gemini Models"
                     && usage.group(forModel: "claude-opus-5-5-high")?.name == "Claude and GPT models"
                     && usage.group(forModel: "gpt-oss-120b-medium")?.name == "Claude and GPT models"
                     && usage.group(forModel: "gemini-4-argon-medium")?.name == "Gemini 4 Argon",
                     "Each model counts against its own group")
        precondition(AntigravityUsageFetcher.parse(Data(#"{"status":"SUCCESS","response":"hi"}"#.utf8)) == nil,
                     "A reply without groups is no answer")

        let now = copilotDate("2026-10-31T05:00:00Z")!
        let settings = AppSettings.shared
        let savedModel = settings.agyModel
        defer { settings.agyModel = savedModel }
        settings.agyModel = ""
        var agyCompletion: ((Result<AntigravityAccountUsage, Error>) -> Void)?
        let tracker = UsageTracker(quotaLoader: { $0(.failure(CopilotQuotaError.timeout)) }, claudeLoader: nil,
                                   antigravityLoader: { { agyCompletion = $0 } }, quotaClock: { now })
        BackendLimitTracker.shared.clear()
        defer { BackendLimitTracker.shared.clear() }
        tracker.refreshQuotas()
        precondition(agyCompletion != nil, "One refresh reads Antigravity too")
        agyCompletion?(.success(usage))
        try await Task.sleep(for: .milliseconds(20))
        precondition(tracker.copilotUsage.antigravity?.account == usage
                     && tracker.copilotUsage.antigravity?.isStale(at: now) == false
                     && BackendLimitTracker.shared.limitedUntil(.antigravity, now: now) == nil,
                     "Room left in the Gemini group: Antigravity stays in use")

        let full = try requireHome(AntigravityUsageFetcher.parse(reply(geminiFiveHour: 0)))
        let later = UsageTracker(quotaLoader: { $0(.failure(CopilotQuotaError.timeout)) }, claudeLoader: nil,
                                 antigravityLoader: { { $0(.success(full)) } }, quotaClock: { now })
        later.refreshQuotas()
        try await Task.sleep(for: .milliseconds(20))
        precondition(BackendLimitTracker.shared.limitedUntil(.antigravity, now: now) == copilotDate("2026-10-31T07:31:18Z"),
                     "Auto runs on Gemini: its full 5-hour window sends messages to the fallback until it resets")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(later.copilotUsage)) as? [String: Any]
        precondition(((encoded?["antigravity"] as? [String: Any])?["account"] as? [String: Any])?["groups"] != nil,
                     "Remote clients get Antigravity's limits under `antigravity`")
        print("Antigravity usage: /usage groups, windows, model groups, fallback on a full window and Remote passed")
    }
}
