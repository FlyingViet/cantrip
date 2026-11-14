import Foundation

/// `@muse …` at the start of a message, in Cantrip Home or any tab: Cantrip sends the rest to the
/// user's Muse and shows Muse's reply in that chat. The tab's own model sees neither. Nothing else
/// a user, tab or model writes is ever sent to Muse.
enum MuseMention {
    struct Parsed: Equatable {
        /// What to send, without the mention.
        var text: String
        /// `@muse #feed-id …`: that feed's Muse chat instead of Muse's main chat.
        var feedID: String?
    }

    /// `set up apartments`, `setup apartments`, `approve apartments` → "apartments".
    static func setupCommand(_ command: String) -> String? {
        for prefix in ["set up ", "setup ", "approve "] where command.hasPrefix(prefix) {
            let id = command.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if id.range(of: #"^[a-z0-9][a-z0-9-]{1,39}$"#, options: .regularExpression) != nil { return id }
        }
        return nil
    }

    static func parse(_ message: String) -> Parsed? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.prefix(5).lowercased() == "@muse" else { return nil }
        var rest = trimmed.dropFirst(5)
        // @museum, @muse-cli, @muse's… aren't mentions.
        if let next = rest.first, !(next.isWhitespace || next == ":" || next == ",") { return nil }
        rest = rest.drop { $0.isWhitespace || $0 == ":" || $0 == "," }
        var feedID: String?
        if rest.first == "#" {
            let token = rest.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !token.isEmpty {
                feedID = token.lowercased()
                rest = rest.dropFirst(token.count + 1).drop { $0.isWhitespace || $0 == ":" || $0 == "," }
            }
        }
        return Parsed(text: String(rest).trimmingCharacters(in: .whitespacesAndNewlines), feedID: feedID)
    }
}

/// The Privacy Gate's detectors on an `@muse` message before anything leaves the Mac. Muse runs on
/// Meta's servers, so mail, texts, financial details, contacts, location, secrets and the user's
/// private terms wait for an explicit OK, whatever the gate's own mode for Home is.
enum MuseSendCheck {
    enum Category: String, Codable, CaseIterable {
        case mail, texts, finance, contacts, location, secrets, privateTerms
    }

    struct Finding: Equatable {
        let category: Category
        let reason: String
    }

    static func findings(in text: String, ownerNames: [String] = [], privateTerms: [String] = []) -> [Finding] {
        var found: [Finding] = []
        func add(_ category: Category, _ reason: String) {
            if !found.contains(Finding(category: category, reason: reason)) { found.append(.init(category: category, reason: reason)) }
        }
        let hits = PrivacyDetectors.scan(text, ownerNames: ownerNames)
        func any(_ detector: PrivacyDetector) -> Bool { (hits[detector] ?? 0) > 0 }
        if any(.secret) { add(.secrets, "a secret or key") }
        for detector in [PrivacyDetector.ssn, .card, .account] where any(detector) { add(.finance, detector.label) }
        for detector in [PrivacyDetector.email, .phone] where any(detector) { add(.contacts, detector.label) }
        if any(.address) { add(.location, PrivacyDetector.address.label) }
        let lowered = text.lowercased()
        for (category, reason, pattern) in patterns
        where lowered.range(of: pattern, options: .regularExpression) != nil {
            add(category, reason)
        }
        if text.contains("/Library/Mail/") { add(.mail, "a Mail file") }
        if text.contains("/Library/Messages/") { add(.texts, "a Messages file") }
        if count(mailHeader, in: text) >= 2 { add(.mail, "email headers") }
        if count(chatLine, in: text) >= 2 { add(.texts, "a text conversation") }
        if text.range(of: #"-?\d{1,2}\.\d{4,},\s*-?\d{1,3}\.\d{4,}"#, options: .regularExpression) != nil {
            add(.location, "coordinates")
        }
        if PrivacyDetectors.privateTermCount(privateTerms, in: text) > 0 { add(.privateTerms, "one of your private terms") }
        return found
    }

