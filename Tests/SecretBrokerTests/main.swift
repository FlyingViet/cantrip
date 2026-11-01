import Foundation

// Focused tests for the secrets broker: no keychain, no Bitwarden, no real secrets. Every value
// below is an example. Runs in a temporary home (see the Makefile's test-secrets).

@main
enum SecretBrokerTests {
    static func main() throws {
        requireTemporaryHome()
        testNames()
        try testImportPlan()
        testBitwardenItems()
        try testRunPlan()
        testMasker()
        try testSync()
        try testRunner()
        print("Secret broker: import mapping, Bitwarden items, sync, run plans, masking and the runner passed")
    }

    static func requireTemporaryHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let real = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)).standardizedFileURL.path }
        guard let testHome = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"],
              URL(fileURLWithPath: testHome).standardizedFileURL.path == home, home != real else {
            fatalError("Secret tests write an index and lock files in the home folder; run them with `make test-secrets`")
        }
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("secret-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func testNames() {
        precondition(SecretImport.itemName(forRelativePath: "service.env") == "service")
        precondition(SecretImport.itemName(forRelativePath: "account.json") == "account")
        precondition(SecretImport.itemName(forRelativePath: "keys/AuthKey_EXAMPLE.p8") == "keys-AuthKey_EXAMPLE-p8")
        precondition(SecretImport.itemName(forRelativePath: "signing/cert.p12.password") == "signing-cert-p12-password")
        precondition(SecretImport.itemName(forRelativePath: "proxy.token") == "proxy-token")
        precondition(SecretImport.itemName(forRelativePath: "odd name.env") == "odd-name")
        precondition(SecretNames.isItemName("example-api_1") && !SecretNames.isItemName("a.b") && !SecretNames.isItemName(""))
        precondition(SecretNames.isVariableName("EXAMPLE_TOKEN") && SecretNames.isVariableName("_X")
                     && !SecretNames.isVariableName("1X") && !SecretNames.isVariableName("A-B"))

        for name in ["keys/cert.cer", "keys/cert.csr", "keys/cert.pem", "keys/cert.certid", "keys/profiles/app.mobileprovision",
                     "keys/profiles/app.mobileprovision.bak-old", "keys/wwdr_example.pem", ".DS_Store"] {
            precondition(!SecretImport.isSecretFile(name), "\(name) isn't secret")
        }
        for name in ["service.env", "keys/AuthKey.p8", "keys/cert.p12", "keys/cert.key", "keys/p12.password", "api.key"] {
            precondition(SecretImport.isSecretFile(name), "\(name) is secret")
        }

        precondition(SecretImport.variableNames(inEnvFile: "# comment\nexport A_URL=x\nB_TOKEN=\"y z\"\n\nnot a line\nA_URL=again\n")
                     == ["A_URL", "B_TOKEN"])
        let plain = ["EXAMPLE_URL", "EXAMPLE_API", "EXAMPLE_BASE", "EXAMPLE_USER", "EXAMPLE_EMAIL", "EXAMPLE_KEY_ID",
                     "EXAMPLE_ISSUER_ID", "EXAMPLE_LIBRARY_ID", "EXAMPLE_PORT", "EXAMPLE_PUBKEY", "EXAMPLE_CHAT_ID"]
        for name in plain { precondition(SecretImport.isPlain(name, value: "https://service.example"), "\(name) is plain") }
        let hidden = ["EXAMPLE_TOKEN", "EXAMPLE_API_KEY", "EXAMPLE_PASSWORD", "EXAMPLE_PASS", "EXAMPLE_SECRET",
                      "EXAMPLE_WEBHOOK_URL", "EXAMPLE_WEBHOOK_ID", "EXAMPLE_ACCESS_URL", "EXAMPLE_HEARTBEAT_ID", "RESTIC_PASSWORD"]
        for name in hidden { precondition(!SecretImport.isPlain(name, value: "value"), "\(name) is hidden") }
        precondition(!SecretImport.isPlain("EXAMPLE_URL", value: "https://user:pw@service.example/"),
                     "A URL with a password in it is hidden")
    }

    static func testImportPlan() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ path: String, _ text: String) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("service.env", "# example\nexport SERVICE_URL=https://service.example\nSERVICE_TOKEN=\"tok en'with\\$(literal)\"\nSERVICE_USER='someone'\n")
        try write("account.json", "{\"type\": \"example\", \"private_key\": \"-----BEGIN-----\\nabc\\n\"}\n")
        try write("proxy.token", "example-proxy-token-123\n")
        try write("keys/cert.cer", "public")
        try write("keys/profiles/app.mobileprovision", "public")
        var binary = Data((0..<600).map { UInt8($0 % 256) })
        binary[0] = 0xFF
        try binary.write(to: folder.appendingPathComponent("keys/cert.p12"))

        let plan = try SecretImport.plan(folder: folder)
        precondition(plan.map(\.item) == ["account", "keys-cert-p12", "proxy-token", "service"], "\(plan.map(\.item))")
        let service = plan.first { $0.item == "service" }!
        precondition(service.kind == .fields && service.fields.map(\.name) == ["SERVICE_URL", "SERVICE_TOKEN", "SERVICE_USER"])
        precondition(service.fields.map(\.hidden) == [false, true, false])
        precondition(plan.first { $0.item == "keys-cert-p12" }?.kind == .binary)
        precondition(plan.first { $0.item == "account" }?.kind == .text)

        let item = try SecretImport.item(for: service, folder: folder)
        precondition(item.field("SERVICE_TOKEN")?.value == "tok en'with$(literal)", "Values are what the shell sees")
        precondition(item.field("SERVICE_USER")?.value == "someone")
        let p12 = try SecretImport.item(for: plan.first { $0.item == "keys-cert-p12" }!, folder: folder)
        precondition(p12.binary && p12.fileData == binary, "Binary files round-trip through base64")
        let token = try SecretImport.item(for: plan.first { $0.item == "proxy-token" }!, folder: folder)
        precondition(token.text == "example-proxy-token-123\n" && token.textValue == "example-proxy-token-123")

        precondition(SecretImport.matches(item, item))
        var changed = item
        changed.fields[1].value += "!"
        precondition(!SecretImport.matches(item, changed), "A changed value no longer matches")
        var moved = item
        moved.fields.reverse()
        precondition(SecretImport.matches(item, moved), "Field order doesn't matter")
    }

    static func bitwardenRoundTrip(_ item: SecretItem, id: String = UUID().uuidString) -> [String: Any] {
        var object = SecretBitwarden.newItem(item, folderID: "folder-1")
        object["id"] = id
        object["revisionDate"] = "2026-01-02T03:04:05.000Z"
        // As `bw` returns it: JSON, nulls included.
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func testBitwardenItems() {
        let item = SecretItem(name: "service", fields: [
            SecretField(name: "SERVICE_URL", value: "https://service.example", hidden: false),
            SecretField(name: "SERVICE_TOKEN", value: "example-token-value", hidden: true),
        ])
        let object = SecretBitwarden.newItem(item, folderID: "folder-1")
        precondition(object["type"] as? Int == 2 && object["folderId"] as? String == "folder-1")
        let types = (object["fields"] as? [[String: Any]])?.map { $0["type"] as? Int }
        precondition(types == [0, 1], "Secrets are hidden fields, addresses plain text")
        guard case .success(var parsed) = SecretBitwarden.item(from: bitwardenRoundTrip(item)) else { fatalError("parse") }
        precondition(parsed.revision != nil)
        parsed.revision = nil
        precondition(parsed == item, "A created item reads back the same")

        let binary = SecretItem(name: "cert", text: Data([1, 2, 3, 250]).base64EncodedString(), binary: true)
        guard case .success(var parsedBinary) = SecretBitwarden.item(from: bitwardenRoundTrip(binary)) else { fatalError("binary") }
        parsedBinary.revision = nil
        precondition(parsedBinary == binary && parsedBinary.fileData == Data([1, 2, 3, 250]) && parsedBinary.kind == .binary)

        let encoded = try! SecretBitwarden.encoded(["name": "x"])
        precondition(Data(base64Encoded: encoded) == (try! JSONSerialization.data(withJSONObject: ["name": "x"], options: [.sortedKeys])))

        if case .success = SecretBitwarden.item(from: ["name": "has space", "type": 2]) { fatalError("Bad names are skipped") }
        if case .success = SecretBitwarden.item(from: ["name": "ok", "type": 2, "fields": [["name": "bad-name", "value": "v", "type": 1]]]) {
            fatalError("Fields that can't be variables are reported")
        }
        guard case .success(let login) = SecretBitwarden.item(from: [
            "name": "router", "type": 1, "login": ["username": "admin", "password": "example-password"],
        ]) else { fatalError("login") }
        precondition(login.fields == [SecretField(name: "username", value: "admin", hidden: false),
                                      SecretField(name: "password", value: "example-password", hidden: true)],
                     "Login items hand out their user name and password")
        guard case .success(let boolean) = SecretBitwarden.item(from: [
            "name": "flags", "type": 2, "fields": [["name": "ENABLED", "value": "true", "type": 2]],
        ]) else { fatalError("bool") }
        precondition(boolean.fields.isEmpty, "Boolean and linked fields aren't secrets to hand out")
    }

    static let exampleItems: [String: SecretItem] = [
        "service": SecretItem(name: "service", fields: [
            SecretField(name: "SERVICE_URL", value: "https://service.example", hidden: false),
            SecretField(name: "SERVICE_TOKEN", value: "example-token-value", hidden: true),
        ]),
        "proxy-token": SecretItem(name: "proxy-token", text: "example-proxy-token-123\n"),
        "account": SecretItem(name: "account", text: "{\"key\": \"example-account-key\"}\n"),
        "quoted": SecretItem(name: "quoted", fields: [
            SecretField(name: "QUOTED_PASS", value: "it's a $(value) with \"quotes\"\nand a line", hidden: true),
        ]),
    ]

    static func testRunPlan() throws {
        let plan = try SecretRunPlan.parse(["service", "proxy.PROXY", "ALIAS=service.SERVICE_TOKEN", "TOKEN=proxy-token",
                                            "--file", "ACCOUNT_FILE=account", "--env-file", "ENV=service", "--", "tool", "--flag"])
        precondition(plan.command == ["tool", "--flag"] && !plan.temporaryFiles)
        precondition(plan.variables == [
            .init(name: "", item: "service", field: nil),
            .init(name: "PROXY", item: "proxy", field: "PROXY"),
            .init(name: "ALIAS", item: "service", field: "SERVICE_TOKEN"),
            .init(name: "TOKEN", item: "proxy-token", field: nil),
        ])
        precondition(plan.files == [.init(variable: "ACCOUNT_FILE", item: "account", format: .content),
                                    .init(variable: "ENV", item: "service", format: .env)])
        precondition(plan.items == ["service", "proxy", "proxy-token", "account"])

        for bad in [["service"], ["--", "tool"], ["service", "--"], ["a.b.c", "--", "x"], ["--file", "account", "--", "x"],
                    ["--bogus", "--", "x"], ["1VAR=service", "--", "x"]] {
            do { _ = try SecretRunPlan.parse(bad); fatalError("\(bad) should fail") } catch is SecretRunPlan.Failure {}
        }

        let environment = try SecretRunPlan.parse(["service", "ALIAS=service.SERVICE_TOKEN", "TOKEN=proxy-token", "--", "x"])
            .environment(items: exampleItems)
        precondition(environment == ["SERVICE_URL": "https://service.example", "SERVICE_TOKEN": "example-token-value",
                                     "ALIAS": "example-token-value", "TOKEN": "example-proxy-token-123"])
        for bad in [["missing", "--", "x"], ["service.NOPE", "--", "x"], ["proxy-token", "--", "x"], ["V=service", "--", "x"]] {
            do { _ = try SecretRunPlan.parse(bad).environment(items: exampleItems); fatalError("\(bad) should fail") }
            catch let failure as SecretRunPlan.Failure { precondition(!failure.message.contains("example-"), "Errors never hold values") }
        }

        precondition(SecretRunPlan.shellQuoted("plain-value_1.2:3") == "plain-value_1.2:3")
        precondition(SecretRunPlan.shellQuoted("it's") == "'it'\\''s'")
        let envFile = try SecretRunPlan.fileContents(exampleItems["quoted"]!, format: .env)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("env")
        try envFile.write(to: url)
        let sourced = try ProcessRunner.run("/bin/sh", ["-c", ". \"$1\"; printf %s \"$QUOTED_PASS\"", "sh", url.path])
        precondition(String(decoding: sourced.output, as: UTF8.self) == exampleItems["quoted"]!.fields[0].value,
                     "An env file sources back to the exact value")
        do { _ = try SecretRunPlan.fileContents(exampleItems["service"]!, format: .content); fatalError("fields aren't file content") }
        catch is SecretRunPlan.Failure {}
    }

    static func testMasker() {
        let values: [(label: String, value: String)] = [("service.SERVICE_TOKEN", "example-token-value"),
                                                        ("short", "abc"), ("account", "line one is long enough\nsecond line also long enough")]
        let masker = SecretMasker(values)
        precondition(masker.mask("token=example-token-value; done") == "token=[secret:service.SERVICE_TOKEN]; done")
        precondition(masker.mask("abc stays") == "abc stays", "Very short values aren't masked")
        precondition(masker.mask("printed: second line also long enough") == "printed: [secret:account]",
                     "Lines of a multi-line value are masked on their own")
        precondition(masker.mask(#"{"v":"line one is long enough\nsecond line also long enough"}"#) == #"{"v":"[secret:account]"}"#,
                     "JSON-escaped values are masked")

        var streaming = SecretMasker(values)
        var output: [UInt8] = []
        for byte in Array("start example-token-value end example-tok".utf8) { output += streaming.feed([byte]) }
        precondition(String(decoding: output, as: UTF8.self) == "start [secret:service.SERVICE_TOKEN] end ",
                     "A value split across reads is still masked; a possible start is held back")
        output += streaming.finish()
        precondition(String(decoding: output, as: UTF8.self).hasSuffix(" end example-tok"), "The tail is released at the end")

        var plain = SecretMasker(values)
        precondition(plain.feed(Array("no secrets here\n".utf8)) == Array("no secrets here\n".utf8), "Other output isn't delayed")

        let overlapping = SecretMasker([("long", "example-token-value-longer"), ("short", "example-token")])
        precondition(overlapping.mask("example-token-value-longer example-token") == "[secret:long] [secret:short]")

        precondition(!SecretRedaction.isActive)
        SecretRedaction.update(exampleItems["service"]!.maskedValues)
        precondition(SecretRedaction.redact("log: example-token-value") == "log: [secret:service.SERVICE_TOKEN]")
        precondition(SecretRedaction.redact("https://service.example") == "https://service.example", "Plain fields aren't masked")
        SecretRedaction.update([])
    }

    /// A fake `bw` that records every call.
    final class FakeBitwarden {
        var status = "locked"
        var password = "example-master-password"
        var items: [[String: Any]] = []
        var folders: [[String: Any]] = [["id": "folder-1", "name": SecretIndex.defaultFolder]]
        var calls: [(arguments: [String], environment: [String: String], input: Data?)] = []

        var cli: BitwardenCLI {
            BitwardenCLI(executable: "/fake/bw") { [self] arguments, environment, input in
                calls.append((arguments, environment, input))
                func ok(_ object: Any) -> ProcessRunner.Result {
                    .init(status: 0, output: try! JSONSerialization.data(withJSONObject: object), errorOutput: Data())
                }
                switch Array(arguments.prefix(2)) {
                case ["status", "--nointeraction"]: return ok(["status": status])
                case ["unlock", "--passwordenv"]:
                    guard environment[BitwardenCLI.passwordVariable] == password else {
                        return .init(status: 1, output: Data(), errorOutput: Data("Invalid master password.".utf8))
                    }
                    return .init(status: 0, output: Data("example-session\n".utf8), errorOutput: Data())
                case ["lock", "--nointeraction"]: return .init(status: 0, output: Data(), errorOutput: Data())
                default: break
                }
                guard environment["BW_SESSION"] == "example-session" else {
                    return .init(status: 1, output: Data(), errorOutput: Data("Vault is locked.".utf8))
                }
                switch Array(arguments.prefix(2)) {
                case ["sync", "--nointeraction"]: return ok([:])
                case ["list", "folders"]: return ok(folders)
                case ["list", "items"]: return ok(items)
                case ["create", "folder"]:
                    folders.append(["id": "folder-new", "name": SecretIndex.defaultFolder])
                    return ok(["id": "folder-new"])
                case ["create", "item"], ["edit", "item"]:
                    let json = try! JSONSerialization.jsonObject(with: Data(base64Encoded: input!)!) as! [String: Any]
                    var stored = json
                    stored["id"] = arguments[0] == "edit" ? arguments[2] : UUID().uuidString
                    stored["revisionDate"] = "2026-01-02T03:04:05.000Z"
                    items.removeAll { $0["id"] as? String == stored["id"] as? String }
                    items.append(stored)
                    return ok(stored)
                default:
                    return .init(status: 1, output: Data(), errorOutput: Data("unknown".utf8))
                }
            }
        }
    }

    static func testSync() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("secrets/index.json")
        let store = SecretKeychain.Store.memory()
        let fake = FakeBitwarden()
        let service = exampleItems["service"]!
        fake.items = [bitwardenRoundTrip(service), ["name": "bad name", "type": 2, "folderId": "folder-1"]]

        fake.status = "unauthenticated"
        do { _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL); fatalError() }
        catch is BitwardenCLI.Failure {}
        precondition(SecretIndex.load(from: indexURL)?.lastError?.contains("bw login") == true, "A failure is recorded by name")
        fake.status = "locked"

        do { _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { nil }, indexURL: indexURL); fatalError() }
        catch is SecretSync.Cancelled {}
        precondition(!fake.calls.contains { $0.arguments.first == "unlock" }, "Cancelling never unlocks")

        do { _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { "wrong" }, indexURL: indexURL); fatalError() }
        catch let failure as BitwardenCLI.Failure { precondition(failure.message.contains("didn't accept")) }

        fake.calls.removeAll()
        let report = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL)
        precondition(report.cached == ["service"] && report.skipped.count == 1, "\(report)")
        let cachedService = try store.item("service")
        precondition(cachedService?.fields == service.fields, "Values land in the keychain cache")
        precondition(fake.calls.last?.arguments.first == "lock", "The vault is locked again")
        precondition(fake.calls.allSatisfy { call in !call.arguments.contains { $0.contains("example-") } },
                     "Passwords and session keys never go in arguments")
        precondition(fake.calls.filter { $0.environment[BitwardenCLI.passwordVariable] != nil }.map { $0.arguments[0] } == ["unlock"],
                     "Only unlock sees the password")
        let indexText = try String(contentsOf: indexURL, encoding: .utf8)
        precondition(!indexText.contains("example-token-value") && indexText.contains("SERVICE_TOKEN"), "The index holds names only")
        let index = SecretIndex.load(from: indexURL)!
        precondition(index.lastSync != nil && index.lastError == nil && index.items.map(\.name) == ["service"])
        let mode = (try FileManager.default.attributesOfItem(atPath: indexURL.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600)

        // Import: new items are created, existing ones left alone unless asked to update.
        var changed = service
        changed.fields[1].value = "example-rotated-value"
        let newItem = exampleItems["proxy-token"]!
        let imported = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password },
                                          importing: [changed, newItem], indexURL: indexURL)
        precondition(imported.created == ["proxy-token"] && imported.existing == ["service"], "\(imported)")
        let unchanged = try store.item("service")?.field("SERVICE_TOKEN")?.value
        precondition(unchanged == "example-token-value", "Existing items aren't overwritten")
        let cachedToken = try store.item("proxy-token")
        precondition(cachedToken?.text == newItem.text)
        let updated = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password },
                                         importing: [changed], updateExisting: true, indexURL: indexURL)
        let rotated = try store.item("service")?.field("SERVICE_TOKEN")?.value
        precondition(updated.updated == ["service"] && rotated == "example-rotated-value")

        // Gone from Bitwarden: gone from the cache. An emptied folder keeps the cache.
        fake.items.removeAll { $0["name"] as? String == "proxy-token" }
        let pruned = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL)
        let afterPrune = try store.names()
        precondition(pruned.removed == ["proxy-token"] && afterPrune == ["service"])
        fake.items.removeAll()
        let kept = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL)
        let afterEmpty = try store.names()
        precondition(kept.kept == ["service"] && afterEmpty == ["service"])

        // A missing folder is an error when syncing; importing creates it.
        fake.folders.removeAll()
        do { _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL); fatalError() }
        catch let failure as BitwardenCLI.Failure { precondition(failure.message.contains("no folder")) }
        _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, importing: [newItem], indexURL: indexURL)
        precondition(fake.folders.count == 1)

        let held = try SecretSync.SyncLock(SecretIndex.lockFile(for: indexURL))
        do { _ = try SecretSync.run(bitwarden: fake.cli, store: store, password: { fake.password }, indexURL: indexURL); fatalError() }
        catch let failure as BitwardenCLI.Failure { precondition(failure.message.contains("already running")) }
        held.release()
    }

    /// Runs a command through the runner and returns its exit status and what it printed.
    static func run(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let output = Pipe(), errors = Pipe()
        let plan = try SecretRunPlan.parse(arguments)
        let status = try SecretRunner.execute(plan, items: exampleItems, output: output.fileHandleForWriting.fileDescriptor,
                                              errors: errors.fileHandleForWriting.fileDescriptor)
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        return (status, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func testRunner() throws {
        let echoed = try run(["service", "TOKEN=proxy-token", "--", "/bin/sh", "-c",
                              "printf '%s %s\\n' \"$SERVICE_URL\" \"$SERVICE_TOKEN\"; printf '%s' \"$TOKEN\" >&2; exit 7"])
        precondition(echoed.status == 7, "The command's exit status passes through")
        precondition(echoed.output == "https://service.example [secret:service.SERVICE_TOKEN]\n", echoed.output)
        precondition(echoed.errors == "[secret:proxy-token]", "Standard error is masked too: \(echoed.errors)")

        setenv("EXPECTED_ACCOUNT", exampleItems["account"]!.text!, 1)
        setenv("EXPECTED_QUOTED", exampleItems["quoted"]!.fields[0].value, 1)
        defer { unsetenv("EXPECTED_ACCOUNT"); unsetenv("EXPECTED_QUOTED") }
        let piped = try run(["--file", "ACCOUNT_FILE=account", "--env-file", "QUOTED_ENV=quoted", "--", "/bin/sh", "-c",
                             "[ \"$(cat \"$ACCOUNT_FILE\"; printf x)\" = \"${EXPECTED_ACCOUNT}x\" ] && echo file-ok; "
                             + ". \"$QUOTED_ENV\"; [ \"$QUOTED_PASS\" = \"$EXPECTED_QUOTED\" ] && echo env-ok; "
                             + "[ -p \"$ACCOUNT_FILE\" ] && echo pipe; [ -f \"$QUOTED_ENV\" ] && stat -f %Lp \"$QUOTED_ENV\"; echo \"$ACCOUNT_FILE\""])
        let lines = piped.output.split(separator: "\n").map(String.init)
        precondition(lines.prefix(4) == ["file-ok", "env-ok", "pipe", "600"], "OUT[" + piped.output + "] ERR[" + piped.errors + "]")
        precondition(!FileManager.default.fileExists(atPath: lines[4]), "The pipe is removed when the command ends")

        let temporary = try run(["--temp-files", "--file", "ACCOUNT_FILE=account", "--", "/bin/sh", "-c",
                                 "cat \"$ACCOUNT_FILE\" >/dev/null; [ \"$(cat \"$ACCOUNT_FILE\"; printf x)\" = \"${EXPECTED_ACCOUNT}x\" ] && echo twice; "
                                 + "stat -f %Lp \"$ACCOUNT_FILE\"; echo \"$ACCOUNT_FILE\""])
        let temporaryLines = temporary.output.split(separator: "\n").map(String.init)
        precondition(temporaryLines.prefix(2) == ["twice", "600"], temporary.output + temporary.errors)
        precondition(!FileManager.default.fileExists(atPath: temporaryLines[2]), "Temporary files are deleted when the command ends")

        let signalled = try run(["service", "--", "/bin/sh", "-c", "kill -TERM $$"])
        precondition(signalled.status == 128 + SIGTERM, "A signal exit is reported like a shell does")

        do { _ = try run(["service", "--", "no-such-command-anywhere"]); fatalError() }
        catch let failure as SecretCLI.Failure { precondition(failure.code == 127) }

        let store = SecretKeychain.Store.memory()
        do { _ = try SecretRunner.run(try SecretRunPlan.parse(["service", "--", "/usr/bin/true"]), store: store); fatalError() }
        catch let failure as SecretCLI.Failure { precondition(failure.message.contains("cantrip secret sync")) }
    }
}
