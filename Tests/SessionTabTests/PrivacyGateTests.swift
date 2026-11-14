import Foundation

extension SessionTabTests {
    /// The Privacy Gate: rules and detectors, the classifier client (rotations, averaging, timeout,
    /// never cloud on failure), the policy section (absent, partial, kept by older clients),
    /// observe mode changing nothing, and enforce mode's routes for Home chat and tasks.
    @MainActor
    static func testPrivacyGate() async throws {
        try testPrivacyDetectorsAndRules()
        try await testPrivacyClassifierClient()
        try testPrivacyPolicySection()
        try await testPrivacyGateObserveAndEnforce()
        try await testPrivacyHints()
        print("Privacy Gate: detectors, rules, classifier client, policy section, observe no-op and enforce routing passed")
    }

    // Synthetic values, built at run time so the source holds no credential-shaped literal.
    static let syntheticSecret = "api_key=" + "Qm7Xp2" + "Lr9Vt4Kw8"
    static let syntheticPhone = "(415) 555-" + "0134"

    static func privacyRequest(_ request: String, earlier: String = "", message: String? = nil, workdir: String = "",
                               kind: PrivacyGateRequest.Kind = .homeChat, task: UUID? = nil) -> PrivacyGateRequest {
        PrivacyGateRequest(kind: kind, taskID: task, taskTitle: task == nil ? nil : "Synthetic task",
                           conversationKey: task.map { "task:\($0.uuidString)" } ?? "home-chat-test",
                           request: request, earlier: earlier, message: message ?? request, workdir: workdir,
                           backend: "copilot", mcpServers: ["personal", "homelab", "docs"])
    }

