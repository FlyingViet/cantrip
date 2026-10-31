import AppKit
import CoreLocation
import CryptoKit
import Darwin
import Foundation
import MapKit
import SwiftUI

// MARK: - Link Preview Models

/// Metadata and cached image reference for a rich web link card shown under an assistant reply.
struct LinkPreviewCard: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var url: String
    var domain: String
    var title: String
    var siteName: String?
    var imageID: String?

    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "url": url,
            "domain": domain,
            "title": title,
        ]
        if let siteName, !siteName.isEmpty { result["siteName"] = siteName }
        if let imageID, !imageID.isEmpty { result["imageID"] = imageID }
        return result
    }
}

// MARK: - Link Preview Security & Extraction

enum LinkPreviewSecurity {
    static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authorization",
        "key", "api_key", "apikey", "secret", "client_secret", "password", "passwd", "pwd",
        "sig", "signature", "x-amz-signature", "x-amz-security-token", "x-amz-credential",
        "x-goog-signature", "x-goog-credential", "sas", "se", "sp", "sv", "sr",
        "code", "session", "session_id", "sessionid", "jwt", "bearer", "credential",
        "private_key", "passcode", "otp", "nonce",
    ]

    static let blockedHostSuffixes: [String] = [
        ".local", ".localhost", ".internal", ".lan", ".home.arpa",
        ".ts.net",
    ]

    /// Your own domains whose pages are private, e.g. a home lab's (`defaults write <bundle id>
    /// richCardBlockedDomains -array example.net`): never fetched for a preview, subdomains too.
    static var blockedDomains: [String] {
        (UserDefaults.standard.stringArray(forKey: "richCardBlockedDomains") ?? [])
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }
    }

    static func cleanDomain(for url: URL) -> String {
        guard var host = url.host?.lowercased() else { return "" }
        if host.hasPrefix("www.") && host.count > 4 {
            host.removeFirst(4)
        }
        return host
    }

    static func cardID(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidImageID(_ id: String) -> Bool {
        guard (16...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
        }
    }

    /// Returns true only for public HTTP/HTTPS URLs without credentials, private/tailnet hosts, or token query strings.
    static func isAllowed(urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return isAllowed(url: url)
    }

    static func isAllowed(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard url.user == nil && url.password == nil else {
            return false
        }
        guard let rawHost = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !rawHost.isEmpty else {
            return false
        }
        if rawHost == "localhost" || rawHost == "ts.net" {
            return false
        }
        for domain in blockedDomains where rawHost == domain || rawHost.hasSuffix("." + domain) {
            return false
        }
        for suffix in blockedHostSuffixes where rawHost.hasSuffix(suffix) {
            return false
        }
        let unbracketed = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLiteralIPAddress(unbracketed) {
            if isPrivateOrReservedIP(unbracketed) { return false }
        } else if !rawHost.contains(".") {
            // Single-label intranet hostnames (e.g. http://nas/admin) are never public web pages.
            return false
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if sensitiveQueryKeys.contains(name) { return false }
                if name.contains("token") || name.contains("secret") || name.contains("signature")
                    || name.contains("password") || name.contains("apikey") || name.contains("api_key") {
                    return false
                }
            }
        }
        return true
    }

    /// Verifies via DNS that `host` resolves only to public IPv4/IPv6 addresses.
    static func resolvesToPublicAddress(host: String) -> Bool {
        let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLiteralIPAddress(clean) {
            return !isPrivateOrReservedIP(clean)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(clean, nil, &hints, &res)
        guard status == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var sawAddress = false
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let addr = info.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = getnameinfo(
                addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard err == 0 else { return false }
            let ip = String(cString: buffer)
            sawAddress = true
            if isPrivateOrReservedIP(ip) { return false }
        }
        return sawAddress
    }

    static func isLiteralIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let clean = host.components(separatedBy: "%").first ?? host
        return inet_pton(AF_INET, clean, &v4) == 1 || inet_pton(AF_INET6, clean, &v6) == 1
    }

    static func isPrivateOrReservedIP(_ ip: String) -> Bool {
        let clean = ip.components(separatedBy: "%").first ?? ip
        var v4 = in_addr()
        if inet_pton(AF_INET, clean, &v4) == 1 {
            return isPrivateOrReservedIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, clean, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            guard bytes.count == 16 else { return true }
            // Unspecified :: or loopback ::1
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
                return true
            }
            // IPv4-mapped ::ffff:a.b.c.d
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                let mapped = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                    | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
                return isPrivateOrReservedIPv4(mapped)
            }
            // Unique local fc00::/7 (includes Tailscale fd7a:115c:a1e0::/48)
            if (bytes[0] & 0xfe) == 0xfc { return true }
            // Link-local fe80::/10
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
            // Multicast ff00::/8
            if bytes[0] == 0xff { return true }
            // Documentation 2001:db8::/32
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
                return true
            }
            return false
        }
        return true
    }

    private static func isPrivateOrReservedIPv4(_ address: UInt32) -> Bool {
        let a = (address >> 24) & 0xff
        let b = (address >> 16) & 0xff
        let c = (address >> 8) & 0xff
        if a == 0 || a == 10 || a == 127 { return true } // 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8
        if a == 100 && (b & 0xc0) == 64 { return true }  // 100.64.0.0/10 (CGNAT / Tailscale)
        if a == 169 && b == 254 { return true }          // 169.254.0.0/16 (link-local)
        if a == 172 && (16...31).contains(b) { return true } // 172.16.0.0/12
        if a == 192 && b == 0 && (c == 0 || c == 2) { return true } // 192.0.0.0/24, 192.0.2.0/24
        if a == 192 && b == 168 { return true }          // 192.168.0.0/16
        if a == 198 && (b == 18 || b == 19) { return true } // 198.18.0.0/15
        if a == 198 && b == 51 && c == 100 { return true } // 198.51.100.0/24
        if a == 203 && b == 0 && c == 113 { return true } // 203.0.113.0/24
        if a >= 224 { return true }                      // Multicast & reserved 224.0.0.0/4+
        return false
    }
}

