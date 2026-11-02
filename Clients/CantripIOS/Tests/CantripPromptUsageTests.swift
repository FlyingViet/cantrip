import XCTest
@testable import Hermes

final class CantripPromptUsageTests: XCTestCase {
    private let hostMessage = """
    {"id":"u1","role":"user","text":"How big is this prompt?","thinking":"","activities":[],
     "promptUsage":{"contextTokens":38210,"contextLimit":200000,"systemTokens":12000,"toolTokens":11118,
      "conversationTokens":15092,"messageTokens":1850,"addedTokens":1844,"latestContextTokens":41500,
      "modelCalls":2,"inputTokens":79400,"cachedInputTokens":68000,"outputTokens":1200}}
    """

    func testDecodesTheHostContract() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(hostMessage.utf8))
        let usage = try XCTUnwrap(message.promptUsage)
        XCTAssertEqual(usage.summary, "38.2k tokens of context · 19% of 200k")
        XCTAssertEqual(usage.sections.map(\.title), ["When sent", "This run"])
        XCTAssertEqual(usage.sections[0].rows.map(\.label),
                       ["Total", "System instructions", "Tool definitions", "Conversation", "This message", "Added by Cantrip"])
        XCTAssertEqual(usage.sections[0].rows.first?.value, 38_210.formatted() + " of " + 200_000.formatted())
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Input tokens" }?.value,
                       79_400.formatted() + " (86% cached)")
        XCTAssertEqual(usage.sections[1].rows.last?.label, "Latest context")
        XCTAssertTrue(usage.accessibilitySummary.hasPrefix(38_210.formatted() + " tokens of context, 19% of "))
    }

    func testOlderHostsAndPartialReportsStillDecode() throws {
        let legacy = #"{"id":"u1","role":"user","text":"hi","thinking":"","activities":[]}"#
        XCTAssertNil(try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(legacy.utf8)).promptUsage)

        // Claude Code reports totals and a context size, but no breakdown or window size.
        let partial = #"{"contextTokens":950,"messageTokens":20,"addedTokens":0}"#
        let usage = try JSONDecoder().decode(CantripPromptUsage.self, from: Data(partial.utf8))
        XCTAssertEqual(usage.summary, "950 tokens of context")
        XCTAssertEqual(usage.sections.map(\.title), ["When sent"])
        XCTAssertEqual(usage.sections[0].rows.map(\.label), ["Total", "This message"])

        let sentOnly = try JSONDecoder().decode(CantripPromptUsage.self, from: Data(#"{"messageTokens":1850}"#.utf8))
        XCTAssertEqual(sentOnly.summary, "About 1.9k tokens sent")
    }

    func testCompactFormatting() {
        XCTAssertEqual(CantripPromptUsage.compact(999), "999")
        XCTAssertEqual(CantripPromptUsage.compact(38_210), "38.2k")
        XCTAssertEqual(CantripPromptUsage.compact(412_000), "412k")
        XCTAssertEqual(CantripPromptUsage.compact(1_260_000), "1.3M")
        XCTAssertEqual(CantripPromptUsage.percent(1, of: 1_000), "<1%")
        XCTAssertEqual(CantripPromptUsage.percent(0, of: 0), "0%")
    }
}
