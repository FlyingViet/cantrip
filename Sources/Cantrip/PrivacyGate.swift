import Foundation
import NaturalLanguage

// MARK: - Request

/// One Home request as the gate sees it.
struct PrivacyGateRequest {
    enum Kind: String, Codable { case homeChat, homeTask }
    var kind: Kind
    var taskID: UUID?
    var taskTitle: String?
    /// Identifies the Home conversation (for staying local) or the task (for the cache).
    var conversationKey: String
    var request: String
    var earlier: String
    /// The whole message about to be sent.
    var message: String
    var workdir: String
    var backend: String
    /// MCP servers the run can use.
    var mcpServers: [String] = []
}

// MARK: - Rules

/// A rule's decision with what it saw. Values are never kept: only kinds and counts.
struct PrivacyRuleOutcome: Equatable {
    var rule: PrivacyGateRule?
    var reason: String
    /// "phone@request": 1. Every detector's hits in every segment, matched or not.
    var hits: [String: Int]
    var elapsedMs: Int
}

enum PrivacyRules {
    /// The message without the always-loaded memory (core files, the notes list and the protocol),
    /// and the retrieved snippets on their own.
    static func split(message: String) -> (withoutMemory: String, retrieved: String) {
        let ends = ["Don't mention the vault unless asked.)", "about this conversation anywhere.)"]
        guard let start = message.range(of: "(Persistent memory — three layers")
                ?? message.range(of: "(Memory from previous sessions:\n") else { return (message, "") }
        let end = ends.compactMap { message.range(of: $0, range: start.upperBound..<message.endIndex)?.upperBound }
            .min() ?? message.endIndex
        let block = message[start.lowerBound..<end]
        var rest = String(message[..<start.lowerBound]) + message[end...]
        var retrieved = ""
        // Attended memory carries its snippets inside the block, before the closing instruction.
        if let snippets = block.range(of: "RETRIEVED — ") {
            let tail = block[snippets.lowerBound...]
            let stop = ["\n\nMaintain memory silently", "\n\nPRIVATE MODE"]
                .compactMap { tail.range(of: $0)?.lowerBound }.min() ?? tail.endIndex
            retrieved = String(tail[..<stop])
        }
        // A scheduled task's snippets come after its prompt in their own parentheses.
        if let task = rest.range(of: "(RETRIEVED — memory snippets auto-matched to this task") {
            retrieved += (retrieved.isEmpty ? "" : "\n") + rest[task.lowerBound...]
            rest = String(rest[..<task.lowerBound])
        }
        return (rest, retrieved)
    }

    static func segments(_ request: PrivacyGateRequest) -> [PrivacySegment: String] {
        let (withoutMemory, retrieved) = split(message: request.message)
        var context = withoutMemory
        for known in [request.request, request.earlier] where !known.isEmpty {
            context = context.replacingOccurrences(of: known, with: "")
        }
        return [.request: request.request, .earlier: request.earlier, .memory: retrieved, .context: context]
    }

    /// First match wins: the run's own route, then each enabled rule in order.
    static func evaluate(_ request: PrivacyGateRequest, settings: PrivacyGateSettings, privateTerms: [String],
                         isRepository: (String) -> Bool = PrivacyRules.isRepository) -> PrivacyRuleOutcome {
        let started = Date()
        let segments = segments(request)
        var hits: [String: Int] = [:]
        var found: [PrivacySegment: Set<PrivacyDetector>] = [:]
        for (segment, text) in segments where !text.isEmpty {
            for (detector, count) in PrivacyDetectors.scan(text) where count > 0 {
                hits["\(detector.rawValue)@\(segment.rawValue)", default: 0] += count
                found[segment, default: []].insert(detector)
            }
        }
        var sources: [PrivacySegment: Set<String>] = [:]
        for (segment, text) in segments where !text.isEmpty {
            let named = PrivacyDetectors.sources(in: text, segment: segment)
            for source in named { hits["source.\(source)@\(segment.rawValue)", default: 0] += 1 }
            if !named.isEmpty { sources[segment] = named }
        }
        var terms: [PrivacySegment: Int] = [:]
        for (segment, text) in segments where !text.isEmpty {
            let count = PrivacyDetectors.privateTermCount(privateTerms, in: text)
            if count > 0 { terms[segment] = count; hits["privateTerm@\(segment.rawValue)"] = count }
        }
        let repository = !request.workdir.isEmpty && isRepository(request.workdir)
        let elapsed = { Int(Date().timeIntervalSince(started) * 1000) }

        for rule in settings.rules where rule.enabled {
            let scope = rule.segments
            var matched: [String] = []
            for detector in rule.detectors ?? [] {
                let places = scope.filter { found[$0]?.contains(detector) == true }
                if !places.isEmpty { matched.append("\(detector.label) in \(describe(places))") }
            }
            for source in rule.sources ?? [] {
                let places = scope.filter { sources[$0]?.contains(source) == true }
                if !places.isEmpty { matched.append("\(source) in \(describe(places))") }
            }
            if rule.privateTerms == true {
                let places = scope.filter { (terms[$0] ?? 0) > 0 }
                if !places.isEmpty { matched.append("a private term in \(describe(places))") }
            }
            if rule.repoWorkdir == true, repository { matched.append("work in a repository folder") }
            if !matched.isEmpty {
                return PrivacyRuleOutcome(rule: rule, reason: matched.joined(separator: "; "), hits: hits, elapsedMs: elapsed())
            }
        }
        return PrivacyRuleOutcome(rule: nil, reason: "no rule matched", hits: hits, elapsedMs: elapsed())
    }