    static let patterns: [(Category, String, String)] = [
        (.mail, "mail content", #"\b(this|that|the|an|my|your) (e-?mail|inbox)\b|\bgmail\b|\bforwarded message\b|\bmail_(search|read)\b"#),
        (.texts, "text messages", #"\b(i?messages?|text messages?|texts? from|my texts|this text|sms|whatsapp|group chat)\b"#),
        (.finance, "financial details", #"\b(my|our) (bank|bank accounts?|accounts? balances?|balances?|finances|transactions|budget|spending|salary|paychecks?|paystubs?|net worth|statements?|taxes|credit (score|cards?)|investments?|401k|brokerage)\b|\b(bank statement|routing number|net worth|tax return|firefly)\b"#),
        (.contacts, "contacts", #"\b(my contacts|contact (card|list)|address book|phone numbers? (of|for))\b"#),
        (.location, "your location", #"\b(my (current )?location|where i am( now)?|i'?m (at|near) (home|my)|my (home |current )?address|home address|gps)\b"#),
    ]

    private static let mailHeader = try! NSRegularExpression(pattern: #"(?im)^(from|to|cc|subject|date|reply-to):\s+\S"#)
    private static let chatLine = try! NSRegularExpression(pattern: #"(?m)^\[?\d{1,2}[:.]\d{2}(\s?[ap]\.?m\.?)?\]?\s*[^:\n]{1,40}:\s+\S"#)

    private static func count(_ regex: NSRegularExpression, in text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// "mail content and an email address".
    static func describe(_ findings: [Finding]) -> String { describe(reasons: findings.map(\.reason)) }

    static func describe(reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "nothing"
        case 1: return reasons[0]
        default: return reasons.dropLast().joined(separator: ", ") + " and " + reasons.last!
        }
    }
}

/// One `@muse` exchange in a chat: saved on its message (role `handoff`, author "Muse").
struct MuseExchange: Codable, Equatable {
    enum State: String, Codable {
        case checking, needsApproval, sending, replied, noReply, notSent, failed
        /// A feed's setup message, waiting for the user's `@muse set up <feed>`.
        case setupPending
    }

    /// How long a held message can still be sent with `@muse send`.
    static let holdLifetime: TimeInterval = 15 * 60

    var state: State
    var request: String
    /// "main chat" or the feed's title.
    var chat: String
    var sessionID: String?
    /// What the Privacy Gate found, when it asked first.
    var findings: [String]?
    /// Choices Muse asked the user to make (a purchase, an email to send). Never answered by Cantrip.
    var choices: [[String]]?
    var savedFiles: [String]?
    var detail: String?
    var updatedAt = Date()

    static let author = "Muse"

    /// The message text clients show: the request, then Muse's reply or where things stand.
    func text(reply: String = "") -> String {
        let quoted = request.prefix(600).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        let head = "> **@muse**\(chat == "main chat" ? "" : " · \(chat)")\n" + quoted
        let body: String
        switch state {
        case .checking: body = "Checking it with the Privacy Gate…"
        case .needsApproval:
            body = "**Waiting for your OK.** The Privacy Gate found \(MuseSendCheck.describe(reasons: findings ?? [])). "
                + "Muse runs on Meta's servers, and nothing has been sent to it. To send this as written, reply "
                + "`@muse send` within 15 minutes; `@muse cancel` drops it."
        case .setupPending: return detail ?? ""
        case .sending: body = detail ?? "Sent to Muse. Waiting for its reply…"
        case .replied:
            var parts = [reply.isEmpty ? "_Muse replied without text._" : reply]
            if let files = savedFiles, !files.isEmpty { parts.append("Saved to Artifacts: " + files.joined(separator: ", ") + ".") }
            body = parts.joined(separator: "\n\n")
        case .noReply: body = detail ?? "Muse hasn't replied after 5 minutes. Its answer will be in the Muse app."
        case .notSent: body = detail ?? "Not sent to Muse."
        case .failed: body = "Muse couldn't be reached: " + (detail ?? "unknown error") + "."
        }
        return head + "\n\n" + body
    }

    /// Muse's text, made safe to show as Markdown: no images that load from the web, no fenced
    /// blocks Cantrip would read as its own protocol, no control characters, at most 20,000 characters.
    static func sanitized(_ text: String) -> String {
        var text = String(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\("#, with: "[$1](", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^(\s*)(```|~~~)\s*cantrip"#, with: "$1$2text cantrip", options: .regularExpression)
        return text.count > 20_000 ? String(text.prefix(20_000)) + "…" : text
    }

    /// A card for Muse's links and tasks it showed, and for a choice it wants the user to make.
    static func cards(for reply: MuseReply) -> [CardDocument] {
        var cards: [CardDocument] = []
        if !reply.choices.isEmpty {
            var header = CardDocument.Block(type: "header")
            header.title = "Muse is asking you"
            header.symbol = "hand.raised"
            var notice = CardDocument.Block(type: "notice")
            notice.title = reply.choices.map { $0.joined(separator: " · ") }.joined(separator: "  |  ")
            notice.text = "Cantrip never answers for you. Reply with @muse and your answer, or answer in the Muse app."
            notice.tone = "warning"
            cards.append(CardDocument(id: "muse-choice-\(reply.lastSeq)", type: "muse", blocks: [header, notice]))
        }
        if !reply.cards.isEmpty {
            var list = CardDocument.Block(type: "list")
            list.title = "From Muse"
            list.items = reply.cards.prefix(8).map { card in
                var item = CardDocument.Item(title: card.title)
                item.subtitle = [card.subtitle, card.url, card.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return item
            }
            cards.append(CardDocument(id: "muse-shown-\(reply.lastSeq)", type: "muse", blocks: [list]))
        }
        return cards
    }
}

extension ChatSession {
    /// Handles an `@muse` message: true when it was one (sent, held for approval, or refused).
    /// Runs before the tab's own delivery, so it never queues behind or interrupts the tab's work.
    @discardableResult
    func receiveMuseMention(_ prompt: String) -> Bool {
        guard let mention = MuseMention.parse(prompt) else { return false }
        let connector = MuseConnector.shared
        var exchange = MuseExchange(state: .checking, request: mention.text, chat: "main chat")
        let source = isCantripHome ? "Cantrip Home" : "tab “\(title)”"
        func finish(_ state: MuseExchange.State, _ detail: String) -> Bool {
            exchange.state = state
            exchange.detail = detail
            appendMuse(exchange)
            MuseLog.write("@muse from \(source) not sent: \(detail.prefix(120))")
            return true
        }
        if mention.text.isEmpty { return finish(.notSent, "Write what to send after @muse. Nothing was sent.") }
        let command = mention.text.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if mention.feedID == nil, command == "send" || command == "cancel" {
            answerHeldMuse(send: command == "send", source: source)
            return true
        }
        if mention.feedID == nil, let feedID = MuseMention.setupCommand(command) {
            approveMuseFeed(feedID, source: source)
            return true
        }
        if isLocalPrivate || isPrivate { return finish(.notSent, "Private tabs never send to Muse. Nothing was sent.") }
        guard connector.isEnabled else {
            return finish(.notSent, "Muse is off. Turn it on in Settings › Tools & sign-ins › Muse. Nothing was sent.")
        }
        if let feedID = mention.feedID {
            guard let feed = MuseFeeds.shared.feed(feedID), let session = feed.sessionID, feed.state != .pendingApproval else {
                return finish(.notSent, "There's no active Muse feed “\(feedID)”. Nothing was sent.")
            }
            exchange.chat = feed.title
            exchange.sessionID = session
        }
        let gate = PrivacyGate.shared
        let findings = MuseSendCheck.findings(in: mention.text, ownerNames: gate.settings.ownerNames,
                                              privateTerms: gate.policy().privateTerms)
        guard findings.isEmpty else {
            exchange.state = .needsApproval
            exchange.findings = findings.map(\.reason)
            appendMuse(exchange)
            let categories = Set(findings.map(\.category))
            MuseLog.write("@muse from \(source) held: Privacy Gate found "
                          + MuseSendCheck.Category.allCases.filter(categories.contains).map(\.rawValue).joined(separator: ", "))
            return true
        }
        let messageID = appendMuse(exchange)
        sendToMuse(exchange, messageID: messageID, source: source)
        return true
    }

    /// `@muse send` / `@muse cancel`: the user's answer to the latest held message in this chat.
    private func answerHeldMuse(send: Bool, source: String) {
        guard let index = messages.lastIndex(where: { $0.muse?.state == .needsApproval }),
              var held = messages[index].muse else {
            var note = MuseExchange(state: .notSent, request: send ? "send" : "cancel", chat: "main chat")
            note.detail = "Nothing is waiting to be sent to Muse."
            appendMuse(note)
            return
        }
        let id = messages[index].id
        if Date().timeIntervalSince(held.updatedAt) > MuseExchange.holdLifetime {
            held.state = .notSent
            held.detail = "Not sent: it waited more than 15 minutes. Send it again with @muse if you still want to."
            updateMuse(id, held)
            return
        }
        guard send else {
            held.state = .notSent
            held.detail = "Not sent: you cancelled it."
            updateMuse(id, held)
            MuseLog.write("@muse from \(source): held message cancelled")
            return
        }
        MuseLog.write("@muse from \(source): the user approved the held message")
        sendToMuse(held, messageID: id, source: source)
    }

    /// `@muse set up <feed>`: the user approves a feed's setup message.
    private func approveMuseFeed(_ feedID: String, source: String) {
        var note = MuseExchange(state: .sending, request: "set up \(feedID)", chat: "main chat")
        guard let feed = MuseFeeds.shared.feed(feedID), feed.state == .pendingApproval || feed.state == .failed else {
            note.state = .notSent
            note.detail = "There's no Muse feed “\(feedID)” waiting to be set up."
            appendMuse(note)
            return
        }
        note.chat = feed.title
        note.detail = "Setting up “\(feed.title)” in Muse…"
        let id = appendMuse(note)
        Task { @MainActor [weak self] in
            do {
                try await MuseFeeds.shared.approve(feedID)
                note.state = .notSent
                note.detail = "Set up in Muse. Its results will arrive as “\(feed.title)” records, checked by Cantrip; you'll get a notification."
            } catch {
                note.state = .failed
                note.detail = error.localizedDescription
            }
            self?.updateMuse(id, note)
        }
    }

    /// A feed waiting for the user's approval, shown in the chat that asked for it.
    func postMuseFeedSetup(_ feed: MuseFeed) {
        var note = MuseExchange(state: .setupPending, request: "set up \(feed.id)", chat: feed.title)
        note.detail = "**The “\(feed.title)” feed is ready to set up.** Cantrip will start a Muse chat for it and send "
            + "this once:\n\n" + feed.setupMessage.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
            + "\n\nTo send it, reply `@muse set up \(feed.id)`, or approve it in Settings › Tools & sign-ins › Muse. "
            + "Nothing has been sent to Muse yet."
        appendMuse(note)
    }

    private func sendToMuse(_ exchange: MuseExchange, messageID: UUID, source: String) {
        var exchange = exchange
        exchange.state = .sending
        updateMuse(messageID, exchange)
        Task { @MainActor [weak self] in
            do {
                let reply = try await MuseConnector.shared.ask(exchange.request, chat: exchange.sessionID,
                                                                chatTitle: exchange.chat, source: source)
                exchange.state = reply.replied ? .replied : .noReply
                exchange.choices = reply.choices.isEmpty ? nil : reply.choices
                exchange.savedFiles = reply.savedFiles.isEmpty ? nil : reply.savedFiles
                self?.updateMuse(messageID, exchange, reply: MuseExchange.sanitized(reply.text),
                                 cards: MuseExchange.cards(for: reply))
            } catch let failure as MuseBridgeProcess.Failure {
                switch failure.kind {
                case "auth":
                    exchange.state = .notSent
                    exchange.detail = "Not sent: Muse's login is missing or expired. " + MuseStatus.loginSteps
                case "notInstalled":
                    exchange.state = .notSent
                    exchange.detail = "Not sent: " + MuseStatus.installSteps
                case "off":
                    exchange.state = .notSent
                    exchange.detail = "Not sent: Muse is off in Settings."
                default:
                    exchange.state = .failed
                    exchange.detail = String(failure.message.prefix(300))
                }
                self?.updateMuse(messageID, exchange)
            } catch {
                exchange.state = .failed
                exchange.detail = error.localizedDescription
                self?.updateMuse(messageID, exchange)
            }
        }
    }

    @discardableResult
    private func appendMuse(_ exchange: MuseExchange) -> UUID {
        var message = ChatMessage(role: .handoff, text: exchange.text(), author: MuseExchange.author)
        message.muse = exchange
        messages.append(message)
        persistTranscript()
        return message.id
    }

    private func updateMuse(_ id: UUID, _ exchange: MuseExchange, reply: String = "", cards: [CardDocument]? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var exchange = exchange
        exchange.updatedAt = Date()
        messages[index].muse = exchange
        messages[index].text = exchange.text(reply: reply)
        if let cards { messages[index].cards = cards }
        persistTranscript()
    }
}
