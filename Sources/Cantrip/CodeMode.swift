import Foundation
import JavaScriptCore

/// Code mode: a model writes one short JavaScript program against Cantrip's read-only MCP tools
/// as typed async functions; Cantrip runs it in a JavaScriptCore sandbox and only the program's
/// result goes back to the model. See docs/code-mode.md.
enum CodeMode {
    static let serverName = "cantrip_code"
    static let runTool = "run_tool_script"
    static let apiTool = "tool_api"
    static let settingKey = "codeModeEnabled"

    /// Off by default. Read from defaults so the relay's queue can check it.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// The server backends' configs get while code mode is on (relayed, limited to its two tools).
    static var virtualServer: MCPServer { MCPServer(name: serverName, tools: [runTool, apiTool]) }

    struct Limits {
        var seconds: TimeInterval = 120
        var cpuSeconds: Double = 2
        var memoryMB = 512
        var toolCalls = 40
        var concurrent = 4
        var scriptCharacters = 20_000
        var outputCharacters = 12_000
        var logCharacters = 2_000
        /// Programs one task may run. Past `programNudge` each result reminds the model to finish
        /// (replays: local models kept writing one more search instead of answering).
        var programNudge = 5
        var programsPerTask = 15
    }

    /// Added to a program's result once its task has run more than `programNudge` programs.
    static func budgetNote(program: Int, limits: Limits) -> String {
        guard program > limits.programNudge else { return "" }
        return "\n\n[Program \(program) of at most \(limits.programsPerTask) for this task. If you have what the task needs, "
            + "answer now. Otherwise put every remaining lookup into one program; don't rerun a lookup with reworded queries.]"
    }

    static func budgetRefusal(_ limits: Limits) -> String {
        "This task already ran \(limits.programsPerTask) programs, the limit. Answer now with what you have and say what you couldn't check."
    }

    /// Backends read their MCP configs when they start: rewrite them with or without `cantrip_code`.
    static func settingChanged(_ enabled: Bool) {
        Task { @MainActor in
            guard let snapshot = MCPRegistry.load() else { return }
            do {
                let written = try MCPMigration.sync(snapshot)
                Log.write("code mode: \(enabled ? "on" : "off"); rewrote \(written.joined(separator: ", "))")
            } catch {
                Log.write("code mode: couldn't rewrite the backends' MCP configs: \(error.localizedDescription)")
            }
        }
    }

    /// Servers a program never reaches, whatever else allows them.
    static func isBlocked(server: String) -> Bool { PrivateLocalTools.isBlocked(server: server) }
}

/// One tool a program may call.
struct CodeModeTool {
    let server: String
    let name: String
    let description: String
    let inputSchema: [String: Any]
    var outputSchema: [String: Any]?

    var key: String { "\(server)/\(name)" }
    var serverIdentifier: String { CodeModeAPI.identifier(server) }
    var identifier: String { CodeModeAPI.identifier(name) }