    static func testPrivacyDetectorsAndRules() throws {
        let scan = { PrivacyDetectors.scan($0) }
        precondition(scan("Deploy with \(syntheticSecret) tonight")[.secret, default: 0] > 0, "a credential assignment")
        precondition(scan("SSN 123-45-6789")[.ssn] == 1 && scan("ref 000-12-3456")[.ssn] == 0, "SSN shape, not 000")
        precondition(scan("card 4111 1111 1111 1111")[.card] == 1 && scan("order 4111 1111 1111 1112")[.card] == 0,
                     "Luhn-valid card numbers only")
        precondition(scan("account number 12345678")[.account] == 1, "account numbers")
        precondition(scan("write to jane.doe@example.com")[.email] == 1
                     && scan("Co-authored-by: Bot <123+bot@users.noreply.github.com>")[.email] == 0, "emails, not noreply")
        precondition(scan("call \(syntheticPhone)")[.phone] == 1 && scan("build 1.1.18-63")[.phone] == 0, "phone numbers")
        precondition(scan("Ship it to 742 Evergreen Terrace, Springfield, OR 97477")[.address] == 1, "street addresses")
        precondition(scan("Ask Maria Gonzalez about the invoice")[.name, default: 0] >= 1, "people's names")
        precondition(scan("Ask Claude or Copilot to review the diff")[.name] == 0, "assistant names aren't people")
        // The owner's own names (whole or in part) and acronyms the tagger reads as names don't count.
        let owners = ["Jordan Rivera"]
        let mention = "Jordan Rivera asked to free 40 GB on the build disk."
        precondition(scan(mention)[.name, default: 0] >= 1, "without owner names it's a person: \(scan(mention))")
        precondition(PrivacyDetectors.scan(mention, ownerNames: owners)[.name] == 0
                     && PrivacyDetectors.scan("Jordan, free some space", ownerNames: owners)[.name] == 0, "the owner isn't counted")
        precondition(PrivacyDetectors.personalNames(in: "Jordan Rivera and Maria Gonzalez met", ignoring: owners) >= 1,
                     "other people still count")
        precondition(PrivacyDetectors.personalNames(in: "Keep 40 GB free. NAS backups run nightly.") == 0, "units and acronyms aren't people")
        let code = scan("How do I reverse the words in a Swift string?")
        precondition(code.values.allSatisfy { $0 == 0 }, "a code question has no hits: \(code)")
        precondition(PrivacyDetectors.privateTermCount(["Zephyrine"], in: "notes for zephyrine's party") == 1
                     && PrivacyDetectors.privateTermCount(["Zephyr"], in: "Zephyrine") == 0, "whole private terms")

        // The always-loaded core memory never counts; retrieved snippets do.
        let memory = """
        Question about lunch.

        (Persistent memory — three layers, all in /vault:

        CORE — always loaded, maintain within caps:
        USER: Pat Example, phone \(syntheticPhone)

        NOTES — procedures that worked; read relevant ones BEFORE acting: a.md

        SESSIONS — past conversations logged in /vault/sessions/ as daily markdown; grep them when I reference something from before.

        RETRIEVED — memory snippets auto-matched to this query (verify before relying on them):
        lunch with jane.doe@example.com

        Maintain memory silently as you work: … Don't mention the vault unless asked.)
        """
        let split = PrivacyRules.split(message: memory)
        precondition(!split.withoutMemory.contains("555") && split.withoutMemory.contains("Question about lunch")
                     && split.retrieved.contains("jane.doe@example.com") && !split.retrieved.contains("Pat Example"), "\(split)")
        let task = PrivacyRules.split(message: "HEAD\n\n(Persistent memory — three layers …\nCORE …\nDon't mention the vault unless asked.)\n\nRun the task.\n\n(RETRIEVED — memory snippets auto-matched to this task (x):\nsnippet)")
        precondition(task.withoutMemory.contains("Run the task.") && task.withoutMemory.contains("HEAD")
                     && task.retrieved.contains("snippet") && !task.withoutMemory.contains("CORE"), "task layout: \(task)")

        // First match wins, in order.
        let settings = PrivacyGateSettings()
        func rule(_ request: PrivacyGateRequest, terms: [String] = [], repo: Bool = false) -> PrivacyRuleOutcome {
            PrivacyRules.evaluate(request, settings: settings, privateTerms: terms, isRepository: { _ in repo })
        }
        precondition(rule(privacyRequest("Use \(syntheticSecret) to deploy")).rule?.id == "secrets")
        precondition(rule(privacyRequest("Summarize my emails from today")).rule?.id == "private-sources")
        precondition(rule(privacyRequest("What did my bank statement say about fees?")).rule?.route == .local)
        // Numbers that identify someone decide; names, terms and contact details hand over to the classifier.
        let card = rule(privacyRequest("Pay with 4111 1111 1111 1111"))
        precondition(card.rule?.id == "personal-details" && card.rule?.route == .redactApprove && card.rule?.askClassifier != true)
        precondition(rule(privacyRequest("My SSN is 123-45-6789")).rule?.id == "personal-details")
        let pii = rule(privacyRequest("Text \(syntheticPhone) that I'm late"))
        precondition(pii.rule?.id == "personal-hints" && pii.rule?.askClassifier == true && pii.hits["phone@request"] == 1, "\(pii)")
        precondition(rule(privacyRequest("Plan the trip with Zephyrine"), terms: ["Zephyrine"]).rule?.id == "personal-hints")
        precondition(rule(privacyRequest("Fix the failing test", workdir: "/tmp/repo"), repo: true).rule?.id == "code")
        precondition(rule(privacyRequest("How do I reverse a list?")).rule == nil)
        // Personal details in added context (Home's data, location) are recorded but don't decide by default.
        let context = rule(privacyRequest("How do I reverse a list?", message: "How do I reverse a list?\n\nCall \(syntheticPhone)"))
        precondition(context.rule == nil && context.hits["phone@context"] == 1, "\(context)")
        // Home's own data is full of names and private terms: they're recorded and never decide.
        let homeData = "How do I reverse a list?\n\n(CANTRIP HOME — data: tab “Party for Maria Gonzalez” in /Volumes/Zephyrine)"
        let busy = rule(privacyRequest("How do I reverse a list?", earlier: "Ask Maria Gonzalez about Zephyrine", message: homeData),
                        terms: ["Zephyrine"])
        precondition(busy.rule == nil && busy.hits["privateTerm@context"] == 1 && busy.hits["privateTerm@earlier"] == 1, "\(busy)")
        // An earlier turn counts for numbers that identify someone, not for weaker signs.
        precondition(rule(privacyRequest("And then?", earlier: "My SSN is 123-45-6789")).rule?.id == "personal-details")
        precondition(rule(privacyRequest("And then?", earlier: "Text \(syntheticPhone) about dinner")).rule == nil)
        // A weak sign comes before the code rule: the classifier decides, not "it's a repository".
        precondition(rule(privacyRequest("Send the diff to jane.doe@example.com", workdir: "/tmp/repo"), repo: true).rule?.id == "personal-hints")

        // A saved copy of the old rule (weak signs anywhere decided) is split; other rules stay as saved.
        func decoded(_ rules: [PrivacyGateRule]) throws -> [PrivacyGateRule] {
            var saved = PrivacyGateSettings()
            saved.rules = rules
            return try JSONDecoder().decode(PrivacyGateSettings.self, from: JSONEncoder().encode(saved)).rules
        }
        var oldOff = PrivacyGateRule.previousPersonalDetails
        oldOff.enabled = false
        let old = try decoded([PrivacyGateRule.defaults[0], oldOff, PrivacyGateRule.defaults.last!])
        precondition(old.map(\.id) == ["secrets", "personal-details", "personal-hints", "code"]
                     && old[1].detectors == [.ssn, .card, .account] && old[2].askClassifier == true
                     && !old[1].enabled && !old[2].enabled, "\(old.map(\.id))")
        var custom = PrivacyGateRule.previousPersonalDetails
        custom.scope = [.request]
        let kept = try decoded([custom])
        let current = try decoded(PrivacyGateRule.defaults)
        precondition(kept == [custom] && current == PrivacyGateRule.defaults, "a changed rule is the user's own")
        var named = PrivacyGateSettings()
        named.ownerNames = ["Jordan Rivera"]
        let roundTrip = try JSONDecoder().decode(PrivacyGateSettings.self, from: JSONEncoder().encode(named))
        precondition(roundTrip.ownerNames == ["Jordan Rivera"])
        named.ownerNames = Array(repeating: "x", count: 21)
        precondition(!named.validationErrors().isEmpty, "a bounded owner list")
        // A disabled rule is skipped.
        var off = settings
        off.rules[0].enabled = false
        precondition(PrivacyRules.evaluate(privacyRequest("Use \(syntheticSecret)"), settings: off, privateTerms: [])
            .rule?.id != "secrets")
    }