enum LinkPreviewExtractor {
    static let maximumLinksPerMessage = 3

    /// Extracts up to 3 distinct allowed HTTP/HTTPS URLs from Markdown text outside code blocks and inline code.
    static func extractURLs(from markdown: String, limit: Int = maximumLinksPerMessage) -> [URL] {
        guard limit > 0, !markdown.isEmpty else { return [] }
        let stripped = stripCodeBlocksAndSpans(from: markdown)
        var results: [URL] = []
        var seen = Set<String>()

        func consider(_ raw: String) {
            guard results.count < limit else { return }
            let cleaned = trimURLPunctuation(raw)
            guard let url = URL(string: cleaned), LinkPreviewSecurity.isAllowed(url: url) else { return }
            let key = normalizedKey(for: url)
            guard seen.insert(key).inserted else { return }
            results.append(url)
        }

        // Remove Markdown image links ![alt](url) so inline images aren't treated as page links.
        let withoutImages = stripped.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#,
            with: " ",
            options: .regularExpression
        )

        // Match Markdown links [label](url), autolinks <https://...>, or bare https?://...
        let pattern = #"\[[^\]]+\]\(\s*(https?://[^\s)"']+)(?:\s+["'][^"']*["'])?\s*\)|<(https?://[^>\s]+)>|\b(https?://[^\s<>()]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsRange = NSRange(withoutImages.startIndex..<withoutImages.endIndex, in: withoutImages)
        regex.enumerateMatches(in: withoutImages, options: [], range: nsRange) { match, _, stop in
            guard let match else { return }
            for group in 1...3 {
                let range = match.range(at: group)
                if range.location != NSNotFound, let swiftRange = Range(range, in: withoutImages) {
                    consider(String(withoutImages[swiftRange]))
                    break
                }
            }
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    private static func normalizedKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.string ?? url.absoluteString
    }

    private static func trimURLPunctuation(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\"", "”", "’"]
        while let last = result.last, trailing.contains(last) {
            if last == ")" {
                let opens = result.filter { $0 == "(" }.count
                let closes = result.filter { $0 == ")" }.count
                if closes <= opens { break }
            }
            result.removeLast()
        }
        return result
    }

    private static func stripCodeBlocksAndSpans(from text: String) -> String {
        var nonFencedLines: [String] = []
        var activeFence: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if trimmed.hasPrefix(fence) {
                    activeFence = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                activeFence = "```"
                continue
            }
            if trimmed.hasPrefix("~~~") {
                activeFence = "~~~"
                continue
            }
            nonFencedLines.append(line)
        }
        let withoutFences = nonFencedLines.joined(separator: "\n")
        // Strip inline code spans `...`
        var output = ""
        output.reserveCapacity(withoutFences.count)
        var index = withoutFences.startIndex
        while index < withoutFences.endIndex {
            if withoutFences[index] == "`" {
                var ticks = 0
                var tickEnd = index
                while tickEnd < withoutFences.endIndex && withoutFences[tickEnd] == "`" {
                    ticks += 1
                    tickEnd = withoutFences.index(after: tickEnd)
                }
                let delimiter = String(repeating: "`", count: ticks)
                if let closing = withoutFences.range(of: delimiter, range: tickEnd..<withoutFences.endIndex) {
                    output.append(" ")
                    index = closing.upperBound
                    continue
                } else {
                    output.append(contentsOf: delimiter)
                    index = tickEnd
                    continue
                }
            }
            output.append(withoutFences[index])
            index = withoutFences.index(after: index)
        }
        return output
    }
}

// MARK: - HTML Open Graph / Title Parser

enum LinkPreviewHTMLParser {
    struct ParsedMetadata: Equatable, Sendable {
        var title: String
        var siteName: String?
        var imageURL: URL?
        var domain: String
    }

    static func parse(htmlData: Data, pageURL: URL) -> ParsedMetadata? {
        let prefixData = htmlData.prefix(512 * 1024)
        let html = String(data: prefixData, encoding: .utf8)
            ?? String(data: prefixData, encoding: .isoLatin1)
            ?? ""
        return parse(html: html, pageURL: pageURL)
    }

    static func parse(html: String, pageURL: URL) -> ParsedMetadata? {
        guard LinkPreviewSecurity.isAllowed(url: pageURL) else { return nil }
        let domain = LinkPreviewSecurity.cleanDomain(for: pageURL)
        guard !domain.isEmpty else { return nil }

        // Only inspect up to </head> if present (plus a generous prefix) to avoid scanning huge bodies.
        let headScope: String
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            headScope = String(html[..<headEnd.upperBound])
        } else {
            headScope = String(html.prefix(128 * 1024))
        }

        let metas = extractMetaTags(from: headScope)
        let ogTitle = metas["og:title"]
        let twitterTitle = metas["twitter:title"]
        let docTitle = extractTitleTag(from: headScope)

        let rawTitle = [ogTitle, twitterTitle, docTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let chosenTitle = rawTitle.map(sanitizeText), !chosenTitle.isEmpty else {
            return nil
        }

        let rawSite = metas["og:site_name"] ?? metas["application-name"]
        let siteName = rawSite.map(sanitizeText).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }

