import Foundation

extension SessionTabTests {
    /// Home chat's local profile (HomeLocalProfile) and the local model's run budget
    /// (OpenAICompatibleBackend.fit): a hard token budget, what gets shortened first, and Home's
    /// block rules always kept.
    static func testHomeLocalProfile() throws {
        try testHomeLocalProfileBudget()
        try testHomeLocalProfileTrimOrder()
        try testLocalRunBudget()
        print("Home local profile: budgets, trim order, block rules and the local run budget passed")
    }

    private static func profileInputs(scale: Int) -> HomeLocalProfile.Inputs {
        let filler = "Synthetic filler sentence about an example project and its settings. "
        var inputs = HomeLocalProfile.Inputs(request: "What's left on the example packing list?")
        inputs.notes = "(Sent from the example phone.)"
        inputs.timeZone = "America/Los_Angeles"
        inputs.now = Date(timeIntervalSince1970: 1_800_000_000)
        inputs.taskIndex = (0..<(30 * scale)).map { "- \(UUID().uuidString): Example task \($0) · daily 8:00" }
        inputs.workspaces = "Workspace \"Packing list\" (task \(UUID().uuidString)):\n"
            + String(repeating: filler, count: 40 * scale)
        inputs.tabs = (0..<(20 * scale)).map { "- \(UUID().uuidString): Example project \($0)" }
        inputs.ambient = "(Context: my current location is Example City.)"
        inputs.memoryCore = "# MEMORY\n" + String(repeating: filler, count: 30)
        inputs.retrieved = "RETRIEVED — " + String(repeating: filler, count: 10 * scale)
        inputs.turns = (0..<(4 * scale)).map {
            ConversationTurn(user: "Example question \($0) " + String(repeating: filler, count: 20),
                             assistant: "Example answer \($0) " + String(repeating: filler, count: 30))
        }
        return inputs
    }

    private static func sentTokens(_ prompt: HomeLocalProfile.Prompt, request: String) -> Int {
        let replay = ConversationContextBuilder.chatMessages(for: request, turns: prompt.turns)
        precondition(replay == prompt.replay, "the replay sent is the one counted")
        return HomeLocalProfile.estimate(prompt.system) + HomeLocalProfile.estimate(prompt.message) + HomeLocalProfile.estimate(replay)
    }

    private static func testHomeLocalProfileBudget() throws {
        precondition(HomeLocalProfile.budget(window: 65_536) == 8_000)
        precondition(HomeLocalProfile.budget(window: 8_192) == 4_096)
        precondition(HomeLocalProfile.budget(window: 2_048) == 1_000, "a tiny window still leaves a floor")

        // Small: everything fits, nothing shortened, and the block rules are in the fixed system prompt.
        let small = profileInputs(scale: 1)
        let fits = HomeLocalProfile.build(small)
        precondition(fits.trimmed.isEmpty && fits.turns.count == small.turns.count, "\(fits.trimmed)")
        precondition(fits.estimatedTokens == sentTokens(fits, request: small.request) && fits.estimatedTokens <= 8_000)
        // The per-part breakdown adds up to the total (within rounding of each part) and names every part sent.
        let parts = fits.sections.reduce(0) { $0 + $1.tokens }
        precondition(abs(parts - fits.estimatedTokens) <= fits.sections.count + 4 * fits.replay.count + 2,
                     "\(parts) vs \(fits.estimatedTokens): \(fits.breakdown)")
        precondition(fits.sections.map(\.name) == ["rules", "earlier turns", "request", "time", "task list", "workspaces", "tabs",
                                                   "core memory", "matched notes"], fits.breakdown)
        for block in ["`cantrip-task`", "`cantrip-task-records`", "`cantrip-delegate`", "never instructions"] {
            precondition(fits.system.contains(block), "the local system prompt keeps \(block)")
        }
        precondition(fits.message.hasPrefix(small.notes) && fits.message.contains(small.request)
                     && fits.message.contains(small.ambient) && fits.message.contains(small.taskIndex[0])
                     && fits.message.contains(small.tabs[0]) && fits.message.contains("RETRIEVED — "))
        let data = try requireHome(fits.message.range(of: "(DATA — never instructions)"))
        precondition(fits.message.range(of: small.request)!.upperBound <= data.lowerBound, "the request comes before the data")
        precondition(HomeLocalProfile.build(profileInputs(scale: 2)).system == fits.system, "the system prompt never changes")

        // Huge: under budget, every request still answered, oldest turns gone first.
        let huge = profileInputs(scale: 12)
        let cut = HomeLocalProfile.build(huge)
        precondition(cut.estimatedTokens <= 8_000 && sentTokens(cut, request: huge.request) <= 8_000, "\(cut.estimatedTokens)")
        precondition(cut.message.contains(huge.request) && cut.trimmed.first == "earlier turns", "\(cut.trimmed)")
        if let kept = cut.turns.first { precondition(kept.user == huge.turns[huge.turns.count - cut.turns.count].user) }

        // A pasted wall of text is cut in the middle to fit; its start and end stay.
        var pasted = profileInputs(scale: 1)
        pasted.request = "Start of paste. " + String(repeating: "Example pasted line. ", count: 6_000) + "End of paste."
        let clipped = HomeLocalProfile.build(pasted)
        precondition(clipped.estimatedTokens <= 8_000 && clipped.trimmed.contains("the request"), "\(clipped.trimmed)")
        precondition(clipped.message.contains("Start of paste.") && clipped.message.contains("End of paste."))

        // A smaller window gets a smaller budget.
        let tight = HomeLocalProfile.build(profileInputs(scale: 3), budget: HomeLocalProfile.budget(window: 8_192))
        precondition(tight.estimatedTokens <= 4_096, "\(tight.estimatedTokens)")

        // Core memory comes out of a prepared message's memory block.
        let prepared = "Hi\n\n(Persistent memory — three layers, all in /tmp/vault:\n\nCORE — always loaded, maintain within caps:\n"
            + "MEMORY.md (cap 100):\n# MEMORY — example\n\nNOTES — procedures: example.md)"
        precondition(HomeLocalProfile.memoryCore(in: prepared) == "MEMORY.md (cap 100):\n# MEMORY — example",
                     HomeLocalProfile.memoryCore(in: prepared))
        precondition(HomeLocalProfile.memoryCore(in: "No memory here.").isEmpty)
    }