    init(server: String, name: String, description: String, inputSchema: [String: Any], outputSchema: [String: Any]? = nil) {
        self.server = server
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    init(_ tool: PrivateLocalTools.Tool) {
        self.init(server: tool.server, name: tool.name, description: tool.description, inputSchema: tool.schema,
                  outputSchema: tool.outputSchema)
    }
}

/// What a call from a program came to.
enum CodeModeCallOutcome {
    /// The tool's text (JSON when the tool returned JSON) and whether it reported an error.
    case output(String, isError: Bool)
    /// Not run: why (a policy, the Privacy Gate, the relay or code mode's own rules).
    case refused(String)
}

// MARK: - Output shapes

/// A result's structure: key names and value types, never values.
indirect enum CodeModeShape: Equatable {
    case string, number, boolean, null, unknown
    case array(CodeModeShape)
    case object([String: CodeModeShape], optional: Set<String>)
    case record(CodeModeShape)
    case union([CodeModeShape])

    static let maxKeys = 40
    static let maxDepth = 6

    /// A key that is a name in the API, not data (an email address or a person's name is data).
    static func isPlainKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,40}$", options: .regularExpression) != nil
    }

    init(_ value: Any, depth: Int = 0) {
        guard depth <= Self.maxDepth else { self = .unknown; return }
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        case is String: self = .string
        case let array as [Any]:
            self = .array(array.prefix(20).map { CodeModeShape($0, depth: depth + 1) }.reduce(CodeModeShape?.none) { $0?.merged(with: $1) ?? $1 } ?? .unknown)
        case let object as [String: Any]:
            if object.count > Self.maxKeys || !object.keys.allSatisfy(Self.isPlainKey) {
                self = .record(object.values.prefix(20).map { CodeModeShape($0, depth: depth + 1) }
                    .reduce(CodeModeShape?.none) { $0?.merged(with: $1) ?? $1 } ?? .unknown)
            } else {
                self = .object(object.mapValues { CodeModeShape($0, depth: depth + 1) }, optional: [])
            }
        default: self = .unknown
        }
    }

    func merged(with other: CodeModeShape) -> CodeModeShape {
        if self == other { return self }
        switch (self, other) {
        case (.unknown, _): return other
        case (_, .unknown): return self
        case (.array(let a), .array(let b)): return .array(a.merged(with: b))
        case (.record(let a), .record(let b)): return .record(a.merged(with: b))
        case (.object(let a, let oa), .object(let b, let ob)):
            var keys = a
            var optional = oa.union(ob)
            for (key, shape) in b {
                if let existing = keys[key] { keys[key] = existing.merged(with: shape) } else { keys[key] = shape; optional.insert(key) }
            }
            for key in a.keys where b[key] == nil { optional.insert(key) }
            guard keys.count <= Self.maxKeys else {
                return .record(keys.values.reduce(CodeModeShape.unknown) { $0.merged(with: $1) })
            }
            return .object(keys, optional: optional)
        case (.union(let members), _):
            return Self.joined(members + [other])
        case (_, .union(let members)):
            return Self.joined([self] + members)
        default:
            return Self.joined([self, other])
        }
    }

    private static func joined(_ members: [CodeModeShape]) -> CodeModeShape {
        var out: [CodeModeShape] = []
        for member in members.flatMap({ if case .union(let inner) = $0 { return inner } else { return [$0] } }) {
            if let index = out.firstIndex(where: { $0.sameKind(as: member) }) { out[index] = out[index].merged(with: member) }
            else { out.append(member) }
        }
        return out.count == 1 ? out[0] : out.count > 4 ? .unknown : CodeModeShape.union(out)
    }

    private func sameKind(as other: CodeModeShape) -> Bool {
        switch (self, other) {
        case (.array, .array), (.object, .object), (.record, .record): return true
        default: return self == other
        }
    }

    var typescript: String { typescript(depth: .max) }

    /// TypeScript with objects nested more than `depth` levels deep written as `object`.
    func typescript(depth: Int) -> String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        case .unknown: return "unknown"
        case .array(let element):
            let inner = element.typescript(depth: depth)
            return element.isCompound ? "Array<\(inner)>" : "\(inner)[]"
        case .record(let value): return depth <= 0 ? "object" : "Record<string, \(value.typescript(depth: depth - 1))>"
        case .union(let members): return members.map { $0.typescript(depth: depth) }.joined(separator: " | ")
        case .object(let keys, let optional):
            guard !keys.isEmpty else { return "{}" }
            guard depth > 0 else { return "object" }
            return "{ " + keys.keys.sorted().map { "\($0)\(optional.contains($0) ? "?" : ""): \(keys[$0]!.typescript(depth: depth - 1))" }
                .joined(separator: "; ") + " }"
        }
    }

    private var isCompound: Bool { if case .union = self { return true }; return false }

    var json: Any {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .null: return "null"
        case .unknown: return "unknown"
        case .array(let element): return ["array": element.json]
        case .record(let value): return ["record": value.json]
        case .union(let members): return ["union": members.map(\.json)]
        case .object(let keys, let optional):
            return ["object": keys.mapValues(\.json), "optional": optional.sorted()] as [String: Any]
        }
    }

    init?(json: Any) {
        if let name = json as? String {
            switch name {
            case "string": self = .string
            case "number": self = .number
            case "boolean": self = .boolean
            case "null": self = .null
            case "unknown": self = .unknown
            default: return nil
            }
            return
        }
        guard let object = json as? [String: Any] else { return nil }
        if let element = object["array"] { guard let shape = CodeModeShape(json: element) else { return nil }; self = .array(shape) }
        else if let value = object["record"] { guard let shape = CodeModeShape(json: value) else { return nil }; self = .record(shape) }
        else if let members = object["union"] as? [Any] { self = .union(members.compactMap { CodeModeShape(json: $0) }) }
        else if let keys = object["object"] as? [String: Any] {
            var shapes: [String: CodeModeShape] = [:]
            for (key, value) in keys where Self.isPlainKey(key) { shapes[key] = CodeModeShape(json: value) ?? .unknown }
            self = .object(shapes, optional: Set(object["optional"] as? [String] ?? []))
        } else { return nil }
    }
}