        let rawImage = metas["og:image:secure_url"]
            ?? metas["og:image"]
            ?? metas["og:image:url"]
            ?? metas["twitter:image"]
            ?? metas["twitter:image:src"]
        var resolvedImageURL: URL?
        if let rawImage = rawImage.map(decodeHTMLEntities)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawImage.isEmpty,
           let candidate = URL(string: rawImage, relativeTo: pageURL)?.absoluteURL,
           LinkPreviewSecurity.isAllowed(url: candidate) {
            resolvedImageURL = candidate
        }

        return ParsedMetadata(
            title: String(chosenTitle.prefix(200)),
            siteName: siteName,
            imageURL: resolvedImageURL,
            domain: domain
        )
    }

    private static func extractMetaTags(from html: String) -> [String: String] {
        var values: [String: String] = [:]
        guard let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]),
              let attrRegex = try? NSRegularExpression(
                pattern: #"([a-zA-Z0-9_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#,
                options: []
              ) else {
            return values
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        metaRegex.enumerateMatches(in: html, options: [], range: nsRange) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let tag = String(html[tagRange])
            var attrs: [String: String] = [:]
            let tagNSRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            attrRegex.enumerateMatches(in: tag, options: [], range: tagNSRange) { attrMatch, _, _ in
                guard let attrMatch, let nameRange = Range(attrMatch.range(at: 1), in: tag) else { return }
                let name = tag[nameRange].lowercased()
                for group in 2...4 {
                    let valRange = attrMatch.range(at: group)
                    if valRange.location != NSNotFound, let swiftValRange = Range(valRange, in: tag) {
                        attrs[name] = String(tag[swiftValRange])
                        break
                    }
                }
            }
            guard let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(),
                  let content = attrs["content"], !content.isEmpty else {
                return
            }
            if values[key] == nil {
                values[key] = content
            }
        }
        return values
    }

    private static func extractTitleTag(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<title\b[^>]*>(.*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    static func sanitizeText(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = decodeHTMLEntities(withoutTags)
        let cleanedScalars = decoded.unicodeScalars.filter { scalar in
            scalar == " " || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(cleanedScalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&ndash;", "–"),
            ("&mdash;", "—"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&rdquo;", "”"), ("&ldquo;", "“"), ("&trade;", "™"),
            ("&reg;", "®"), ("&copy;", "©"), ("&hellip;", "…"), ("&middot;", "·"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]{1,6})|([0-9]{1,7}));"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result) else { continue }
                var codePoint: UInt32?
                if match.range(at: 1).location != NSNotFound, let hexRange = Range(match.range(at: 1), in: result) {
                    codePoint = UInt32(result[hexRange], radix: 16)
                } else if match.range(at: 2).location != NSNotFound, let decRange = Range(match.range(at: 2), in: result) {
                    codePoint = UInt32(result[decRange], radix: 10)
                }
                if let codePoint, let scalar = UnicodeScalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }
        return result
    }
}

// MARK: - Link Preview Store & Safe Unfurler

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              LinkPreviewSecurity.isAllowed(url: url),
              let host = url.host,
              LinkPreviewSecurity.resolvesToPublicAddress(host: host) else {
            completionHandler(nil)
            return
        }
        var clean = request
        clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(clean)
    }
}

