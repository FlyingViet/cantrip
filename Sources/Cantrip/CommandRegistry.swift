import Foundation

/// User-defined commands ("skills"): executables in
/// ~/.config/cantrip/commands/. Invoke as `/name args` in the panel.
/// A `# description: …` line in the script's header feeds the typeahead.
struct ScriptCommand: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let path: String
}

final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()
    @Published private(set) var commands: [ScriptCommand] = []
    private var lastScan = Date.distantPast

    private var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cantrip/commands")
    }

    private init() {
        ensureDir()
        reload()
    }

    /// Only the folder: no example script, so "/" lists only commands you actually have.
    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func reload() {
        guard Date().timeIntervalSince(lastScan) > 5 else { return }
        lastScan = Date()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var found: [ScriptCommand] = []
        for file in files {
            guard fm.isExecutableFile(atPath: file.path),
                  !file.hasDirectoryPath else { continue }
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            guard !name.isEmpty else { continue }
            var description = ""
            if let head = try? String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n").prefix(10) {
                for line in head {
                    if let range = line.range(of: #"#\s*description:\s*"#,
                                              options: .regularExpression) {
                        description = String(line[range.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            found.append(ScriptCommand(name: name, description: description,
                                       path: file.path))
        }
        let sorted = found.sorted { $0.name < $1.name }
        if Thread.isMainThread { commands = sorted } else { DispatchQueue.main.async { self.commands = sorted } }
    }

    /// Typeahead matches for a query beginning with "/".
    func matches(for query: String) -> [ScriptCommand] {
        guard query.hasPrefix("/") else { return [] }
        reload()
        let word = query.dropFirst().components(separatedBy: " ").first?.lowercased() ?? ""
        // Once args are being typed, only show the exact command.
        if query.contains(" ") {
            return commands.filter { $0.name == word }
        }
        return commands.filter { word.isEmpty || $0.name.hasPrefix(word) }
    }

    func command(named name: String) -> ScriptCommand? {
        commands.first { $0.name == name.lowercased() }
    }
}