/// Result shapes seen per tool, kept across launches (key names and types only).
final class CodeModeShapes: @unchecked Sendable {
    static let shared = CodeModeShapes()

    let file: URL
    private let lock = NSLock()
    private var shapes: [String: CodeModeShape]?

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cantrip/code-mode/shapes.json")) {
        self.file = file
    }

    private func loaded() -> [String: CodeModeShape] {
        if let shapes { return shapes }
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        let read = object.compactMapValues { CodeModeShape(json: $0) }
        shapes = read
        return read
    }

    func shape(for key: String) -> CodeModeShape? { lock.withLock { loaded()[key] } }

    /// Merges one result's shape. Text that isn't JSON teaches nothing.
    func observe(_ key: String, text: String) {
        guard let first = text.first, first == "{" || first == "[",
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return }
        var seen = CodeModeShape(value)
        if case .object(var keys, let optional) = seen {
            // Servers' warnings about untrusted content repeat on every result; they aren't data the program needs.
            keys["note"] = nil
            seen = .object(keys, optional: optional.subtracting(["note"]))
        }
        let snapshot: [String: CodeModeShape]? = lock.withLock {
            var all = loaded()
            let merged = all[key].map { $0.merged(with: seen) } ?? seen
            guard merged != all[key] else { return nil }
            all[key] = merged
            shapes = all
            return all
        }
        guard let snapshot else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: snapshot.mapValues(\.json), options: [.sortedKeys]) {
            try? PrivateFile.write(data, to: file)
        }
    }
}

// MARK: - Typed API