actor LinkPreviewStore {
    static let shared = LinkPreviewStore()

    typealias FetchHandler = @Sendable (URL) async throws -> (Data, URL, String?)

    static let maxHTMLBytes = 512 * 1024
    static let maxImageBytes = 4 * 1024 * 1024

    private var memoryCards: [String: LinkPreviewCard] = [:]
    private var memoryImages: [String: Data] = [:]
    private var customFetcher: FetchHandler?
    private let redirectDelegate = SafeRedirectDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    init(fetcher: FetchHandler? = nil) {
        self.customFetcher = fetcher
    }

    func setCustomFetcher(_ fetcher: FetchHandler?) {
        self.customFetcher = fetcher
    }

    private var cacheDirectory: URL {
        CantripPaths.cache("link-previews", isDirectory: true)
    }

    func resolve(forText text: String, enabled: Bool = true) async -> [LinkPreviewCard] {
        guard enabled else { return [] }
        let urls = LinkPreviewExtractor.extractURLs(from: text)
        guard !urls.isEmpty else { return [] }
        return await resolve(urls: urls)
    }

    func resolve(urls: [URL]) async -> [LinkPreviewCard] {
        if customFetcher == nil, ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil {
            return []
        }
        var cards: [LinkPreviewCard] = []
        for url in urls.prefix(LinkPreviewExtractor.maximumLinksPerMessage) {
            if let card = await resolveOne(url: url) {
                cards.append(card)
            }
        }
        return cards
    }

    func imageData(id: String) -> Data? {
        guard LinkPreviewSecurity.isValidImageID(id) else { return nil }
        if let data = memoryImages[id] { return data }
        let file = cacheDirectory.appendingPathComponent("\(id).img")
        guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= Self.maxImageBytes else {
            return nil
        }
        memoryImages[id] = data
        return data
    }

    func storeCachedImage(_ data: Data, id: String) {
        guard LinkPreviewSecurity.isValidImageID(id), !data.isEmpty, data.count <= Self.maxImageBytes else { return }
        memoryImages[id] = data
        let dir = cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(id).img"), options: .atomic)
    }

    private func resolveOne(url: URL) async -> LinkPreviewCard? {
        guard LinkPreviewSecurity.isAllowed(url: url) else { return nil }
        let id = LinkPreviewSecurity.cardID(for: url.absoluteString)
        if let cached = memoryCards[id] {
            if cached.imageID == nil || imageData(id: id) != nil {
                return cached
            }
        }
        let metaFile = cacheDirectory.appendingPathComponent("\(id).json")
        if customFetcher == nil,
           let data = try? Data(contentsOf: metaFile),
           let diskCard = try? JSONDecoder().decode(LinkPreviewCard.self, from: data) {
            if diskCard.imageID == nil || imageData(id: id) != nil {
                memoryCards[id] = diskCard
                return diskCard
            }
        }

        do {
            let (htmlData, finalURL, mimeType) = try await fetchResource(url: url, maxBytes: Self.maxHTMLBytes, accept: "text/html,application/xhtml+xml")
            guard LinkPreviewSecurity.isAllowed(url: finalURL) else { return nil }
            if let mimeType = mimeType?.lowercased(),
               !mimeType.contains("html") && !mimeType.contains("xml") && !mimeType.contains("text/plain") {
                return nil
            }
            guard let parsed = LinkPreviewHTMLParser.parse(htmlData: htmlData, pageURL: finalURL) else {
                return nil
            }
            var imageID: String?
            if let imageURL = parsed.imageURL {
                if let (imgBytes, finalImgURL, _) = try? await fetchResource(url: imageURL, maxBytes: Self.maxImageBytes, accept: "image/*"),
                   LinkPreviewSecurity.isAllowed(url: finalImgURL),
                   Self.looksLikeImage(imgBytes) {
                    storeCachedImage(imgBytes, id: id)
                    imageID = id
                }
            }
            let card = LinkPreviewCard(
                id: id,
                url: finalURL.absoluteString,
                domain: parsed.domain,
                title: parsed.title,
                siteName: parsed.siteName,
                imageID: imageID
            )
            memoryCards[id] = card
            let dir = cacheDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(card) {
                try? encoded.write(to: metaFile, options: .atomic)
            }
            return card
        } catch {
            return nil
        }
    }

    private func fetchResource(url: URL, maxBytes: Int, accept: String) async throws -> (Data, URL, String?) {
        guard LinkPreviewSecurity.isAllowed(url: url) else {
            throw URLError(.noPermissionsToReadFile)
        }
        if let customFetcher {
            let (data, finalURL, mime) = try await customFetcher(url)
            guard data.count <= maxBytes, LinkPreviewSecurity.isAllowed(url: finalURL) else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return (data, finalURL, mime)
        }
        guard let host = url.host else { throw URLError(.badURL) }
        let allowedDNS = await Task.detached(priority: .utility) {
            LinkPreviewSecurity.resolvesToPublicAddress(host: host)
        }.value
        guard allowedDNS else { throw URLError(.noPermissionsToReadFile) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = http.url, LinkPreviewSecurity.isAllowed(url: finalURL) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return (data, finalURL, http.mimeType)
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let prefix = Array(data.prefix(12))
        // JPEG: FF D8 FF
        if prefix[0] == 0xFF && prefix[1] == 0xD8 && prefix[2] == 0xFF { return true }
        // PNG: 89 50 4E 47
        if prefix[0] == 0x89 && prefix[1] == 0x50 && prefix[2] == 0x4E && prefix[3] == 0x47 { return true }
        // GIF: 47 49 46 38
        if prefix[0] == 0x47 && prefix[1] == 0x49 && prefix[2] == 0x46 && prefix[3] == 0x38 { return true }
        // WebP: RIFF....WEBP
        if prefix[0] == 0x52 && prefix[1] == 0x49 && prefix[2] == 0x46 && prefix[3] == 0x46
            && prefix[8] == 0x57 && prefix[9] == 0x45 && prefix[10] == 0x42 && prefix[11] == 0x50 {
            return true
        }
        return false
    }
}

// MARK: - Inline Map Card Models

/// One verified real-world place pin and list row inside an inline map card.
struct PlacePin: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var category: String?
    var address: String?
    var phone: String?
    var website: String?
    var rating: Double?
    var reviewCount: Int?
    var priceLevel: String?
    var isOpenNow: Bool?
    var hoursSummary: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var appleMapsURL: String {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)),
        ]
        return components.string ?? "https://maps.apple.com/"
    }

    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "name": name,
            "latitude": latitude,
            "longitude": longitude,
            "appleMapsURL": appleMapsURL,
        ]
        if let category, !category.isEmpty { result["category"] = category }
        if let address, !address.isEmpty { result["address"] = address }
        if let phone, !phone.isEmpty { result["phone"] = phone }
        if let website, !website.isEmpty { result["website"] = website }
        if let rating { result["rating"] = rating }
        if let reviewCount { result["reviewCount"] = reviewCount }
        if let priceLevel, !priceLevel.isEmpty { result["priceLevel"] = priceLevel }
        if let isOpenNow { result["isOpenNow"] = isOpenNow }
        if let hoursSummary, !hoursSummary.isEmpty { result["hoursSummary"] = hoursSummary }
        return result
    }
}

/// Interactive inline map card attached to an assistant reply.
struct PlaceCard: Codable, Equatable, Sendable {
    var query: String
    var regionName: String?
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
    var places: [PlacePin]
    var attribution: String = "Apple Maps · © OpenStreetMap"

    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "query": query,
            "centerLatitude": centerLatitude,
            "centerLongitude": centerLongitude,
            "latitudeDelta": latitudeDelta,
            "longitudeDelta": longitudeDelta,
            "places": places.map(\.snapshot),
            "attribution": attribution,
        ]
        if let regionName, !regionName.isEmpty { result["regionName"] = regionName }
        return result
    }
}

/// Fenced `places` / `cantrip-places` JSON payload emitted by the agent at the end of a reply.
/// Coordinates, hours, ratings, and contact details are resolved by `PlaceCardResolver` from
/// MapKit and OpenStreetMap rather than accepted from model guesses.
struct PlaceBlockProposal: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var name: String
        var query: String?
        var category: String?
    }

    var query: String?
    var near: String?
    var places: [Item]
}

// MARK: - OpenStreetMap Opening Hours Evaluator