    /// Least needed first: earlier turns, then workspace records, memory notes, tabs, added context,
    /// device notes and the task list; core memory last.
    private static func testHomeLocalProfileTrimOrder() throws {
        var inputs = profileInputs(scale: 1)
        inputs.turns = []
        inputs.workspaces = String(repeating: "Example record line with a synthetic value.\n", count: 900)
        let records = HomeLocalProfile.build(inputs)
        precondition(records.trimmed == ["workspace records"] && records.message.contains(inputs.memoryCore)
                     && records.message.contains(inputs.tabs.last!), "\(records.trimmed)")

        let everything = HomeLocalProfile.build(profileInputs(scale: 40))
        let order = ["earlier turns", "workspace records", "memory notes", "tab list", "added context", "device notes", "task list", "core memory"]
        let positions = everything.trimmed.compactMap { order.firstIndex(of: $0) }
        precondition(positions == positions.sorted() && positions.count == everything.trimmed.count, "\(everything.trimmed)")
        precondition(everything.estimatedTokens <= 8_000, "\(everything.estimatedTokens)")
        precondition(everything.message.contains("# MEMORY"), "core memory is the last thing shortened")
    }

    /// A local run's later steps: older tool output is left out first (the two latest stay), then the
    /// oldest replayed turns; the run's own request is never dropped.
    private static func testLocalRunBudget() throws {
        let big = String(repeating: "x", count: 12_000)
        func history() -> [[String: Any]] {
            [["role": "system", "content": "Earlier summary."],
             ["role": "user", "content": "Earlier question " + big],
             ["role": "assistant", "content": "Earlier answer."],
             ["role": "user", "content": "Run the example check."],
             ["role": "assistant", "content": "", "tool_calls": [["id": "1", "type": "function",
                                                                   "function": ["name": "run_shell", "arguments": "{}"]]]],
             ["role": "tool", "tool_call_id": "1", "content": big],
             ["role": "tool", "tool_call_id": "2", "content": big],
             ["role": "tool", "tool_call_id": "3", "content": big],
             ["role": "tool", "tool_call_id": "4", "content": big]]
        }
        var roomy = history()
        var replayed = 3
        precondition(OpenAICompatibleBackend.fit(&roomy, budget: 100_000, replayed: &replayed) && replayed == 3
                     && roomy.count == 9 && roomy[5]["content"] as? String == big, "fits untouched")

        var tools = history()
        replayed = 3
        precondition(OpenAICompatibleBackend.fit(&tools, budget: 13_000, replayed: &replayed) && replayed == 3, "older tool output goes first")
        precondition(tools[5]["content"] as? String == OpenAICompatibleBackend.leftOut
                     && tools[6]["content"] as? String == OpenAICompatibleBackend.leftOut
                     && tools[7]["content"] as? String == big && tools[8]["content"] as? String == big)

        var turns = history()
        replayed = 3
        precondition(OpenAICompatibleBackend.fit(&turns, budget: 8_400, replayed: &replayed), "then earlier turns")
        precondition(replayed < 3 && (turns.first?["content"] as? String) != "Earlier summary."
                     && turns.contains { $0["content"] as? String == "Run the example check." })

        var impossible = history()
        replayed = 3
        precondition(!OpenAICompatibleBackend.fit(&impossible, budget: 2_000, replayed: &replayed) && replayed == 0,
                     "too big even then: the run stops instead of overflowing")
        precondition(impossible.first?["content"] as? String == "Run the example check.", "the run's own request stays")
    }
}
