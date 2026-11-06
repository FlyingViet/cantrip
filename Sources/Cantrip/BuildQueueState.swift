import Foundation

/// What a running command printed about the build queue, for its card.
enum BuildQueueState: Equatable {
    static let marker = "cantrip build queue:"

    /// Waiting for a slot, with the line's details ("2 running: … · 1 ahead").
    case waiting(String)
    /// It got a slot and the build started.
    case started

    /// The newest queue line in `output`, if any.
    static func latest(in output: String) -> BuildQueueState? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let line = output[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("started") { return .started }
        if line.hasPrefix("waiting for a build slot") {
            let detail = line.dropFirst("waiting for a build slot".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            return .waiting(detail)
        }
        return nil
    }
}
