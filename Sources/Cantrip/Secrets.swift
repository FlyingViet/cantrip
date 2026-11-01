import CryptoKit
import Foundation

// Cantrip's secrets broker. Bitwarden is the source of truth: one folder, one item per secret.
// The Keychain is the runtime cache (`SecretKeychain`), filled by `SecretSync` whenever the user
// unlocks the vault, so unattended jobs keep working while it's locked. Commands get values
// through `cantrip secret run`; models, clients and logs only ever see names.

/// One named value inside a secret: an environment variable when handed out.
struct SecretField: Codable, Equatable {
    var name: String
    var value: String
    /// A hidden field in Bitwarden, masked wherever Cantrip passes output along. URLs, user names
    /// and IDs are plain.
    var hidden: Bool
}

/// One Bitwarden item from the secrets folder, as cached in the Keychain.
struct SecretItem: Codable, Equatable {
    var name: String
    var fields: [SecretField] = []
    /// A secure note's text: a JSON file, a key, a token. Base64 when `binary`.
    var text: String?
    var binary = false
    var revision: Date?

    var kind: SecretSummary.Kind { binary ? .binary : (text != nil && fields.isEmpty ? .text : .fields) }

    func field(_ name: String) -> SecretField? { fields.first { $0.name == name } }

    /// The bytes a file of this item holds: the decoded binary, or the text as written.
    var fileData: Data? {
        guard let text else { return nil }
        return binary ? Data(base64Encoded: text, options: .ignoreUnknownCharacters) : Data(text.utf8)
    }

    /// A one-value text item as an environment variable: a token or password without its newline.
    var textValue: String? {
        guard !binary, let text else { return nil }
        var value = text
        while value.hasSuffix("\n") || value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    /// Values to keep out of output: hidden fields and the text of text items.
    var maskedValues: [(label: String, value: String)] {
        var values = fields.filter(\.hidden).map { (label: "\(name).\($0.name)", value: $0.value) }
        if let text { values.append((label: name, value: binary ? text : (textValue ?? text))) }
        return values
    }

    var summary: SecretSummary {
        SecretSummary(name: name, kind: kind, fields: fields.map(\.name), revision: revision)
    }
}

/// What clients, Settings and agents may see of a secret: its name and field names.
struct SecretSummary: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case fields, text, binary }
    var id: String { name }
    var name: String
    var kind: Kind
    var fields: [String]
    var revision: Date?
}

/// The names-only state of the cache, shared by the CLI and the app: `~/.cache/Cantrip/secrets/index.json`.
struct SecretIndex: Codable, Equatable {
    var folder = SecretIndex.defaultFolder
    var items: [SecretSummary] = []
    var lastSync: Date?
    var lastAttempt: Date?
    var lastError: String?
    /// Items in the folder that weren't cached, with why (names only).
    var skipped: [String] = []

    static let defaultFolder = "Cantrip Secrets"

    static var file: URL {
        ProcessInfo.processInfo.environment["CANTRIP_SECRETS_INDEX"].map { URL(fileURLWithPath: $0) }
            ?? CantripPaths.cache("secrets/index.json")
    }

    static func load(from url: URL = file) -> SecretIndex? {
        try? PrivateFile.read(SecretIndex.self, from: url, decoder: decoder)
    }

    func save(to url: URL = file) throws {
        try PrivateFile.write(self, to: url, encoder: Self.encoder)
    }

    var remotePayload: [String: Any] {
        var payload: [String: Any] = [
            "folder": folder,
            "items": items.map { item -> [String: Any] in
                var row: [String: Any] = ["name": item.name, "kind": item.kind.rawValue, "fields": item.fields]
                if let revision = item.revision { row["updated"] = ISO8601DateFormatter().string(from: revision) }
                return row
            },
            "skipped": skipped,
        ]
        if let lastSync { payload["lastSync"] = ISO8601DateFormatter().string(from: lastSync) }
        if let lastAttempt { payload["lastAttempt"] = ISO8601DateFormatter().string(from: lastAttempt) }
        if let lastError { payload["lastError"] = lastError }
        return payload
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum SecretNames {
    /// Item names are what commands and agents type: letters, digits, `-` and `_`.
    static func isItemName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }
}

// MARK: - Bitwarden items

enum SecretBitwarden {
    static let encodingField = "cantrip-encoding"

