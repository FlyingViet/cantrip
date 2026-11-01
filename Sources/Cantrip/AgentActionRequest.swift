import Foundation

/// One tool call, normalized from whichever backend asked to run it.
struct CantripHomeActionRequest: Equatable {
    enum Kind: String { case shell, write, read, url, mcp, other }
    var kind: Kind
    var command = ""
    var cwd: String?
    var paths: [String] = []
    var url: String?
    var server: String?
    var tool: String?
    var readOnly = false
    var writesFiles = false
    /// Text typed into a task that's already running, so Cantrip can't tell which program reads it.
    var taskInput = false

    static func shell(_ command: String) -> Self { .init(kind: .shell, command: command) }
    static func write(_ path: String) -> Self { .init(kind: .write, paths: [path]) }

    /// The bridge's summary of a Copilot SDK permission request.
    init?(copilotJSON text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let raw = object["kind"] as? String else { return nil }
        let kind = Kind(rawValue: raw) ?? .other
        self.init(kind: kind)
        command = object["fullCommandText"] as? String ?? ""
        paths = (object["possiblePaths"] as? [String] ?? [])
            + [object["fileName"] as? String, object["path"] as? String].compactMap { $0 }
        url = object["url"] as? String
        server = object["serverName"] as? String
        tool = object["toolName"] as? String
        readOnly = object["readOnly"] as? Bool ?? false
        writesFiles = object["hasWriteFileRedirection"] as? Bool ?? false
    }

    init(kind: Kind, command: String = "", cwd: String? = nil, paths: [String] = [],
         url: String? = nil, server: String? = nil, tool: String? = nil,
         readOnly: Bool = false, writesFiles: Bool = false) {
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.paths = paths
        self.url = url
        self.server = server
        self.tool = tool
        self.readOnly = readOnly
        self.writesFiles = writesFiles
    }

    /// A Claude Code `can_use_tool` request.
    init(claudeTool name: String, input: [String: Any]) {
        switch name {
        case "Bash":
            self.init(kind: .shell, command: input["command"] as? String ?? "")
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            self.init(kind: .write, paths: path.isEmpty ? [] : [path])
        case "WebFetch", "WebSearch":
            self.init(kind: .url, url: input["url"] as? String ?? input["query"] as? String, tool: name)
        case "Read", "Glob", "Grep", "LS":
            let path = input["file_path"] as? String ?? input["path"] as? String ?? ""
            self.init(kind: .read, paths: path.isEmpty ? [] : [path], tool: name, readOnly: true)
        case let tool where tool.hasPrefix("mcp__"):
            let parts = tool.components(separatedBy: "__")
            self.init(kind: .mcp, server: parts.count > 1 ? parts[1] : nil,
                      tool: parts.count > 2 ? parts[2...].joined(separator: "__") : tool)
        default:
            self.init(kind: .other, tool: name)
        }
    }

    /// An Antigravity `PreToolUse` hook request (`toolCall.name` and `toolCall.args`).
    init(antigravityTool name: String, input: [String: Any]) {
        switch name {
        case "run_command":
            let cwd = (input["Cwd"] as? String).flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            self.init(kind: .shell, command: input["CommandLine"] as? String ?? "", cwd: cwd)
        case "write_file", "edit_file", "write_to_file", "replace_file_content", "multi_replace_file_content":
            let path = input["Path"] as? String ?? input["TargetFile"] as? String ?? ""
            self.init(kind: .write, paths: path.isEmpty ? [] : [path])
        case "read_file", "view_file", "list_dir", "find_by_name", "grep_search":
            let path = input["Path"] as? String
                ?? input["AbsolutePath"] as? String
                ?? input["DirectoryPath"] as? String
                ?? input["SearchDirectory"] as? String
                ?? input["SearchPath"] as? String ?? ""
            self.init(kind: .read, paths: path.isEmpty ? [] : [path], tool: name, readOnly: true)
        case "read_url_content", "search_web":
            self.init(kind: .url, url: input["Url"] as? String ?? input["query"] as? String,
                      tool: name, readOnly: true)
        case "call_mcp_tool":
            self.init(kind: .mcp, server: input["ServerName"] as? String,
                      tool: input["ToolName"] as? String)
        case "manage_task" where (input["Action"] as? String)?.lowercased() == "send_input":
            // Input for a background task (a shell started with RunPersistent, say) runs like a command.
            self.init(kind: .shell, command: input["Input"] as? String ?? "")
            taskInput = true
        case "invoke_subagent":
            self.init(kind: .other, tool: name)
        case let tool where tool.hasPrefix("mcp__") || tool.hasPrefix("mcp_"):
            let sep = tool.hasPrefix("mcp__") ? "__" : "_"
            let parts = tool.components(separatedBy: sep)
            self.init(kind: .mcp, server: parts.count > 1 ? parts[1] : nil,
                      tool: parts.count > 2 ? parts[2...].joined(separator: sep) : tool)
        default:
            self.init(kind: .other, tool: name)
        }
    }
}
