import Foundation

/// Shell command lines as Cantrip's policies read them: heredoc bodies split out, simple commands
/// found at separators and substitutions, and each command's words without quoting, variable
/// assignments, redirections or wrappers. Shared by Cantrip Home's guardrails and the agent policy.
enum ShellCommandText {
    /// A command line with its heredoc bodies taken out. `code` keeps a `<<HEREDOC#n` marker
    /// where body n was introduced, so the command reading it can be found. Comments are dropped.
    struct Text: Equatable {
        var code: String
        var heredocs: [String]
    }

    static func splitHeredocs(_ command: String) -> Text {
        let characters = Array(command)
        var code = ""
        var bodies: [String] = []
        var pending: [(delimiter: String, stripsTabs: Bool)] = []
        var quote: Character?
        var escaped = false
        var arithmetic = 0
        // `$(…)` and backticks start fresh quoting, even inside double quotes.
        var substitutions: [(restore: Character?, backtick: Bool)] = []
        var index = 0
        func atWordStart() -> Bool {
            guard let last = code.last else { return true }
            return " \t\n;&|()".contains(last)
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if escaped { code.append(character); escaped = false; index += 1; continue }
            if character == "\\", quote != "'" { code.append(character); escaped = true; index += 1; continue }
            if quote != "'", character == "$", next == "(" {
                let isArithmetic = index + 2 < characters.count && characters[index + 2] == "("
                if isArithmetic { arithmetic += 1 }
                code += isArithmetic ? "$((" : "$("
                index += isArithmetic ? 3 : 2
                substitutions.append((quote, false))
                quote = nil
                continue
            }
            if quote != "'", character == "`" {
                code.append(character)
                index += 1
                if let last = substitutions.last, last.backtick {
                    substitutions.removeLast()
                    quote = last.restore
                } else {
                    substitutions.append((quote, true))
                    quote = nil
                }
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                code.append(character)
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                code.append(character)
                index += 1
                continue
            }
            if character == "#", atWordStart() {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == ")", let last = substitutions.last, !last.backtick {
                if arithmetic > 0, next == ")" {
                    arithmetic -= 1
                    code += "))"
                    index += 2
                } else {
                    code.append(character)
                    index += 1
                }
                substitutions.removeLast()
                quote = last.restore
                continue
            }
            if character == "(", next == "(" {
                arithmetic += 1
            } else if character == ")", arithmetic > 0, next == ")" {
                arithmetic -= 1
            }
            if character == "<", arithmetic == 0, index + 1 < characters.count, characters[index + 1] == "<",
               code.last != "<", !(index + 2 < characters.count && characters[index + 2] == "<") {
                var cursor = index + 2
                var stripsTabs = false
                if cursor < characters.count, characters[cursor] == "-" { stripsTabs = true; cursor += 1 }
                while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 }
                var delimiter = ""
                var delimiterQuote: Character?
                while cursor < characters.count {
                    let next = characters[cursor]
                    if let open = delimiterQuote {
                        if next == open { delimiterQuote = nil } else { delimiter.append(next) }
                    } else if next == "'" || next == "\"" {
                        delimiterQuote = next
                    } else if next == "\\" {
                        // `<<\EOF` quotes the delimiter like `<<'EOF'`.
                    } else if " \t\n;&|<>()".contains(next) {
                        break
                    } else {
                        delimiter.append(next)
                    }
                    cursor += 1
                }
                if !delimiter.isEmpty {
                    code += "<<HEREDOC#\(bodies.count + pending.count)"
                    pending.append((delimiter, stripsTabs))
                    index = cursor
                    continue
                }
            }
            if character == "\n", !pending.isEmpty {
                code.append("\n")
                index += 1
                for heredoc in pending {
                    var lines: [String] = []
                    while index < characters.count {
                        var line = ""
                        while index < characters.count, characters[index] != "\n" { line.append(characters[index]); index += 1 }
                        if index < characters.count { index += 1 }
                        let compared = heredoc.stripsTabs ? String(line.drop { $0 == "\t" }) : line
                        if compared == heredoc.delimiter { break }
                        lines.append(line)
                    }
                    bodies.append(lines.joined(separator: "\n"))
                }
                pending.removeAll()
                continue
            }
            code.append(character)
            index += 1
        }
        // A heredoc with no body before the command ended reads nothing.
        bodies += pending.map { _ in "" }
        return .init(code: code, heredocs: bodies)
    }