    /// A weak sign hands the decision to the classifier (or decides when there's none); `trial`
    /// (`cantrip privacy test`) decides without recording, and says what the classifier thinks.
    static func testPrivacyHints() async throws {
        let gate = PrivacyGate.shared
        let saved = (gate.classifier, gate.directory, gate.privateLocal, gate.policy)
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-hints-\(UUID().uuidString)")
        defer {
            (gate.classifier, gate.directory, gate.privateLocal, gate.policy) = saved
            try? FileManager.default.removeItem(at: logs)
        }
        gate.directory = logs
        gate.privateLocal = {
            var local = PrivateLocalConfiguration()
            local.api = .openAI
            local.baseURL = "https://model-server.local/v1"
            local.model = "local-model"
            return local
        }
        var section = PrivacyGateSettings()
        section.ownerNames = ["Jordan Rivera"]
        gate.policy = { var document = AgentPolicyDocument(); document.privateTerms = ["Zephyrine"]; document.privacyGate = section; return document }
        var calls = 0
        var answer = (local: 0.03, cloud: 0.95)
        var delay: UInt64 = 0
        gate.classifier = PrivacyClassifier(transport: { request in
            calls += 1
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            let redact = max(0, 1 - answer.local - answer.cloud)
            let data = decisionsReply((0..<3).map { _ in [("local", answer.local), ("cloud", answer.cloud), ("redact", redact)] })
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        // A name in the request: the classifier decides (here, cloud); the hint is recorded.
        let named = privacyRequest("Remind me to call Maria Gonzalez about the invoice")
        let cloud = await gate.decide(named, settings: section)
        precondition(cloud.route == .cloud && cloud.source == .classifier && cloud.rule == nil && cloud.hint == "personal-hints"
                     && cloud.reason.hasPrefix("personal-hints (") && calls == 1, "\(cloud)")
        gate.record(cloud, request: named, settings: section, applied: false, totalMs: 1)
        let logged = gate.records(since: .distantPast)
        precondition(logged.last?.hint == "personal-hints" && logged.last?.rule == nil, "\(logged)")
        precondition(gate.report(days: 1).contains("matched personal-hints, which leaves the decision to the classifier"))
        // Answers just under the threshold in use are counted against that threshold.
        var close = cloud
        close.probabilities = [.cloud: 0.72, .local: 0.2, .redactApprove: 0.08]
        close.route = .redactApprove
        gate.record(close, request: named, settings: section, applied: false, totalMs: 1)
        precondition(gate.report(days: 1).contains("1 answers were 55-74% cloud: just under the cloud threshold (75%)."),
                     gate.report(days: 1))

        // The owner's own name and Home's data alone are no hint at all.
        let own = await gate.decide(privacyRequest("Jordan Rivera here: how do I reverse a list?",
                                                   message: "Jordan Rivera here: how do I reverse a list?\n\nTabs: Zephyrine, Maria Gonzalez"),
                                    settings: section)
        precondition(own.hint == nil && own.rule == nil && own.source == .classifier, "\(own)")

        // Without a classifier the hint decides, as the rule's own route.
        var off = section
        off.classifier.enabled = false
        let fallback = await gate.decide(privacyRequest("Plan the trip with Zephyrine"), settings: off)
        precondition(fallback.route == .redactApprove && fallback.source == .rule && fallback.rule == "personal-hints"
                     && fallback.hint == nil, "\(fallback)")

        // A trial records nothing; when a rule decides, it still says what the classifier thinks.
        let before = gate.records(since: .distantPast).count
        answer = (0.9, 0.05)
        let card = await gate.trial(privacyRequest("Pay the deposit with 4111 1111 1111 1111"), settings: section)
        precondition(card.decision.rule == "personal-details" && card.decision.route == .redactApprove
                     && card.classifier?.route == .local && (card.classifier?.probabilities?[.local] ?? 0) > 0.85, "\(card)")
        answer = (0.03, 0.95)
        let code = await gate.trial(privacyRequest("Write a Swift function that reverses a sentence."), settings: section)
        precondition(code.decision.route == .cloud && code.decision.source == .classifier && code.classifier == nil, "\(code)")
        precondition(gate.records(since: .distantPast).count == before, "a trial isn't recorded")

        // A scheduled task waits longer for the classifier than Home chat does.
        var slow = section
        slow.classifier.timeoutMs = 500
        slow.classifier.taskTimeoutMs = 3_000
        delay = 1_200_000_000
        let chat = await gate.decide(privacyRequest("Explain how a B-tree splits a node."), settings: slow)
        precondition(chat.source == .offline && chat.route == nil && chat.classifierMs == 500, "\(chat)")
        let task = await gate.decide(privacyRequest("Delete build folders older than 14 days.", kind: .homeTask, task: UUID()),
                                     settings: slow)
        precondition(task.source == .classifier && task.route == .cloud, "\(task)")
        delay = 0
        slow.classifier.taskTimeoutMs = 100
        precondition(!slow.validationErrors().isEmpty, "a bounded task timeout")
        try testPrivacyClassifierInput()
    }

    /// Home chat's classifier reads the request, the user's earlier messages and the start of the
    /// latest reply within chatInputCharacters (so it answers within the chat timeout); tasks keep
    /// their input.
    static func testPrivacyClassifierInput() throws {
        let classifier = PrivacyClassifierSettings()
        precondition(classifier.chatInputCharacters == 900 && classifier.maxInputCharacters == 3000 && classifier.timeoutMs == 2500)
        let reply = String(repeating: "The release notes cover the parser and the build cache. ", count: 90)
        let conversation = PrivacyGate.classifierConversation([
            ConversationTurn(user: "Draft the release notes", assistant: "An old reply that stays out."),
            ConversationTurn(user: " Plan the release notes ", assistant: reply),
        ])
        let opening = String(reply.trimmingCharacters(in: .whitespaces).prefix(PrivacyGate.classifierReplyCharacters))
        precondition(conversation == "Draft the release notes\n\nPlan the release notes\n" + opening,
                     "the user's messages, and only the start of the latest reply: \(conversation)")
        precondition(PrivacyGate.classifierConversation([]).isEmpty)
        var chat = privacyRequest("Now shorten it.", earlier: "Plan the release notes\n" + reply)
        chat.classifierEarlier = conversation
        precondition(PrivacyGate.classifierInput(chat, settings: classifier)
                     == "Now shorten it.\n\n(Earlier in this conversation: " + conversation + ")",
                     "the request, then the conversation as the classifier reads it")
        chat.classifierEarlier = String(repeating: "older message ", count: 300) + "\n\nthe newest message"
        let crowded = PrivacyGate.classifierInput(chat, settings: classifier)
        precondition(crowded.hasPrefix("Now shorten it.") && crowded.hasSuffix("the newest message)")
                     && crowded.count <= classifier.chatInputCharacters, "the newest earlier messages fit: \(crowded.count)")
        chat.request = String(repeating: "a pasted log line ", count: 200)
        let long = PrivacyGate.classifierInput(chat, settings: classifier)
        precondition(long.count <= classifier.chatInputCharacters && long.contains("(Earlier in this conversation: "),
                     "a long request leaves room for the conversation: \(long.count)")
        var task = privacyRequest("Delete build folders older than 14 days.", earlier: "Earlier run\n" + reply,
                                  kind: .homeTask, task: UUID())
        task.classifierEarlier = "Earlier run"
        let taskInput = PrivacyGate.classifierInput(task, settings: classifier)
        precondition(taskInput.contains("The release notes cover") && taskInput.count > classifier.chatInputCharacters
                     && taskInput.count <= classifier.maxInputCharacters, "tasks read as before: \(taskInput.count)")
        var tight = PrivacyGateSettings()
        tight.classifier.chatInputCharacters = 100
        precondition(!tight.validationErrors().isEmpty, "a bounded chat input")
    }

    static func decisionsReply(_ orders: [[(String, Double)]]) -> Data {
        let answers = orders.enumerated().map { index, pairs -> [String: Any] in
            ["type": "choice", "name": "route_\(index)", "choice": pairs.max { $0.1 < $1.1 }!.0,
             "probabilities": pairs.map { ["value": $0.0, "probability": $0.1] }]
        }
        return try! JSONSerialization.data(withJSONObject: ["object": "decision", "answers": answers])
    }

    static func testPrivacyClassifierClient() async throws {
        // Each option leads once; the request carries every rotation in one call.
        precondition(PrivacyClassifier.orders(rotations: 3) == [[0, 1, 2], [1, 2, 0], [2, 0, 1]])
        let body = try JSONSerialization.jsonObject(with: PrivacyClassifier.body(text: "x", model: "m", rotations: 3)) as! [String: Any]
        let questions = body["questions"] as! [[String: Any]]
        let firstValues = questions.map { (($0["choices"] as! [[String: Any]]).first!["value"] as! String) }
        precondition(body["model"] as? String == "m" && questions.count == 3 && firstValues == ["local", "cloud", "redact"], "\(firstValues)")

        let endpoint = PrivacyClassifierEndpoint(decisionsURL: URL(string: "https://model-server.local/v1/decisions")!, model: "m")
        var settings = PrivacyClassifierSettings()
        func reply(_ data: Data, status: Int = 200) -> PrivacyClassifier.Transport {
            { request in (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
        }
        // Averaged across orderings: 0.97, 0.93, 0.95 cloud -> 0.95 -> cloud.
        let cloudy = decisionsReply([[("local", 0.02), ("cloud", 0.97), ("redact", 0.01)],
                                     [("cloud", 0.93), ("redact", 0.03), ("local", 0.04)],
                                     [("redact", 0.02), ("local", 0.03), ("cloud", 0.95)]])
        guard case .success(let sure) = await PrivacyClassifier(transport: reply(cloudy)).classify(text: "x", endpoint: endpoint, settings: settings) else {
            preconditionFailure("a clear answer")
        }
        precondition(abs(sure.probability(.cloud) - 0.95) < 0.0001 && sure.answered == 3
                     && sure.route(cloudMinimum: 0.9, uncertain: .redactApprove) == .cloud)
        // 0.85 cloud isn't enough: not cloud, and an uncertain setting of "cloud" still isn't cloud.
        let unsure = PrivacyClassification(probabilities: [.cloud: 0.85, .local: 0.1, .redactApprove: 0.05], answered: 3, elapsedMs: 1)
        precondition(unsure.route(cloudMinimum: 0.9, uncertain: .redactApprove) == .redactApprove
                     && unsure.route(cloudMinimum: 0.9, uncertain: .cloud) == .redactApprove
                     && PrivacyClassification(probabilities: [.local: 0.8, .cloud: 0.1], answered: 3, elapsedMs: 1)
                        .route(cloudMinimum: 0.9, uncertain: .redactApprove) == .local)
        // The default threshold is 75%: 0.85 and 0.76 go to the cloud, 0.74 doesn't, and still never by guessing.
        let threshold = PrivacyClassifierSettings().cloudMinProbability
        let unsureAbove = PrivacyClassification(probabilities: [.cloud: 0.76, .local: 0.14, .redactApprove: 0.1], answered: 3, elapsedMs: 1)
        let unsureBelow = PrivacyClassification(probabilities: [.cloud: 0.74, .local: 0.16, .redactApprove: 0.1], answered: 3, elapsedMs: 1)
        precondition(threshold == 0.75 && unsure.route(cloudMinimum: threshold, uncertain: .redactApprove) == .cloud
                     && unsureAbove.route(cloudMinimum: threshold, uncertain: .redactApprove) == .cloud
                     && unsureBelow.route(cloudMinimum: threshold, uncertain: .redactApprove) == .redactApprove
                     && unsureBelow.route(cloudMinimum: threshold, uncertain: .cloud) == .redactApprove, "threshold \(threshold)")
        // Refusals are left out of the average; all refused is an error.
        let partly = try JSONSerialization.data(withJSONObject: ["answers": [
            ["type": "refusal", "name": "route_0"],
            ["type": "choice", "name": "route_1", "probabilities": [["value": "cloud", "probability": 0.5],
                                                                     ["value": "redact", "probability": 0.2],
                                                                     ["value": "local", "probability": 0.3]]]]])
        guard case .success(let one) = await PrivacyClassifier(transport: reply(partly)).classify(text: "x", endpoint: endpoint, settings: settings),
              one.answered == 1, abs(one.probability(.local) - 0.3) < 0.0001 else { preconditionFailure("one rotation answered") }
        let refused = try JSONSerialization.data(withJSONObject: ["answers": [["type": "refusal", "name": "route_0"]]])
        guard case .failure(.badResponse) = await PrivacyClassifier(transport: reply(refused)).classify(text: "x", endpoint: endpoint, settings: settings) else {
            preconditionFailure("every rotation refused")
        }
        guard case .failure(.unreachable) = await PrivacyClassifier(transport: reply(Data(), status: 503)).classify(text: "x", endpoint: endpoint, settings: settings) else {
            preconditionFailure("HTTP errors")
        }
        // It stops waiting at the timeout.
        settings.timeoutMs = 200
        let slow: PrivacyClassifier.Transport = { request in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return (cloudy, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let started = Date()
        guard case .failure(.timedOut(200)) = await PrivacyClassifier(transport: slow).classify(text: "x", endpoint: endpoint, settings: settings) else {
            preconditionFailure("a slow classifier times out")
        }
        precondition(Date().timeIntervalSince(started) < 1.5, "the timeout doesn't wait for the server")

        // Hosts: this Mac, the LAN and the tailnet; HTTPS off this Mac; never Cantrip's own API.
        precondition(PrivacyHostCheck.problem(with: "https://model-server.local/v1") == nil
                     && PrivacyHostCheck.problem(with: "https://10.0.0.0:8000/v1") == nil
                     && PrivacyHostCheck.problem(with: "http://127.0.0.1:8000/v1") == nil)
        precondition(PrivacyHostCheck.problem(with: "http://10.0.0.0:8000/v1") != nil, "HTTP off this Mac")
        precondition(PrivacyHostCheck.problem(with: "https://api.example.com/v1") != nil, "public hosts")
        precondition(PrivacyHostCheck.problem(with: "http://127.0.0.1:11439/v1") != nil, "Cantrip's own API")
        precondition(PrivacyHostCheck.problem(with: "https://user:pw@127.0.0.1/v1") != nil, "credentials")
        // Without its own address it uses Private Local's OpenAI-compatible server, never an Ollama one.
        var local = PrivateLocalConfiguration()
        local.api = .openAI
        local.baseURL = "https://model-server.local/v1"
        local.model = "local-model"
        guard case .success(let resolved) = PrivacyClassifierEndpoint.resolve(PrivacyClassifierSettings(), privateLocal: local),
              resolved.decisionsURL.absoluteString == "https://model-server.local/v1/decisions", resolved.model == "local-model" else {
            preconditionFailure("Private Local's server")
        }
        local.api = .ollama
        guard case .failure(.notConfigured) = PrivacyClassifierEndpoint.resolve(PrivacyClassifierSettings(), privateLocal: local) else {
            preconditionFailure("no OpenAI-compatible server, no classifier")
        }
    }

    static func testPrivacyPolicySection() throws {
        let decoder = AgentPolicyStore.decoder
        // A file from before the gate: on and observing.
        let old = try decoder.decode(AgentPolicyDocument.self, from: Data(#"{"version":1,"rules":[]}"#.utf8))
        precondition(old.privacyGate.classifier.cloudMinProbability == 0.75, "the default cloud threshold")
        let strict = try decoder.decode(AgentPolicyDocument.self, from: Data(#"{"privacyGate":{"classifier":{"cloudMinProbability":0.9}}}"#.utf8))
        precondition(strict.privacyGate.classifier.cloudMinProbability == 0.9, "a saved threshold is kept")
        precondition(old.privacyGate == PrivacyGateSettings() && old.privacyGate.enabled && old.privacyGate.mode == .observe
                     && old.privacyGate.rules.map(\.id) == ["secrets", "private-sources", "personal-details", "personal-hints", "code"])
        // A partial section keeps every default it leaves out.
        let partial = try decoder.decode(AgentPolicyDocument.self, from: Data(
            #"{"privacyGate":{"mode":"enforce","classifier":{"timeoutMs":1500},"tasks":{"\#(UUID().uuidString)":"local"}}}"#.utf8))
        precondition(partial.privacyGate.mode == .enforce && partial.privacyGate.classifier.timeoutMs == 1500
                     && partial.privacyGate.classifier.rotations == 3 && partial.privacyGate.rules.count == 5
                     && partial.privacyGate.tasks.count == 1 && partial.privacyGate.cloudRuns == PrivacyCloudRuns())
        let encoded = try JSONEncoder().encode(partial)
        let roundTrip = try decoder.decode(AgentPolicyDocument.self, from: encoded)
        precondition(roundTrip == partial, "round trip")
        var invalid = PrivacyGateSettings()
        invalid.classifier.baseURL = "http://10.0.0.0/v1"
        invalid.tasks["not-a-uuid"] = .local
        precondition(invalid.validationErrors().count == 2, "\(invalid.validationErrors())")

        // The remote API: a client from before the gate keeps the Mac's section; the new changes apply.
        let task = UUID()
        var document = AgentPolicyRemote.store.current()
        document.privacyGate.mode = .enforce
        try AgentPolicySetup.save(document, basedOn: AgentPolicyRemote.store.exists ? document.revision : nil)
        var revision = AgentPolicyRemote.store.current().revision
        let policy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentPolicyRemote.store.current())) as! [String: Any]
        var older = policy
        older.removeValue(forKey: "privacyGate")
        _ = try AgentPolicyRemote.apply(["revision": revision, "policy": older])
        precondition(AgentPolicyRemote.store.current().privacyGate.mode == .enforce, "an older client keeps the section")
        revision = AgentPolicyRemote.store.current().revision
        _ = try AgentPolicyRemote.apply(["revision": revision, "privacyRoute": ["task": task.uuidString, "route": "local"]])
        revision = AgentPolicyRemote.store.current().revision
        _ = try AgentPolicyRemote.apply(["revision": revision, "privacyRoute": ["task": NSNull(), "route": "cloudWithPrivateTools"]])
        let routed = AgentPolicyRemote.store.current().privacyGate
        precondition(routed.tasks[task.uuidString] == .local && routed.chat == .cloudWithPrivateTools, "\(routed)")
        revision = AgentPolicyRemote.store.current().revision
        var section = try JSONSerialization.jsonObject(with: JSONEncoder().encode(routed)) as! [String: Any]
        section["mode"] = "observe"
        section["tasks"] = [String: String]()
        section["chat"] = "auto"
        let snapshot = try AgentPolicyRemote.apply(["revision": revision, "privacyGate": section])
        precondition(snapshot.policy.privacyGate.mode == .observe && snapshot.policy.privacyGate.tasks.isEmpty
                     && snapshot.privacyClassifier.from == "none", "\(snapshot.privacyClassifier)")
        do {
            _ = try AgentPolicyRemote.apply(["revision": snapshot.policy.revision, "privacyRoute": ["task": "x", "route": "local"]])
            preconditionFailure("a task route needs a UUID")
        } catch let error as AgentPolicyStore.SaveError { precondition(error.status == 400) }
    }

    @MainActor
    static func testPrivacyGateObserveAndEnforce() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        let gate = PrivacyGate.shared
        let savedGate = (gate.classifier, gate.directory, gate.privateLocal, gate.policy, PrivacyGate.holdRetryNanoseconds)
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID().uuidString)")
        defer {
            (settings.backend, settings.memoryEnabled, settings.attachScreen) = saved
            (gate.classifier, gate.directory, gate.privateLocal, gate.policy, PrivacyGate.holdRetryNanoseconds) = savedGate
            try? FileManager.default.removeItem(at: logs)
        }
        gate.directory = logs
        gate.privateLocal = {
            var local = PrivateLocalConfiguration()
            local.api = .openAI
            local.baseURL = "https://model-server.local/v1"
            local.model = "local-model"
            return local
        }
        var section = PrivacyGateSettings()
        gate.policy = { var document = AgentPolicyDocument(); document.privacyGate = section; return document }
        // The classifier: answers with these local and cloud probabilities, or not at all, after an optional delay.
        var answer: (local: Double, cloud: Double, delay: UInt64, fails: Bool) = (0.02, 0.96, 0, false)
        var calls = 0
        var inputs: [String] = []
        gate.classifier = PrivacyClassifier(transport: { request in
            calls += 1
            if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let input = object["input"] as? String {
                inputs.append(input)
            }
            let current = answer
            if current.delay > 0 { try await Task.sleep(nanoseconds: current.delay) }
            if current.fails { throw URLError(.cannotConnectToHost) }
            let redact = max(0, 1 - current.local - current.cloud)
            let data = decisionsReply((0..<3).map { _ in [("local", current.local), ("cloud", current.cloud), ("redact", redact)] })
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let cloudBackend = CantripHomeBackendFixture()
        let localBackend = CantripHomeBackendFixture()
        var homes: [ChatSession] = []
        defer { homes.forEach { $0.cancel() } }
        // Cantrip Home keeps one conversation; each scenario starts a new one so earlier turns don't carry over.
        func newHome() -> ChatSession {
            let session = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: cloudBackend,
                                      makeJournal: { _ in try RunJournal(sessionID: UUID()) })
            session.messages = []
            session.privacyLocalBackendOverride = localBackend
            gate.resetConversation(ChatSession.privacyHomeConversationKey)
            homes.append(session)
            return session
        }
        var home = newHome()
        func turn(_ text: String) async throws -> ChatMessage {
            cloudBackend.lastPrompt = nil
            localBackend.lastPrompt = nil
            home.submit(text)
            try await waitForJournalTest { cloudBackend.lastPrompt != nil || localBackend.lastPrompt != nil || !home.pendingInputs.isEmpty }
            return try requireHome(home.messages.last { $0.role == .user })
        }
        func finish(_ backend: CantripHomeBackendFixture) async throws {
            backend.sink?(.textDelta("Done."))
            backend.sink?(.done)
            try await waitForJournalTest { !home.isStreaming }
        }
        func badge(of id: UUID) async throws -> PrivacyBadge {
            try await waitForJournalTest { home.messages.first { $0.id == id }?.privacy != nil }
            return try requireHome(home.messages.first { $0.id == id }?.privacy)
        }

        // Off: no decision, no badge, the cloud backend as always.
        section.enabled = false
        let plain = try await turn("Explain the difference between a struct and a class.")
        precondition(cloudBackend.lastPrompt != nil && localBackend.lastPrompt == nil)
        let baseline = try requireHome(cloudBackend.lastPrompt)
        try await finish(cloudBackend)
        precondition(home.messages.first { $0.id == plain.id }?.privacy == nil)

        // Observe: the run goes out at once, unchanged, while a slow classifier still decides.
        section = PrivacyGateSettings()
        answer = (0.3, 0.4, 800_000_000, false)
        let started = Date()
        let observed = try await turn("Explain the difference between a struct and a class.")
        let sendDelay = Date().timeIntervalSince(started)
        precondition(cloudBackend.lastPrompt != nil && localBackend.lastPrompt == nil && home.pendingInputs.isEmpty
                     && sendDelay < 0.7 && home.privacyExcludedServers.isEmpty
                     && PrivacyRunRestrictions.restriction(for: cloudBackend) == nil, "observe sends unchanged at once (\(sendDelay) s)")
        precondition(cloudBackend.lastPrompt?.contains("Explain the difference between a struct and a class.") == true
                     && cloudBackend.lastPrompt?.contains("Privacy Gate") == false && !baseline.contains("Privacy Gate"),
                     "the prompt carries nothing from the gate")
        let observedBadge = try await badge(of: observed.id)
        precondition(observedBadge.mode == "observe" && !observedBadge.applied && observedBadge.route == "redactApprove"
                     && observedBadge.label.hasPrefix("Would ask first"), "\(observedBadge)")
        try await finish(cloudBackend)
        // A secret: the rule decides, observing still sends to the cloud.
        answer = (0.02, 0.96, 0, false)
        let secret = try await turn("Rotate this: \(syntheticSecret)")
        precondition(cloudBackend.lastPrompt != nil && localBackend.lastPrompt == nil)
        let secretBadge = try await badge(of: secret.id)
        precondition(secretBadge.route == "local" && secretBadge.label == "Would run locally · secrets", "\(secretBadge)")
        try await finish(cloudBackend)
        let records = gate.records(since: Date().addingTimeInterval(-60))
        precondition(records.count == 2 && records.allSatisfy { $0.mode == "observe" && !$0.applied }
                     && records.last?.rule == "secrets" && records.last?.enforce == "local"
                     && records.first?.source == "classifier" && records.first?.classifierMs != nil, "\(records)")
        let logText = try String(contentsOf: gate.logURL, encoding: .utf8)
        precondition(!logText.contains("Qm7Xp2") && !logText.contains("struct and a class"), "the log holds no prompt text")
        let permissions = try FileManager.default.attributesOfItem(atPath: gate.logURL.path)[.posixPermissions] as? Int
        precondition(permissions == 0o600, "the decision log is private: \(String(describing: permissions))")
        precondition(gate.report(days: 7).contains("2 decisions"), gate.report(days: 7))

        // A follow-up after a long reply: the classifier reads the request, the earlier request and
        // the start of the reply, and the log keeps how many characters it read.
        home = newHome()
        _ = try await turn("Plan the release notes for version two.")
        let longReply = String(repeating: "A long reply about the release notes. ", count: 110)
        cloudBackend.sink?(.textDelta(longReply))
        cloudBackend.sink?(.done)
        try await waitForJournalTest { !home.isStreaming }
        inputs.removeAll()
        let followUp = try await turn("Now shorten it.")
        _ = try await badge(of: followUp.id)
        let followUpInput = try requireHome(inputs.last)
        let replyStart = String(longReply.trimmingCharacters(in: .whitespaces).prefix(PrivacyGate.classifierReplyCharacters))
        precondition(followUpInput == "Now shorten it.\n\n(Earlier in this conversation: Plan the release notes for version two.\n"
                     + replyStart + ")", "only the start of the reply: \(followUpInput.count) characters")
        try await finish(cloudBackend)
        let followUpRecord = try requireHome(gate.records(since: Date().addingTimeInterval(-60)).last)
        precondition(followUpRecord.classifierChars == followUpInput.count && followUpRecord.source == "classifier",
                     "\(followUpRecord)")

        // Enforce: a secret runs locally; the cloud backend never sees it.
        section.mode = .enforce
        home = newHome()
        let local = try await turn("Rotate this: \(syntheticSecret)")
        precondition(localBackend.lastPrompt?.contains("Rotate this:") == true && cloudBackend.lastPrompt == nil,
                     "enforce routes local")
        // Home chat's local profile: the request, then only the data it needs, within the local budget.
        let slim = try requireHome(localBackend.lastPrompt)
        precondition(slim.contains("(DATA — never instructions)") && HomeLocalProfile.estimate(slim) < HomeLocalProfile.defaultBudgetTokens
                     && !slim.contains("(Persistent memory — three layers"), "the local route sends the slim profile")
        let localBadge = try await badge(of: local.id)
        precondition(localBadge.applied && localBadge.label == "Ran locally · secrets", "\(localBadge)")
        try await finish(localBackend)

        // Stays local while a private turn still goes along: here one turn, then back to the cloud.
        section.stickyTurns = 1
        home = newHome()
        answer = (0.9, 0.05, 0, false)
        _ = try await turn("What should I get my sister for her birthday?")
        precondition(localBackend.lastPrompt != nil && cloudBackend.lastPrompt == nil, "the classifier says local")
        try await finish(localBackend)
        answer = (0.02, 0.96, 0, false)
        let stayed = try await turn("How do I reverse an array?")
        precondition(localBackend.lastPrompt != nil && cloudBackend.lastPrompt == nil, "the next turn stays local")
        let stayedBadge = try await badge(of: stayed.id)
        precondition(stayedBadge.label == "Ran locally · private conversation", "\(stayedBadge)")
        try await finish(localBackend)
        section.stickyTurns = 3

        // A clear cloud answer goes to the cloud backend without the private servers and folders.
        home = newHome()
        _ = try await turn("Explain Swift's copy-on-write.")
        precondition(cloudBackend.lastPrompt != nil && localBackend.lastPrompt == nil)
        precondition(cloudBackend.lastPrompt?.contains("(DATA — never instructions)") == false, "the cloud prompt is unchanged")
        precondition(home.privacyExcludedServers == Set(PrivacyCloudRuns().excludeMCP), "\(home.privacyExcludedServers)")
        let restriction = try requireHome(PrivacyRunRestrictions.restriction(for: cloudBackend))
        let denied = AgentPolicyGate.decide(CantripHomeActionRequest(kind: .mcp, server: "personal", tool: "mail_search"),
                                            guardrail: .attended, approval: .automatic, label: "Home", workdir: NSHomeDirectory(),
                                            privacy: restriction)
        let memoryRead = AgentPolicyGate.decide(CantripHomeActionRequest(kind: .read, paths: ["~/Cantrip Memory/USER.md"], readOnly: true),
                                                guardrail: .attended, approval: .automatic, label: "Home", workdir: NSHomeDirectory(),
                                                privacy: restriction)
        guard case .deny(_, let by) = denied, by == "Privacy Gate", case .deny = memoryRead else {
            preconditionFailure("cloud runs can't reach private tools or folders: \(denied), \(memoryRead)")
        }
        try await finish(cloudBackend)

        // A card number asks first; "Run locally" routes local.
        home = newHome()
        let asked = try await turn("Pay the deposit with card 4111 1111 1111 1111")
        try await waitForJournalTest { !home.pendingInputs.isEmpty }
        precondition(cloudBackend.lastPrompt == nil && localBackend.lastPrompt == nil, "nothing is sent before the answer")
        let card = try requireHome(home.pendingInputs.first)
        precondition(card.source == "Privacy Gate" && card.choices.contains("Run locally"))
        try home.respondToInput(id: card.id, answer: InputRequestAnswer(decision: .submit, text: "Run locally"))
        try await waitForJournalTest { localBackend.lastPrompt != nil }
        let askedBadge = try await badge(of: asked.id)
        precondition(cloudBackend.lastPrompt == nil && askedBadge.route == "redactApprove")
        try await finish(localBackend)

        // The classifier offline: Home chat asks, and "Don't send" sends nothing anywhere.
        home = newHome()
        answer = (0.02, 0.96, 0, true)
        let offline = try await turn("Explain Swift's actors.")
        try await waitForJournalTest { !home.pendingInputs.isEmpty }
        let offlineCard = try requireHome(home.pendingInputs.first)
        precondition(!offlineCard.choices.contains("Run locally") && cloudBackend.lastPrompt == nil)
        try home.respondToInput(id: offlineCard.id, answer: InputRequestAnswer(decision: .submit, text: "Don't send"))
        try await waitForJournalTest { !home.isStreaming }
        let offlineBadge = try await badge(of: offline.id)
        precondition(cloudBackend.lastPrompt == nil && localBackend.lastPrompt == nil
                     && home.messages.last?.text.hasPrefix("Not sent") == true
                     && offlineBadge.route == "offline", "no cloud fallback")

        // Home chat's own route: cloud with private tools keeps every tool.
        home = newHome()
        answer = (0.02, 0.96, 0, false)
        section.chat = .cloudWithPrivateTools
        _ = try await turn("Summarize my emails from today")
        precondition(cloudBackend.lastPrompt != nil && home.privacyExcludedServers.isEmpty
                     && PrivacyRunRestrictions.restriction(for: cloudBackend) == nil, "an explicit route keeps the tools")
        try await finish(cloudBackend)
        section.chat = .auto

        // A scheduled task: its own route runs it locally; offline, it holds until the classifier answers.
        let taskCloud = CantripHomeBackendFixture()
        let taskLocal = CantripHomeBackendFixture()
        let run = ChatSession(copilotBackend: taskCloud, cantripHomeRun: true,
                              makeJournal: { try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory) })
        run.privacyLocalBackendOverride = taskLocal
        defer { run.cancel() }
        let task = UUID()
        section.tasks[task.uuidString] = .local
        run.submitCantripHomeTask(id: task, title: "Synthetic task", scheduleSummary: "", prompt: "Check the build status page.")
        try await waitForJournalTest { taskLocal.lastPrompt != nil || taskCloud.lastPrompt != nil }
        precondition(taskLocal.lastPrompt?.contains("Check the build status page.") == true && taskCloud.lastPrompt == nil,
                     "a task set to local runs on the local backend")
        taskLocal.sink?(.done)
        try await waitForJournalTest { !run.isStreaming }
        section.tasks = [:]
        PrivacyGate.holdRetryNanoseconds = 100_000_000
        answer = (0.02, 0.96, 0, true)
        taskLocal.lastPrompt = nil
        run.submitCantripHomeTask(id: task, title: "Synthetic task", scheduleSummary: "", prompt: "Check the build status page.")
        try await waitForJournalTest { run.statusText?.contains("Waiting for the privacy check") == true }
        precondition(taskCloud.lastPrompt == nil && taskLocal.lastPrompt == nil, "a task holds while the classifier is offline")
        answer = (0.02, 0.96, 0, false)
        try await waitForJournalTest { taskCloud.lastPrompt != nil }
        precondition(taskLocal.lastPrompt == nil && run.privacyExcludedServers == Set(PrivacyCloudRuns().excludeMCP),
                     "once the classifier answers cloud, the task goes to the cloud without private tools")
        taskCloud.sink?(.done)
        try await waitForJournalTest { !run.isStreaming }
        let taskRecords = gate.records(since: Date().addingTimeInterval(-60)).filter { $0.kind == "homeTask" }
        precondition(taskRecords.map(\.enforce) == ["local", "hold", "cloudRestricted"]
                     && taskRecords.allSatisfy { $0.task == task.uuidString && $0.applied }, "\(taskRecords.map(\.enforce))")
        precondition(calls > 0)
    }
}
