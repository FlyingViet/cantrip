import Foundation

/// What a child tab's shell command needs that only one task may use at a time. The Simulator
/// waits its turn; the rest belong to the parent tab, which runs them after the merge.
enum ChildTabResource: String, CaseIterable {
    case simulator, cantrip, testFlight, release, device

    var denial: String {
        let what: String
        switch self {
        case .simulator: what = "Simulator runs"
        case .cantrip: what = "restarting, installing or deploying Cantrip"
        case .testFlight: what = "TestFlight uploads"
        case .release: what = "publishing releases and updates"
        case .device: what = "installing on devices"
        }
        return "Child tabs leave \(what) to the parent tab, which runs it after this work merges. Don't retry it another way; say in your Summary that it's needed."
    }

    private static let patterns: [(ChildTabResource, String)] = [
        (.simulator, #"\bxcodebuild\b[^;&|]*\btest(-without-building)?\b"#),
        (.simulator, #"\bsimctl\s+(boot|install|launch|spawn|io)\b"#),
        (.cantrip, #"deploy-when-idle"#),
        (.cantrip, #"\bmake\b[^;&|]*Cantrip\b[^;&|]*\brun\b"#),
        (.cantrip, #"\bcantrip\s+daemon\s+(start|stop|restart)\b"#),
        (.cantrip, #"CANTRIP_INSTALL_NOW"#),
        (.cantrip, #"Coding/Cantrip/install\.sh"#),
        (.cantrip, #"\bopen\s+(-[a-zA-Z]+\s+)*[^;&|]*Cantrip\.app\b"#),
        (.cantrip, #"(quit|kill)[^;&|]*(application|app)\s+"?Cantrip\b"#),
        (.testFlight, #"ios-testflight"#),
        (.testFlight, #"\baltool\b[^;&|]*--upload"#),
        (.testFlight, #"\bfastlane\s+(pilot|beta|deliver)\b"#),
        (.testFlight, #"\beas\s+submit\b"#),
        (.release, #"\bgh\s+release\s+(create|upload|edit|delete)\b"#),
        (.release, #"\brelease\.sh\b"#),
        (.release, #"\bnpm\s+publish\b"#),
        (.release, #"\beas\s+update\b"#),
        (.release, #"\bnetlify\s+deploy\b"#),
        (.release, #"\bdeploy:web\b"#),
        (.device, #"\bdevicectl\s+device\s+(install|process\s+launch)\b"#),
        (.device, #"\bios-deploy\b"#),
        (.device, #"\bideviceinstaller\b"#),
        (.device, #"\btailscale\s+file\s+cp\b"#),
        (.device, #"taildrop-when-online"#),
    ]

    /// The resource `command` needs, if any (the first match by the order above).
    static func resource(for command: String) -> ChildTabResource? {
        for (resource, pattern) in patterns
        where command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return resource
        }
        return nil
    }

    /// Whether some process on the Mac is running a Simulator build or test right now.
    static func simulatorBusy(commandLines: [String]) -> Bool {
        commandLines.contains { line in
            resource(for: line) == .simulator && !line.contains("bash -c") && !line.contains("zsh -c")
        }
    }
}

/// A host decision on one of a child tab's tool requests.
enum ChildPolicyVerdict: Equatable {
    case proceed
    case deny(String)
}

/// Host-wide turns for shared resources among child tabs. A child holds the Simulator from when
/// it's granted until its turn ends; any other build or test on the Mac also makes it wait.
@MainActor
final class ChildTabResourceLocks {
    static var pollInterval: UInt64 = 5_000_000_000
    static var maximumWait: TimeInterval = 40 * 60
    /// Tests replace it; the default reads the Mac's process list.
    var externallyBusy: @Sendable () -> Bool = {
        ChildTabResource.simulatorBusy(commandLines: StorageUpkeep.ProcessSnapshot.current().commandLines)
    }
    private(set) var holders: [ChildTabResource: UUID] = [:]
    /// Each session's current wait; `release` ends it, so a stopped child is never granted later.
    private var waits: [UUID: UUID] = [:]

    func acquire(_ resource: ChildTabResource, session: UUID, holderTitle: @escaping (UUID) -> String?,
                 status: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        if holders[resource] == session { return completion(true, "") }
        let started = Date()
        let busyCheck = externallyBusy
        let wait = UUID()
        waits[session] = wait
        Task { @MainActor [weak self] in
            var announced = ""
            while let self {
                guard self.waits[session] == wait else {
                    return completion(false, "Cantrip stopped waiting for the Simulator.")
                }
                let holder = self.holders[resource]
                var free = holder == nil || holder == session
                if free {
                    let busy = await Task.detached(priority: .utility) { busyCheck() }.value
                    free = !busy && (self.holders[resource] == nil || self.holders[resource] == session)
                }
                if free, self.waits[session] == wait {
                    self.holders[resource] = session
                    self.waits[session] = nil
                    return completion(true, "")
                }
                if Date().timeIntervalSince(started) > Self.maximumWait {
                    self.waits[session] = nil
                    return completion(false, "The Simulator stayed busy for \(Int(Self.maximumWait / 60)) minutes, so this run was skipped. Say so in your Summary.")
                }
                let who = self.holders[resource].flatMap(holderTitle).map { "child tab “\($0)”" } ?? "another build or test"
                let message = "Waiting for the Simulator: \(who) is using it"
                if message != announced {
                    announced = message
                    status(message)
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
            completion(false, "Cantrip stopped waiting for the Simulator.")
        }
    }

    func release(_ session: UUID) {
        holders = holders.filter { $0.value != session }
        waits[session] = nil
    }
}
