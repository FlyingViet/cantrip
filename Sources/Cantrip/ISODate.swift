import Foundation

/// ISO 8601 timestamps as JSON, CLIs and GitHub write them, plus local day keys.
///
/// Formatters are costly to build and safe to share across threads once configured,
/// so there is one of each.
enum ISODate {
    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "2026-10-27T16:19:22Z" or, unless `allowFractionalSeconds` is false, "2026-10-27T16:19:22.123Z".
    static func date(from text: String, allowFractionalSeconds: Bool = true) -> Date? {
        whole.date(from: text) ?? (allowFractionalSeconds ? fractional.date(from: text) : nil)
    }

    /// "2026-10-27T16:19:22Z", in UTC.
    static func string(from date: Date) -> String {
        whole.string(from: date)
    }

    /// "2026-10-27" for `date` in the Mac's current time zone, always in Gregorian digits.
    static func localDay(_ date: Date) -> String {
        day.string(from: date)
    }
}