enum OSMOpeningHours {
    private static let dayCodes: [String: Int] = [
        "su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7,
    ]

    /// Evaluates standard OpenStreetMap `opening_hours` strings (e.g. `"24/7"`,
    /// `"Mo-Fr 08:00-17:00; Sa 09:00-14:00; Su off"`) at `date` in `timeZone`.
    /// Returns `nil` when the string is empty or uses unsupported syntax.
    static func evaluate(_ raw: String?, at date: Date = Date(), timeZone: TimeZone = .current) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let cleaned = raw.lowercased()
        if cleaned == "24/7" { return true }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date) // 1 = Sun ... 7 = Sat
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let currentMinutes = hour * 60 + minute

        let clauses = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return nil }

        var parsedAnyClause = false
        var matchedOpen = false
        var matchedClosed = false

        for clause in clauses {
            let lower = clause.lowercased()
            if lower.hasPrefix("ph ") || lower.hasPrefix("ph,") {
                continue
            }
            guard let parsed = parseClause(lower) else { continue }
            parsedAnyClause = true
            guard parsed.weekdays.contains(weekday) else { continue }
            if parsed.isOff {
                matchedClosed = true
                matchedOpen = false
            } else {
                for range in parsed.minuteRanges {
                    if range.contains(currentMinutes) {
                        matchedOpen = true
                    }
                }
            }
        }

        guard parsedAnyClause else { return nil }
        if matchedClosed { return false }
        return matchedOpen
    }

    private struct ClauseRule {
        var weekdays: Set<Int>
        var isOff: Bool
        var minuteRanges: [ClosedRange<Int>]
    }

    private static func parseClause(_ clause: String) -> ClauseRule? {
        let tokens = clause.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var weekdays = Set<Int>()
        var timePartIndex = 0
        if let parsedDays = parseDays(tokens[0]) {
            weekdays = parsedDays
            timePartIndex = 1
        } else {
            // No day selector means every day (e.g. "08:00-20:00")
            weekdays = Set(1...7)
            timePartIndex = 0
        }

        guard timePartIndex < tokens.count else { return nil }
        let rest = tokens[timePartIndex...].joined(separator: " ")
        if rest == "off" || rest == "closed" {
            return ClauseRule(weekdays: weekdays, isOff: true, minuteRanges: [])
        }
        if rest == "24/7" || rest == "open" {
            return ClauseRule(weekdays: weekdays, isOff: false, minuteRanges: [0...1440])
        }

        var ranges: [ClosedRange<Int>] = []
        for piece in rest.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let endpoints = trimmed.split(separator: "-").map(String.init)
            guard endpoints.count == 2,
                  let start = parseMinutes(endpoints[0]),
                  let end = parseMinutes(endpoints[1]) else {
                return nil
            }
            if end >= start {
                ranges.append(start...end)
            } else {
                // Overnight range e.g. 18:00-02:00
                ranges.append(start...1440)
                ranges.append(0...end)
            }
        }
        guard !ranges.isEmpty else { return nil }
        return ClauseRule(weekdays: weekdays, isOff: false, minuteRanges: ranges)
    }

    private static func parseDays(_ spec: String) -> Set<Int>? {
        var days = Set<Int>()
        for part in spec.split(separator: ",") {
            let cleaned = part.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { continue }
            if cleaned == "ph" { continue }
            let rangeParts = cleaned.split(separator: "-").map(String.init)
            if rangeParts.count == 1 {
                guard let day = dayCodes[rangeParts[0]] else { return nil }
                days.insert(day)
            } else if rangeParts.count == 2 {
                guard let start = dayCodes[rangeParts[0]], let end = dayCodes[rangeParts[1]] else {
                    return nil
                }
                if start <= end {
                    for d in start...end { days.insert(d) }
                } else {
                    for d in start...7 { days.insert(d) }
                    for d in 1...end { days.insert(d) }
                }
            } else {
                return nil
            }
        }
        return days.isEmpty ? nil : days
    }

    private static func parseMinutes(_ clock: String) -> Int? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...24).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }
}

// MARK: - Place Card Resolver (MapKit + OpenStreetMap)

