import Foundation

/// Finds text that looks like a credential, so a skill or a rule file never carries one to every
/// backend. Findings name the file, line and kind only: never the value.
enum SecretScan {
    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let kind: String
        var description: String { "\(file):\(line): \(kind)" }
    }

    private static let tokenPatterns: [(kind: String, regex: NSRegularExpression)] = [
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("API key", #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}\b"#),
        ("Stripe key", #"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        ("AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("GitLab token", #"\bglpat-[A-Za-z0-9_-]{20,}\b"#),
        ("JSON web token", #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        ("password in a URL", #"[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s/@$]{3,}@"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// `NAME=value`, `name: value`, `"name": "value"` and `--name value` where the name says it's a secret.
    private static let assignment = try! NSRegularExpression(pattern:
        #"(?i)\b([A-Z0-9_.-]*(?:api[_-]?key|apikey|token|secret|passw(?:or)?d|passwd|pwd|auth[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|bearer))["']?\s*(?:[:=]|\s)\s*["']?([^\s"'`,;)]+)"#)
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(?:bearer|token)\s+([A-Za-z0-9._~+/=-]{20,})"#)

    /// Placeholders and references that aren't values: `$VAR`, `${VAR}`, `<token>`, `xxxx`, `...`.
    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if value.count < 12 { return true }
        if value.contains("$") || value.contains("{") || value.contains("<") || value.contains("%") || value.contains("(") { return true }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("./") || lower.hasPrefix("http") { return true }
        let words = ["your", "example", "changeme", "placeholder", "redacted", "dummy", "xxxx", "****", "....", "replace",
                     "secret-", "token-", "env", "keychain", "bitwarden", "cantrip"]
        if words.contains(where: lower.contains) { return true }
        if Set(value).count < 6 { return true }
        // Words joined by dashes or underscores (a name, not a credential).
        let separated = value.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
        if separated.count > 1, separated.allSatisfy({ $0.allSatisfy { $0.isLetter } }) { return true }
        // A credential mixes character classes; a plain word or identifier doesn't.
        let classes = [value.contains(where: \.isLowercase), value.contains(where: \.isUppercase),
                       value.contains(where: \.isNumber)].filter { $0 }.count
        return classes < 2
    }

    static func scan(text: String, file: String) -> [Finding] {
        var findings: [Finding] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            var kinds: [String] = []
            for (kind, regex) in tokenPatterns where regex.firstMatch(in: line, range: range) != nil {
                kinds.append(kind)
            }
            if kinds.isEmpty {
                for match in assignment.matches(in: line, range: range) {
                    guard let valueRange = Range(match.range(at: 2), in: line) else { continue }
                    if !isPlaceholder(String(line[valueRange])) { kinds.append("value assigned to a credential name"); break }
                }
            }
            if kinds.isEmpty, let match = bearer.firstMatch(in: line, range: range),
               let valueRange = Range(match.range(at: 1), in: line), !isPlaceholder(String(line[valueRange])) {
                kinds.append("bearer token")
            }
            for kind in kinds { findings.append(Finding(file: file, line: index + 1, kind: kind)) }
        }
        return findings
    }

    /// Every text file under `folder` (links followed only inside it). Files over 2 MB or with NUL
    /// bytes are skipped; a link that leaves the folder is reported, not read.
    static func scan(folder: URL, relativeTo base: URL? = nil) -> [Finding] {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let label = base ?? folder.deletingLastPathComponent()
        var findings: [Finding] = []
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                             options: []) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == ".git" || name == ".DS_Store" { enumerator.skipDescendants(); continue }
            let relative = relativePath(url, to: label)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().standardizedFileURL
                if !target.path.hasPrefix(root.path + "/") {
                    findings.append(Finding(file: relative, line: 0, kind: "link to a file outside the skill"))
                    continue
                }
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.size] as? NSNumber)?.intValue,
                  size <= 2_000_000, let data = try? Data(contentsOf: url), !data.contains(0) else { continue }
            findings += scan(text: String(decoding: data, as: UTF8.self), file: relative)
        }
        return findings
    }

    static func relativePath(_ url: URL, to base: URL) -> String {
        let path = url.standardizedFileURL.path, prefix = base.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