enum CodeModeAPI {
    private static let reserved: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum",
        "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null",
        "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield",
        "let", "static", "implements", "interface", "package", "private", "protected", "public", "await", "async",
        "args", "log", "recipes", "globalThis", "Object", "Array", "JSON", "Promise", "Math", "Date", "String", "Number",
    ]

    /// A JavaScript identifier for a server or tool name (`search-flight` -> `search_flight`).
    static func identifier(_ name: String) -> String {
        var out = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if out.isEmpty || out.first!.isNumber { out = "_" + out }
        return reserved.contains(out) ? out + "_" : out
    }

    /// A JSON Schema as a TypeScript type (enough of it for tool arguments and results).
    static func typescript(_ schema: Any?, depth: Int = 0) -> String {
        guard depth < 6, let schema = schema as? [String: Any] else { return "unknown" }
        if let values = schema["enum"] as? [Any], !values.isEmpty {
            return values.prefix(20).map { value -> String in
                if let text = value as? String { return literal(text) }
                return "\(value)"
            }.joined(separator: " | ")
        }
        for key in ["anyOf", "oneOf"] {
            if let options = schema[key] as? [Any], !options.isEmpty {
                return Array(Set(options.map { typescript($0, depth: depth + 1) })).sorted().joined(separator: " | ")
            }
        }
        let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map { [$0] } ?? []
        if types.count > 1 {
            var one = schema
            return types.map { type -> String in one["type"] = type; return typescript(one, depth: depth + 1) }.joined(separator: " | ")
        }
        switch types.first {
        case "string": return "string"
        case "integer", "number": return "number"
        case "boolean": return "boolean"
        case "null": return "null"
        case "array":
            let element = typescript(schema["items"], depth: depth + 1)
            return element.contains(" | ") ? "Array<\(element)>" : "\(element)[]"
        case "object", nil:
            guard let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
                if let additional = schema["additionalProperties"] as? [String: Any] {
                    return "Record<string, \(typescript(additional, depth: depth + 1))>"
                }
                return types.first == nil && schema.isEmpty ? "unknown" : "Record<string, unknown>"
            }
            let required = Set(schema["required"] as? [String] ?? [])
            return "{ " + properties.keys.sorted().map { key -> String in
                let name = CodeModeShape.isPlainKey(key) ? key : literal(key)
                return "\(name)\(required.contains(key) ? "" : "?"): \(typescript(properties[key], depth: depth + 1))"
            }.joined(separator: "; ") + " }"
        default:
            return "unknown"
        }
    }

    private static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func comment(_ text: String, limit: Int = 220) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "*/", with: "* /").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// The result type: the declared output schema, else the shape seen so far, else unknown.
    /// Longest result type shown in full: a tool that returns a whole report would otherwise push every
    /// other tool out of the description.
    static let outputTypeCharacters = 1_500

    static func outputType(_ tool: CodeModeTool, shapes: CodeModeShapes) -> String {
        if let schema = tool.outputSchema { return typescript(schema) }
        guard let shape = shapes.shape(for: tool.key) else { return "unknown" }
        let full = shape.typescript
        guard full.count > outputTypeCharacters else { return full }
        for depth in [4, 3, 2] {
            let outer = shape.typescript(depth: depth)
            if outer.count <= outputTypeCharacters { return outer }
        }
        return shape.typescript(depth: 1)
    }

    /// Declarations for the given tools and recipes, grouped by server.
    static func declarations(_ tools: [CodeModeTool], recipes: [CodeModeRecipe], shapes: CodeModeShapes) -> String {
        var lines: [String] = []
        for server in Array(Set(tools.map(\.server))).sorted() {
            let ident = identifier(server)
            lines.append("declare const \(ident): {\(ident == server ? "" : " // \(server)")")
            for tool in tools.filter({ $0.server == server }).sorted(by: { $0.name < $1.name }) {
                if !tool.description.isEmpty { lines.append("  /** \(comment(tool.description)) */") }
                let input = typescript(tool.inputSchema)
                let arguments = input == "unknown" || input == "Record<string, unknown>" ? "args?: Record<string, unknown>" : "args: \(input)"
                lines.append("  \(tool.identifier)(\(arguments)): Promise<\(outputType(tool, shapes: shapes))>;\(tool.identifier == tool.name ? "" : " // \(tool.name)")")
            }
            lines.append("};")
        }
        if !recipes.isEmpty {
            lines.append("declare const recipes: {")
            for recipe in recipes.sorted(by: { $0.name < $1.name }) {
                lines.append("  /** \(comment(recipe.description)) */")
                lines.append("  \(identifier(recipe.name))(args: \(recipe.params)): Promise<\(recipe.returns)>;")
            }
            lines.append("};")
        }
        return lines.joined(separator: "\n")
    }

    /// `run_tool_script`'s description: how to write a program, then the API when it fits.
    static func runDescription(_ tools: [CodeModeTool], recipes: [CodeModeRecipe], shapes: CodeModeShapes,
                               limits: CodeMode.Limits, inlineLimit: Int = 14_000) -> String {
        let declarations = declarations(tools, recipes: recipes, shapes: shapes)
        let servers = Array(Set(tools.map(\.server))).sorted()
        var text = """
        Run one JavaScript program that chains read-only tool calls on the Mac; only its return value comes back. \
        Use it instead of calling tools one by one when a result feeds the next call (search, then read each match). \
        Plan the whole lookup first and put it in ONE program: independent calls in Promise.all, every search wording \
        in the same program (or one call when a tool takes a list), then return only what the task needs. Run another \
        program only for what the results point to (reading specific ids), never to retry a lookup reworded; a tool \
        that sweeps or summarizes in one call beats many small searches. A task may run \(limits.programsPerTask) programs. \
        Write the body of an async function: each server is a global object whose tools are async functions taking \
        the tool's arguments and returning its parsed JSON result (or text). Use Promise.all for independent calls, \
        try/catch for calls that may fail, `args` for the call's args, `log(...)` for notes, and `return` only the \
        fields you need. Recipes (`recipes.NAME(args)`) are saved chains. No files, network or timers. Limits: \
        \(limits.toolCalls) tool calls, \(Int(limits.seconds)) s, \(limits.outputCharacters) characters of result. \
        Only read-only tools exist here; anything else throws.
        """
        if declarations.count <= inlineLimit {
            text += "\n\nAPI:\n" + declarations
        } else {
            text += "\n\nServers: \(servers.joined(separator: ", ")). Call \(CodeMode.apiTool) with the servers you need for their declarations."
            if !recipes.isEmpty { text += " Recipes: \(recipes.map(\.name).sorted().joined(separator: ", "))." }
        }
        return text
    }

    static let runInputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script": ["type": "string", "description": "Body of an async JavaScript function using the API; `return` the result."],
            "args": ["type": "object", "description": "Optional values the program reads as `args`."],
        ] as [String: Any],
        "required": ["script"],
    ]

    static let apiInputSchema: [String: Any] = [
        "type": "object",
        "properties": ["servers": ["type": "array", "items": ["type": "string"],
                                   "description": "Server names; empty for all."]] as [String: Any],
    ]
}