    /// A secure note for `item`, as `bw create item` takes it (before base64).
    static func newItem(_ item: SecretItem, folderID: String) -> [String: Any] {
        var fields: [[String: Any]] = item.fields.map {
            ["name": $0.name, "value": $0.value, "type": $0.hidden ? 1 : 0]
        }
        if item.binary { fields.append(["name": encodingField, "value": "base64", "type": 0]) }
        return [
            "type": 2, "name": item.name, "notes": item.text ?? NSNull(), "folderId": folderID,
            "favorite": false, "secureNote": ["type": 0], "fields": fields, "reprompt": 0,
            "organizationId": NSNull(), "collectionIds": NSNull(), "login": NSNull(), "card": NSNull(),
            "identity": NSNull(),
        ]
    }

    /// What `bw create`/`bw edit` read on stdin: the item's JSON, base64-encoded.
    static func encoded(_ object: [String: Any]) throws -> Data {
        Data(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString().utf8)
    }

    /// An item from `bw list items`, or why it was skipped.
    static func item(from object: [String: Any]) -> Result<SecretItem, SkipReason> {
        let name = object["name"] as? String ?? ""
        guard SecretNames.isItemName(name) else { return .failure(.name(name)) }
        var item = SecretItem(name: name)
        if let revision = object["revisionDate"] as? String { item.revision = ISODate.date(from: revision) }
        if (object["type"] as? Int) == 1, let login = object["login"] as? [String: Any] {
            if let user = login["username"] as? String, !user.isEmpty {
                item.fields.append(SecretField(name: "username", value: user, hidden: false))
            }
            if let password = login["password"] as? String, !password.isEmpty {
                item.fields.append(SecretField(name: "password", value: password, hidden: true))
            }
        }
        var badFields: [String] = []
        for field in object["fields"] as? [[String: Any]] ?? [] {
            let fieldName = field["name"] as? String ?? ""
            let value = field["value"] as? String ?? ""
            if fieldName == encodingField {
                item.binary = value == "base64"
                continue
            }
            guard SecretNames.isVariableName(fieldName) else { badFields.append(fieldName); continue }
            // Linked (3) and boolean (2) fields carry no secret; text (0) is plain, hidden (1) masked.
            let type = field["type"] as? Int ?? 1
            guard type == 0 || type == 1 else { continue }
            item.fields.removeAll { $0.name == fieldName }
            item.fields.append(SecretField(name: fieldName, value: value, hidden: type == 1))
        }
        if let notes = object["notes"] as? String, !notes.isEmpty { item.text = notes }
        if !badFields.isEmpty { return .failure(.fields(name, badFields)) }
        return .success(item)
    }

    enum SkipReason: Error, Equatable, CustomStringConvertible {
        case name(String)
        case fields(String, [String])

        var description: String {
            switch self {
            case .name(let name):
                return "“\(name)”: item names may use only letters, digits, - and _"
            case .fields(let name, let fields):
                return "\(name): field names must be environment variable names (\(fields.joined(separator: ", ")))"
            }
        }
    }
}

// MARK: - Import from files

/// Turns a folder of secret files into Bitwarden items: `.env` files become fields (hidden unless
/// the name says URL, user or ID), anything else a note's text, and binary files base64 text.
enum SecretImport {
    struct Entry: Equatable {
        enum Kind: String { case fields, text, binary }
        var path: String
        var item: String
        var kind: Kind
        /// Variable names and whether each is hidden; empty unless `fields`.
        var fields: [(name: String, hidden: Bool)] = []

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.path == rhs.path && lhs.item == rhs.item && lhs.kind == rhs.kind
                && lhs.fields.map(\.name) == rhs.fields.map(\.name) && lhs.fields.map(\.hidden) == rhs.fields.map(\.hidden)
        }
    }

