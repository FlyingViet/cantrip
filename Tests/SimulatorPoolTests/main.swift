import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    let passed: Bool
    do { passed = try condition() } catch {
        failures += 1
        fputs("FAIL: \(message) (threw \(error))\n", stderr)
        return
    }
    if !passed {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

/// An in-memory `simctl`: devices, device types and runtimes, recording every change.
final class FakeSimctl: @unchecked Sendable {
    struct Entry {
        var udid: String
        var name: String
        var state = "Shutdown"
        var type: String
        var runtime: String
        var available = true
        var bytes: Int64 = 0
        var lastUsed: Date?
    }

    private let lock = NSLock()
    var devices: [Entry] = []
    var calls: [[String]] = []
    let types = [("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "iPhone Duo"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "iPhone 17 Pro"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max", "iPhone 17 Pro Max"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPhone-17", "iPhone 17"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "iPhone 18 Pro"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPad-A16", "iPad (A16)"),
                 ("com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB", "iPad Pro 11-inch (M5)"),
                 ("com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", "Apple Watch Series 11 (46mm)"),
                 ("com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K", "Apple TV 4K (3rd generation)")]
    /// As installed on the Mac: iOS 27.1 and 27.2 (betas) run only the iPhone Duo, which 26.5 and 27.0 don't.
    let runtimes = [("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5", "iOS"),
                    ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "27.0", "iOS"),
                    ("com.apple.CoreSimulator.SimRuntime.iOS-27-1", "27.1", "iOS"),
                    ("com.apple.CoreSimulator.SimRuntime.iOS-27-2", "27.2", "iOS"),
                    ("com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "27.0", "watchOS"),
                    ("com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "27.0", "tvOS")]
    private var counter = 0

    static let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    static let pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    static let proMax = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
    static let iPhone17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    static let iPadPro = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"
    static let ios272 = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    static let ios271 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
    static let ios270 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    static let ios265 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

    func supported(by runtime: (String, String, String)) -> [String] {
        types.map(\.0).filter { type in
            switch runtime.2 {
            case "watchOS": return type.contains("Watch")
            case "tvOS": return type.contains("TV")
            default:
                guard type.contains("iPhone") || type.contains("iPad") else { return false }
                return type == FakeSimctl.duo ? runtime.1 >= "27.1" : runtime.1 < "27.1"
            }
        }
    }

    func entry(_ udid: String) -> Entry? { lock.withLock { devices.first { $0.udid == udid } } }
    func mutations() -> [[String]] { lock.withLock { calls.filter { $0.first != "list" } } }
    func update(_ udid: String, _ change: (inout Entry) -> Void) {
        lock.withLock { if let index = devices.firstIndex(where: { $0.udid == udid }) { change(&devices[index]) } }
    }

    var simctl: SimulatorPool.Simctl { SimulatorPool.Simctl { [self] in try run($0) } }

    private func run(_ arguments: [String]) throws -> Data {
        try lock.withLock {
            calls.append(arguments)
            func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
            func fail(_ text: String) -> SimulatorPool.Failure { SimulatorPool.Failure(message: text) }
            switch arguments.first {
            case "list":
                switch arguments[1] {
                case "devices":
                    var lists: [String: [[String: Any]]] = [:]
                    for device in devices {
                        var entry: [String: Any] = ["udid": device.udid, "name": device.name, "state": device.state,
                                                    "deviceTypeIdentifier": device.type, "isAvailable": device.available,
                                                    "dataPathSize": device.bytes]
                        if let used = device.lastUsed { entry["lastUsedAt"] = ISO8601DateFormatter().string(from: used) }
                        lists[device.runtime, default: []].append(entry)
                    }
                    return try json(["devices": lists])
                case "devicetypes":
                    return try json(["devicetypes": types.map { ["identifier": $0.0, "name": $0.1] }])
                default:
                    return try json(["runtimes": runtimes.map { runtime in
                        ["identifier": runtime.0, "version": runtime.1, "name": "\(runtime.2) \(runtime.1)", "isAvailable": true,
                         "supportedDeviceTypes": supported(by: runtime).map { ["identifier": $0] }] as [String: Any]
                    }])
                }
            case "create":
                counter += 1
                let udid = String(format: "00000000-0000-0000-0000-%012d", counter)
                devices.append(Entry(udid: udid, name: arguments[1], type: arguments[2], runtime: arguments[3]))
                return Data((udid + "\n").utf8)
            case "clone":
                guard let source = devices.first(where: { $0.udid == arguments[1] }) else { throw fail("no source") }
                guard source.state == "Shutdown" else { throw fail("Unable to clone device in current state: Booted") }
                counter += 1
                let udid = String(format: "00000000-0000-0000-0001-%012d", counter)
                var copy = source
                copy.udid = udid
                copy.name = arguments[2]
                devices.append(copy)
                return Data((udid + "\n").utf8)
            case "shutdown":
                guard let index = devices.firstIndex(where: { $0.udid == arguments[1] }), devices[index].state == "Booted" else {
                    throw fail("Unable to shutdown device in current state: Shutdown")
                }
                devices[index].state = "Shutdown"
                return Data()
            case "rename":
                guard let index = devices.firstIndex(where: { $0.udid == arguments[1] }) else { throw fail("no device") }
                devices[index].name = arguments[2]
                return Data()
            case "erase":
                guard let index = devices.firstIndex(where: { $0.udid == arguments[1] }) else { throw fail("no device") }
                guard devices[index].state == "Shutdown" else { throw fail("booted") }
                devices[index].bytes = 0
                return Data()
            case "delete":
                if arguments[1] == "unavailable" {
                    devices.removeAll { !$0.available }
                } else {
                    guard let index = devices.firstIndex(where: { $0.udid == arguments[1] }) else { throw fail("no device") }
                    devices.remove(at: index)
                }
                return Data()
            default:
                throw fail("unexpected \(arguments)")
            }
        }
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-simulator-pool-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let now = Date()
let day: TimeInterval = 86_400
func context(_ fake: FakeSimctl, lines: [String] = [], at time: Date = now, folder: String = "state") -> SimulatorPool.Context {
    var context = SimulatorPool.Context()
    context.store = SimulatorPool.Store(directory: root.appendingPathComponent(folder))
    context.simctl = fake.simctl
    context.commandLines = { lines }
    context.now = { time }
    context.policy = SimulatorPool.Policy()
    return context
}

// MARK: - Resolving device types and runtimes

do {
    let fake = FakeSimctl()
    let types = try fake.simctl.deviceTypes(), runtimes = try fake.simctl.runtimes()
    let duo = try SimulatorPool.resolveType("iphone duo", in: types)
    expect(duo.name == "iPhone Duo", "device types match by name, any case")
    expect((try? SimulatorPool.resolveType("17 Pro", in: types)) == nil, "an ambiguous name is refused")
    let ipad = try SimulatorPool.resolveType("iPad (", in: types)
    expect(ipad.name == "iPad (A16)", "a unique partial name matches")
    let newest = try SimulatorPool.resolveRuntime(nil, for: duo, in: runtimes)
    expect(newest.version == "27.2", "the newest runtime by default")
    let pro = try SimulatorPool.resolveType("iPhone 17 Pro", in: types)
    let named = try SimulatorPool.resolveRuntime("iOS 27.0", for: pro, in: runtimes)
    expect(named.version == "27.0", "runtimes match by name")
    expect(try SimulatorPool.resolveRuntime(nil, for: pro, in: runtimes).version == "27.0",
           "the newest runtime that runs the device, not a Duo-only beta")
    let major = try SimulatorPool.resolveRuntime("27", for: duo, in: runtimes)
    expect(major.version == "27.2", "a major version takes its newest")
    expect((try? SimulatorPool.resolveRuntime("25.0", for: duo, in: runtimes)) == nil, "a missing runtime is refused")
} catch {
    expect(false, "resolving threw \(error)")
}

// MARK: - Mapping requests onto the pool

do {
    let fake = FakeSimctl()
    let types = try fake.simctl.deviceTypes(), runtimes = try fake.simctl.runtimes()
    let policy = SimulatorPool.Policy()
    func resolve(_ device: String, _ os: String? = nil, exact: Bool = false,
                 pool: [SimulatorPool.Member] = []) throws -> SimulatorPool.Target {
        try SimulatorPool.resolve(device: device, os: os, exact: exact, types: types, runtimes: runtimes, pool: pool, policy: policy)
    }
    for (device, os) in [("iPhone 18 Pro", nil), ("iPhone 17", "26.5"), ("iPhone 17 Pro Max", "27.0"), ("iPhone 12", nil),
                         ("iPhone 17 Pro", "26.5")] as [(String, String?)] {
        let target = try resolve(device, os)
        expect(target.key == "iPhone 17 Pro|27.0" && !target.temporaryOnly,
               "\(device) \(os ?? "") resolves to the pool's iPhone 17 Pro on iOS 27.0; got \(target.key)")
        expect(target.note?.contains("one layout") == true && target.note?.contains("--exact") == true,
               "and says which simulator it got and how to get that model: \(target.note ?? "nil")")
    }
    expect(try resolve("iPhone 17 Pro").note == nil && (try resolve("iphone", "27.0")).note == nil,
           "asking for the pool's iPhone itself needs no note")
    var bigPhone = policy
    bigPhone.phone = "iPhone 17 Pro Max"
    let configured = try SimulatorPool.resolve(device: "iPhone 17", os: nil, exact: false, types: types, runtimes: runtimes,
                                               pool: [], policy: bigPhone)
    expect(configured.key == "iPhone 17 Pro Max|27.0", "the pool's iPhone is a setting")
    var missing = policy
    missing.phone = "iPhone 99"
    expect((try? SimulatorPool.resolve(device: "iPhone", os: nil, exact: false, types: types, runtimes: runtimes,
                                       pool: [], policy: missing)) == nil, "a pool iPhone that isn't installed is refused")

    expect(try resolve("iPhone Duo").key == "iPhone Duo|27.1", "the Duo defaults to iOS 27.1")
    expect(try resolve("iPhone Duo", "27.2").key == "iPhone Duo|27.2", "and keeps a simulator per iOS version")
    var newDuo = policy
    newDuo.duoOS = "26.0"
    expect(try SimulatorPool.resolve(device: "Duo", os: nil, exact: false, types: types, runtimes: runtimes, pool: [],
                                     policy: newDuo).key == "iPhone Duo|27.2", "a Duo default that isn't installed takes the newest")

    let iPadMember = SimulatorPool.Member(key: "iPad Pro 11-inch (M5)|27.0", udid: "IPAD")
    let air = try resolve("iPad (A16)", "26.5", pool: [iPadMember])
    expect(air.key == iPadMember.key && air.note?.contains("one iPad") == true, "an iPad request gets the pool's one iPad")
    expect(try resolve("iPad", pool: [iPadMember]).note == nil, "a plain “iPad” gets it without a note")
    expect(try resolve("iPad (A16)").key == "iPad (A16)|27.0", "with no iPad yet, the one asked for becomes the pool's")
    expect(try resolve("Apple Watch Series 11 (46mm)").key == "Apple Watch Series 11 (46mm)|27.0", "watches resolve to watchOS")
    expect(SimulatorPool.describe("Apple TV 4K (3rd generation)|27.0") == "Apple TV 4K (3rd generation), tvOS 27.0",
           "descriptions name the platform")

    let exact = try resolve("iPhone 18 Pro", "26.5", exact: true)
    expect(exact.key == "iPhone 18 Pro|26.5" && exact.temporaryOnly && exact.note == nil, "--exact keeps the model and OS asked for")
    let exactPooled = try resolve("iPhone Duo", "27.2", exact: true, pool: [.init(key: "iPhone Duo|27.2", udid: "DUO")])
    expect(!exactPooled.temporaryOnly, "--exact for a kind the pool keeps uses the pool's")
} catch {
    expect(false, "mapping threw \(error)")
}

// MARK: - Leasing

do {
    let fake = FakeSimctl()
    fake.devices = [
        .init(udid: "AAAA4778-0000-0000-0000-000000000000", name: "iPhone Duo", type: FakeSimctl.duo,
              runtime: FakeSimctl.ios272, bytes: 2_800_000_000, lastUsed: now.addingTimeInterval(-3_600)),
        .init(udid: "BBBB431D-0000-0000-0000-000000000000", name: "Maps-Duo-QA", type: FakeSimctl.duo,
              runtime: FakeSimctl.ios272, lastUsed: now.addingTimeInterval(-day)),
        .init(udid: "DUO27000-0000-0000-0000-000000000000", name: "iPhone Duo", type: FakeSimctl.duo,
              runtime: FakeSimctl.ios270, lastUsed: now),
    ]
    let c = context(fake)
    let first = try SimulatorPool.acquire(device: "iPhone Duo", os: "27.2", tab: "tab-a", context: c)
    expect(first.lease.udid.hasPrefix("AAAA4778") && !first.lease.temporary,
           "the most recently used simulator of that kind becomes the pool's")
    expect(fake.mutations().isEmpty, "adopting an existing simulator changes nothing in it")
    let again = try SimulatorPool.acquire(device: "iPhone Duo", os: "27.2", tab: "tab-a", context: c)
    expect(again.renewed && again.lease.id == first.lease.id, "the same tab gets its lease back")

    let second = try SimulatorPool.acquire(device: "iPhone Duo", os: "27.2", tab: "tab-b", context: c)
    expect(second.lease.temporary && second.lease.udid != first.lease.udid, "another tab gets a temporary copy")
    expect(fake.mutations().last?.first == "clone", "a shut-down pool simulator is cloned, keeping its apps")
    expect(fake.entry(second.lease.udid)?.name.hasPrefix(SimulatorPool.temporaryPrefix) == true, "copies are named as temporary")

    fake.update(first.lease.udid) { $0.state = "Booted" }
    let third = try SimulatorPool.acquire(device: "iPhone Duo", os: "27.2", tab: "tab-c", context: c)
    expect(third.lease.temporary && fake.mutations().last?.first == "create", "a booted pool simulator can't be cloned, so a new one is made")

    let state = c.store.read()
    expect(state.pool.count == 1 && state.leases.count == 3 && state.temporaries.count == 2, "one pool simulator, three leases")

    let ended = try SimulatorPool.release(tab: "tab-b", context: c)
    expect(ended.map(\.id) == [second.lease.id], "a tab's release ends only its own leases")
    expect(fake.entry(second.lease.udid) == nil, "a released temporary copy is deleted")
    expect(c.store.read().temporaries[second.lease.udid] == nil, "and forgotten")
    try SimulatorPool.release(third.lease.shortID, context: c)
    expect(fake.entry(third.lease.udid) == nil, "a lease can be released by its short ID")
    try SimulatorPool.release(tab: "tab-a", context: c)
    expect(fake.entry(first.lease.udid)?.state == "Shutdown", "a released pool simulator is shut down, not deleted")
    expect(c.store.read().leases.isEmpty, "no leases left")

    // A process naming the pool simulator's UDID is using it, lease or not.
    let busy = context(fake, lines: ["xcodebuild test -destination id=\(first.lease.udid)"])
    let copy = try SimulatorPool.acquire(device: "iPhone Duo", os: "27.2", tab: "tab-d", context: busy)
    expect(copy.lease.temporary, "a simulator a build is using isn't leased out")
    try SimulatorPool.release(tab: "tab-d", context: busy)

    // Nothing of that kind yet: the pool makes one.
    let made = try SimulatorPool.acquire(device: "iPhone 17 Pro", os: "27.0", tab: nil, context: c)
    expect(!made.lease.temporary && fake.entry(made.lease.udid)?.name == "Cantrip Pool · iPhone 17 Pro · iOS 27.0",
           "a missing pool simulator is created once, named for the pool")
    expect(made.lease.expiresAt.timeIntervalSince(now) == SimulatorPool.defaultLeaseHours * 3_600, "leases outside a tab expire")

    // An expired lease ends at the next acquire.
    let later = context(fake, at: now.addingTimeInterval(5 * 3_600))
    let reused = try SimulatorPool.acquire(device: "iPhone 17 Pro", os: "27.0", tab: nil, context: later)
    expect(!reused.lease.temporary && reused.lease.udid == made.lease.udid, "an expired lease frees the pool simulator")
    expect(c.store.read().leases.count == 1, "the expired lease is gone")
    try SimulatorPool.release(all: true, context: c)

    // Adopting makes a chosen simulator the pool's for its kind.
    let member = try SimulatorPool.adopt("bbbb431d-0000-0000-0000-000000000000", context: c)
    expect(member.key == "iPhone Duo|27.2" && c.store.read().pool.filter { $0.key == member.key }.count == 1,
           "adopt replaces the pool's simulator for that kind")
    expect(fake.entry(member.udid)?.name == "Cantrip Pool · iPhone Duo · iOS 27.2", "a project's simulator takes the pool's name")
    expect(fake.entry("AAAA4778-0000-0000-0000-000000000000")?.name == "iPhone Duo", "Xcode's default names stay")
} catch {
    expect(false, "leasing threw \(error)")
}

// MARK: - One iPhone for every iPhone request

do {
    let fake = FakeSimctl()
    fake.devices = [
        .init(udid: "CANON000-0000-0000-0000-000000000000", name: "Cantrip Pool · iPhone 17 Pro · iOS 27.0", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios270, bytes: 5_000_000_000, lastUsed: now.addingTimeInterval(-3_600)),
        .init(udid: "PRO18000-0000-0000-0000-000000000000", name: "iPhone 18 Pro",
              type: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime: FakeSimctl.ios270, lastUsed: now),
    ]
    let c = context(fake, folder: "canonical")
    let eighteen = try SimulatorPool.acquire(device: "iPhone 18 Pro", os: nil, tab: "tab-a", context: c)
    expect(eighteen.lease.udid.hasPrefix("CANON000") && !eighteen.lease.temporary,
           "an iPhone 18 Pro request gets the pool's iPhone 17 Pro; got \(eighteen.lease.udid)")
    expect(eighteen.description == "iPhone 17 Pro, iOS 27.0" && eighteen.note?.contains("iPhone 18 Pro") == true,
           "and the reply says which simulator it got: \(eighteen.note ?? "nil")")
    try SimulatorPool.release(tab: "tab-a", context: c)
    let seventeen = try SimulatorPool.acquire(device: "iPhone 17", os: "26.5", tab: "tab-b", context: c)
    expect(seventeen.lease.udid.hasPrefix("CANON000"), "an iPhone 17 request on iOS 26.5 gets the same simulator")
    try SimulatorPool.release(tab: "tab-b", context: c)
    expect(c.store.read().pool == [.init(key: "iPhone 17 Pro|27.0", udid: "CANON000-0000-0000-0000-000000000000")],
           "the pool keeps one iPhone; got \(c.store.read().pool)")

    let exact = try SimulatorPool.acquire(device: "iPhone 17 Pro Max", os: "26.5", exact: true, tab: "tab-c", context: c)
    expect(exact.lease.temporary && exact.lease.key == "iPhone 17 Pro Max|26.5", "--exact gives that model and OS")
    expect(fake.entry(exact.lease.udid)?.name.hasPrefix(SimulatorPool.temporaryPrefix) == true
           && fake.entry(exact.lease.udid)?.runtime == FakeSimctl.ios265, "as a temporary copy")
    expect(c.store.read().pool.count == 1, "never as a new pool member")
    let again = try SimulatorPool.acquire(device: "iPhone 17 Pro Max", os: "26.5", exact: true, tab: "tab-c", context: c)
    expect(again.renewed && again.lease.udid == exact.lease.udid, "asking again keeps the same copy")
    try SimulatorPool.release(tab: "tab-c", context: c)
    expect(fake.entry(exact.lease.udid) == nil && c.store.read().temporaries.isEmpty, "the copy is deleted on release")

    expect((try? SimulatorPool.adopt("PRO18000-0000-0000-0000-000000000000", context: c)) == nil,
           "another iPhone can't become the pool's")
    expect(c.store.read().pool.count == 1, "so the pool still has one iPhone")
} catch {
    expect(false, "one iPhone threw \(error)")
}

// MARK: - Two tabs at once

if true {
    let fake = FakeSimctl()
    fake.devices = [.init(udid: "POOLPRO0-0000-0000-0000-000000000000", name: "iPhone 17 Pro", type: FakeSimctl.pro,
                          runtime: FakeSimctl.ios270, lastUsed: now)]
    let c = context(fake, folder: "parallel")
    var results: [SimulatorPool.Acquired?] = [nil, nil]
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 2) { index in
        let acquired = try? SimulatorPool.acquire(device: "iPhone 17 Pro", os: "27.0", tab: "tab-\(index)", context: c)
        lock.withLock { results[index] = acquired }
    }
    let udids = Set(results.compactMap { $0?.lease.udid })
    expect(udids.count == 2, "two tabs acquiring at once get different simulators")
    expect(results.compactMap { $0 }.filter(\.lease.temporary).count == 1, "one gets the pool's, the other a copy")
}

// MARK: - Cleanup

do {
    let fake = FakeSimctl()
    let gb: Int64 = 1_000_000_000
    fake.devices = [
        .init(udid: "POOLBOOT-0000-0000-0000-000000000000", name: "iPhone Duo", state: "Booted", type: FakeSimctl.duo,
              runtime: FakeSimctl.ios272, bytes: 2 * gb, lastUsed: now.addingTimeInterval(-2 * 3_600)),
        .init(udid: "POOLBIG0-0000-0000-0000-000000000000", name: "iPhone 17 Pro", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios270, bytes: 12 * gb, lastUsed: now.addingTimeInterval(-day)),
        .init(udid: "POOLLEAS-0000-0000-0000-000000000000", name: "iPhone 17 Pro", state: "Booted", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios272, bytes: 15 * gb, lastUsed: now.addingTimeInterval(-5 * day)),
        .init(udid: "TEMPOLD0-0000-0000-0000-000000000000", name: "Cantrip Temp · iPhone Duo · iOS 27.2 · ab12",
              type: FakeSimctl.duo, runtime: FakeSimctl.ios272, bytes: gb, lastUsed: now.addingTimeInterval(-2 * day)),
        .init(udid: "TEMPNEW0-0000-0000-0000-000000000000", name: "Cantrip Temp · iPhone Duo · iOS 27.2 · cd34",
              type: FakeSimctl.duo, runtime: FakeSimctl.ios272, bytes: gb, lastUsed: now.addingTimeInterval(-3_600)),
        .init(udid: "NAMEDOLD-0000-0000-0000-000000000000", name: "Reader-iPhone-Duo", type: FakeSimctl.duo,
              runtime: FakeSimctl.ios272, bytes: 6 * gb, lastUsed: now.addingTimeInterval(-5 * day)),
        .init(udid: "NAMEDNEW-0000-0000-0000-000000000000", name: "loading-qa", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios270, bytes: 3 * gb, lastUsed: now.addingTimeInterval(-day)),
        .init(udid: "NAMEDBOT-0000-0000-0000-000000000000", name: "Links QA", state: "Booted", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios270, bytes: gb, lastUsed: now.addingTimeInterval(-9 * day)),
        .init(udid: "NAMEDUSE-0000-0000-0000-000000000000", name: "Shop UI QA", type: FakeSimctl.pro,
              runtime: FakeSimctl.ios270, bytes: gb, lastUsed: now.addingTimeInterval(-9 * day)),
        .init(udid: "DEFAULTD-0000-0000-0000-000000000000", name: "iPhone 17 Pro", type: FakeSimctl.pro,
              runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", bytes: gb / 2, lastUsed: now.addingTimeInterval(-9 * day)),
        .init(udid: "DEFAULTE-0000-0000-0000-000000000000", name: "iPad (A16)", type: "com.apple.CoreSimulator.SimDeviceType.iPad-A16",
              runtime: FakeSimctl.ios270, bytes: 1_000_000, lastUsed: now.addingTimeInterval(-90 * day)),
        .init(udid: "GONE0000-0000-0000-0000-000000000000", name: "Old iPhone", type: FakeSimctl.pro,
              runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0", available: false, bytes: 2 * gb,
              lastUsed: now.addingTimeInterval(-90 * day)),
    ]
    let c = context(fake, lines: ["maestro test --device NAMEDUSE-0000-0000-0000-000000000000 flow.yaml"], folder: "sweep")
    try c.store.locked { state in
        state.pool = [.init(key: "iPhone Duo|27.2", udid: "POOLBOOT-0000-0000-0000-000000000000"),
                      .init(key: "iPhone 17 Pro|27.0", udid: "POOLBIG0-0000-0000-0000-000000000000"),
                      .init(key: "iPhone 17 Pro|27.2", udid: "POOLLEAS-0000-0000-0000-000000000000")]
        state.leases = [.init(id: "lease-live", udid: "POOLLEAS-0000-0000-0000-000000000000", key: "iPhone 17 Pro|27.2",
                              temporary: false, tab: "tab-x", acquiredAt: now, expiresAt: now.addingTimeInterval(3_600))]
        state.temporaries = ["TEMPOLD0-0000-0000-0000-000000000000": now.addingTimeInterval(-2 * day),
                             "TEMPNEW0-0000-0000-0000-000000000000": now.addingTimeInterval(-3_600)]
    }
    func actions(_ report: SimulatorPool.SweepReport) -> [String: SimulatorPool.Action.Kind] {
        Dictionary(report.actions.map { (String($0.udid.prefix(8)), $0.kind) }, uniquingKeysWith: { a, _ in a })
    }
    let before = c.store.read()

    // Only what the pool made, by default.
    let pooled = SimulatorPool.sweep(SimulatorPool.SweepOptions(), dryRun: true, context: c)
    expect(actions(pooled) == ["POOLBOOT": .shutDown, "POOLBIG0": .erased, "TEMPOLD0": .deleted],
           "pool sweep: shut down a free booted pool simulator, erase one over the cap, delete an old copy; got \(actions(pooled))")
    expect(fake.mutations().isEmpty && c.store.read() == before, "a dry run changes nothing")

    var everything = SimulatorPool.SweepOptions()
    everything.includeUnmanaged = true
    let preview = SimulatorPool.sweep(everything, dryRun: true, context: c)
    expect(actions(preview) == ["POOLBOOT": .shutDown, "POOLBIG0": .erased, "TEMPOLD0": .deleted,
                                "NAMEDOLD": .deleted, "DEFAULTD": .erased, "GONE0000": .deleted],
           "with other simulators: delete named ones unused 3 days and ones without a runtime, empty Xcode's defaults; got \(actions(preview))")
    expect(preview.bytesRemoved == (12 + 1 + 6 + 2) * gb + gb / 2, "space counts deleted and erased data")
    expect(preview.simulators == 12 && preview.leased == 1, "the report counts simulators and leases")
    expect(fake.mutations().isEmpty, "still nothing changed")

    let real = SimulatorPool.sweep(everything, dryRun: false, context: c)
    expect(actions(real) == actions(preview), "the real run does what the dry run listed")
    expect(real.errors.isEmpty, "no errors: \(real.errors)")
    let left = Set(fake.devices.map { String($0.udid.prefix(8)) })
    expect(left == ["POOLBOOT", "POOLBIG0", "POOLLEAS", "TEMPNEW0", "NAMEDNEW", "NAMEDBOT", "NAMEDUSE", "DEFAULTD", "DEFAULTE"],
           "kept: pool simulators, a new copy, recent, booted and in-use ones, Xcode's defaults; got \(left.sorted())")
    expect(fake.entry("POOLBOOT-0000-0000-0000-000000000000")?.state == "Shutdown", "the free pool simulator was shut down")
    expect(fake.entry("POOLBIG0-0000-0000-0000-000000000000")?.bytes == 0, "the big pool simulator was erased")
    expect(fake.entry("POOLLEAS-0000-0000-0000-000000000000")?.state == "Booted", "a leased simulator is never touched")
    expect(fake.entry("DEFAULTD-0000-0000-0000-000000000000")?.bytes == 0, "a default simulator with data was emptied")
    expect(c.store.read().temporaries.keys.sorted() == ["TEMPNEW0-0000-0000-0000-000000000000"], "the deleted copy is forgotten")
    expect(fake.mutations().contains(["delete", "unavailable"]), "simulators without a runtime go through simctl")
} catch {
    expect(false, "sweep threw \(error)")
}

if failures > 0 {
    fputs("\(failures) simulator pool test(s) failed\n", stderr)
    exit(1)
}
print("Simulator pool: leases, temporary copies, parallel tabs and cleanup passed")