// MARK: - Recipes

/// A saved program for a chain that recurs. Offered only when every tool it lists is allowed.
struct CodeModeRecipe {
    let name: String
    let description: String
    /// TypeScript type of `args`.
    let params: String
    /// TypeScript type of the result.
    let returns: String
    /// `server.tool` for every tool it calls.
    let tools: [String]
    let script: String

    init(name: String, description: String, params: String, returns: String, tools: [String], script: String) {
        self.name = name
        self.description = description
        self.params = params
        self.returns = returns
        self.tools = tools
        self.script = script
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, CodeModeShape.isPlainKey(name),
              let script = json["script"] as? String, !script.isEmpty else { return nil }
        self.init(name: name, description: json["description"] as? String ?? "",
                  params: json["params"] as? String ?? "Record<string, unknown>",
                  returns: json["returns"] as? String ?? "unknown",
                  tools: json["tools"] as? [String] ?? [], script: script)
    }

    func available(with tools: [CodeModeTool]) -> Bool {
        let allowed = Set(tools.map { "\($0.server).\($0.name)" })
        return self.tools.allSatisfy(allowed.contains)
    }
}

enum CodeModeRecipes {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cantrip/code-mode/recipes")
    }

    /// Chains the Home trackers repeat on every run.
    static let builtIn: [CodeModeRecipe] = [
        CodeModeRecipe(
            name: "mail_digest",
            description: "Search Mail, then read each match: one call instead of a search plus one read per message. Takes mail_search's filters; bodies are cut to bodyChars.",
            params: "{ query?: string; sender?: string; folder?: string; since?: string; until?: string; unread_only?: boolean; limit?: number; bodyChars?: number }",
            returns: "{ count: number; messages: Array<{ id: number; date: string; from: string; to: unknown; subject: string; labels: unknown; attachments: unknown; body: string }> }",
            tools: ["personal.mail_search", "personal.mail_read"],
            script: """
            const { bodyChars = 1500, limit = 10, ...filters } = args || {};
            const found = await personal.mail_search({ ...filters, limit: Math.min(Math.max(limit, 1), 25) });
            const list = (found && found.messages) || [];
            const read = await Promise.all(list.map(async m => {
              try {
                const full = await personal.mail_read({ message_id: m.id, max_chars: Math.min(Math.max(bodyChars, 200), 8000) });
                return { id: m.id, date: full.date, from: full.from, to: full.to, subject: full.subject, labels: full.labels,
                         attachments: full.attachments, body: full.body };
              } catch (e) {
                return { id: m.id, date: m.date, from: m.from, subject: m.subject, labels: m.labels, attachments: m.attachments,
                         body: m.preview, error: String(e.message || e) };
              }
            }));
            return { count: read.length, messages: read };
            """),
        CodeModeRecipe(
            name: "message_threads",
            description: "List recent Messages chats, then read each one's latest messages: one call instead of one read per chat.",
            params: "{ since?: string; chats?: number; perChat?: number; unread_only?: boolean }",
            returns: "{ count: number; chats: Array<{ chat_id: number; name: unknown; last_at: string; messages: Array<{ at: string; from: string; text: string }> }> }",
            tools: ["personal.messages_chats", "personal.messages_read"],
            script: """
            const { since, chats = 8, perChat = 20, unread_only = false } = args || {};
            const listed = await personal.messages_chats({ ...(since ? { since } : {}), unread_only, limit: Math.min(Math.max(chats, 1), 25) });
            const all = (listed && listed.chats) || [];
            const threads = await Promise.all(all.map(async c => {
              try {
                const read = await personal.messages_read({ chat_id: c.chat_id, ...(since ? { since } : {}), limit: Math.min(Math.max(perChat, 1), 100) });
                return { chat_id: c.chat_id, name: c.name || c.participants, last_at: c.last_at,
                         messages: ((read && read.messages) || []).map(m => ({ at: m.at, from: m.from, text: m.text })) };
              } catch (e) {
                return { chat_id: c.chat_id, name: c.name || c.participants, last_at: c.last_at, messages: [], error: String(e.message || e) };
              }
            }));
            return { count: threads.length, chats: threads };
            """),
        CodeModeRecipe(
            name: "contact_activity",
            description: "Everything recent with one person: their contact card, mail from them and your Messages with them, in one call.",
            params: "{ name: string; since?: string; mail?: number; messages?: number }",
            returns: "{ contacts: unknown; mail: unknown; messages: unknown }",
            tools: ["personal.contacts_lookup", "personal.mail_search", "personal.messages_read"],
            script: """
            const { name, since, mail = 10, messages = 30 } = args || {};
            if (!name) throw new Error("contact_activity needs args.name");
            const [contacts, mails, texts] = await Promise.all([
              personal.contacts_lookup({ query: name, limit: 3 }).catch(e => ({ error: String(e.message || e) })),
              personal.mail_search({ sender: name, folder: "all", ...(since ? { since } : {}), limit: Math.min(Math.max(mail, 1), 50) }).catch(e => ({ error: String(e.message || e) })),
              personal.messages_read({ contact: name, ...(since ? { since } : {}), limit: Math.min(Math.max(messages, 1), 100) }).catch(e => ({ error: String(e.message || e) })),
            ]);
            return { contacts: contacts.contacts || contacts, mail: mails.messages || mails, messages: texts.messages || texts };
            """),
    ]

    /// Built-in recipes, then files in the folder (a file wins over a built-in of the same name).
    static func all(folder: URL = folder) -> [CodeModeRecipe] {
        var byName = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.name, $0) })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any],
                  let recipe = CodeModeRecipe(json: object) else { continue }
            byName[recipe.name] = recipe
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}