actor PlaceCardResolver {
    static let shared = PlaceCardResolver()
    @MainActor static var locationContextProvider: (() -> String?)?

    static let agentGuidance = """
    When your reply recommends real-world places (clinics, restaurants, cafes, stores, venues, or \
    landmarks), end your reply with a fenced `places` JSON block so Cantrip can render an \
    interactive map card with place pins under your text:
    ```places
    {"near":"Santa Clara, CA","places":[{"name":"Concentra Urgent Care","query":"Concentra Urgent Care Santa Clara CA","category":"Urgent care clinic"}]}
    ```
    Include only real places you named in your reply (up to 8). Omit fields you do not know; \
    Cantrip resolves exact coordinates, addresses, hours, phone numbers, and websites via MapKit \
    and OpenStreetMap. Never invent ratings, price levels, hours, or coordinates.
    """

    typealias LookupHandler = @Sendable (PlaceBlockProposal, Date) async -> PlaceCard?

    private var customLookup: LookupHandler?
    private let osmSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    init(lookup: LookupHandler? = nil) {
        self.customLookup = lookup
    }

    func setCustomLookup(_ lookup: LookupHandler?) {
        self.customLookup = lookup
    }

    /// Strips fenced `places` or `cantrip-places` JSON blocks from `text` and returns the last valid proposal.
    static func extractProposal(from text: inout String) -> PlaceBlockProposal? {
        guard let regex = try? NSRegularExpression(
            pattern: #"```(?:cantrip-places|places)[ \t]*\r?\n(.*?)```"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return nil }

        var latestProposal: PlaceBlockProposal?
        for match in matches.reversed() {
            if latestProposal == nil, let payloadRange = Range(match.range(at: 1), in: text) {
                let rawJSON = String(text[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                latestProposal = decodeProposal(from: rawJSON)
            }
            if let fullRange = Range(match.range, in: text) {
                text.removeSubrange(fullRange)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return latestProposal
    }

    static func decodeProposal(from json: String) -> PlaceBlockProposal? {
        guard let data = json.data(using: .utf8), data.count <= 32 * 1024 else { return nil }
        if let proposal = try? JSONDecoder().decode(PlaceBlockProposal.self, from: data) {
            let validItems = proposal.places.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !validItems.isEmpty || (proposal.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
                return PlaceBlockProposal(
                    query: proposal.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                    near: proposal.near?.trimmingCharacters(in: .whitespacesAndNewlines),
                    places: Array(validItems.prefix(8))
                )
            }
        }
        if let items = try? JSONDecoder().decode([PlaceBlockProposal.Item].self, from: data) {
            let validItems = items.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !validItems.isEmpty else { return nil }
            return PlaceBlockProposal(query: nil, near: nil, places: Array(validItems.prefix(8)))
        }
        return nil
    }

    func resolve(_ proposal: PlaceBlockProposal, now: Date = Date()) async -> PlaceCard? {
        if let customLookup {
            return await customLookup(proposal, now)
        }
        if ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil {
            return nil
        }
        return await resolveLive(proposal, now: now)
    }

    private func resolveLive(_ proposal: PlaceBlockProposal, now: Date) async -> PlaceCard? {
        let nearHint = proposal.near?.trimmingCharacters(in: .whitespacesAndNewlines)
        let regionHint = await resolveSearchRegion(near: nearHint)
        var resolvedPins: [PlacePin] = []
        var seenCoordinates: [CLLocationCoordinate2D] = []

        if !proposal.places.isEmpty {
            for (index, item) in proposal.places.prefix(8).enumerated() {
                let rawSearch = (item.query ?? item.name).trimmingCharacters(in: .whitespacesAndNewlines)
                let searchQuery: String
                if let nearHint, !nearHint.isEmpty,
                   !rawSearch.localizedCaseInsensitiveContains(nearHint) {
                    searchQuery = "\(rawSearch) \(nearHint)"
                } else {
                    searchQuery = rawSearch
                }
                guard let mapItem = await searchFirstMapItem(query: searchQuery, region: regionHint) else {
                    continue
                }
                let coord = Self.coordinate(of: mapItem)
                guard CLLocationCoordinate2DIsValid(coord),
                      !(coord.latitude == 0 && coord.longitude == 0) else {
                    continue
                }
                // Deduplicate pins within ~30 meters of each other with the same name.
                if seenCoordinates.contains(where: {
                    abs($0.latitude - coord.latitude) < 0.0003 && abs($0.longitude - coord.longitude) < 0.0003
                }) {
                    continue
                }
                seenCoordinates.append(coord)

                let osmMeta = await fetchOSMMetadata(
                    name: mapItem.name ?? item.name,
                    coordinate: coord,
                    now: now
                )
                let category = Self.friendlyCategory(mapItem.pointOfInterestCategory)
                    ?? osmMeta?.category
                    ?? item.category?.trimmingCharacters(in: .whitespacesAndNewlines)
                let address = Self.extractAddress(from: mapItem)
                let website = Self.cleanWebsite(mapItem.url?.absoluteString ?? osmMeta?.website)
                let phone = mapItem.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? osmMeta?.phone
                let pinID = "place-\(index + 1)-\( abs((mapItem.name ?? item.name).hashValue) % 100_000 )"

                resolvedPins.append(PlacePin(
                    id: pinID,
                    name: mapItem.name ?? item.name,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    category: category?.isEmpty == false ? category : nil,
                    address: address?.isEmpty == false ? address : nil,
                    phone: phone?.isEmpty == false ? phone : nil,
                    website: website,
                    rating: nil,
                    reviewCount: nil,
                    priceLevel: nil,
                    isOpenNow: osmMeta?.isOpenNow,
                    hoursSummary: osmMeta?.hoursSummary
                ))
            }
        } else if let query = proposal.query, !query.isEmpty {
            let fullQuery = (nearHint != nil && !query.localizedCaseInsensitiveContains(nearHint!))
                ? "\(query) \(nearHint!)" : query
            let items = await searchMapItems(query: fullQuery, region: regionHint, limit: 5)
            for (index, mapItem) in items.enumerated() {
                let coord = Self.coordinate(of: mapItem)
                guard CLLocationCoordinate2DIsValid(coord),
                      !(coord.latitude == 0 && coord.longitude == 0),
                      let name = mapItem.name, !name.isEmpty else {
                    continue
                }
                let osmMeta = await fetchOSMMetadata(name: name, coordinate: coord, now: now)
                let category = Self.friendlyCategory(mapItem.pointOfInterestCategory) ?? osmMeta?.category
                resolvedPins.append(PlacePin(
                    id: "place-\(index + 1)",
                    name: name,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    category: category,
                    address: Self.extractAddress(from: mapItem),
                    phone: mapItem.phoneNumber ?? osmMeta?.phone,
                    website: Self.cleanWebsite(mapItem.url?.absoluteString ?? osmMeta?.website),
                    rating: nil,
                    reviewCount: nil,
                    priceLevel: nil,
                    isOpenNow: osmMeta?.isOpenNow,
                    hoursSummary: osmMeta?.hoursSummary
                ))
            }
        }

        guard !resolvedPins.isEmpty else { return nil }
        return Self.buildCard(
            query: proposal.query ?? proposal.places.first?.name ?? "Places",
            regionName: nearHint,
            places: resolvedPins
        )
    }

    static func buildCard(query: String, regionName: String?, places: [PlacePin]) -> PlaceCard {
        let lats = places.map(\.latitude)
        let lons = places.map(\.longitude)
        let minLat = lats.min() ?? 37.3541
        let maxLat = lats.max() ?? 37.3541
        let minLon = lons.min() ?? -121.9552
        let maxLon = lons.max() ?? -121.9552
        let centerLat = (minLat + maxLat) / 2.0
        let centerLon = (minLon + maxLon) / 2.0
        let latDelta = max((maxLat - minLat) * 1.65, 0.025)
        let lonDelta = max((maxLon - minLon) * 1.65, 0.035)
        return PlaceCard(
            query: query,
            regionName: regionName,
            centerLatitude: centerLat,
            centerLongitude: centerLon,
            latitudeDelta: latDelta,
            longitudeDelta: lonDelta,
            places: places
        )
    }

    @MainActor
    private func resolveSearchRegion(near: String?) async -> MKCoordinateRegion? {
        if let near, !near.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = near
            if let response = try? await MKLocalSearch(request: request).start() {
                return response.boundingRegion
            }
        }
        if let context = Self.locationContextProvider?(),
           let openParen = context.lastIndex(of: "("),
           let closeParen = context.lastIndex(of: ")"), openParen < closeParen {
            let pair = context[context.index(after: openParen)..<closeParen]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if pair.count == 2 {
                return MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]),
                    span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
                )
            }
        }
        return nil
    }

    @MainActor
    private func searchFirstMapItem(query: String, region: MKCoordinateRegion?) async -> MKMapItem? {
        let items = await searchMapItems(query: query, region: region, limit: 1)
        return items.first
    }

    @MainActor
    private func searchMapItems(query: String, region: MKCoordinateRegion?, limit: Int) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        guard let response = try? await MKLocalSearch(request: request).start() else {
            return []
        }
        return Array(response.mapItems.prefix(limit))
    }

    private struct OSMPlaceMetadata {
        var isOpenNow: Bool?
        var hoursSummary: String?
        var category: String?
        var phone: String?
        var website: String?
    }

    private func fetchOSMMetadata(name: String, coordinate: CLLocationCoordinate2D, now: Date) async -> OSMPlaceMetadata? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        let delta = 0.015
        let viewbox = String(
            format: "%.5f,%.5f,%.5f,%.5f",
            coordinate.longitude - delta, coordinate.latitude + delta,
            coordinate.longitude + delta, coordinate.latitude - delta
        )
        components.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "extratags", value: "1"),
            URLQueryItem(name: "viewbox", value: viewbox),
            URLQueryItem(name: "bounded", value: "1"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Cantrip/1.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = try? await osmSession.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            return nil
        }
        let extratags = first["extratags"] as? [String: Any] ?? [:]
        let rawHours = extratags["opening_hours"] as? String
        let isOpenNow = OSMOpeningHours.evaluate(rawHours, at: now)
        let typeLabel = (first["type"] as? String).map {
            $0.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let phone = (extratags["phone"] as? String) ?? (extratags["contact:phone"] as? String)
        let website = (extratags["website"] as? String) ?? (extratags["contact:website"] as? String)
        return OSMPlaceMetadata(
            isOpenNow: isOpenNow,
            hoursSummary: rawHours,
            category: typeLabel,
            phone: phone,
            website: Self.cleanWebsite(website)
        )
    }

    /// MapKit's `location` and `address` are macOS 26+; older Macs read the placemark.
    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(macOS 26.0, *) { return item.location.coordinate }
        return item.placemark.coordinate
    }

    private static func extractAddress(from item: MKMapItem) -> String? {
        if #available(macOS 26.0, *) {
            if let full = item.address?.fullAddress, !full.isEmpty {
                return full.replacingOccurrences(of: "\n", with: ", ")
            }
            if let short = item.address?.shortAddress, !short.isEmpty {
                return short
            }
            return nil
        }
        guard let title = item.placemark.title, !title.isEmpty else { return nil }
        return title
    }

    private static func cleanWebsite(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url.absoluteString
    }

    private static func friendlyCategory(_ category: MKPointOfInterestCategory?) -> String? {
        guard let raw = category?.rawValue else { return nil }
        let stripped = raw.replacingOccurrences(of: "MKPOICategory", with: "")
        guard !stripped.isEmpty else { return nil }
        let spaced = stripped.replacingOccurrences(
            of: #"([a-z])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        return spaced.capitalized
    }
}