    /// Indices of the heredocs a segment reads, from its `<<HEREDOC#n` markers.
    static func heredocMarkers(in segment: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"<<HEREDOC#(\d+)"#)
        return regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)).compactMap { match in
            Range(match.range(at: 1), in: segment).flatMap { Int(segment[$0]) }
        }
    }

    /// One simple command, the separator that ended it (`&&`, `||`, `;`, `|`, `&`, newline,
    /// `(`, `)`, `$(`, a backtick, or empty at the end), and how many subshells deep it runs.
    struct Segment: Equatable {
        var text: String
        var separator: String
        var depth: Int
    }

    /// Splits a command line into simple commands at unquoted separators, pipes, subshells
    /// and command substitutions (also inside double quotes).
    static func scopedSegments(of command: String) -> [Segment] {
        enum Scope { case parenthesis(Character?), backtick(Character?) }
        let characters = Array(command)
        var segments: [Segment] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var scopes: [Scope] = []
        var index = 0
        func flush(_ separator: String) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(.init(text: trimmed, separator: separator, depth: scopes.count)) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { current.append(character); escaped = true; continue }
            if quote == "'" {
                if character == "'" { quote = nil }
                current.append(character)
                continue
            }
            if character == "`" {
                flush("`")
                if case .backtick(let restore)? = scopes.last {
                    scopes.removeLast()
                    quote = restore
                } else {
                    scopes.append(.backtick(quote))
                    quote = nil
                }
                continue
            }
            if character == "$", next == "(" {
                index += 1
                flush("$(")
                scopes.append(.parenthesis(quote))
                quote = nil
                continue
            }
            if quote == "\"" {
                if character == "\"" { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "(":
                flush("(")
                scopes.append(.parenthesis(nil))
            case ")":
                flush(")")
                if case .parenthesis(let restore)? = scopes.last {
                    scopes.removeLast()
                    quote = restore
                }
            case "&", "|":
                if next == character {
                    index += 1
                    flush(String([character, character]))
                } else if character == "|", next == "&" {
                    index += 1
                    flush("|")
                } else if character == "&", next == ">" || current.last == ">" || current.last == "<" {
                    current.append(character)
                } else {
                    flush(String(character))
                }
            case ";", "\n", "\r":
                flush(character == "\r" ? "\n" : String(character))
            default:
                current.append(character)
            }
        }
        flush("")
        return segments
    }

    static func segments(of command: String) -> [String] {
        scopedSegments(of: splitHeredocs(command).code).map(\.text)
    }

    /// Words of one simple command, without quotes, leading variable assignments,
    /// redirections, or wrappers like `env`, `nohup` and `time`.
    static func commandWords(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaped = false
        for character in segment {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                // `$'…'` and `$"…"` are quoting, not a variable.
                if current.hasSuffix("$") { current.removeLast() }
                quote = character
                hasWord = true
                continue
            }
            if character == " " || character == "\t" {
                if hasWord || !current.isEmpty { words.append(current) }
                current = ""
                hasWord = false
                continue
            }
            current.append(character)
        }
        if hasWord || !current.isEmpty { words.append(current) }
        var index = 0
        var cleaned: [String] = []
        while index < words.count {
            let word = words[index]
            if word.range(of: #"^[0-9&]*>{1,2}&?$|^<{1,3}$"#, options: .regularExpression) != nil {
                index += 2
                continue
            }
            if word.range(of: #"^[0-9&]*>{1,2}|^<{1,3}"#, options: .regularExpression) != nil {
                index += 1
                continue
            }
            cleaned.append(word)
            index += 1
        }
        let wrappers: Set<String> = ["env", "nohup", "time", "command", "exec", "builtin", "nice", "caffeinate", "noglob", "xargs"]
        // Shell keywords that start a command inside if/while/for/{ … } blocks.
        let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{"]
        while let first = cleaned.first {
            if keywords.contains(first) {
                cleaned.removeFirst()
                continue
            }
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) != nil
                || wrappers.contains(baseName(first)) {
                cleaned.removeFirst()
                while let flag = cleaned.first, flag.hasPrefix("-") { cleaned.removeFirst() }
                continue
            }
            break
        }
        return cleaned
    }

    static func redirectTargets(_ command: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?<![<>&0-9])(?:[0-9&]?>{1,2}\|?)\s*("[^"]+"|'[^']+'|[^\s;&|<>()]+)"#)
        let range = NSRange(command.startIndex..., in: command)
        return pattern.matches(in: command, range: range).compactMap { match in
            Range(match.range(at: 1), in: command).map { String(command[$0]) }
        }.filter { !$0.hasPrefix("&") }
    }

    static func baseName(_ word: String) -> String {
        (word as NSString).lastPathComponent.lowercased()
    }
}