    /// Certificates, signing requests and provisioning profiles are public: they stay files.
    static let publicExtensions: Set<String> = ["cer", "crt", "csr", "certid", "mobileprovision", "bak"]
    static let ignoredNames: Set<String> = [".DS_Store"]
    static let textExtensions: Set<String> = ["env", "json", "txt"]

    /// `keys/AuthKey.p8` → `keys-AuthKey-p8`; `service.env` → `service`.
    static func itemName(forRelativePath path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        guard var last = components.popLast() else { return path }
        let ext = (last as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { last = (last as NSString).deletingPathExtension }
        components.append(last)
        return components.joined(separator: "-").map { character -> Character in
            let scalar = character.unicodeScalars.first!
            return character.isASCII && (CharacterSet.alphanumerics.contains(scalar) || character == "-" || character == "_")
                ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }

    /// Whether a file in the folder holds a secret worth importing (by name only).
    static func isSecretFile(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        guard !ignoredNames.contains(name) else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if publicExtensions.contains(ext) || relativePath.split(separator: "/").contains("profiles") { return false }
        // `.pem` files here are certificates; private keys use `.key`/`.p8`/`.p12`.
        if ext == "pem" || name.lowercased().hasPrefix("wwdr") { return false }
        return true
    }

    /// Variable names assigned in an env file, in order (names only; values come from the shell).
    static func variableNames(inEnvFile text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("export ") { body = String(body.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = body.firstIndex(of: "=") else { continue }
            let name = String(body[..<equals])
            if SecretNames.isVariableName(name), !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Plain (not hidden) when the name says it's an address, a user name or an identifier, and the
    /// value carries no credential. Webhooks and access URLs embed tokens, so they stay hidden.
    static func isPlain(_ name: String, value: String) -> Bool {
        let upper = name.uppercased()
        if ["WEBHOOK", "ACCESS", "TOKEN", "SECRET", "PASS", "KEY"].contains(where: { upper.contains($0) })
            && !upper.hasSuffix("_KEY_ID") && !upper.hasSuffix("PUBKEY") { return false }
        let plainSuffixes = ["_URL", "_BASE", "_API", "_DATA", "_HOST", "_USER", "_USERNAME", "_LOGIN", "_EMAIL",
                             "_PORT", "_TAILNET", "_LIBRARY_ID", "_USER_ID", "_ENDPOINT_ID", "_ACCOUNT_ID",
                             "_CHAT_ID", "_KEY_ID", "_ISSUER_ID", "_PUBKEY", "_SUPERUSER"]
        guard plainSuffixes.contains(where: { upper.hasSuffix($0) }) || ["URL", "HOST", "USER", "USERNAME"].contains(upper)
        else { return false }
        // user:password@host in a URL is a credential.
        if let url = URLComponents(string: value), url.password != nil || url.user != nil { return false }
        return true
    }

    /// The env file's values as the shell sees them when it sources the file.
    static func shellValues(ofEnvFile url: URL, names: [String]) throws -> [String: String] {
        let result = try ProcessRunner.run(
            "/bin/bash", ["--noprofile", "--norc", "-c", "set -a; . \"$1\" >/dev/null 2>&1; env -0", "cantrip-import", url.path],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: 15)
        guard result.succeeded else { throw ImportError.unreadable(url.lastPathComponent) }
        var values: [String: String] = [:]
        for entry in result.output.split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8), let equals = text.firstIndex(of: "=") else { continue }
            let name = String(text[..<equals])
            if names.contains(name) { values[name] = String(text[text.index(after: equals)...]) }
        }
        return values
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case notUTF8(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) couldn't be read as an env file."
            case .notUTF8(let name): return "\(name) isn't text."
            case .tooLarge(let name): return "\(name) is too large for a Bitwarden note (the limit is about 7 KB of text)."
            }
        }
    }

    /// Bitwarden notes hold 10,000 encrypted characters; base64 and encryption add about a third.
    static let maximumNoteBytes = 7_000

    /// The files under `folder` worth importing, with the item each becomes (reads names only).
    static func plan(folder: URL) throws -> [Entry] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            guard isSecretFile(relative) else { continue }
            let ext = url.pathExtension.lowercased()
            let data = try Data(contentsOf: url)
            var entry = Entry(path: relative, item: itemName(forRelativePath: relative), kind: .text)
            if ext == "env", let text = String(data: data, encoding: .utf8) {
                let names = variableNames(inEnvFile: text)
                if !names.isEmpty {
                    let values = try shellValues(ofEnvFile: url, names: names)
                    entry.kind = .fields
                    entry.fields = names.map { (name: $0, hidden: !isPlain($0, value: values[$0] ?? "")) }
                }
            } else if String(data: data, encoding: .utf8) == nil || ext == "p12" {
                entry.kind = .binary
            }
            entries.append(entry)
        }
        return entries.sorted { $0.item < $1.item }
    }

    /// The item for one planned file, with its values (only ever passed on to Bitwarden or compared).
    static func item(for entry: Entry, folder: URL) throws -> SecretItem {
        let url = folder.appendingPathComponent(entry.path)
        let data = try Data(contentsOf: url)
        var item = SecretItem(name: entry.item)
        switch entry.kind {
        case .fields:
            let values = try shellValues(ofEnvFile: url, names: entry.fields.map(\.name))
            item.fields = entry.fields.map { SecretField(name: $0.name, value: values[$0.name] ?? "", hidden: $0.hidden) }
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8(entry.path) }
            guard data.count <= maximumNoteBytes else { throw ImportError.tooLarge(entry.path) }
            item.text = text
        case .binary:
            guard data.count * 4 / 3 <= maximumNoteBytes else { throw ImportError.tooLarge(entry.path) }
            item.text = data.base64EncodedString()
            item.binary = true
        }
        return item
    }

    /// Whether the cached item holds exactly what the file does, compared by SHA-256.
    static func matches(_ cached: SecretItem, _ fromFile: SecretItem) -> Bool {
        digest(cached) == digest(fromFile)
    }

    static func digest(_ item: SecretItem) -> String {
        var hasher = SHA256()
        for field in item.fields.sorted(by: { $0.name < $1.name }) {
            hasher.update(data: Data("f:\(field.name)=".utf8))
            hasher.update(data: Data(field.value.utf8))
            hasher.update(data: Data([0]))
        }
        if let data = item.fileData { hasher.update(data: Data("t:".utf8)); hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Handing secrets to a command

/// What `cantrip secret run` gives the command: environment variables, and files (a one-read
/// pipe, or a private temporary file) whose paths go in variables.
struct SecretRunPlan: Equatable {
    struct Variable: Equatable {
        var name: String
        var item: String
        /// nil: the whole item (a text item's value).
        var field: String?
    }

    struct File: Equatable {
        enum Format: String { case content, env }
        var variable: String
        var item: String
        var format: Format
    }

    var variables: [Variable] = []
    var files: [File] = []
    var temporaryFiles = false
    var command: [String] = []

    var items: [String] {
        var names: [String] = []
        for name in variables.map(\.item) + files.map(\.item) where !names.contains(name) { names.append(name) }
        return names
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let usage = "Usage: cantrip secret run [--file VAR=NAME] [--env-file VAR=NAME] [--temp-files] NAME|NAME.FIELD|VAR=NAME[.FIELD] ... -- COMMAND [ARGS...]"

    /// Parses everything after `secret run`. Item-wide specs (`NAME`) expand once items are known.
    static func parse(_ arguments: [String]) throws -> SecretRunPlan {
        var plan = SecretRunPlan()
        guard let separator = arguments.firstIndex(of: "--") else { throw Failure(message: usage) }
        plan.command = Array(arguments[(separator + 1)...])
        guard !plan.command.isEmpty else { throw Failure(message: "Give the command to run after --.") }
        var index = 0
        let specs = Array(arguments[..<separator])
        while index < specs.count {
            let argument = specs[index]
            switch argument {
            case "--temp-files":
                plan.temporaryFiles = true
            case "--file", "--env-file":
                index += 1
                guard index < specs.count, let (variable, item, field) = split(specs[index]), let variable, field == nil else {
                    throw Failure(message: "\(argument) needs VAR=NAME.")
                }
                plan.files.append(File(variable: variable, item: item, format: argument == "--file" ? .content : .env))
            default:
                guard !argument.hasPrefix("-"), let (variable, item, field) = split(argument) else {
                    throw Failure(message: "“\(argument)” isn't a secret name. \(usage)")
                }
                plan.variables.append(Variable(name: variable ?? field ?? "", item: item, field: field))
            }
            index += 1
        }
        guard !plan.variables.isEmpty || !plan.files.isEmpty else { throw Failure(message: "Name at least one secret. \(usage)") }
        return plan
    }

    /// `VAR=item.FIELD` → (VAR, item, FIELD); `item` → (nil, item, nil).
    private static func split(_ spec: String) -> (String?, String, String?)? {
        var variable: String?
        var rest = Substring(spec)
        if let equals = rest.firstIndex(of: "=") {
            variable = String(rest[..<equals])
            rest = rest[rest.index(after: equals)...]
            guard SecretNames.isVariableName(variable!) else { return nil }
        }
        let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard SecretNames.isItemName(parts[0]) else { return nil }
        if parts.count == 2 { guard SecretNames.isVariableName(parts[1]) else { return nil } }
        return (variable, parts[0], parts.count == 2 ? parts[1] : nil)
    }

    /// The environment variables to set, given the cached items. Throws when one is missing.
    func environment(items: [String: SecretItem]) throws -> [String: String] {
        var environment: [String: String] = [:]
        for variable in variables {
            guard let item = items[variable.item] else { throw Failure(message: Self.missing(variable.item)) }
            if let fieldName = variable.field {
                guard let field = item.field(fieldName) else {
                    throw Failure(message: "\(item.name) has no field \(fieldName). Its fields: \(item.fields.map(\.name).joined(separator: ", ")).")
                }
                environment[variable.name] = field.value
            } else if !variable.name.isEmpty {
                if let value = item.textValue, item.fields.isEmpty {
                    environment[variable.name] = value
                } else if item.fields.count == 1 {
                    environment[variable.name] = item.fields[0].value
                } else {
                    throw Failure(message: "\(variable.name)=\(item.name): pick one field (\(variable.name)=\(item.name).FIELD) or use --file.")
                }
            } else {
                guard !item.fields.isEmpty else {
                    throw Failure(message: "\(item.name) has no fields. Give it a variable (VAR=\(item.name)) or use --file VAR=\(item.name).")
                }
                for field in item.fields { environment[field.name] = field.value }
            }
        }
        return environment
    }

    static func missing(_ name: String) -> String {
        "No secret named \(name) in the keychain cache. See `cantrip secret list`, or run `cantrip secret sync` after adding it to the \(SecretIndex.defaultFolder) folder in Bitwarden."
    }

    /// A file's bytes: the item's content, or its fields as `KEY=value` lines a shell can source.
    static func fileContents(_ item: SecretItem, format: File.Format) throws -> Data {
        switch format {
        case .content:
            guard let data = item.fileData else {
                throw Failure(message: "\(item.name) has fields, not file content: use --env-file.")
            }
            return data
        case .env:
            return Data(item.fields.map { "\($0.name)=\(shellQuoted($0.value))\n" }.joined().utf8)
        }
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+,-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
