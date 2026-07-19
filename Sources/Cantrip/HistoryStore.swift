import Foundation

struct HistoryEntry: Identifiable {
    let id = UUID()
    let day: String
    let time: String
    let backend: String
    let user: String
    let assistant: String
}

/// Parses the memory vault's daily session logs into browsable entries.
enum HistoryStore {
    static func load(limitDays: Int = 30) -> [HistoryEntry] {
        let dir = URL(fileURLWithPath: AppSettings.shared.memoryPath)
            .appendingPathComponent("sessions")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limitDays)

        var all: [HistoryEntry] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let day = file.deletingPathExtension().lastPathComponent
            var fileEntries: [HistoryEntry] = []
            for chunk in text.components(separatedBy: "\n## ").dropFirst() {
                let header = chunk.components(separatedBy: "\n").first ?? ""
                let headerParts = header.components(separatedBy: " · ")
                guard let userRange = chunk.range(of: "**User:** "),
                      let assistantRange = chunk.range(of: "**Assistant:** "),
                      userRange.upperBound <= assistantRange.lowerBound else { continue }
                fileEntries.append(HistoryEntry(
                    day: day,
                    time: headerParts.first?.trimmingCharacters(in: .whitespaces) ?? "",
                    backend: headerParts.count > 1 ? headerParts[1] : "",
                    user: String(chunk[userRange.upperBound..<assistantRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    assistant: String(chunk[assistantRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            all += fileEntries.reversed() // newest first within the day
        }
        return all
    }
}