// MARK: - Sandbox

/// Runs one program in a fresh JavaScriptCore context that holds only the tool functions.
final class CodeModeRunner: @unchecked Sendable {
    struct Result {
        var value: String?
        var error: String?
        var toolCalls = 0
        var refused = 0
        var calls: [String: Int] = [:]
        var log: [String] = []
        var seconds: Double = 0

        /// What the model gets back.
        var reply: String {
            var parts: [String] = []
            if let value { parts.append(value) }
            if let error { parts.append("Error: \(error)") }
            if !log.isEmpty { parts.append("Log:\n" + log.joined(separator: "\n")) }
            parts.append("(\(toolCalls) tool call\(toolCalls == 1 ? "" : "s")\(refused > 0 ? ", \(refused) refused" : ""), \(String(format: "%.1f", seconds)) s)")
            return parts.joined(separator: "\n\n")
        }
    }

    typealias Perform = (CodeModeTool, [String: Any]) async -> CodeModeCallOutcome

    let tools: [CodeModeTool]
    let recipes: [CodeModeRecipe]
    let limits: CodeMode.Limits
    let shapes: CodeModeShapes?
    private let perform: Perform
    private let queue = DispatchQueue(label: "cantrip.code-mode")
    private var context: JSContext?
    private var byKey: [String: CodeModeTool] = [:]
    private var result = Result()
    private var running: [Task<Void, Never>] = []
    private var waiting: [() -> Void] = []
    private var inFlight = 0
    private var finished = false
    private var continuation: CheckedContinuation<Result, Never>?
    private var started = Date()
    private var logCharacters = 0
    fileprivate var watchdog = Watchdog()

    init(tools: [CodeModeTool], recipes: [CodeModeRecipe] = [], limits: CodeMode.Limits = .init(),
         shapes: CodeModeShapes? = .shared, perform: @escaping Perform) {
        self.tools = tools
        self.recipes = recipes.filter { $0.available(with: tools) }
        self.limits = limits
        self.shapes = shapes
        self.perform = perform
        for tool in tools { byKey[tool.key] = tool }
    }

