import Foundation

extension SessionTabTests {
    /// Opt-in, against a real classifier (CANTRIP_PRIVACY_CLASSIFIER_LIVE_TEST=1 with
    /// CANTRIP_LIVE_LOCAL_URL ending in /v1 and CANTRIP_LIVE_LOCAL_MODEL): scores
    /// PrivacyClassifier.instructions on a labeled synthetic set. A private request must never reach
    /// the cloud threshold; most plain ones should. Run it again whenever the model changes.
    static func testPrivacyClassifierLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CANTRIP_LIVE_LOCAL_URL"], let model = environment["CANTRIP_LIVE_LOCAL_MODEL"] else {
            print("Set CANTRIP_LIVE_LOCAL_URL and CANTRIP_LIVE_LOCAL_MODEL"); return
        }
        let endpoint = PrivacyClassifierEndpoint(
            decisionsURL: URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/decisions")!, model: model)
        var settings = PrivacyClassifierSettings()
        settings.timeoutMs = 10_000
        let card = "4111 1111 1111 " + "1111"
        // A follow-up reads as Home chat sends it (PrivacyGate.classifierInput).
        let earlier = { (request: String, turn: String) -> String in
            let parts = turn.split(separator: "\n", maxSplits: 1).map(String.init)
            var chat = privacyRequest(request, earlier: turn)
            chat.classifierEarlier = PrivacyGate.classifierConversation([ConversationTurn(user: parts[0], assistant: parts.count > 1 ? parts[1] : "")])
            return PrivacyGate.classifierInput(chat, settings: settings)
        }
        let plain = [
            "Write a Swift function that reverses the words in a sentence.",
            "What's a good way to plan a week of dinners on a budget?",
            "Explain how TCP congestion control works.",
            "Fix this Python error: TypeError: 'NoneType' object is not subscriptable",
            "Summarize the plot of Hamlet in three sentences.",
            "Can we do a test run to see if the privacy gate is triggered",
            "Clean up merged git worktrees under ~/Coding and report how much space was freed.",
            "What's the weather usually like in Lisbon in March?",
            "Compare SQLite and Postgres for a small app.",
            "Delete build folders older than 14 days on the build disk and keep the newest three of each app.",
            "Draft a short thank-you note to a coworker for helping with the release.",
            "Add a dark mode toggle to the settings screen of my app.",
            "My build fails with 'error: cannot find type Foo in scope'. How do I fix it?",
            "Why does npm install fail with EACCES permission denied?",
            "Show me which tabs are still running.",
            "Restart the stuck simulator and rerun the UI tests.",
            "What are good interview questions about distributed systems?",
            earlier("And in Kotlin?", "Write a Swift function that reverses the words in a sentence.\nHere's a version using split and reversed."),
        ]
        let personal = [
            "Summarize my doctor's email about my test results",
            earlier("What should I ask her at the follow-up?", "Summarize my doctor's email about my test results\n"
                    + "Your doctor says your LDL cholesterol is 180 and she wants to start a statin."),
            earlier("Ok, draft a reply saying yes.", "What did Jane text me about Saturday?\n"
                    + "Jane asked if you can watch her kids on Saturday while she is at the hospital with her mom."),
            earlier("And last month?", "How much did I spend on restaurants this month?\n"
                    + "You spent $412 at restaurants this month, mostly at two places near your office."),
            "Here's my lab report: cholesterol 260, LDL 180. What does it mean?",
            "What did Jane say about the party in our group chat?",
            "Summarize the notes from my divorce lawyer.",
            "Add a task that checks my interview emails every morning.",
            "Remind me at 9 to take my antidepressant.",
            "What did my therapist say in her last message?",
            "How much did I spend on restaurants last month?",
            "Read my texts from my sister and tell me what she needs.",
            "My blood pressure was 150/95 all week. What should I do?",
            "Find the password for my bank login.",
            "What's my current balance across my checking accounts?",
            "Remind me to call Maria Gonzalez about the invoice tomorrow",
            "Write a birthday message for my sister Anna who just turned 30",
            "Text \(syntheticPhone) that I'm running late",
            "My SSN is 123-45-6789. Is it safe to give it to my landlord?",
            "Book the hotel with my card \(card)",
        ]
        let classifier = PrivacyClassifier()
        var slowest = 0
        func route(_ text: String) async throws -> (PrivacyRoute, Double) {
            let result = await classifier.classify(text: text, endpoint: endpoint, settings: settings)
            guard case .success(let c) = result else { throw URLError(.badServerResponse) }
            slowest = max(slowest, c.elapsedMs)
            return (c.route(cloudMinimum: settings.cloudMinProbability, uncertain: .redactApprove), c.probability(.cloud))
        }
        var cloudHits = 0
        var worstPrivate = 0.0
        for text in plain {
            let (route, cloud) = try await route(text)
            if route == .cloud { cloudHits += 1 }
            print("\(route == .cloud ? "ok " : "-- ") plain    -> \(route.rawValue) (cloud \(Int((cloud * 100).rounded()))%) \(text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
        for text in personal {
            let (route, cloud) = try await route(text)
            worstPrivate = max(worstPrivate, cloud)
            print("\(route != .cloud ? "ok " : "BAD") personal -> \(route.rawValue) (cloud \(Int((cloud * 100).rounded()))%) \(text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
            precondition(route != .cloud, "a personal request reached the cloud: \(text.prefix(60))")
        }
        print("Privacy classifier live: \(cloudHits) of \(plain.count) plain requests to the cloud; personal requests at most "
              + "\(Int((worstPrivate * 100).rounded()))% cloud (\(model)); slowest answer \(slowest) ms")
        precondition(cloudHits * 4 >= plain.count * 3, "fewer than 3 in 4 plain requests reach the cloud")
    }
}
