import Foundation

enum PackageTracking {
    struct MailMessage {
        let id: String
        let receivedAt: Date
        let sender: String
        let subject: String
        let content: String
    }

    enum Carrier: String {
        case amazon
        case ups
        case fedex
        case usps
        case dhl
        case ontrac
        case unknown

        var displayName: String {
            switch self {
            case .amazon: return "Amazon Logistics"
            case .ups: return "UPS"
            case .fedex: return "FedEx"
            case .usps: return "USPS"
            case .dhl: return "DHL"
            case .ontrac: return "OnTrac"
            case .unknown: return "Carrier"
            }
        }

        func trackingURL(for number: String) -> String? {
            let encoded = number.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? number
            switch self {
            case .amazon:
                return "https://track.amazon.com/tracking/\(encoded)"
            case .ups:
                return "https://www.ups.com/track?tracknum=\(encoded)"
            case .fedex:
                return "https://www.fedex.com/fedextrack/?trknbr=\(encoded)"
            case .usps:
                return "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(encoded)"
            case .dhl:
                return "https://www.dhl.com/us-en/home/tracking/tracking-express.html"
                    + "?submit=1&tracking-id=\(encoded)"
            case .ontrac:
                return "https://www.ontrac.com/tracking/?number=\(encoded)"
            case .unknown:
                return nil
            }
        }
    }

    enum Status: String {
        case delivered
        case outForDelivery
        case delayed
        case inTransit
        case labelCreated
        case unknown

        var label: String {
            switch self {
            case .delivered: return "Delivered"
            case .outForDelivery: return "Out for delivery"
            case .delayed: return "Delayed"
            case .inTransit: return "In transit"
            case .labelCreated: return "Label created"
            case .unknown: return "Shipment update"
            }
        }
    }

    struct Shipment {
        let id: String
        let merchant: String
        let title: String
        let carrier: Carrier
        let trackingNumber: String?
        let status: Status
        let eta: String?
        let updatedAt: Date
        let group: String

        var payload: [String: Any] {
            var result: [String: Any] = [
                "id": id,
                "merchant": merchant,
                "title": title,
                "carrier": carrier.displayName,
                "status": status.rawValue,
                "statusLabel": status.label,
                "group": group,
                "updatedAt": ISO8601DateFormatter().string(from: updatedAt)
            ]
            if let trackingNumber {
                result["trackingNumber"] = trackingNumber
                result["trackingURL"] = carrier.trackingURL(for: trackingNumber) ?? ""
            }
            if let eta {
                result["eta"] = eta
            }
            return result
        }
    }

    private struct TrackingCandidate {
        let number: String
        let carrier: Carrier
    }

    private struct MutableShipment {
        var shipment: Shipment
    }

