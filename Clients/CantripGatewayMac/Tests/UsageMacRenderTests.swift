import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Usage Limits as the Mac's sheet shows it: each limit's use and reset, for every backend.
@MainActor
final class UsageMacRenderTests: XCTestCase {
    /// Renders for review. Set TEST_RUNNER_USAGE_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testUsageLimitsMacScreenshot() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_USAGE_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_USAGE_ARTIFACT_DIR to render Usage Limits on the Mac.")
        }
        let now = Date(), iso = ISO8601DateFormatter()
        func at(_ hours: Double) -> String { iso.string(from: now.addingTimeInterval(hours * 3600)) }
        func bucket(_ id: String, _ window: String, _ remaining: Double, _ reset: Double) -> [String: Any] {
            ["id": id, "name": window, "window": window, "remainingPercent": remaining, "resetsAt": at(reset)]
        }
        let snapshot: [String: Any] = [
            "checkedAt": at(0), "isRefreshing": false, "activeBackend": "Claude Code",
            "account": ["login": "account", "plan": "enterprise", "buckets": [
                ["id": "premium_interactions", "billingMode": "credits", "isUnlimited": false, "remainingPercent": 0,
                 "entitlement": 1_000_000, "remaining": 0, "overage": 0, "overageAllowed": false,
                 "resetAt": at(21), "observedAt": at(0)],
                ["id": "chat", "billingMode": "credits", "isUnlimited": true, "observedAt": at(0)],
            ]],
            "claude": ["checkedAt": at(0), "account": ["plan": "max", "windows": [
                ["id": "five_hour", "percentUsed": 42, "resetsAt": at(2.5), "severity": "normal"],
                ["id": "seven_day", "percentUsed": 31, "resetsAt": at(100)],
            ]]],
            "antigravity": ["checkedAt": at(0), "account": ["groups": [
                ["name": "Gemini Models", "buckets": [bucket("gemini-weekly", "weekly", 99, 166), bucket("gemini-5h", "5h", 96, 4.5)]],
                ["name": "Claude and GPT models", "buckets": [bucket("tp-weekly", "weekly", 100, 167), bucket("tp-5h", "5h", 100, 5.5)]],
                ["name": "Gemini 4 Argon", "buckets": [bucket("argon-weekly", "weekly", 100, 167)]],
            ]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        let model = CopilotUsageModel()
        await model.refresh { try JSONDecoder().decode(CopilotUsageSnapshot.self, from: data) }
        XCTAssertNotNil(model.snapshot?.antigravity)
        let view = CopilotUsageView(model: model, remote: CantripRemoteModel())
            .frame(width: 520, height: 1180)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 1180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("usage-limits-mac.png"))
    }
}
