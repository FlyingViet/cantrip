import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var queryItems: [URLQueryItem] = []

    var target: String {
        var components = URLComponents()
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.string ?? path
    }

    func query(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    var isHistoryRead: Bool {
        let parts = path.split(separator: "/")
        return method == "GET" && parts.starts(with: ["api", "v1", "sessions"])
            && (parts.count == 4 || (parts.count == 6 && parts[4] == "messages"))
    }

    var json: [String: Any]? {
        guard !body.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
              )
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard requestParts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0 else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let target = String(requestParts[1])
        guard let components = URLComponents(string: target) else { return nil }
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: components.path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength)),
            queryItems: components.queryItems ?? []
        )
    }

    static func needsMoreData(_ data: Data) -> Bool {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else { return true }
        guard let headerText = String(
            data: data[..<headerRange.lowerBound],
            encoding: .utf8
        ) else { return false }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let raw = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(raw), parsed >= 0 else { return false }
            contentLength = parsed
        }
        return data.count < headerRange.upperBound + contentLength
    }
}