    static func shipments(from messages: [MailMessage], now: Date = Date()) -> [Shipment] {
        var shipments: [String: MutableShipment] = [:]
        let uniqueMessages = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.receivedAt >= second.receivedAt ? first : second
            }
        ).values.sorted { $0.receivedAt < $1.receivedAt }

        for message in uniqueMessages {
            let searchable = "\(message.sender)\n\(message.subject)\n\(message.content)"
            let candidates = trackingCandidates(in: searchable)
            let status = shipmentStatus(subject: message.subject, content: message.content)
            guard !candidates.isEmpty || (status != .unknown && hasShippingSignal(searchable))
            else { continue }

            let eta = estimatedDelivery(in: "\(message.subject)\n\(message.content)")
            let merchant = merchantName(sender: message.sender, text: searchable)
            let title = cleanSubject(message.subject)
            let orderID = orderIdentifier(in: searchable)
            let effectiveCandidates: [TrackingCandidate?] = candidates.isEmpty
                ? [nil]
                : candidates.map(Optional.some)

            for candidate in effectiveCandidates {
                let identity = candidate?.number
                    ?? orderID
                    ?? "\(merchant.lowercased())|\(canonicalSubject(title))"
                let carrier = candidate?.carrier ?? carrierFromContext(searchable)
                let effectiveStatus = status == .unknown ? .inTransit : status
                let shipment = Shipment(
                    id: identity,
                    merchant: merchant,
                    title: title,
                    carrier: carrier,
                    trackingNumber: candidate?.number,
                    status: effectiveStatus,
                    eta: eta,
                    updatedAt: message.receivedAt,
                    group: group(for: effectiveStatus, eta: eta, now: now)
                )

                if let existing = shipments[identity]?.shipment {
                    let mergedETA = shipment.eta ?? existing.eta
                    let mergedTracking = shipment.trackingNumber ?? existing.trackingNumber
                    let mergedCarrier = shipment.carrier == .unknown
                        ? existing.carrier
                        : shipment.carrier
                    let mergedStatus = status == .unknown ? existing.status : shipment.status
                    shipments[identity] = MutableShipment(shipment: Shipment(
                        id: identity,
                        merchant: shipment.merchant,
                        title: shipment.title,
                        carrier: mergedCarrier,
                        trackingNumber: mergedTracking,
                        status: mergedStatus,
                        eta: mergedETA,
                        updatedAt: shipment.updatedAt,
                        group: group(for: mergedStatus, eta: mergedETA, now: now)
                    ))
                } else {
                    shipments[identity] = MutableShipment(shipment: shipment)
                }
            }
        }

        let groupOrder = ["arrivingSoon": 0, "active": 1, "delivered": 2]
        let activeCutoff = Calendar.current.date(byAdding: .day, value: -45, to: now)
            ?? .distantPast
        let deliveredCutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)
            ?? .distantPast
        return shipments.values.map(\.shipment).filter {
            $0.updatedAt >= ($0.status == .delivered ? deliveredCutoff : activeCutoff)
        }.sorted {
            let left = groupOrder[$0.group] ?? 3
            let right = groupOrder[$1.group] ?? 3
            if left != right { return left < right }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func trackingCandidates(in text: String) -> [TrackingCandidate] {
        var result: [TrackingCandidate] = []
        var seen = Set<String>()

        func appendMatches(_ pattern: String, carrier: Carrier) {
            for value in captures(pattern, in: text) {
                let normalized = normalizeTrackingNumber(value)
                guard normalized.count >= 8, seen.insert(normalized).inserted else { continue }
                result.append(TrackingCandidate(number: normalized, carrier: carrier))
            }
        }

        appendMatches(#"(?i)\b(1Z[0-9A-Z]{16})\b"#, carrier: .ups)
        appendMatches(#"(?i)\b(TBA\d{10,15})\b"#, carrier: .amazon)
        appendMatches(#"(?i)\b([A-Z]{2}\d{9}US)\b"#, carrier: .usps)
        appendMatches(#"(?i)\b(9[2345](?:[\s-]?\d){18,21})\b"#, carrier: .usps)
        appendMatches(#"(?i)\b(JD\d{18})\b"#, carrier: .dhl)

        let lower = text.lowercased()
        if lower.contains("fedex") || lower.contains("fedex.com") {
            appendMatches(#"\b((?:\d[\s-]?){12}|(?:\d[\s-]?){15}|(?:\d[\s-]?){20}|(?:\d[\s-]?){22})\b"#,
                          carrier: .fedex)
        }
        if lower.contains("ontrac") || lower.contains("lasership") {
            appendMatches(#"(?i)\b([CD](?:[\s-]?\d){14})\b"#, carrier: .ontrac)
        }
        if lower.contains("dhl") {
            appendMatches(#"\b((?:\d[\s-]?){10,11})\b"#, carrier: .dhl)
        }

        for value in captures(
            #"(?i)\b(?:tracking(?:\s+(?:number|no|id))?|track(?:ing)?\s+(?:your\s+)?package)\s*[#:\-]?\s*([A-Z0-9][A-Z0-9-]{7,29})\b"#,
            in: text
        ) {
            let normalized = normalizeTrackingNumber(value)
            guard !normalized.isEmpty,
                  normalized.contains(where: \.isNumber),
                  !isOrderIdentifier(normalized),
                  seen.insert(normalized).inserted else { continue }
            result.append(TrackingCandidate(
                number: normalized,
                carrier: inferCarrier(number: normalized, context: text)
            ))
        }
        return result
    }

    private static func inferCarrier(number: String, context: String) -> Carrier {
        if matches(#"(?i)^1Z[0-9A-Z]{16}$"#, in: number) { return .ups }
        if matches(#"(?i)^TBA\d{10,15}$"#, in: number) { return .amazon }
        if matches(#"(?i)^(?:[A-Z]{2}\d{9}US|9[2345]\d{18,21})$"#, in: number) {
            return .usps
        }
        if matches(#"(?i)^JD\d{18}$"#, in: number) { return .dhl }
        return carrierFromContext(context)
    }

    private static func carrierFromContext(_ text: String) -> Carrier {
        let lower = text.lowercased()
        if lower.contains("amazon") || lower.contains("tba") { return .amazon }
        if lower.contains("fedex") { return .fedex }
        if lower.contains("usps") || lower.contains("postal service") { return .usps }
        if lower.contains("ontrac") || lower.contains("lasership") { return .ontrac }
        if lower.contains("dhl") { return .dhl }
        if matches(#"(?i)\bUPS\b"#, in: text) || lower.contains("ups.com") { return .ups }
        return .unknown
    }

    private static func shipmentStatus(subject: String, content: String) -> Status {
        let subjectStatus = status(in: subject)
        if subjectStatus != .unknown { return subjectStatus }
        return status(in: String(content.prefix(3_000)))
    }

    private static func status(in text: String) -> Status {
        if matches(
            #"(?i)(?:^\s*delivered\b|\b(?:has been|was|successfully) delivered\b|\bpackage (?:was )?delivered\b|\bdelivered (?:at|on|to|today|yesterday)\b)"#,
            in: text
        ) {
            return .delivered
        }
        if matches(
            #"(?i)\b(?:delayed|delivery exception|delivery attempt|unable to deliver|problem with (?:your )?(?:delivery|shipment)|held at)\b"#,
            in: text
        ) {
            return .delayed
        }
        if matches(
            #"(?i)\b(?:out for delivery|arriv(?:ing|es) today|delivery today)\b"#,
            in: text
        ) {
            return .outForDelivery
        }
        if matches(
            #"(?i)\b(?:has shipped|shipped|on the way|in transit|picked up|departed|moving through (?:the )?network)\b"#,
            in: text
        ) {
            return .inTransit
        }
        if matches(
            #"(?i)\b(?:label created|shipment information (?:sent|received)|pre-shipment|awaiting (?:the )?(?:item|package))\b"#,
            in: text
        ) {
            return .labelCreated
        }
        return .unknown
    }

    private static func estimatedDelivery(in text: String) -> String? {
        let days = "(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"
        let months = "(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|"
            + "Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|"
            + "Nov(?:ember)?|Dec(?:ember)?)"
        let date = "(?:today|tomorrow|\(days)(?:,?\\s+\(months)\\s+\\d{1,2})?|"
            + "\(months)\\s+\\d{1,2}(?:,?\\s+\\d{4})?|"
            + "\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?)"
        let pattern = "(?i)\\b(?:arriving|arrives|estimated delivery(?: date)?|"
            + "expected delivery|scheduled delivery|delivery date)"
            + "\\s*(?:is|:|-)?\\s*(?:by|on)?\\s*(\(date))\\b"
        return firstCapture(pattern, in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func group(for status: Status, eta: String?, now: Date) -> String {
        if status == .delivered { return "delivered" }
        if status == .outForDelivery { return "arrivingSoon" }
        if let eta, isSoon(eta, relativeTo: now) { return "arrivingSoon" }
        return "active"
    }

    private static func isSoon(_ eta: String, relativeTo now: Date) -> Bool {
        let lower = eta.lowercased()
        if lower == "today" || lower == "tomorrow" { return true }
        guard let date = date(fromETA: eta, relativeTo: now) else { return false }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else {
            return false
        }
        return date >= start && date <= end
    }

    private static func date(fromETA eta: String, relativeTo now: Date) -> Date? {
        let calendar = Calendar.current
        var value = eta.trimmingCharacters(in: .whitespacesAndNewlines)
        let weekdays = DateFormatter().weekdaySymbols ?? []
        if let weekday = weekdays.first(where: { value.caseInsensitiveCompare($0) == .orderedSame }),
           let index = weekdays.firstIndex(of: weekday) {
            let current = calendar.component(.weekday, from: now)
            let target = index + 1
            let daysAhead = (target - current + 7) % 7
            return calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now))
        }
        if let comma = value.firstIndex(of: ",") {
            let prefix = String(value[..<comma])
            if weekdays.contains(where: { prefix.caseInsensitiveCompare($0) == .orderedSame }) {
                value = String(value[value.index(after: comma)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        if !value.contains(String(calendar.component(.year, from: now))) {
            value += " \(calendar.component(.year, from: now))"
        }
        for format in ["MMMM d yyyy", "MMM d yyyy", "M/d/yyyy", "M/d/yy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value.replacingOccurrences(of: ",", with: "")) {
                return date
            }
        }
        return nil
    }

    private static func merchantName(sender: String, text: String) -> String {
        let lower = text.lowercased()
        let known: [(terms: [String], name: String)] = [
            (["amazon", "amzn"], "Amazon"),
            (["shop.app", "shopify"], "Shop"),
            (["walmart"], "Walmart"),
            (["best buy", "bestbuy"], "Best Buy"),
            (["target.com"], "Target"),
            (["apple.com"], "Apple"),
            (["etsy"], "Etsy"),
            (["ebay"], "eBay"),
            (["nike"], "Nike"),
            (["fedex"], "FedEx"),
            (["usps", "postal service"], "USPS"),
            (["ontrac", "lasership"], "OnTrac"),
            (["dhl"], "DHL")
        ]
        if let match = known.first(where: { item in
            item.terms.contains(where: lower.contains)
        }) {
            return match.name
        }
        if matches(#"(?i)\bUPS\b"#, in: sender) || sender.lowercased().contains("ups.com") {
            return "UPS"
        }
        let display = sender
            .components(separatedBy: "<").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
            ?? ""
        if !display.isEmpty, !display.contains("@") {
            return String(display.prefix(60))
        }
        if let domain = sender.split(separator: "@").last?
            .split(separator: ">").first?
            .split(separator: ".").first {
            return String(domain).capitalized
        }
        return "Shipment"
    }

    private static func cleanSubject(_ subject: String) -> String {
        let clean = subject
            .replacingOccurrences(
                of: #"(?i)^\s*(?:re|fwd?)\s*:\s*"#,
                with: "",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return clean.isEmpty ? "Package update" : String(clean.prefix(140))
    }

    private static func canonicalSubject(_ subject: String) -> String {
        subject.lowercased()
            .replacingOccurrences(
                of: #"(?i)\b(?:delivered|shipped|shipping|arriving|arrival|delivery|package|order|update|your|is|has|been|on|the|way)\b"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .prefix(8)
            .joined(separator: "-")
    }

    private static func orderIdentifier(in text: String) -> String? {
        if let amazon = firstCapture(#"\b(\d{3}-\d{7}-\d{7})\b"#, in: text) {
            return "order:\(amazon)"
        }
        if let generic = firstCapture(
            #"(?i)\border\s*(?:number|no\.?|#|:)\s*([A-Z0-9][A-Z0-9-]{3,24})\b"#,
            in: text
        ) {
            return "order:\(generic.uppercased())"
        }
        return nil
    }

    private static func isOrderIdentifier(_ value: String) -> Bool {
        matches(#"^\d{3}-\d{7}-\d{7}$"#, in: value)
    }

    private static func hasShippingSignal(_ text: String) -> Bool {
        matches(
            #"(?i)\b(?:package|shipment|shipped|shipping|deliver(?:ed|y|ing)?|arriv(?:e|es|ing|al)|tracking|on the way|out for delivery|label created)\b"#,
            in: text
        )
    }

    private static func normalizeTrackingNumber(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }
}
