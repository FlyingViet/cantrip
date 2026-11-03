import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let fakeToken = "gho_FAKEtoken0123456789abcdefABCDEF012345"
private let tokenPath = "/Users/someone/.config/gh/hosts.yml"

private func json(_ text: String) -> GitHubAuthStatus? { GitHubAuthParser.parse(json: Data(text.utf8)) }

private func noSecrets(_ status: GitHubAuthStatus, _ label: String) {
    let payload = GitHubAuthParser.payload(status)
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    expect(!text.contains("gho_"), "\(label): no token in the payload")
    expect(!text.contains(fakeToken), "\(label): no token in the payload")
    expect(!text.contains("hosts.yml") && !text.contains("tokenSource") && !text.contains("keyring"),
           "\(label): not where the token is kept")
    expect(!text.contains("Bad credentials"), "\(label): not gh's error text")
    expect(Set(payload.keys).isSubset(of: ["state", "host", "login", "scopes", "accounts", "checkedAt", "checking"]),
           "\(label): only the reported fields: \(payload.keys.sorted())")
}

// Signed in (gh 2.92, `gh auth status --json hosts --hostname github.com`).
let signedIn = json("""
{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo-qa",
"tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}
""")
expect(signedIn?.state == .signedIn, "signed in")
expect(signedIn?.login == "octo-qa", "login")
expect(signedIn?.scopes == ["gist", "read:org", "repo", "workflow"], "scopes: \(signedIn?.scopes ?? [])")
expect(signedIn?.host == "github.com", "host")
if let signedIn { noSecrets(signedIn, "signed in") }

// --show-token output must never reach a payload either.
let shown = json("""
{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo-qa",
"tokenSource":"\(tokenPath)","token":"\(fakeToken)","scopes":"repo","gitProtocol":"https"}]}}
""")
expect(shown?.state == .signedIn, "token shown: still signed in")
if let shown { noSecrets(shown, "token shown") }

// Signed out.
expect(json(#"{"hosts":{}}"#)?.state == .signedOut, "no hosts: signed out")
expect(json(#"{"hosts":{"enterprise.example":[{"state":"success","active":true,"login":"x"}]}}"#)?.state == .signedOut,
       "another host only: signed out on github.com")

// Several accounts: the active one counts; every account is listed without tokens.
let several = json("""
{"hosts":{"github.com":[
{"state":"success","active":false,"host":"github.com","login":"work-qa","tokenSource":"keyring","scopes":"repo"},
{"state":"success","active":true,"host":"github.com","login":"octo-qa","tokenSource":"keyring","scopes":"repo, workflow"}]}}
""")
expect(several?.state == .signedIn && several?.login == "octo-qa", "active account wins")
expect(several?.scopes == ["repo", "workflow"], "active account's scopes")
expect(several?.accounts.map(\.login) == ["work-qa", "octo-qa"], "every account")
expect(several?.accounts.map(\.active) == [false, true], "which is active")
if let several { noSecrets(several, "several") }

// A rejected sign-in needs signing in again; gh's error text stays on the Mac.
let rejected = json("""
{"hosts":{"github.com":[{"state":"error","error":"HTTP 401: Bad credentials (https://api.github.com/)",
"active":true,"host":"github.com","login":"octo-qa","tokenSource":"\(tokenPath)","gitProtocol":"https"}]}}
""")
expect(rejected?.state == .needsSignIn, "rejected: needs sign-in")
expect(rejected?.login == "octo-qa", "rejected: login kept")
if let rejected { noSecrets(rejected, "rejected") }

// Offline or timed out: unknown, never "signed out".
let offline = json("""
{"hosts":{"github.com":[{"state":"error","error":"dial tcp: lookup api.github.com: no such host",
"active":true,"host":"github.com","login":"octo-qa"}]}}
""")
expect(offline?.state == .unknown, "offline: unknown")
expect(json(#"{"hosts":{"github.com":[{"state":"timeout","active":true,"login":"octo-qa"}]}}"#)?.state == .unknown,
       "timeout: unknown")
expect(json("not json") == nil, "not JSON")

// Text from gh before `--json`.
let text = GitHubAuthParser.parse(text: """
github.com
  ✓ Logged in to github.com account octo-qa (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'

  ✓ Logged in to github.com account work-qa (keyring)
  - Active account: false
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'repo'
""")
expect(text.state == .signedIn && text.login == "octo-qa", "text: active account")
expect(text.scopes == ["gist", "read:org", "repo", "workflow"], "text scopes: \(text.scopes)")
expect(text.accounts.map(\.login) == ["octo-qa", "work-qa"], "text: every account")
noSecrets(text, "text")
let older = GitHubAuthParser.parse(text: """
github.com
  ✓ Logged in to github.com as octo-qa (oauth_token)
  ✓ Git operations for github.com configured to use https protocol.
  ✓ Token: *******************
  ✓ Token scopes: gist, read:org, repo
""")
expect(older.state == .signedIn && older.login == "octo-qa" && older.scopes == ["gist", "read:org", "repo"], "older text")
expect(GitHubAuthParser.parse(text: "You are not logged into any GitHub hosts. To log in, run: gh auth login").state == .signedOut,
       "text: signed out")
let failed = GitHubAuthParser.parse(text: """
github.com
  X Failed to log in to github.com account octo-qa (keyring)
  - Active account: true
  - The token in keyring is invalid.
  - To re-authenticate, run: gh auth login -h github.com
""")
expect(failed.state == .needsSignIn && failed.login == "octo-qa", "text: invalid token")

// Probing: missing gh, an old gh without --json, a timeout.
expect(GitHubAuthParser.probe(ghPath: nil) { _ in nil }.state == .notInstalled, "missing gh")
var calls: [[String]] = []
let fallback = GitHubAuthParser.probe(ghPath: "/opt/gh") { arguments in
    calls.append(arguments)
    if arguments.contains("--json") { return .init(output: "", errors: "unknown flag: --json") }
    return .init(output: "", errors: "github.com\n  ✓ Logged in to github.com as octo-qa (oauth_token)\n  ✓ Token scopes: repo")
}
expect(fallback.state == .signedIn && fallback.login == "octo-qa", "old gh: text fallback")
expect(calls.count == 2 && !calls.joined().contains("--show-token") && !calls.joined().contains("token"),
       "never asks gh for a token: \(calls)")
expect(GitHubAuthParser.probe(ghPath: "/opt/gh") { _ in .init(output: "", timedOut: true) }.state == .unknown, "timeout")
expect(GitHubAuthParser.probe(ghPath: "/opt/gh") { _ in .init(output: #"{"hosts":{}}"#,
       errors: "You are not logged into any GitHub hosts.") }.state == .signedOut, "signed out with a notice on stderr")

if failures > 0 {
    fputs("\(failures) GitHub sign-in test(s) failed\n", stderr)
    exit(1)
}
print("GitHub sign-in tests passed")