    func run(_ script: String, arguments: [String: Any] = [:]) async -> Result {
        guard script.count <= limits.scriptCharacters else {
            return Result(error: "The program is \(script.count) characters; the limit is \(limits.scriptCharacters). Use a recipe or a shorter program.")
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.started = Date()
                self.start(script, arguments: arguments)
            }
            queue.asyncAfter(deadline: .now() + limits.seconds) {
                self.finish(error: "Stopped after \(Int(self.limits.seconds)) s. Ask for less, or split the work.")
            }
        }
    }

    // Everything below runs on `queue`.

    private func start(_ script: String, arguments: [String: Any]) {
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            return finish(error: "The sandbox couldn't start.")
        }
        self.context = context
        watchdog.install(on: context, cpuSeconds: limits.cpuSeconds, memoryMB: limits.memoryMB)
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            let message = exception?.toString() ?? "unknown error"
            let reason = self.watchdog.reason ?? message
            self.finish(error: reason)
        }
        // Nothing but the language: no timers, no WebAssembly, no shared memory.
        context.evaluateScript("""
        for (const name of ["setTimeout","setInterval","clearTimeout","clearInterval","queueMicrotask","WebAssembly",
                            "Atomics","SharedArrayBuffer","FinalizationRegistry","WeakRef","console","print","quit","read","load"]) {
          try { delete globalThis[name]; } catch (e) {}
          try { Object.defineProperty(globalThis, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
        }
        """)
        let call: @convention(block) (String, String, String, JSValue, JSValue) -> Void = { [weak self] server, tool, json, resolve, reject in
            self?.call(server: server, tool: tool, json: json, resolve: resolve, reject: reject)
        }
        let log: @convention(block) (String) -> Void = { [weak self] line in self?.log(line) }
        let done: @convention(block) (String) -> Void = { [weak self] json in self?.finish(value: json) }
        let fail: @convention(block) (String) -> Void = { [weak self] message in self?.finish(error: message) }
        context.setObject(call, forKeyedSubscript: "__call" as NSString)
        context.setObject(log, forKeyedSubscript: "__log" as NSString)
        context.setObject(done, forKeyedSubscript: "__done" as NSString)
        context.setObject(fail, forKeyedSubscript: "__fail" as NSString)
        let argsJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8), as: UTF8.self)
        context.evaluateScript(prelude() + """

        (async (args) => {
        \(script)
        })(Object.freeze(\(argsJSON))).then(value => {
          let text;
          try { text = JSON.stringify(value === undefined ? null : value); } catch (e) { text = JSON.stringify(String(value)); }
          __done(text === undefined ? "null" : text);
        }, error => __fail(error && error.message ? (error.name && error.name !== "Error" ? error.name + ": " : "") + error.message : String(error)));
        """)
    }

    private func prelude() -> String {
        var lines = ["""
        "use strict";
        const __tool = (server, tool) => (a) => new Promise((resolve, reject) =>
          __call(server, tool, JSON.stringify(a === undefined ? {} : a), resolve, message => reject(new Error(message))));
        globalThis.log = (...parts) => __log(parts.map(p => typeof p === "string" ? p : (() => { try { return JSON.stringify(p); } catch (e) { return String(p); } })()).join(" "));
        """]
        for server in Array(Set(tools.map(\.server))).sorted() {
            let entries = tools.filter { $0.server == server }
                .map { "\(CodeModeAPI.identifier($0.name)): __tool(\(Self.js($0.server)), \(Self.js($0.name)))" }
            lines.append("globalThis[\(Self.js(CodeModeAPI.identifier(server)))] = Object.freeze({ \(entries.joined(separator: ", ")) });")
        }
        let recipeEntries = recipes.map { recipe in
            "\(CodeModeAPI.identifier(recipe.name)): async (args) => {\n\(recipe.script)\n}"
        }
        lines.append("globalThis.recipes = Object.freeze({ \(recipeEntries.joined(separator: ",\n")) });")
        return lines.joined(separator: "\n")
    }

    private static func js(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func log(_ line: String) {
        guard logCharacters < limits.logCharacters else { return }
        let kept = String(line.prefix(limits.logCharacters - logCharacters))
        logCharacters += kept.count
        result.log.append(kept)
    }

    private func call(server: String, tool: String, json: String, resolve: JSValue, reject: JSValue) {
        guard !finished else { return }
        let key = "\(server)/\(tool)"
        guard let target = byKey[key] else {
            result.refused += 1
            reject.call(withArguments: ["\(server).\(tool) isn't available here: code mode only has the read-only tools in its API."])
            return
        }
        guard result.toolCalls < limits.toolCalls else {
            result.refused += 1
            reject.call(withArguments: ["The limit of \(limits.toolCalls) tool calls per program was reached."])
            return
        }
        result.toolCalls += 1
        result.calls[key, default: 0] += 1
        let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let begin = { [weak self] in
            guard let self else { return }
            self.inFlight += 1
            let perform = self.perform
            let task = Task { [weak self] in
                let outcome = await perform(target, arguments)
                self?.queue.async { self?.deliver(outcome, key: key, resolve: resolve, reject: reject) }
            }
            self.running.append(task)
        }
        if inFlight < limits.concurrent { begin() } else { waiting.append(begin) }
    }

    private func deliver(_ outcome: CodeModeCallOutcome, key: String, resolve: JSValue, reject: JSValue) {
        inFlight -= 1
        if !waiting.isEmpty { waiting.removeFirst()() }
        guard !finished, let context else { return }
        switch outcome {
        case .refused(let reason):
            result.refused += 1
            reject.call(withArguments: [reason])
        case .output(let text, let isError):
            if isError {
                reject.call(withArguments: ["\(key.replacingOccurrences(of: "/", with: ".")) failed: \(text.prefix(800))"])
                return
            }
            shapes?.observe(key, text: text)
            // Parsed here: invalid JSON in JavaScript would reach the context's exception handler.
            if text.first == "{" || text.first == "[",
               let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
               let value = JSValue(object: object, in: context) {
                resolve.call(withArguments: [value])
            } else {
                resolve.call(withArguments: [text])
            }
        }
    }

    private func finish(value: String? = nil, error: String? = nil) {
        guard !finished else { return }
        finished = true
        if let value {
            var text = value
            if text.count > limits.outputCharacters {
                text = String(text.prefix(limits.outputCharacters))
                    + "\n[\(value.count - limits.outputCharacters) more characters left out: return only the fields you need.]"
            }
            result.value = text
        }
        result.error = error
        result.seconds = Date().timeIntervalSince(started)
        running.forEach { $0.cancel() }
        running = []
        waiting = []
        watchdog.stop()
        context?.exceptionHandler = nil
        context = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Stops a program that computes too long or grows memory too much (JavaScriptCore's watchdog).
/// The watchdog fires once per arming, so each check that lets the program go on re-arms it.
fileprivate struct Watchdog {
    final class State {
        var slices = 0
        var maxSlices = 10
        var baseline: UInt64 = 0
        var memoryLimit: UInt64 = 0
        var reason: String?
        var group: JSContextGroupRef?
    }

    typealias Callback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    typealias SetLimit = @convention(c) (JSContextGroupRef, Double, Callback?, UnsafeMutableRawPointer?) -> Void
    typealias ClearLimit = @convention(c) (JSContextGroupRef) -> Void
    static let slice = 0.5
    nonisolated(unsafe) static let functions: (set: SetLimit, clear: ClearLimit)? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
              let set = dlsym(handle, "JSContextGroupSetExecutionTimeLimit"),
              let clear = dlsym(handle, "JSContextGroupClearExecutionTimeLimit") else { return nil }
        return (unsafeBitCast(set, to: SetLimit.self), unsafeBitCast(clear, to: ClearLimit.self))
    }()

    private var state: Unmanaged<State>?
    var reason: String? { state?.takeUnretainedValue().reason }

    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    mutating func install(on context: JSContext, cpuSeconds: Double, memoryMB: Int) {
        guard let functions = Self.functions, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        let state = State()
        state.maxSlices = max(1, Int((cpuSeconds / Self.slice).rounded(.up)))
        state.baseline = Self.footprint
        state.memoryLimit = UInt64(memoryMB) * 1_048_576
        state.group = group
        let retained = Unmanaged.passRetained(state)
        self.state = retained
        functions.set(group, Self.slice, codeModeWatchdogFired, retained.toOpaque())
    }

    mutating func stop() {
        if let state {
            if let group = state.takeUnretainedValue().group, let functions = Self.functions { functions.clear(group) }
            state.takeUnretainedValue().group = nil
            state.release()
        }
        state = nil
    }
}

/// The watchdog's check after each slice of uninterrupted compute: stop, or re-arm and go on.
private func codeModeWatchdogFired(_ context: JSContextRef?, _ info: UnsafeMutableRawPointer?) -> Bool {
    guard let info else { return true }
    let state = Unmanaged<Watchdog.State>.fromOpaque(info).takeUnretainedValue()
    state.slices += 1
    if state.slices >= state.maxSlices {
        state.reason = "Stopped: the program computed for more than \(Double(state.maxSlices) * Watchdog.slice) s without waiting on a tool."
        return true
    }
    let now = Watchdog.footprint
    if now > state.baseline, now - state.baseline > state.memoryLimit {
        state.reason = "Stopped: the program used more than \(state.memoryLimit / 1_048_576) MB of memory."
        return true
    }
    guard let group = state.group, let functions = Watchdog.functions else { return true }
    functions.set(group, Watchdog.slice, codeModeWatchdogFired, info)
    return false
}
