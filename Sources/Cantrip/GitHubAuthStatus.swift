import Foundation

/// The Mac's GitHub CLI (`gh`) sign-in on github.com, which every backend uses for pushes, pull
/// requests and GitHub Builds. Only the host, each account's login, whether it's the active one,
/// whether GitHub accepts it and its scopes: never a token, where it's kept (`tokenSource` can be a
/// file path) or gh's own error text.
struct GitHubAuthStatus: Codable, Equatable {
    enum State: String, Codable {
        /// The active account works.
        case signedIn
        /// gh has an account, but GitHub rejected its sign-in (revoked or expired).
        case needsSignIn
        /// No account on github.com.
        case signedOut
        /// No gh on the Mac.
        case notInstalled
        /// gh couldn't tell (offline, timed out): not a reason to sign in.
        case unknown
    }

    struct Account: Codable, Equatable {
        var login: String
        var active: Bool
        /// nil while gh couldn't reach GitHub to check it.
        var valid: Bool?
        var scopes: [String]
    }

    var state: State
    var host = GitHubAuthParser.host
    /// The active account's login and scopes.
    var login: String?
    var scopes: [String] = []
    var accounts: [Account] = []
    var checkedAt: String?
    var checking = false
}

enum GitHubAuthParser {
    static let host = "github.com"

    /// `gh auth status --json hosts`, or nil when the output isn't that JSON.
    static func parse(json data: Data) -> GitHubAuthStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hosts = object["hosts"] as? [String: Any] else { return nil }
        let entries = hosts[host] as? [[String: Any]] ?? []
        let accounts = entries.compactMap { entry -> GitHubAuthStatus.Account? in
            guard let login = entry["login"] as? String, !login.isEmpty else { return nil }
            let valid: Bool?
            switch entry["state"] as? String {
            case "success": valid = true
            case "error": valid = rejected(entry["error"] as? String ?? "") ? false : nil
            default: valid = nil
            }
            return .init(login: login, active: entry["active"] as? Bool ?? false, valid: valid,
                         scopes: scopes(entry["scopes"]))
        }
        return status(accounts)
    }

    /// `gh auth status --hostname github.com` text, from gh versions before `--json`:
    /// "✓ Logged in to github.com account NAME (keyring)" (or "… as NAME (oauth_token)" on older
    /// ones), "X Failed to log in to github.com account NAME", "- Active account: true" and
    /// "- Token scopes: 'repo', 'gist'".
    static func parse(text: String) -> GitHubAuthStatus {
        if text.localizedCaseInsensitiveContains("not logged into any") {
            return .init(state: .signedOut)
        }
        var accounts: [GitHubAuthStatus.Account] = []
        var inHost = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !raw.hasPrefix(" "), !raw.hasPrefix("\t") {
                inHost = line == host
                continue
            }
            guard inHost else { continue }
            if let login = account(in: line, after: "Logged in to \(host) account ")
                ?? account(in: line, after: "Logged in to \(host) as ") {
                accounts.append(.init(login: login, active: true, valid: true, scopes: []))
            } else if let login = account(in: line, after: "Failed to log in to \(host) account ")
                        ?? account(in: line, after: "Failed to log in to \(host) as ") {
                accounts.append(.init(login: login, active: true, valid: nil, scopes: []))
            } else if !accounts.isEmpty, let value = value(in: line, after: "Active account:") {
                accounts[accounts.count - 1].active = value == "true"
            } else if !accounts.isEmpty, let value = value(in: line, after: "Token scopes:") {
                accounts[accounts.count - 1].scopes = scopes(value)
            } else if !accounts.isEmpty, accounts[accounts.count - 1].valid == nil, rejected(line) {
                accounts[accounts.count - 1].valid = false
            }
        }
        // Older gh shows one account per host, with no "Active account" line.
        if accounts.count > 1, !text.contains("Active account:") {
            for index in accounts.indices { accounts[index].active = index == 0 }
        }
        return status(accounts, emptyMeans: text.contains(host) ? .unknown : .signedOut)
    }

    /// What one gh run printed: standard output and standard error apart (signed out, gh writes
    /// its notice to standard error beside the JSON).
    struct Run {
        var output: String
        var errors: String = ""
        var timedOut = false
    }

    /// One check of the Mac's gh: `run` runs gh with the given arguments (nil when it couldn't start).
    static func probe(ghPath: String?, run: ([String]) -> Run?) -> GitHubAuthStatus {
        guard ghPath != nil else { return .init(state: .notInstalled) }
        guard let json = run(["auth", "status", "--json", "hosts", "--hostname", host]), !json.timedOut else {
            return .init(state: .unknown)
        }
        if let status = parse(json: Data(json.output.utf8)) { return status }
        // A gh from before `--json` on auth status says so; ask it in words instead.
        guard (json.output + json.errors).contains("unknown flag"),
              let text = run(["auth", "status", "--hostname", host]), !text.timedOut else {
            return .init(state: .unknown)
        }
        return parse(text: text.output + "\n" + text.errors)
    }

    /// The JSON clients get (in GET /api/v1/backends as `github`).
    static func payload(_ status: GitHubAuthStatus) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(status),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["state": GitHubAuthStatus.State.unknown.rawValue, "host": host]
        }
        return object
    }

    private static func status(_ accounts: [GitHubAuthStatus.Account],
                               emptyMeans empty: GitHubAuthStatus.State = .signedOut) -> GitHubAuthStatus {
        guard let current = accounts.first(where: \.active) ?? accounts.first else { return .init(state: empty) }
        let state: GitHubAuthStatus.State = switch current.valid {
        case true?: .signedIn
        case false?: .needsSignIn
        case nil: .unknown
        }
        return .init(state: state, login: current.login, scopes: current.scopes, accounts: accounts)
    }

    /// GitHub turned the saved sign-in down, as opposed to gh not reaching it.
    private static func rejected(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["401", "bad credentials", "is invalid", "expired", "revoked"].contains { lowered.contains($0) }
    }

    private static func scopes(_ value: Any?) -> [String] {
        let parts: [String]
        if let list = value as? [String] { parts = list }
        else if let text = value as? String { parts = text.components(separatedBy: ",") }
        else { return [] }
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }.filter { !$0.isEmpty }
    }

    private static func account(in line: String, after marker: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...]
        let login = rest.prefix { !$0.isWhitespace && $0 != "(" }
        return login.isEmpty ? nil : String(login)
    }

    private static func value(in line: String, after marker: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}