    private static func describe(_ segments: Set<PrivacySegment>) -> String {
        let names: [PrivacySegment: String] = [.request: "the request", .earlier: "earlier turns",
                                               .memory: "memory snippets", .context: "added context"]
        return PrivacySegment.allCases.filter(segments.contains).compactMap { names[$0] }.joined(separator: ", ")
    }

    static func isRepository(_ folder: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        while url.path != "/" && url.path != home {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }
}

// MARK: - Detectors

/// Finds kinds of private detail. Results are counts; matched text never leaves this type.
enum PrivacyDetectors {
    /// Characters each detector reads at most per segment (long Home data stays fast).
    static let scanLimit = 60_000

    static func scan(_ text: String) -> [PrivacyDetector: Int] {
        let text = String(text.prefix(scanLimit))
        var result: [PrivacyDetector: Int] = [:]
        result[.secret] = SecretScan.scan(text: text, file: "").count
        result[.ssn] = matches(ssn, in: text)
        result[.card] = cardNumbers(in: text)
        result[.account] = matches(account, in: text) + matches(iban, in: text)
        result[.email] = emails(in: text)
        let detected = dataDetector(text)
        result[.phone] = detected.phones
        result[.address] = detected.addresses
        result[.name] = personalNames(in: text)
        return result
    }

    private static let ssn = try! NSRegularExpression(pattern: #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#)
    private static let cardCandidate = try! NSRegularExpression(pattern: #"\b\d(?:[ -]?\d){12,18}\b"#)
    private static let account = try! NSRegularExpression(
        pattern: #"(?i)\b(?:account|acct|routing)(?:\s+(?:no|number|#))?\b[^\n\d]{0,16}\d[\d -]{4,20}\d"#)
    private static let iban = try! NSRegularExpression(pattern: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#)
    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func cardNumbers(in text: String) -> Int {
        cardCandidate.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            let digits = text[range].compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && luhn(digits)
        }.count
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 { let doubled = digit * 2; sum += doubled > 9 ? doubled - 9 : doubled } else { sum += digit }
        }
        return sum % 10 == 0 && Set(digits).count > 1
    }

    static func emails(in text: String) -> Int {
        email.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            let address = text[range].lowercased()
            return !address.contains("noreply") && !address.hasSuffix(".invalid") && !address.hasSuffix(".test")
        }.count
    }

    private static func dataDetector(_ text: String) -> (phones: Int, addresses: Int) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue) else { return (0, 0) }
        var phones = 0, addresses = 0
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            if match.resultType == .phoneNumber, let number = match.phoneNumber,
               number.filter(\.isNumber).count >= 10 {
                phones += 1
            } else if match.resultType == .address,
                      match.addressComponents?[.street] != nil {
                addresses += 1
            }
        }
        return (phones, addresses)
    }

    /// Assistant, product and model names that NLTagger reads as people.
    static let notPeople: Set<String> = ["cantrip", "pip", "claude", "copilot", "codex", "gemini", "siri", "alexa",
                                          "qwen", "gemma", "llama", "mistral", "sonnet", "opus", "haiku", "grok",
                                          "antigravity", "xcode", "swift", "home"]

    static func personalNames(in text: String) -> Int {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: Set<String> = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName {
                let name = text[range].trimmingCharacters(in: .whitespaces)
                if name.count > 1, !notPeople.contains(name.lowercased()) { names.insert(name.lowercased()) }
            }
            return true
        }
        return names.count
    }

    static func privateTermCount(_ terms: [String], in text: String) -> Int {
        let lowered = text.lowercased()
        return terms.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
            .filter { term in
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
                return lowered.range(of: pattern, options: .regularExpression) != nil
            }.count
    }

    /// Private data sources a text asks about or carries. The request is read for intent; any
    /// segment can carry Mail or Messages attachments.
    static func sources(in text: String, segment: PrivacySegment) -> Set<String> {
        var found: Set<String> = []
        if text.contains("/Library/Mail/") { found.insert("mail") }
        if text.contains("/Library/Messages/") { found.insert("messages") }
        guard segment == .request else { return found }
        let lowered = text.lowercased()
        for (source, pattern) in sourcePatterns where lowered.range(of: pattern, options: .regularExpression) != nil {
            found.insert(source)
        }
        return found
    }

    static let sourcePatterns: [(String, String)] = [
        ("personal", #"\b(e-?mails?|inbox|gmail|imessages?|text messages?|my (messages|texts|calendar|contacts)|calendar events?|contacts? (list|card)|mail_(search|read)|messages_(read|chats)|calendar_events|contacts_lookup)\b"#),
        ("homelab", #"\b(firefly|paperless|home assistant|net worth|bank (accounts?|statements?|balances?)|my (bank|accounts?|balances?|spending|finances|transactions|budget)|spending (by|this|last)|transactions|scanned (documents?|receipts?)|homelab)\b"#),
        ("bitwarden", #"\b(bitwarden|passwords?|my vault|credentials?|2fa|one-time codes?|login (details|info))\b"#),
        ("forms", #"\b(fill (out|in) (the|this|a|my) (pdf|form)|pdf forms?|tax forms?)\b"#),
    ]
}
