import Foundation

/// Best-effort plan-quota lookups. GitHub's AI-credit billing API is
/// young and shape-shifts, so parsing is deliberately loose: find the
/// numbers, show what's found, log the raw payload for debugging.
enum QuotaFetcher {
    /// Copilot AI credits via `gh api` (requires an authenticated gh CLI).
    static func fetchCopilotQuota(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let login = shell("gh api user -q .login"),
                  !login.isEmpty else {
                completion(nil)
                return
            }
            let endpoints = [
                "/users/\(login)/settings/billing/ai_credit/usage",
                "/users/\(login)/settings/billing/usage",
            ]
            for endpoint in endpoints {
                if let out = shell("gh api \(endpoint) 2>/dev/null"),
                   let summary = parse(out) {
                    completion(summary)
                    return
                }
            }
            completion(nil)
        }
    }

    private static func shell(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        Log.write("quota: copilot payload \(String(json.prefix(300)))")

        // Real schema (GET /users/{u}/settings/billing/usage):
        // {"usageItems":[{"date","product","sku","quantity","unitType",
        //   "netAmount",…}]} — Copilot appears as its own product rows.
        if let items = obj["usageItems"] as? [[String: Any]] {
            let monthFormatter = DateFormatter()
            monthFormatter.dateFormat = "yyyy-MM"
            let thisMonth = monthFormatter.string(from: Date())

            var quantity = 0.0
            var unit: String?
            var billed = 0.0
            for item in items {
                let product = (item["product"] as? String ?? "").lowercased()
                let sku = (item["sku"] as? String ?? "").lowercased()
                guard product.contains("copilot") || sku.contains("copilot")
                    || sku.contains("ai credit") || sku.contains("ai_credit")
                    || sku.contains("premium") else { continue }
                guard let date = item["date"] as? String,
                      date.hasPrefix(thisMonth) else { continue }
                quantity += (item["quantity"] as? Double)
                    ?? Double(item["quantity"] as? Int ?? 0)
                unit = unit ?? item["unitType"] as? String
                billed += item["netAmount"] as? Double ?? 0
            }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            if quantity > 0 {
                var line = "\(formatter.string(from: NSNumber(value: quantity)) ?? String(Int(quantity))) \((unit ?? "credits").lowercased()) used this month"
                if billed > 0 { line += String(format: " · $%.2f billed", billed) }
                return line
            }
            return "no Copilot usage billed yet this month (allotment isn't exposed by GitHub's API)"
        }
        var used = 0.0
        var included = 0.0

        func number(_ value: Any?) -> Double? {
            (value as? Double) ?? (value as? Int).map(Double.init)
                ?? (value as? String).flatMap(Double.init)
        }
        func isCopilotish(_ dict: [String: Any]) -> Bool {
            dict.values.contains {
                guard let s = $0 as? String else { return false }
                let lowered = s.lowercased()
                return lowered.contains("copilot") || lowered.contains("ai_credit")
            }
        }
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                let copilotItem = isCopilotish(dict)
                for (k, v) in dict {
                    let key = k.lowercased()
                    if let n = number(v), n > 0 {
                        if key.contains("included") || key.contains("entitlement")
                            || key.contains("allotment") || key.contains("limit") {
                            included = max(included, n)
                        } else if key.contains("used") || key.contains("consumed")
                            || (key == "quantity" && copilotItem) {
                            used += n
                        }
                    }
                    walk(v)
                }
            } else if let array = any as? [Any] {
                array.forEach(walk)
            }
        }
        walk(obj)
        guard used > 0 || included > 0 else { return nil }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        func fmt(_ v: Double) -> String {
            formatter.string(from: NSNumber(value: v)) ?? String(Int(v))
        }
        if included > 0 {
            let pct = used / included * 100
            return "\(fmt(used)) AI credits / \(fmt(included)) (\(String(format: "%.0f", pct))%) this month"
        }
        return "\(fmt(used)) AI credits used this month"
    }
}
