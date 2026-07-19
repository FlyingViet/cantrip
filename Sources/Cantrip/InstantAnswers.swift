import AppKit
import Foundation

/// Zero-latency local answers — no LLM round-trip. Handles arithmetic,
/// common unit conversions, and "open <app>". Returns nil to fall
/// through to the normal backend.
enum InstantAnswers {
    static func answer(for query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let math = evaluateMath(q) { return math }
        if let unit = convertUnits(q) { return unit }
        if let open = openApp(q) { return open }
        return nil
    }

    // MARK: - Math

    private static func evaluateMath(_ q: String) -> String? {
        var expr = q.lowercased()
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        guard !expr.isEmpty,
              expr.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              expr.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil,
              expr.rangeOfCharacter(from: .decimalDigits) != nil,
              Double(expr) == nil, // not just a bare number
              expr.filter({ $0 == "(" }).count == expr.filter({ $0 == ")" }).count,
              let lastChar = expr.replacingOccurrences(of: " ", with: "").last,
              lastChar.isNumber || lastChar == ")" // no trailing operator
        else { return nil }
        // Integer division surprises nobody wants: force floating point,
        // touching only bare integers (lookarounds keep 12.5 intact).
        expr = expr.replacingOccurrences(
            of: #"(?<![\d.])(\d+)(?![\d.])"#, with: "$1.0",
            options: .regularExpression)
        let parsed = NSExpression(format: expr)
        guard let value = (parsed.expressionValue(with: nil, context: nil) as? NSNumber)?.doubleValue,
              value.isFinite else { return nil }
        return "**= \(format(value))**"
    }

    // MARK: - Units

    private struct Unit {
        let category: String
        let toBase: Double   // multiplier into the category's base unit
        let label: String
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ names: [String], _ category: String, _ factor: Double, _ label: String) {
            for name in names { table[name] = Unit(category: category, toBase: factor, label: label) }
        }
        add(["mm", "millimeter", "millimeters"], "length", 0.001, "mm")
        add(["cm", "centimeter", "centimeters"], "length", 0.01, "cm")
        add(["m", "meter", "meters", "metre", "metres"], "length", 1, "m")
        add(["km", "kilometer", "kilometers"], "length", 1000, "km")
        add(["in", "inch", "inches"], "length", 0.0254, "in")
        add(["ft", "foot", "feet"], "length", 0.3048, "ft")
        add(["yd", "yard", "yards"], "length", 0.9144, "yd")
        add(["mi", "mile", "miles"], "length", 1609.344, "mi")
        add(["g", "gram", "grams"], "mass", 0.001, "g")
        add(["kg", "kilogram", "kilograms", "kilo", "kilos"], "mass", 1, "kg")
        add(["lb", "lbs", "pound", "pounds"], "mass", 0.45359237, "lb")
        add(["oz", "ounce", "ounces"], "mass", 0.028349523, "oz")
        add(["ml", "milliliter", "milliliters"], "volume", 0.001, "ml")
        add(["l", "liter", "liters", "litre", "litres"], "volume", 1, "L")
        add(["gal", "gallon", "gallons"], "volume", 3.785411784, "gal")
        add(["cup", "cups"], "volume", 0.2365882365, "cups")
        add(["floz"], "volume", 0.0295735296, "fl oz")
        add(["kb"], "data", 1, "KB")
        add(["mb"], "data", 1024, "MB")
        add(["gb"], "data", 1_048_576, "GB")
        add(["tb"], "data", 1_073_741_824, "TB")
        add(["sec", "second", "seconds", "s"], "time", 1, "s")
        add(["min", "minute", "minutes"], "time", 60, "min")
        add(["hr", "hour", "hours", "h"], "time", 3600, "hr")
        add(["day", "days", "d"], "time", 86400, "days")
        return table
    }()

    private static func convertUnits(_ q: String) -> String? {
        let pattern = #"^([\d.,]+)\s*°?\s*([a-zA-Z]+)\s+(?:to|in|as)\s+°?\s*([a-zA-Z]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let vRange = Range(match.range(at: 1), in: q),
              let fromRange = Range(match.range(at: 2), in: q),
              let toRange = Range(match.range(at: 3), in: q),
              let value = Double(q[vRange].replacingOccurrences(of: ",", with: ""))
        else { return nil }
        let from = String(q[fromRange]).lowercased()
        let to = String(q[toRange]).lowercased()

        // Temperature is affine, handled separately.
        let temps = ["c": "c", "celsius": "c", "f": "f", "fahrenheit": "f"]
        if let f = temps[from], let t = temps[to], f != t {
            let result = f == "c" ? value * 9 / 5 + 32 : (value - 32) * 5 / 9
            return "**\(format(value))°\(f.uppercased()) = \(format(result))°\(t.uppercased())**"
        }
        guard let fromUnit = units[from], let toUnit = units[to],
              fromUnit.category == toUnit.category else { return nil }
        let result = value * fromUnit.toBase / toUnit.toBase
        return "**\(format(value)) \(fromUnit.label) = \(format(result)) \(toUnit.label)**"
    }

    // MARK: - App launching

    private static func openApp(_ q: String) -> String? {
        let lower = q.lowercased()
        guard lower.hasPrefix("open ") || lower.hasPrefix("launch ") else { return nil }
        let name = q.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count < 40, !name.contains("/") else { return nil }

        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        for dir in dirs {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if let appFile = contents.first(where: {
                $0.hasSuffix(".app") &&
                $0.dropLast(4).lowercased() == name.lowercased()
            }) ?? contents.first(where: {
                $0.hasSuffix(".app") &&
                $0.lowercased().hasPrefix(name.lowercased())
            }) {
                let url = URL(fileURLWithPath: "\(dir)/\(appFile)")
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: NSWorkspace.OpenConfiguration())
                return "Opening **\(appFile.replacingOccurrences(of: ".app", with: ""))**…"
            }
        }
        return nil // unknown app — let the LLM figure out what was meant
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 1 ? 6 : 4
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