// MARK: - OpenStreetMap Tile Proxy & Cache

actor MapTileProxy {
    static let shared = MapTileProxy()

    typealias TileFetcher = @Sendable (Int, Int, Int) async throws -> Data

    /// 1x1 transparent PNG fallback when offline or in isolated tests.
    static let fallbackTilePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    private var memoryTiles: [String: Data] = [:]
    private var customFetcher: TileFetcher?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    init(fetcher: TileFetcher? = nil) {
        self.customFetcher = fetcher
    }

    func setCustomFetcher(_ fetcher: TileFetcher?) {
        self.customFetcher = fetcher
    }

    static func isValidTile(z: Int, x: Int, y: Int) -> Bool {
        guard (0...19).contains(z) else { return false }
        let limit = 1 << z
        return (0..<limit).contains(x) && (0..<limit).contains(y)
    }

    func tile(z: Int, x: Int, y: Int) async throws -> Data {
        guard Self.isValidTile(z: z, x: x, y: y) else {
            throw URLError(.badURL)
        }
        let key = "\(z)/\(x)/\(y)"
        if let cached = memoryTiles[key] { return cached }

        let file = CantripPaths.cache("map-tiles/\(key).png")
        if customFetcher == nil,
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           let disk = try? Data(contentsOf: file), !disk.isEmpty {
            memoryTiles[key] = disk
            return disk
        }

        if let customFetcher {
            let data = try await customFetcher(z, x, y)
            cacheTile(data, key: key, file: file)
            return data
        }

        guard let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Cantrip/1.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty, data.count <= 512 * 1024 else {
            throw URLError(.badServerResponse)
        }
        cacheTile(data, key: key, file: file)
        return data
    }

    private func cacheTile(_ data: Data, key: String, file: URL) {
        if memoryTiles.count >= 128, let firstKey = memoryTiles.keys.first {
            memoryTiles.removeValue(forKey: firstKey)
        }
        memoryTiles[key] = data
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Native macOS SwiftUI Rich Card Views

struct LinkPreviewCardStack: View {
    let cards: [LinkPreviewCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                LinkPreviewCardView(card: card)
            }
        }
    }
}

