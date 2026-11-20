import CryptoKit
import Foundation

/// Weak entity tags for JSON reads. A client that sends back the tag of the copy it already holds
/// (If-None-Match) gets 304 Not Modified with no body when nothing changed. Responses stay
/// `Cache-Control: no-store`, so browsers never keep private data; only clients that keep their own
/// copy (the iPhone app's saved copy) send the header, and older clients never see a 304.
enum HTTPEntityTag {
    static func applies(status: Int, isGet: Bool, contentType: String) -> Bool {
        status == 200 && isGet
            && contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// A hash of the body as encoded before compression, so gzip and identity clients share one tag.
    static func tag(for body: Data) -> String {
        "W/\"" + SHA256.hash(data: body).prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
    }

    /// If-None-Match names this tag (compared weakly) or is `*`.
    static func matches(_ header: String?, _ tag: String) -> Bool {
        guard let header, !header.isEmpty else { return false }
        func opaque(_ value: Substring) -> Substring {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return Substring(trimmed.hasPrefix("W/") ? String(trimmed.dropFirst(2)) : trimmed)
        }
        let wanted = opaque(Substring(tag))
        return header.split(separator: ",").contains { item in
            item.trimmingCharacters(in: .whitespaces) == "*" || opaque(item) == wanted
        }
    }
}
