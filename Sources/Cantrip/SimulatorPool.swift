import Darwin
import Foundation

/// Simulators shared by agent tabs, so tabs testing at the same time never drive the same one and
/// per-task simulators don't pile up. The pool stays small: iPhone apps have one layout, so every
/// iPhone request shares one iPhone (`Policy.phone`); the iPhone Duo folds, so it keeps one per iOS
/// version; and there is one iPad, Apple Watch and Apple TV. `cantrip sim acquire` leases the
/// pool's simulator to a tab, or makes a temporary copy when another tab holds it (`--exact` for a
/// model or OS the pool doesn't keep). Releasing (or the tab's turn ending) shuts it down and
/// deletes a temporary copy. `sweep`, run by `StorageUpkeep`, cleans up what was left behind.
enum SimulatorPool {
    /// Names of simulators the pool makes. Adopted ones keep their names.
    static let poolPrefix = "Cantrip Pool"
    static let temporaryPrefix = "Cantrip Temp"
    /// A tab's lease ends with its turn; this only bounds one whose host stopped watching.
    static let tabLeaseHours = 12.0
    static let defaultLeaseHours = 4.0

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Policy

    /// What the pool hands out; settings of the same names (`cantrip config set simulatorPoolPhone …`).
    struct Policy: Equatable {
        /// Every iPhone request but the Duo's gets this model: iPhone apps have one layout.
        var phone = "iPhone 17 Pro"
        /// Its iOS version; empty for the newest installed one that runs it.
        var phoneOS = ""
        /// The iPhone Duo's iOS version when a request names none (each version has its own simulator).
        var duoOS = "27.1"
        /// Pool and temporary simulators booted at once; a leased one counts before it boots.
        var maxBooted = 2
        /// Nothing new boots while free plus compressible memory is below this (GB; 0 turns it off)
        /// or macOS reports memory pressure.
        var minFreeMemoryGB = 4
        /// How long `acquire` waits in line for room before giving up.
        var waitMinutes = 10
        /// Seconds between checks while waiting.
        var pollSeconds = 3.0
        /// A pool simulator or temporary copy booted this long with no lease and nothing using it
        /// is shut down.
        var idleMinutes = 15

        enum Key {
            static let phone = "simulatorPoolPhone"
            static let phoneOS = "simulatorPoolPhoneOS"
            static let duoOS = "simulatorPoolDuoOS"
            static let maxBooted = "simulatorPoolMaxBooted"
            static let minFreeMemoryGB = "simulatorPoolMinFreeMemoryGB"
            static let waitMinutes = "simulatorPoolWaitMinutes"
            static let idleMinutes = "simulatorPoolIdleMinutes"
        }

        static let maxBootedRange = 1...8
        static let minFreeMemoryRange = 0...64
        static let waitRange = 0...120
        static let idleRange = 5...1_440