struct LinkPreviewCardView: View {
    let card: LinkPreviewCard
    @State private var image: NSImage?

    var body: some View {
        Button {
            if let url = URL(string: card.url), LinkPreviewSecurity.isAllowed(url: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    ZStack {
                        Color.white
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 196)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 196)
                    .clipped()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(card.domain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            }
            .frame(maxWidth: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.title), \(card.domain)")
        .accessibilityAddTraits(.isLink)
        .task(id: card.imageID) {
            guard let imageID = card.imageID else {
                image = nil
                return
            }
            if let data = await LinkPreviewStore.shared.imageData(id: imageID),
               let loaded = NSImage(data: data) {
                image = loaded
            }
        }
    }
}

struct PlaceCardView: View {
    let card: PlaceCard
    @State private var position: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedPlaceID: String?

    init(card: PlaceCard) {
        self.card = card
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: card.centerLatitude, longitude: card.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: card.latitudeDelta, longitudeDelta: card.longitudeDelta)
        )
        _currentRegion = State(initialValue: region)
        _position = State(initialValue: .region(region))
        _selectedPlaceID = State(initialValue: card.places.first?.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(position: $position) {
                ForEach(card.places) { place in
                    Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                        Button {
                            selectedPlaceID = place.id
                            openDirections(place)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cross.case.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Color(red: 0.90, green: 0.35, blue: 0.35), in: Circle())
                                Text(place.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 3)
                            .padding(.trailing, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(selectedPlaceID == place.id ? 0.88 : 0.72))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(selectedPlaceID == place.id ? 0.55 : 0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .environment(\.colorScheme, .dark)
            .onMapCameraChange { context in
                currentRegion = context.region
            }

            // Floating place list overlay (top-left, matching the Muse reference card)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.places.enumerated()), id: \.element.id) { index, place in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.1))
                    }
                    PlaceListRowView(
                        place: place,
                        isSelected: selectedPlaceID == place.id,
                        onFocus: { focus(on: place) },
                        onDirections: { openDirections(place) }
                    )
                }
            }
            .frame(width: 248)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(12)

            // Zoom +/- buttons (top-right)
            VStack(spacing: 1) {
                Button { zoom(by: 0.5) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom in")
                Divider().frame(width: 22).overlay(Color.white.opacity(0.16))
                Button { zoom(by: 2.0) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom out")
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)

            // Attribution badge (bottom-right)
            Text("© OpenStreetMap · Apple Maps")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
        }
        .frame(maxWidth: 580)
        .frame(height: 310)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private func focus(on place: PlacePin) {
        selectedPlaceID = place.id
        let next = MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: min(currentRegion.span.latitudeDelta, 0.03),
                longitudeDelta: min(currentRegion.span.longitudeDelta, 0.03)
            )
        )
        currentRegion = next
        position = .region(next)
    }

    private func zoom(by factor: Double) {
        let latDelta = min(max(currentRegion.span.latitudeDelta * factor, 0.002), 60)
        let lonDelta = min(max(currentRegion.span.longitudeDelta * factor, 0.002), 60)
        let next = MKCoordinateRegion(
            center: currentRegion.center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        currentRegion = next
        position = .region(next)
    }

    private func openDirections(_ place: PlacePin) {
        if let url = URL(string: place.appleMapsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PlaceListRowView: View {
    let place: PlacePin
    let isSelected: Bool
    let onFocus: () -> Void
    let onDirections: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onFocus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let rating = place.rating {
                            Text(String(format: "%.1f", rating))
                                .foregroundStyle(.white.opacity(0.85))
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(red: 0.96, green: 0.72, blue: 0.25))
                            if let count = place.reviewCount {
                                Text("(\(count))")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Text("·").foregroundStyle(.white.opacity(0.45))
                        }
                        if let price = place.priceLevel, !price.isEmpty {
                            Text(price).foregroundStyle(.white.opacity(0.7))
                            Text("·").foregroundStyle(.white.opacity(0.45))
                        }
                        if let category = place.category, !category.isEmpty {
                            Text(category)
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    if let isOpen = place.isOpenNow {
                        Text(isOpen ? "Open" : "Closed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                isOpen
                                    ? Color(red: 0.30, green: 0.83, blue: 0.45)
                                    : Color(red: 0.95, green: 0.42, blue: 0.40)
                            )
                    } else if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button(action: onDirections) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(red: 0.48, green: 0.68, blue: 1.0))
                }
                .buttonStyle(.plain)
                if let phone = place.phone,
                   let telURL = URL(string: "tel:" + phone.filter { "0123456789+".contains($0) }) {
                    Button {
                        NSWorkspace.shared.open(telURL)
                    } label: {
                        Label("Call", systemImage: "phone")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                if let website = place.website, let webURL = URL(string: website) {
                    Button {
                        NSWorkspace.shared.open(webURL)
                    } label: {
                        Label("Website", systemImage: "safari")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
    }
}