        static func standard(_ defaults: UserDefaults = .standard) -> Policy {
            var policy = Policy()
            func text(_ key: String) -> String? { defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces) }
            func number(_ key: String, _ range: ClosedRange<Int>) -> Int? {
                (defaults.object(forKey: key) as? NSNumber).map { min(max($0.intValue, range.lowerBound), range.upperBound) }
            }
            if let phone = text(Key.phone), !phone.isEmpty { policy.phone = phone }
            if let os = text(Key.phoneOS) { policy.phoneOS = os }
            if let os = text(Key.duoOS) { policy.duoOS = os }
            if let value = number(Key.maxBooted, maxBootedRange) { policy.maxBooted = value }
            if let value = number(Key.minFreeMemoryGB, minFreeMemoryRange) { policy.minFreeMemoryGB = value }
            if let value = number(Key.waitMinutes, waitRange) { policy.waitMinutes = value }
            if let value = number(Key.idleMinutes, idleRange) { policy.idleMinutes = value }
            return policy
        }
    }

    /// The Mac's memory, checked before another simulator may boot.
    struct Memory: Equatable {
        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        var pressureLevel: Int
        /// Free plus compressible memory: `kern.memorystatus_level` (what `memory_pressure` calls
        /// "System-wide memory free percentage") of physical memory.
        var availableBytes: Int64

        static let unknown = Memory(pressureLevel: 1, availableBytes: .max)

        var isUnderPressure: Bool { pressureLevel >= 2 }

        static func current() -> Memory {
            guard let percent = sysctl("kern.memorystatus_level"), let total = sysctl("hw.memsize"), total > 0 else {
                return .unknown
            }
            return Memory(pressureLevel: Int(sysctl("kern.memorystatus_vm_pressure_level") ?? 1),
                          availableBytes: total / 100 * percent)
        }

        private static func sysctl(_ name: String) -> Int64? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == 4 || size == 8 else { return nil }
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            // A 4-byte value fills the low half (little-endian), sign-extended here.
            return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
        }
    }

    /// Kinds of simulator the pool keeps one of. The iPhone Duo folds, so each of its iOS versions
    /// keeps its own; other iPhones share one, and so do iPads, watches and TVs. Anything else
    /// (Apple Vision Pro) keeps one per device type and OS version.
    enum Family: Hashable {
        case phone, duo, tablet, watch, tv
        case other(String)

        init(deviceName name: String) {
            let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
            if lower.hasPrefix("iphone") || lower == "duo" {
                self = lower.contains("duo") ? .duo : .phone
            } else if lower.hasPrefix("ipad") {
                self = .tablet
            } else if lower.hasPrefix("apple watch") || lower.hasPrefix("watch") {
                self = .watch
            } else if lower.hasPrefix("apple tv") {
                self = .tv
            } else {
                self = .other(lower)
            }
        }

        /// The family of a pool key ("iPhone Duo|27.2").
        init(key: String) { self.init(deviceName: SimulatorPool.typeName(ofKey: key)) }

        /// One simulator per device type and OS version rather than one for the whole family.
        var perVersion: Bool {
            switch self {
            case .duo, .other: return true
            case .phone, .tablet, .watch, .tv: return false
            }
        }

        var platform: String {
            switch self {
            case .watch: return "watchOS"
            case .tv: return "tvOS"
            case .other(let name) where name.hasPrefix("apple vision"): return "visionOS"
            default: return "iOS"
            }
        }

        var label: String {
            switch self {
            case .phone: return "iPhone"
            case .duo: return "iPhone Duo"
            case .tablet: return "iPad"
            case .watch: return "Apple Watch"
            case .tv: return "Apple TV"
            case .other(let name): return name
            }
        }
    }

    // MARK: - Simulators

    struct Device: Equatable {
        var udid: String
        var name: String
        var state: String
        var typeIdentifier: String
        var runtimeIdentifier: String
        var isAvailable: Bool
        var dataBytes: Int64
        /// When it was last booted or shut down; for one never booted, when it was made.
        var lastUsed: Date?

        var isBooted: Bool { state == "Booted" }
    }

    struct DeviceType: Equatable {
        var identifier: String
        var name: String
    }

    struct Runtime: Equatable {
        var identifier: String
        /// "27.2"
        var version: String
        /// "iOS 27.2"
        var name: String
        var isAvailable: Bool
        var supportedTypes: Set<String>
    }

    /// `xcrun simctl`, replaceable in tests.
    struct Simctl {
        var run: ([String]) throws -> Data

        static let system = Simctl { arguments in
            let result = try ProcessRunner.run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: 600)
            guard result.succeeded else {
                let detail = result.errorText.isEmpty ? (result.timedOut ? "timed out" : "failed") : result.errorText
                throw Failure(message: "simctl \(arguments.prefix(2).joined(separator: " ")): \(detail)")
            }
            return result.output
        }

        private func json(_ arguments: [String]) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: try run(arguments)) as? [String: Any] else {
                throw Failure(message: "simctl \(arguments.joined(separator: " ")) returned no JSON.")
            }
            return object
        }

        func devices() throws -> [Device] {
            let lists = try json(["list", "devices", "-j"])["devices"] as? [String: [[String: Any]]] ?? [:]
            return lists.flatMap { runtime, devices in
                devices.compactMap { entry -> Device? in
                    guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { return nil }
                    var lastUsed = (entry["lastUsedAt"] as? String).flatMap { ISODate.date(from: $0) }
                    if lastUsed == nil, let data = entry["dataPath"] as? String {
                        let folder = (data as NSString).deletingLastPathComponent
                        lastUsed = (try? FileManager.default.attributesOfItem(atPath: folder))?[.creationDate] as? Date
                    }
                    return Device(udid: udid, name: name, state: entry["state"] as? String ?? "",
                                  typeIdentifier: entry["deviceTypeIdentifier"] as? String ?? "",
                                  runtimeIdentifier: runtime,
                                  isAvailable: entry["isAvailable"] as? Bool ?? false,
                                  dataBytes: (entry["dataPathSize"] as? NSNumber)?.int64Value ?? 0,
                                  lastUsed: lastUsed)
                }
            }
            .sorted { $0.udid < $1.udid }
        }

        func deviceTypes() throws -> [DeviceType] {
            (try json(["list", "devicetypes", "-j"])["devicetypes"] as? [[String: Any]] ?? []).compactMap {
                guard let identifier = $0["identifier"] as? String, let name = $0["name"] as? String else { return nil }
                return DeviceType(identifier: identifier, name: name)
            }
        }

        func runtimes() throws -> [Runtime] {
            (try json(["list", "runtimes", "-j"])["runtimes"] as? [[String: Any]] ?? []).compactMap {
                guard let identifier = $0["identifier"] as? String, let version = $0["version"] as? String else { return nil }
                let types = ($0["supportedDeviceTypes"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String }
                return Runtime(identifier: identifier, version: version, name: $0["name"] as? String ?? version,
                               isAvailable: $0["isAvailable"] as? Bool ?? false, supportedTypes: Set(types))
            }
        }

        func create(_ name: String, type: String, runtime: String) throws -> String {
            String(decoding: try run(["create", name, type, runtime]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func clone(_ udid: String, name: String) throws -> String {
            String(decoding: try run(["clone", udid, name]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Shutting down one that isn't booted fails harmlessly.
        func shutdown(_ udid: String) { _ = try? run(["shutdown", udid]) }
        func delete(_ udid: String) throws { _ = try run(["delete", udid]) }
        func erase(_ udid: String) throws { _ = try run(["erase", udid]) }
        func rename(_ udid: String, to name: String) throws { _ = try run(["rename", udid, name]) }
        func deleteUnavailable() throws { _ = try run(["delete", "unavailable"]) }
    }

    // MARK: - Pool and leases

    /// The pool's simulator for one kind ("iPhone 17 Pro|27.0", "iPhone Duo|27.2"): see `Family`.
    struct Member: Codable, Equatable {
        var key: String
        var udid: String
    }

    struct Lease: Codable, Equatable {
        var id: String
        var udid: String
        var key: String
        /// A copy made because the pool's simulator was busy; deleted on release.
        var temporary: Bool
        /// The Cantrip tab holding it (`CANTRIP_TAB_ID`): its turn ending releases it.
        var tab: String?
        var acquiredAt: Date
        var expiresAt: Date

        var shortID: String { String(id.prefix(8)) }
    }

    /// A process waiting in `acquire` for room, first come first served.
    struct Waiter: Codable, Equatable {
        var id: String
        var tab: String?
        var pid: Int32
        /// "iPhone 17 Pro, iOS 27.0"
        var wants: String
        var since: Date
        /// Refreshed on every check; one not seen for a while gave up.
        var seen: Date
    }

    struct State: Codable, Equatable {
        var pool: [Member] = []
        var leases: [Lease] = []
        /// Temporary copies the pool made, by UDID, with when.
        var temporaries: [String: Date] = [:]
        var waiting: [Waiter] = []

        init() {}

        // Older files lack newer fields; a missing one mustn't empty the pool.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pool = try container.decodeIfPresent([Member].self, forKey: .pool) ?? []
            leases = try container.decodeIfPresent([Lease].self, forKey: .leases) ?? []
            temporaries = try container.decodeIfPresent([String: Date].self, forKey: .temporaries) ?? [:]
            waiting = try container.decodeIfPresent([Waiter].self, forKey: .waiting) ?? []
        }

        func isTemporary(_ device: Device) -> Bool {
            temporaries[device.udid] != nil || device.name.hasPrefix(SimulatorPool.temporaryPrefix)
        }

        func member(_ udid: String) -> Member? { pool.first { $0.udid == udid } }
    }

    /// `~/.cache/Cantrip/simulators/pool.json`, shared by the host and `cantrip` commands under a lock.
    struct Store {
        var directory: URL

        static var standard: Store { Store(directory: CantripPaths.cache("simulators", isDirectory: true)) }

        var file: URL { directory.appendingPathComponent("pool.json") }

        func read() -> State {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: file)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
        }

        /// Runs `body` holding the lock and saves the state it leaves, even when it throws.
        func locked<T>(_ body: (inout State) throws -> T) throws -> T {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = open(directory.appendingPathComponent("pool.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw Failure(message: "Couldn't open the simulator pool's lock in \(directory.path).") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw Failure(message: "Couldn't lock the simulator pool.") }
            defer { flock(lock, LOCK_UN) }
            var state = read()
            let original = state
            defer {
                if state != original {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try? encoder.encode(state).write(to: file, options: .atomic)
                }
            }
            return try body(&state)
        }
    }

    /// What the pool works with; tests replace each part.
    struct Context {
        var store = Store.standard
        var simctl = Simctl.system
        /// Every running process's command line: one naming a simulator's UDID (xcodebuild,
        /// Maestro, simctl) is using it.
        var commandLines: () -> [String] = { StorageUpkeep.ProcessSnapshot.current().commandLines }
        var now: () -> Date = Date.init
        var policy = Policy.standard()
        var memory: () -> Memory = Memory.current
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var processID = getpid()
        var isRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    }

    /// For agents' system instructions: lease simulators instead of making them.
    static func agentGuidance(command: String) -> String {
        """
        Simulators on this Mac are shared and few. To run an app or tests in one, lease it: \
        `\(command) sim acquire --device iPhone` prints a UDID that's yours until your turn ends. \
        iPhone apps have one layout, so test them on that single pool iPhone: don't ask for a \
        particular iPhone model or iOS version unless the bug only happens there (then add \
        `--exact`, which makes a temporary copy). Only the iPhone Duo has a simulator per iOS \
        version (`--device 'iPhone Duo' [--os 27.1]`); iPad, Apple Watch and Apple TV have one each. \
        A tab has one simulator at a time (leasing another kind releases the first), and only a \
        couple run at once, so `acquire` may wait for one; don't work around it. \
        Use it only by UDID: `xcodebuild -destination 'id=UDID'`, `xcrun simctl boot UDID`, \
        `maestro --device UDID`. Never make simulators with `simctl create` or `simctl clone`, and \
        never delete or erase them. When you're done, `\(command) sim release` shuts it down (and \
        deletes a temporary copy); Cantrip also does this when your turn ends.
        """
    }

    static func key(type: DeviceType, runtime: Runtime) -> String { "\(type.name)|\(runtime.version)" }

    /// "iPhone Duo|27.2" → "iPhone Duo".
    static func typeName(ofKey key: String) -> String {
        String(key.split(separator: "|", maxSplits: 1).first ?? Substring(key))
    }

    /// "iPhone Duo|27.2" → "iPhone Duo, iOS 27.2".
    static func describe(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        return "\(parts[0]), \(Family(deviceName: parts[0]).platform) \(parts[1])"
    }

    static func resolveType(_ name: String, in types: [DeviceType]) throws -> DeviceType {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = types.first(where: { $0.name.lowercased() == wanted || $0.identifier.lowercased() == wanted }) {
            return exact
        }
        let close = types.filter { $0.name.lowercased().contains(wanted) }
        if close.count == 1 { return close[0] }
        let suggestions = (close.isEmpty ? types.filter { $0.name.hasPrefix("iPhone") || $0.name.hasPrefix("iPad") } : close)
            .prefix(12).map(\.name).joined(separator: ", ")
        throw Failure(message: "No single simulator device type is called “\(name)”. Try one of: \(suggestions).")
    }

    /// The installed runtime for `os` ("27.2", "iOS 27.2"), or the newest one that runs the device type.
    static func resolveRuntime(_ os: String?, for type: DeviceType, in runtimes: [Runtime]) throws -> Runtime {
        let usable = runtimes.filter { $0.isAvailable && $0.supportedTypes.contains(type.identifier) }
        guard let os = os?.trimmingCharacters(in: .whitespaces), !os.isEmpty else {
            guard let newest = usable.max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) else {
                throw Failure(message: "No installed simulator runtime runs \(type.name).")
            }
            return newest
        }
        let version = os.split(separator: " ").last.map(String.init) ?? os
        if let match = usable.first(where: { $0.version == version || $0.name.lowercased() == os.lowercased() })
            ?? usable.filter({ $0.version.hasPrefix(version + ".") })
                .max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) {
            return match
        }
        let installed = usable.map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        throw Failure(message: "\(type.name) has no installed runtime for \(os). Installed: \(installed.joined(separator: ", ")).")
    }

    /// Whether `os` ("27", "27.0", "iOS 27.0") names `runtime`.
    static func matches(_ os: String, _ runtime: Runtime) -> Bool {
        let os = os.trimmingCharacters(in: .whitespaces)
        let version = os.split(separator: " ").last.map(String.init) ?? os
        return runtime.version == version || runtime.name.lowercased() == os.lowercased()
            || runtime.version.hasPrefix(version + ".")
    }

    /// What a request gets.
    struct Target: Equatable {
        var type: DeviceType
        var runtime: Runtime
        var key: String
        /// A model or OS the pool doesn't keep, asked for with `exact`: a temporary copy.
        var temporaryOnly = false
        /// Why it isn't what was asked for.
        var note: String?
        /// The exact model and OS asked for, when they're installed: a tab already holding a lease
        /// on that (from `--exact`, or from before the pool kept one iPhone) keeps it.
        var askedKey: String?

        var description: String { "\(type.name), \(runtime.name)" }
    }

    /// The pool's iPhone: `Policy.phone` on `Policy.phoneOS` (the newest that runs it when empty).
    static func phone(_ policy: Policy, types: [DeviceType], runtimes: [Runtime]) throws -> (DeviceType, Runtime) {
        guard let type = try? resolveType(policy.phone, in: types) else {
            throw Failure(message: "The pool's iPhone, “\(policy.phone)” (the \(Policy.Key.phone) setting), isn't an "
                + "installed simulator device type. Set another: cantrip config set \(Policy.Key.phone) 'iPhone 17 Pro'.")
        }
        return (type, try resolveRuntime(policy.phoneOS.isEmpty ? nil : policy.phoneOS, for: type, in: runtimes))
    }

    /// Maps a request onto the pool: any iPhone but the Duo gets the pool's iPhone, an iPad, watch or
    /// TV gets the pool's one of those when it has one, and the Duo gets its simulator for that iOS
    /// version (`Policy.duoOS` when none is named). With `exact`, the model and OS asked for: the
    /// pool's when it keeps that kind, otherwise a temporary copy.
    static func resolve(device: String, os: String?, exact: Bool, types: [DeviceType], runtimes: [Runtime],
                        pool: [Member], policy: Policy) throws -> Target {
        let os = os.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        var family = Family(deviceName: device)
        var asked: DeviceType?
        if case .other = family {
            let type = try resolveType(device, in: types)
            asked = type
            family = Family(deviceName: type.name)
        }
        func duoRuntime(_ type: DeviceType) throws -> Runtime {
            if let os { return try resolveRuntime(os, for: type, in: runtimes) }
            if let chosen = try? resolveRuntime(policy.duoOS, for: type, in: runtimes) { return chosen }
            return try resolveRuntime(nil, for: type, in: runtimes)
        }
        func target(_ type: DeviceType, _ runtime: Runtime, note: String? = nil) -> Target {
            var chosen = Target(type: type, runtime: runtime, key: key(type: type, runtime: runtime), note: note)
            if let askedType = asked ?? (try? resolveType(device, in: types)),
               let askedRuntime = family == .duo ? try? duoRuntime(askedType) : try? resolveRuntime(os, for: askedType, in: runtimes) {
                chosen.askedKey = key(type: askedType, runtime: askedRuntime)
            }
            return chosen
        }
        // A family the pool keeps one of: its first member (in pool order) whose device type and
        // runtime are installed. `leaving` keeps the same one.
        func kept(_ family: Family) -> (Member, DeviceType, Runtime)? {
            for member in pool where Family(key: member.key) == family {
                if let type = types.first(where: { $0.name == typeName(ofKey: member.key) }),
                   let runtime = runtimes.first(where: {
                       $0.isAvailable && $0.supportedTypes.contains(type.identifier) && member.key == key(type: type, runtime: $0)
                   }) {
                    return (member, type, runtime)
                }
            }
            return nil
        }
        if exact {
            let type = try asked ?? resolveType(device, in: types)
            let runtime = family == .duo ? try duoRuntime(type) : try resolveRuntime(os, for: type, in: runtimes)
            var chosen = target(type, runtime)
            // The pool's own only if the pool keeps it; a member on its way out isn't handed out.
            let pooled: Bool
            switch family {
            case .phone:
                pooled = (try? phone(policy, types: types, runtimes: runtimes)).map { key(type: $0.0, runtime: $0.1) } == chosen.key
            case .tablet, .watch, .tv:
                pooled = kept(family)?.0.key == chosen.key
            case .duo, .other:
                pooled = pool.contains { $0.key == chosen.key }
            }
            chosen.temporaryOnly = !pooled
            return chosen
        }
        let askedFor = os.map { "\(device) on \($0)" } ?? device
        switch family {
        case .phone:
            let (type, runtime) = try phone(policy, types: types, runtimes: runtimes)
            let sameModel = device.trimmingCharacters(in: .whitespaces).lowercased() == type.name.lowercased()
                || device == type.identifier
            let differs = !sameModel && device.trimmingCharacters(in: .whitespaces).lowercased() != "iphone"
                || os.map { !matches($0, runtime) } == true
            return target(type, runtime, note: differs
                ? "Asked for \(askedFor). iPhone apps have one layout, so every iPhone request shares the pool's "
                    + "\(type.name), \(runtime.name). For a bug only that model or version shows, add --exact."
                : nil)
        case .duo:
            let type = try asked ?? resolveType(device, in: types)
            return target(type, try duoRuntime(type))
        case .tablet, .watch, .tv:
            if let (_, type, runtime) = kept(family) {
                let generic = device.trimmingCharacters(in: .whitespaces).lowercased() == family.label.lowercased()
                let same = (generic || (asked ?? (try? resolveType(device, in: types))) == type)
                    && os.map { matches($0, runtime) } != false
                return target(type, runtime, note: same ? nil
                    : "Asked for \(askedFor). The pool keeps one \(family.label): \(type.name), \(runtime.name). "
                        + "For a bug only that model or version shows, add --exact.")
            }
            let type = try asked ?? resolveType(device, in: types)
            return target(type, try resolveRuntime(os, for: type, in: runtimes))
        case .other:
            let type = try asked ?? resolveType(device, in: types)
            return target(type, try resolveRuntime(os, for: type, in: runtimes))
        }
    }

    struct Acquired: Codable {
        var lease: Lease
        var name: String
        /// "iPhone Duo, iOS 27.2"
        var description: String
        /// The tab already held this lease; it was renewed.
        var renewed = false
        /// How the request was mapped onto the pool, and what happened to the tab's other leases.
        var note: String?
        /// The tab's leases on other simulators, ended first: a tab has one at a time.
        var released: [Lease] = []
    }

    private enum Attempt {
        case acquired(Acquired)
        case waiting(String)
    }

    /// Leases a simulator for `device` on `os` (see `resolve`): the pool's own when it's free,
    /// otherwise a temporary copy. A tab asking again for the same kind gets its lease back; asking
    /// for another kind ends its other leases first, unless a running process still uses one.
    /// Nothing new boots past `Policy.maxBooted` or while memory is short: the request waits in
    /// line, first come first served, for up to `wait` seconds (`Policy.waitMinutes` when nil),
    /// telling `progress` why, and fails if no room comes.
    static func acquire(device: String, os: String?, exact: Bool = false, tab: String?, hours: Double? = nil,
                        wait: TimeInterval? = nil, context c: Context = Context(),
                        progress: (String) -> Void = { _ in }) throws -> Acquired {
        let types = try c.simctl.deviceTypes(), runtimes = try c.simctl.runtimes()
        let patience = max(wait ?? Double(c.policy.waitMinutes) * 60, 0)
        let start = c.now()
        let deadline = start.addingTimeInterval(patience)
        let waiter = Waiter(id: UUID().uuidString.lowercased(), tab: tab, pid: c.processID, wants: device, since: start, seen: start)
        var told: (reason: String, at: Date)?
        while true {
            let attempt = try c.store.locked { state in
                try attemptAcquire(device: device, os: os, exact: exact, tab: tab, hours: hours, types: types,
                                   runtimes: runtimes, waiter: waiter, queue: patience > 0, state: &state, context: c)
            }
            switch attempt {
            case .acquired(let acquired):
                return acquired
            case .waiting(let reason):
                let now = c.now()
                guard now < deadline else {
                    if patience > 0 { _ = try? c.store.locked { $0.waiting.removeAll { $0.id == waiter.id } } }
                    throw Failure(message: patience > 0
                        ? "No simulator came free in \(duration(patience)): \(reason) Try again later; "
                            + "`cantrip sim list` shows who has them."
                        : "No simulator is free right now: \(reason)")
                }
                if told == nil || (told?.reason != reason && now.timeIntervalSince(told!.at) >= 30) {
                    progress("Waiting for a simulator until \(deadline.formatted(date: .omitted, time: .shortened)): \(reason)")
                    told = (reason, now)
                }
                c.sleep(max(min(c.policy.pollSeconds, deadline.timeIntervalSince(now)), 0))
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds)) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }

    /// One try at `acquire`, holding the lock: a lease, or why it has to wait (then it's in line).
    private static func attemptAcquire(device: String, os: String?, exact: Bool, tab: String?, hours: Double?,
                                       types: [DeviceType], runtimes: [Runtime], waiter: Waiter, queue: Bool,
                                       state: inout State, context c: Context) throws -> Attempt {
        let target = try resolve(device: device, os: os, exact: exact, types: types, runtimes: runtimes,
                                 pool: state.pool, policy: c.policy)
        let (type, runtime, key, description) = (target.type, target.runtime, target.key, target.description)
        let now = c.now()
        var devices = try c.simctl.devices()
        reap(&state, now: now, simctl: c.simctl)
        let lifetime = (hours ?? (tab == nil ? defaultLeaseHours : tabLeaseHours)) * 3_600
        func done(_ acquired: Acquired) -> Attempt {
            state.waiting.removeAll { $0.id == waiter.id }
            return .acquired(acquired)
        }
        // The same kind again, or exactly the model and OS asked for (a lease from --exact, or from
        // before the pool kept one iPhone, stays the tab's while it works).
        let present = Set(devices.map(\.udid))
        let held = tab.flatMap { tab in
            state.leases.firstIndex { $0.tab == tab && $0.key == key && present.contains($0.udid) }
                ?? state.leases.firstIndex { $0.tab == tab && $0.key == target.askedKey && present.contains($0.udid) }
        }
        if let index = held {
            state.leases[index].expiresAt = now.addingTimeInterval(lifetime)
            let lease = state.leases[index]
            return done(Acquired(lease: lease, name: devices.first { $0.udid == lease.udid }?.name ?? "",
                                 description: lease.key == key ? description : describe(lease.key), renewed: true,
                                 note: lease.key == key ? target.note : nil))
        }
        let lines = c.commandLines()
        func inUse(_ udid: String) -> Bool { lines.contains { $0.contains(udid) } }
        // A tab has one simulator at a time: its others end first, unless a process still uses one.
        let others = tab.map { tab in state.leases.filter { $0.tab == tab && $0.key != key } } ?? []
        let ending = others.filter { !inUse($0.udid) }
        let kept = others.filter { inUse($0.udid) }
        let endingIDs = Set(ending.map(\.id))
        let staying = state.leases.filter { !endingIDs.contains($0.id) }

        let member = target.temporaryOnly ? nil
            : try poolMember(key: key, type: type, runtime: runtime, state: &state, devices: &devices, simctl: c.simctl)
        let reuse = member.flatMap { member in
            staying.contains { $0.udid == member.udid } || inUse(member.udid) ? nil : member.udid
        }

        // Room: the pool's and temporary simulators that are booted or leased, less the tab's ending ones.
        let snapshot = state
        let booted = Set(devices.filter { $0.isBooted && (snapshot.member($0.udid) != nil || snapshot.isTemporary($0)) }.map(\.udid))
        let before = Set(state.leases.map(\.udid)).union(booted)
        let freeing = Set(ending.map(\.udid)).subtracting(staying.map(\.udid))
        var occupied = Set(staying.map(\.udid)).union(booted).subtracting(freeing)
        let swapping = before.count > occupied.count
        if reuse.map({ !occupied.contains($0) }) ?? true, occupied.count >= c.policy.maxBooted, !swapping {
            // One booted with no lease and nothing using it past the idle time gives its room back.
            let idle = devices.filter { device in
                booted.contains(device.udid) && occupied.contains(device.udid) && !staying.contains { $0.udid == device.udid }
                    && !inUse(device.udid) && now.timeIntervalSince(device.lastUsed ?? .distantPast) >= Double(c.policy.idleMinutes) * 60
            }
            for device in idle where occupied.count >= c.policy.maxBooted {
                c.simctl.shutdown(device.udid)
                occupied.remove(device.udid)
            }
        }
        if reuse.map({ !occupied.contains($0) }) ?? true {
            var reasons: [String] = []
            if occupied.count >= c.policy.maxBooted, !swapping {
                let holders = occupied.sorted().map { udid -> String in
                    if let lease = staying.first(where: { $0.udid == udid }) {
                        return "\(describe(lease.key)) for " + (lease.tab.map { "tab \($0.prefix(8))" } ?? "a lease outside a tab")
                    }
                    return "\(devices.first { $0.udid == udid }?.name ?? udid), booted without a lease"
                }
                reasons.append("\(occupied.count) of \(c.policy.maxBooted) allowed at once are in use "
                    + "(\(holders.joined(separator: "; "))); the limit is the \(Policy.Key.maxBooted) setting")
            }
            if !swapping {
                let memory = c.memory()
                let needed = Int64(c.policy.minFreeMemoryGB) * 1_000_000_000
                if memory.isUnderPressure || (needed > 0 && memory.availableBytes < needed) {
                    reasons.append("memory is short (\(StorageUpkeep.format(memory.availableBytes)) free or compressible, "
                        + "needs \(StorageUpkeep.format(needed))\(memory.isUnderPressure ? ", and macOS reports memory pressure" : ""))")
                }
                let staleAfter = max(60, c.policy.pollSeconds * 10)
                state.waiting.removeAll {
                    $0.id != waiter.id && (now.timeIntervalSince($0.seen) > staleAfter || !c.isRunning($0.pid))
                }
                let ahead = state.waiting.prefix { $0.id != waiter.id }.count
                if ahead > 0 { reasons.append(ahead == 1 ? "1 request is ahead of yours" : "\(ahead) requests are ahead of yours") }
            }
            if !reasons.isEmpty {
                if queue {
                    var entry = waiter
                    entry.wants = description
                    entry.seen = now
                    if let index = state.waiting.firstIndex(where: { $0.id == waiter.id }) {
                        state.waiting[index] = entry
                    } else {
                        state.waiting.insert(entry, at: state.waiting.firstIndex { $0.since > waiter.since } ?? state.waiting.count)
                    }
                }
                return .waiting(reasons.joined(separator: "; ") + ".")
            }
        }

        end(ending, in: &state, simctl: c.simctl)
        let id = UUID().uuidString.lowercased()
        var notes = [target.note].compactMap { $0 }
        let udid: String, name: String
        if let reuse {
            udid = reuse
            name = devices.first { $0.udid == reuse }?.name ?? ""
        } else {
            // A copy of a shut-down pool simulator keeps its apps; a booted one can't be copied.
            name = "\(temporaryPrefix) · \(type.name) · \(runtime.name) · \(id.prefix(4))"
            if let member, devices.first(where: { $0.udid == member.udid })?.isBooted == false,
               let copy = try? c.simctl.clone(member.udid, name: name), !copy.isEmpty {
                udid = copy
            } else {
                udid = try c.simctl.create(name, type: type.identifier, runtime: runtime.identifier)
            }
            state.temporaries[udid] = now
            if target.temporaryOnly { notes.append("The pool doesn't keep \(description), so this is a temporary copy.") }
        }
        if !ending.isEmpty {
            notes.append("Released your lease on \(ending.map { describe($0.key) }.joined(separator: " and ")) first: "
                + "a tab has one simulator at a time.")
        }
        if !kept.isEmpty {
            notes.append("Your lease on \(kept.map { describe($0.key) }.joined(separator: " and ")) stays: "
                + "a running process still uses it.")
        }
        let lease = Lease(id: id, udid: udid, key: key, temporary: reuse == nil, tab: tab,
                          acquiredAt: now, expiresAt: now.addingTimeInterval(lifetime))
        state.leases.append(lease)
        return done(Acquired(lease: lease, name: name, description: description,
                             note: notes.isEmpty ? nil : notes.joined(separator: " "), released: ending))
    }

    /// The pool's simulator for `key`: the recorded one, else the most recently used existing one
    /// of that kind (adopted), else a new one.
    private static func poolMember(key: String, type: DeviceType, runtime: Runtime, state: inout State,
                                   devices: inout [Device], simctl: Simctl) throws -> Member {
        if let member = state.pool.first(where: { $0.key == key }),
           devices.contains(where: { $0.udid == member.udid && $0.isAvailable }) {
            return member
        }
        state.pool.removeAll { $0.key == key }
        let leased = Set(state.leases.map(\.udid))
        let snapshot = state
        let candidates = devices.filter {
            $0.typeIdentifier == type.identifier && $0.runtimeIdentifier == runtime.identifier && $0.isAvailable
                && !snapshot.isTemporary($0) && !leased.contains($0.udid) && snapshot.member($0.udid) == nil
        }
        let udid: String
        if let best = candidates.max(by: { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }) {
            udid = best.udid
            if let name = renameOnAdopting(best, type: type, runtime: runtime, simctl: simctl),
               let index = devices.firstIndex(where: { $0.udid == udid }) {
                devices[index].name = name
            }
        } else {
            let name = poolName(type: type, runtime: runtime)
            udid = try simctl.create(name, type: type.identifier, runtime: runtime.identifier)
            devices.append(Device(udid: udid, name: name, state: "Shutdown", typeIdentifier: type.identifier,
                                  runtimeIdentifier: runtime.identifier, isAvailable: true, dataBytes: 0, lastUsed: nil))
        }
        let member = Member(key: key, udid: udid)
        state.pool.append(member)
        return member
    }

    static func poolName(type: DeviceType, runtime: Runtime) -> String {
        "\(poolPrefix) · \(type.name) · \(runtime.name)"
    }

    /// A project's own simulator ("Maps-Duo-QA") takes the pool's name when adopted; Xcode's
    /// default ones keep theirs, since scripts pick them by name. Returns the new name.
    private static func renameOnAdopting(_ device: Device, type: DeviceType, runtime: Runtime, simctl: Simctl) -> String? {
        guard device.name != type.name, !device.name.hasPrefix(poolPrefix) else { return nil }
        let name = poolName(type: type, runtime: runtime)
        return (try? simctl.rename(device.udid, to: name)) == nil ? nil : name
    }

    /// Makes an existing simulator the pool's for its kind (`Family`), replacing the one it had. The
    /// pool's iPhone has to be `Policy.phone` on its OS.
    @discardableResult
    static func adopt(_ udid: String, context c: Context = Context()) throws -> Member {
        let devices = try c.simctl.devices()
        guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }), device.isAvailable else {
            throw Failure(message: "No available simulator has the UDID \(udid).")
        }
        let types = try c.simctl.deviceTypes(), runtimes = try c.simctl.runtimes()
        guard let type = types.first(where: { $0.identifier == device.typeIdentifier }),
              let runtime = runtimes.first(where: { $0.identifier == device.runtimeIdentifier }) else {
            throw Failure(message: "\(device.name)'s device type or runtime isn't installed.")
        }
        let family = Family(deviceName: type.name)
        if family == .phone {
            let (phoneType, phoneRuntime) = try phone(c.policy, types: types, runtimes: runtimes)
            guard phoneType == type, phoneRuntime.identifier == runtime.identifier else {
                throw Failure(message: "The pool's only iPhone is \(phoneType.name), \(phoneRuntime.name) (the "
                    + "\(Policy.Key.phone) and \(Policy.Key.phoneOS) settings): adopt one of those, or change them first.")
            }
        }
        return try c.store.locked { state in
            guard !state.isTemporary(device) else { throw Failure(message: "\(device.name) is a temporary copy.") }
            let member = Member(key: key(type: type, runtime: runtime), udid: device.udid)
            _ = renameOnAdopting(device, type: type, runtime: runtime, simctl: c.simctl)
            state.pool.removeAll {
                $0.key == member.key || $0.udid == member.udid || (!family.perVersion && Family(key: $0.key) == family)
            }
            state.pool.append(member)
            state.pool.sort { $0.key < $1.key }
            return member
        }
    }

    /// Ends leases: the one named by lease ID (or its first 8 characters) or UDID, all of `tab`'s,
    /// or every lease. Each simulator no other lease holds is shut down; a temporary one is deleted.
    @discardableResult
    static func release(_ target: String? = nil, tab: String? = nil, all: Bool = false,
                        context c: Context = Context()) throws -> [Lease] {
        try c.store.locked { state in
            let wanted = target?.trimmingCharacters(in: .whitespaces).lowercased()
            let ending = state.leases.filter { lease in
                if all { return true }
                if let wanted, !wanted.isEmpty {
                    return lease.id == wanted || (wanted.count >= 8 && lease.id.hasPrefix(wanted)) || lease.udid.lowercased() == wanted
                }
                return tab != nil && lease.tab == tab
            }
            end(ending, in: &state, simctl: c.simctl)
            return ending
        }
    }

    /// Whether `tab` holds any lease, read without the lock (for skipping work).
    static func hasLeases(tab: String, store: Store = .standard) -> Bool {
        store.read().leases.contains { $0.tab == tab }
    }

    /// The UDIDs `tab` holds.
    static func leasedUDIDs(tab: String, store: Store = .standard) -> [String] {
        store.read().leases.filter { $0.tab == tab }.map(\.udid)
    }

    private static func end(_ leases: [Lease], in state: inout State, simctl: Simctl) {
        let ids = Set(leases.map(\.id))
        state.leases.removeAll { ids.contains($0.id) }
        for udid in Set(leases.map(\.udid)) where !state.leases.contains(where: { $0.udid == udid }) {
            simctl.shutdown(udid)
            if leases.contains(where: { $0.udid == udid && $0.temporary }) {
                if (try? simctl.delete(udid)) != nil { state.temporaries[udid] = nil }
            }
        }
    }

    /// Ends leases past their time.
    private static func reap(_ state: inout State, now: Date, simctl: Simctl) {
        end(state.leases.filter { $0.expiresAt <= now }, in: &state, simctl: simctl)
    }

    // MARK: - Cleanup

    struct SweepOptions {
        /// Also clean up simulators the pool didn't make: delete named ones unused for
        /// `unusedDays`, erase Xcode's default ones that hold data, and delete ones whose runtime
        /// is gone. Off by default: they may be someone's.
        var includeUnmanaged = false
        var unusedDays = 3
        var temporaryHours = 24
        /// A pool simulator holding more data than this is erased while it's free (never an
        /// iPhone Duo's: its installed apps are kept).
        var poolSizeCap: Int64 = 10_000_000_000
        /// A free pool simulator or temporary copy booted longer than this is shut down.
        var idleBootMinutes = Policy().idleMinutes

        /// The pool's own upkeep, with the idle time from the settings.
        static func pool(_ policy: Policy) -> SweepOptions {
            var options = SweepOptions()
            options.idleBootMinutes = policy.idleMinutes
            return options
        }
    }

    /// Pool members the pool no longer keeps, by UDID, with why: an iPhone other than the pool's
    /// one (`phoneKey`), and all but one iPad, watch or TV (the first available one in pool order,
    /// as `resolve` hands out). The iPhone Duo keeps one per iOS version. Nothing leaves while its
    /// simulator is unavailable (its runtime missing for now), and no iPhone leaves before the
    /// pool's own one is there and available, so a runtime that's briefly gone can't make the
    /// wrong one leave.
    static func leaving(_ state: State, devices: [Device], phoneKey: String?) -> [String: String] {
        let available = Dictionary(devices.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a }).filter { $0.value.isAvailable }
        var result: [String: String] = [:]
        for (family, members) in Dictionary(grouping: state.pool, by: { Family(key: $0.key) }) where !family.perVersion {
            let keeper = family == .phone
                ? phoneKey.flatMap { key in members.first { $0.key == key && available[$0.udid] != nil } }
                : members.first { available[$0.udid] != nil }
            guard let keeper else { continue }
            for member in members where member.udid != keeper.udid && available[member.udid] != nil {
                result[member.udid] = family == .phone ? "every iPhone request shares the pool's \(describe(keeper.key))"
                    : "the pool keeps one \(family.label): \(describe(keeper.key))"
            }
        }
        return result
    }

    /// The pool's iPhone's key, or nil when it can't be resolved.
    static func phoneKey(_ policy: Policy, types: [DeviceType], runtimes: [Runtime]) -> String? {
        (try? phone(policy, types: types, runtimes: runtimes)).map { key(type: $0.0, runtime: $0.1) }
    }

    /// The pool's own upkeep, run every few minutes by the host and by `cantrip sim tidy`: idle
    /// simulators shut down, members the pool no longer keeps deleted once free, and old copies
    /// deleted. Nil when the pool has nothing to look after.
    static func tidy(dryRun: Bool = false, context c: Context = Context(), log: (String) -> Void = { _ in }) -> SweepReport? {
        let state = c.store.read()
        guard !state.pool.isEmpty || !state.leases.isEmpty || !state.temporaries.isEmpty else { return nil }
        return sweep(.pool(c.policy), dryRun: dryRun, context: c, log: log)
    }

    struct Action: Codable, Equatable {
        enum Kind: String, Codable { case deleted, erased, shutDown }
        var udid: String
        var name: String
        var kind: Kind
        var bytes: Int64
        var reason: String
    }

    struct SweepReport: Codable, Equatable {
        var actions: [Action] = []
        var errors: [String] = []
        var simulators = 0
        var totalBytes: Int64 = 0
        var poolBytes: Int64 = 0
        var leased = 0

        /// Space freed (deleted and erased simulators' data).
        var bytesRemoved: Int64 { actions.filter { $0.kind != .shutDown }.reduce(0) { $0 + $1.bytes } }
        var removedCount: Int { actions.filter { $0.kind != .shutDown }.count }
    }

    /// Cleans up simulators: never one with a live lease or a process using it, and never a
    /// booted one the pool didn't make. Pool simulators stay (erased past the size cap), except
    /// members the pool no longer keeps (`leaving`), which are deleted.
    static func sweep(_ o: SweepOptions, dryRun: Bool, context c: Context = Context(),
                      log: (String) -> Void = { _ in }) -> SweepReport {
        var report = SweepReport()
        do {
            let devices = try c.simctl.devices()
            let types = try c.simctl.deviceTypes()
            let typeNames = Dictionary(types.map { ($0.identifier, $0.name) }, uniquingKeysWith: { a, _ in a })
            let canonicalPhone = phoneKey(c.policy, types: types, runtimes: try c.simctl.runtimes())
            let lines = c.commandLines()
            let now = c.now()
            func work(_ state: inout State) {
                if !dryRun { reap(&state, now: now, simctl: c.simctl) }
                let live = Set(state.leases.filter { $0.expiresAt > now }.map(\.udid))
                report.leased = live.count
                report.simulators = devices.count
                report.totalBytes = devices.reduce(0) { $0 + $1.dataBytes }
                report.poolBytes = devices.filter { state.member($0.udid) != nil }.reduce(0) { $0 + $1.dataBytes }
                var deletesUnavailable = false
                let leavingMembers = leaving(state, devices: devices, phoneKey: canonicalPhone)
                let idle = Double(o.idleBootMinutes) * 60
                for device in devices {
                    guard !live.contains(device.udid), !lines.contains(where: { $0.contains(device.udid) }) else { continue }
                    let age = now.timeIntervalSince(device.lastUsed ?? .distantPast)
                    if state.isTemporary(device) {
                        let made = state.temporaries[device.udid] ?? device.lastUsed ?? .distantPast
                        if now.timeIntervalSince(made) >= Double(o.temporaryHours) * 3_600 {
                            act(.deleted, device, reason: "temporary copy without a lease for \(o.temporaryHours) hours")
                            if !dryRun { state.temporaries[device.udid] = nil }
                        } else if device.isBooted, age >= idle {
                            act(.shutDown, device, reason: "temporary copy booted without a lease")
                        }
                    } else if let member = state.member(device.udid) {
                        if let why = leavingMembers[device.udid] {
                            // A booted one may be someone's for a moment; it goes once idle.
                            guard !device.isBooted || age >= idle else { continue }
                            if act(.deleted, device, reason: "no longer in the pool: \(why)"), !dryRun {
                                state.pool.removeAll { $0.udid == device.udid }
                            }
                            continue
                        }
                        var shutDown = !device.isBooted
                        if device.isBooted, age >= idle {
                            act(.shutDown, device, reason: "pool simulator booted without a lease")
                            shutDown = true
                        }
                        if shutDown, device.dataBytes > o.poolSizeCap, Family(key: member.key) != .duo {
                            act(.erased, device, reason: "pool simulator over \(StorageUpkeep.format(o.poolSizeCap))")
                        }
                    } else if o.includeUnmanaged, !device.isBooted {
                        if !device.isAvailable {
                            act(.deleted, device, reason: "its runtime isn't installed", run: false)
                            deletesUnavailable = true
                            continue
                        }
                        guard age >= Double(o.unusedDays) * 86_400 else { continue }
                        let days = age > 365 * 86_400 ? "ever" : "\(Int(age / 86_400)) days"
                        if device.name == typeNames[device.typeIdentifier] {
                            // Xcode's own default simulators stay in its device list, emptied.
                            if device.dataBytes >= 100_000_000 { act(.erased, device, reason: "unused for \(days)") }
                        } else {
                            act(.deleted, device, reason: "not in the pool, unused for \(days)")
                        }
                    }
                }
                if deletesUnavailable, !dryRun {
                    do { try c.simctl.deleteUnavailable() } catch { report.errors.append(error.localizedDescription) }
                }
            }
            @discardableResult
            func act(_ kind: Action.Kind, _ device: Device, reason: String, run: Bool = true) -> Bool {
                if !dryRun, run {
                    do {
                        switch kind {
                        case .shutDown: c.simctl.shutdown(device.udid)
                        case .erased: c.simctl.shutdown(device.udid); try c.simctl.erase(device.udid)
                        case .deleted: c.simctl.shutdown(device.udid); try c.simctl.delete(device.udid)
                        }
                    } catch {
                        report.errors.append("Simulator \(device.name) (\(device.udid)): \(error.localizedDescription)")
                        return false
                    }
                }
                let verb: String
                switch kind {
                case .deleted: verb = dryRun ? "would delete" : "deleted"
                case .erased: verb = dryRun ? "would erase" : "erased"
                case .shutDown: verb = dryRun ? "would shut down" : "shut down"
                }
                let bytes = kind == .shutDown ? 0 : device.dataBytes
                report.actions.append(Action(udid: device.udid, name: device.name, kind: kind, bytes: bytes, reason: reason))
                log("simulator \(device.name) (\(device.udid)) \(verb): \(StorageUpkeep.format(device.dataBytes)), \(reason)")
                return true
            }
            if dryRun {
                var state = c.store.read()
                work(&state)
            } else {
                try c.store.locked { state in work(&state) }
            }
        } catch {
            report.errors.append("Simulators: \(error.localizedDescription)")
        }
        return report
    }
}
